// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// **Starport** ([STARPORT], doc/plan/starport_plan.md): a directory of public
// servers of buildat apps, as an app. Servers announce to it
// (builtin/starport_announce); clients list from it and report listings
// (client/core/starport); moderators, operators and the admin use it by
// joining it (client_lua/init.lua).
//
// The HTTP API, under /api/v1/ on the server's port (network:http_request),
// JSON in and out, a refusal an {"ok": false, "code": ..., "error": ...}
// with status 200:
//   POST /api/v1/announce       a server's announce ([STARPORT] 2)
//   GET|POST /api/v1/list       the listings this instance serves ([STARPORT] 4)
//   POST /api/v1/report         a report ([STARPORT] 5)
//   POST /api/v1/report_status  a reporter's receipts' outcomes
//   GET /api/v1/transparency    the numbers ([STARPORT] 6)
//   GET /api/v1/icon/<sha256>   a listing's icon, a PNG ([SERVER_ICONS])
//   POST /api/v1/id/<call>      a Starport ID's calls ([STARPORT] 10)
//   GET /authorize, GET /id  the pages a web client signs in by and an
//                            ID's settings are on ([WEB_ID_TRUST]);
//                            /authorize?site=<id> a website's sign-in
//                            ([STARPORT_SITE_LOGIN])
//   GET /brand/<file>        the pages' font and logo ([HTML_BRAND])
//   GET /                    the listed servers and the numbers as a page,
//                            ?kind=, ?audience= ([FRONT_PAGES]), only
//                            what suits a teen, claimed an hour, with no
//                            open report;
//                            the web client is at /app ([PLAY_PATH])
// The API answers any origin (CORS *): it takes no cookies.
// In the app, "sp:req" carries a JSON {id, cmd, ...} from a joined client
// and "sp:res" the answer {id, ok, result | error}.
//
// Everything is in the save "starport", a store a kind of record, each
// record JSON: listings, keys, reports, groups, audit, operators, appeals,
// settings, bans.
#include "core/log.h"
#include "core/json.h"
#include "core/version.h"
#include "interface/os.h"
#include "interface/aitta.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/http.h"
#include "interface/sha256.h"
#include "interface/fs.h"
#include "interface/process.h"
#include "interface/bignum.h"
#include "interface/web_brand.h"
#include "client_file/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "accounts/api.h"
#include "moderation/api.h"
#include <algorithm>
#include <cmath>
#include <ctime>
#include <deque>
#include <fstream>
#include <sstream>
#include <memory>
#include <mutex>
#include <thread>
#include <chrono>
#include <set>
#include <condition_variable>

using json::jstr;
using json::jint;
using interface::sha256::unhex;
using interface::sha256::is_hex;

#define MODULE "main"

using interface::Event;

namespace starport {

// ---------------------------------------------------------------------------
// Helpers

// [SIM_CLOCK]: the calendar, which a check may move
static int64_t now_s(){ return interface::os::wall_us() / 1000000; }
static int64_t day_of(int64_t t){ return t / 86400; }

static ss_ hex(const ss_ &raw){ return interface::sha256::hex(raw); }
static ss_ random_hex(size_t bytes){
	return hex(interface::bignum::random_bytes(bytes));
}
// The same, without telling how much of it was
static bool same(const ss_ &a, const ss_ &b)
{
	if(a.size() != b.size())
		return false;
	unsigned char d = 0;
	for(size_t i = 0; i < a.size(); i++)
		d |= (unsigned char)(a[i] ^ b[i]);
	return d == 0;
}

static const json::Value& jget(const json::Value &v, const char *k)
{
	return v.get(k);
}
static double jnum(const json::Value &v, const char *k, double def = 0)
{
	const json::Value &x = v.get(k);
	return x.is_number() ? x.as_number() : def;
}
static bool in_set(const ss_ &s, std::initializer_list<const char*> set)
{
	for(const char *x : set)
		if(s == x)
			return true;
	return false;
}

// ---------------------------------------------------------------------------
// The categories ([STARPORT] 3)

static const std::initializer_list<const char*> KINDS =
		{"world", "arena", "app", "other"};
// [PLAY_PATH] the web client's path for a listing: a game's word or an
// app's
static ss_ play_path(const ss_ &kind)
{
	return kind == "world" || kind == "arena" ? "/play" : "/app";
}
static const std::initializer_list<const char*> AUDIENCES =
		{"everyone", "teen", "adult"};
static const std::initializer_list<const char*> ACCESSES =
		{"open", "invite", "starport", "password", "external"};
static const std::initializer_list<const char*> REASONS = {"category",
		"illegal", "csam", "harassment", "scam", "malware", "impersonation",
		"spam", "other"};
// Each descriptor and the values it takes; a bool one is "yes"/"no"
static const sm_<ss_, sv_<ss_>> DESCRIPTORS = {
	{"violence", {"none", "cartoon", "realistic"}},
	{"chat", {"none", "moderated", "unmoderated"}},
	{"ugc", {"none", "moderated", "unmoderated"}},
	{"language", {"no", "yes"}},
	{"sexual", {"no", "yes"}},
	{"drugs", {"no", "yes"}},
	{"purchases", {"no", "yes"}},
	{"gambling", {"no", "yes"}},
	{"personal_data", {"no", "yes"}},
};
// How much a reason weighs in the queue's order
static int reason_severity(const ss_ &reason)
{
	static const sm_<ss_, int> s = {{"csam", 100}, {"malware", 60},
		{"illegal", 50}, {"scam", 40}, {"harassment", 30},
		{"impersonation", 25}, {"category", 20}, {"spam", 15}, {"other", 10}};
	auto it = s.find(reason);
	return it == s.end() ? 10 : it->second;
}

// A category's value: one a newer Buildat added is taken as a word and
// listed as "other" (normalized in api_announce)
static bool word_ok(const ss_ &v)
{
	return !v.empty() && v.size() <= 24 && v.find_first_not_of(
			"abcdefghijklmnopqrstuvwxyz0123456789_-") == ss_::npos;
}

// The announce's keys this reads; the rest, a newer Buildat's, are kept as
// the listing's "extra" and passed on in the list
static const std::initializer_list<const char*> ANNOUNCE_KEYS = {"name",
		"description", "kind", "audience", "access", "login", "signup_url",
		"descriptors", "tags", "languages", "region", "address", "unlisted",
		"port", "icon", "tls", "app", "version", "package", "game", "players",
		"players_max", "updating", "bans", "id", "secret", "fleet", "pool"};

// "" when the announce's categories are whole and right, else why not
static ss_ check_categories(const json::Value &b)
{
	// [STARPORT_DEFAULT_URL]: an unlisted announce may leave out its name,
	// kind, audience and descriptors (none of it is in the list; the name
	// falls back to the host). Rating its audience for the admin would be
	// a claim made in their name. Listing it asks for them.
	const bool unlisted = b.get("unlisted").is_true();
	auto missing = [&](const ss_ &v){
		return unlisted && (v.empty() || v == "?");
	};
	const ss_ name = jstr(b, "name");
	if(!missing(name) && (name.empty() || name.size() > 60))
		return "name: 1 to 60 characters";
	if(jstr(b, "description").size() > 500)
		return "description: at most 500 characters";
	if(!missing(jstr(b, "kind")) && !word_ok(jstr(b, "kind")))
		return "kind: world, arena, app or other";
	if(!missing(jstr(b, "audience")) && !word_ok(jstr(b, "audience")))
		return "audience: everyone, teen or adult";
	// An access or login this does not know is kept: a client that does
	// not know it either leaves the listing out
	if(!word_ok(jstr(b, "access")))
		return "access: open, invite, starport, password or external";
	// How people log in: its own accounts, Starport IDs, or both (10c)
	if(!word_ok(jstr(b, "login", "local")))
		return "login: local, starport or both";
	// An account made somewhere else first: where ([STARPORT] 3)
	const ss_ signup = jstr(b, "signup_url");
	if(jstr(b, "access") == "external" && (signup.size() > 200 ||
			(signup.compare(0, 8, "https://") != 0 &&
			signup.compare(0, 7, "http://") != 0) ||
			signup.find_first_of(" \"<>\r\n") != ss_::npos))
		return "signup_url: the http(s) address an account is made at, "
				"for access external";
	const json::Value &d = b.get("descriptors");
	if(!d.is_object() && !(unlisted && d.is_undefined()))
		return "descriptors: an object";
	for(const auto &pair : DESCRIPTORS){
		if(!d.is_object())
			break;
		const ss_ v = jstr(d, pair.first.c_str());
		// One a server's version does not know yet is "unknown" ([STARPORT]
		// 3: categories are versioned)
		if(d.get(pair.first).is_undefined() || missing(v))
			continue;
		if(!word_ok(v))
			return "descriptors."+pair.first+": one of "+dump(pair.second);
	}
	const json::Value &tags = b.get("tags");
	if(!tags.is_undefined()){
		if(!tags.is_array() || tags.size() > 8)
			return "tags: at most 8";
		for(unsigned i = 0; i < tags.size(); i++){
			const json::Value &t = tags.at(i);
			if(!t.is_string() || t.as_string().empty() ||
					t.as_string().size() > 24 || t.as_string().find_first_not_of(
					"abcdefghijklmnopqrstuvwxyz0123456789_-") != ss_::npos)
				return "tags: a-z, 0-9, _ and -, at most 24 characters";
		}
	}
	const json::Value &langs = b.get("languages");
	if(!langs.is_undefined()){
		if(!langs.is_array() || langs.size() > 8)
			return "languages: at most 8";
		for(unsigned i = 0; i < langs.size(); i++)
			if(!langs.at(i).is_string() || langs.at(i).as_string().size() > 8)
				return "languages: codes such as \"en\" or \"fi\"";
	}
	if(jstr(b, "region").size() > 32)
		return "region: at most 32 characters";
	const ss_ addr = jstr(b, "address");
	if(addr.size() > 253 || addr.find_first_of(" /?#@\\") != ss_::npos)
		return "address: a host name or an address";
	return "";
}

// ---------------------------------------------------------------------------
#include "id_page.h"

// ---------------------------------------------------------------------------
// The instance's settings, with their defaults ([STARPORT] 5a, 7, 8)

static json::Value default_settings()
{
	json::Value s = json::object();
	s.set("name", "Starport");
	// What this instance serves, whatever a client asks ([STARPORT] 4)
	json::Value filter = json::object();
	filter.set("exclude_audience", json::array());
	filter.set("exclude_kind", json::array());
	filter.set("exclude_descriptors", json::array());
	s.set("filter", filter);
	// A key's standing ([STARPORT] 5a)
	s.set("lambda", 0.937);
	s.set("f_full", 0.139);
	s.set("b", 0.3);
	s.set("tau_days", 14.2);
	s.set("w_min", 0.01);
	// Reports' thresholds, per reason ([STARPORT] 7)
	json::Value th = json::object();
	json::Value d = json::object();
	d.set("hide", 3.0);
	d.set("delist", 8.0);
	th.set("default", d);
	for(const char *r : {"csam", "malware"}){
		json::Value x = json::object();
		x.set("hide", 1.0);
		x.set("delist", 2.0);
		th.set(r, x);
	}
	s.set("thresholds", th);
	// How long an address is kept ([STARPORT] 8)
	s.set("retention_days", (int64_t)7);
	// A line at the top of everyone's Overview ([STARPORT_UI]); "high"
	// draws it in the highlight colour, an empty text not at all
	json::Value notice = json::object();
	notice.set("text", "");
	notice.set("priority", "low");
	s.set("notice", notice);
	// Whether an operator's e-mail address is confirmed by a code mailed
	// to it ([STARPORT] 2a); off for a test instance, the address then
	// taken as given
	s.set("email_confirmation", true);
	// [FRONT_PAGES]: seconds a listing is claimed before the page at /
	// shows it, so reports reach it first
	s.set("page_delay", (int64_t)3600);
	// Whether players can make Starport IDs here (10)
	s.set("id_registration", true);
	// [WEB_ID_TRUST]: web pages besides a listed server's own that
	// /authorize sends a token to, as origins ("https://play.example.org")
	s.set("web_clients", json::array());
	// Whose reports go first ([STARPORT] 6)
	s.set("trusted_flaggers", json::array());
	// [STARPORT_RECOMMENDS]: the Hearth a client's "Discuss" joins, and
	// the Aittas a client is offered, as addresses
	s.set("recommended_hearth", "");
	s.set("recommended_aittas", json::array());
	// [PLAY_LINKS]: the play page ("https://play.example.org"; "" for
	// none) the page at / links each TLS server to, which /api/v1/list hands
	// clients and an announce's answer hands each listed server, so that
	// it lets the page's WebSocket in; it is one of web_clients too
	s.set("play_url", "");
	return s;
}

// A listing's categories as served: the announce's, with what a moderator
// set over it
static json::Value effective(const json::Value &l)
{
	json::Value out = json::object();
	for(const char *k : {"kind", "audience", "access"})
		out.set(k, l.get(k));
	out.set("descriptors", l.get("descriptors").deepcopy());
	const json::Value &r = l.get("relabel");
	if(r.is_object()){
		for(json::Iterator it(r); it.valid(); it.next()){
			const ss_ k = it.key();
			if(k == "kind" || k == "audience" || k == "access")
				out.set(k, it.value());
			else if(DESCRIPTORS.count(k)){
				json::Value d = out.get("descriptors").deepcopy();
				d.set(k, it.value());
				out.set("descriptors", d);
			}
		}
	}
	return out;
}

// ---------------------------------------------------------------------------

// [VERSION_CHECK]: a link in the version adapter's answer, as the client
// gets it: https, short, nothing a line or a shell reads specially
static bool version_link(const json::Value &v)
{
	if(!v.is_string())
		return false;
	const ss_ u = v.as_string();
	if(u.compare(0, 8, "https://") != 0 || u.size() <= 8 || u.size() > 500)
		return false;
	for(char c : u)
		if((unsigned char)c <= ' ' || c == 127 || c == '\'' || c == '"' ||
				c == '\\')
			return false;
	return true;
}

// The adapter's answer as /api/v1/list carries it, or undefined and why:
// {version = "0.6.89", url, platforms = {linux = {url}, ...}}, no other
// keys; a platform that is not a short name or has no good url is left out
static json::Value version_answer(const json::Value &a, ss_ *why)
{
	const ss_ v = a.get("version").is_string() ? a.get("version").as_string() : "";
	// A pre-release too: the client offers it only to who asks
	if(!interface::aitta::semver_ok(v)){
		*why = "no \"version\" that is SemVer 2.0";
		return json::Value();
	}
	if(!version_link(a.get("url"))){
		*why = "no \"url\" starting https://";
		return json::Value();
	}
	json::Value out = json::object();
	out.set("version", v);
	out.set("url", a.get("url"));
	json::Value platforms = json::object();
	const json::Value &p = a.get("platforms");
	for(json::Iterator it(p); p.is_object() && it.valid(); it.next()){
		const ss_ k = it.key();
		bool name_ok = !k.empty() && k.size() <= 16;
		for(char c : k)
			name_ok = name_ok && (isalnum((unsigned char)c) || c == '_');
		if(name_ok && it.value().is_object() &&
				version_link(it.value().get("url"))){
			json::Value e = json::object();
			e.set("url", it.value().get("url"));
			platforms.set(k, e);
		}
	}
	out.set("platforms", platforms);
	return out;
}

struct VerifyJob {
	ss_ listing;
	ss_ url;      // http://host:port/api/v1/starport/challenge?...
	ss_ expect;   // the hex HMAC
};
struct VerifyResult {
	ss_ listing;
	bool ok = false;
	ss_ why;
};

struct Module: public interface::Module, public moderation::Host
{
	interface::Server *m_server;
	storage::Save *m_save = nullptr;
	json::Value m_settings;
	int64_t m_last_day = 0;
	int64_t m_next_reverify = 0;
	// Rate limits, in memory only: by key, a count and when it started
	// key -> count, window start, window length
	network::RateTable m_rates;

	// The verifier: a thread of its own, as it waits on other servers
	std::mutex m_vmutex;
	std::condition_variable m_vwake;
	std::deque<VerifyJob> m_vjobs;
	std::deque<VerifyResult> m_vresults;
	std::thread m_vthread;
	bool m_vstop = false;

	// Mail that failed to send, from mail()'s threads, which may outlive
	// the module: turned into the admins' events on a tick
	struct MailFailures { std::mutex m; sv_<ss_> lines; };
	std::shared_ptr<MailFailures> m_mail_failures =
			std::make_shared<MailFailures>();

	// [VERSION_CHECK]: the version adapter's last good answer (undefined
	// for none), and its run on a thread, which may outlive the module
	json::Value m_version;
	int64_t m_next_version_run = 0;
	struct VersionRun { std::mutex m; bool running = false, done = false;
			int status = 0; ss_ out; };
	std::shared_ptr<VersionRun> m_version_run =
			std::make_shared<VersionRun>();

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
	}

	~Module()
	{
		{
			std::lock_guard<std::mutex> lock(m_vmutex);
			m_vstop = true;
		}
		m_vwake.notify_all();
		if(m_vthread.joinable())
			m_vthread.join();
	}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("network:packet_received/sp:req"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("network:http_request", on_http, network::HttpRequest)
		EVENT_TYPEN("network:packet_received/sp:req", on_req, network::Packet)
	}

	// -----------------------------------------------------------------------
	// Storage

	storage::Store* store(const char *name){ return m_save->store(name); }

	// [DB_INDEXES]: the listings parsed once and kept, as /api/v1/list, the
	// front page and every announce read all of them. Written through put()
	// and listing_remove() only.
	std::map<ss_, json::Value> m_listings;
	bool m_listings_read = false;
	const std::map<ss_, json::Value>& listings()
	{
		if(!m_listings_read){
			for(const ss_ &id : store("listings")->list("")){
				ss_ text;
				if(store("listings")->get(id, text))
					m_listings[id] = json::load_string(text.c_str());
			}
			m_listings_read = true;
		}
		return m_listings;
	}
	sv_<ss_> listing_ids()
	{
		sv_<ss_> ids;
		for(auto &pair : listings())
			ids.push_back(pair.first);
		return ids;
	}
	void listing_remove(const ss_ &id)
	{
		store("listings")->remove(id);
		m_listings.erase(id);
	}

	json::Value load(const char *store_name, const ss_ &key)
	{
		if(ss_(store_name) == "listings"){
			auto it = listings().find(key);
			return it == m_listings.end() ? json::Value() : it->second;
		}
		ss_ text;
		if(!store(store_name)->get(key, text))
			return json::Value();
		return json::load_string(text.c_str());
	}
	void put(const char *store_name, const ss_ &key, const json::Value &v)
	{
		store(store_name)->set(key, v.stringify());
		if(ss_(store_name) == "listings" && m_listings_read)
			m_listings[key] = v;
	}

	const json::Value& setting(const char *k)
	{
		const json::Value &v = m_settings.get(k);
		if(!v.is_undefined())
			return v;
		static json::Value defaults = default_settings();
		return defaults.get(k);
	}
	double setting_num(const char *k){ return setting(k).as_number(); }

	// [STARPORT_RECOMMENDS], as /api/v1/list and an ID's "me" carry it
	json::Value recommends()
	{
		json::Value v = json::object();
		v.set("hearth", setting("recommended_hearth"));
		v.set("aittas", setting("recommended_aittas"));
		return v;
	}

	// [PLAY_LINKS] the play page, without a trailing /, and its origin
	ss_ play_url()
	{
		const json::Value &v = setting("play_url");
		ss_ u = v.is_string() ? v.as_string() : "";
		while(!u.empty() && u.back() == '/')
			u.pop_back();
		return u;
	}
	ss_ play_origin()
	{
		const ss_ u = play_url();
		const size_t s = u.find("://");
		return s == ss_::npos ? "" : u.substr(0, u.find('/', s + 3));
	}

	// [PLAY_OOTB] the defaults with the stored values over them: a setting
	// newer than this Starport's first start is on its Settings page too
	json::Value all_settings()
	{
		json::Value r = default_settings();
		for(json::Iterator it(m_settings); it.valid(); it.next())
			r.set(it.key(), it.value());
		return r;
	}

	void on_start()
	{
		// One user's clients at once, as in floorplanner
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_multiple_logins(true);
		});
		storage::access(m_server, [&](storage::Interface *s){
			m_save = s->open("starport");
			if(!m_save)
				m_save = s->create("starport");
		});
		if(!m_save)
			throw Exception("starport: cannot open or create the save");
		m_settings = load("settings", "settings");
		if(!m_settings.is_object()){
			m_settings = default_settings();
			put("settings", "settings", m_settings);
		}
		network::access(m_server, [&](network::Interface *iface){
			iface->claim_http_path("/authorize");
			iface->claim_http_path("/id");
			iface->claim_http_path("/brand/");
			iface->claim_http_path("/"); // [FRONT_PAGES]; the client is at /app
		});
		// m_last_day stays 0: the daily pass runs at the first tick too, so a
		// Starport down at midnight still clears what the retention ends
		m_vthread = std::thread([this](){ verifier(); });
		log_i(MODULE, "Starport \"%s\": %zu listings", cs(jstr(m_settings,
				"name")), listing_ids().size());
	}

	// -----------------------------------------------------------------------
	// The HTTP API

	void respond(const network::HttpRequest &r, int status, const json::Value &v)
	{
		network::access(m_server, [&](network::Interface *iface){
			// The API takes no cookies, a session is in the body: any page
			// may call it ([WEB_ID_TRUST], the web client's fetch)
			iface->http_respond(r.peer, status, "application/json",
					v.stringify(), "Access-Control-Allow-Origin: *\r\n");
		});
	}
	// code is for a program to match, error for a person to read
	void refuse(const network::HttpRequest &r, const ss_ &why,
			const ss_ &code = "refused")
	{
		json::Value v = json::object();
		v.set("ok", false);
		v.set("code", code);
		v.set("error", why);
		respond(r, 200, v);
	}

	void on_http(const network::HttpRequest &r)
	{
		if(!m_save)
			return;
		json::Value body;
		if(r.method == "POST"){
			json::json_error_t err;
			body = json::load_string(r.body.c_str(), &err);
			if(!body.is_object()){
				refuse(r, "the body is not a JSON object");
				return;
			}
		} else {
			body = json::object();
		}
		if(r.path == "/" && r.method == "GET")
			front_page(r);
		else if(r.path == "/api/v1/announce" && r.method == "POST")
			api_announce(r, body);
		else if(r.path == "/api/v1/delist" && r.method == "POST")
			api_delist(r, body);
		else if(r.path == "/api/v1/list")
			api_list(r, body);
		else if(r.path == "/api/v1/report" && r.method == "POST")
			api_report(r, body);
		else if(r.path == "/api/v1/report_status" && r.method == "POST")
			api_report_status(r, body);
		else if(r.path.compare(0, 11, "/api/v1/id/") == 0 && r.method == "POST")
			api_id(r, body);
		else if(r.path == "/api/v1/transparency")
			api_transparency(r);
		else if(r.path.compare(0, 13, "/api/v1/icon/") == 0 && r.method == "GET")
			api_icon(r, r.path.substr(13));
		else if((r.path == "/authorize" || r.path == "/id") &&
				r.method == "GET"){
			// Never in a frame: its Allow would be clicked through one
			network::access(m_server, [&](network::Interface *iface){
				iface->http_respond(r.peer, 200, "text/html; charset=utf-8",
						id_page(), "X-Frame-Options: DENY\r\n"
						"Content-Security-Policy: frame-ancestors 'none'\r\n");
			});
		}
		else if(r.method == "GET" && network::serve_brand(m_server, r))
			return;
		else if(r.path.compare(0, 17, "/api/v1/starport/") == 0)
			return; // builtin/starport_announce's, were this listed itself
		else {
			json::Value v = json::object();
			v.set("ok", false);
			v.set("error", "no such call");
			respond(r, 404, v);
		}
	}

	// A listing's icon by its hash ([SERVER_ICONS]), kept for a day
	void api_icon(const network::HttpRequest &r, const ss_ &sha)
	{
		ss_ hex;
		if(sha.size() != 64 || !store("icons")->get(sha, hex)){
			json::Value v = json::object();
			v.set("ok", false);
			v.set("error", "no such icon");
			respond(r, 404, v);
			return;
		}
		ss_ png;
		for(size_t i = 0; i + 1 < hex.size(); i += 2)
			png += (char)std::stoi(hex.substr(i, 2), nullptr, 16);
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, 200, "image/png", png,
					"Access-Control-Allow-Origin: *\r\n"
					"Cache-Control: max-age=86400\r\n");
		});
	}

	bool banned(const ss_ &kind, const ss_ &what)
	{
		if(what.empty())
			return false;
		json::Value b = load("bans", kind+":"+what);
		if(!b.is_object())
			return false;
		const int64_t until = jint(b, "until");
		return until == 0 || until > now_s();
	}

	// An account that exists (an ID, or an operator who joined and has
	// not used it as one), neither suspended nor banned
	bool good_standing(const ss_ &name)
	{
		if(name.empty() || banned("account", name))
			return false;
		bool exists = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			exists = a->exists(name);
		});
		return exists && jint(load("ids", name), "suspended_until") <= now_s();
	}

	// -- 2. Announce

	void api_announce(const network::HttpRequest &r, const json::Value &b)
	{
		if(banned("address", r.address)){
			refuse(r, "this address may not announce");
			return;
		}
		const ss_ why = check_categories(b);
		if(!why.empty()){
			refuse(r, why);
			return;
		}
		const int64_t port = jint(b, "port");
		if(port < 1 || port > 65535){
			refuse(r, "port: 1 to 65535");
			return;
		}
		// [SERVER_ICONS] The server's icon, in hex: a PNG of 64 pixels a
		// side or less, kept by its hash and served at /api/v1/icon/<hash>.
		// It is the listing's content and goes with it.
		// simplified: an icon no listing names any more stays in the store
		ss_ icon_sha;
		if(!jstr(b, "icon").empty()){
			const ss_ hex = jstr(b, "icon");
			ss_ png;
			if(hex.size() <= 2 * 64 * 1024 &&
					hex.find_first_not_of("0123456789abcdef") == ss_::npos)
				for(size_t i = 0; i + 1 < hex.size(); i += 2)
					png += (char)std::stoi(hex.substr(i, 2), nullptr, 16);
			const unsigned side = interface::fs::SERVER_ICON_SIDE;
			if(png.size() * 2 != hex.size() ||
					!interface::fs::icon_png_ok(png, side)){
				refuse(r, "icon: a PNG of 64 KB or less and "+
						itos((int64_t)side)+" pixels a side or less, in hex");
				return;
			}
			icon_sha = interface::sha256::hex(interface::sha256::calculate(png));
			ss_ have;
			if(!store("icons")->get(icon_sha, have))
				store("icons")->set(icon_sha, hex);
		}
		const ss_ id = jstr(b, "id");
		json::Value l;
		json::Value answer = json::object();
		const int64_t t = now_s();
		if(!id.empty()){
			if(!m_rates.ok("announce", id, 1, 20)){
				refuse(r, "announced too often", "too_often");
				return;
			}
			l = load("listings", id);
			if(!l.is_object() || !same(jstr(l, "secret"), jstr(b, "secret"))){
				refuse(r, "no such listing, or not its secret", "no_listing");
				return;
			}
		} else {
			if(!m_rates.ok("new_listing", network::address_key(r.address),
					5, 86400)){
				refuse(r, "too many new listings from this address today");
				return;
			}
			l = json::object();
			l.set("id", random_hex(8));
			l.set("secret", random_hex(32));
			l.set("first_seen", t);
			l.set("status", "active");
			l.set("owner", "");
			l.set("strikes", json::array());
			answer.set("secret", jstr(l, "secret"));
		}
		if(banned("listing", jstr(l, "id")) ||
				banned("account", jstr(l, "owner"))){
			refuse(r, "this listing may not announce");
			return;
		}
		// The address it is reached at: what it named, or where the announce
		// came from
		ss_ host = jstr(b, "address");
		if(host.empty())
			host = r.address;
		// Into the challenge's URL: a host name or an address, nothing else
		if(host.size() > 253 || host.find_first_not_of(
				"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
				"0123456789.-:") != ss_::npos){
			refuse(r, "address: a host name or an IP address");
			return;
		}
		// Behind a proxy with TLS: challenged over HTTPS, joined by a
		// secure WebSocket
		const bool tls = b.get("tls").is_true();
		const bool moved = jstr(l, "host") != host || jint(l, "port") != port ||
				l.get("tls").is_true() != tls;
		l.set("tls", tls);
		for(const char *k : {"name", "description", "kind", "audience",
				"access", "region", "app", "version", "signup_url",
				"package", "game"})
			l.set(k, b.get(k).is_string() ? b.get(k) : json::Value(""));
		// Left out by an unlisted one (check_categories)
		for(const char *k : {"kind", "audience"})
			if(jstr(l, k) == "?")
				l.set(k, "");
		// A newer Buildat's kind is "other"; its audience the strictest
		if(!jstr(l, "kind").empty() && !in_set(jstr(l, "kind"), KINDS))
			l.set("kind", "other");
		if(!jstr(l, "audience").empty() &&
				!in_set(jstr(l, "audience"), AUDIENCES))
			l.set("audience", "adult");
		if(jstr(l, "name").empty() || jstr(l, "name") == "?")
			l.set("name", host);
		l.set("login", jstr(b, "login", "local"));
		// 10g: verified and taking IDs, not served in the list
		l.set("unlisted", b.get("unlisted").is_true());
		// Announcing again ends a withdrawal
		l.del_key("withdrawn");
		json::Value desc = b.get("descriptors").is_object() ?
				b.get("descriptors").deepcopy() : json::object();
		for(const auto &pair : DESCRIPTORS)
			if(desc.get(pair.first).is_undefined() ||
					std::find(pair.second.begin(), pair.second.end(),
					jstr(desc, pair.first.c_str())) == pair.second.end())
				desc.set(pair.first, "unknown");
		l.set("descriptors", desc);
		json::Value extra = json::object();
		for(json::Iterator it(b); it.valid(); it.next())
			if(!in_set(it.key(), ANNOUNCE_KEYS))
				extra.set(it.key(), it.value());
		// simplified: past 4 KB the unknown keys are dropped, not refused
		l.set("extra", extra.stringify().size() <= 4096 ? extra :
				json::object());
		l.set("tags", b.get("tags").is_array() ? b.get("tags") : json::array());
		l.set("languages", b.get("languages").is_array() ? b.get("languages") :
				json::array());
		l.set("players", jint(b, "players"));
		l.set("players_max", jint(b, "players_max"));
		// [SERVE_UPDATE_POLITE] 3: about to restart for an update; listed
		// as "updating" until it announces again, 10 minutes at most
		l.set("updating_until", b.get("updating").is_true() ? t + 600 :
				(int64_t)0);
		l.set("icon", icon_sha);
		l.set("host", host);
		l.set("port", port);
		l.set("last_announce", t);
		// A failed check is tried again at the next announce: a restart,
		// a moment's network trouble
		if(moved || jstr(l, "verify") != "ok"){
			l.set("verify", "pending");
			queue_verify(l);
		}
		join_fleet(l, jstr(b, "fleet"), jstr(b, "pool"));
		put("listings", jstr(l, "id"), l);
		consistency_check(l);
		pool_check(l);
		take_bans(l, b.get("bans"));
		answer.set("blocked", blocked_for(l));
		answer.set("subscribed", subscribed_names(l));
		answer.set("ok", true);
		answer.set("id", jstr(l, "id"));
		answer.set("status", served_status(l));
		if(jstr(l, "status") != "banned")
			answer.set("play", play_url());
		respond(r, 200, answer);
	}

	// -- 2b. Fleets and pools

	// "<id>:<code>" from the announce: the right code puts the listing in
	// the fleet and claims it for the fleet's owner; none takes it out;
	// a wrong one leaves it out and a moderator looks
	void join_fleet(json::Value &l, const ss_ &line, ss_ pool)
	{
		const size_t colon = line.find(':');
		const ss_ fid = colon == ss_::npos ? line : line.substr(0, colon);
		const ss_ code = colon == ss_::npos ? "" : line.substr(colon + 1);
		if(pool.size() > 32)
			pool = pool.substr(0, 32);
		if(fid.empty()){
			set_fleet(l, "");
			l.set("pool", "");
			return;
		}
		const json::Value f = load("fleets", fid);
		if(jstr(l, "fleet_removed") == fid)
			return; // its operator took it out; the config still says it
		if(f.is_object() && same(jstr(f, "code"), code) &&
				!banned("account", jstr(f, "owner"))){
			if(jstr(l, "fleet") != fid){
				record("", jstr(l, "id"), "fleet", "joined fleet "+fid, true);
				event({jstr(f, "owner")}, "", jstr(l, "name")+" joined your "
						"fleet "+jstr(f, "name"));
			}
			set_fleet(l, fid);
			l.set("pool", pool);
			l.set("owner", jstr(f, "owner"));
			if(l.get("claimed").is_undefined())
				l.set("claimed", now_s());
			return;
		}
		// One the fleet's new code turned away just leaves; one that never
		// was in it is looked at, once
		if(jstr(l, "fleet") == fid && f.is_object())
			event({jstr(f, "owner")}, "", jstr(l, "name")+" left your fleet "+
					jstr(f, "name")+" (its code is no longer the fleet's)");
		if(jstr(l, "fleet") != fid && jstr(l, "fleet_flagged") != fid){
			l.set("fleet_flagged", fid);
			const ss_ gid = jstr(l, "id")+"|impersonation";
			json::Value g = load("groups", gid);
			if(!g.is_object() || jstr(g, "state") != "open")
				open_group(gid, jstr(l, "id"), "impersonation",
						"Starport: announced with a wrong code for fleet "+fid);
		}
		set_fleet(l, "");
		l.set("pool", "");
	}

	// [FLEET_SUB_CARRY] A listing into fleet `fid` ("" for none), its
	// players' identity scope (id_scope_of) moved with it:
	// - a scope stays with its owner: an empty fleet takes the scope of
	//   the first listing to join it, and the last listing to leave takes
	//   the fleet's away with it (the fleet's is then fresh, taken by the
	//   next to join);
	// - any other move (into a fleet that has listings, out of one that
	//   keeps some: back to the listing's own, or a fresh one if the
	//   fleet keeps that) is to another scope, with the one before kept as
	//   `scope_prev` for the token's `prev_sub` -- 2 a listing in 30 days,
	//   past that nothing is carried.
	// Fleets from before this have "fleet:<id>" (no "scope" field) and
	// keep it. simplified: there is no fleet merge to carry across
	void set_fleet(json::Value &l, const ss_ &fid)
	{
		const ss_ was = jstr(l, "fleet");
		if(was == fid)
			return;
		const ss_ old_scope = id_scope_of(l);
		const ss_ old_where = where_of(l);
		if(!was.empty()){
			json::Value f = load("fleets", was);
			if(fleet_members(was, jstr(l, "id")) == 0 && f.is_object()){
				l.set("scope", old_scope);
				f.set("scope", "");
				put("fleets", was, f);
			} else if(own_scope_of(l) == id_scope_of(l)){
				// The fleet has the scope this listing founded it with
				l.set("scope", "scope:"+random_hex(12));
			}
		}
		l.set("fleet", fid);
		if(!fid.empty()){
			json::Value f = load("fleets", fid);
			if(f.is_object() && f.get("scope").is_string() &&
					jstr(f, "scope").empty() &&
					fleet_members(fid, jstr(l, "id")) == 0){
				f.set("scope", own_scope_of(l));
				put("fleets", fid, f);
			}
		}
		const ss_ new_scope = id_scope_of(l);
		if(new_scope == old_scope)
			return;
		json::Value moves = json::array();
		const json::Value &m = l.get("scope_moves");
		for(unsigned i = 0; m.is_array() && i < m.size(); i++)
			if(now_s() - m.at(i).as_integer() < 30 * 86400)
				moves.append(m.at(i));
		const bool carry = moves.size() < 2;
		moves.append(json::Value(now_s()));
		l.set("scope_moves", moves);
		l.set("scope_prev", carry ? old_scope : ss_());
		l.set("scope_prev_where", carry ? old_where : ss_());
		record("", jstr(l, "id"), "fleet", "identity scope moved"+
				ss_(carry ? "" : " (over 2 in 30 days: not carried)"), true);
	}
	// The listings in fleet `fid` other than `but`
	int fleet_members(const ss_ &fid, const ss_ &but)
	{
		int n = 0;
		for(auto &p : listings())
			n += p.first != but && jstr(p.second, "fleet") == fid;
		return n;
	}

	// A pool's servers are one entry, so they have to be the same thing:
	// one that differs from the others is shown on its own and looked at
	void pool_check(json::Value l)
	{
		if(jstr(l, "pool").empty())
			return;
		const json::Value mine = effective(l);
		for(auto &p : listings()){
			if(p.first == jstr(l, "id"))
				continue;
			const json::Value &o = p.second;
			if(jstr(o, "fleet") != jstr(l, "fleet") ||
					jstr(o, "pool") != jstr(l, "pool") ||
					o.get("pool_mismatch").is_true())
				continue;
			const json::Value e = effective(o);
			const bool differs = jstr(o, "app") != jstr(l, "app") ||
					e.stringify() != mine.stringify();
			if(differs != l.get("pool_mismatch").is_true()){
				l.set("pool_mismatch", differs);
				put("listings", jstr(l, "id"), l);
				if(differs)
					open_group(jstr(l, "id")+"|category", jstr(l, "id"),
							"category", "Starport: not the app or the "
							"categories of the rest of pool "+jstr(l, "pool"));
			}
			return;
		}
	}

	// The listings a group is about: its listing's, or its fleet's
	sv_<ss_> members_of(const json::Value &g)
	{
		const ss_ fid = jstr(g, "fleet");
		if(fid.empty())
			return {jstr(g, "listing")};
		sv_<ss_> out;
		for(auto &p : listings())
			if(jstr(p.second, "fleet") == fid)
				out.push_back(p.first);
		return out;
	}

	// 10g: a server off this Starport's list at once, by its own word;
	// kept, and back at its next announce
	void api_delist(const network::HttpRequest &r, const json::Value &b)
	{
		json::Value l = load("listings", jstr(b, "id"));
		if(!l.is_object() || !same(jstr(l, "secret"), jstr(b, "secret"))){
			refuse(r, "no such listing, or not its secret", "no_listing");
			return;
		}
		l.set("withdrawn", true);
		put("listings", jstr(l, "id"), l);
		json::Value v = json::object();
		v.set("ok", true);
		respond(r, 200, v);
	}

	// What it says that a listing whose audience is everyone has
	// unmoderated chat or content: a moderator looks ([STARPORT] 3)
	void consistency_check(const json::Value &l)
	{
		const json::Value e = effective(l);
		if(jstr(e, "audience") != "everyone")
			return;
		const json::Value &d = e.get("descriptors");
		if(jstr(d, "chat") != "unmoderated" && jstr(d, "ugc") != "unmoderated")
			return;
		const ss_ gid = jstr(l, "id")+"|category";
		json::Value g = load("groups", gid);
		if(g.is_object() && jstr(g, "state") == "open")
			return;
		if(g.is_object() && jstr(g, "decided") == "dismiss")
			return; // a moderator has looked already
		open_group(gid, jstr(l, "id"), "category",
				"Starport: an audience of everyone with unmoderated chat or "
				"content");
	}

	// "listed", or why it is not served
	ss_ served_status(const json::Value &l)
	{
		const ss_ st = jstr(l, "status");
		if(st == "delisted" || st == "banned")
			return st;
		if(jstr(l, "verify") != "ok")
			return jstr(l, "verify") == "failed" ?
					"unverified: the challenge to its address failed" :
					"unverified: being checked";
		if(jstr(l, "owner").empty())
			return "unclaimed: an operator account claims it with the claim "
					"code (starport_claim.txt)";
		const ss_ f = filtered_out(l);
		if(!f.empty())
			return "filtered out by this instance: "+f;
		if(l.get("withdrawn").is_true())
			return "withdrawn by its server";
		if(now_s() - jint(l, "last_announce") > 900)
			return "offline";
		if(l.get("unlisted").is_true())
			return "unlisted by its server: it takes Starport IDs, and is "
					"not in the list";
		return st == "hidden" ? "hidden from filtered views" : "listed";
	}

	// Why the instance's own filter leaves it out, or ""
	ss_ filtered_out(const json::Value &l)
	{
		const json::Value e = effective(l);
		const json::Value &f = setting("filter");
		auto has = [](const json::Value &arr, const ss_ &v){
			if(!arr.is_array())
				return false;
			for(unsigned i = 0; i < arr.size(); i++)
				if(arr.at(i).is_string() && arr.at(i).as_string() == v)
					return true;
			return false;
		};
		if(has(f.get("exclude_audience"), jstr(e, "audience")))
			return "audience "+jstr(e, "audience");
		if(has(f.get("exclude_kind"), jstr(e, "kind")))
			return "kind "+jstr(e, "kind");
		const json::Value &ex = f.get("exclude_descriptors");
		if(ex.is_array()){
			for(unsigned i = 0; i < ex.size(); i++){
				const ss_ d = ex.at(i).is_string() ? ex.at(i).as_string() : "";
				const ss_ v = jstr(e.get("descriptors"), d.c_str());
				// Unknown is left out with what it might be
				if(v == "yes" || v == "unmoderated" || v == "realistic" ||
						v == "unknown")
					return "descriptor "+d;
			}
		}
		return "";
	}

	// -- The verifier

	void queue_verify(const json::Value &l)
	{
		const ss_ nonce = random_hex(16);
		ss_ host = jstr(l, "host");
		if(host.find(':') != ss_::npos)
			host = "["+host+"]";
		VerifyJob j;
		j.listing = jstr(l, "id");
		j.url = ss_(l.get("tls").is_true() ? "https://" : "http://")+host+":"+
				itos(jint(l, "port"))+
				"/api/v1/starport/challenge?listing="+j.listing+"&nonce="+nonce;
		j.expect = hex(interface::sha256::hmac(unhex(jstr(l, "secret")),
				"buildat-challenge-1\n"+nonce));
		{
			std::lock_guard<std::mutex> lock(m_vmutex);
			// One thread checks them in turn, each up to http_get's two
			// minutes: past a thousand waiting, a new one waits for its
			// listing's next announce ([SECURITY_RUN_1])
			if(m_vjobs.size() >= 1000){
				log_w(MODULE, "Listing %s: a thousand checks are waiting; "
						"not checked this time", cs(j.listing));
				return;
			}
			m_vjobs.push_back(j);
		}
		m_vwake.notify_all();
	}

	void verifier()
	{
		for(;;){
			VerifyJob j;
			{
				std::unique_lock<std::mutex> lock(m_vmutex);
				m_vwake.wait(lock, [this](){
					return m_vstop || !m_vjobs.empty();
				});
				if(m_vstop)
					return;
				j = m_vjobs.front();
				m_vjobs.pop_front();
			}
			VerifyResult res;
			res.listing = j.listing;
			// A 503 is asked again 3 s later, twice: a server that has just
			// restarted under util/serve_latest_release.sh shares its port
			// with the stand-in page for a moment after it announces
			for(int attempt = 0; attempt < 3; attempt++){
				if(attempt > 0)
					std::this_thread::sleep_for(std::chrono::seconds(3));
				try {
					const ss_ text = interface::http_get(j.url);
					const json::Value v = json::load_string(text.c_str());
					res.ok = v.is_object() &&
							same(jstr(v, "response"), j.expect);
					if(!res.ok)
						res.why = "a wrong answer";
				} catch(std::exception &e){
					res.why = e.what();
				}
				if(res.ok || res.why.find("error: 503") == ss_::npos)
					break;
			}
			std::lock_guard<std::mutex> lock(m_vmutex);
			m_vresults.push_back(res);
		}
	}

	void apply_verify_results()
	{
		std::deque<VerifyResult> results;
		{
			std::lock_guard<std::mutex> lock(m_vmutex);
			results.swap(m_vresults);
		}
		for(const VerifyResult &res : results){
			json::Value l = load("listings", res.listing);
			if(!l.is_object())
				continue;
			l.set("verify", res.ok ? "ok" : "failed");
			l.set("verified_at", now_s());
			put("listings", res.listing, l);
			log_i(MODULE, "Listing %s (%s): verified %s%s", cs(res.listing),
					cs(jstr(l, "name")), res.ok ? "ok" : "not",
					res.ok ? "" : cs(": "+res.why));
		}
	}

	// -- 3b. The version adapter ([VERSION_CHECK])

	// <user>/apps/<app>/version_adapter, an executable the admin put there
	// (never a setting: an admin's web login must not run commands), run
	// at the start and hourly, given 60 s; it prints one JSON object. A
	// failed run keeps the last good answer. No file, nothing done.
	// simplified: through sh and timeout(1), so a Linux Starport only
	void version_tick(int64_t t)
	{
		std::shared_ptr<VersionRun> run = m_version_run;
		int status = 0;
		ss_ out;
		{
			std::lock_guard<std::mutex> lock(run->m);
			if(run->running)
				return;
			if(run->done){
				run->done = false;
				status = run->status;
				out.swap(run->out);
				take_version(status, out);
			}
		}
		if(t < m_next_version_run)
			return;
		m_next_version_run = t + 3600;
		const ss_ dir = m_server->get_config().get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id();
		const ss_ path = dir+"/version_adapter";
		if(!interface::fs::path_exists(path))
			return;
		if(path.find('\'') != ss_::npos){
			log_w(MODULE, "Version adapter: a quote in its path; not run");
			return;
		}
		run->running = true;
		std::thread([run, path, dir](){
			interface::process::ExecOptions o;
			o.output_path = dir+"/version_adapter.out";
			const int status = interface::process::shell_exec(
					"timeout 60 '"+path+"' 2>/dev/null", o);
			std::ifstream f(o.output_path, std::ios::binary);
			std::ostringstream os;
			os<<f.rdbuf();
			std::lock_guard<std::mutex> lock(run->m);
			run->status = status;
			run->out = os.str().substr(0, 65536);
			run->running = false;
			run->done = true;
		}).detach();
	}

	void take_version(int status, const ss_ &out)
	{
		ss_ why;
		json::Value v;
		if(status != 0){
			why = "it failed (wait status "+itos(status)+")";
		} else {
			json::json_error_t err;
			const json::Value a = json::load_string(out.c_str(), &err);
			v = a.is_object() ? version_answer(a, &why) : json::Value();
			if(!a.is_object())
				why = "not a JSON object";
		}
		if(!v.is_object()){
			log_w(MODULE, "Version adapter: %s; %s", cs(why),
					m_version.is_object() ? "the last answer kept" : "no answer");
			return;
		}
		if(!m_version.is_object() || m_version.stringify() != v.stringify())
			log_i(MODULE, "Version adapter: %s", cs(v.stringify()));
		m_version = v;
	}

	// -- 4. List

	void api_list(const network::HttpRequest &r, const json::Value &b)
	{
		if(!m_rates.ok("list", network::address_key(r.address), 60, 60)){
			refuse(r, "listed too often", "too_often");
			return;
		}
		const ss_ key = jstr(b, "key");
		if(!key.empty())
			key_seen(key);
		json::Value v = json::object();
		v.set("ok", true);
		v.set("starport", jstr(m_settings, "name"));
		v.set("servers", listed_servers());
		v.set("recommends", recommends());
		v.set("play", play_url());
		if(m_version.is_object())
			v.set("version", m_version);
		respond(r, 200, v);
	}

	// What /api/v1/list hands out: the listed servers, and those hidden from
	// filtered views marked restricted
	json::Value listed_servers()
	{
		json::Value servers = json::array();
		for(auto &pair : listings()){
			const json::Value &l = pair.second;
			if(!l.is_object())
				continue;
			const ss_ st = served_status(l);
			if(st != "listed" && st != "hidden from filtered views")
				continue;
			json::Value s = json::object();
			for(const char *k : {"id", "name", "description", "host", "port",
					"app", "version", "tags", "languages", "region", "signup_url",
					"login", "tls", "package", "game",
					"players", "players_max"})
				s.set(k, l.get(k));
			if(!jstr(l, "icon").empty())
				s.set("icon", jstr(l, "icon"));
			const json::Value e = effective(l);
			for(const char *k : {"kind", "audience", "access", "descriptors"})
				s.set(k, e.get(k));
			s.set("restricted", st != "listed");
			for(json::Iterator it(l.get("extra")); it.valid(); it.next())
				if(s.get(it.key()).is_undefined())
					s.set(it.key(), it.value());
			if(jint(l, "updating_until") > now_s())
				s.set("updating", true);
			const ss_ fid = jstr(l, "fleet");
			if(!fid.empty()){
				const json::Value f = load("fleets", fid);
				json::Value fs = json::object();
				for(const char *k : {"id", "name", "description", "link"})
					fs.set(k, jstr(f, k));
				s.set("fleet", fs);
				if(!l.get("pool_mismatch").is_true())
					s.set("pool", jstr(l, "pool"));
			}
			servers.append(s);
		}
		return servers;
	}

	// -- 5a. A key's standing

	// The record of a client's key, by the hash of its secret
	void key_seen(const ss_ &secret_hex)
	{
		if(!is_hex(secret_hex, 64))
			return;
		const ss_ h = hex(interface::sha256::calculate(unhex(secret_hex)));
		const int64_t d = day_of(now_s());
		json::Value k = load("keys", h);
		if(!k.is_object()){
			k = json::object();
			k.set("first_day", d);
			k.set("f", 1.0);
			k.set("last_day", d);
			k.set("upheld", (int64_t)0);
			k.set("rejected", (int64_t)0);
			put("keys", h, k);
			return;
		}
		const int64_t last = jint(k, "last_day");
		if(last >= d)
			return;
		// The filter run to today: the days between were 0, today is 1
		const double lambda = setting_num("lambda");
		k.set("f", jnum(k, "f") * pow(lambda, (double)(d - last)) + 1.0);
		k.set("last_day", d);
		put("keys", h, k);
	}

	// What a report by this key weighs ([STARPORT] 5a): its age and its
	// freshness, then its reports' record
	double key_weight(const ss_ &h)
	{
		const double w_min = setting_num("w_min");
		json::Value k = h.empty() ? json::Value() : load("keys", h);
		if(!k.is_object())
			return w_min;
		const int64_t d = day_of(now_s());
		const double lambda = setting_num("lambda");
		const double f = jnum(k, "f") * pow(lambda, (double)(d -
				jint(k, "last_day")));
		const double F = f * (1.0 - lambda);
		const double age = (double)(d - jint(k, "first_day"));
		double w = (1.0 - exp(-age / setting_num("tau_days"))) *
				pow(std::min(1.0, F / setting_num("f_full")), setting_num("b"));
		// A record of reports a moderator upheld adds to it; one of
		// rejected ones takes from it
		const int64_t up = jint(k, "upheld"), rej = jint(k, "rejected");
		w *= (1.0 + 0.1 * std::min<int64_t>(up, 10)) / (1.0 + 0.5 * rej);
		return std::max(w_min, w);
	}

	bool key_muted(const ss_ &h)
	{
		json::Value k = h.empty() ? json::Value() : load("keys", h);
		if(!k.is_object())
			return false;
		return jint(k, "muted_until") > now_s();
	}

	bool trusted(const ss_ &h)
	{
		const json::Value &t = setting("trusted_flaggers");
		for(unsigned i = 0; t.is_array() && i < t.size(); i++)
			if(t.at(i).is_string() && t.at(i).as_string() == h)
				return true;
		return false;
	}

	// -- 5. Report

	void api_report(const network::HttpRequest &r, const json::Value &b)
	{
		if(!m_rates.ok("report_addr", network::address_key(r.address),
				10, 3600)){
			refuse(r, "too many reports from this address; try later");
			return;
		}
		const ss_ listing = jstr(b, "listing");
		json::Value l = load("listings", listing);
		if(!l.is_object()){
			refuse(r, "no such listing");
			return;
		}
		const ss_ reason = jstr(b, "reason");
		if(!in_set(reason, REASONS)){
			refuse(r, "reason: one of category, illegal, csam, harassment, "
					"scam, malware, impersonation, spam, other");
			return;
		}
		const ss_ text = jstr(b, "text");
		if(text.size() > 2000){
			refuse(r, "text: at most 2000 characters");
			return;
		}
		const ss_ evidence = jstr(b, "evidence");
		if(evidence.size() > 48 * 1024){
			refuse(r, "evidence: at most 48 KiB");
			return;
		}
		ss_ h;
		const ss_ key = jstr(b, "key");
		if(!key.empty()){
			if(!is_hex(key, 64)){
				refuse(r, "key: 64 hex digits");
				return;
			}
			key_seen(key);
			h = hex(interface::sha256::calculate(unhex(key)));
			if(!m_rates.ok("report_key", h, 5, 3600)){
				refuse(r, "too many reports from this key; try later");
				return;
			}
		}
		json::Value rep = json::object();
		const ss_ id = random_hex(8);
		rep.set("id", id);
		rep.set("listing", listing);
		rep.set("reason", reason);
		rep.set("text", text);
		if(!evidence.empty())
			rep.set("evidence", evidence);
		if(b.get("suggest").is_object())
			rep.set("suggest", b.get("suggest"));
		rep.set("key", h);
		rep.set("address", r.address);
		rep.set("ts", now_s());
		rep.set("trusted", trusted(h));
		rep.set("weight", trusted(h) ? 1.0 : key_weight(h));
		// Of the whole fleet the listing is in, where the reporter said so
		const ss_ fleet = b.get("whole_fleet").is_true() ? jstr(l, "fleet") :
				ss_();
		const ss_ gid = (fleet.empty() ? listing : "fleet:"+fleet)+"|"+reason;
		rep.set("group", gid);
		if(!fleet.empty())
			rep.set("fleet", fleet);
		json::Value fields = json::object();
		fields.set("fleet", fleet);
		mod_do([&](moderation::Interface *m){
			m->add_report(this, rep, fields);
		});
		json::Value v = json::object();
		v.set("ok", true);
		v.set("receipt", id);
		respond(r, 200, v);
	}

	// -- 5, 6 and 7 in builtin/moderation: this is its Host

	void mod_do(std::function<void(moderation::Interface*)> f)
	{
		moderation::access(m_server, f);
	}

	void open_group(const ss_ &gid, const ss_ &listing, const ss_ &reason,
			const ss_ &note)
	{
		mod_do([&](moderation::Interface *m){
			m->open_group(this, gid, listing, reason, note, json::Value());
		});
	}

	// An operator's own doings in the audit log, not the moderators'
	void record(const ss_ &by, const ss_ &listing, const ss_ &action,
			const ss_ &text, bool automatic)
	{
		mod_do([&](moderation::Interface *m){
			m->audit(this, by, listing, action, "", text, automatic, false);
		});
	}

	storage::Save* save(){ return m_save; }
	ss_ name(){ return "Starport"; }
	json::Value subject(const ss_ &id){ return load("listings", id); }
	int severity(const ss_ &reason){ return reason_severity(reason); }

	// An ID's group is its suspension's, by a moderator: none of its
	// listings, nothing automatic
	sv_<ss_> members(const json::Value &g)
	{
		return jstr(g, "id_name").empty() ? members_of(g) : sv_<ss_>();
	}

	json::Value thresholds(const json::Value &g)
	{
		// An ID is suspended by a moderator, never by reports alone (10d)
		if(!jstr(g, "id_name").empty())
			return json::object();
		const json::Value &th = setting("thresholds");
		const json::Value &t = th.get(jstr(g, "reason"));
		return t.is_object() ? t : th.get("default");
	}

	// The spam filter ([STARPORT] 7): held back, not counted
	ss_ held(const json::Value &rep)
	{
		return key_muted(jstr(rep, "key")) ?
				"a key whose reports were mostly rejected" : "";
	}

	// [STARPORT] 7: one per address range -- an IPv4 /24, an IPv6 /48,
	// however the address was written ([SECURITY_RUN_7]: by its text,
	// 2001:db8::1 and 2001:db8:0:1::5 were two) -- and all the new keys of
	// a burst together as one
	ss_ bucket(const json::Value &rep)
	{
		if(rep.get("trusted").is_true())
			return "trusted:"+jstr(rep, "key");
		const json::Value k = load("keys", jstr(rep, "key"));
		const bool fresh = !k.is_object() ||
				day_of(now_s()) - jint(k, "first_day") < 2;
		return fresh ? "fresh" : "net:"+network::address_bin(
				jstr(rep, "address"), 3);
	}

	json::Value auto_act(const json::Value &g, const ss_ &id,
			const ss_ &want)
	{
		json::Value l = load("listings", id);
		if(!l.is_object())
			return json::Value();
		if(jstr(g, "reason") == "category" && want == "hide"){
			// Relabelled to what most reporters said, where they said it
			sm_<ss_, int> votes;
			const json::Value &reps = g.get("reports");
			for(unsigned i = 0; i < reps.size(); i++){
				const json::Value rep = load("reports", reps.at(i).as_string());
				const ss_ a = jstr(rep.get("suggest"), "audience");
				if(in_set(a, AUDIENCES))
					votes[a]++;
			}
			ss_ best;
			int n = 0;
			for(auto &pair : votes)
				if(pair.second > n)
					best = pair.first, n = pair.second;
			if(!best.empty()){
				json::Value rl = l.get("relabel").is_object() ?
						l.get("relabel").deepcopy() : json::object();
				rl.set("audience", best);
				l.set("relabel", rl);
			}
		}
		const ss_ prev = jstr(l, "status");
		if(want == "delist" || prev != "delisted")
			l.set("status", want == "delist" ? "delisted" : "hidden");
		l.set("status_auto", true);
		put("listings", id, l);
		return l;
	}

	void uphold(moderation::Interface *m, const ss_ &by, const json::Value &g,
			const json::Value &q)
	{
		const ss_ reason = jstr(g, "reason");
		if(!jstr(g, "id_name").empty()){
			suspend_id(m, by, jstr(g, "id_name"), jint(q, "days"), reason,
					jstr(q, "text"));
			return;
		}
		const sv_<ss_> members = members_of(g);
		if(members.empty())
			throw Exception("the listing has gone");
		for(const ss_ &id : members){
			const json::Value l = load("listings", id);
			if(l.is_object())
				apply_action(m, by, l, q, reason);
		}
	}

	// What was done automatically is undone
	bool undo_auto(const ss_ &id, const json::Value &g)
	{
		json::Value l = load("listings", id);
		if(!l.get("status_auto").is_true())
			return false;
		l.set("status", "active");
		l.set("status_auto", false);
		if(jstr(g, "reason") == "category")
			l.del_key("relabel");
		put("listings", id, l);
		return true;
	}

	void reverse(moderation::Interface *m, const ss_ &by,
			const json::Value &a, const ss_ &text)
	{
		// An ID's suspension (10d): lifted
		const ss_ lid = jstr(a, "listing");
		if(lid.compare(0, 3, "id:") == 0){
			json::Value id = load("ids", lid.substr(3));
			if(id.is_object()){
				id.set("suspended_until", (int64_t)0);
				put("ids", lid.substr(3), id);
			}
			m->audit(this, by, lid, "restore", "appeal", text, false);
		}
		json::Value l = load("listings", lid);
		if(l.is_object()){
			l.set("status", "active");
			l.set("status_until", (int64_t)0);
			l.del_key("relabel");
			put("listings", jstr(l, "id"), l);
			store("bans")->remove("listing:"+jstr(l, "id"));
			m->audit(this, by, jstr(l, "id"), "restore", "appeal", text, false);
			m->statement(this, l, "restored", "appeal", text, by);
		}
	}

	void decided(const json::Value &rep, bool upheld)
	{
		const ss_ h = jstr(rep, "key");
		json::Value k = h.empty() ? json::Value() : load("keys", h);
		if(!k.is_object())
			return;
		const char *f = upheld ? "upheld" : "rejected";
		k.set(f, jint(k, f) + 1);
		// [STARPORT] 6: a reporter whose reports are mostly rejected is
		// not heard for a while
		if(jint(k, "rejected") >= 5 && jint(k, "rejected") >
				3 * jint(k, "upheld"))
			k.set("muted_until", now_s() + 30 * 86400);
		put("keys", h, k);
	}

	// A statement by mail too, to an operator who gave an address
	void notify(const json::Value &s)
	{
		const ss_ owner = jstr(s, "owner");
		const json::Value o = owner.empty() ? json::Value() :
				load("operators", owner);
		if(jstr(o, "email").empty() || !can_mail())
			return;
		const ss_ sp = jstr(m_settings, "name");
		const ss_ name = jstr(s, "listing_name");
		mail(owner, jstr(o, "email"), sp+": "+jstr(s, "action")+": "+name,
				"Your listing \""+name+"\" ("+jstr(s, "listing")+") on "+sp+
				":\n\n    "+jstr(s, "action")+", for "+jstr(s, "reason")+
				"\n\n"+jstr(s, "text")+"\n\n"+"Appeal from your account on "+
				sp+"; another moderator than the one who acted decides.\n");
	}

	// An event on the Overview ([STARPORT_UI]): for the accounts and roles
	// ("@moderators", "@admins") in `to`; whoever did it (`by`) does not
	// see their own. Kept 90 days (daily()).
	void event(const sv_<ss_> &to, const ss_ &by, const ss_ &text)
	{
		json::Value e = json::object();
		const int64_t t = now_s();
		e.set("ts", t);
		json::Value who = json::array();
		for(const ss_ &x : to)
			who.append(x);
		e.set("to", who);
		e.set("by", by);
		e.set("text", text);
		char key[40];
		snprintf(key, sizeof key, "%012lld-%s", (long long)t,
				random_hex(3).c_str());
		put("events", key, e);
	}

	// The latest events for `name`, newest first
	json::Value events_for(const ss_ &name, bool mod, bool admin, size_t max)
	{
		json::Value out = json::array();
		sv_<ss_> keys = store("events")->list("");
		for(size_t i = keys.size(); i > 0 && out.size() < max; i--){
			const json::Value e = load("events", keys[i - 1]);
			if(jstr(e, "by") == name)
				continue;
			const json::Value &to = e.get("to");
			for(unsigned j = 0; to.is_array() && j < to.size(); j++){
				const ss_ x = to.at(j).is_string() ? to.at(j).as_string() : "";
				if(x == name || (x == "@moderators" && mod) ||
						(x == "@admins" && admin)){
					out.append(e);
					break;
				}
			}
		}
		return out;
	}

	// -- 5. The reporter's outcomes

	void api_report_status(const network::HttpRequest &r, const json::Value &b)
	{
		// Up to a hundred lookups a request, and nobody needs to log in
		if(!m_rates.ok("report_status", network::address_key(r.address),
				30, 60)){
			refuse(r, "asked too often", "too_often");
			return;
		}
		const ss_ key = jstr(b, "key");
		if(!is_hex(key, 64)){
			refuse(r, "key: 64 hex digits");
			return;
		}
		const ss_ h = hex(interface::sha256::calculate(unhex(key)));
		json::Value out = json::array();
		const json::Value &ids = b.get("receipts");
		for(unsigned i = 0; ids.is_array() && i < ids.size() && i < 100; i++){
			if(!ids.at(i).is_string())
				continue;
			const json::Value rep = load("reports", ids.at(i).as_string());
			if(!rep.is_object() || jstr(rep, "key") != h)
				continue;
			json::Value o = json::object();
			o.set("receipt", jstr(rep, "id"));
			o.set("state", jstr(rep, "state"));
			o.set("outcome", jstr(rep, "outcome"));
			out.append(o);
		}
		json::Value v = json::object();
		v.set("ok", true);
		v.set("reports", out);
		respond(r, 200, v);
	}

	// -- 6. Transparency

	void api_transparency(const network::HttpRequest &r)
	{
		// Every report read, for anyone: once a few seconds an address
		if(!m_rates.ok("transparency", network::address_key(r.address), 10, 60)){
			refuse(r, "asked too often", "too_often");
			return;
		}
		respond(r, 200, transparency());
	}

	json::Value transparency()
	{
		json::Value by_reason = json::object(), by_action = json::object();
		sv_<int64_t> times;
		int64_t reports = 0;
		for(const ss_ &id : store("reports")->list("")){
			const json::Value rep = load("reports", id);
			const ss_ reason = jstr(rep, "reason");
			by_reason.set(reason, jint(by_reason, reason.c_str()) + 1);
			reports++;
			if(jint(rep, "decided_at") > 0)
				times.push_back(jint(rep, "decided_at") - jint(rep, "ts"));
		}
		for(const ss_ &id : store("audit")->list("")){
			const json::Value a = load("audit", id);
			const ss_ k = jstr(a, "action")+(a.get("auto").is_true() ?
					" (automatic)" : "");
			by_action.set(k, jint(by_action, k.c_str()) + 1);
		}
		std::sort(times.begin(), times.end());
		json::Value v = json::object();
		v.set("ok", true);
		v.set("starport", jstr(m_settings, "name"));
		v.set("reports", reports);
		v.set("reports_by_reason", by_reason);
		v.set("actions", by_action);
		v.set("median_seconds_to_decide", times.empty() ? (int64_t)0 :
				times[times.size() / 2]);
		return v;
	}

	// -----------------------------------------------------------------------
	// [FRONT_PAGES]: what / shows a browser, read-only, from what the API
	// hands out to anyone. Filters are links: ?kind=, ?audience=. Only
	// what suits a teen and has been looked at for a while, with no way to
	// show more: left out are an adult listing, one kept out of filtered
	// views, one saying yes to sexual content, drugs or gambling or with
	// unmoderated chat or content, one with an open report, and one
	// claimed less than "page_delay" ago. The busiest first.
	// simplified: the delay counts from the claim, so a name or icon
	// changed later shows at once; hold a changed listing back too if
	// that is abused.

	// Whether the page at / leaves a listing out for its words
	static bool page_unsuitable(const json::Value &s)
	{
		const ss_ a = jstr(s, "audience");
		if((a != "everyone" && a != "teen") || s.get("restricted").is_true())
			return true;
		const json::Value &d = s.get("descriptors");
		for(const char *k : {"sexual", "drugs", "gambling"})
			if(jstr(d, k) == "yes")
				return true;
		return jstr(d, "chat") == "unmoderated" ||
				jstr(d, "ugc") == "unmoderated";
	}

	static ss_ server_box(const json::Value &s, const ss_ &play_url)
	{
		using interface::web_brand::html;
		using interface::web_brand::cut;
		ss_ b = "<div class=\"box\">";
		if(!jstr(s, "icon").empty())
			b += "<img class=\"icon\" src=\"/api/v1/icon/"+html(jstr(s, "icon"))+
					"\" width=\"48\" height=\"48\" alt=\"\">";
		const ss_ host = jstr(s, "host");
		const int64_t port = jint(s, "port");
		b += "<b>"+html(cut(jstr(s, "name"), 60))+"</b> <span class=\"meta\">"+
				html(host)+":"+itos(port)+"</span>";
		if(!jstr(s, "description").empty())
			b += "<br>"+html(cut(jstr(s, "description"), 300));
		sv_<ss_> m;
		for(const char *k : {"app", "kind", "audience"})
			if(!jstr(s, k).empty())
				m.push_back(k == ss_("audience") ? "for "+jstr(s, k) : jstr(s, k));
		m.push_back(itos(jint(s, "players"))+" of "+itos(jint(s, "players_max"))+
				" players");
		if(!jstr(s, "region").empty())
			m.push_back(jstr(s, "region"));
		if(!jstr(s, "version").empty())
			m.push_back("version "+jstr(s, "version"));
		m.push_back("access: "+jstr(s, "access"));
		m.push_back("login: "+jstr(s, "login", "local"));
		// The descriptors in words, those that say something
		const json::Value &d = s.get("descriptors");
		for(const auto &pair : DESCRIPTORS){
			const ss_ v = jstr(d, pair.first.c_str());
			if(v.empty() || v == "none" || v == "no")
				continue;
			ss_ k = pair.first;
			std::replace(k.begin(), k.end(), '_', ' ');
			m.push_back(v == "yes" ? k : v+" "+k);
		}
		ss_ line;
		for(const ss_ &x : m)
			line += (line.empty() ? "" : ", ")+html(x);
		b += "<br><span class=\"meta\">"+line+"</span><br>";
		// A server behind TLS serves the web client; its address as the
		// client's list has it. The Starport's play page joins it, where
		// there is one ([PLAY_LINKS])
		if(s.get("tls").is_true() && !play_url.empty())
			b += "<a href=\""+html(play_url)+"/?server="+html(host)+":"+
					itos(port)+"\" rel=\"nofollow noopener\">"
					"Play in your browser</a>";
		else if(s.get("tls").is_true())
			b += "<a href=\"https://"+html(host)+(port == 443 ? ss_() :
					":"+itos(port))+play_path(jstr(s, "kind"))+
					"\" rel=\"nofollow noopener\">"
					"Play in your browser</a>";
		else
			b += "<span class=\"meta\">Native client only</span>";
		if(!jstr(s, "signup_url").empty())
			b += " <span class=\"meta\">&middot; sign up at "+
					html(jstr(s, "signup_url"))+"</span>";
		return b+"</div>\n";
	}

	void front_page(const network::HttpRequest &r)
	{
		using interface::web_brand::html;
		if(!m_rates.ok("page", network::address_key(r.address), 30, 60)){
			network::access(m_server, [&](network::Interface *iface){
				iface->http_respond(r.peer, 429, "text/plain",
						"Too many requests; try again in a minute.\n");
			});
			return;
		}
		const ss_ name = jstr(m_settings, "name");
		ss_ kind = r.param("kind");
		ss_ audience = r.param("audience");
		if(!in_set(kind, KINDS))
			kind = "";
		if(audience != "everyone" && audience != "teen")
			audience = "";
		// A filter's link keeps the other
		auto link = [&](const ss_ &k, const ss_ &a, const ss_ &text, bool on){
			ss_ q;
			if(!k.empty()) q += "&kind="+k;
			if(!a.empty()) q += "&audience="+a;
			if(!q.empty()) q[0] = '?';
			return on ? "<b>"+text+"</b>" :
					"<a href=\"/"+q+"\">"+text+"</a>";
		};
		ss_ c = "<h1>"+html(name)+"</h1><p>A Starport: a list of Buildat "
				"servers that announce themselves here, and the Starport ID "
				"their players log in with. The Buildat client lists these "
				"servers and joins them.</p>\n<p class=\"meta\">Kind: "+
				link("", audience, "all", kind.empty());
		for(const char *k : KINDS)
			c += " "+link(k, audience, k, kind == k);
		c += "<br>Audience: "+link(kind, "", "all", audience.empty());
		for(const char *a : {"everyone", "teen"})
			c += " "+link(kind, a, a, audience == a);
		c += "</p>\n";
		// What an open report is about: its listing, or a whole fleet
		std::set<ss_> reported;
		sv_<ss_> open;
		mod_do([&](moderation::Interface *m){ open = m->open_groups(this); });
		for(const ss_ &gid : open){
			const json::Value g = load("groups", gid);
			if(jstr(g, "state") != "open")
				continue;
			reported.insert(jstr(g, "listing"));
			if(!jstr(g, "fleet").empty())
				reported.insert(jstr(g, "fleet"));
		}
		reported.erase("");
		// Fleets as groups, their servers under them; the rest after
		sm_<ss_, sv_<json::Value>> fleets;
		sm_<ss_, json::Value> fleet_of;
		sv_<json::Value> lone;
		const json::Value all = listed_servers();
		for(unsigned i = 0; i < all.size(); i++){
			const json::Value &s = all.at(i);
			if(!kind.empty() && jstr(s, "kind") != kind)
				continue;
			if(!audience.empty() && jstr(s, "audience") != audience)
				continue;
			if(page_unsuitable(s) || reported.count(jstr(s, "id")) ||
					reported.count(jstr(s.get("fleet"), "id")))
				continue;
			const json::Value l = load("listings", jstr(s, "id"));
			if(now_s() - std::max(jint(l, "first_seen"), jint(l, "claimed")) <
					(int64_t)setting_num("page_delay"))
				continue;
			const ss_ fid = jstr(s.get("fleet"), "id");
			if(fid.empty()){
				lone.push_back(s);
			} else {
				fleets[fid].push_back(s);
				fleet_of[fid] = s.get("fleet");
			}
		}
		// The busiest first: servers by players, fleets by their total
		auto players = [](const sv_<json::Value> &v){
			int64_t n = 0;
			for(const json::Value &s : v)
				n += jint(s, "players");
			return n;
		};
		auto busiest = [](sv_<json::Value> &v){
			std::stable_sort(v.begin(), v.end(), [](const json::Value &a,
					const json::Value &b){
				return jint(a, "players") > jint(b, "players");
			});
		};
		busiest(lone);
		sv_<ss_> order;
		for(auto &pair : fleets){
			busiest(pair.second);
			order.push_back(pair.first);
		}
		std::stable_sort(order.begin(), order.end(), [&](const ss_ &a,
				const ss_ &b){
			return players(fleets[a]) > players(fleets[b]);
		});
		using interface::web_brand::cut;
		for(const ss_ &fid : order){
			const json::Value &f = fleet_of[fid];
			c += "<h2>"+html(cut(jstr(f, "name"), 60))+"</h2>";
			if(!jstr(f, "description").empty())
				c += "<p class=\"meta\">"+html(cut(jstr(f, "description"),
						300))+"</p>";
			for(const json::Value &s : fleets[fid])
				c += server_box(s, play_url());
		}
		if(!lone.empty() || fleets.empty())
			c += "<h2>Servers</h2>\n";
		for(const json::Value &s : lone)
			c += server_box(s, play_url());
		if(lone.empty() && fleets.empty())
			c += "<p>No servers are listed here"+ss_(kind.empty() &&
					audience.empty() ? "" : " with these filters")+".</p>\n";
		const json::Value t = transparency();
		const int64_t median = jint(t, "median_seconds_to_decide");
		c += "<h2>Moderation</h2><p>"+itos(jint(t, "reports"))+" reports "
				"received; ";
		ss_ acts;
		const json::Value &a = t.get("actions");
		for(json::Iterator it(a); it.valid(); it.next())
			acts += (acts.empty() ? "" : ", ")+html(it.key())+" "+
					itos(jint(a, it.ckey()));
		c += (acts.empty() ? ss_("no actions taken") : "actions: "+acts)+
				"; the median time to decide a report: "+(median == 0 ?
				ss_("none decided yet") : median < 7200 ?
				itos(median / 60)+" minutes" : itos(median / 3600)+" hours")+
				". <a href=\"/api/v1/transparency\">The numbers</a>.</p>\n"
				"<h2>Privacy</h2><p>This page sets no cookies and loads nothing "
				"from elsewhere. A Starport ID keeps a name, a password and "
				"what you choose to add; <a href=\"/id\">the ID page</a> shows "
				"and changes yours.</p>\n";
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, 200, "text/html; charset=utf-8",
					interface::web_brand::page(name, name, c));
		});
	}

	// -----------------------------------------------------------------------
	// 10. Starport ID: an account of this server's builtin/accounts, and
	// what Starport keeps of it in "ids" (all of it listed to the user at
	// registration, 10a)

	static int64_t this_year()
	{
		return interface::os::utc_tm(now_s()).tm_year + 1900;
	}

	// 10b: the lowest the age can be, from the year alone; 18 for "18 or
	// over", which is all that is known of an adult
	static int64_t age_low(const json::Value &id)
	{
		if(id.get("adult").is_true())
			return 18;
		// Not said yet (an account made by joining the app): the youngest
		if(id.get("birth_year").is_undefined())
			return 0;
		return this_year() - jint(id, "birth_year") - 1;
	}
	static const char* band(const json::Value &id)
	{
		const int64_t a = age_low(id);
		return a >= 18 ? "18+" : a >= 13 ? "13-17" : "under 13";
	}

	// The account: "" when done, else why not. q has adult (bool), or
	// birth_year and, under 13, consent
	ss_ set_age(json::Value &id, const json::Value &q)
	{
		if(q.get("adult").is_true()){
			id.set("adult", true);
			id.del_key("birth_year");
			id.del_key("consent");
			return "";
		}
		const int64_t y = jint(q, "birth_year");
		if(y < this_year() - 120 || y > this_year())
			return "birth_year: the year you were born";
		json::Value probe = json::object();
		probe.set("birth_year", y);
		if(age_low(probe) >= 18){
			// Not kept: an adult is "18 or over" and nothing more
			id.set("adult", true);
			id.del_key("birth_year");
			id.del_key("consent");
			return "";
		}
		if(age_low(probe) < 13 && !q.get("consent").is_true())
			return "consent: under 13, a parent's consent is needed";
		id.set("adult", false);
		id.set("birth_year", y);
		id.set("consent", q.get("consent").is_true());
		return "";
	}

	json::Value id_me(const ss_ &name)
	{
		const json::Value id = load("ids", name);
		const json::Value o = load("operators", name);
		json::Value me = json::object();
		me.set("name", name);
		me.set("email", jstr(o, "email"));
		me.set("email_pending", jstr(o, "email_pending"));
		me.set("adult", id.get("adult").is_true());
		if(!id.get("adult").is_true())
			me.set("birth_year", jint(id, "birth_year"));
		me.set("consent", id.get("consent").is_true());
		me.set("band", !id.get("adult").is_true() &&
				id.get("birth_year").is_undefined() ? "not said" : band(id));
		me.set("logins", jint(id, "logins"));
		me.set("key", jstr(id, "key"));
		bool totp = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			totp = a->totp_on(name);
		});
		me.set("totp", totp);
		me.set("suspended_until", jint(id, "suspended_until"));
		json::Value scopes = json::array();
		const json::Value &sc = id.get("scopes");
		if(sc.is_object())
			for(json::Iterator it(sc); it.valid(); it.next()){
				json::Value x = json::object();
				x.set("scope", it.key());
				x.set("name", jstr(it.value(), "name"));
				scopes.append(x);
			}
		me.set("scopes", scopes);
		// Its statements of reasons (6), where it was suspended
		json::Value st = json::array();
		for(const ss_ &sid : store("statements")->list("")){
			const json::Value s = load("statements", sid);
			if(jstr(s, "owner") == name)
				st.append(s);
		}
		me.set("statements", st);
		me.set("recommends", recommends());
		return me;
	}

	// A session, kept by its hash. [WEB_ID_TRUST] (b): when, from where
	// and how ("login" or "register", on "page" -- Starport's own -- or
	// a client), which the ID sees with its recent logins
	ss_ new_session(const ss_ &name, const network::HttpRequest &r,
			const char *how)
	{
		const ss_ session = random_hex(32);
		json::Value s = json::object();
		s.set("name", name);
		s.set("expires", now_s() + 30 * 86400);
		s.set("created", now_s());
		s.set("address", r.address);
		s.set("how", ss_(how)+(r.origin.empty() ? " in a client" :
				" on the Starport's page"));
		put("sessions", hex(interface::sha256::calculate(session)), s);
		// The last 20 logins
		json::Value id = load("ids", name);
		if(id.is_object()){
			json::Value recent = json::array();
			const json::Value &old = id.get("recent");
			const unsigned n = old.is_array() ? old.size() : 0;
			for(unsigned i = n > 19 ? n - 19 : 0; i < n; i++)
				recent.append(old.at(i));
			json::Value e = json::object();
			for(const char *k : {"created", "address", "how"})
				e.set(k, s.get(k));
			recent.append(e);
			id.set("recent", recent);
			put("ids", name, id);
		}
		return session;
	}

	// A session's or a login's record as the ID sees it: the address only
	// while the retention keeps addresses ([STARPORT] 8)
	json::Value seen(const json::Value &x)
	{
		json::Value e = json::object();
		e.set("created", jint(x, "created"));
		e.set("how", jstr(x, "how"));
		const bool keep = now_s() - jint(x, "created") <
				(int64_t)(setting_num("retention_days") * 86400);
		e.set("address", keep ? jstr(x, "address") : ss_());
		return e;
	}

	// The ID a session is of, or ""
	ss_ session_name(const ss_ &session)
	{
		if(session.empty() || session.size() > 100)
			return "";
		const ss_ key = hex(interface::sha256::calculate(session));
		const json::Value s = load("sessions", key);
		if(!s.is_object())
			return "";
		if(jint(s, "expires") < now_s()){
			store("sessions")->remove(key);
			return "";
		}
		// Used, it lasts 30 days from now: activity is the proof. Written
		// once a day at most
		if(jint(s, "expires") < now_s() + 29 * 86400){
			json::Value u = s;
			u.set("expires", now_s() + 30 * 86400);
			put("sessions", key, u);
		}
		return jstr(s, "name");
	}

	// The reminder of a missing recovery e-mail: on the 2nd, 6th, 18th,
	// 54th... login (2 * 3^n, 10a)
	static bool remind_login(int64_t n)
	{
		for(int64_t m = 2; m <= n; m *= 3)
			if(m == n)
				return true;
		return false;
	}

	// A listing's community: "fleet:<id>" or "listing:<id>", what
	// blocklists name as their publishers and subscribers
	ss_ scope_of(const json::Value &l)
	{
		return jstr(l, "fleet").empty() ? "listing:"+jstr(l, "id") :
				"fleet:"+jstr(l, "fleet");
	}
	// A per-fleet identity (10c): the same in a fleet, different in any
	// other; a listing in no fleet is its own scope. [FLEET_SUB_CARRY]:
	// stored, so it stays with its owner across fleet moves (set_fleet)
	ss_ own_scope_of(const json::Value &l)
	{
		return l.get("scope").is_string() && !jstr(l, "scope").empty() ?
				jstr(l, "scope") : "listing:"+jstr(l, "id");
	}
	ss_ id_scope_of(const json::Value &l)
	{
		const ss_ fid = jstr(l, "fleet");
		if(fid.empty())
			return own_scope_of(l);
		const json::Value f = load("fleets", fid);
		return f.get("scope").is_string() && !jstr(f, "scope").empty() ?
				jstr(f, "scope") : "fleet:"+fid;
	}
	// For the player's question: where a listing's identity scope is
	ss_ where_of(const json::Value &l)
	{
		const ss_ fid = jstr(l, "fleet");
		return fid.empty() ? jstr(l, "name") :
				"the fleet "+jstr(load("fleets", fid), "name");
	}
	ss_ sub_of(const ss_ &name, const ss_ &scope)
	{
		json::Value k = load("settings", "id_secret");
		if(!k.is_string()){
			k = json::Value(random_hex(32));
			put("settings", "id_secret", k);
		}
		return hex(interface::sha256::hmac(unhex(k.as_string()),
				name+"|"+scope)).substr(0, 24);
	}

	static ss_ base64url(const ss_ &data)
	{
		static const char *A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnop"
				"qrstuvwxyz0123456789-_";
		ss_ out;
		uint32_t buf = 0;
		int bits = 0;
		for(unsigned char c : data){
			buf = (buf << 8) | c;
			bits += 8;
			while(bits >= 6){
				out += A[(buf >> (bits - 6)) & 63];
				bits -= 6;
			}
		}
		if(bits > 0)
			out += A[(buf << (6 - bits)) & 63];
		return out;
	}

	void api_id(const network::HttpRequest &r, const json::Value &b)
	{
		const ss_ what = r.path.substr(11);
		json::Value result;
		ss_ error;
		try {
			// [WEB_ID_TRUST]: a page of another origin -- a web client a
			// game server served, which could keep the password -- gets
			// no ID call but authorize_info: an ID logs in on this
			// Starport's own page. A native client sends no Origin.
			const size_t sep = r.origin.find("://");
			if(!r.origin.empty() && what != "authorize_info" &&
					(sep == ss_::npos || r.origin.substr(sep + 3) != r.host))
				throw Exception("a web page logs in to a Starport ID on "
						"the Starport's own page");
			result = id_call(r, what, b);
		} catch(std::exception &e){
			error = e.what();
		}
		json::Value v = json::object();
		if(error.empty()){
			v.set("ok", true);
			v.set("result", result);
		} else {
			v.set("ok", false);
			v.set("code", error == "session" ? "session" : "refused");
			v.set("error", error);
		}
		respond(r, 200, v);
	}

	json::Value id_call(const network::HttpRequest &r, const ss_ &what,
			const json::Value &b)
	{
		accounts::Interface *acc = nullptr;
		accounts::access(m_server, [&](accounts::Interface *a){ acc = a; });
		if(!acc)
			throw Exception("Starport is not ready");
		if(what == "register"){
			if(!setting("id_registration").is_true())
				throw Exception("this Starport makes no new IDs");
			if(!m_rates.ok("id_register", network::address_bin(r.address), 5,
					86400))
				throw Exception("too many new IDs from this network today");
			const ss_ name = jstr(b, "name");
			json::Value id = json::object();
			const ss_ age_error = set_age(id, b);
			if(!age_error.empty())
				throw Exception(age_error);
			const ss_ err = acc->create_account(name, jstr(b, "password"));
			if(!err.empty())
				throw Exception(err);
			id.set("logins", (int64_t)1);
			id.set("created", now_s());
			id.set("scopes", json::object());
			// The report key the client had, or a new one (5c)
			const ss_ key = jstr(b, "key");
			id.set("key", is_hex(key, 64) ? key : random_hex(32));
			put("ids", name, id);
			json::Value out = json::object();
			if(!jstr(b, "email").empty()){
				try {
					out.set("email", cmd_set_email(name, jstr(b, "email")));
				} catch(std::exception &e){
					out.set("email_error", e.what());
				}
			}
			out.set("session", new_session(name, r, "register"));
			out.set("me", id_me(name));
			return out;
		}
		if(what == "login"){
			const ss_ name = jstr(b, "name");
			// Wrong logins by the block of addresses they come from, not
			// by the name: who a client says it is means nothing before
			// it has logged in, and a limit by name was anyone's to keep
			// its owner out
			const ss_ bin = network::address_bin(r.address);
			auto wrong = [&](const char *why){
				m_rates.ok("id_login_wrong", bin, 30, 3600);
				throw Exception(why);
			};
			if(!m_rates.ok("id_login_wrong", bin, 30, 3600, false))
				throw Exception("too many wrong logins from this network; "
						"try later");
			json::Value id = load("ids", name);
			if(!acc->check_password(name, jstr(b, "password")))
				wrong("wrong name or password");
			// An account made by joining the app (an operator's) is an ID
			// too, from its first login here; its age is not said yet
			if(!id.is_object()){
				id = json::object();
				id.set("logins", (int64_t)0);
				id.set("created", now_s());
				id.set("scopes", json::object());
				id.set("key", random_hex(32));
				id.set("adult", false);
			}
			if(acc->totp_on(name)){
				if(jstr(b, "totp").empty())
					throw Exception("totp");
				if(!acc->check_totp(name, jstr(b, "totp")))
					wrong("wrong TOTP code");
			}
			if(jint(id, "suspended_until") > now_s())
				throw Exception("this ID is suspended; its statement of "
						"reasons is on the Starport");
			id.set("logins", jint(id, "logins") + 1);
			put("ids", name, id);
			json::Value out = json::object();
			out.set("session", new_session(name, r, "login"));
			out.set("me", id_me(name));
			out.set("remind_email", jstr(load("operators", name),
					"email").empty() && remind_login(jint(id, "logins")));
			return out;
		}
		// [WEB_ID_TRUST]: what /authorize shows before its Allow
		if(what == "authorize_info"){
			// [STARPORT_SITE_LOGIN] Or a website's
			if(!jstr(b, "site").empty()){
				const json::Value f = find_site(b);
				json::Value out = json::object();
				out.set("name", jstr(f, "name"));
				out.set("origin", jstr(f, "origin"));
				out.set("site", true);
				return out;
			}
			const json::Value l = find_listing(b);
			json::Value out = json::object();
			out.set("name", jstr(l, "name"));
			out.set("origin", web_origin(l, b));
			return out;
		}
		if(what == "reset_request"){
			const ss_ name = jstr(b, "name");
			const json::Value o = load("operators", name);
			if(!m_rates.ok("id_reset", name, 3, 86400) ||
					!m_rates.ok("id_reset_addr",
						network::address_key(r.address), 10, 86400))
				throw Exception("too many resets; try later");
			// Said the same whether or not there is an address, so a
			// name's e-mail cannot be probed
			if(!jstr(o, "email").empty() && can_mail()){
				json::Value id = load("ids", name);
				const ss_ code = random_hex(4);
				id.set("reset_code", code);
				id.set("reset_ts", now_s());
				put("ids", name, id);
				const ss_ sp = jstr(m_settings, "name");
				mail(name, jstr(o, "email"), sp+": a new password",
						"A new password for the Starport ID "+name+" on "+sp+
						" was asked for. The code is:\n\n    "+code+"\n\n"
						"If that was not you, nothing needs doing.\n");
			}
			return json::Value("if the ID has a recovery e-mail, a code "
					"went to it");
		}
		if(what == "reset"){
			const ss_ name = jstr(b, "name");
			json::Value id = load("ids", name);
			if(!m_rates.ok("id_reset_try", name, 10, 86400) ||
					jstr(id, "reset_code").empty() ||
					now_s() - jint(id, "reset_ts") > 86400 ||
					!same(jstr(id, "reset_code"), jstr(b, "code")))
				throw Exception("not the code, or it is over a day old");
			const ss_ err = acc->set_password(name, jstr(b, "password"));
			if(!err.empty())
				throw Exception(err);
			id.set("reset_code", "");
			put("ids", name, id);
			return json::Value(true);
		}
		// The rest are of a logged-in ID
		const ss_ name = session_name(jstr(b, "session"));
		if(name.empty())
			throw Exception("session");
		json::Value id = load("ids", name);
		if(!id.is_object())
			throw Exception("session");
		if(what == "me")
			return id_me(name);
		// [WEB_ID_TRUST] (b): the sessions and the recent logins, and an
		// end to every session but this one
		const ss_ this_key = hex(interface::sha256::calculate(
				jstr(b, "session")));
		if(what == "sessions"){
			json::Value out = json::object();
			json::Value ss = json::array();
			for(const ss_ &k : store("sessions")->list("")){
				const json::Value x = load("sessions", k);
				if(jstr(x, "name") != name || jint(x, "expires") < now_s())
					continue;
				json::Value e = seen(x);
				e.set("this", k == this_key);
				ss.append(e);
			}
			out.set("sessions", ss);
			json::Value rs = json::array();
			const json::Value &recent = id.get("recent");
			for(unsigned i = 0; recent.is_array() && i < recent.size(); i++)
				rs.append(seen(recent.at(i)));
			out.set("recent", rs);
			return out;
		}
		if(what == "logout_others"){
			int64_t n = 0;
			for(const ss_ &k : store("sessions")->list(""))
				if(k != this_key && jstr(load("sessions", k), "name") == name){
					store("sessions")->remove(k);
					n++;
				}
			return json::Value(n);
		}
		// (b): with TOTP on, a change of the password, the e-mail or the
		// TOTP takes a fresh code too, in "totp": a session alone is not
		// enough. Turning it off takes one already ("code").
		if((what == "password" || what == "email" || (what == "totp" &&
				jstr(b, "cmd") == "begin")) && acc->totp_on(name)){
			if(jstr(b, "totp").empty())
				throw Exception("totp");
			if(!acc->check_totp(name, jstr(b, "totp")))
				throw Exception("wrong TOTP code");
		}
		if(what == "logout"){
			store("sessions")->remove(hex(interface::sha256::calculate(
					jstr(b, "session"))));
			return json::Value(true);
		}
		if(what == "email")
			return cmd_set_email(name, jstr(b, "email"));
		if(what == "confirm_email")
			return cmd_confirm_email(name, jstr(b, "code"));
		if(what == "age"){
			const ss_ err = set_age(id, b);
			if(!err.empty())
				throw Exception(err);
			put("ids", name, id);
			return id_me(name);
		}
		if(what == "password"){
			if(!acc->check_password(name, jstr(b, "old")))
				throw Exception("the old password is wrong");
			const ss_ err = acc->set_password(name, jstr(b, "new"));
			if(!err.empty())
				throw Exception(err);
			return json::Value(true);
		}
		if(what == "totp"){
			const ss_ cmd = jstr(b, "cmd");
			json::Value out = json::object();
			if(cmd == "begin"){
				out.set("secret", acc->totp_begin(name));
				out.set("uri", acc->totp_uri(name, jstr(out, "secret")));
			} else if(cmd == "confirm" || cmd == "off"){
				const ss_ err = cmd == "confirm" ?
						acc->totp_confirm(name, jstr(b, "code")) :
						acc->totp_off(name, jstr(b, "code"));
				if(!err.empty())
					throw Exception(err);
			}
			out.set("on", acc->totp_on(name));
			return out;
		}
		if(what == "delete"){
			if(!acc->check_password(name, jstr(b, "password")))
				throw Exception("the password is wrong");
			// What moderation must keep of a suspended ID stays, as its
			// record and not as the account (10a)
			if(jint(id, "suspended_until") > now_s()){
				json::Value keep = json::object();
				keep.set("band", band(id));
				keep.set("suspended_until", jint(id, "suspended_until"));
				keep.set("deleted", now_s());
				put("moderation_ids", name, keep);
			}
			store("ids")->remove(name);
			store("operators")->remove(name);
			acc->delete_account(name);
			for(const ss_ &k : store("sessions")->list(""))
				if(jstr(load("sessions", k), "name") == name)
					store("sessions")->remove(k);
			return json::Value(true);
		}
		if(what == "token")
			return id_token(name, id, b);
		throw Exception("no such call");
	}

	// 10c: a token for one listing, signed with its secret, which its
	// server checks without asking Starport. The name used in a fleet is
	// asked the first time ("name" back, and the ID's own as a suggestion)
	json::Value id_token(const ss_ &name, json::Value id, const json::Value &b)
	{
		if(jint(id, "suspended_until") > now_s())
			throw Exception("this ID is suspended");
		if(!id.get("adult").is_true() && id.get("birth_year").is_undefined())
			throw Exception("say your age first: servers on this Starport "
					"have age limits, so an ID says whether its owner is 18 "
					"or over (in the client: Starport settings..., Starport "
					"ID..., Change the age...)");
		// [STARPORT_SITE_LOGIN] A website's: its origin, its own scope and
		// secret, no audience
		const bool site = !jstr(b, "site").empty();
		const json::Value l = site ? find_site(b) : find_listing(b);
		const ss_ origin = site ? jstr(l, "origin") : web_origin(l, b);
		// 10b: the age band against the listing's audience
		const ss_ aud = site ? "" : jstr(effective(l), "audience");
		const int64_t age = age_low(id);
		if((aud == "adult" && age < 18) || (aud == "teen" && age < 13))
			throw Exception("this server's audience is "+aud+": not for "
					"this ID's age");
		const ss_ scope = site ? "site:"+jstr(l, "id") : id_scope_of(l);
		json::Value scopes = id.get("scopes").is_object() ?
				id.get("scopes").deepcopy() : json::object();
		ss_ shown = jstr(scopes.get(scope), "name");
		// The name changed: the community's server has an account of its
		// own by the one it had (the client asks the player for another)
		const bool rename = b.get("rename").is_true() &&
				!jstr(b, "name").empty() && jstr(b, "name") != shown;
		if(shown.empty() || rename){
			const ss_ want = jstr(b, "name");
			if(want.empty()){
				json::Value out = json::object();
				out.set("need_name", true);
				out.set("suggest", name);
				return out;
			}
			if(want.size() > 20 || want.find_first_not_of(
					"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
					"0123456789_-") != ss_::npos)
				throw Exception("a name is 1 to 20 letters, digits, _ or -");
			const ss_ taken_key = scope+"|"+want;
			const json::Value taken = load("scope_names", taken_key);
			if(taken.is_string() && taken.as_string() != name)
				throw Exception("that name is taken in this community");
			put("scope_names", taken_key, json::Value(name));
			if(!shown.empty())
				store("scope_names")->remove(scope+"|"+shown);
			json::Value s = json::object();
			s.set("name", want);
			scopes.set(scope, s);
			id.set("scopes", scopes);
			put("ids", name, id);
			shown = want;
		}
		// 10d: which ID a server's report of this identity is about
		put("subs", scope+"|"+sub_of(name, scope), json::Value(name));
		// The format is public (doc/starport.txt): v, typ and aud say what
		// it is and for whom, listing or site the same as aud
		json::Value p = json::object();
		p.set("v", 1);
		p.set("typ", site ? "site" : "server");
		p.set("iss", jstr(m_settings, "name"));
		p.set("aud", jstr(l, "id"));
		p.set("sub", sub_of(name, scope));
		p.set("name", shown);
		p.set(site ? "site" : "listing", jstr(l, "id"));
		p.set("exp", now_s() + 30 * 86400);
		if(aud == "adult")
			p.set("adult", true);
		// [FLEET_SUB_CARRY] One move back, for this listing only: the
		// server asks the player whether to keep the account it knew
		const ss_ prev = site ? ss_() : jstr(l, "scope_prev");
		if(!prev.empty() && prev != scope){
			p.set("prev_sub", sub_of(name, prev));
			p.set("moved_from", jstr(l, "scope_prev_where"));
			p.set("moved_to", where_of(l));
		}
		const ss_ payload = base64url(p.stringify());
		json::Value out = json::object();
		out.set("token", payload+"."+hex(interface::sha256::hmac(
				unhex(jstr(l, "secret")), "buildat-token-1\n"+payload)));
		out.set(site ? "site" : "listing", jstr(l, "id"));
		out.set("name", shown);
		out.set("exp", jint(p, "exp"));
		if(!origin.empty())
			out.set("origin", origin);
		return out;
	}

	// [STARPORT_SITE_LOGIN] A token's website, by its id; none of a banned
	// account's
	json::Value find_site(const json::Value &b)
	{
		const json::Value f = load("sites", jstr(b, "site"));
		if(!f.is_object() || banned("account", jstr(f, "owner")))
			throw Exception("no such site");
		return f;
	}

	// A token's listing: by its id, or else (10g) an unlisted server by the
	// address the client is connected to, among the verified listings --
	// never by an id the server names, which could be another server's
	json::Value find_listing(const json::Value &b)
	{
		json::Value l = load("listings", jstr(b, "listing"));
		const ss_ address = jstr(b, "address");
		if(!l.is_object() && !address.empty()){
			for(auto &p : listings()){
				const json::Value &o = p.second;
				if(jstr(o, "verify") == "ok" && jstr(o, "status") != "banned" &&
						jstr(o, "host")+":"+itos(jint(o, "port")) == address){
					l = o;
					break;
				}
			}
		}
		if(!l.is_object())
			throw Exception("no such listing");
		// By its id too, only what the address lookup finds: a listing
		// that never proved its address could name another server's
		// ([SECURITY_RUN_2]; that server refuses the token, but the
		// sign-in window would show its host)
		if(jstr(l, "verify") != "ok" || jstr(l, "status") == "banned")
			throw Exception("this listing is not verified (yet): its server "
					"has not answered the Starport at its address");
		return l;
	}

	// [WEB_ID_TRUST]: the web page a token for `l` may go to, for /authorize
	// ("web": true): the web client the listed server serves itself, or one
	// of the setting web_clients (a fixed page that joins any server). ""
	// when not asked for the web.
	ss_ web_origin(const json::Value &l, const json::Value &b)
	{
		if(!b.get("web").is_true())
			return "";
		const bool tls = l.get("tls").is_true();
		const int64_t port = jint(l, "port");
		const ss_ own = ss_(tls ? "https://" : "http://")+jstr(l, "host")+
				(port == (tls ? 443 : 80) ? ss_() : ":"+itos(port));
		const ss_ want = jstr(b, "origin");
		if(want.empty() || want == own)
			return own;
		if(!play_origin().empty() && want == play_origin())
			return want;
		const json::Value &c = setting("web_clients");
		for(unsigned i = 0; c.is_array() && i < c.size(); i++)
			if(c.at(i).is_string() && c.at(i).as_string() == want)
				return want;
		throw Exception("this Starport sends no tokens to "+want);
	}

	// -----------------------------------------------------------------------
	// Every tick: the verifier's results; once a day, what keeping data
	// costs; every six hours, the listings checked again

	void on_tick(const interface::TickEvent &)
	{
		if(!m_save)
			return;
		apply_verify_results();
		version_tick(now_s());
		sv_<ss_> failed;
		{
			std::lock_guard<std::mutex> lock(m_mail_failures->m);
			failed.swap(m_mail_failures->lines);
		}
		for(const ss_ &line : failed)
			event({"@admins"}, "", line);
		const int64_t t = now_s();
		if(t >= m_next_reverify){
			m_next_reverify = t + 6 * 3600;
			for(auto &p : listings()){
				const json::Value &l = p.second;
				if(l.is_object() && t - jint(l, "last_announce") < 900)
					queue_verify(l);
			}
		}
		if(day_of(t) != m_last_day){
			m_last_day = day_of(t);
			daily();
		}
	}

	void daily()
	{
		const int64_t t = now_s();
		const int64_t keep = jint(m_settings, "retention_days", 7) * 86400;
		int cleared = 0;
		store("reports")->batch([&](){
			for(const ss_ &id : store("reports")->list("")){
				json::Value rep = load("reports", id);
				if(!jstr(rep, "address").empty() && t - jint(rep, "ts") > keep){
					rep.set("address", "");
					put("reports", id, rep);
					cleared++;
				}
			}
		});
		// simplified: events are dropped after 90 days, seen or not
		store("events")->batch([&](){
			for(const ss_ &k : store("events")->list(""))
				if(t - jint(load("events", k), "ts") > 90 * 86400)
					store("events")->remove(k);
		});
		// Listings not heard from in 30 days go, a claimed one in a year
		// while its owner is in good standing, unless moderation has a
		// record of them
		int gone = 0;
		for(const ss_ &id : listing_ids()){
			const json::Value &l = m_listings[id];
			if(t - jint(l, "last_announce") >
					(good_standing(jstr(l, "owner")) ? 365 : 30) * 86400 &&
					jstr(l, "status") == "active" &&
					l.get("strikes").size() == 0){
				listing_remove(id);
				gone++;
			}
		}
		// A login's or a session's address goes after the retention too
		// ([STARPORT_ADDR_RETENTION]); seen() already hides it from the ID
		auto clear_old = [&](json::Value &x){
			if(jstr(x, "address").empty() || t - jint(x, "created") <= keep)
				return false;
			x.set("address", "");
			cleared++;
			return true;
		};
		for(const ss_ &name : store("ids")->list("")){
			json::Value id = load("ids", name);
			bool changed = false;
			// 10b: a year that has reached 18 is dropped for "18 or over"
			if(!id.get("adult").is_true() && age_low(id) >= 18){
				id.set("adult", true);
				id.del_key("birth_year");
				id.del_key("consent");
				changed = true;
			}
			json::Value recent = id.get("recent");
			for(unsigned i = 0; recent.is_array() && i < recent.size(); i++)
				changed |= clear_old(recent[i]);
			if(recent.is_array())
				id.set("recent", recent);
			if(changed)
				put("ids", name, id);
		}
		for(const ss_ &k : store("sessions")->list("")){
			json::Value s = load("sessions", k);
			if(jint(s, "expires") < t)
				store("sessions")->remove(k);
			else if(clear_old(s))
				put("sessions", k, s);
		}
		// A delisting for a time runs out
		for(auto &p : listings()){
			const int64_t until = jint(p.second, "status_until");
			if(until > 0 && until <= t){
				const ss_ &id = p.first;
				json::Value l = p.second;
				l.set("status", "active");
				l.set("status_until", (int64_t)0);
				put("listings", id, l);
			}
		}
		log_i(MODULE, "Daily: %d addresses cleared, %d listings gone", cleared,
				gone);
	}

	// -----------------------------------------------------------------------
	// The app: moderators, operators and the admin ([STARPORT] 1, 2a, 6)

	ss_ account_of(network::PeerInfo::Id peer)
	{
		ss_ name;
		accounts::access(m_server, [&](accounts::Interface *a){
			name = a->name_of(peer);
		});
		return name;
	}
	bool is_admin(const ss_ &name)
	{
		return accounts::level(m_server, name) >= accounts::LV_ADMIN;
	}
	// A Steward or the Host in accounts' levels ([TRUST_LADDER])
	bool is_moderator(const ss_ &name)
	{
		return accounts::level(m_server, name) >= accounts::LV_MODERATOR;
	}

	void on_req(const network::Packet &packet)
	{
		const ss_ name = account_of(packet.sender);
		network::answer_request(m_server, packet, "sp:res", name,
				m_save ? "" : "Starport is not ready", [&](const json::Value &req){
			return handle(name, jstr(req, "cmd"), req);
		});
	}

	json::Value listing_summary(const json::Value &l)
	{
		json::Value s = json::object();
		for(const char *k : {"id", "name", "description", "host", "port",
				"app", "status", "owner", "verify", "players", "relabel",
				"fleet", "pool", "pool_mismatch",
				"status_until", "last_announce"})
			s.set(k, l.get(k));
		const json::Value e = effective(l);
		for(const char *k : {"kind", "audience", "access", "descriptors"})
			s.set(k, e.get(k));
		s.set("served", served_status(l));
		return s;
	}

	json::Value handle(const ss_ &name, const ss_ &cmd, const json::Value &q)
	{
		const bool mod = is_moderator(name);
		const bool admin = is_admin(name);
		if(cmd == "me")
			return cmd_me(name, mod, admin);
		// {name, level}: accounts' rules, one sets only below one's own
		if(cmd == "level"){
			ss_ why;
			accounts::access(m_server, [&](accounts::Interface *a){
				why = a->set_level(jstr(q, "name"), jint(q, "level"), name);
			});
			if(!why.empty())
				throw Exception(why);
			return json::Value(true);
		}
		if(cmd == "set_email")
			return cmd_set_email(name, jstr(q, "email"));
		if(cmd == "confirm_email")
			return cmd_confirm_email(name, jstr(q, "code"));
		if(cmd == "claim")
			return cmd_claim(name, q);
		if(cmd == "fleet_create" || cmd == "fleet_update" ||
				cmd == "fleet_new_code")
			return cmd_fleet(name, cmd, q);
		if(cmd == "fleet_remove_server")
			return cmd_fleet_remove_server(name, q);
		if(cmd == "site_create" || cmd == "site_update" ||
				cmd == "site_new_secret" || cmd == "site_remove")
			return cmd_site(name, cmd, q);
		if(cmd.compare(0, 10, "blocklist_") == 0 || cmd == "blocklists")
			return cmd_blocklist(name, cmd, q);
		if(cmd == "appeal"){
			ss_ id;
			mod_do([&](moderation::Interface *m){
				id = m->appeal(this, name, q);
			});
			return json::Value(id);
		}
		if(cmd == "overview"){
			// The events, and the time they were last seen, which moves on
			json::Value r = json::object();
			const json::Value seen = load("seen", name);
			r.set("seen", jint(seen, "ts"));
			r.set("events", events_for(name, mod, admin, 100));
			json::Value now = json::object();
			now.set("ts", now_s());
			put("seen", name, now);
			return r;
		}
		if(!mod)
			throw Exception("for moderators");
		json::Value r;
		if(cmd == "queue"){
			mod_do([&](moderation::Interface *m){ r = m->queue(this); });
			return r;
		}
		if(cmd == "group")
			return cmd_group(jstr(q, "group"));
		if(cmd == "decide"){
			mod_do([&](moderation::Interface *m){ m->decide(this, name, q); });
			return json::Value(true);
		}
		if(cmd == "act")
			return cmd_act(name, q);
		if(cmd == "listings")
			return cmd_listings(jstr(q, "search"));
		if(cmd == "audit"){
			mod_do([&](moderation::Interface *m){ r = m->audit_log(this); });
			return r;
		}
		if(cmd == "appeals"){
			mod_do([&](moderation::Interface *m){ r = m->appeals(this); });
			return r;
		}
		if(cmd == "decide_appeal"){
			mod_do([&](moderation::Interface *m){
				m->decide_appeal(this, name, q);
			});
			return json::Value(true);
		}
		if(cmd == "suspend_id"){
			mod_do([&](moderation::Interface *m){
				suspend_id(m, name, jstr(q, "id"), jint(q, "days"),
						jstr(q, "reason", "other"), jstr(q, "text"));
			});
			return json::Value(true);
		}
		if(!admin)
			throw Exception("for the admin");
		if(cmd == "settings")
			return all_settings();
		if(cmd == "set_settings")
			return cmd_set_settings(name, q);
		if(cmd == "trust_reporter")
			return cmd_trust_reporter(q);
		throw Exception("no such command: "+cmd);
	}

	json::Value cmd_me(const ss_ &name, bool mod, bool admin)
	{
		json::Value r = json::object();
		r.set("name", name);
		r.set("moderator", mod);
		r.set("admin", admin);
		// [STARPORT_COPY_IDS]: the Starport server's own version, for a
		// label in the client's navigation bar (no hash)
		r.set("version", ss_(BUILDAT_VERSION));
		const json::Value o = load("operators", name);
		r.set("email", o.is_object() ? jstr(o, "email") : ss_());
		r.set("email_pending", o.is_object() ? jstr(o, "email_pending") :
				ss_());
		r.set("email_confirmation", setting("email_confirmation").is_true());
		json::Value ls = json::array();
		for(auto &p : listings()){
			const json::Value &l = p.second;
			if(jstr(l, "owner") == name)
				ls.append(listing_summary(l));
		}
		r.set("listings", ls);
		json::Value st = json::array();
		for(const ss_ &id : store("statements")->list("")){
			const json::Value s = load("statements", id);
			if(jstr(s, "owner") == name)
				st.append(s);
		}
		r.set("statements", st);
		json::Value fleets = json::array();
		for(const ss_ &id : store("fleets")->list("")){
			const json::Value f = load("fleets", id);
			if(jstr(f, "owner") == name)
				fleets.append(f);
		}
		r.set("fleets", fleets);
		json::Value sites = json::array();
		for(const ss_ &id : store("sites")->list("")){
			const json::Value f = load("sites", id);
			if(jstr(f, "owner") == name)
				sites.append(f);
		}
		r.set("sites", sites);
		r.set("starport", jstr(m_settings, "name"));
		// The Overview's ([STARPORT_UI]): the notice, the standing, what
		// waits, and how many events are unseen
		r.set("notice", setting("notice"));
		const json::Value id = load("ids", name);
		r.set("suspended_until", jint(id, "suspended_until"));
		r.set("suspended", jint(id, "suspended_until") > now_s());
		bool totp = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			totp = a->totp_on(name);
		});
		r.set("totp", totp);
		std::set<ss_> appealed;
		int64_t open_appeals = 0;
		for(const ss_ &aid : store("appeals")->list("")){
			const json::Value a = load("appeals", aid);
			if(jstr(a, "by") == name)
				appealed.insert(jstr(a, "statement"));
			open_appeals += jstr(a, "state") == "open";
		}
		for(unsigned i = 0; i < st.size(); i++){
			json::Value x = st.at(i);
			x.set("appealed", appealed.count(jstr(x, "id")) > 0);
			st.set_at(i, x);
		}
		r.set("statements", st);
		int64_t offers = 0;
		for(const ss_ &bid : store("blocklists")->list("")){
			const json::Value b = load("blocklists", bid);
			if(jstr(b, "owner") == name && b.get("offers").is_array())
				offers += b.get("offers").size();
		}
		r.set("blocklist_offers", offers);
		if(mod){
			int64_t groups = 0;
			mod_do([&](moderation::Interface *m){
				groups = m->open_groups(this).size();
			});
			r.set("queue", groups);
			r.set("open_appeals", open_appeals);
		}
		const int64_t seen = jint(load("seen", name), "ts");
		const json::Value ev = events_for(name, mod, admin, 100);
		int64_t unseen = 0;
		for(unsigned i = 0; i < ev.size(); i++)
			unseen += jint(ev.at(i), "ts") > seen;
		r.set("unseen_events", unseen);
		return r;
	}

	// "set" when taken as given, "sent" when a code went to it
	json::Value cmd_set_email(const ss_ &name, const ss_ &email)
	{
		// Goes into a mail's header: one address, nothing that ends a line
		const size_t at = email.find('@');
		if(email.size() > 200 || at == ss_::npos || at == 0 ||
				at != email.rfind('@') || at + 1 == email.size() ||
				email.find_first_of(" \t\r\n<>,;\"()") != ss_::npos)
			throw Exception("an e-mail address");
		json::Value o = load("operators", name);
		if(!o.is_object())
			o = json::object();
		if(!setting("email_confirmation").is_true()){
			o.set("email", email);
			o.set("email_pending", "");
			put("operators", name, o);
			return json::Value("set");
		}
		if(!interface::mail_supported())
			throw Exception("this Starport's libcurl cannot send mail (a "
					"minimal build): its admin installs a full one, or turns "
					"email_confirmation off");
		if(!can_mail())
			throw Exception("this Starport cannot send mail: its admin sets "
					"the mail server (Admin, Health), or turns "
					"email_confirmation off");
		if(!m_rates.ok("mail", name, 3, 3600))
			throw Exception("three codes an hour; try later");
		const ss_ code = random_hex(4);
		o.set("email_pending", email);
		o.set("email_code", code);
		o.set("email_code_ts", now_s());
		put("operators", name, o);
		const ss_ sp = jstr(m_settings, "name");
		mail(name, email, sp+": confirming your e-mail address",
				"The account "+name+" on "+sp+" gave this address as its\n"
				"contact. To confirm it, enter this code there:\n"
				"\n"
				"    "+code+"\n"
				"\n"
				"If that was not you, nothing needs doing.\n");
		return json::Value("sent");
	}

	// Whether mail can go: the server's mail server ([SERVER_ADMIN_PAGE]),
	// and a libcurl that has SMTP
	bool can_mail()
	{
		bool ok = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			ok = a->can_mail();
		});
		return ok;
	}

	// A mail to an account's address, by builtin/accounts on a thread of
	// its own: a failure comes back holding copies only, as this module
	// may be gone before the mail server answers. `to` is an address
	// set_email let through: nothing in it ends a header line
	void mail(const ss_ &account, const ss_ &to, const ss_ &subject,
			const ss_ &text)
	{
		std::shared_ptr<MailFailures> failures = m_mail_failures;
		const ss_ who = account;
		accounts::access(m_server, [&](accounts::Interface *a){
			a->mail(to, subject, text, [=](const ss_ &error){
				if(error.empty())
					return;
				std::lock_guard<std::mutex> lock(failures->m);
				failures->lines.push_back("Mail to "+who+" failed: "+error);
			});
		});
	}

	json::Value cmd_confirm_email(const ss_ &name, const ss_ &code)
	{
		json::Value o = load("operators", name);
		if(!o.is_object() || jstr(o, "email_pending").empty())
			throw Exception("no address waiting for a code");
		if(now_s() - jint(o, "email_code_ts") > 86400)
			throw Exception("the code is over a day old; ask for another");
		if(!same(jstr(o, "email_code"), code))
			throw Exception("not the code");
		o.set("email", jstr(o, "email_pending"));
		o.set("email_pending", "");
		o.set("email_code", "");
		put("operators", name, o);
		return json::Value(true);
	}

	json::Value cmd_claim(const ss_ &name, const json::Value &q)
	{
		const json::Value o = load("operators", name);
		if(!o.is_object() || jstr(o, "email").empty())
			throw Exception("set your contact e-mail first");
		if(banned("account", name))
			throw Exception("this account may not claim listings");
		json::Value l = load("listings", jstr(q, "listing"));
		if(!l.is_object())
			throw Exception("no such listing");
		const ss_ code = hex(interface::sha256::hmac(unhex(jstr(l, "secret")),
				"buildat-claim-1\n")).substr(0, 16);
		if(!same(code, jstr(q, "code")))
			throw Exception("not its claim code");
		// A server with a new key: its old listing's record comes along
		const ss_ old = jstr(q, "replaces");
		if(!old.empty()){
			const json::Value ol = load("listings", old);
			if(!ol.is_object() || jstr(ol, "owner") != name)
				throw Exception("the listing replaced is not yours");
			for(const char *k : {"status", "status_until", "status_auto",
					"relabel", "strikes", "first_seen", "claimed"})
				if(!ol.get(k).is_undefined())
					l.set(k, ol.get(k));
			listing_remove(old);
			record(name, jstr(l, "id"), "replace", "replaces "+old, false);
		}
		l.set("owner", name);
		if(l.get("claimed").is_undefined())
			l.set("claimed", now_s());
		put("listings", jstr(l, "id"), l);
		record(name, jstr(l, "id"), "claim", "", false);
		return listing_summary(l);
	}

	// -- 10d. Bans shared: blocklists

	// A server's whole current set of reported bans: kept as its own, and
	// a ban new to it is a report about the ID for a moderator -- once:
	// a ban dropped and announced again is not news for 30 days
	// (ban_reported, a key a listing and an identity this Starport gave
	// in its scope; simplified: not pruned, bounded by those identities)
	void take_bans(const json::Value &l, const json::Value &bans)
	{
		if(!bans.is_array())
			return;
		const ss_ scope = id_scope_of(l);
		const json::Value old = load("listing_bans", jstr(l, "id"));
		std::set<ss_> was;
		for(unsigned j = 0; old.is_array() && j < old.size(); j++)
			was.insert(jstr(old.at(j), "sub"));
		json::Value now = json::array();
		for(unsigned i = 0; i < bans.size() && i < 10000; i++){
			const json::Value &x = bans.at(i);
			const ss_ sub = jstr(x, "sub");
			const json::Value who = load("subs", scope+"|"+sub);
			if(!who.is_string())
				continue; // not an identity this Starport gave
			json::Value e = json::object();
			e.set("sub", sub);
			e.set("name", who.as_string());
			ss_ reason = jstr(x, "reason");
			e.set("reason", reason);
			now.append(e);
			if(was.count(sub))
				continue;
			const ss_ rkey = jstr(l, "id")+"|"+sub;
			const json::Value seen = load("ban_reported", rkey);
			if(seen.is_object() && now_s() - jint(seen, "ts") < 30 * 86400)
				continue;
			json::Value mark = json::object();
			mark.set("ts", now_s());
			put("ban_reported", rkey, mark);
			if(!in_set(reason, REASONS))
				reason = "other";
			json::Value rep = json::object();
			const ss_ rid = random_hex(8);
			rep.set("id", rid);
			rep.set("listing", jstr(l, "id"));
			rep.set("reason", reason);
			rep.set("text", "banned on "+jstr(l, "name")+" ("+
					jstr(l, "id")+"), reported by the server");
			rep.set("key", "");
			rep.set("address", "");
			rep.set("ts", now_s());
			rep.set("trusted", false);
			rep.set("weight", 1.0);
			rep.set("state", "open");
			rep.set("group", "id:"+who.as_string()+"|"+reason);
			json::Value fields = json::object();
			fields.set("id_name", who.as_string());
			mod_do([&](moderation::Interface *m){
				m->add_report(this, rep, fields);
			});
		}
		put("listing_bans", jstr(l, "id"), now);
	}

	// The IDs a list bans: its publishers' current bans
	std::set<ss_> list_bans(const json::Value &list)
	{
		std::set<ss_> names;
		const json::Value &pubs = list.get("publishers");
		for(const ss_ &lid : store("listing_bans")->list("")){
			const json::Value ol = load("listings", lid);
			bool published = false;
			for(unsigned i = 0; pubs.is_array() && i < pubs.size(); i++){
				const ss_ p = pubs.at(i).as_string();
				published |= p == scope_of(ol) || p == "listing:"+lid;
			}
			if(!published)
				continue;
			const json::Value bans = load("listing_bans", lid);
			for(unsigned i = 0; bans.is_array() && i < bans.size(); i++)
				names.insert(jstr(bans.at(i), "name"));
		}
		return names;
	}

	// What a listing's server keeps out: the bans of the lists it
	// subscribes to, each as the identity it has in that server's fleet
	json::Value blocked_for(const json::Value &l)
	{
		const ss_ scope = scope_of(l);
		std::set<ss_> names;
		for(const ss_ &id : store("blocklists")->list("")){
			const json::Value list = load("blocklists", id);
			const json::Value &subs = list.get("subscribers");
			bool sub = false;
			for(unsigned i = 0; subs.is_array() && i < subs.size(); i++){
				const ss_ s = subs.at(i).as_string();
				sub |= s == scope || s == "listing:"+jstr(l, "id");
			}
			if(sub)
				for(const ss_ &n : list_bans(list))
					names.insert(n);
		}
		json::Value out = json::array();
		for(const ss_ &n : names)
			out.append(sub_of(n, id_scope_of(l)));
		return out;
	}

	// The names of the blocklists a listing's server follows
	json::Value subscribed_names(const json::Value &l)
	{
		json::Value out = json::array();
		for(const ss_ &id : store("blocklists")->list("")){
			const json::Value list = load("blocklists", id);
			const json::Value &subs = list.get("subscribers");
			for(unsigned i = 0; subs.is_array() && i < subs.size(); i++){
				const ss_ s = subs.at(i).as_string();
				if(s == scope_of(l) || s == "listing:"+jstr(l, "id")){
					out.append(jstr(list, "name"));
					break;
				}
			}
		}
		return out;
	}

	// Whether `scope` ("fleet:<id>" or "listing:<id>") is the account's
	bool owns_scope(const ss_ &name, const ss_ &scope)
	{
		if(scope.compare(0, 6, "fleet:") == 0)
			return jstr(load("fleets", scope.substr(6)), "owner") == name;
		if(scope.compare(0, 8, "listing:") == 0)
			return jstr(load("listings", scope.substr(8)), "owner") == name;
		return false;
	}

	static json::Value without(const json::Value &arr, const ss_ &x)
	{
		json::Value out = json::array();
		for(unsigned i = 0; arr.is_array() && i < arr.size(); i++)
			if(arr.at(i).as_string() != x)
				out.append(arr.at(i));
		return out;
	}
	static json::Value with(const json::Value &arr, const ss_ &x)
	{
		json::Value out = without(arr, x);
		out.append(x);
		return out;
	}

	// Lists are public within the Starport: anyone subscribes their own
	// servers to any. Publishing to another's list is offered by the
	// server's owner and accepted by the list's
	json::Value cmd_blocklist(const ss_ &name, const ss_ &cmd,
			const json::Value &q)
	{
		if(cmd == "blocklists"){
			json::Value out = json::array();
			for(const ss_ &id : store("blocklists")->list("")){
				json::Value list = load("blocklists", id);
				list.set("bans", (int64_t)list_bans(list).size());
				out.append(list);
			}
			return out;
		}
		if(cmd == "blocklist_create"){
			const ss_ lname = jstr(q, "name");
			if(lname.empty() || lname.size() > 60)
				throw Exception("name: 1 to 60 characters");
			if(banned("account", name))
				throw Exception("this account may not make blocklists");
			int n = 0;
			for(const ss_ &id : store("blocklists")->list(""))
				n += jstr(load("blocklists", id), "owner") == name;
			if(n >= 20)
				throw Exception("20 blocklists an account");
			json::Value list = json::object();
			list.set("id", random_hex(6));
			list.set("name", lname);
			list.set("owner", name);
			list.set("publishers", json::array());
			list.set("offers", json::array());
			list.set("subscribers", json::array());
			put("blocklists", jstr(list, "id"), list);
			return list;
		}
		json::Value list = load("blocklists", jstr(q, "list"));
		if(!list.is_object())
			throw Exception("no such blocklist");
		const ss_ scope = jstr(q, "scope");
		const bool own_list = jstr(list, "owner") == name;
		if(cmd == "blocklist_accept" || cmd == "blocklist_drop"){
			if(!own_list)
				throw Exception("not your blocklist");
			// A publisher's bans reach the list's subscribers: only what
			// its owner offered
			if(cmd == "blocklist_accept" &&
					without(list.get("offers"), scope).size() ==
					list.get("offers").size())
				throw Exception("no such offer");
			list.set("offers", without(list.get("offers"), scope));
			const size_t colon = scope.find(':');
			const ss_ kind = scope.substr(0, colon), sid = colon ==
					ss_::npos ? "" : scope.substr(colon + 1);
			const ss_ offerer = jstr(load(kind == "fleet" ? "fleets" :
					"listings", sid), "owner");
			if(!offerer.empty())
				event({offerer}, name, "Your offer of "+scope+" to the "
						"blocklist "+jstr(list, "name")+" was "+
						(cmd == "blocklist_accept" ? "accepted" : "refused"));
			if(cmd == "blocklist_accept")
				list.set("publishers", with(list.get("publishers"), scope));
			else
				list.set("publishers", without(list.get("publishers"), scope));
		} else {
			if(!owns_scope(name, scope))
				throw Exception("scope: fleet:<id> or listing:<id> of yours");
			if(cmd == "blocklist_publish"){
				if(own_list)
					list.set("publishers", with(list.get("publishers"),
							scope));
				else
					list.set("offers", with(list.get("offers"), scope));
			} else if(cmd == "blocklist_unpublish"){
				list.set("publishers", without(list.get("publishers"), scope));
				list.set("offers", without(list.get("offers"), scope));
			} else if(cmd == "blocklist_subscribe"){
				list.set("subscribers", q.get("on").is_false() ?
						without(list.get("subscribers"), scope) :
						with(list.get("subscribers"), scope));
			} else
				throw Exception("no such command: "+cmd);
		}
		put("blocklists", jstr(list, "id"), list);
		return list;
	}

	// A Starport moderator's suspension of an ID, with its statement (6)
	void suspend_id(moderation::Interface *m, const ss_ &by,
			const ss_ &idname, int64_t days, const ss_ &reason,
			const ss_ &text)
	{
		json::Value id = load("ids", idname);
		if(!id.is_object())
			throw Exception("no such ID");
		id.set("suspended_until", days > 0 ? now_s() + days * 86400 :
				(int64_t)4102444800LL);
		put("ids", idname, id);
		for(const ss_ &k : store("sessions")->list(""))
			if(jstr(load("sessions", k), "name") == idname)
				store("sessions")->remove(k);
		m->audit(this, by, "id:"+idname, "suspend", reason, text, false);
		json::Value fake = json::object();
		fake.set("id", "id:"+idname);
		fake.set("name", "Starport ID "+idname);
		fake.set("owner", idname);
		m->statement(this, fake, days > 0 ? "suspended for "+itos(days)+" days" :
				"suspended", reason, text, by);
	}

	// -- 2b. An operator's fleets: made, renamed, a new code

	json::Value cmd_fleet(const ss_ &name, const ss_ &cmd, const json::Value &q)
	{
		json::Value f;
		if(cmd == "fleet_create"){
			const json::Value o = load("operators", name);
			if(!o.is_object() || jstr(o, "email").empty())
				throw Exception("set your contact e-mail first");
			if(banned("account", name))
				throw Exception("this account may not make fleets");
			int n = 0;
			for(const ss_ &id : store("fleets")->list(""))
				n += jstr(load("fleets", id), "owner") == name;
			if(n >= 20)
				throw Exception("20 fleets an account");
			f = json::object();
			f.set("id", random_hex(6));
			f.set("owner", name);
			f.set("code", random_hex(8));
			f.set("scope", ""); // [FLEET_SUB_CARRY]: the first listing's
		} else {
			f = load("fleets", jstr(q, "fleet"));
			if(!f.is_object() || jstr(f, "owner") != name)
				throw Exception("no such fleet of yours");
			if(cmd == "fleet_new_code")
				f.set("code", random_hex(8));
		}
		if(cmd != "fleet_new_code"){
			const ss_ fname = jstr(q, "name");
			if(fname.empty() || fname.size() > 60)
				throw Exception("name: 1 to 60 characters");
			if(jstr(q, "description").size() > 500 || jstr(q, "link").size() > 200)
				throw Exception("description: at most 500 characters, link 200");
			f.set("name", fname);
			f.set("description", jstr(q, "description"));
			f.set("link", jstr(q, "link"));
		}
		put("fleets", jstr(f, "id"), f);
		record(name, "", cmd, "fleet "+jstr(f, "id"), false);
		return f;
	}

	// [STARPORT_SITE_LOGIN] An operator's websites: a site signs its
	// visitors in by a Starport ID as a web client does a server's
	// (/authorize?site=<id>), the token by postMessage to its origin only,
	// signed with its secret, an identity of its own as a fleet's
	static bool origin_ok(const ss_ &o)
	{
		const size_t sep = o.find("://");
		if(o.size() > 200 || sep == ss_::npos ||
				(o.substr(0, sep) != "https" && o.substr(0, sep) != "http"))
			return false;
		const ss_ rest = o.substr(sep + 3);
		if(rest.empty() || rest[0] == ':')
			return false;
		for(char c : rest)
			if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
					c == '.' || c == '-' || c == ':'))
				return false;
		return true;
	}
	json::Value cmd_site(const ss_ &name, const ss_ &cmd, const json::Value &q)
	{
		json::Value f;
		if(cmd == "site_create"){
			const json::Value o = load("operators", name);
			if(!o.is_object() || jstr(o, "email").empty())
				throw Exception("set your contact e-mail first");
			if(banned("account", name))
				throw Exception("this account may not register sites");
			int n = 0;
			for(const ss_ &id : store("sites")->list(""))
				n += jstr(load("sites", id), "owner") == name;
			if(n >= 20)
				throw Exception("20 sites an account");
			f = json::object();
			f.set("id", random_hex(6));
			f.set("owner", name);
			f.set("secret", random_hex(32));
		} else {
			f = load("sites", jstr(q, "site"));
			if(!f.is_object() || jstr(f, "owner") != name)
				throw Exception("no such site of yours");
			if(cmd == "site_remove"){
				store("sites")->remove(jstr(f, "id"));
				record(name, "", cmd, "site "+jstr(f, "id"), false);
				return json::Value(true);
			}
			if(cmd == "site_new_secret")
				f.set("secret", random_hex(32));
		}
		if(cmd != "site_new_secret"){
			const ss_ sname = jstr(q, "name"), origin = jstr(q, "origin");
			if(sname.empty() || sname.size() > 60)
				throw Exception("name: 1 to 60 characters");
			if(!origin_ok(origin))
				throw Exception("origin: https://host[:port], no path, in "
						"lower case");
			f.set("name", sname);
			f.set("origin", origin);
		}
		put("sites", jstr(f, "id"), f);
		record(name, "", cmd, "site "+jstr(f, "id"), false);
		return f;
	}

	json::Value cmd_fleet_remove_server(const ss_ &name, const json::Value &q)
	{
		json::Value l = load("listings", jstr(q, "listing"));
		const json::Value f = load("fleets", jstr(l, "fleet"));
		if(!l.is_object() || jstr(f, "owner") != name)
			throw Exception("no such server in a fleet of yours");
		l.set("fleet_removed", jstr(l, "fleet"));
		set_fleet(l, "");
		l.set("pool", "");
		put("listings", jstr(l, "id"), l);
		return listing_summary(l);
	}

	json::Value cmd_group(const ss_ &gid)
	{
		json::Value r;
		mod_do([&](moderation::Interface *m){ r = m->group(this, gid); });
		const json::Value g = r.get("group");
		// An ID's: its age band and whether it is suspended, nothing more
		if(!jstr(g, "id_name").empty()){
			const json::Value id = load("ids", jstr(g, "id_name"));
			json::Value x = json::object();
			x.set("name", jstr(g, "id_name"));
			x.set("band", id.is_object() ? band(id) : "deleted");
			x.set("suspended_until", jint(id, "suspended_until"));
			r.set("id", x);
		}
		const json::Value l = load("listings", jstr(g, "listing"));
		if(l.is_object())
			r.set("listing", listing_summary(l));
		return r;
	}

	// A moderator's action on a listing ([STARPORT] 6): relabel, hide,
	// delist (for days, or until review), ban, or for plainly illegal
	// content delist at once and keep what the reports carried
	void apply_action(moderation::Interface *m, const ss_ &by, json::Value l,
			const json::Value &q, const ss_ &reason)
	{
		const ss_ type = jstr(q, "action");
		const ss_ text = jstr(q, "text");
		const ss_ id = jstr(l, "id");
		if(type == "relabel"){
			const json::Value &fields = q.get("fields");
			if(!fields.is_object())
				throw Exception("fields: what to set");
			json::Value rl = l.get("relabel").is_object() ?
					l.get("relabel").deepcopy() : json::object();
			for(json::Iterator it(fields); it.valid(); it.next())
				rl.set(it.key(), it.value());
			l.set("relabel", rl);
			if(jstr(l, "status") == "hidden" && l.get("status_auto").is_true())
				l.set("status", "active");
		} else if(type == "hide"){
			l.set("status", "hidden");
		} else if(type == "delist" || type == "csam"){
			l.set("status", "delisted");
			const int64_t days = jint(q, "days");
			l.set("status_until", days > 0 ? now_s() + days * 86400 :
					(int64_t)0);
			json::Value strikes = l.get("strikes").deepcopy();
			strikes.append(now_s());
			l.set("strikes", strikes);
			repeat_offender(l);
		} else if(type == "ban"){
			l.set("status", "banned");
			const int64_t days = jint(q, "days");
			const int64_t until = days > 0 ? now_s() + days * 86400 : 0;
			ban("listing", id, until, by);
			ban("address", jstr(l, "host"), until, by);
			if(q.get("ban_account").is_true() && !jstr(l, "owner").empty())
				ban("account", jstr(l, "owner"), until, by);
		} else if(type == "restore"){
			l.set("status", "active");
			l.set("status_until", (int64_t)0);
		} else
			throw Exception("action: relabel, hide, delist, csam, ban or "
					"restore");
		l.set("status_auto", false);
		put("listings", id, l);
		if(type == "csam"){
			// Kept apart from the retention's clearing, for the authorities
			// the instance's law says to tell
			json::Value keep = json::object();
			keep.set("listing", l);
			keep.set("ts", now_s());
			keep.set("by", by);
			put("preserved", id+"-"+itos(now_s()), keep);
		}
		m->audit(this, by, id, type, reason, text, false);
		m->statement(this, l, type, reason, text, by);
	}

	void ban(const ss_ &kind, const ss_ &what, int64_t until, const ss_ &by)
	{
		if(what.empty())
			return;
		json::Value b = json::object();
		b.set("until", until);
		b.set("by", by);
		b.set("ts", now_s());
		put("bans", kind+":"+what, b);
	}

	// An operator whose listings are delisted again and again may not
	// announce for a while ([STARPORT] 6)
	void repeat_offender(const json::Value &l)
	{
		const ss_ owner = jstr(l, "owner");
		if(owner.empty())
			return;
		int n = 0;
		const int64_t t = now_s();
		for(auto &p : listings()){
			const json::Value &o = p.second;
			if(jstr(o, "owner") != owner)
				continue;
			const json::Value &s = o.get("strikes");
			for(unsigned i = 0; s.is_array() && i < s.size(); i++)
				if(t - s.at(i).as_integer() < 90 * 86400)
					n++;
		}
		if(n >= 3){
			ban("account", owner, t + 30 * 86400, "Starport");
			log_i(MODULE, "%s: delisted %d times in 90 days; barred for 30 days",
					cs(owner), n);
		}
	}

	json::Value cmd_act(const ss_ &by, const json::Value &q)
	{
		if(!jstr(q, "fleet").empty()){
			const ss_ reason = jstr(q, "reason");
			if(!in_set(reason, REASONS))
				throw Exception("reason: one of the report reasons");
			json::Value g = json::object();
			g.set("fleet", jstr(q, "fleet"));
			const sv_<ss_> members = members_of(g);
			if(members.empty())
				throw Exception("no servers in that fleet");
			mod_do([&](moderation::Interface *m){
				for(const ss_ &id : members)
					apply_action(m, by, load("listings", id), q, reason);
			});
			return json::Value((int64_t)members.size());
		}
		json::Value l = load("listings", jstr(q, "listing"));
		if(!l.is_object())
			throw Exception("no such listing");
		const ss_ reason = jstr(q, "reason");
		if(!in_set(reason, REASONS))
			throw Exception("reason: one of the report reasons");
		mod_do([&](moderation::Interface *m){
			apply_action(m, by, l, q, reason);
		});
		return listing_summary(load("listings", jstr(q, "listing")));
	}

	json::Value cmd_listings(const ss_ &search)
	{
		json::Value out = json::array();
		ss_ s = search;
		std::transform(s.begin(), s.end(), s.begin(), ::tolower);
		for(auto &p : listings()){
			const ss_ &id = p.first;
			const json::Value &l = p.second;
			ss_ hay = jstr(l, "name")+" "+jstr(l, "id")+" "+jstr(l, "owner")+
					" "+jstr(l, "host");
			std::transform(hay.begin(), hay.end(), hay.begin(), ::tolower);
			if(s.empty() || hay.find(s) != ss_::npos)
				out.append(listing_summary(l));
			if(out.size() >= 200)
				break;
		}
		return out;
	}

	// The key that made a report becomes a trusted flagger's ([STARPORT]
	// 6), and nobody had to see its hash
	json::Value cmd_trust_reporter(const json::Value &q)
	{
		const json::Value rep = load("reports", jstr(q, "report"));
		const ss_ h = jstr(rep, "key");
		if(h.empty())
			throw Exception("no such report, or it was made without a key");
		if(trusted(h))
			return json::Value(false);
		json::Value next = m_settings.deepcopy();
		json::Value t = setting("trusted_flaggers").deepcopy();
		if(!t.is_array())
			t = json::array();
		t.append(h);
		next.set("trusted_flaggers", t);
		m_settings = next;
		put("settings", "settings", m_settings);
		return json::Value(true);
	}

	json::Value cmd_set_settings(const ss_ &by, const json::Value &q)
	{
		const json::Value &s = q.get("settings");
		if(!s.is_object())
			throw Exception("settings: an object");
		json::Value next = m_settings.deepcopy();
		for(json::Iterator it(s); it.valid(); it.next()){
			const ss_ k = it.key();
			if(default_settings().get(k).is_undefined())
				throw Exception("no such setting: "+k);
			next.set(k, it.value());
			event({"@admins"}, by, by+" set "+k+" to "+
					it.value().stringify());
		}
		m_settings = next;
		put("settings", "settings", m_settings);
		return all_settings();
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
