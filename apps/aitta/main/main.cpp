// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// **Aitta** ([AITTA_MVP], doc/plan/aitta_plan.md): a registry of buildat
// apps, as an app. An author joins it (builtin/accounts: a local account
// or a Starport ID, as the server's admin set up its logins) and binds an
// author name to their key; `bin/buildat aitta publish` uploads a signed
// release; Aitta checks it and lists it, unreviewed. The server's
// moderators and admins review it ([AITTA_REVIEW], below): reviewed, needs
// changes, relabelled or delisted, its "review" in the list. Anyone
// reports a release ([AITTA_REPORTS]); the moderators decide through
// builtin/moderation, the author told and able to appeal. The admin can
// delist.
//
// The HTTP API, under /api/aitta/ on the server's port, JSON out, a
// refusal {"ok": false, "error": ...} with status 200:
//   GET  list                       the listed releases, and "delisted":
//                                   those out of it, each with why
//   GET  info?key=<public key>      the licences taken here, and the
//                                   author the key is bound to ("" for
//                                   none): what the client's publish
//                                   screen asks ([AITTA_PUBLISH_UI])
//   GET  release?id=author/name/version  one, with its changelog's text
//                                   ([PACKAGE_SUBJECT]: what a Hearth
//                                   posts as the release's thread)
//   GET  archive/<sha256>.zip|.sig  a release's two files; ?ticket= a
//                                   reviewer's playtest's, once each, of
//                                   a release not listed too
//   POST upload_begin?size=N        body: the release's .sig. Its key must
//                                   be bound to an author, and the
//                                   signature good for the hash it names.
//   POST upload_part?sha256=&offset=  body: the next bytes, 60000 at most
//   POST upload_end?sha256=         the checks, and the listing
//   POST report                     {release, reason, text, key}: a
//                                   report, its receipt; or the package
//                                   page's form, urlencoded
//   POST report_status              {key, receipts}: their outcomes
// And a browser's pages ([FRONT_PAGES]), the web client at /app:
//   GET  /                          each package's latest release
//   GET  /p/<author>/<name>         a package's listed releases
//   GET  /brand/<file>              the pages' font and logo
// In the app, "ai:req" carries a JSON {id, cmd, ...} from a joined client
// and "ai:res" the answer {id, ok, result | error}.
//
// The records are in the save "aitta": stores authors (author -> its key
// and account), keys (key -> author), owners (account -> author),
// releases ("author/name/version" -> the manifest's fields, sha256, size,
// key, time, delisted, review, review_note, reviewed_by, playtested_by),
// changelogs (the same key -> {text}), relabels (author/name -> the
// audience a reviewer set), reporters (a report key's hash -> its
// record), settings, and builtin/moderation's reports, groups, audit,
// statements and appeals. The archives are files, by hash, in
// <user>/apps/<app>/archives.
#include "core/log.h"
#include "core/json.h"
#include "interface/os.h"
#include "interface/process.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/sha256.h"
#include "interface/aitta.h"
#include "interface/zip.h"
#include "interface/bignum.h"
#include "interface/web_brand.h"
#include "client_file/api.h"
#include "network/api.h"
#include "storage/api.h"
#include "accounts/api.h"
#include "moderation/api.h"
#include <ctime>
#include <map>
#include <set>
#include <algorithm>
#include <fstream>
#include <sstream>

using json::jstr;
using interface::sha256::is_hex;

#define MODULE "main"

using interface::Event;

// [SIM_CLOCK]: the calendar, which a check may move
static int64_t now_s(){ return interface::os::wall_us() / 1000000; }
// [REWORK_FIXES] Requests a minute per network (network::address_bin: a
// v4 /24, a v6 /64): reads (pages, lists, archives) and uploads.
// simplified: per network; many networks get many times it
static const int READS_A_MINUTE = 240;
static const int UPLOADS_A_MINUTE = 30;

// An author name: what a manifest's "author" may be
static bool plain_name(const ss_ &s)
{
	if(s.empty() || s.size() > 40)
		return false;
	for(char c : s)
		if(!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
			return false;
	return true;
}

// [AITTA_REPORTS] What a release is reported for: Starport's reasons and
// Aitta's own (malware, licence, broken), each its severity in the queue
static const std::map<ss_, int> REASONS = {
	{"csam", 100}, {"malware", 90}, {"illegal", 80}, {"scam", 60},
	{"harassment", 50}, {"impersonation", 40}, {"licence", 30},
	{"category", 20}, {"broken", 10}, {"spam", 10}, {"other", 5},
};
// And what a person reads for each, in the order a form offers them
static const char *const REASON_NAMES[][2] = {
	{"malware", "Malware or harmful code"}, {"licence", "Licence or "
	"copyright violation"}, {"broken", "Broken"}, {"category", "Wrong "
	"audience"}, {"illegal", "Illegal content"}, {"csam", "Child sexual "
	"abuse material"}, {"harassment", "Harassment or abuse"}, {"scam",
	"Scam or phishing"}, {"impersonation", "Impersonation"}, {"spam",
	"Spam"}, {"other", "Other"},
};

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	std::ostringstream os;
	os<<f.rdbuf();
	return os.str();
}

static bool write_file(const ss_ &path, const ss_ &data)
{
	std::ofstream f(path, std::ios::binary);
	f<<data;
	return f.good();
}

// The licences the official instance takes ([AITTA] decision 2): free
// ones. An instance changes the list in its settings.
static json::Value default_settings()
{
	json::Value s = json::object();
	json::Value l = json::array();
	for(const char *n : {"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause",
			"ISC", "Zlib", "MPL-2.0", "GPL-2.0", "GPL-3.0", "LGPL-2.1",
			"LGPL-3.0", "AGPL-3.0", "Unlicense", "CC0-1.0", "CC-BY-3.0",
			"CC-BY-4.0", "CC-BY-SA-3.0", "CC-BY-SA-4.0"})
		l.append(n);
	s.set("licences", l);
	s.set("max_size", (int64_t)50 * 1000 * 1000);
	// Seconds before a package's next release is listed (http_list)
	s.set("update_delay", (int64_t)0);
	// [FRONT_PAGES]: seconds a release is listed before the page at /
	// shows it, so it can be delisted first
	s.set("page_delay", (int64_t)3600);
	// [AITTA_SERVE] This Aitta's address as its pages give it in the
	// commands; "" for the request's own host
	s.set("public_url", "");
	// [AITTA_SERVERLESS] The play server's page a serverless package's
	// "Play in the browser" opens, <play_url>/#run=<author>/<name>; ""
	// for no link
	s.set("play_url", "");
	// [AITTA_HOSTING_LINK] A hosting provider's address: each app's
	// "Host at <domain>" link, <provider>?aitta=<this>&package=<a>/<n>;
	// "" for none
	s.set("app_hosting_provider", "");
	// [AITTA_REPORTS] What a report weighs: anonymous, and with the
	// client's report key (times its record of upheld and rejected ones).
	// simplified: a Starport ID's standing is not asked; a key is a key
	s.set("anon_weight", 0.01);
	s.set("key_weight", 0.1);
	// A release reported past "hide" is out of the list until a moderator
	// looks, past "delist" delisted; malware and CSAM at once
	json::Value th = json::object(), d = json::object(),
			now = json::object();
	d.set("hide", 3.0);
	d.set("delist", 6.0);
	now.set("hide", 1.0);
	now.set("delist", 2.0);
	th.set("default", d);
	th.set("malware", now);
	th.set("csam", now);
	s.set("thresholds", th);
	return s;
}

// [AITTA_PAGE_TEXT] The pages' footer link into the client
static const char *MANAGE = "Manage your published apps";

struct Upload {
	json::Value sig;
	ss_ author;
	size_t size = 0;
	ss_ data;
	int64_t started = 0;
};

struct Module: public interface::Module, public moderation::Host
{
	interface::Server *m_server;
	storage::Save *m_save = nullptr;
	json::Value m_settings;
	ss_ m_archives;
	ss_ m_tmp;
	sm_<ss_, Upload> m_uploads; // by sha256
	network::RateTable m_hits;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("network:packet_received/ai:req"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:http_request", on_http, network::HttpRequest)
		EVENT_TYPEN("network:packet_received/ai:req", on_req, network::Packet)
	}

	storage::Store* store(const char *name){ return m_save->store(name); }
	json::Value load(const char *store_name, const ss_ &key)
	{
		ss_ text;
		if(!store(store_name)->get(key, text))
			return json::Value();
		return json::load_string(text.c_str());
	}
	void put(const char *store_name, const ss_ &key, const json::Value &v)
	{
		store(store_name)->set(key, v.stringify());
	}
	// A setting, its default where the save has none
	json::Value setting(const char *k)
	{
		const json::Value &v = m_settings.get(k);
		return v.is_undefined() ? default_settings().get(k) : v;
	}

	ss_ get(const char *store_name, const ss_ &key)
	{
		ss_ v;
		store(store_name)->get(key, v);
		return v;
	}

	void on_start()
	{
		// One user's clients at once, as in floorplanner
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_multiple_logins(true);
		});
		storage::access(m_server, [&](storage::Interface *s){
			m_save = s->open("aitta");
			if(!m_save)
				m_save = s->create("aitta");
		});
		if(!m_save)
			throw Exception("aitta: cannot open or create the save");
		m_settings = load("settings", "settings");
		if(!m_settings.is_object()){
			m_settings = default_settings();
			put("settings", "settings", m_settings);
		}
		const interface::ServerConfig &c = m_server->get_config();
		const ss_ app = m_server->get_app_id();
		m_archives = c.get<ss_>("user_path")+"/apps/"+app+"/archives";
		m_tmp = c.get<ss_>("cache_path")+"/apps/"+app+"/tmp";
		interface::fs::create_directories(m_archives);
		interface::fs::create_directories(m_tmp);
		// [FRONT_PAGES]: a browser's pages; the web client is at /app
		network::access(m_server, [&](network::Interface *iface){
			iface->claim_http_path("/");
			iface->claim_http_path("/p/");
			iface->claim_http_path("/brand/");
		});
		log_i(MODULE, "Aitta: %zu releases", store("releases")->list("").size());
	}

	// -----------------------------------------------------------------------
	// The HTTP API

	void respond(const network::HttpRequest &r, int status,
			const ss_ &type, const ss_ &body)
	{
		// Any page may read it: no cookies, and the web client fetches the
		// list, .sig and .zip from its own origin ([WEB_ID_TRUST] (c))
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, status, type, body,
					"Access-Control-Allow-Origin: *\r\n");
		});
	}
	void respond(const network::HttpRequest &r, const json::Value &v)
	{
		respond(r, 200, "application/json", v.stringify());
	}
	void refuse(const network::HttpRequest &r, const ss_ &why)
	{
		json::Value v = json::object();
		v.set("ok", false);
		v.set("error", why);
		respond(r, v);
	}
	void ok(const network::HttpRequest &r, const ss_ &what = "")
	{
		json::Value v = json::object();
		v.set("ok", true);
		if(!what.empty())
			v.set("result", what);
		respond(r, v);
	}

	bool allowed(const network::HttpRequest &r)
	{
		const bool post = r.method == "POST";
		return m_hits.ok(post ? "u" : "r", network::address_bin(r.address),
				post ? UPLOADS_A_MINUTE : READS_A_MINUTE, 60);
	}

	void on_http(const network::HttpRequest &r)
	{
		const ss_ base = "/api/aitta/";
		const bool page = r.path == "/" || r.path.compare(0, 3, "/p/") == 0 ||
				r.path.compare(0, 7, "/brand/") == 0;
		if(!page && r.path.compare(0, base.size(), base) != 0)
			return;
		if(!allowed(r))
			return refuse(r, "too many requests from your network: wait a "
					"minute");
		if(page)
			return html_page(r);
		if(!m_save)
			return refuse(r, "Aitta is not ready");
		const ss_ call = r.path.substr(base.size());
		try {
			if(call == "list")
				return http_list(r);
			if(call == "info")
				return http_info(r);
			if(call == "release")
				return http_release(r);
			if(call.compare(0, 8, "archive/") == 0)
				return http_archive(r, call.substr(8));
			if(call.compare(0, 6, "media/") == 0)
				return http_media(r, call.substr(6));
			if(r.method != "POST")
				return refuse(r, "no such call");
			if(call == "upload_begin")
				return http_upload_begin(r);
			if(call == "upload_part")
				return http_upload_part(r);
			if(call == "upload_end")
				return http_upload_end(r);
			if(call == "report")
				return http_report(r);
			if(call == "report_status")
				return http_report_status(r);
		} catch(std::exception &e){
			return refuse(r, e.what());
		}
		refuse(r, "no such call");
	}

	json::Value releases(bool with_delisted)
	{
		json::Value list = json::array();
		for(const ss_ &k : store("releases")->list("")){
			json::Value rel = load("releases", k);
			if(!with_delisted && (rel.get("delisted").is_true() ||
					rel.get("hidden").is_true()))
				continue;
			list.append(rel);
		}
		return list;
	}

	// A release is listed once it is "update_delay" seconds old (the
	// instance's setting, 0 if not set), so a compromised key's release
	// can be reported and delisted before it reaches everybody. A
	// package's first listed release is listed at once: it updates nothing.
	void http_list(const network::HttpRequest &r)
	{
		json::Value v = json::object();
		v.set("ok", true);
		// [AITTA_SERVERLESS] ?serverless=1: those only, for a play page
		json::Value list = listed_releases();
		if(r.param("serverless") == "1"){
			json::Value only = json::array();
			for(unsigned i = 0; i < list.size(); i++)
				if(list.at(i).get("serverless").is_true())
					only.append(list.at(i));
			list = only;
		}
		v.set("releases", list);
		// [AITTA_REPORTS] And what is out of it, with why: a client notes
		// it on the tile of one it has installed
		json::Value out = json::array();
		for(const ss_ &k : store("releases")->list("")){
			const json::Value rel = load("releases", k);
			if(!rel.get("delisted").is_true() && !rel.get("hidden").is_true())
				continue;
			json::Value o = json::object();
			for(const char *f : {"author", "name", "version", "sha256"})
				o.set(f, jstr(rel, f));
			o.set("why", jstr(rel, "delisted_why"));
			out.append(o);
		}
		v.set("delisted", out);
		respond(r, v);
	}

	// [AITTA_REPORTS] A report on a release: JSON {release, reason, text,
	// key (the client's report key for this Aitta, optional)}, or the
	// package page's form with the same fields, urlencoded, answered by a
	// page. Ten an hour a network, five a key; the receipt is the report's
	// id, its outcome asked by the key (report_status).
	void http_report(const network::HttpRequest &r)
	{
		const bool form = r.body.empty() || r.body[0] != '{';
		json::Value b = form ? json::object() :
				json::load_string(r.body.c_str());
		if(form)
			for(const char *f : {"release", "reason", "text"})
				b.set(f, network::query_value(r.body, f));
		auto answer = [&](const ss_ &error, const ss_ &receipt){
			if(!form){
				if(!error.empty())
					return refuse(r, error);
				json::Value v = json::object();
				v.set("ok", true);
				v.set("receipt", receipt);
				return respond(r, v);
			}
			using interface::web_brand::html;
			const ss_ body = (error.empty() ? "<p>Sent; a moderator will "
					"look. Receipt "+html(receipt)+".</p>" : "<p>Not sent: "+
					html(error)+"</p>")+"<p><a href=\"/\">Aitta</a></p>";
			network::access(m_server, [&](network::Interface *iface){
				iface->http_respond(r.peer, 200, "text/html; charset=utf-8",
						interface::web_brand::page("Report - Aitta", "Aitta",
						body, MANAGE), "");
			});
		};
		const ss_ net = network::address_bin(r.address);
		if(!m_hits.ok("report", net, 10, 3600))
			return answer("too many reports from your network; try later", "");
		const ss_ id = jstr(b, "release");
		// [AITTA_PACKAGE_PAGE] Or "author/name": the package's page
		const json::Value rel = is_page(id) ? shown_page(id) :
				load("releases", id);
		if(!rel.is_object() || rel.get("delisted").is_true())
			return answer(is_page(id) ? "no such page" : "no such release", "");
		const ss_ reason = jstr(b, "reason");
		if(!REASONS.count(reason))
			return answer("reason: one of csam, malware, illegal, scam, "
					"harassment, impersonation, licence, category, broken, "
					"spam, other", "");
		const ss_ text = jstr(b, "text");
		if(text.size() > 2000)
			return answer("text: at most 2000 characters", "");
		ss_ h;
		const ss_ key = jstr(b, "key");
		if(!key.empty()){
			if(!is_hex(key, 64))
				return answer("key: 64 hex digits", "");
			h = interface::sha256::hex(interface::sha256::calculate(key));
			if(!m_hits.ok("report_key", h, 5, 3600))
				return answer("too many reports from this key; try later", "");
		}
		json::Value rep = json::object();
		const ss_ rid = interface::sha256::hex(
				interface::bignum::random_bytes(8)).substr(0, 16);
		rep.set("id", rid);
		rep.set("listing", id);
		rep.set("reason", reason);
		rep.set("text", text);
		rep.set("key", h);
		// The network, not the address, under the module's field, which
		// it keeps from the moderators
		rep.set("address", net);
		rep.set("ts", now_s());
		rep.set("weight", key_weight(h));
		rep.set("group", id+"|"+reason);
		moderation::access(m_server, [&](moderation::Interface *m){
			m->add_report(this, rep, json::object());
		});
		log_i(MODULE, "A report on %s: %s", cs(id), cs(reason));
		answer("", rid);
	}

	// {key, receipts: [id...]}: each of the key's reports' {receipt,
	// state, outcome}
	void http_report_status(const network::HttpRequest &r)
	{
		const json::Value b = json::load_string(r.body.c_str());
		const ss_ key = jstr(b, "key");
		if(!is_hex(key, 64))
			return refuse(r, "key: 64 hex digits");
		const ss_ h = interface::sha256::hex(interface::sha256::calculate(key));
		const json::Value &ids = b.get("receipts");
		json::Value out = json::array();
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
		respond(r, v);
	}

	// A keyed report's weight: the setting, more for a record of upheld
	// reports and less for rejected ones, as Starport's
	double key_weight(const ss_ &h)
	{
		const double anon = setting("anon_weight").as_number();
		if(h.empty())
			return anon;
		const json::Value k = load("reporters", h);
		auto n = [&](const char *f){
			return k.get(f).is_number() ? (int64_t)k.get(f).as_number() : 0;
		};
		return std::max(anon, setting("key_weight").as_number() *
				(1.0 + 0.1 * std::min<int64_t>(n("upheld"), 10)) /
				(1.0 + 0.5 * n("rejected")));
	}

	void http_info(const network::HttpRequest &r)
	{
		json::Value v = json::object();
		v.set("ok", true);
		v.set("licences", m_settings.get("licences"));
		const ss_ key = r.param("key");
		v.set("author", is_hex(key, 130) ? get("keys", key) : "");
		respond(r, v);
	}

	json::Value listed_releases()
	{
		const json::Value &d = m_settings.get("update_delay");
		const int64_t delay = d.is_number() ? (int64_t)d.as_number() : 0;
		const json::Value all = releases(false);
		auto pkg = [&](unsigned i){
			return jstr(all.at(i), "author")+"/"+jstr(all.at(i), "name");
		};
		auto time = [&](unsigned i){
			return (int64_t)all.at(i).get("time").as_number();
		};
		std::map<ss_, unsigned> first;
		for(unsigned i = 0; i < all.size(); i++)
			if(!first.count(pkg(i)) || time(i) < time(first[pkg(i)]))
				first[pkg(i)] = i;
		json::Value list = json::array();
		for(unsigned i = 0; i < all.size(); i++)
			if(first[pkg(i)] == i || now_s() - time(i) >= delay)
				list.append(all.at(i));
		return list;
	}

	// -----------------------------------------------------------------------
	// [FRONT_PAGES]: what a browser is shown, read-only, from what list
	// hands out: / lists each package's latest release, /p/<author>/<name>
	// a package's every listed one

	static ss_ date(int64_t t)
	{
		const struct tm tm = interface::os::utc_tm(t);
		char b[16];
		strftime(b, sizeof b, "%Y-%m-%d", &tm);
		return b;
	}

	static ss_ url_encode(const ss_ &v)
	{
		static const char *hex = "0123456789ABCDEF";
		ss_ o;
		for(unsigned char c : v){
			if(isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~')
				o += (char)c;
			else
				o += ss_("%")+hex[c >> 4]+hex[c & 15];
		}
		return o;
	}

	// [AITTA_SERVERLESS] "Play in the browser" for a serverless release,
	// with the setting play_url; [AITTA_HOSTING_LINK] "Host at <domain>"
	// for an app, with app_hosting_provider; "" for neither. self: this
	// Aitta's address, as the package page's commands give it
	ss_ outside_links(const json::Value &rel, const ss_ &self)
	{
		using interface::web_brand::html;
		const ss_ pkg = jstr(rel, "author")+"/"+jstr(rel, "name");
		auto get = [&](const char *k){
			ss_ v = setting(k).is_string() ? setting(k).as_string() : "";
			while(!v.empty() && v.back() == '/')
				v.pop_back();
			return v;
		};
		sv_<ss_> out;
		const ss_ play = get("play_url");
		if(!play.empty() && rel.get("serverless").is_true())
			out.push_back("<a href=\""+html(play)+"/#run="+html(pkg)+"\">"
					"Play in the browser</a>");
		const ss_ host = get("app_hosting_provider");
		const size_t at = host.find("://");
		if(at != ss_::npos && jstr(rel, "kind") != "extension"){
			const ss_ domain = host.substr(at + 3, host.find_first_of("/:?#",
					at + 3) - (at + 3));
			out.push_back("<a href=\""+html(host+(host.find('?') == ss_::npos ?
					"?" : "&")+"aitta="+url_encode(self)+"&package="+
					url_encode(pkg))+"\" rel=\"nofollow noopener\">Host at "+
					html(domain)+"</a>");
		}
		ss_ o;
		for(const ss_ &x : out)
			o += (o.empty() ? "" : " ")+x;
		return o;
	}

	// links: outside_links()'s, by the files' links
	static ss_ release_box(const json::Value &rel, bool latest,
			const ss_ &links = "")
	{
		using interface::web_brand::html;
		const ss_ pkg = jstr(rel, "author")+"/"+jstr(rel, "name");
		const ss_ sha = jstr(rel, "sha256");
		const int64_t size = (int64_t)rel.get("size").as_number();
		// [PACKAGE_MEDIA] Its icon before the name
		const ss_ icon = jstr(rel, "icon");
		ss_ b = "<div class=\"box\">"+(is_hex(icon, 64) ? "<img src=\""
				"/api/aitta/media/"+icon+"\" alt=\"\" width=\"32\" height=\"32\" "
				"style=\"vertical-align:middle\"> " : "")+"<b>"+(latest ?
				"<a href=\"/p/"+html(pkg)+
				"\">"+html(pkg)+"</a>" : html(pkg))+"</b> "+
				html(jstr(rel, "version"))+" <span class=\"meta\">"+
				html(jstr(rel, "kind"))+(rel.get("serverless").is_true() ?
				", runs in the browser" : "")+", for "+html(jstr(rel, "audience"))+
				", "+date((int64_t)rel.get("time")
				.as_number())+", "+(size < 1000 ? itos(size)+" bytes" : size < 1000000 ?
				itos(size / 1000)+" kB" :
				itos(size / 1000000)+" MB")+", "+(jstr(rel, "review") ==
				"reviewed" ? "reviewed" : "unreviewed")+"</span>";
		if(!jstr(rel, "description").empty())
			b += "<br>"+html(jstr(rel, "description"));
		b += "<br><span class=\"meta\">Licence: code "+
				html(jstr(rel, "license_code"))+", media "+
				html(jstr(rel, "license_media"))+"</span><br>"
				"<a href=\"/api/aitta/archive/"+html(sha)+".zip\">.zip</a> "
				"<a href=\"/api/aitta/archive/"+html(sha)+".sig\">.sig</a>";
		if(!links.empty())
			b += " "+links;
		// Its discussion at its home Hearth, as the client's "Discuss"
		const ss_ home = jstr(rel, "home_hearth");
		if(home.compare(0, 8, "https://") == 0 ||
				home.compare(0, 7, "http://") == 0)
			b += " <a href=\""+html(home.back() == '/' ? home.substr(0,
					home.size() - 1) : home)+"/p/"+html(pkg)+"\" "
					"rel=\"nofollow noopener\">Discuss</a>";
		return b+"</div>\n";
	}

	// [AITTA_PACKAGE_PAGE] A page's description as HTML: escaped, a blank
	// line a paragraph, a line break a <br>, an http(s):// address a link
	static ss_ page_text(ss_ t)
	{
		using interface::web_brand::html;
		ss_ out, para;
		t.erase(std::remove(t.begin(), t.end(), '\r'), t.end());
		auto flush = [&](){
			if(!para.empty())
				out += "<p>"+para+"</p>\n";
			para.clear();
		};
		size_t at = 0;
		while(at < t.size()){
			const size_t nl = t.find('\n', at);
			const ss_ line = t.substr(at, nl == ss_::npos ? ss_::npos : nl - at);
			at = nl == ss_::npos ? t.size() : nl + 1;
			if(line.find_first_not_of(" \t") == ss_::npos){
				flush();
				continue;
			}
			if(!para.empty())
				para += "<br>";
			size_t i = 0;
			while(i < line.size()){
				size_t u = std::min(line.find("http://", i),
						line.find("https://", i));
				if(u == ss_::npos){
					para += html(line.substr(i));
					break;
				}
				size_t e = line.find_first_of(" \t\"<>", u);
				if(e == ss_::npos)
					e = line.size();
				while(e > u && ss_(".,;:!?)'").find(line[e - 1]) != ss_::npos)
					e--;
				const ss_ url = line.substr(u, e - u);
				para += html(line.substr(i, u - i));
				para += url.find("://") + 3 < url.size() ? "<a href=\""+
						html(url)+"\" rel=\"nofollow noopener\">"+html(url)+
						"</a>" : html(url);
				i = e;
			}
		}
		flush();
		return out;
	}

	void html_page(const network::HttpRequest &r)
	{
		auto send = [&](int status, const ss_ &type, const ss_ &body,
				const ss_ &headers = ""){
			network::access(m_server, [&](network::Interface *iface){
				iface->http_respond(r.peer, status, type, body, headers);
			});
		};
		if(network::serve_brand(m_server, r))
			return;
		if(r.path.compare(0, 7, "/brand/") == 0)
			return send(404, "text/plain", "Not found\n");
		const ss_ html_type = "text/html; charset=utf-8";
		if(!m_save)
			return send(503, html_type, interface::web_brand::page("Aitta",
					"Aitta", "<p>Starting.</p>", MANAGE));
		const json::Value all = listed_releases();
		// Only what suits a teen, listed "page_delay" seconds (an older
		// save has none: an hour), with no way to show more
		const json::Value &pd = m_settings.get("page_delay");
		const int64_t delay = pd.is_number() ? (int64_t)pd.as_number() : 3600;
		sv_<json::Value> rels;
		for(unsigned i = 0; i < all.size(); i++){
			const json::Value &rel = all.at(i);
			const ss_ a = jstr(rel, "audience");
			if((a == "everyone" || a == "teen") &&
					now_s() - (int64_t)rel.get("time").as_number() >= delay)
				rels.push_back(rel);
		}
		// Newest first; a package's latest is its first
		std::sort(rels.begin(), rels.end(), [](const json::Value &a,
				const json::Value &b){
			return a.get("time").as_number() > b.get("time").as_number();
		});
		auto pkg = [](const json::Value &rel){
			return jstr(rel, "author")+"/"+jstr(rel, "name");
		};
		using interface::web_brand::html;
		ss_ c;
		// simplified: behind a proxy without public_url set, the address
		// may read as the proxy's inside one; the setting is the fix
		ss_ self = jstr(m_settings, "public_url");
		if(self.empty())
			self = "http://"+r.host;
		if(r.path.compare(0, 3, "/p/") == 0){
			const ss_ want = r.path.substr(3);
			// [AITTA_INSTALL_HELP] The newest, the rest folded
			sv_<const json::Value*> mine;
			for(const json::Value &rel : rels)
				if(pkg(rel) == want)
					mine.push_back(&rel);
			if(mine.empty())
				return send(404, html_type, interface::web_brand::page(
						"Not found", "Aitta", "<p>No package of that name is "
						"listed here. <a href=\"/\">The list</a>.</p>", MANAGE));
			c = release_box(*mine[0], false);
			if(mine.size() > 1){
				c += "<details><summary>Older releases ("+
						itos(mine.size() - 1)+")</summary>\n";
				for(size_t i = 1; i < mine.size(); i++)
					c += release_box(*mine[i], false);
				c += "</details>\n";
			}
			// [AITTA_SERVE] The commands for a dedicated server, filled in
			ss_ vers;
			for(const json::Value *rel : mine)
				vers += "bin/buildat aitta install "+self+" "+want+"@"+
						jstr(*rel, "version")+" <user dir>\n";
			const ss_ name = jstr(*mine[0], "name");
			const ss_ pl = outside_links(*mine[0], self);
			c += "<h2>Install</h2>\n"+(pl.empty() ? "" : "<p>"+pl+"</p>")+
					"<details><summary>On the client</summary>"
					"<ol><li>In the Buildat client, open <b>Apps from Aitta"
					"</b>.</li><li>If this Aitta, <code>"+html(self)+"</code>, "
					"is not one of the client's Aittas, add it in the "
					"Starport settings (<b>Starport settings...</b> in the "
					"launcher, then <b>Add Aitta</b>).</li><li>Search for "
					"<code>"+html(name)+"</code> and pick <b>Install</b>; the "
					"client checks the author's signature first.</li>"+
					(jstr(*mine[0], "review") == "reviewed" ? "" :
					"<li>The newest release is unreviewed: it shows only "
					"with <b>Apps from Aitta (unreviewed): shown</b> in the "
					"same settings.</li>")+"</ol></details>\n"
					"<details><summary>On a dedicated server</summary>"
					"<div class=\"box\"><span class=\"meta\">In the "
					"directory of a Buildat release; the newest listed, or a "
					"version</span><pre>"
					"bin/buildat aitta install "+html(self)+" "+html(want)+
					" &lt;user dir&gt;\n"
					"util/serve_latest_release.sh "+html(want)+
					" &lt;port&gt; &lt;user dir&gt;\n"
					"# following its releases here:\n"
					"AITTA="+html(self)+" util/serve_latest_release.sh "+
					html(want)+" &lt;port&gt; &lt;user dir&gt;</pre><pre>"+
					html(vers)+"</pre></div></details>\n";
			// [AITTA_REPORTS] A report from the web: anonymous, so it
			// weighs little alone
			ss_ f = "<h2>Report</h2><form method=\"post\" action=\""
					"/api/aitta/report\"><p><select name=\"release\">";
			for(const json::Value &rel : rels)
				if(pkg(rel) == want)
					f += "<option>"+html(pkg(rel)+"/"+jstr(rel, "version"))+
							"</option>";
			// [AITTA_PACKAGE_PAGE] And the page
			const json::Value pg = shown_page(want);
			if(pg.is_object())
				f += "<option value=\""+html(want)+"\">The page</option>";
			f += "</select> <select name=\"reason\">";
			for(const auto &x : REASON_NAMES)
				f += "<option value=\""+ss_(x[0])+"\">"+x[1]+"</option>";
			f += "</select></p><p><textarea name=\"text\" maxlength=\"2000\" "
					"rows=\"3\" cols=\"60\" placeholder=\"What is wrong "
					"(optional)\"></textarea></p><p><button>Send the report"
					"</button></p></form>\n";
			// [PACKAGE_MEDIA] The newest's icon by the heading;
			// [AITTA_PACKAGE_PAGE] its description, its screenshot and
			// the page's, each a link to the image, the page's text
			const ss_ icon = jstr(*mine[0], "icon");
			sv_<ss_> shots;
			if(is_hex(jstr(*mine[0], "screenshot"), 64))
				shots.push_back(jstr(*mine[0], "screenshot"));
			const json::Value &ps = pg.get("screenshots");
			for(unsigned i = 0; ps.is_array() && i < ps.size(); i++)
				if(ps.at(i).is_string() && is_hex(ps.at(i).as_string(), 64))
					shots.push_back(ps.at(i).as_string());
			ss_ head = "<h1>"+(is_hex(icon, 64) ? "<img src=\""
					"/api/aitta/media/"+icon+"\" alt=\"\" width=\"48\" "
					"height=\"48\" style=\"vertical-align:middle\"> " : "")+
					html(want)+"</h1><p>"+html(jstr(*mine[0], "description"))+
					"</p>\n";
			if(!shots.empty()){
				head += "<p class=\"shots\">";
				for(const ss_ &h : shots)
					head += "<a href=\"/api/aitta/media/"+h+"\"><img src=\""
							"/api/aitta/media/"+h+"\" alt=\"A screenshot\" "
							"style=\"max-width:100%;max-height:180px;"
							"margin:0 6px 6px 0\"></a>";
				head += "</p>\n";
			}
			if(pg.is_object())
				head += "<div class=\"page\">"+page_text(jstr(pg,
						"description"))+"</div>\n";
			return send(200, html_type, interface::web_brand::page(want+
					" - Aitta", "Aitta", head+"<p class=\""
					"meta\">Every listed release, the newest first.</p>\n"+
					(pl.empty() ? "" : "<p>"+pl+"</p>\n")+c+
					f, MANAGE));
		}
		std::set<ss_> seen;
		for(const json::Value &rel : rels)
			if(seen.insert(pkg(rel)).second)
				c += release_box(rel, true, outside_links(rel, self));
		ss_ body = "<h1>Aitta</h1><p>A registry of Buildat apps and "
				"extensions: their authors sign each release with their own "
				"key, and Aitta lists it. A release is unreviewed until this "
				"server's reviewers mark it reviewed.</p><p>To install one, "
				"open the Buildat client and pick <b>Apps from Aitta</b>.</p>\n";
		body += c.empty() ? "<p>Nothing is published here yet.</p>\n" :
				"<h2>Packages</h2>\n"+c;
		send(200, html_type, interface::web_brand::page("Aitta", "Aitta",
				body, MANAGE));
	}

	void http_release(const network::HttpRequest &r)
	{
		const ss_ id = r.param("id");
		const json::Value rel = load("releases", id);
		if(!rel.is_object() || rel.get("delisted").is_true())
			return refuse(r, "no such release");
		json::Value v = json::object();
		v.set("ok", true);
		v.set("release", rel);
		const json::Value c = load("changelogs", id);
		v.set("changelog", c.is_object() ? jstr(c, "text") : ss_());
		respond(r, v);
	}

	// A delisted release's files are not served either
	bool listed_hash(const ss_ &sha)
	{
		for(const ss_ &k : store("releases")->list("")){
			json::Value rel = load("releases", k);
			if(jstr(rel, "sha256") == sha)
				return !rel.get("delisted").is_true() &&
						!rel.get("hidden").is_true();
		}
		return false;
	}

	void http_archive(const network::HttpRequest &r, const ss_ &file)
	{
		const size_t dot = file.find('.');
		const ss_ sha = file.substr(0, dot), ext = dot == ss_::npos ? "" :
				file.substr(dot);
		if(!is_hex(sha, 64) || (ext != ".zip" && ext != ".sig") ||
				!(ticket_ok(r.param("ticket"), sha, ext) || listed_hash(sha)))
			return respond(r, 404, "text/plain", "Not found\n");
		respond(r, 200, ext == ".zip" ? "application/zip" : "application/json",
				read_file(m_archives+"/"+sha+ext));
	}

	// [PACKAGE_MEDIA] A listed release's icon or screenshot, by its
	// sha256: the type its bytes are, never sniffed, cached for good (a
	// hash's bytes do not change)
	void http_media(const network::HttpRequest &r, const ss_ &sha)
	{
		bool listed = false;
		if(is_hex(sha, 64))
			for(const ss_ &k : store("releases")->list("")){
				const json::Value rel = load("releases", k);
				if((jstr(rel, "icon") == sha || jstr(rel, "screenshot") == sha) &&
						!rel.get("delisted").is_true() &&
						!rel.get("hidden").is_true())
					listed = true;
			}
		// [AITTA_PACKAGE_PAGE] Or a shown page's screenshot
		if(is_hex(sha, 64) && !listed)
			for(const ss_ &k : store("pages")->list("")){
				const json::Value pg = shown_page(k);
				const json::Value &sl = pg.get("screenshots");
				for(unsigned i = 0; sl.is_array() && i < sl.size(); i++)
					if(sl.at(i).is_string() && sl.at(i).as_string() == sha)
						listed = true;
			}
		ss_ data, type;
		if(listed)
			data = read_file(m_archives+"/media/"+sha);
		if(data.empty() || (interface::aitta::media_check("screenshot", data,
				&type) != "" && interface::aitta::media_check("icon", data,
				&type) != ""))
			return respond(r, 404, "text/plain", "Not found\n");
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, 200, type, data,
					"Access-Control-Allow-Origin: *\r\n"
					"X-Content-Type-Options: nosniff\r\n"
					"Cache-Control: public, max-age=31536000, immutable\r\n");
		});
	}

	void http_upload_begin(const network::HttpRequest &r)
	{
		const json::Value sig = json::load_string(r.body.c_str());
		const ss_ sha = jstr(sig, "sha256"), key = jstr(sig, "key");
		const int64_t size = atoll(r.param("size").c_str());
		// [AITTA_PACKAGE_PAGE] Or a package's page, sent the same way
		const bool page = jstr(sig, "format") == interface::aitta::PAGE_FORMAT;
		if((!page && jstr(sig, "format") != interface::aitta::RELEASE_FORMAT) ||
				!is_hex(sha, 64))
			return refuse(r, "the body is not a release's .sig");
		const ss_ author = get("keys", key);
		if(author.empty())
			return refuse(r, "this key is not bound to an author here: "
					"join Aitta and bind it first");
		// [AITTA_REPORTS] A moderator's bar
		const json::Value bar = load("authors", author).get("barred_until");
		if(bar.is_number() && (bar.as_number() < 0 ||
				bar.as_number() > now_s()))
			return refuse(r, "the author "+author+" is barred from "
					"publishing here: see your statements on Aitta's page");
		if(!interface::aitta::verify_hash(key, sha, jstr(sig, "signature"),
				page ? interface::aitta::PAGE_FORMAT :
				interface::aitta::RELEASE_FORMAT))
			return refuse(r, "the signature does not match the hash");
		const json::Value &max = m_settings.get("max_size");
		if(size <= 0 || (max.is_number() && size > max.as_number()))
			return refuse(r, "the archive's size is 1 byte to "+
					itos((int64_t)max.as_number())+" bytes here");
		if(!page && interface::fs::path_exists(m_archives+"/"+sha+".zip"))
			return refuse(r, "this archive is here already");
		// simplified: at most four uploads at once and ten minutes each,
		// in memory; an upload server's worth of resumable uploads is the
		// upgrade, when releases grow past what one request a piece carries
		for(auto it = m_uploads.begin(); it != m_uploads.end();){
			if(now_s() - it->second.started > 600)
				it = m_uploads.erase(it);
			else
				it++;
		}
		if(m_uploads.size() >= 4 && !m_uploads.count(sha))
			return refuse(r, "busy: try again in a while");
		Upload &u = m_uploads[sha];
		u = Upload();
		u.sig = sig;
		u.author = author;
		u.size = (size_t)size;
		u.started = now_s();
		ok(r);
	}

	void http_upload_part(const network::HttpRequest &r)
	{
		auto it = m_uploads.find(r.param("sha256"));
		if(it == m_uploads.end())
			return refuse(r, "no upload of that hash: upload_begin first");
		Upload &u = it->second;
		if((size_t)atoll(r.param("offset").c_str()) != u.data.size())
			return refuse(r, "the next piece is at offset "+
					itos((int64_t)u.data.size()));
		if(u.data.size() + r.body.size() > u.size)
			return refuse(r, "more than the size given");
		u.data += r.body;
		ok(r);
	}

	// [AITTA_LUA51] What of a release's client-side Lua (a client_lua
	// directory's, or an extension's every file) the web client's Lua 5.1
	// will not load: luac51's parse error and LuaJIT's \x, \z and \u{
	// escapes, "file:line: why" a line each; "" when it all loads.
	// simplified: luac51 stops at the first file that does not parse
	ss_ lua51_problems(const ss_ &dir, bool extension)
	{
		sv_<ss_> files;
		for(const ss_ &f : interface::aitta::package_files(dir))
			if(f.size() > 4 && f.compare(f.size() - 4, 4, ".lua") == 0 &&
					(extension || ("/"+f).find("/client_lua/") != ss_::npos))
				files.push_back(f);
		ss_ out;
		for(const ss_ &f : files){
			const ss_ t = read_file(dir+"/"+f);
			int line = 1;
			for(size_t i = 0; i + 1 < t.size(); i++){
				if(t[i] == '\n')
					line++;
				if(t[i] != '\\')
					continue;
				const char c = t[++i];
				if(c == 'z' || (c == 'u' && i + 1 < t.size() && t[i + 1] == '{') ||
						(c == 'x' && i + 1 < t.size() && isxdigit((unsigned char)t[i + 1])))
					out += f+":"+itos(line)+": \\"+ss_(1, c)+" is LuaJIT's escape; "
							"Lua 5.1 reads it as the letter\n";
				if(c == '\n')
					line++;
			}
		}
		const ss_ luac = interface::os::get_sibling_exe_path("luac51");
		if(files.empty() || !interface::fs::path_exists(luac))
			return out;
		// Numbered copies: no name the package chose reaches the shell
		const ss_ d = dir+".lua51";
		interface::fs::create_directories(d);
		// Short names, from inside: luac cuts a long one to "...<end>"
		ss_ cmd = "cd '"+d+"' && '"+luac+"' -p";
		for(size_t i = 0; i < files.size(); i++){
			write_file(d+"/"+itos((int64_t)i)+".lua", read_file(dir+"/"+files[i]));
			cmd += " "+itos((int64_t)i)+".lua";
		}
		interface::process::ExecOptions o;
		o.output_path = d+"/out";
		const bool parsed = luac.find('\'') == ss_::npos &&
				d.find('\'') == ss_::npos ?
				interface::process::shell_exec(cmd, o) == 0 : true;
		ss_ said = parsed ? "" : read_file(o.output_path).substr(0, 4096);
		interface::fs::remove_all(d);
		if(parsed)
			return out;
		// "<luac>: <n>.lua:<line>: <why>" to "<file>:<line>: <why>"
		const size_t at = said.find(luac+": ");
		if(at != ss_::npos){
			said = said.substr(at + luac.size() + 2);
			const size_t dot = said.find(".lua");
			const size_t n = (size_t)atoi(said.c_str());
			if(dot != ss_::npos && n < files.size())
				said = files[n]+said.substr(dot + 4);
		}
		while(!said.empty() && (said.back() == '\n' || said.back() == '\r'))
			said.pop_back();
		return out+said+"\n";
	}

	void http_upload_end(const network::HttpRequest &r)
	{
		const ss_ sha = r.param("sha256");
		auto it = m_uploads.find(sha);
		if(it == m_uploads.end())
			return refuse(r, "no upload of that hash");
		Upload u = it->second;
		m_uploads.erase(it);
		if(u.data.size() != u.size)
			return refuse(r, "the archive is not whole");
		if(interface::sha256::hex(interface::sha256::calculate(u.data)) != sha)
			return refuse(r, "the archive is not the one the .sig is for");
		if(jstr(u.sig, "format") == interface::aitta::PAGE_FORMAT)
			return page_end(r, u);
		// The manifest, out of the archive
		// Beside where it goes, so the move is a rename; unpacked under
		// the cache
		const ss_ zip = m_archives+"/"+sha+".part";
		const ss_ dir = m_tmp+"/"+sha;
		if(!write_file(zip, u.data))
			return refuse(r, "cannot store the archive");
		json::Value m;
		try {
			interface::fs::create_directories(dir);
			interface::zip_extract(zip, dir);
			m = json::load_string(read_file(dir+"/meta.json").c_str());
		} catch(std::exception &e){
			interface::fs::remove_all(dir);
			interface::fs::remove_all(zip);
			return refuse(r, ss_("the archive: ")+e.what());
		}
		const bool changelog_there = jstr(m, "changelog").empty() ||
				interface::fs::path_exists(dir+"/"+jstr(m, "changelog"));
		// Its text kept for the release's thread ([PACKAGE_SUBJECT]), the
		// first 64 KiB: a Hearth message holds less than that anyway
		ss_ changelog;
		if(!jstr(m, "changelog").empty() && changelog_there)
			changelog = read_file(dir+"/"+jstr(m, "changelog")).substr(0,
					64 * 1024);
		// [AITTA_SERVERLESS] A serverless package's client Lua must load on
		// the web; another's is only warned of
		const ss_ lua51 = m.is_object() ? lua51_problems(dir,
				interface::aitta::kind_of(m) == "extension") : "";
		// [PACKAGE_MEDIA] Its icon and screenshot, checked, kept by hash
		const ss_ media_why = m.is_object() ?
				interface::aitta::check_media(m, dir) : "";
		sm_<ss_, ss_> media;
		for(const char *k : {"icon", "screenshot"})
			if(media_why.empty() && !jstr(m, k).empty())
				media[k] = read_file(dir+"/"+jstr(m, k));
		interface::fs::remove_all(dir);
		auto drop = [&](const ss_ &why){
			interface::fs::remove_all(zip);
			refuse(r, why);
		};
		const ss_ why = interface::aitta::check_manifest(m);
		if(!why.empty())
			return drop("meta.json: "+why);
		if(!changelog_there)
			return drop("meta.json: \"changelog\": "+jstr(m, "changelog")+
					" is not in the archive");
		if(jstr(m, "author") != u.author)
			return drop("the key is bound to the author \""+u.author+
					"\", and the manifest says \""+jstr(m, "author")+"\"");
		for(const char *k : {"license_code", "license_media"})
			if(!licence_ok(jstr(m, k)))
				return drop(ss_(k)+" \""+jstr(m, k)+"\" is not one this "
						"instance takes");
		const ss_ id = jstr(m, "author")+"/"+jstr(m, "name")+"/"+
				jstr(m, "version");
		// A moderator's "Delist package" holds for its later releases
		if(!get("delisted_packages", jstr(m, "author")+"/"+jstr(m, "name"))
				.empty())
			return drop(jstr(m, "author")+"/"+jstr(m, "name")+" is delisted "
					"here: see your statements on Aitta's page");
		if(!load("releases", id).is_undefined())
			return drop(id+" is here already");
		if(!media_why.empty())
			return drop("meta.json: "+media_why);
		if(m.get("serverless").as_boolean() && !lua51.empty())
			return drop("\"serverless\": the web client's Lua 5.1 cannot "
					"load this:\n"+lua51);
		if(!interface::fs::rename(zip, m_archives+"/"+sha+".zip") ||
				!write_file(m_archives+"/"+sha+".sig", u.sig.stringify()+"\n"))
			return drop("cannot store the archive");
		json::Value rel = json::object();
		for(const char *k : {"author", "name", "version", "description",
				"license_code", "license_media", "home_hearth", "changelog",
				"audience"})
			rel.set(k, jstr(m, k));
		rel.set("engine_api", m.get("engine_api"));
		// [SERVERLESS_PLAY] Its client half runs with no server: Play
		rel.set("serverless", m.get("serverless").as_boolean());
		rel.set("kind", interface::aitta::kind_of(m));
		interface::fs::create_directories(m_archives+"/media");
		for(const auto &x : media){
			const ss_ h = interface::sha256::hex(
					interface::sha256::calculate(x.second));
			if(!write_file(m_archives+"/media/"+h, x.second))
				return drop("cannot store the "+x.first);
			rel.set(x.first, h);
		}
		rel.set("sha256", sha);
		rel.set("size", (int64_t)u.size);
		rel.set("key", jstr(u.sig, "key"));
		rel.set("time", now_s());
		rel.set("delisted", false);
		// A reviewer's relabel holds for the package's later releases
		// ([AITTA_REVIEW]). simplified: until a reviewer relabels it again
		const json::Value lock = load("relabels", jstr(m, "author")+"/"+
				jstr(m, "name"));
		if(lock.is_object() && jstr(lock, "audience") != jstr(m, "audience")){
			rel.set("audience_manifest", jstr(m, "audience"));
			rel.set("audience", jstr(lock, "audience"));
		}
		put("releases", id, rel);
		if(!changelog.empty()){
			json::Value c = json::object();
			c.set("text", changelog);
			put("changelogs", id, c);
		}
		log_i(MODULE, "Listed %s (%zu bytes) from %s", cs(id), u.size,
				cs(r.address));
		if(lua51.empty())
			return ok(r, id);
		json::Value v = json::object();
		v.set("ok", true);
		v.set("result", id);
		v.set("warning", "The web client's Lua 5.1 cannot load this:\n"+lua51);
		respond(r, v);
	}

	// [AITTA_PACKAGE_PAGE] "author/name": a package's page; a release's
	// id has its version too
	static bool is_page(const ss_ &id)
	{
		return std::count(id.begin(), id.end(), '/') == 1;
	}
	// The page shown on the package's page: there, not delisted or hidden
	json::Value shown_page(const ss_ &pkg)
	{
		const json::Value pg = load("pages", pkg);
		return pg.is_object() && !pg.get("delisted").is_true() &&
				!pg.get("hidden").is_true() ? pg : json::Value();
	}

	// [AITTA_PACKAGE_PAGE] A package's page: page.json and its
	// screenshots, signed by a key bound to the package's author, newer
	// than the last, which it replaces whole. After a moderator delisted
	// the page, a new one waits for a moderator: hidden, with a report of
	// its own in the queue, shown when that is dismissed.
	void page_end(const network::HttpRequest &r, const Upload &u)
	{
		const ss_ sha = jstr(u.sig, "sha256");
		const ss_ zip = m_tmp+"/"+sha+".page.zip", dir = m_tmp+"/"+sha+".page";
		json::Value p;
		sm_<ss_, ss_> files;
		ss_ failed;
		try {
			if(!write_file(zip, u.data))
				throw Exception("cannot store it");
			interface::fs::create_directories(dir);
			interface::zip_extract(zip, dir);
			p = json::load_string(read_file(dir+"/page.json").c_str());
			// The names check_page() takes: none leaves the directory
			const json::Value &sl = p.get("screenshots");
			for(unsigned i = 0; sl.is_array() && i < sl.size() && i < 8; i++){
				if(sl.at(i).is_string() && !sl.at(i).as_string().empty() &&
						sl.at(i).as_string()[0] != '.' &&
						sl.at(i).as_string().find_first_of("/\\") == ss_::npos)
					files[sl.at(i).as_string()] = read_file(dir+"/"+
							sl.at(i).as_string());
			}
		} catch(std::exception &e){
			failed = ss_("the archive: ")+e.what();
		}
		interface::fs::remove_all(dir);
		interface::fs::remove_all(zip);
		if(!failed.empty())
			return refuse(r, failed);
		const ss_ why = interface::aitta::check_page(p, files);
		if(!why.empty())
			return refuse(r, "page.json: "+why);
		const ss_ pkg = jstr(p, "package");
		if(pkg.substr(0, pkg.find('/')) != u.author)
			return refuse(r, "the key is bound to the author \""+u.author+
					"\", and the page is for "+pkg);
		if(!get("delisted_packages", pkg).empty())
			return refuse(r, pkg+" is delisted here: see your statements on "
					"Aitta's page");
		if(store("releases")->list(pkg+"/").empty())
			return refuse(r, "no release of "+pkg+" here: publish one first");
		const json::Value old = load("pages", pkg);
		if(old.is_object() && p.get("time_ms").as_number() <=
				old.get("time_ms").as_number())
			return refuse(r, "the page here is as new as this or newer");
		json::Value pg = json::object();
		pg.set("package", pkg);
		pg.set("author", u.author);
		pg.set("name", pkg.substr(pkg.find('/') + 1));
		pg.set("description", jstr(p, "description"));
		// simplified: a replaced page's screenshots stay on disk, unserved;
		// the uploads' rate and a bound key bound it. A sweep of the hashes
		// nothing names is the upgrade, when a disk fills
		json::Value hashes = json::array();
		interface::fs::create_directories(m_archives+"/media");
		const json::Value &sl = p.get("screenshots");
		for(unsigned i = 0; i < sl.size(); i++){
			const ss_ &data = files[sl.at(i).as_string()];
			const ss_ h = interface::sha256::hex(
					interface::sha256::calculate(data));
			if(!write_file(m_archives+"/media/"+h, data))
				return refuse(r, "cannot store a screenshot");
			hashes.append(json::Value(h));
		}
		pg.set("screenshots", hashes);
		// An integer: a real is stringified to six digits
		pg.set("time_ms", (int64_t)p.get("time_ms").as_number());
		pg.set("time", now_s());
		pg.set("key", jstr(u.sig, "key"));
		pg.set("delisted", false);
		const bool held = old.get("moderated").is_true();
		pg.set("moderated", held);
		pg.set("hidden", held);
		pg.set("status_auto", held);
		pg.set("delisted_why", held ? "waits for a moderator: the last page "
				"was delisted" : "");
		put("pages", pkg, pg);
		if(held){
			json::Value rep = json::object();
			rep.set("id", interface::sha256::hex(
					interface::bignum::random_bytes(8)).substr(0, 16));
			rep.set("listing", pkg);
			rep.set("reason", "other");
			rep.set("text", "A new page after a delisted one: dismiss to "
					"show it");
			rep.set("key", "");
			rep.set("address", "");
			rep.set("ts", now_s());
			rep.set("weight", 0.0);
			rep.set("group", pkg+"|other");
			rep.set("state", "open");
			moderation::access(m_server, [&](moderation::Interface *m){
				m->add_report(this, rep, json::object());
			});
		}
		log_i(MODULE, "The page of %s (%u screenshots) from %s%s", cs(pkg),
				hashes.size(), cs(r.address), held ? ", held" : "");
		ok(r, held ? pkg+": it waits for a moderator, as the last page was "
				"delisted" : pkg);
	}

	// "GPL-3.0-only", "GPL-3.0-or-later" and "GPL-3.0+" are GPL-3.0's
	bool licence_ok(ss_ l)
	{
		for(const char *suffix : {"-only", "-or-later", "+"}){
			const ss_ s = suffix;
			if(l.size() > s.size() && l.compare(l.size() - s.size(), s.size(), s) == 0)
				l = l.substr(0, l.size() - s.size());
		}
		const json::Value &list = m_settings.get("licences");
		for(unsigned i = 0; list.is_array() && i < list.size(); i++)
			if(list.at(i).is_string() && list.at(i).as_string() == l)
				return true;
		return false;
	}

	// -----------------------------------------------------------------------
	// [AITTA_REVIEW] The review: the server's moderators and admins
	// (accounts' LV_MODERATOR and up) read a release's files and its diff
	// against the package's last reviewed version, playtest it by a ticket,
	// and mark it: reviewed, needs changes (a note to the author),
	// relabelled (its audience, kept for the package's later releases) or
	// delisted (builtin/moderation: a statement of reasons to the author).
	// Each mark is in the audit log, with whether it was playtested.

	// A release's files, unpacked once under the cache.
	// simplified: kept until the cache is cleared; a sweep of the old ones
	// when a reviewer's cache grows past what the disk minds
	ss_ unpacked(const json::Value &rel)
	{
		const ss_ sha = jstr(rel, "sha256");
		const ss_ dir = m_tmp+"/review/"+sha;
		if(!interface::fs::path_exists(dir+"/meta.json")){
			interface::fs::remove_all(dir);
			interface::fs::create_directories(dir);
			interface::zip_extract(m_archives+"/"+sha+".zip", dir);
		}
		return dir;
	}

	json::Value review_release(const ss_ &id)
	{
		const json::Value rel = load("releases", id);
		if(!rel.is_object())
			throw Exception("no release "+id);
		return rel;
	}

	// The package's latest reviewed release before this one, or undefined
	json::Value review_base(const json::Value &rel)
	{
		json::Value best;
		for(const ss_ &k : store("releases")->list(jstr(rel, "author")+"/"+
				jstr(rel, "name")+"/")){
			const json::Value o = load("releases", k);
			// simplified: by publish time in seconds; two releases of one
			// second are both "before" each other
			if(jstr(o, "review") != "reviewed" || rel_id(o) == rel_id(rel) ||
					o.get("time").as_number() > rel.get("time").as_number())
				continue;
			if(!best.is_object() || o.get("time").as_number() >
					best.get("time").as_number())
				best = o;
		}
		return best;
	}

	static ss_ rel_id(const json::Value &rel)
	{
		return jstr(rel, "author")+"/"+jstr(rel, "name")+"/"+
				jstr(rel, "version");
	}

	// Every file under dir, '/' separated, sorted
	static void files_of(const ss_ &dir, const ss_ &prefix,
			sm_<ss_, ss_> &out)
	{
		for(const auto &n : interface::fs::list_directory(dir)){
			if(n.is_directory)
				files_of(dir+"/"+n.name, prefix+n.name+"/", out);
			else
				out[prefix+n.name] = dir+"/"+n.name;
		}
	}

	// No NUL in its first 8000 bytes, as git tells
	static bool is_text(const ss_ &data)
	{
		const size_t z = data.find('\0');
		return z == ss_::npos || z >= 8000;
	}

	static sv_<ss_> lines_of(const ss_ &s)
	{
		sv_<ss_> out;
		std::istringstream is(s);
		ss_ line;
		while(std::getline(is, line))
			out.push_back(line);
		return out;
	}

	// The changed lines, "-" and "+", with two of context and "..." for
	// what is left out between. simplified: a whole-file LCS, so a file
	// pair over 3000 lines each is "too long to compare"; Myers' diff is
	// the upgrade
	// `cells`: what is left of the release's budget of (n + 1) * (m + 1)
	static ss_ line_diff(const ss_ &a_text, const ss_ &b_text, size_t &cells)
	{
		const sv_<ss_> a = lines_of(a_text), b = lines_of(b_text);
		const size_t n = a.size(), m = b.size();
		if((n + 1) * (m + 1) > 9000000 || (n + 1) * (m + 1) > cells)
			return "(too long to compare here: "+itos(n)+" and "+itos(m)+
					" lines)\n";
		cells -= (n + 1) * (m + 1);
		// Each line an id, so a comparison is one int whatever its length
		std::map<ss_, uint32_t> ids;
		sv_<uint32_t> ai, bi;
		for(const ss_ &x : a)
			ai.push_back(ids.emplace(x, (uint32_t)ids.size()).first->second);
		for(const ss_ &x : b)
			bi.push_back(ids.emplace(x, (uint32_t)ids.size()).first->second);
		sv_<sv_<uint32_t>> L(n + 1, sv_<uint32_t>(m + 1, 0));
		for(size_t i = n; i-- > 0;)
			for(size_t j = m; j-- > 0;)
				L[i][j] = ai[i] == bi[j] ? L[i + 1][j + 1] + 1 :
						std::max(L[i + 1][j], L[i][j + 1]);
		sv_<ss_> ops; // " x", "-x", "+x"
		size_t i = 0, j = 0;
		while(i < n || j < m){
			if(i < n && j < m && ai[i] == bi[j])
				ops.push_back(" "+a[i++]), j++;
			else if(j < m && (i == n || L[i][j + 1] >= L[i + 1][j]))
				ops.push_back("+"+b[j++]);
			else
				ops.push_back("-"+a[i++]);
		}
		ss_ out;
		bool skipped = false;
		for(size_t k = 0; k < ops.size(); k++){
			bool near = false;
			for(size_t d = (k < 2 ? 0 : k - 2); d < ops.size() && d <= k + 2;
					d++)
				near = near || ops[d][0] != ' ';
			// simplified: a 64 KiB diff a file, a line's first 300 bytes
			if(out.size() > 64 * 1024){
				out += "(... the rest left out)\n";
				break;
			}
			if(near){
				out += ops[k].substr(0, 300)+(ops[k].size() > 300 ? "..." : "")+
						"\n";
				skipped = false;
			} else if(!skipped){
				out += "...\n";
				skipped = true;
			}
		}
		return out;
	}

	json::Value review_diff(const json::Value &rel)
	{
		const json::Value base = review_base(rel);
		sm_<ss_, ss_> now, before;
		files_of(unpacked(rel), "", now);
		if(base.is_object())
			files_of(unpacked(base), "", before);
		json::Value added = json::array(), removed = json::array(),
				changed = json::array();
		size_t cells = 50000000;
		for(auto &f : now)
			if(!before.count(f.first))
				added.append(f.first);
		for(auto &f : before){
			if(!now.count(f.first)){
				removed.append(f.first);
				continue;
			}
			const ss_ a = read_file(f.second), b = read_file(now[f.first]);
			if(a == b)
				continue;
			json::Value c = json::object();
			c.set("path", f.first);
			c.set("diff", is_text(a) && is_text(b) ? line_diff(a, b, cells) :
					"(binary: "+itos((int64_t)a.size())+" bytes, now "+
					itos((int64_t)b.size())+")\n");
			changed.append(c);
		}
		json::Value v = json::object();
		v.set("base", base.is_object() ? rel_id(base) : ss_());
		v.set("added", added);
		v.set("removed", removed);
		v.set("changed", changed);
		return v;
	}

	// One ticket a playtest ([AITTA_REVIEW]): a release's two files, once
	// each, for an hour, to whoever has it. simplified: in memory; a
	// restart drops them, and the reviewer asks for another
	struct Ticket {
		ss_ release, sha, by;
		int64_t expires = 0;
		bool zip = false, sig = false;
	};
	sm_<ss_, Ticket> m_tickets;

	// Whether the file is the ticket's, unfetched, in time; marks it
	bool ticket_ok(const ss_ &t, const ss_ &sha, const ss_ &ext)
	{
		auto it = m_tickets.find(t);
		if(t.empty() || it == m_tickets.end() || it->second.sha != sha ||
				now_s() > it->second.expires)
			return false;
		bool &used = ext == ".zip" ? it->second.zip : it->second.sig;
		if(used)
			return false;
		used = true;
		if(ext == ".zip"){
			json::Value rel = load("releases", it->second.release);
			json::Value by = rel.get("playtested_by").is_array() ?
					rel.get("playtested_by").deepcopy() : json::array();
			by.append(it->second.by);
			rel.set("playtested_by", by);
			put("releases", it->second.release, rel);
			log_i(MODULE, "Playtest: %s fetched %s", cs(it->second.by),
					cs(it->second.release));
		}
		return true;
	}

	bool playtested(const json::Value &rel, const ss_ &by)
	{
		const json::Value &p = rel.get("playtested_by");
		for(unsigned i = 0; p.is_array() && i < p.size(); i++)
			if(p.at(i).is_string() && p.at(i).as_string() == by)
				return true;
		return false;
	}

	json::Value handle_review(const ss_ &name, const ss_ &cmd,
			const json::Value &q)
	{
		if(cmd == "review_list"){
			// Oldest first: unreviewed (not yet, or needs changes),
			// reviewed, delisted, or all
			const ss_ f = jstr(q, "filter", "unreviewed");
			json::Value all = releases(true);
			sv_<json::Value> out;
			for(unsigned i = 0; i < all.size(); i++){
				const json::Value &r = all.at(i);
				const bool del = r.get("delisted").is_true();
				const bool rev = jstr(r, "review") == "reviewed";
				if(f == "all" || (f == "delisted" && del) ||
						(f == "reviewed" && rev && !del) ||
						(f == "unreviewed" && !rev && !del))
					out.push_back(r);
			}
			std::sort(out.begin(), out.end(), [](const json::Value &a,
					const json::Value &b){
				return a.get("time").as_number() < b.get("time").as_number();
			});
			json::Value v = json::array();
			for(const json::Value &r : out)
				v.append(r);
			return v;
		}
		const ss_ id = jstr(q, "release");
		json::Value rel = review_release(id);
		if(cmd == "review_release"){
			json::Value v = json::object();
			v.set("release", rel);
			const json::Value c = load("changelogs", id);
			v.set("changelog", c.is_object() ? jstr(c, "text") : ss_());
			sm_<ss_, ss_> files;
			files_of(unpacked(rel), "", files);
			json::Value fl = json::array();
			for(auto &f : files){
				json::Value x = json::object();
				x.set("path", f.first);
				x.set("size", (int64_t)interface::fs::file_size(f.second));
				fl.append(x);
			}
			v.set("files", fl);
			const json::Value base = review_base(rel);
			v.set("base", base.is_object() ? rel_id(base) : ss_());
			v.set("playtested", playtested(rel, name));
			json::Value hist = json::array(), entries;
			moderation::access(m_server, [&](moderation::Interface *m){
				entries = m->audit_log(this);
			});
			for(unsigned i = 0; i < entries.size(); i++)
				if(jstr(entries.at(i), "listing") == id)
					hist.append(entries.at(i));
			v.set("history", hist);
			return v;
		}
		if(cmd == "review_file"){
			sm_<ss_, ss_> files;
			files_of(unpacked(rel), "", files);
			auto it = files.find(jstr(q, "path"));
			if(it == files.end())
				throw Exception("no file "+jstr(q, "path")+" in "+id);
			const ss_ data = read_file(it->second);
			// simplified: the first 64 KiB, as a Hearth message holds less
			return json::Value(!is_text(data) ? "(binary, "+
					itos((int64_t)data.size())+" bytes)" : data.size() >
					64 * 1024 ? data.substr(0, 64 * 1024)+"\n(... "+
					itos((int64_t)data.size())+" bytes in all)" : data);
		}
		if(cmd == "review_diff")
			return review_diff(rel);
		if(cmd == "playtest"){
			Ticket t;
			t.release = id;
			t.sha = jstr(rel, "sha256");
			t.by = name;
			t.expires = now_s() + 3600;
			for(auto it = m_tickets.begin(); it != m_tickets.end();)
				it = now_s() > it->second.expires ? m_tickets.erase(it) : ++it;
			const ss_ ticket = interface::sha256::hex(
					interface::bignum::random_bytes(16));
			m_tickets[ticket] = t;
			log_i(MODULE, "Playtest: a ticket for %s to %s", cs(id), cs(name));
			json::Value v = json::object();
			v.set("ticket", ticket);
			v.set("release", id);
			v.set("sha256", t.sha);
			return v;
		}
		if(cmd == "review_mark"){
			const ss_ action = jstr(q, "action");
			const ss_ note = jstr(q, "note");
			if(note.size() > 4000)
				throw Exception("the note: at most 4000 characters");
			const ss_ pkg = jstr(rel, "author")+"/"+jstr(rel, "name");
			if(action == "reviewed"){
				rel.set("review", "reviewed");
				rel.set("review_note", "");
			} else if(action == "needs_changes"){
				if(note.empty())
					throw Exception("say what needs changing");
				rel.set("review", "needs_changes");
				rel.set("review_note", note);
			} else if(action == "relabel"){
				const ss_ a = jstr(q, "audience");
				if(a != "everyone" && a != "teen" && a != "adult")
					throw Exception("audience: everyone, teen or adult");
				rel.set("audience", a);
				json::Value lock = json::object();
				lock.set("audience", a);
				lock.set("by", name);
				put("relabels", pkg, lock);
			} else if(action == "delist"){
				rel.set("delisted", true);
			} else
				throw Exception("action: reviewed, needs_changes, relabel or "
						"delist");
			rel.set("reviewed_by", name);
			rel.set("reviewed_at", now_s());
			put("releases", id, rel);
			const ss_ text = action == "relabel" ? "to "+jstr(rel,
					"audience")+(note.empty() ? "" : ": "+note) : note;
			const ss_ how = playtested(rel, name) ? "playtested" :
					"not playtested";
			moderation::access(m_server, [&](moderation::Interface *m){
				m->audit(this, name, id, action, how, text, false, false);
				if(action == "delist" || action == "relabel")
					m->statement(this, subject(id), action == "delist" ?
							"delisted" : "relabelled", "review", text, name);
			});
			log_i(MODULE, "%s: %s %s (%s)", cs(name), cs(action), cs(id),
					cs(how));
			return rel;
		}
		throw Exception("no such command: "+cmd);
	}

	// -- builtin/moderation's Host: a subject is a release, its owner the
	// account its author is bound by. The review audits and states
	// through it; reports ([AITTA_REPORTS]) are grouped by release and
	// reason, and Aitta's moderators and admins decide them.
	storage::Save* save(){ return m_save; }
	ss_ name(){ return "Aitta"; }
	json::Value subject(const ss_ &id)
	{
		const json::Value rel = load(is_page(id) ? "pages" : "releases", id);
		if(!rel.is_object())
			return json::Value();
		json::Value s = json::object();
		s.set("id", id);
		s.set("name", is_page(id) ? "the page of "+id : id);
		s.set("owner", jstr(load("authors", jstr(rel, "author")), "account"));
		return s;
	}
	sv_<ss_> members(const json::Value &g){ return {jstr(g, "listing")}; }
	int severity(const ss_ &reason)
	{
		auto it = REASONS.find(reason);
		return it == REASONS.end() ? 0 : it->second;
	}
	json::Value thresholds(const json::Value &g)
	{
		const json::Value th = setting("thresholds");
		const json::Value &t = th.get(jstr(g, "reason"));
		return t.is_object() ? t : th.get("default");
	}
	ss_ held(const json::Value &rep)
	{
		const json::Value k = load("reporters", jstr(rep, "key"));
		return k.get("muted_until").is_number() &&
				k.get("muted_until").as_number() > now_s() ?
				"a key whose reports were mostly rejected" : "";
	}
	// One per network: anonymous reports are free to make
	ss_ bucket(const json::Value &rep){ return "net:"+jstr(rep, "address"); }
	json::Value auto_act(const json::Value &g, const ss_ &id,
			const ss_ &want)
	{
		const char *st = is_page(id) ? "pages" : "releases";
		json::Value rel = load(st, id);
		if(!rel.is_object())
			return json::Value();
		if(want == "delist")
			rel.set("delisted", true);
		else
			rel.set("hidden", true);
		rel.set("status_auto", true);
		rel.set("delisted_why", "reported for "+jstr(g, "reason")+
				"; out of the list until a moderator looks");
		put(st, id, rel);
		return subject(id);
	}
	// q: {action (unreview, delist, delist_package, bar), text, days (a
	// bar's; 0 until a moderator lifts it)}
	void uphold(moderation::Interface *m, const ss_ &by,
			const json::Value &g, const json::Value &q)
	{
		const ss_ id = jstr(g, "listing"), reason = jstr(g, "reason"),
				action = jstr(q, "action"), text = jstr(q, "text");
		// [AITTA_PACKAGE_PAGE] A page is delisted, or its author barred
		const bool page = is_page(id);
		json::Value rel = load(page ? "pages" : "releases", id);
		if(!rel.is_object())
			throw Exception(page ? "the page has gone" : "the release has gone");
		if(action != "unreview" && action != "delist" &&
				action != "delist_package" && action != "bar")
			throw Exception("action: unreview, delist, delist_package or bar");
		if(page && action != "delist" && action != "bar")
			throw Exception("a page is delisted, or its author barred");
		const ss_ pkg = jstr(rel, "author")+"/"+jstr(rel, "name")+"/";
		ss_ stated = action == "unreview" ? "unreviewed" : action == "bar" ?
				"barred" : action == "delist" ? (page ? "page delisted" :
				"delisted") : "package delisted";
		if(page){
			rel.set("hidden", false);
			rel.set("status_auto", false);
			rel.set("delisted_why", "");
			if(action == "delist"){
				rel.set("delisted", true);
				// Its next waits for a moderator
				rel.set("moderated", true);
				rel.set("delisted_why", reason+(text.empty() ? "" : ": "+text));
			}
			put("pages", id, rel);
		}
		for(const ss_ &k : page ? sv_<ss_>() : store("releases")->list(pkg)){
			json::Value o = load("releases", k);
			if(k != id && action != "delist_package")
				continue;
			// A moderator has looked: what reports did alone is theirs now
			o.set("hidden", false);
			o.set("status_auto", false);
			o.set("delisted_why", "");
			if(action == "unreview")
				o.set("review", "");
			if(action == "delist" || action == "delist_package"){
				o.set("delisted", true);
				o.set("delisted_why", reason+(text.empty() ? "" : ": "+text));
			}
			put("releases", k, o);
		}
		if(action == "delist_package")
			store("delisted_packages")->set(pkg.substr(0, pkg.size() - 1), by);
		if(action == "bar"){
			const double days = q.get("days").is_number() ?
					q.get("days").as_number() : 0;
			json::Value a = load("authors", jstr(rel, "author"));
			a.set("barred_until", days > 0 ? now_s() + (int64_t)(days * 86400) :
					(int64_t)-1);
			put("authors", jstr(rel, "author"), a);
			stated += days > 0 ? " for "+itos((int64_t)days)+" days" :
					" until a moderator lifts it";
		}
		m->audit(this, by, id, action, reason, text, false, true);
		m->statement(this, subject(id), stated, reason, text, by);
	}
	bool undo_auto(const ss_ &id, const json::Value &g)
	{
		const char *st = is_page(id) ? "pages" : "releases";
		json::Value rel = load(st, id);
		if(!rel.get("status_auto").is_true())
			return false;
		rel.set("hidden", false);
		rel.set("delisted", false);
		rel.set("status_auto", false);
		rel.set("delisted_why", "");
		// A held page ([AITTA_PACKAGE_PAGE]): a moderator has let it be
		if(is_page(id))
			rel.set("moderated", false);
		put(st, id, rel);
		return true;
	}
	// An appeal reversed: what its statement said was done, undone
	void reverse(moderation::Interface *m, const ss_ &by,
			const json::Value &a, const ss_ &text)
	{
		const ss_ id = jstr(a, "listing");
		const bool page = is_page(id);
		json::Value rel = load(page ? "pages" : "releases", id);
		if(!rel.is_object())
			return;
		const ss_ action = jstr(load("statements", jstr(a, "statement")),
				"action");
		const ss_ pkg = jstr(rel, "author")+"/"+jstr(rel, "name")+"/";
		if(page && action == "page delisted"){
			for(const char *k : {"delisted", "hidden", "status_auto",
					"moderated"})
				rel.set(k, false);
			rel.set("delisted_why", "");
			put("pages", id, rel);
		}
		for(const ss_ &k : page ? sv_<ss_>() : store("releases")->list(pkg)){
			json::Value o = load("releases", k);
			if(k != id && action != "package delisted")
				continue;
			if(action == "unreviewed")
				o.set("review", "reviewed");
			else if(action.compare(0, 6, "barred") != 0){
				o.set("delisted", false);
				o.set("hidden", false);
				o.set("status_auto", false);
				o.set("delisted_why", "");
			}
			put("releases", k, o);
		}
		if(action == "package delisted")
			store("delisted_packages")->set(pkg.substr(0, pkg.size() - 1), "");
		if(action.compare(0, 6, "barred") == 0){
			json::Value au = load("authors", jstr(rel, "author"));
			au.set("barred_until", (int64_t)0);
			put("authors", jstr(rel, "author"), au);
		}
		m->audit(this, by, id, "restore", "appeal", text, false, true);
		m->statement(this, subject(id), "restored", "appeal", text, by);
	}
	void decided(const json::Value &rep, bool upheld)
	{
		const ss_ h = jstr(rep, "key");
		if(h.empty())
			return;
		json::Value k = load("reporters", h);
		if(!k.is_object())
			k = json::object();
		const char *f = upheld ? "upheld" : "rejected";
		auto n = [&](const char *x){
			return k.get(x).is_number() ? (int64_t)k.get(x).as_number() : 0;
		};
		k.set(f, n(f) + 1);
		// Mostly rejected: not heard for a month, as on Starport
		if(n("rejected") >= 5 && n("rejected") > 3 * n("upheld"))
			k.set("muted_until", now_s() + 30 * 86400);
		put("reporters", h, k);
	}
	// simplified: the moderators see the queue on their page; no events
	void event(const sv_<ss_> &to, const ss_ &by, const ss_ &text)
	{
		log_i(MODULE, "%s", cs(text));
	}
	// The author reads it on their Aitta page; no mail
	void notify(const json::Value &s){}

	// -----------------------------------------------------------------------
	// The app: an author binds a key; the admin delists and sets settings

	void on_req(const network::Packet &packet)
	{
		const json::Value q = json::load_string(packet.data.c_str());
		json::Value res = json::object();
		res.set("id", q.get("id"));
		ss_ name;
		bool admin = false, reviewer = false;
		accounts::access(m_server, [&](accounts::Interface *a){
			name = a->name_of(packet.sender);
			admin = !name.empty() && a->is_admin(name);
			reviewer = !name.empty() &&
					a->level(name) >= accounts::LV_MODERATOR;
		});
		ss_ error;
		json::Value result;
		if(!m_save)
			error = "Aitta is not ready";
		else if(name.empty())
			error = "join first";
		else {
			try {
				const ss_ cmd = jstr(q, "cmd");
				if(cmd.compare(0, 7, "review_") == 0 || cmd == "playtest" ||
						cmd.compare(0, 4, "mod_") == 0){
					if(!reviewer)
						throw Exception("for the reviewers: this server's "
								"moderators and admins");
					result = cmd.compare(0, 4, "mod_") == 0 ?
							handle_mod(name, cmd, q) : handle_review(name, cmd, q);
				} else
					result = handle(name, admin, reviewer, cmd, q);
			} catch(std::exception &e){
				error = e.what();
			}
		}
		res.set("ok", error.empty());
		if(error.empty())
			res.set("result", result);
		else
			res.set("error", error);
		network::access(m_server, [&](network::Interface *iface){
			iface->send(packet.sender, "ai:res", res.stringify());
		});
	}

	// [AITTA_REPORTS] The moderators' side of builtin/moderation: the
	// queue, a group, its decision, the audit log, the appeals
	json::Value handle_mod(const ss_ &name, const ss_ &cmd,
			const json::Value &q)
	{
		json::Value v;
		moderation::access(m_server, [&](moderation::Interface *m){
			if(cmd == "mod_queue")
				v = m->queue(this);
			else if(cmd == "mod_group")
				v = m->group(this, jstr(q, "group"));
			else if(cmd == "mod_decide"){
				m->decide(this, name, q);
				v = json::Value(true);
			} else if(cmd == "mod_audit")
				v = m->audit_log(this);
			else if(cmd == "mod_appeals")
				v = m->appeals(this);
			else if(cmd == "mod_decide_appeal"){
				m->decide_appeal(this, name, q);
				v = json::Value(true);
			} else
				throw Exception("no such command: "+cmd);
		});
		return v;
	}

	json::Value handle(const ss_ &name, bool admin, bool reviewer,
			const ss_ &cmd, const json::Value &q)
	{
		// [AITTA_REPORTS] An author's statements of reasons, newest first,
		// and an appeal of one
		if(cmd == "statements"){
			sv_<json::Value> mine;
			for(const ss_ &k : store("statements")->list("")){
				const json::Value st = load("statements", k);
				if(jstr(st, "owner") == name)
					mine.push_back(st);
			}
			std::sort(mine.begin(), mine.end(), [](const json::Value &a,
					const json::Value &b){
				return a.get("ts").as_number() > b.get("ts").as_number();
			});
			json::Value out = json::array();
			for(size_t i = 0; i < mine.size() && i < 100; i++)
				out.append(mine[i]);
			return out;
		}
		if(cmd == "appeal"){
			ss_ id;
			moderation::access(m_server, [&](moderation::Interface *m){
				id = m->appeal(this, name, q);
			});
			return json::Value(id);
		}
		if(cmd == "me"){
			json::Value v = json::object();
			v.set("account", name);
			v.set("admin", admin);
			v.set("reviewer", reviewer);
			const ss_ author = get("owners", name);
			v.set("author", author);
			v.set("key", author.empty() ? "" : jstr(load("authors", author), "key"));
			v.set("releases", releases(admin));
			return v;
		}
		if(cmd == "bind"){
			const ss_ author = jstr(q, "author"), key = jstr(q, "key");
			if(!get("owners", name).empty())
				throw Exception("this account has its author name already");
			if(!plain_name(author))
				throw Exception("an author name is 1 to 40 of a-z, 0-9 and _");
			if(!get("authors", author).empty())
				throw Exception("the author name \""+author+"\" is taken");
			// An uncompressed P-256 point: 04, then x and y
			if(!is_hex(key, 130) || key.compare(0, 2, "04") != 0)
				throw Exception("the key is what `bin/buildat aitta keygen` "
						"printed: 130 hex digits");
			if(!get("keys", key).empty())
				throw Exception("this key is bound already");
			json::Value a = json::object();
			a.set("author", author);
			a.set("key", key);
			a.set("account", name);
			a.set("time", now_s());
			put("authors", author, a);
			store("keys")->set(key, author);
			store("owners")->set(name, author);
			log_i(MODULE, "%s bound the author name %s to a key", cs(name),
					cs(author));
			return json::Value(true);
		}
		if(cmd == "delist" || cmd == "relist"){
			if(!admin)
				throw Exception("only the admin delists");
			const ss_ id = jstr(q, "release");
			json::Value rel = load("releases", id);
			if(!rel.is_object())
				throw Exception("no release "+id);
			rel.set("delisted", cmd == "delist");
			// [SERVE_DELISTED] Why, as a moderator's: "<reason>: <text>",
			// which a server following the Aitta reads in the list
			const ss_ text = jstr(q, "text"), reason = jstr(q, "reason");
			if(!reason.empty() && !REASONS.count(reason))
				throw Exception("reason: one of the report reasons");
			rel.set("delisted_why", cmd == "relist" ? ss_() : reason.empty() ?
					text : reason+(text.empty() ? "" : ": "+text));
			put("releases", id, rel);
			// In the audit log the moderators read, and told to the owner,
			// as a moderator's delist is: the admin does not undo one
			// unseen ([SEC_RUN4_LEFTOVERS])
			moderation::access(m_server, [&](moderation::Interface *m){
				m->audit(this, name, id, cmd, "admin", text, false);
				m->statement(this, subject(id), cmd == "delist" ?
						"delisted" : "relisted", "the admin's decision", text,
						name);
			});
			log_i(MODULE, "%s: %s %s", cs(name), cs(cmd), cs(id));
			return json::Value(true);
		}
		// [AITTA_SETTINGS_PAGE] Every setting, the defaults under the
		// stored ones, for the admin's Settings page
		if(cmd == "settings"){
			if(!admin)
				throw Exception("only the admin reads settings");
			json::Value r = default_settings();
			for(json::Iterator it(m_settings); it.valid(); it.next())
				r.set(it.key(), it.value());
			return r;
		}
		// Settings by name, each one default_settings has
		if(cmd == "set_settings"){
			if(!admin)
				throw Exception("only the admin sets settings");
			const json::Value &s = q.get("settings");
			if(!s.is_object())
				throw Exception("settings: an object");
			json::Value next = m_settings.deepcopy();
			for(json::Iterator it(s); it.valid(); it.next()){
				if(default_settings().get(it.key()).is_undefined())
					throw Exception("no such setting: "+it.key());
				next.set(it.key(), it.value());
			}
			m_settings = next;
			put("settings", "settings", m_settings);
			log_i(MODULE, "%s set %s", cs(name), cs(s.stringify()));
			return m_settings;
		}
		throw Exception("no such command: "+cmd);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
// vim: set noet ts=4 sw=4:
