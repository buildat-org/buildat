// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// Hashes and big integer arithmetic for Lua: the primitives that are too slow
// or too fiddly to write in Lua. What is built on them -- an SRP login, say --
// is written in Lua.
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/sha1.h"
#include "interface/sha256.h"
#include "interface/bignum.h"
#include <mbedtls/gcm.h>
#include <mbedtls/pkcs5.h>
#include <qrcodegen.h>
#include <algorithm>
#include <cstring>
#include <map>
#include <memory>
#define MODULE "lua_bindings"

namespace lua_bindings {

// sha1(data: string) -> 20 bytes
static int l_sha1(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	ss_ digest = interface::sha1::calculate(data);
	lua_pushlstring(L, digest.c_str(), digest.size());
	return 1;
}

// sha256(data: string) -> 32 bytes
static int l_sha256(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	ss_ digest = interface::sha256::calculate(data);
	lua_pushlstring(L, digest.c_str(), digest.size());
	return 1;
}

// hex(data: string) -> string
static int l_hex(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	ss_ hex = interface::sha256::hex(data);
	lua_pushlstring(L, hex.c_str(), hex.size());
	return 1;
}

// Bignum primitives; numbers are big-endian byte strings. The composition on
// top of these -- SRP's hashing and padding, say -- belongs in Lua.

// An operand: 1024 bytes at most, twice SRP's 4096-bit group. A server's
// Lua handing mod_exp 70 kB numbers held the client's frame for minutes
static ss_ operand(lua_State *L, int i)
{
	ss_ v = lua_checkcppstring(L, i);
	if(v.size() > 1024)
		luaL_error(L, "bignum: an operand of 1024 bytes at most, got %d",
				(int)v.size());
	return v;
}

// bignum_add(a, b) -> a + b
static int l_bignum_add(lua_State *L)
{
	ss_ r = interface::bignum::add(operand(L, 1),
			operand(L, 2));
	lua_pushlstring(L, r.c_str(), r.size());
	return 1;
}

// bignum_mul(a, b) -> a * b
static int l_bignum_mul(lua_State *L)
{
	ss_ r = interface::bignum::mul(operand(L, 1),
			operand(L, 2));
	lua_pushlstring(L, r.c_str(), r.size());
	return 1;
}

// bignum_mod(a, m) -> a mod m
static int l_bignum_mod(lua_State *L)
{
	try {
		ss_ r = interface::bignum::mod(operand(L, 1),
				operand(L, 2));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_mod(): %s", e.what());
	}
	return 1;
}

// bignum_sub_mod(a, b, m) -> (a - b) mod m
static int l_bignum_sub_mod(lua_State *L)
{
	try {
		ss_ r = interface::bignum::sub_mod(operand(L, 1),
				operand(L, 2), operand(L, 3));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_sub_mod(): %s", e.what());
	}
	return 1;
}

// bignum_mul_mod(a, b, m) -> (a * b) mod m
static int l_bignum_mul_mod(lua_State *L)
{
	try {
		ss_ r = interface::bignum::mul_mod(operand(L, 1),
				operand(L, 2), operand(L, 3));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_mul_mod(): %s", e.what());
	}
	return 1;
}

// bignum_mod_exp(base, exponent, m) -> base^exponent mod m
static int l_bignum_mod_exp(lua_State *L)
{
	try {
		ss_ r = interface::bignum::mod_exp(operand(L, 1),
				operand(L, 2), operand(L, 3));
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "bignum_mod_exp(): %s", e.what());
	}
	return 1;
}

// random_bytes(n) -> n bytes from the platform's cryptographic random source
static int l_random_bytes(lua_State *L)
{
	int n = luaL_checkint(L, 1);
	if(n < 1 || n > 1024)
		return luaL_error(L, "random_bytes(): 1...1024 bytes, got %i", n);
	try {
		ss_ r = interface::bignum::random_bytes(n);
		lua_pushlstring(L, r.c_str(), r.size());
	} catch(std::exception &e){
		return luaL_error(L, "random_bytes(): %s", e.what());
	}
	return 1;
}

// -- [STARPORT] 10f: Mbed TLS, for the trusted side (client/core/network,
// client/core/starport); not in the sandbox

// seal(password, plain) -> a blob: a salt, PBKDF2-HMAC-SHA256 of the
// password (100000 rounds) as an AES-256-GCM key, the IV, the ciphertext
// and the tag. For the Starport ID tokens a client keeps (10c), opened by
// the password when the Starport cannot be reached.
static const int SEAL_ROUNDS = 100000;

static bool seal_key(const ss_ &password, const ss_ &salt, unsigned char *key)
{
	return mbedtls_pkcs5_pbkdf2_hmac_ext(MBEDTLS_MD_SHA256,
			(const unsigned char*)password.data(), password.size(),
			(const unsigned char*)salt.data(), salt.size(), SEAL_ROUNDS, 32,
			key) == 0;
}

static int l_seal(lua_State *L)
{
	const ss_ password = lua_checkcppstring(L, 1);
	const ss_ plain = lua_checkcppstring(L, 2);
	const ss_ salt = interface::bignum::random_bytes(16);
	const ss_ iv = interface::bignum::random_bytes(12);
	unsigned char key[32];
	if(!seal_key(password, salt, key))
		return luaL_error(L, "seal: PBKDF2 failed");
	ss_ out(plain.size(), '\0');
	unsigned char tag[16];
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int r = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 256);
	if(r == 0)
		r = mbedtls_gcm_crypt_and_tag(&gcm, MBEDTLS_GCM_ENCRYPT, plain.size(),
				(const unsigned char*)iv.data(), iv.size(), nullptr, 0,
				(const unsigned char*)plain.data(), (unsigned char*)&out[0],
				16, tag);
	mbedtls_gcm_free(&gcm);
	if(r != 0)
		return luaL_error(L, "seal: AES-GCM failed");
	const ss_ blob = salt+iv+out+ss_((const char*)tag, 16);
	lua_pushlstring(L, blob.data(), blob.size());
	return 1;
}

// unseal(password, blob) -> the plain text, or nil: a wrong password and a
// changed blob alike
static int l_unseal(lua_State *L)
{
	const ss_ password = lua_checkcppstring(L, 1);
	const ss_ blob = lua_checkcppstring(L, 2);
	if(blob.size() < 16 + 12 + 16)
		return 0;
	const ss_ salt = blob.substr(0, 16), iv = blob.substr(16, 12);
	const ss_ ct = blob.substr(28, blob.size() - 44);
	const ss_ tag = blob.substr(blob.size() - 16);
	unsigned char key[32];
	if(!seal_key(password, salt, key))
		return 0;
	ss_ out(ct.size(), '\0');
	mbedtls_gcm_context gcm;
	mbedtls_gcm_init(&gcm);
	int r = mbedtls_gcm_setkey(&gcm, MBEDTLS_CIPHER_ID_AES, key, 256);
	if(r == 0)
		r = mbedtls_gcm_auth_decrypt(&gcm, ct.size(),
				(const unsigned char*)iv.data(), iv.size(), nullptr, 0,
				(const unsigned char*)tag.data(), tag.size(),
				(const unsigned char*)ct.data(), (unsigned char*)&out[0]);
	mbedtls_gcm_free(&gcm);
	if(r != 0)
		return 0;
	lua_pushlstring(L, out.data(), out.size());
	return 1;
}

// qr_code(text) -> the modules' bits as a string of '0' and '1', a row at a
// time from the top, and the side; or nil. A TOTP secret's otpauth:// link,
// shown to an authenticator app's camera ([STARPORT] 10a). Safe: it reads
// nothing and writes nothing.
static int l_qr_code(lua_State *L)
{
	const ss_ text = lua_checkcppstring(L, 1);
	uint8_t qr[qrcodegen_BUFFER_LEN_MAX];
	uint8_t tmp[qrcodegen_BUFFER_LEN_MAX];
	if(text.size() > 1000 || !qrcodegen_encodeText(text.c_str(), tmp, qr,
			qrcodegen_Ecc_MEDIUM, qrcodegen_VERSION_MIN, qrcodegen_VERSION_MAX,
			qrcodegen_Mask_AUTO, true))
		return 0;
	const int n = qrcodegen_getSize(qr);
	ss_ bits;
	bits.reserve(n * n);
	for(int y = 0; y < n; y++)
		for(int x = 0; x < n; x++)
			bits += qrcodegen_getModule(qr, x, y) ? '1' : '0';
	lua_pushlstring(L, bits.data(), bits.size());
	lua_pushinteger(L, n);
	return 2;
}

void init_crypto(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(sha1)
	DEF_BUILDAT_FUNC(sha256)
	DEF_BUILDAT_FUNC(hex)
	DEF_BUILDAT_FUNC(bignum_add)
	DEF_BUILDAT_FUNC(bignum_mul)
	DEF_BUILDAT_FUNC(bignum_mod)
	DEF_BUILDAT_FUNC(bignum_sub_mod)
	DEF_BUILDAT_FUNC(bignum_mul_mod)
	DEF_BUILDAT_FUNC(bignum_mod_exp)
	DEF_BUILDAT_FUNC(random_bytes)
	DEF_BUILDAT_FUNC(seal)
	DEF_BUILDAT_FUNC(unseal)
	DEF_BUILDAT_FUNC(qr_code)
}

} // namespace lua_bindings

// vim: set noet ts=4 sw=4:
