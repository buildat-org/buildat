// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "interface/address.h"
#include "interface/aitta.h"
#include "interface/bignum.h"
#include "interface/compress.h"
#include "interface/fs.h"
#include "interface/os.h"
#include "interface/sha256.h"
#include "interface/zip.h"
#include "core/log.h"
#include "zlib.h"
#include <mbedtls/ecdsa.h>
#include <mbedtls/ecp.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <fstream>
#include <sstream>

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
		"client_main", "disable_cpp", "dependencies", "reverse_dependencies",
		"cxxflags", "ldflags", "cxxflags_windows", "ldflags_windows",
		"cxxflags_linux", "ldflags_linux"};
	for(json::Iterator it(v); it.valid(); it.next()){
		const ss_ key = it.key();
		bool ok = false;
		for(const char *k : known)
			ok = ok || key == k;
		if(!ok)
			return "meta.json: \""+key.substr(0, 40)+"\" is not a key this "
					"Buildat knows";
	}
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
	if(!known("kind", {"app", "extension"}))
		return "\"kind\": \"app\" or \"extension\"";
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
	const bool icon = which == "icon";
	const size_t max_bytes = icon ? 64 * 1024 : 2 * 1000 * 1000;
	const uint32_t max_side = icon ? 256 : 1920;
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
				return "screenshot: not a JPEG the client can read";
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
					return "screenshot: a JPEG of 8 bits a sample only";
				h = be(at + 5, 2);
				w = be(at + 7, 2);
				t = "image/jpeg";
				break;
			}
			if((m >= 0xc3 && m <= 0xcf && m != 0xc4 && m != 0xc8 &&
					m != 0xcc) || m == 0xda || m == 0xd9)
				return "screenshot: a baseline or progressive JPEG only "
						"(no lossless, no arithmetic coding)";
			if(len < 2)
				break;
			at += 2 + len;
		}
		if(t.empty())
			return "screenshot: not a JPEG the client can read";
	} else {
		return icon ? "icon: not a PNG" : "screenshot: not a PNG or a JPEG";
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

ss_ kind_of(const json::Value &m)
{
	const json::Value &k = m.get("kind");
	return k.is_string() && k.as_string() == "extension" ? "extension" : "app";
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

static ss_ zip_directory(const ss_ &dir)
{
	sv_<std::pair<ss_, ss_>> files;
	for(const ss_ &name : package_files(dir))
		files.emplace_back(name, read_file(dir+"/"+name));
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

ss_ pack(const ss_ &app_dir, const ss_ &key_path, const ss_ &out_dir)
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
	const ss_ media = check_media(m, app_dir);
	if(!media.empty())
		throw Exception(app_dir+"/meta.json: "+media);
	return write_signed(zip_directory(app_dir), read_file(key_path),
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

ss_ install(const ss_ &zip_path, const ss_ &sig_path, const ss_ &user_path,
		bool review)
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
		const ss_ kind = kind_of(m);
		if(review){
			// [AITTA_REVIEW] A playtest: apart from the installed ones,
			// no key kept, and a second one of a version replaces the first.
			// simplified: apps only; an extension is reviewed by its files
			if(kind != "app")
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
		for(const auto &n : fs::list_directory(app))
			if(n.is_directory && kind_of(json::load_file(
					(app+"/"+n.name+"/meta.json").c_str(), &e)) != kind)
				throw Exception(m.get("author").as_string()+"/"+
						m.get("name").as_string()+" is installed as an"+
						(kind == "app" ? " extension" : " app"));
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

}
}
// vim: set noet ts=4 sw=4:
