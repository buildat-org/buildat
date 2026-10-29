// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/address.h"
#include "interface/aitta.h"
#include "interface/bignum.h"
#include "interface/compress.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/sha256.h"
#include "interface/zip.h"
#include "core/log.h"
#include "zlib.h"
#include <mbedtls/ecdsa.h>
#include <mbedtls/ecp.h>
#include <algorithm>
#include <cmath>
#include <cctype>
#include <cstring>
#include <fstream>
#include <sstream>
#include <tuple>

using interface::sha256::unhex;

#define MODULE "aitta"

namespace interface {
namespace aitta {

static const char *KEY_HEADER = "aitta-key-1 ";
static const char *SIG_FORMAT = RELEASE_FORMAT;

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	if(!f.good())
		throw Exception("cannot read "+path);
	std::ostringstream os;
	os<<f.rdbuf();
	return os.str();
}

static void write_file(const ss_ &path, const ss_ &data)
{
	std::ofstream f(path, std::ios::binary);
	f<<data;
	if(!f.good())
		throw Exception("cannot write "+path);
}

static int rng(void*, unsigned char *out, size_t len)
{
	const ss_ r = bignum::random_bytes(len);
	memcpy(out, r.data(), len);
	return 0;
}

// What is signed: the format and the data's hash, so that a signature
// over something else is never one over a release
static ss_ digest_of_hash(const ss_ &sha256_hex, const char *format)
{
	return sha256::calculate(ss_(format)+"\n"+sha256_hex);
}

struct Keypair {
	mbedtls_ecp_keypair kp;
	Keypair(){ mbedtls_ecp_keypair_init(&kp); }
	~Keypair(){ mbedtls_ecp_keypair_free(&kp); }
	ss_ public_hex(){
		unsigned char buf[100];
		size_t n = 0;
		if(mbedtls_ecp_write_public_key(&kp, MBEDTLS_ECP_PF_UNCOMPRESSED,
				&n, buf, sizeof buf) != 0)
			throw Exception("cannot write the public key");
		return sha256::hex(ss_((char*)buf, n));
	}
};

static void load_key(Keypair &k, const ss_ &key_file_text)
{
	const ss_ head = KEY_HEADER;
	ss_ t = key_file_text;
	while(!t.empty() && (t.back() == '\n' || t.back() == '\r' || t.back() == ' '))
		t.pop_back();
	if(t.compare(0, head.size(), head) != 0)
		throw Exception("not an aitta key (no \""+head+"\")");
	const ss_ d = unhex(t.substr(head.size()));
	if(mbedtls_ecp_read_key(MBEDTLS_ECP_DP_SECP256R1, &k.kp,
			(const unsigned char*)d.data(), d.size()) != 0 ||
			mbedtls_ecp_keypair_calc_public(&k.kp, rng, nullptr) != 0)
		throw Exception("a bad aitta key");
}

void keygen(ss_ &key_file_text, ss_ &public_hex)
{
	Keypair k;
	if(mbedtls_ecp_gen_key(MBEDTLS_ECP_DP_SECP256R1, &k.kp, rng, nullptr) != 0)
		throw Exception("cannot make a key");
	unsigned char d[32];
	size_t n = 0;
	if(mbedtls_ecp_write_key_ext(&k.kp, &n, d, sizeof d) != 0)
		throw Exception("cannot write the key");
	key_file_text = ss_(KEY_HEADER)+sha256::hex(ss_((char*)d, n))+"\n";
	public_hex = k.public_hex();
}

ss_ public_of(const ss_ &key_file_text)
{
	Keypair k;
	load_key(k, key_file_text);
	return k.public_hex();
}

ss_ sign(const ss_ &key_file_text, const ss_ &data, const char *format)
{
	Keypair k;
	load_key(k, key_file_text);
	mbedtls_ecdsa_context ctx;
	mbedtls_ecdsa_init(&ctx);
	const ss_ h = digest_of_hash(sha256::hex(sha256::calculate(data)),
			format);
	unsigned char sig[MBEDTLS_ECDSA_MAX_LEN];
	size_t n = 0;
	int r = mbedtls_ecdsa_from_keypair(&ctx, &k.kp);
	if(r == 0)
		r = mbedtls_ecdsa_write_signature(&ctx, MBEDTLS_MD_SHA256,
				(const unsigned char*)h.data(), h.size(), sig, sizeof sig, &n,
				rng, nullptr);
	mbedtls_ecdsa_free(&ctx);
	if(r != 0)
		throw Exception("cannot sign");
	return sha256::hex(ss_((char*)sig, n));
}

bool verify(const ss_ &public_hex, const ss_ &data, const ss_ &signature_hex,
		const char *format)
{
	return verify_hash(public_hex, sha256::hex(sha256::calculate(data)),
			signature_hex, format);
}

bool verify_hash(const ss_ &public_hex, const ss_ &sha256_hex,
		const ss_ &signature_hex, const char *format)
{
	ss_ q, sig;
	try {
		q = unhex(public_hex);
		sig = unhex(signature_hex);
	} catch(std::exception &){
		return false;
	}
	Keypair k;
	mbedtls_ecp_group grp;
	mbedtls_ecp_point pt;
	mbedtls_ecp_group_init(&grp);
	mbedtls_ecp_point_init(&pt);
	mbedtls_ecdsa_context ctx;
	mbedtls_ecdsa_init(&ctx);
	const ss_ h = digest_of_hash(sha256_hex, format);
	bool ok = mbedtls_ecp_group_load(&grp, MBEDTLS_ECP_DP_SECP256R1) == 0 &&
			mbedtls_ecp_point_read_binary(&grp, &pt,
				(const unsigned char*)q.data(), q.size()) == 0 &&
			mbedtls_ecp_set_public_key(MBEDTLS_ECP_DP_SECP256R1, &k.kp, &pt) == 0 &&
			mbedtls_ecdsa_from_keypair(&ctx, &k.kp) == 0 &&
			mbedtls_ecdsa_read_signature(&ctx,
				(const unsigned char*)h.data(), h.size(),
				(const unsigned char*)sig.data(), sig.size()) == 0;
	mbedtls_ecdsa_free(&ctx);
	mbedtls_ecp_point_free(&pt);
	mbedtls_ecp_group_free(&grp);
	return ok;
}

// A name a path is made of: a directory under <user>/installed
static bool plain_name(const ss_ &s, bool dots)
{
	if(s.empty() || s.size() > 40 || s == "." || s == "..")
		return false;
	for(char c : s){
		const bool ok = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
				c == '_' || (dots && ((c >= 'A' && c <= 'Z') || c == '.' ||
					c == '-' || c == '+'));
		if(!ok)
			return false;
	}
	return true;
}

// SemVer 2.0 ([COMPAT_BREAK_07] 8k): MAJOR.MINOR.PATCH, numbers without a
// leading zero, then -pre.release and +build, dot-separated identifiers of
// 0-9A-Za-z-, a numeric one of the prerelease without a leading zero
bool semver_ok(const ss_ &v)
{
	if(!plain_name(v, true))
		return false;
	const size_t plus = v.find('+');
	const ss_ build = plus == ss_::npos ? "" : v.substr(plus + 1);
	const ss_ head = v.substr(0, plus);
	const size_t dash = head.find('-');
	const ss_ core = head.substr(0, dash);
	const ss_ pre = dash == ss_::npos ? "" : head.substr(dash + 1);
	auto ids = [](const ss_ &s, bool numeric_only, bool no_lead_zero){
		size_t n = 0;
		for(size_t a = 0; a <= s.size(); n++){
			size_t b = s.find('.', a);
			if(b == ss_::npos)
				b = s.size();
			const ss_ id = s.substr(a, b - a);
			const bool num = !id.empty() &&
					id.find_first_not_of("0123456789") == ss_::npos;
			if(id.empty() || id.find_first_not_of("0123456789"
					"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ-") !=
					ss_::npos || (numeric_only && !num) ||
					(no_lead_zero && num && id.size() > 1 && id[0] == '0'))
				return (size_t)0;
			a = b + 1;
		}
		return n;
	};
	return ids(core, true, true) == 3 &&
			(dash == ss_::npos || ids(pre, false, true) > 0) &&
			(plus == ss_::npos || ids(build, false, false) > 0);
}

// An http(s) address with no space, quote or angle bracket in it
static bool address_ok(const ss_ &a)
{
	interface::Url u;
	if(a.size() > 200 || !interface::parse_url(a, &u) ||
			(u.scheme != "http" && u.scheme != "https"))
		return false;
	for(char c : a)
		if(c <= ' ' || c > '~' || c == '"' || c == '<' || c == '>' ||
				c == '\\')
			return false;
	return true;
}

// A path inside the archive: '/' separated, no part empty or starting
// with '.' (pack leaves those out), letters, digits, . - _
static bool archive_path_ok(const ss_ &p)
{
	if(p.empty() || p.size() > 200)
		return false;
	bool part_start = true;
	for(char c : p){
		if(c == '/'){
			if(part_start)
				return false;
			part_start = true;
			continue;
		}
		if(part_start && c == '.')
			return false;
		if(!isalnum((unsigned char)c) && c != '.' && c != '-' && c != '_')
			return false;
		part_start = false;
	}
	return !part_start;
}

// **The app contract** ([COMPAT_BREAK_07] 8c): "" when a module's
// meta.json is one this loads, else why not. An app's module says the
// engine API it is written for; a builtin is the engine's own. A key this
// does not know is refused rather than ignored, so that a misspelt one or
// one a newer Buildat added says so.
ss_ module_meta_refusal(const json::Value &v, bool builtin)
{
	if(!v.is_object())
		return "meta.json is not an object";
	static const char *known[] = {"engine_api", "kind", "comment",
		"client_main", "client_extensions", "disable_cpp", "dependencies",
		"reverse_dependencies", "cxxflags", "ldflags", "cxxflags_windows",
		"ldflags_windows", "cxxflags_linux", "ldflags_linux", "web",
		"server_wasm"};
	for(json::Iterator it(v); it.valid(); it.next()){
		const ss_ key = it.key();
		bool ok = false;
		for(const char *k : known)
			ok = ok || key == k;
		if(!ok)
			return "meta.json: \""+key.substr(0, 40)+"\" is not a key this "
					"Buildat knows";
	}
	// [WEB_LOCAL_SERVER]: the module keeps to the web API; read by the web
	// server's build (util/web_server.cmake), not here
	if(!v.get("web").is_undefined() && !v.get("web").is_boolean())
		return "meta.json: \"web\" is true or false";
	const json::Value &api = v.get("engine_api");
	if(builtin && api.is_undefined())
		return "";
	if(!api.is_integer())
		return "meta.json: \"engine_api\": the engine API it is written for "
				"is missing; this Buildat runs "+
				itos(ENGINE_API_MIN)+"-"+
				itos(ENGINE_API);
	const ss_ why = engine_api_refusal(api.as_integer());
	return why.empty() ? "" : "meta.json: "+why;
}

ss_ check_manifest(const json::Value &m, bool service)
{
	if(!m.is_object())
		return "meta.json is not an object";
	auto str = [&](const char *k) -> ss_ {
		const json::Value &v = m.get(k);
		return v.is_string() ? v.as_string() : "";
	};
	if(!plain_name(str("author"), false))
		return "\"author\": 1 to 40 of a-z, 0-9 and _";
	if(!plain_name(str("name"), false))
		return "\"name\": 1 to 40 of a-z, 0-9 and _";
	if(!semver_ok(str("version")))
		return "\"version\": a SemVer 2.0 version, like 1.0.0 or 1.0.0-beta.1";
	const json::Value &api = m.get("engine_api");
	if(!api.is_integer() || api.as_integer() < 1)
		return "\"engine_api\": the engine API it is written against, 1 or more";
	if(!service && !engine_api_refusal(api.as_integer()).empty())
		return engine_api_refusal(api.as_integer());
	if(str("license_code").empty() || str("license_media").empty())
		return "\"license_code\" and \"license_media\": its licences";
	if(str("description").size() > 300)
		return "\"description\": 300 characters at most";
	for(const char *k : {"home_hearth", "changelog", "icon", "screenshot"})
		if(!m.get(k).is_undefined() && !m.get(k).is_string())
			return ss_("\"")+k+"\": a string";
	if(!str("home_hearth").empty() && !address_ok(str("home_hearth")))
		return "\"home_hearth\": an http:// or https:// address, 200 "
				"characters at most";
	if(!str("changelog").empty() && !archive_path_ok(str("changelog")))
		return "\"changelog\": a path inside the archive, like CHANGELOG.md";
	for(const char *k : {"icon", "screenshot"})
		if(!str(k).empty() && !archive_path_ok(str(k)))
			return ss_("\"")+k+"\": a path inside the archive, like icon.png";
	// An app named by a variant's base or a world's app: a plain name or
	// <author>.<name>
	auto app_ref_ok = [](const ss_ &b){
		const size_t dot = b.find('.');
		return dot == ss_::npos ? plain_name(b, false) :
				plain_name(b.substr(0, dot), false) &&
				plain_name(b.substr(dot + 1), false);
	};
	// [LUANTI_APP_PACKAGES] A variant's base, and a version to start from
	if(!m.get("base").is_undefined() && !app_ref_ok(str("base")))
		return "\"base\": an app's name, like vanilla, or an installed "
				"package's <author>.<name>";
	if(!m.get("base_version").is_undefined() &&
			!semver_ok(str("base_version")))
		return "\"base_version\": a SemVer 2.0 version, like 1.2.0";
	// [FRONT_PAGES]: who it suits; a browser's page at / lists only
	// "everyone" and "teen"
	// A newer Buildat's word, to a service: a word
	auto known = [&](const char *k, std::initializer_list<const char*> set){
		if(m.get(k).is_undefined())
			return true;
		for(const char *x : set)
			if(str(k) == x)
				return true;
		return service && plain_name(str(k), false);
	};
	if(!known("audience", {"everyone", "teen", "adult"}))
		return "\"audience\": \"everyone\", \"teen\" or \"adult\"";
	if(!known("kind", {"app", "extension", "world", "remix"}))
		return "\"kind\": \"app\", \"extension\", \"world\" or \"remix\"";
	// [APP_REMIX] The settings an app declares, and a remix's values of
	// its base's (checked against them where the base is: remix_refusal)
	if(!m.get("settings").is_undefined()){
		const ss_ why = check_settings_schema(m.get("settings"));
		if(!why.empty())
			return "\"settings\": "+why;
	}
	if(kind_of(m) == "remix"){
		if(!app_ref_ok(str("base")))
			return "\"base\": a remix names the app it is made on, like "
					"demo_board_game, or an installed package's "
					"<author>.<name>";
		const json::Value &v = m.get("setting_values");
		if(!v.is_undefined() && (!v.is_object() || v.size() > SETTINGS_MAX))
			return "\"setting_values\": an object of "+itos(SETTINGS_MAX)+
					" values at most";
		for(json::Iterator it(v); v.is_object() && it.valid(); it.next()){
			const json::Value &x = it.value();
			if(!plain_name(it.key(), false) || !(x.is_number() ||
					x.is_boolean() || (x.is_string() &&
					x.as_string().size() <= 4000)))
				return "\"setting_values\": \""+it.key().substr(0, 40)+
						"\" is not a setting's name with a number, true or "
						"false or a text";
		}
	}
	// [WORLD_PACKAGES] A world is a save of the app it names, made with
	// the versions it names
	if(kind_of(m) == "world"){
		if(!app_ref_ok(str("app")))
			return "\"app\": the app the world is a save of, like vanilla, "
					"or an installed package's <author>.<name>";
		if(!m.get("app_version").is_undefined() &&
				!semver_ok(str("app_version")))
			return "\"app_version\": the app's version it was made with, "
					"a SemVer 2.0 version";
		if(!m.get("buildat_version").is_undefined() &&
				!plain_name(str("buildat_version"), true))
			return "\"buildat_version\": the Buildat it was made with, like "
					"0.7.91";
	}
	// An extension's name in the client is "<author>__<name>", which has to
	// split one way only
	if(kind_of(m) == "extension")
		for(const char *k : {"author", "name"})
			if(str(k).front() == '_' || str(k).back() == '_' ||
					str(k).find("__") != ss_::npos)
				return ss_("\"")+k+"\": an extension's has no \"__\" and "
						"does not start or end with _";
	return "";
}

ss_ media_check(const ss_ &which, const ss_ &data, ss_ *type)
{
	const bool icon = which == "icon", texture = which == "texture";
	const size_t max_bytes = icon ? 64 * 1024 : texture ? 16 << 20 :
			2 * 1000 * 1000;
	const uint32_t max_side = icon ? 256 : texture ? 4096 : 1920;
	const unsigned char *d = (const unsigned char*)data.data();
	auto be = [&](size_t at, int n){
		uint32_t v = 0;
		for(int i = 0; i < n; i++)
			v = v << 8 | d[at + i];
		return v;
	};
	uint32_t w = 0, h = 0;
	ss_ t;
	if(data.size() >= 24 && data.compare(0, 8, "\x89PNG\r\n\x1a\n") == 0 &&
			data.compare(12, 4, "IHDR") == 0){
		t = "image/png";
		w = be(16, 4);
		h = be(20, 4);
	} else if(!icon && data.size() >= 4 && d[0] == 0xff && d[1] == 0xd8){
		// The markers to the first SOF: SOF0 to SOF2 at 8 bits are what
		// stb_image decodes
		size_t at = 2;
		while(at + 4 <= data.size()){
			if(d[at] != 0xff)
				return which+": not a JPEG the client can read";
			const unsigned char m = d[at + 1];
			if(m == 0xff){
				at++;
				continue;
			}
			if(m == 0x01 || (m >= 0xd0 && m <= 0xd7)){
				at += 2;
				continue;
			}
			const uint32_t len = be(at + 2, 2);
			if(m >= 0xc0 && m <= 0xc2){
				if(at + 9 > data.size() || len < 8)
					break;
				if(d[at + 4] != 8)
					return which+": a JPEG of 8 bits a sample only";
				h = be(at + 5, 2);
				w = be(at + 7, 2);
				t = "image/jpeg";
				break;
			}
			if((m >= 0xc3 && m <= 0xcf && m != 0xc4 && m != 0xc8 &&
					m != 0xcc) || m == 0xda || m == 0xd9)
				return which+": a baseline or progressive JPEG only "
						"(no lossless, no arithmetic coding)";
			if(len < 2)
				break;
			at += 2 + len;
		}
		if(t.empty())
			return which+": not a JPEG the client can read";
	} else {
		return icon ? "icon: not a PNG" : which+": not a PNG or a JPEG";
	}
	if(data.size() > max_bytes)
		return which+": "+itos((int64_t)data.size() / 1000)+" kB, more than "+
				itos((int64_t)max_bytes / 1000)+" kB";
	if(w < 1 || h < 1 || w > max_side || h > max_side)
		return which+": "+itos((int64_t)w)+"x"+itos((int64_t)h)+", not 1 to "+
				itos((int64_t)max_side)+" px a side";
	if(icon && w != h)
		return "icon: "+itos((int64_t)w)+"x"+itos((int64_t)h)+", not square";
	if(type)
		*type = t;
	return "";
}

ss_ check_media(const json::Value &m, const ss_ &dir)
{
	for(const char *k : {"icon", "screenshot"}){
		const json::Value &v = m.get(k);
		if(!v.is_string() || v.as_string().empty())
			continue;
		const ss_ path = dir+"/"+v.as_string();
		if(!fs::path_exists(path))
			return ss_("\"")+k+"\": "+v.as_string()+" is not there";
		const ss_ why = media_check(k, read_file(path));
		if(!why.empty())
			return v.as_string()+": "+why.substr(why.find(": ") + 2);
	}
	return "";
}

// a < b in SemVer's order. simplified: MAJOR.MINOR.PATCH by number and a
// prerelease below its release; two prereleases compare as strings, not
// by SemVer's identifiers (1.0.0-beta.11 is below 1.0.0-beta.2 here)
static bool version_less(const ss_ &a, const ss_ &b)
{
	auto key = [](const ss_ &v){
		const ss_ head = v.substr(0, v.find('+'));
		const size_t dash = head.find('-');
		long long n[3] = {0, 0, 0};
		sscanf(head.c_str(), "%lld.%lld.%lld", &n[0], &n[1], &n[2]);
		return std::make_tuple(n[0], n[1], n[2], dash == ss_::npos,
				dash == ss_::npos ? ss_() : head.substr(dash + 1));
	};
	return key(a) < key(b);
}

static ss_ major_of(const ss_ &v)
{
	return v.substr(0, v.find('.'));
}

ss_ find_base(const json::Value &m, const ss_ &app_dir,
		const ss_ &share_path, const ss_ &user_path, ss_ *why)
{
	why->clear();
	const json::Value &bv = m.get("base");
	if(!bv.is_string())
		return "";
	const ss_ b = bv.as_string();
	const size_t dot = b.find('.');
	if(dot == ss_::npos){
		if(!plain_name(b, false)){
			*why = "the base \""+b+"\" is not an app's name";
			return "";
		}
		for(const ss_ &d : {app_dir+"/../"+b, share_path+"/apps/"+b})
			if(fs::path_exists(d+"/main/meta.json"))
				return d;
		*why = "the base app \""+b+"\" is not there";
		return "";
	}
	const ss_ author = b.substr(0, dot), name = b.substr(dot + 1);
	const json::Value &from = m.get("base_version");
	const ss_ least = from.is_string() ? from.as_string() : "";
	if(!plain_name(author, false) || !plain_name(name, false) ||
			(!least.empty() && !semver_ok(least))){
		*why = "the base \""+b+"\" is not <author>.<name>";
		return "";
	}
	const ss_ dir = user_path+"/installed/"+author+"/"+name;
	ss_ best;
	for(const fs::Node &n : fs::list_directory(dir)){
		if(!n.is_directory || !semver_ok(n.name) ||
				!fs::path_exists(dir+"/"+n.name+"/main/meta.json"))
			continue;
		if(!least.empty() && (major_of(n.name) != major_of(least) ||
				version_less(n.name, least)))
			continue;
		if(best.empty() || version_less(best, n.name))
			best = n.name;
	}
	if(best.empty()){
		*why = "the base "+author+"/"+name+(least.empty() ? ss_() :
				" "+least+" or a newer "+major_of(least)+".x")+
				" is not installed";
		return "";
	}
	return dir+"/"+best;
}

ss_ kind_of(const json::Value &m)
{
	const json::Value &k = m.get("kind");
	return k.is_string() && (k.as_string() == "extension" ||
			k.as_string() == "world" || k.as_string() == "remix") ?
			k.as_string() : "app";
}

// [APP_REMIX] **An app's settings and a remix of it**
static size_t utf8_chars(const ss_ &s);

// A path's extension, lower case; "" for none
static ss_ ext_of(const ss_ &p)
{
	const size_t dot = p.rfind('.');
	if(dot == ss_::npos || p.find('/', dot) != ss_::npos)
		return "";
	ss_ e = p.substr(dot + 1);
	for(char &c : e)
		c = tolower((unsigned char)c);
	return e;
}
// The extensions of a file type's value, " png jpg jpeg ", or "" for a
// type that is no file
static ss_ type_exts(const ss_ &type)
{
	return type == "texture" ? " png jpg jpeg " : type == "model" ? " mdl " :
			type == "world" ? " json " : "";
}
// What a remix may carry in place of its base's file: those, and sounds
static const char *const REPLACEABLE = " png jpg jpeg mdl json ogg wav ";
static const uint64_t ASSET_MAX = 16 << 20;
static bool has_ext(const ss_ &exts, const ss_ &p)
{
	const ss_ e = ext_of(p);
	return !e.empty() && exts.find(" "+e+" ") != ss_::npos;
}
bool remix_replaceable(const ss_ &path)
{
	return has_ext(REPLACEABLE, path);
}
static double num(const json::Value &v)
{
	return v.is_integer() ? (double)v.as_integer() : v.as_real();
}
static ss_ gnum(double x)
{
	char b[32];
	snprintf(b, sizeof b, "%g", x);
	return b;
}

ss_ check_setting_value(const json::Value &f, const json::Value &v,
		const set_<ss_> *files)
{
	const ss_ type = json::jstr(f, "type");
	if(type == "number"){
		if(!v.is_number() || !std::isfinite(num(v)))
			return "a number";
		const double x = num(v);
		if(f.get("integer").is_true() && x != std::floor(x))
			return "a whole number";
		if(f.get("min").is_number() && x < num(f.get("min")))
			return "at least "+gnum(num(f.get("min")));
		if(f.get("max").is_number() && x > num(f.get("max")))
			return "at most "+gnum(num(f.get("max")));
		return "";
	}
	if(type == "bool")
		return v.is_boolean() ? "" : "true or false";
	if(!v.is_string())
		return "a text";
	const ss_ s = v.as_string();
	if(type == "choice"){
		const json::Value &c = f.get("choices");
		for(unsigned i = 0; c.is_array() && i < c.size(); i++)
			if(c.at(i).is_string() && c.at(i).as_string() == s)
				return "";
		return "one of its choices";
	}
	if(type == "color")
		return s.size() == 7 && s[0] == '#' && s.find_first_not_of(
				"0123456789abcdefABCDEF", 1) == ss_::npos ? "" :
				"a colour as #rrggbb";
	if(type == "text"){
		const int64_t most = f.get("max_length").is_integer() ?
				f.get("max_length").as_integer() : 100;
		if((int64_t)utf8_chars(s) > most)
			return "at most "+itos(most)+" characters";
		for(unsigned char c : s)
			if(c < 0x20 || c == 0x7f)
				return "a line of text";
		return "";
	}
	// A file of the app's, by the name its client reads it by
	if(!archive_path_ok(s) || s.find('/') == ss_::npos ||
			!has_ext(type_exts(type), s))
		return "a file of the app, <module>/<path>, of"+
				type_exts(type).substr(0, type_exts(type).size() - 1);
	if(files && !files->count(s))
		return s+" is not one of the app's files";
	return "";
}

ss_ check_settings_schema(const json::Value &s)
{
	if(!s.is_array() || s.size() > SETTINGS_MAX)
		return "a list of "+itos(SETTINGS_MAX)+" fields at most";
	set_<ss_> names;
	for(unsigned i = 0; i < s.size(); i++){
		const json::Value &f = s.at(i);
		const ss_ name = json::jstr(f, "name"), type = json::jstr(f, "type");
		if(!f.is_object() || !plain_name(name, false))
			return "each a field, {\"name\": 1 to 40 of a-z, 0-9 and _, "
					"\"type\": ..., \"default\": ...}";
		const ss_ at = name+": ";
		if(!names.insert(name).second)
			return at+"named twice";
		for(const char *k : {"label", "description"})
			if(!f.get(k).is_undefined() && (!f.get(k).is_string() ||
					utf8_chars(f.get(k).as_string()) > 300))
				return at+"\""+k+"\": a text of 300 characters at most";
		if(type == "number"){
			for(const char *k : {"min", "max"})
				if(!f.get(k).is_undefined() && !(f.get(k).is_number() &&
						std::isfinite(num(f.get(k)))))
					return at+"\""+k+"\": a number";
			if(!f.get("integer").is_undefined() &&
					!f.get("integer").is_boolean())
				return at+"\"integer\": true or false";
			if(f.get("min").is_number() && f.get("max").is_number() &&
					num(f.get("min")) > num(f.get("max")))
				return at+"\"min\" is more than \"max\"";
		} else if(type == "text"){
			const json::Value &n = f.get("max_length");
			if(!n.is_undefined() && !(n.is_integer() && n.as_integer() >= 1 &&
					n.as_integer() <= 1000))
				return at+"\"max_length\": 1 to 1000";
		} else if(type == "choice"){
			const json::Value &c = f.get("choices");
			if(!c.is_array() || c.size() < 1 || c.size() > SETTINGS_MAX)
				return at+"\"choices\": a list of 1 to "+itos(SETTINGS_MAX);
			for(unsigned k = 0; k < c.size(); k++)
				if(!c.at(k).is_string() || c.at(k).as_string().empty() ||
						utf8_chars(c.at(k).as_string()) > 100)
					return at+"\"choices\": texts of 1 to 100 characters";
		} else if(type != "bool" && type != "color" &&
				type_exts(type).empty()){
			return at+"\"type\": number, bool, choice, color, text, "
					"texture, model or world";
		}
		const ss_ why = check_setting_value(f, f.get("default"), nullptr);
		if(!why.empty())
			return at+"\"default\": "+why;
	}
	return "";
}

// Every file under dir, '/' separated, the names starting with '.' too
static void walk_all(const ss_ &dir, const ss_ &prefix, sv_<ss_> &out)
{
	for(const fs::Node &n : fs::list_directory(dir)){
		if(n.name.empty() || n.name == "." || n.name == "..")
			continue;
		if(n.is_directory)
			walk_all(dir+"/"+n.name, prefix+n.name+"/", out);
		else
			out.push_back(prefix+n.name);
	}
}

sm_<ss_, ss_> app_client_files(const ss_ &app_dir)
{
	sm_<ss_, ss_> out;
	for(const fs::Node &m : fs::list_directory(app_dir)){
		const ss_ cd = app_dir+"/"+m.name+"/client_data";
		if(!m.is_directory || m.name[0] == '.' ||
				!fs::path_exists(app_dir+"/"+m.name+"/meta.json"))
			continue;
		sv_<ss_> names;
		walk_all(cd, "", names);
		for(const ss_ &n : names)
			out[m.name+"/"+n] = cd+"/"+n;
	}
	return out;
}

// A file a remix carries checked by its bytes: "" or why not
static ss_ asset_refusal(const ss_ &path, const ss_ &ext)
{
	if(fs::file_size(path) > ASSET_MAX)
		return "more than "+itos(ASSET_MAX >> 20)+" MiB";
	const ss_ d = read_file(path);
	if(ext == "png" || ext == "jpg" || ext == "jpeg"){
		ss_ type;
		const ss_ why = media_check("texture", d, &type);
		if(!why.empty())
			return why.substr(why.find(": ") + 2);
		return (ext == "png") == (type == "image/png") ? "" :
				"not a ."+ext+" by its bytes";
	}
	if(ext == "mdl")
		return d.compare(0, 4, "UMDL") == 0 || d.compare(0, 4, "UMD2") == 0 ?
				"" : "not a model (.mdl) by its bytes";
	if(ext == "ogg")
		return d.compare(0, 4, "OggS") == 0 ? "" : "not an Ogg file";
	if(ext == "wav")
		return d.size() >= 12 && d.compare(0, 4, "RIFF") == 0 &&
				d.compare(8, 4, "WAVE") == 0 ? "" : "not a WAVE file";
	json::json_error_t e;
	return json::load_string(d.c_str(), &e).is_undefined() ? "not JSON" : "";
}

ss_ remix_refusal(const ss_ &dir, const json::Value &m, const ss_ &base_dir)
{
	if(kind_of(m) != "remix")
		return "not a remix";
	sm_<ss_, ss_> base_files;
	json::Value schema;
	if(!base_dir.empty()){
		json::json_error_t e;
		const json::Value bm = json::load_file((base_dir+"/meta.json").c_str(),
				&e);
		// simplified: on an app only; a remix of a variant would need the
		// loader to take a base's base
		if(!bm.get("base").is_undefined() || kind_of(bm) != "app")
			return "its base "+json::jstr(m, "base")+" is a variant or a "
					"remix; a remix is made on an app";
		schema = bm.get("settings");
		if(!schema.is_array() || !check_settings_schema(schema).empty())
			return "its base "+json::jstr(m, "base")+" declares no settings";
		base_files = app_client_files(base_dir);
	}
	// Data only: what the base's code runs (modules, client Lua, the
	// launcher, shaders) is not among what it may carry
	sv_<ss_> files;
	walk_all(dir, "", files);
	for(const ss_ &p : files){
		if(p == "meta.json")
			continue;
		const size_t slash = p.find('/');
		const ss_ ext = ext_of(p);
		if(slash == ss_::npos){
			if(archive_path_ok(p) && (ext == "png" || ext == "jpg" ||
					ext == "jpeg" || ext == "md" || ext == "txt"))
				continue;
			return p+": at a remix's root only meta.json and its images and "
					"texts (.png, .jpg, .md, .txt)";
		}
		const size_t second = p.find('/', slash + 1);
		if(!archive_path_ok(p) || second == ss_::npos ||
				p.compare(slash, second - slash + 1, "/client_data/") != 0 ||
				!has_ext(REPLACEABLE, p))
			return p+": a remix carries only files in place of its base's "
					"<module>/client_data/<path>, textures, models, sounds "
					"and worlds ("+ss_(REPLACEABLE).substr(1,
					strlen(REPLACEABLE) - 2)+")";
		if(!base_dir.empty() && !base_files.count(p.substr(0, slash)+"/"+
				p.substr(second + 1)))
			return p+": its base has no such file to replace";
		const ss_ why = asset_refusal(dir+"/"+p, ext);
		if(!why.empty())
			return p+": "+why;
	}
	if(base_dir.empty())
		return "";
	set_<ss_> names;
	for(const auto &f : base_files)
		names.insert(f.first);
	const json::Value &v = m.get("setting_values");
	for(json::Iterator it(v); v.is_object() && it.valid(); it.next()){
		const json::Value *field = nullptr;
		for(unsigned i = 0; i < schema.size(); i++)
			if(json::jstr(schema.at(i), "name") == it.key())
				field = &schema.at(i);
		if(!field)
			return "\"setting_values\": "+it.key()+" is not a setting of "+
					json::jstr(m, "base");
		const ss_ why = check_setting_value(*field, it.value(), &names);
		if(!why.empty())
			return "\"setting_values\": "+it.key()+": "+why;
	}
	return "";
}

json::Value app_settings(const ss_ &app_dir, const ss_ &share_path,
		const ss_ &user_path)
{
	json::json_error_t e;
	const json::Value m = json::load_file((app_dir+"/meta.json").c_str(), &e);
	json::Value schema = m.get("settings");
	if(schema.is_undefined()){
		ss_ why;
		const ss_ base = find_base(m, app_dir, share_path, user_path, &why);
		if(!base.empty())
			schema = json::load_file((base+"/meta.json").c_str(), &e).get(
					"settings");
	}
	json::Value out = json::object();
	if(!check_settings_schema(schema).empty())
		return out;
	const json::Value &values = m.get("setting_values");
	for(unsigned i = 0; i < schema.size(); i++){
		const json::Value &f = schema.at(i);
		const json::Value &v = values.is_object() ?
				values.get(json::jstr(f, "name")) : json::Value();
		out.set(json::jstr(f, "name"), !v.is_undefined() &&
				check_setting_value(f, v, nullptr).empty() ? v :
				f.get("default"));
	}
	return out;
}

json::Value app_settings(interface::Server *server)
{
	return app_settings(server->get_modules_path(),
			server->get_config().get<ss_>("share_path"),
			server->get_config().get<ss_>("user_path"));
}

// A zip of every file under dir, deflated, '/' separated; names that start
// with '.' are left out (.git and the like)
static void collect(const ss_ &dir, const ss_ &prefix, sv_<ss_> &out)
{
	for(const fs::Node &n : fs::list_directory(dir)){
		if(n.name.empty() || n.name[0] == '.')
			continue;
		if(n.is_directory)
			collect(dir+"/"+n.name, prefix+n.name+"/", out);
		else
			out.push_back(prefix+n.name);
	}
}

static void le(ss_ &o, uint32_t v, int bytes)
{
	for(int i = 0; i < bytes; i++)
		o += (char)((v >> (8 * i)) & 0xff);
}

sv_<ss_> package_files(const ss_ &dir)
{
	sv_<ss_> names, out;
	collect(dir, "", names);
	// [AITTA_PACKAGE_PAGE] The package's page on Aitta is not in a release
	for(const ss_ &n : names)
		if(n.compare(0, 11, "aitta_page/") != 0)
			out.push_back(n);
	return out;
}

// The files' names and data in a zip
static ss_ zip_entries(const sv_<std::pair<ss_, ss_>> &files)
{
	ss_ out, central;
	for(const auto &f : files){
		const ss_ &name = f.first, &data = f.second;
		std::ostringstream os(std::ios::binary);
		compress_deflate_raw(data, os);
		const ss_ packed = os.str();
		const uint32_t crc = crc32(0, (const Bytef*)data.data(), data.size());
		const uint32_t offset = out.size();
		// simplified: no zip64, so 4 GB at most; an app is nowhere near
		if(out.size() + packed.size() > 0xffffffffu)
			throw Exception("the archive would pass 4 GB");
		ss_ common;
		le(common, 20, 2); le(common, 0, 2); le(common, 8, 2); // deflate
		le(common, 0, 2); le(common, 0x21, 2); // a fixed time and date
		le(common, crc, 4); le(common, packed.size(), 4);
		le(common, data.size(), 4); le(common, name.size(), 2);
		le(common, 0, 2);
		out += "PK\x03\x04"+common+name+packed;
		central += ss_("PK\x01\x02")+'\x14'+'\x00'+common;
		le(central, 0, 2); le(central, 0, 2); le(central, 0, 2);
		le(central, 0, 4); le(central, offset, 4);
		central += name;
	}
	const uint32_t at = out.size();
	out += central;
	out += "PK\x05\x06";
	le(out, 0, 4); le(out, files.size(), 2); le(out, files.size(), 2);
	le(out, central.size(), 4); le(out, at, 4); le(out, 0, 2);
	return out;
}

static ss_ zip_directory(const ss_ &dir,
		const sv_<std::pair<ss_, ss_>> &built)
{
	sv_<std::pair<ss_, ss_>> files;
	for(const ss_ &name : package_files(dir))
		if(std::none_of(built.begin(), built.end(),
				[&](const std::pair<ss_, ss_> &b){ return b.first == name; }))
			files.emplace_back(name, read_file(dir+"/"+name));
	for(const auto &b : built)
		files.emplace_back(b.first, read_file(b.second));
	return zip_entries(files);
}

// <base>.zip and its <base>.sig: the hash, the key and its signature in
// the format given; the .zip's path
static ss_ write_signed(const ss_ &zip, const ss_ &key, const char *format,
		const ss_ &base)
{
	json::Value sig = json::object();
	sig.set("format", format);
	sig.set("sha256", sha256::hex(sha256::calculate(zip)));
	sig.set("key", public_of(key));
	sig.set("signature", sign(key, zip, format));
	fs::create_directories(fs::strip_file_name(base));
	write_file(base+".zip", zip);
	write_file(base+".sig", sig.stringify()+"\n");
	return base+".zip";
}

ss_ pack(const ss_ &app_dir, const ss_ &key_path, const ss_ &out_dir,
		const sv_<std::pair<ss_, ss_>> &built)
{
	json::json_error_t e;
	const json::Value m = json::load_file((app_dir+"/meta.json").c_str(), &e);
	const ss_ why = check_manifest(m);
	if(!why.empty())
		throw Exception(app_dir+"/meta.json: "+why);
	const json::Value &changelog = m.get("changelog");
	if(changelog.is_string() && !changelog.as_string().empty() &&
			!fs::path_exists(app_dir+"/"+changelog.as_string()))
		throw Exception(app_dir+"/meta.json: \"changelog\": "+
				changelog.as_string()+" is not there");
	if(kind_of(m) == "extension" && !fs::path_exists(app_dir+"/init.lua"))
		throw Exception(app_dir+": an extension has init.lua at its root");
	if(kind_of(m) == "world" && !fs::path_exists(app_dir+"/world/save.sqlite"))
		throw Exception(app_dir+": a world has its save in world/, "
				"save.sqlite at its root");
	const ss_ media = check_media(m, app_dir);
	if(!media.empty())
		throw Exception(app_dir+"/meta.json: "+media);
	// [APP_REMIX] What a remix carries, as an Aitta checks it (the
	// client checks it against the base too)
	if(kind_of(m) == "remix"){
		const ss_ why = remix_refusal(app_dir, m, "");
		if(!why.empty())
			throw Exception(app_dir+": "+why);
	}
	return write_signed(zip_directory(app_dir, built), read_file(key_path),
			SIG_FORMAT, out_dir+"/"+m.get("author").as_string()+"-"+
			m.get("name").as_string()+"-"+m.get("version").as_string());
}

// [AITTA_PACKAGE_PAGE]
static size_t utf8_chars(const ss_ &s)
{
	size_t n = 0;
	for(unsigned char c : s)
		if((c & 0xc0) != 0x80)
			n++;
	return n;
}

ss_ check_page(const json::Value &p, const sm_<ss_, ss_> &files)
{
	if(!p.is_object())
		return "page.json is not an object";
	const ss_ pkg = p.get("package").is_string() ?
			p.get("package").as_string() : "";
	const size_t slash = pkg.find('/');
	if(slash == ss_::npos || !plain_name(pkg.substr(0, slash), false) ||
			!plain_name(pkg.substr(slash + 1), false))
		return "\"package\": <author>/<name>";
	if(!p.get("time_ms").is_number())
		return "\"time_ms\": a number";
	const json::Value &d = p.get("description");
	if(!d.is_string() || utf8_chars(d.as_string()) > 20000)
		return "the description: text, 20000 characters at most";
	const json::Value &shots = p.get("screenshots");
	if(!shots.is_array() || shots.size() > 8)
		return "the screenshots: 8 at most";
	for(unsigned i = 0; i < shots.size(); i++){
		const ss_ n = shots.at(i).is_string() ? shots.at(i).as_string() : "";
		auto it = files.find(n);
		if(n.find('/') != ss_::npos || !archive_path_ok(n) ||
				it == files.end())
			return "the screenshot \""+n+"\" is not there";
		const ss_ why = media_check("screenshot", it->second);
		if(!why.empty())
			return n+": "+why.substr(why.find(": ") + 2);
	}
	return "";
}

ss_ pack_page(const ss_ &page_dir, const ss_ &package, const ss_ &key_path,
		const ss_ &out_dir)
{
	json::Value p = json::object();
	p.set("package", package);
	p.set("time_ms", os::wall_us() / 1000);
	p.set("description", "");
	sv_<ss_> shots;
	sm_<ss_, ss_> files;
	for(const fs::Node &n : fs::list_directory(page_dir)){
		if(n.name.empty() || n.name[0] == '.')
			continue;
		ss_ low = n.name;
		for(char &c : low)
			c = tolower((unsigned char)c);
		auto ends = [&](const char *e){
			const size_t k = strlen(e);
			return low.size() > k && low.compare(low.size() - k, k, e) == 0;
		};
		if(!n.is_directory && n.name == "description.txt")
			p.set("description", read_file(page_dir+"/"+n.name));
		else if(!n.is_directory && (ends(".png") || ends(".jpg") ||
				ends(".jpeg"))){
			shots.push_back(n.name);
			files[n.name] = read_file(page_dir+"/"+n.name);
		} else
			throw Exception(page_dir+"/"+n.name+": a page's directory holds "
					"description.txt and PNG or JPEG screenshots only");
	}
	std::sort(shots.begin(), shots.end());
	json::Value sl = json::array();
	for(const ss_ &n : shots)
		sl.append(json::Value(n));
	p.set("screenshots", sl);
	const ss_ why = check_page(p, files);
	if(!why.empty())
		throw Exception(page_dir+": "+why);
	sv_<std::pair<ss_, ss_>> entries;
	entries.emplace_back("page.json", p.stringify()+"\n");
	for(const ss_ &n : shots)
		entries.emplace_back(n, files[n]);
	ss_ base = package;
	base[base.find('/')] = '-';
	return write_signed(zip_entries(entries), read_file(key_path),
			PAGE_FORMAT, out_dir+"/"+base+"-page");
}

// A release's .sig read and checked against its archive: the .sig, or
// throws why not
static json::Value verified_sig(const ss_ &zip_path, const ss_ &sig_path)
{
	const ss_ zip = read_file(zip_path);
	json::json_error_t e;
	const json::Value sig = json::load_file(sig_path.c_str(), &e);
	auto sstr = [&](const char *k) -> ss_ {
		const json::Value &v = sig.get(k);
		return v.is_string() ? v.as_string() : "";
	};
	if(sstr("format") != SIG_FORMAT)
		throw Exception("not a release's .sig ("+ss_(SIG_FORMAT)+")");
	if(sstr("sha256") != sha256::hex(sha256::calculate(zip)))
		throw Exception("the archive is not the one the .sig is for");
	if(!verify(sstr("key"), zip, sstr("signature")))
		throw Exception("the signature does not match the archive");
	return sig;
}

ss_ install(const ss_ &zip_path, const ss_ &sig_path, const ss_ &user_path,
		bool review, const ss_ &share_path)
{
	const json::Value sig = verified_sig(zip_path, sig_path);
	json::json_error_t e;
	auto sstr = [&](const char *k) -> ss_ {
		const json::Value &v = sig.get(k);
		return v.is_string() ? v.as_string() : "";
	};

	// Unpacked beside where it goes, and moved into place once its
	// manifest has been read: nothing half there under its own name
	const ss_ installed = user_path+(review ? "/review" : "/installed");
	const ss_ incoming = installed+"/.incoming-"+
			sha256::hex(bignum::random_bytes(8));
	fs::create_directories(incoming);
	try {
		zip_extract(zip_path, incoming);
		const json::Value m = json::load_file((incoming+"/meta.json").c_str(), &e);
		const ss_ why = check_manifest(m);
		if(!why.empty())
			throw Exception("meta.json: "+why);
		if(!share_path.empty()){
			ss_ why;
			find_base(m, incoming, share_path, user_path, &why);
			if(!why.empty())
				throw Exception(why+"; install it first");
		}
		const ss_ kind = kind_of(m);
		if(kind == "world")
			throw Exception("a world is installed as a new save of its app, "
					"from the client's Apps from Aitta");
		// [APP_REMIX] A stranger's settings and files over an app that is
		// here: data only, each checked against the base
		if(kind == "remix"){
			ss_ why;
			const ss_ base = find_base(m, incoming, share_path, user_path,
					&why);
			if(base.empty())
				throw Exception(why+"; install it first");
			why = remix_refusal(incoming, m, base);
			if(!why.empty())
				throw Exception("a remix: "+why);
		}
		if(review){
			// [AITTA_REVIEW] A playtest: apart from the installed ones,
			// no key kept, and a second one of a version replaces the first.
			// simplified: apps only; an extension is reviewed by its files
			if(kind != "app" && kind != "remix")
				throw Exception("only an app is playtested; an extension "
						"is reviewed by its files");
			const ss_ app = installed+"/"+m.get("author").as_string()+"__"+
					m.get("name").as_string();
			const ss_ dir = app+"/"+m.get("version").as_string();
			fs::remove_all(dir);
			fs::create_directories(app);
			if(!fs::rename(incoming, dir))
				throw Exception("cannot move it into "+dir);
			write_file(dir+"/.aitta_sha256", sstr("sha256")+"\n");
			return dir;
		}
		const ss_ app = installed+"/"+m.get("author").as_string()+"/"+
				m.get("name").as_string();
		const ss_ dir = app+"/"+m.get("version").as_string();
		if(fs::path_exists(dir))
			throw Exception("already installed: "+dir);
		if(kind == "extension" && !fs::path_exists(incoming+"/init.lua"))
			throw Exception("an extension with no init.lua at its root");
		// An author/name stays the kind it was first installed as
		for(const auto &n : fs::list_directory(app)){
			const ss_ was = n.is_directory ? kind_of(json::load_file(
					(app+"/"+n.name+"/meta.json").c_str(), &e)) : kind;
			if(was != kind)
				throw Exception(m.get("author").as_string()+"/"+
						m.get("name").as_string()+" is installed as "+
						(was == "remix" ? "a " : "an ")+was);
		}
		// The first install's key is the app's: a later version signed by
		// another is someone else's (trust on first install)
		fs::create_directories(app);
		const ss_ key_file = app+"/key";
		if(fs::path_exists(key_file)){
			ss_ known = read_file(key_file);
			while(!known.empty() && (known.back() == '\n' || known.back() == '\r'))
				known.pop_back();
			if(known != sstr("key"))
				throw Exception("signed by another key than the installed "
						"versions of "+m.get("author").as_string()+"/"+
						m.get("name").as_string());
		} else {
			write_file(key_file, sstr("key")+"\n");
		}
		if(!fs::rename(incoming, dir))
			throw Exception("cannot move it into "+dir);
		// Inside, where the app's boxed server can read it to pin a save
		write_file(dir+"/.aitta_sha256", sstr("sha256")+"\n");
		// simplified: an extension has no saves to pin, so the new version
		// replaces the others and the client loads the one there is; a
		// version to go back to is installed again from its release
		if(kind == "extension")
			for(const auto &n : fs::list_directory(app))
				if(n.is_directory && app+"/"+n.name != dir)
					fs::remove_all(app+"/"+n.name);
		return dir;
	} catch(...){
		fs::remove_all(incoming);
		throw;
	}
}

// [WORLD_PACKAGES]
ss_ install_world(const ss_ &zip_path, const ss_ &sig_path,
		const ss_ &user_path, const ss_ &share_path, const ss_ &app,
		const sv_<ss_> &code)
{
	const json::Value sig = verified_sig(zip_path, sig_path);
	// What it says before anything is written: no more files than a save
	// has, nor more than they say they come to
	const sv_<ZipEntry> entries = zip_list(zip_path);
	if(entries.size() > WORLD_FILES_MAX)
		throw Exception(itos((int64_t)entries.size())+" files; a world has "+
				itos(WORLD_FILES_MAX)+" at most");
	const ss_ saves = user_path+"/apps/"+app+"/saves";
	// Beside where it goes, so the save is a rename; a name starting with
	// '.' is no save's
	const ss_ incoming = saves+"/.incoming-"+
			sha256::hex(bignum::random_bytes(8));
	fs::create_directories(incoming);
	try {
		zip_extract(zip_path, incoming, WORLD_UNPACKED_MAX);
		json::json_error_t e;
		const json::Value m = json::load_file((incoming+"/meta.json").c_str(),
				&e);
		const ss_ why = check_manifest(m);
		if(!why.empty())
			throw Exception("meta.json: "+why);
		auto str = [&](const char *k) -> ss_ {
			const json::Value &v = m.get(k);
			return v.is_string() ? v.as_string() : "";
		};
		if(kind_of(m) != "world")
			throw Exception("not a world: an app or an extension is installed "
					"as one");
		if(str("app") != app)
			throw Exception("a world of "+str("app")+", not of "+app);
		// The app it is a save of, here: one that comes with Buildat, or an
		// installed package -- of the version that made it, which another
		// version does not open (storage's pin)
		const size_t dot = app.find('.');
		if(dot == ss_::npos){
			if(!fs::path_exists(share_path+"/apps/"+app))
				throw Exception("its app "+app+" is not here");
		} else {
			const ss_ dir = user_path+"/installed/"+app.substr(0, dot)+"/"+
					app.substr(dot + 1);
			const ss_ v = str("app_version");
			if(!v.empty() && !fs::path_exists(dir+"/"+v+"/meta.json"))
				throw Exception("it was made with "+app+" "+v+": install that "
						"version first");
			if(v.empty() && !fs::path_exists(dir))
				throw Exception("its app "+app+" is not installed: install it "
						"first");
		}
		const ss_ world = incoming+"/world";
		if(!fs::path_exists(world+"/save.sqlite"))
			throw Exception("no world/save.sqlite in it: not a save");
		// A world is data: what its app runs as code is refused, as a
		// stranger's code is not run for having come in a save
		for(const ss_ &c : code)
			if(fs::path_exists(world+"/"+c))
				throw Exception("it carries "+c+", which "+app+" runs as "
						"code; a world package is a save's data only");
		// Its own name, or the next free one; never one storage refuses
		// (Windows' devices, "trash") or the player's list leaves out (_)
		ss_ base = str("name");
		ss_ stem = base;
		for(char &c : stem)
			c = toupper((unsigned char)c);
		if(base[0] == '_' || base == "trash" || stem == "CON" ||
				stem == "PRN" || stem == "AUX" || stem == "NUL" ||
				(stem.size() == 4 && (stem.compare(0, 3, "COM") == 0 ||
				stem.compare(0, 3, "LPT") == 0)))
			base = "world_"+base;
		ss_ name = base;
		for(int i = 2; fs::path_exists(saves+"/"+name); i++){
			if(i > 99)
				throw Exception("no free name for the save "+base);
			name = base+"_"+itos(i);
		}
		if(!fs::rename(world, saves+"/"+name))
			throw Exception("cannot move it into "+saves+"/"+name);
		// For the app's first open of it: a stranger's save
		// (doc/aitta.txt). Written here, after the archive's files, so
		// no archive decides it
		write_file(saves+"/"+name+"/.world_package", str("author")+"/"+
				str("name")+"/"+str("version")+"\n");
		fs::remove_all(incoming);
		return name;
	} catch(...){
		fs::remove_all(incoming);
		throw;
	}
}

}
}
// vim: set noet ts=4 sw=4:
