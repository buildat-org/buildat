// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// **Hearth** ([HEARTH_MVP], doc/plan/forum_plan.md): a forum, as an app.
// Topics, threads under them and messages in those, each at a permanent
// address; an edit keeps what it replaced.
//
// Two faces. **To read**: plain HTML on the server's own port, claimed
// from builtin/network -- what a search engine indexes and a pasted link
// opens:
//   /                the portal: the topics, the latest threads, search
//   /topic/<id>      a topic's threads
//   /t/<id>          a thread, every message under its anchor #m<id>
//   /m/<id>          one message, with the way to its thread
//   /search?q=...    FTS5 over the titles and the messages
//   /f/<id>          an uploaded file ([FORUM] step 5), kept by its use
//   /p/<author>/<name>  a package's place: the threads about it
//   /brand/<file>    the pages' font and logo ([HTML_BRAND])
//   /api/v1/discussed   one recent message as JSON, open to any site
//                    ([HEARTH_DISCUSSED_API]); see discussed()
//   /api/v1/feed     the recent threads as JSON, for a launcher
//                    ([LIVELY_MENU]); see feed()
// **To take part**: the buildat client, joined by builtin/accounts (a local
// account or a Starport ID, as the admin set up its logins). "hr:req"
// carries a JSON {id, cmd, ...} and "hr:res" the answer {id, ok, result |
// error}; handle() says who may do what. Pushed to a client: "hr:new"
// {thread, message} when the thread it has open gets a message (a chat
// runs on it), "hr:notify" {unseen} when it has a notification, and
// "hr:activity" {thread, topic, parent, author, time} for any new message.
//
// The records are one SQLite file, <user>/apps/<app>/hearth.sqlite, with
// a full-text index beside them; every statement binds its values.
//
// **Before the public** ([HEARTH_MVP] step 6, [TRUST_LADDER]): levels --
// a new account, a member (trusted: five active days, or a helper's or a
// moderator's approval; a message hidden in the last 30 days puts it
// back), a helper, a moderator, the admin -- with rate limits by level; a
// new account's first link held for approval; reports of a message,
// weighed by network, that hide it until a moderator looks; a queue for
// the moderators, a hidden message's statement of reasons to its author,
// and the author's appeal.
// simplified: Hearth's own queue; Starport's reports, appeals and audit
// log shared as a builtin is the upgrade, once a third app wants them.
//
// **A release is a thread** ([PACKAGE_SUBJECT], the first slice): the
// admin names the Aittas this Hearth reads and the addresses it is known
// by ("release_sources"). Each minute a thread of its own asks those
// Aittas for their lists, and a release whose manifest names one of the
// addresses as its home Hearth gets a thread of kind "release" in the
// topic "Releases" -- its version, its description and its changelog --
// by "<author> (Aitta)", which no account can be called. Nothing is sent
// to Hearth: it fetches, and only from where its admin said.
#include "core/log.h"
#include "core/json.h"
#include "interface/sha256.h"
#include "interface/os.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/bignum.h"
#include "interface/markup.h"
#include "interface/web_brand.h"
#include "client_file/api.h"
#include "network/api.h"
#include "accounts/api.h"
#include "starport_announce/api.h"
#include <sqlite3.h>
#include "storage/sqlite_stmt.h"
#include <ctime>
#include <cstring>
#include <set>
#include <tuple>
#include <thread>
#include <algorithm>
#include <chrono>
#include <mutex>
#include <atomic>
#include <condition_variable>
#include <random>
#include <map>
#include "interface/http.h"
#include <vector>
// [FORUM] step 5: an upload is read and written again. stb_image reads only
// PNG and JPEG here; Urho3D's stb_image_write (1.02) has no JPEG, so 1.16 is
// vendored beside this file. Both static, apart from libUrho3D's copies.
#define STB_IMAGE_IMPLEMENTATION
#define STB_IMAGE_STATIC
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_MAX_DIMENSIONS 16384
#include <STB/stb_image.h>
#define STB_IMAGE_WRITE_IMPLEMENTATION
#define STB_IMAGE_WRITE_STATIC
#define STBI_WRITE_NO_STDIO
#include "vendor/stb_image_write.h"

using json::jstr;
using json::jint;
using interface::sha256::unhex;

// stb_image's <limits.h> has a NAME_MAX of its own; Hearth's is below
#undef NAME_MAX
#define MODULE "main"

using interface::Event;

// [SIM_CLOCK]: the calendar, which a check may move
static int64_t now_s(){ return interface::os::wall_us() / 1000000; }

// An address as compared: the scheme and host in lower case, no trailing /
static ss_ norm_url(ss_ u)
{
	while(!u.empty() && u.back() == '/')
		u.pop_back();
	const size_t path = u.find('/', u.find("://") == ss_::npos ? 0 :
			u.find("://") + 3);
	for(size_t i = 0; i < u.size() && i < path; i++)
		u[i] = tolower((unsigned char)u[i]);
	return u;
}

// What a user writes: up to `max` bytes, no control bytes but a tab and,
// where lines are allowed, a line break
static ss_ text_ok(const ss_ &s, size_t max, bool lines, const char *what)
{
	if(s.empty())
		return ss_(what)+" is empty";
	if(s.size() > max)
		return ss_(what)+" is "+itos((int64_t)max)+" bytes at most";
	for(char c : s)
		if((unsigned char)c < 0x20 && c != '\t' && !(lines && c == '\n'))
			return ss_(what)+" has a control character";
	return "";
}

using interface::web_brand::html;

// A search as FTS5 reads it: each word a quoted string, so nothing a user
// types is the query language; the last one a prefix
static ss_ fts_query(const ss_ &q)
{
	ss_ out, word;
	auto flush = [&](bool last){
		if(word.empty())
			return;
		ss_ quoted = "\"";
		for(char c : word)
			quoted += c == '"' ? ss_("\"\"") : ss_(1, c);
		out += (out.empty() ? "" : " ")+quoted+"\""+(last ? "*" : "");
		word.clear();
	};
	for(char c : q){
		if(c == ' ' || c == '\t' || c == '\n')
			flush(false);
		else
			word += c;
	}
	flush(true);
	return out;
}

// [FORUM] step 5: an upload, and what is held of it
static const size_t UPLOAD_MAX = 16 * 1024 * 1024;
static const int64_t PIXELS_MAX = 40 * 1000 * 1000;
static const int UPLOADS_AN_HOUR = 20;
// The admin's "files": the budget in bytes, and the seconds unused after
// which an image is crushed again and a file is deleted
static const char *const FILE_SETTINGS[3] = {"budget", "lod2_after",
		"delete_after"};

static void append_cb(void *to, void *data, int size)
{
	((ss_*)to)->append((const char*)data, size);
}

// An image read and written again, its long side at most `long_max` and
// its short side at most `short_max`, each pixel the mean of those it
// covers: nothing of the upload's encoding is kept, its metadata (where a
// photo was taken) with it. A JPEG stays a JPEG at `quality`; a PNG stays
// a PNG.
// simplified: one quality for every JPEG, and a PNG as stb writes it; the
// plan's per-image perceptual check and pngcrush's palette are the upgrade.
// A photo's EXIF orientation is dropped with the rest, so a phone's shot
// that relied on it stands on its side.
static ss_ crush(const ss_ &in, bool jpeg, int long_max, int short_max,
		int quality)
{
	int w, h, n;
	const stbi_uc *src = (const stbi_uc*)in.data();
	if(in.size() > INT_MAX ||
			!stbi_info_from_memory(src, (int)in.size(), &w, &h, &n))
		throw Exception("not an image Hearth can read");
	if((int64_t)w * h > PIXELS_MAX)
		throw Exception("the image has over "+itos(PIXELS_MAX / 1000000)+
				" million pixels");
	stbi_uc *p = stbi_load_from_memory(src, (int)in.size(), &w, &h, &n, 0);
	if(!p)
		throw Exception(ss_("the image cannot be read: ")+
				stbi_failure_reason());
	const double s = std::min(1.0, std::min((double)long_max /
			std::max(w, h), (double)short_max / std::min(w, h)));
	const int nw = std::max(1, (int)(w * s + 0.5));
	const int nh = std::max(1, (int)(h * s + 0.5));
	std::vector<stbi_uc> out((size_t)nw * nh * n);
	std::vector<uint64_t> sum(n);
	for(int y = 0; y < nh; y++){
		const int y0 = (int)((int64_t)y * h / nh);
		const int y1 = std::max(y0 + 1, (int)((int64_t)(y + 1) * h / nh));
		for(int x = 0; x < nw; x++){
			const int x0 = (int)((int64_t)x * w / nw);
			const int x1 = std::max(x0 + 1, (int)((int64_t)(x + 1) * w / nw));
			std::fill(sum.begin(), sum.end(), 0);
			for(int yy = y0; yy < y1; yy++)
				for(int xx = x0; xx < x1; xx++)
					for(int c = 0; c < n; c++)
						sum[c] += p[((size_t)yy * w + xx) * n + c];
			const uint64_t area = (uint64_t)(y1 - y0) * (x1 - x0);
			for(int c = 0; c < n; c++)
				out[((size_t)y * nw + x) * n + c] =
						(stbi_uc)((sum[c] + area / 2) / area);
		}
	}
	stbi_image_free(p);
	ss_ r;
	if(!(jpeg ? stbi_write_jpg_to_func(append_cb, &r, nw, nh, n,
			out.data(), quality) : stbi_write_png_to_func(append_cb, &r,
			nw, nh, n, out.data(), nw * n)))
		throw Exception("the image could not be written");
	return r;
}

// How recently a topic or a thread was written in ([HEARTH_BLOBS]): the
// medium blob within a day, the small one within a week, else nothing
static ss_ blob(int64_t last)
{
	const int64_t age = now_s() - last;
	if(last <= 0 || age > 7 * 86400)
		return "";
	return age <= 86400 ?
			" <span class=\"blob\" title=\"written in today\">\u25cf</span>" :
			" <span class=\"blob\" title=\"written in this week\">\u2022</span>";
}

static ss_ time_text(int64_t t)
{
	const struct tm tmv = interface::os::utc_tm(t);
	char buf[32];
	strftime(buf, sizeof buf, "%Y-%m-%d %H:%M UTC", &tmv);
	return buf;
}

// One statement: values bound in order, columns read by index; prepared
// once and kept (storage/sqlite_stmt.h), or with `cached` false for SQL
// made with values in it
static sqlite_stmt::Cache g_stmts;
struct Q: public sqlite_stmt::Stmt
{
	Q(sqlite3 *db, const char *sql, bool cached = true):
		Stmt(db, cached ? &g_stmts : nullptr, sql, "hearth: "){}
};

static const char *SCHEMA =
	"PRAGMA journal_mode=WAL;"
	"CREATE TABLE IF NOT EXISTS topics(id INTEGER PRIMARY KEY, "
		"parent INTEGER NOT NULL DEFAULT 0, name TEXT NOT NULL, "
		"about TEXT NOT NULL DEFAULT '', "
		// [HEARTH_TRACKER]: its threads are tickets, and a patch is one
		"tracker INTEGER NOT NULL DEFAULT 0);"
	// subject: what the thread is about, a package's "author/name" and key
	// ([PACKAGE_SUBJECT]); stored, and nothing reads it yet
	"CREATE TABLE IF NOT EXISTS threads(id INTEGER PRIMARY KEY, "
		"topic INTEGER NOT NULL, title TEXT NOT NULL, author TEXT NOT NULL, "
		"created INTEGER NOT NULL, last INTEGER NOT NULL, "
		"subject TEXT NOT NULL DEFAULT '', "
		// "This answered it": the message the asker marked, or 0
		"answer INTEGER NOT NULL DEFAULT 0, "
		// Its first message hidden: the thread with it
		"hidden INTEGER NOT NULL DEFAULT 0, "
		// "" a discussion, "question", "problem", "idea", or "release" a
		// package's release
		"kind TEXT NOT NULL DEFAULT '', "
		// A problem's: "open", "confirmed", "fixed" or "wontfix"; the
		// version it was reported in, and the one that fixed it
		"status TEXT NOT NULL DEFAULT '', "
		"version TEXT NOT NULL DEFAULT '', "
		"fixed_in TEXT NOT NULL DEFAULT '', "
		// A ticket's tracker link ([HEARTH_TRACKER]) and who set it
		"link TEXT NOT NULL DEFAULT '', "
		"link_by TEXT NOT NULL DEFAULT '');"
	"CREATE TABLE IF NOT EXISTS messages(id INTEGER PRIMARY KEY, "
		"thread INTEGER NOT NULL, author TEXT NOT NULL, body TEXT NOT NULL, "
		"created INTEGER NOT NULL, edited INTEGER NOT NULL DEFAULT 0, "
		// A moderator's hiding, and its statement of reasons
		"hidden INTEGER NOT NULL DEFAULT 0, "
		"hidden_reason TEXT NOT NULL DEFAULT '');"
	// The admin's: "release_sources" -> {aittas: [url], addresses: [url]}
	"CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, "
		"value TEXT NOT NULL);"
	// A release's thread, by "author/name/version key", made once
	"CREATE TABLE IF NOT EXISTS release_threads(release TEXT PRIMARY KEY, "
		"thread INTEGER NOT NULL);"
	"CREATE INDEX IF NOT EXISTS messages_thread ON messages(thread, id);"
	"CREATE INDEX IF NOT EXISTS messages_author ON messages(author, created);"
	// What an edit replaced, and who made the edit
	"CREATE TABLE IF NOT EXISTS edits(message INTEGER NOT NULL, "
		"body TEXT NOT NULL, time INTEGER NOT NULL, editor TEXT NOT NULL);"
	// A row per message, its rowid the message's id; a thread's title is
	// on its first message
	"CREATE VIRTUAL TABLE IF NOT EXISTS search USING fts5(title, body);"
	// Who follows a thread: whoever started it or wrote in it, and whoever
	// asked to
	"CREATE TABLE IF NOT EXISTS follows(account TEXT NOT NULL, "
		"thread INTEGER NOT NULL, PRIMARY KEY(account, thread));"
	// kind: "reply" (in a followed thread), "mention" (@name), "answer"
	// (a message of theirs answered a thread)
	"CREATE TABLE IF NOT EXISTS notifications(id INTEGER PRIMARY KEY, "
		"account TEXT NOT NULL, kind TEXT NOT NULL, thread INTEGER NOT NULL, "
		"message INTEGER NOT NULL, by TEXT NOT NULL, time INTEGER NOT NULL, "
		"seen INTEGER NOT NULL DEFAULT 0, "
		// A moderator's statement of reasons, for "hidden" and "appeal"
		"note TEXT NOT NULL DEFAULT '');"
	"CREATE INDEX IF NOT EXISTS notifications_account ON "
		"notifications(account, id);"
	// When an account first joined Hearth, and the threads it has read:
	// what its trust grows from
	"CREATE TABLE IF NOT EXISTS members(account TEXT PRIMARY KEY, "
		"first_seen INTEGER NOT NULL);"
	"CREATE TABLE IF NOT EXISTS reads(account TEXT NOT NULL, "
		"thread INTEGER NOT NULL, PRIMARY KEY(account, thread));"
	// The days (UTC, seconds / 86400) an account read a thread on
	"CREATE TABLE IF NOT EXISTS active_days(account TEXT NOT NULL, "
		"day INTEGER NOT NULL, PRIMARY KEY(account, day));"
	// kind "report" (of a message, by anyone) or "appeal" (of its hiding,
	// by its author); state "open", "upheld" or "dismissed"
	"CREATE TABLE IF NOT EXISTS reports(id INTEGER PRIMARY KEY, "
		"kind TEXT NOT NULL, message INTEGER NOT NULL, by TEXT NOT NULL, "
		"reason TEXT NOT NULL, time INTEGER NOT NULL, "
		"state TEXT NOT NULL DEFAULT 'open', handled_by TEXT NOT NULL DEFAULT '', "
		"handled_time INTEGER NOT NULL DEFAULT 0, "
		"statement TEXT NOT NULL DEFAULT '', "
		// [TRUST_LADDER] A report's network (address_bin(), kept while it
		// is open) and weight
		"bin TEXT NOT NULL DEFAULT '', weight INTEGER NOT NULL DEFAULT 0);"
	// [TRUST_LADDER] Who trusted an account, when, and by which held
	// message if by one
	"CREATE TABLE IF NOT EXISTS approvals(account TEXT NOT NULL, "
		"by TEXT NOT NULL, time INTEGER NOT NULL, "
		"message INTEGER NOT NULL DEFAULT 0);"
	// [FORUM] step 5: what was uploaded, at /f/<id>. lod 0 a file kept as
	// it came (not an image), 1 an image as crushed on upload, 2 crushed
	// again; "used" when a person last fetched it (or its upload)
	"CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY, "
		"name TEXT NOT NULL, type TEXT NOT NULL, data BLOB NOT NULL, "
		"lod INTEGER NOT NULL, uploader TEXT NOT NULL, "
		"created INTEGER NOT NULL, used INTEGER NOT NULL);"
	// The files a message names (/f/<id>), so a file only hidden messages
	// name is not served ([SEC_HEARTH_FILES])
	"CREATE TABLE IF NOT EXISTS file_links(file INTEGER NOT NULL, "
		"message INTEGER NOT NULL, PRIMARY KEY(file, message)) "
		"WITHOUT ROWID;";

// [DB_INDEXES]: what the pages, the limits and the queue look up by.
// After COLUMNS_ADDED, whose columns some of them are on.
static const char *INDEXES =
	"CREATE INDEX IF NOT EXISTS threads_topic ON threads(topic, hidden, last);"
	"CREATE INDEX IF NOT EXISTS threads_last ON threads(hidden, last);"
	"CREATE INDEX IF NOT EXISTS threads_author ON threads(author, created);"
	"CREATE INDEX IF NOT EXISTS edits_editor ON edits(editor, time);"
	"CREATE INDEX IF NOT EXISTS edits_message ON edits(message);"
	"CREATE INDEX IF NOT EXISTS reports_by ON reports(by, time);"
	"CREATE INDEX IF NOT EXISTS reports_state ON reports(state);"
	"CREATE INDEX IF NOT EXISTS follows_thread ON follows(thread);"
	"CREATE INDEX IF NOT EXISTS reads_thread ON reads(thread);"
	"CREATE INDEX IF NOT EXISTS topics_parent ON topics(parent);"
	// [HEARTH_NEW_MARKS]: a topic's "Mark all read", per account: nothing
	// in it older than `time` is unread
	"CREATE TABLE IF NOT EXISTS topic_reads(account TEXT NOT NULL, "
		"topic INTEGER NOT NULL, time INTEGER NOT NULL, "
		"PRIMARY KEY(account, topic));"
	// [HEARTH_THANKS]: one row an account a message; a thanks taken back
	// keeps its row, not active, so giving it again tells no one twice
	"CREATE TABLE IF NOT EXISTS thanks(message INTEGER NOT NULL, "
		"account TEXT NOT NULL, time INTEGER NOT NULL, "
		"active INTEGER NOT NULL DEFAULT 1, PRIMARY KEY(message, account));";

static const char *const COLUMNS_ADDED[][3] = {
	{"threads", "answer", "INTEGER NOT NULL DEFAULT 0"},
	{"threads", "hidden", "INTEGER NOT NULL DEFAULT 0"},
	{"messages", "hidden", "INTEGER NOT NULL DEFAULT 0"},
	{"messages", "hidden_reason", "TEXT NOT NULL DEFAULT ''"},
	{"notifications", "note", "TEXT NOT NULL DEFAULT ''"},
	{"threads", "kind", "TEXT NOT NULL DEFAULT ''"},
	{"threads", "status", "TEXT NOT NULL DEFAULT ''"},
	{"threads", "version", "TEXT NOT NULL DEFAULT ''"},
	{"threads", "fixed_in", "TEXT NOT NULL DEFAULT ''"},
	{"topics", "tracker", "INTEGER NOT NULL DEFAULT 0"},
	// [DISCUSS_SERVER]: what Hearth posts in by itself there: "servers",
	// or ""
	{"topics", "category", "TEXT NOT NULL DEFAULT ''"},
	{"threads", "link", "TEXT NOT NULL DEFAULT ''"},
	{"threads", "link_by", "TEXT NOT NULL DEFAULT ''"},
	// [HEARTH_UI]: the last message read, for what is unread since
	{"reads", "last", "INTEGER NOT NULL DEFAULT 0"},
	{"reports", "bin", "TEXT NOT NULL DEFAULT ''"},
	{"reports", "weight", "INTEGER NOT NULL DEFAULT 0"},
	// [HEARTH_NEW_MARKS]: Home's "Mark all read"; first_seen when 0.
	// Not first_seen itself, which trust grows from
	{"members", "since", "INTEGER NOT NULL DEFAULT 0"},
	// [HEARTH_ATTACHMENTS]: an image's thumbnail, at most 320x240; empty
	// for a file that is not an image, or one uploaded before thumbnails
	// until its first is asked for
	{"files", "thumb", "BLOB NOT NULL DEFAULT x''"},
	// [HEARTH_NEW_IMAGES]: 1 shown to everyone (a member's upload, or a
	// helper said), 0 as its uploader's level is (a new account's, shown
	// once it is a member), -1 taken back by a helper
	{"files", "vetted", "INTEGER NOT NULL DEFAULT 1"},
};
// What a poster picks a thread to be ([PACKAGE_SUBJECT]); "release" is
// Hearth's own
static const std::set<ss_> POSTED_KINDS = {"", "question", "problem", "idea",
		"patch"};
// A ticket's statuses ([HEARTH_TRACKER]): a problem's, and a patch's
static const std::set<ss_> STATUSES = {"open", "confirmed", "fixed", "wontfix"};
static const std::set<ss_> PATCH_STATUSES = {"open", "applied", "wontfix"};

// A package's version as a report names it: 1 to 40 of [A-Za-z0-9.+_-]
static bool version_ok(const ss_ &v)
{
	return !v.empty() && v.size() <= 40 && v.find_first_not_of(
			"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.+_-")
			== ss_::npos;
}

// What a thread's line says it is: "problem, fixed in 1.3", "patch,
// applied in 1.4", "question", ""
static ss_ kind_text(const json::Value &t)
{
	const ss_ kind = jstr(t, "kind"), status = jstr(t, "status");
	if(kind != "problem" && kind != "patch")
		return kind;
	if(status == "fixed" || status == "applied")
		return kind+", "+status + (jstr(t, "fixed_in").empty() ? ss_() :
				" in "+jstr(t, "fixed_in"));
	return kind+", "+ss_(status == "wontfix" ? "won't fix" : status);
}

// [HEARTH_TRACKER]: a link's host, lower case, or "" for none: an http(s)
// address only, and none with a user part ("https://a.org@b.org")
static ss_ url_host(const ss_ &u)
{
	const size_t at = u.find("://");
	if(at == ss_::npos)
		return "";
	ss_ scheme = u.substr(0, at);
	for(char &c : scheme)
		c = tolower((unsigned char)c);
	if(scheme != "http" && scheme != "https")
		return "";
	const size_t end = u.find_first_of("/?#", at + 3);
	ss_ host = u.substr(at + 3, end == ss_::npos ? ss_::npos : end - at - 3);
	if(host.find('@') != ss_::npos)
		return "";
	host = host.substr(0, host.find(':'));
	for(char &c : host)
		c = tolower((unsigned char)c);
	if(host.empty() || host.find_first_not_of(
			"abcdefghijklmnopqrstuvwxyz0123456789.-") != ss_::npos)
		return "";
	return host;
}

// Where the links in a message go: each href and image of its markup, and
// every bare "scheme://" or "www." in its text; "" for one that is not an
// http(s) host (mailto:, //host). One to this Hearth's own pages ("/t/1",
// "/f/2", "#m3") is left out
static sv_<ss_> link_hosts(const ss_ &text)
{
	sv_<ss_> out;
	const ss_ h = interface::markup::to_html(text);
	for(const char *attr : {"href=\"", "src=\""}){
		for(size_t at = 0; (at = h.find(attr, at)) != ss_::npos;){
			at += strlen(attr);
			const ss_ u = h.substr(at, h.find('"', at) - at);
			if(u.empty() || u[0] == '#' || (u[0] == '/' && u.compare(0, 2, "//")))
				continue;
			out.push_back(url_host(u));
		}
	}
	ss_ t = text;
	for(char &c : t)
		c = tolower((unsigned char)c);
	for(size_t at = 0; (at = t.find("://", at)) != ss_::npos; at += 3){
		size_t b = at;
		while(b > 0 && isalpha((unsigned char)t[b - 1]))
			b--;
		const size_t e = t.find_first_of(" \t\n<>()[]\"'", at);
		out.push_back(url_host(t.substr(b, e == ss_::npos ? ss_::npos : e - b)));
	}
	for(size_t at = 0; (at = t.find("www.", at)) != ss_::npos; at += 4)
		if(at == 0 || t[at - 1] != '/')
			out.push_back(url_host("http://"+t.substr(at,
					t.find_first_of(" \t\n<>()[]\"'", at) - at)));
	return out;
}

// [HEARTH_TRACKER]: a patch as uploaded -- a .patch or .diff of text whose
// first lines look like one (what a reader sees first), 10,000 lines at
// most; shown inline and served as text
static const size_t PATCH_LINES = 10000;
static const char *PATCH_TYPE = "text/plain; charset=utf-8";
static bool is_patch(const ss_ &name, const ss_ &data)
{
	ss_ n = name;
	for(char &c : n)
		c = tolower((unsigned char)c);
	const bool named = (n.size() > 6 && n.compare(n.size() - 6, 6, ".patch")
			== 0) || (n.size() > 5 && n.compare(n.size() - 5, 5, ".diff") == 0);
	if(!named || data.find('\0') != ss_::npos ||
			(size_t)std::count(data.begin(), data.end(), '\n') > PATCH_LINES)
		return false;
	size_t at = 0;
	for(int i = 0; i < 10 && at < data.size(); i++){
		const ss_ line = data.substr(at, data.find('\n', at) - at);
		for(const char *m : {"From ", "diff --git ", "--- ", "+++ ", "@@ "})
			if(line.compare(0, strlen(m), m) == 0)
				return true;
		at += line.size() + 1;
	}
	return false;
}
static const char *CLAIMED[] = {"/topic/", "/t/", "/m/", "/search", "/f/",
		"/robots.txt", "/p/", "/brand/", "/u/", "/unseen", "/api/v1/discussed", "/api/v1/feed"};

// Trust ([HEARTH_MVP] step 6, [TRUST_LADDER]): accounts' levels, spaced so
// one added later goes between two; compared with >=, never ==. Saved as
// numbers in accounts; their names are accounts::level_name()'s.
using accounts::LV_NEW;
using accounts::LV_MEMBER;
using accounts::LV_HELPER;
using accounts::LV_MODERATOR;
using accounts::LV_ADMIN;
using accounts::level_name;
// What a level may post
struct Limits { int threads_a_day, messages_an_hour; bool links; };
static Limits limits(int lv)
{
	return lv >= LV_MODERATOR ? Limits{1000000, 1000000, true} :
			lv >= LV_HELPER ? Limits{20, 120, true} :
			lv >= LV_MEMBER ? Limits{10, 60, true} : Limits{2, 10, false};
}
// messages.hidden: by a moderator (with a statement), a new account's
// link held for approval, or hidden by reports until a moderator looks
static const int HIDDEN = 1, HELD = 2, REPORTED = 3, DELETED = 4;
// [HEARTH_MOD_TOOLS] A deleted message is kept this long for its appeal
// (the DSA's complaint window), then purged with its files
static const int64_t DELETED_KEEP_S = 183 * 86400;
static ss_ hidden_text(int64_t hidden, const ss_ &reason)
{
	return hidden == HELD ? "Waiting for a "+level_name(LV_HELPER)+
			" to approve its link" : hidden == REPORTED ?
			"Reported; hidden until a "+level_name(LV_MODERATOR)+" looks" :
			hidden == DELETED ? "Deleted by a "+level_name(LV_MODERATOR)+": "+
			reason : "Hidden by a "+level_name(LV_MODERATOR)+": "+reason;
}
// Approvals a day by a helper, and how long it may take one back
static const int APPROVALS_A_DAY = 20;
static const int64_t UNDO_S = 7 * 86400;
// A report weighs by its reporter's level (a member 1, a helper this);
// a network's reports count once, at their highest; at this in all a
// message is hidden until a moderator looks
static const int HIDE_WEIGHT = 3;
static const int REPORTS_A_DAY = 10;
// The days a new account is active on before it stands (level 1)
static const int ACTIVE_DAYS = 5;
// Searches a minute, per address on the HTTP face and per account by
// packet: a search is a full-text query
static const int SEARCHES_A_MINUTE = 30;
// Pages a minute per address, and the bodies of a thread's part (a page,
// an answer): one request a bounded render, so a long thread cannot hold
// the server
// simplified: per address; many addresses get many times it, and a
// limit over all of them (a budget of render time) is the upgrade
static const int PAGES_A_MINUTE = 120;
static const size_t THREAD_PART = 256 * 1024;
static const size_t TITLE_MAX = 200;
static const size_t BODY_MAX = 20000;
static const size_t NAME_MAX = 80;

struct Module: public interface::Module
{
	interface::Server *m_server;
	sqlite3 *m_db = nullptr;
	// The thread each client has open, for "hr:new"
	sm_<network::PeerId, int64_t> m_viewing;
	// The clients that have asked anything, for "hr:activity"
	std::set<network::PeerId> m_joined;
	// Searches and pages per address (or account) a minute
	network::RateTable m_searches;
	// /api/v1/discussed's pick and when it was made
	json::Value m_discussed;
	int64_t m_discussed_at = -1;
	ss_ m_discussed_path;
	// /api/v1/feed's, and when it was made
	json::Value m_feed;
	int64_t m_feed_at = -1;
	// When the files were last held to their budget (sweep_files)
	int64_t m_files_swept = 0;
	// What a request changed, sent once it is committed
	sv_<int64_t> m_new_messages;
	std::set<ss_> m_notified;
	// [PACKAGE_SUBJECT]: the release poller's thread and what it shares,
	// under m_rmutex
	struct ReleaseFound { ss_ aitta; json::Value rel; ss_ changelog; };
	std::mutex m_rmutex;
	std::condition_variable m_rwake;
	// Atomic as http_get reads it: the stop joins m_rthread, which a
	// server that does not answer held up to two minutes
	// ([STARPORT_SHUTDOWN_WAL])
	std::atomic<bool> m_rstop{false};
	bool m_rkick = true;          // poll now, not in a minute
	json::Value m_rsources;       // the admin's "release_sources"
	std::set<ss_> m_rknown;       // releases with a thread, or given up on
	int m_rpolls = 0;             // the poller's rounds, under m_rmutex
	int m_rpolls_said = 0;        // the module thread's, logged
	sv_<ReleaseFound> m_rfound;
	std::thread m_rthread;
	// [HEARTH_VISITOR_FLOW]: the Starports this server announces to (from
	// starport_announce, by the module), the servers they list (by the
	// poller, every few minutes) and the Aitta that lists each package
	sv_<ss_> m_starports;
	json::Value m_slist = json::array();
	std::map<ss_, ss_> m_rpackages;
	int64_t m_starports_at = -1;  // the module's last look, its clock

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{}

	~Module()
	{
		{
			std::lock_guard<std::mutex> lock(m_rmutex);
			m_rstop = true;
		}
		m_rwake.notify_all();
		if(m_rthread.joinable())
			m_rthread.join();
		g_stmts.finalize_all();
		if(m_db)
			sqlite3_close(m_db);
	}

	void init()
	{
		network::query_value_self_check();
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("network:http_request"));
		m_server->sub_event(this, Event::t("network:packet_received/hr:req"));
		m_server->sub_event(this, Event::t("network:client_disconnected"));
		m_server->sub_event(this, Event::t("core:tick"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("network:http_request", on_http, network::HttpRequest)
		EVENT_TYPEN("network:packet_received/hr:req", on_req, network::Packet)
		EVENT_TYPEN("network:client_disconnected", on_client_disconnected,
				network::OldClient)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
	}

	void on_client_disconnected(const network::OldClient &old)
	{
		m_viewing.erase(old.info.id);
		m_joined.erase(old.info.id);
	}

	void on_start()
	{
		// One user's clients at once, as in floorplanner
		accounts::access(m_server, [&](accounts::Interface *i){
			i->set_multiple_logins(true);
		});
		const interface::ServerConfig &c = m_server->get_config();
		const ss_ dir = c.get<ss_>("user_path")+"/apps/"+m_server->get_app_id();
		interface::fs::create_directories(dir);
		const ss_ path = dir+"/hearth.sqlite";
		if(sqlite3_open(path.c_str(), &m_db) != SQLITE_OK)
			throw Exception("hearth: cannot open "+path);
		bool fill_links;
		{ // Closed before the schema's WAL pragma, which an open read stops
			Q had(m_db, "SELECT count(*) FROM sqlite_master WHERE "
					"name = 'file_links'");
			had.step();
			fill_links = had.i(0) == 0;
		}
		char *err = nullptr;
		if(sqlite3_exec(m_db, SCHEMA, nullptr, nullptr, &err) != SQLITE_OK){
			const ss_ e = err ? err : "";
			sqlite3_free(err);
			throw Exception("hearth: the schema: "+e);
		}
		// A file from before a column (2026-10-04's first ones)
		for(const char *const *c : COLUMNS_ADDED){
			Q cols(m_db, (ss_("SELECT count(*) FROM pragma_table_info('")+
					c[0]+"') WHERE name = '"+c[1]+"'").c_str(), false);
			cols.step();
			if(cols.i(0) == 0){
				exec((ss_("ALTER TABLE ")+c[0]+" ADD COLUMN "+c[1]+" "+c[2])
						.c_str());
				// What was read before the position was kept counts as
				// read to its end, not as all of it new
				if(ss_(c[0]) == "reads")
					exec("UPDATE reads SET last = (SELECT ifnull(max(id), 0) "
							"FROM messages WHERE thread = reads.thread)");
			}
		}
		if(sqlite3_exec(m_db, INDEXES, nullptr, nullptr, &err) != SQLITE_OK){
			const ss_ e = err ? err : "";
			sqlite3_free(err);
			throw Exception("hearth: the indexes: "+e);
		}
		// A file from before file_links: its links from every message once
		if(fill_links){
			exec("BEGIN");
			{
				Q m(m_db, "SELECT id, body FROM messages");
				while(m.step())
					link_files(m.i(0), m.s(1));
			}
			exec("COMMIT");
		}
		network::access(m_server, [&](network::Interface *iface){
			iface->claim_http_path("/");
			for(const char *p : CLAIMED)
				iface->claim_http_path(p);
		});
		Q q(m_db, "SELECT count(*) FROM messages");
		q.step();
		log_i(MODULE, "Hearth: %lld messages in %s", (long long)q.i(0),
				cs(path));
		{
			std::lock_guard<std::mutex> lock(m_rmutex);
			m_rsources = setting("release_sources");
			Q k(m_db, "SELECT release FROM release_threads");
			while(k.step())
				m_rknown.insert(k.s(0));
		}
		m_rthread = std::thread([this](){ release_poller(); });
	}

	json::Value setting(const ss_ &key)
	{
		Q q(m_db, "SELECT value FROM settings WHERE key = ?");
		q.b(key);
		if(!q.step())
			return json::object();
		return json::load_string(q.s(0).c_str());
	}

	// -----------------------------------------------------------------------
	// [HEARTH_TRACKER]: tickets, their tracker links and patches

	// The tracker domains: a link to one is shown, whoever posted it
	std::set<ss_> tracker_domains()
	{
		std::set<ss_> out;
		const json::Value v = setting("tracker_domains");
		const json::Value &l = v.get("domains");
		for(unsigned i = 0; l.is_array() && i < l.size(); i++)
			if(l.at(i).is_string())
				out.insert(l.at(i).as_string());
		return out;
	}
	void set_tracker_domains(const std::set<ss_> &domains)
	{
		json::Value l = json::array();
		for(const ss_ &d : domains)
			l.append(d);
		json::Value v = json::object();
		v.set("domains", l);
		Q i(m_db, "INSERT OR REPLACE INTO settings(key, value) "
				"VALUES('tracker_domains', ?)");
		i.b(v.stringify()).step();
	}

	// A ticket's link is shown when its domain is whitelisted, or whoever
	// set it may post links now: the level looked up when the link is
	// shown, so one trusted now has its old links trusted too
	bool link_shown(const ss_ &link, const ss_ &by)
	{
		return !link.empty() && (tracker_domains().count(url_host(link)) ||
				level(by) >= LV_MEMBER);
	}

	// The patches a message links to (/f/<id>), their text inline, at most
	// PATCH_INLINE bytes of them; shown is a use, as a fetch is
	static const size_t PATCH_INLINE = 256 * 1024;
	// The file ids a body names as /f/<id>, in order, each once
	static std::vector<int64_t> file_ids(const ss_ &body)
	{
		std::vector<int64_t> out;
		std::set<int64_t> seen;
		for(size_t at = 0; (at = body.find("/f/", at)) != ss_::npos; at += 3){
			size_t e = at + 3;
			while(e < body.size() && e - at < 18 && isdigit((unsigned char)body[e]))
				e++;
			const int64_t id = atoll(body.substr(at + 3, e - at - 3).c_str());
			if(e != at + 3 && seen.insert(id).second)
				out.push_back(id);
		}
		return out;
	}

	// Whether /f/<id> is served: named only by hidden (or held) messages,
	// or in hidden threads, it is not ([SEC_HEARTH_FILES]). Named by none,
	// it is its uploader's yet, by an id nobody guesses.
	bool file_served(int64_t id)
	{
		Q l(m_db, "SELECT count(*), ifnull(sum(m.hidden = 0 AND "
				"t.hidden = 0), 0) FROM file_links k JOIN messages m ON "
				"m.id = k.message JOIN threads t ON t.id = m.thread "
				"WHERE k.file = ?");
		l.b(id).step();
		return !(l.i(0) > 0 && l.i(1) == 0);
	}

	// [HEARTH_ATTACHMENTS] An image's thumbnail, at most 320x240, from
	// the image as it is kept; the same read and resize as the upload's
	static ss_ make_thumb(const ss_ &data, const ss_ &type)
	{
		return crush(data, type == "image/jpeg", 320, 240, 80);
	}

	// A file's bytes and type, or with `thumb` an image's thumbnail (made
	// and kept on its first ask for one uploaded before thumbnails, and
	// the file itself for one that is not an image); false for none.
	// Fetched is a use, the thumbnail too: it is what a reader sees
	bool file_data(int64_t id, bool thumb, ss_ &type, ss_ &data)
	{
		Q f(m_db, "SELECT type, data, lod, thumb FROM files WHERE id = ?");
		f.b(id);
		if(!f.step())
			return false;
		type = f.s(0);
		data = thumb && f.i(2) > 0 ? f.s(3) : f.s(1);
		if(thumb && f.i(2) > 0 && data.empty()){
			try {
				data = make_thumb(f.s(1), type);
			} catch(std::exception &e){
				log_w(MODULE, "Hearth: file %lld: no thumbnail: %s",
						(long long)id, e.what());
				data = f.s(1);
			}
			Q t(m_db, "UPDATE files SET thumb = ? WHERE id = ?");
			t.blob(data).b(id).step();
		}
		Q u(m_db, "UPDATE files SET used = ? WHERE id = ?");
		u.b(now_s()).b(id).step();
		return true;
	}

	// [HEARTH_NEW_IMAGES] Whether a file is shown to everyone, by its
	// `vetted` (files) and its uploader's level now: a new account's once
	// it is a member, unless a helper took it back
	bool file_vetted(int64_t vetted, const ss_ &uploader)
	{
		return vetted > 0 || (vetted == 0 && level(uploader) >= LV_MEMBER);
	}

	// [HEARTH_ATTACHMENTS] The files a message names, in its order: id,
	// name, type, bytes, and drawn when its text draws it (an image span
	// of /f/<id>, as the thumbnail or in full). A patch is left out: it
	// is shown whole under the message already. Gone ones are left out.
	// [HEARTH_NEW_IMAGES]: vet (files.vetted), vetted, and shown: vetted,
	// or the viewer a helper or above (`helper`)
	json::Value files_of(const ss_ &body, bool helper = false)
	{
		json::Value out = json::array();
		const std::vector<int64_t> ids = file_ids(body);
		if(ids.empty())
			return out;
		const ss_ h = interface::markup::to_html(body);
		for(int64_t id : ids){
			Q f(m_db, "SELECT name, type, length(data), lod, vetted, uploader "
					"FROM files WHERE id = ?");
			f.b(id);
			if(!f.step() || f.s(1) == PATCH_TYPE)
				continue;
			json::Value v = json::object();
			v.set("id", id);
			v.set("name", f.s(0));
			v.set("type", f.s(1));
			v.set("bytes", f.i(2));
			v.set("image", f.i(3) > 0);
			const bool vetted = file_vetted(f.i(4), f.s(5));
			v.set("vet", f.i(4));
			v.set("vetted", vetted);
			v.set("shown", vetted || helper);
			v.set("drawn", h.find("<img src=\"/f/"+itos(id)+"/") != ss_::npos ||
					h.find("<img src=\"/f/"+itos(id)+"\"") != ss_::npos);
			out.append(v);
		}
		return out;
	}

	void link_files(int64_t message_id, const ss_ &body)
	{
		Q d(m_db, "DELETE FROM file_links WHERE message = ?");
		d.b(message_id).step();
		for(int64_t id : file_ids(body)){
			Q i(m_db, "INSERT OR IGNORE INTO file_links(file, message) "
					"VALUES(?, ?)");
			i.b(id).b(message_id).step();
		}
	}

	json::Value patches_in(const ss_ &body)
	{
		json::Value out = json::array();
		size_t total = 0;
		for(int64_t id : file_ids(body)){
			Q f(m_db, "SELECT name, data FROM files WHERE id = ? AND type = ?");
			f.b(id).b(ss_(PATCH_TYPE));
			if(!f.step())
				continue;
			ss_ text = f.s(1);
			if(total + text.size() > PATCH_INLINE)
				text = text.substr(0, total < PATCH_INLINE ? PATCH_INLINE -
						total : 0)+"\n[the rest is at /f/"+itos(id)+"]\n";
			total += text.size();
			Q u(m_db, "UPDATE files SET used = ? WHERE id = ?");
			u.b(now_s()).b(id).step();
			json::Value v = json::object();
			v.set("id", id);
			v.set("name", f.s(0));
			v.set("text", text);
			out.append(v);
		}
		return out;
	}

	// -----------------------------------------------------------------------
	// [FORUM] step 5: files, kept by use

	// The admin's "files" (FILE_SETTINGS), defaults filled in
	json::Value file_settings()
	{
		static const int64_t def[3] = {1LL << 30, 182 * 86400, 365 * 86400};
		json::Value v = setting("files");
		for(int i = 0; i < 3; i++)
			if(!v.get(FILE_SETTINGS[i]).is_number())
				v.set(FILE_SETTINGS[i], def[i]);
		return v;
	}

	// While the files take more than the budget, the longest unused go
	// first -- an image unused for lod2_after crushed again, one unused for
	// delete_after deleted, any other file deleted at lod2_after -- and
	// nothing more once they are under it. Under the budget nothing goes.
	// simplified: an image the portal can still be browsed to is not held
	// apart; use alone keeps a file, and a link from a thread nobody reads
	// keeps none, as the plan says
	void sweep_files()
	{
		m_files_swept = now_s();
		try {
			exec("BEGIN");
			// [HEARTH_MOD_TOOLS] Deleted past the appeal's window: gone, and
			// the files only it used
			Q p(m_db, "SELECT m.id, m.body FROM messages m WHERE m.hidden = ? "
					"AND (SELECT max(handled_time) FROM reports WHERE kind = "
					"'delete' AND message = m.id) < ?");
			p.b((int64_t)DELETED).b(now_s() - DELETED_KEEP_S);
			while(p.step()){
				delete_message(p.i(0));
				for(int64_t f : file_ids(p.s(1))){
					Q d(m_db, "DELETE FROM files WHERE id = ? AND NOT EXISTS "
							"(SELECT 1 FROM file_links WHERE file = ?)");
					d.b(f).b(f).step();
				}
				log_i(MODULE, "Hearth: deleted message %lld purged",
						(long long)p.i(0));
			}
			// [SECURITY_RUN_4] An upload no message names a day on goes,
			// under the budget too: a new account's never-posted uploads
			// filled the disk at 170 MB an hour. simplified: a draft's
			// image is lost after a day; keep drafts' files to lift that
			Q n(m_db, "DELETE FROM files WHERE created < ? AND NOT EXISTS "
					"(SELECT 1 FROM file_links WHERE file = files.id)");
			n.b(now_s() - 86400).step();
			if(sqlite3_changes(m_db) > 0)
				log_i(MODULE, "Hearth: %d files no message names deleted",
						sqlite3_changes(m_db));
			const json::Value s = file_settings();
			const int64_t now = now_s(), budget = jint(s, "budget");
			const int64_t gone = now - jint(s, "delete_after");
			Q t(m_db, "SELECT coalesce(sum(length(data)), 0) FROM files");
			t.step();
			int64_t total = t.i(0);
			Q f(m_db, "SELECT id, lod, used, type, data FROM files "
					"WHERE used <= ? ORDER BY used");
			f.b(now - jint(s, "lod2_after"));
			while(total > budget && f.step()){
				const int64_t id = f.i(0), lod = f.i(1);
				const ss_ data = f.s(4);
				if(lod == 1 && f.i(2) > gone){
					const ss_ c = crush(data, f.s(3) == "image/jpeg", 960, 540,
							60);
					Q u(m_db, "UPDATE files SET data = ?, lod = 2 WHERE id = ?");
					u.blob(c).b(id).step();
					total -= (int64_t)data.size() - (int64_t)c.size();
					log_i(MODULE, "Hearth: file %lld crushed to %zu bytes",
							(long long)id, c.size());
				} else if(lod != 2 || f.i(2) <= gone){
					Q d(m_db, "DELETE FROM files WHERE id = ?");
					d.b(id).step();
					total -= (int64_t)data.size();
					log_i(MODULE, "Hearth: file %lld deleted, unused",
							(long long)id);
				}
			}
			exec("COMMIT");
		} catch(std::exception &e){
			sqlite3_exec(m_db, "ROLLBACK", nullptr, nullptr, nullptr);
			log_w(MODULE, "Hearth: the files' sweep: %s", e.what());
		}
	}

	// -----------------------------------------------------------------------
	// [PACKAGE_SUBJECT]: releases into threads

	// On its own thread: it waits on the Aittas, the module does not
	void release_poller()
	{
		for(;;){
			json::Value src;
			std::set<ss_> known;
			sv_<ss_> starports;
			{
				std::unique_lock<std::mutex> lock(m_rmutex);
				m_rwake.wait_for(lock, std::chrono::seconds(60), [this](){
					return m_rstop || m_rkick;
				});
				if(m_rstop)
					return;
				m_rkick = false;
				src = m_rsources;
				known = m_rknown;
				starports = m_starports;
			}
			std::map<ss_, ss_> packages;
			sv_<ReleaseFound> found = poll_releases(src, known, packages);
			// simplified: every Starport's list every minute, as the
			// Aittas'; Hearth announces to one or two
			const json::Value servers = poll_starports(starports);
			std::lock_guard<std::mutex> lock(m_rmutex);
			for(ReleaseFound &f : found)
				m_rfound.push_back(f);
			m_rpolls++;
			m_rpackages = packages;
			m_slist = servers;
		}
	}

	// The servers the Starports list, each with the play page of the
	// Starport that lists it
	json::Value poll_starports(const sv_<ss_> &starports)
	{
		json::Value out = json::array();
		for(const ss_ &base : starports){
			if(stopping())
				break;
			json::Value list;
			try {
				list = json::load_string(
						interface::http_get(base+"/api/v1/list", nullptr,
						&m_rstop).c_str());
			} catch(std::exception &e){
				log_w(MODULE, "The servers of %s: %s", cs(base), e.what());
				continue;
			}
			const json::Value &servers = list.get("servers");
			for(unsigned i = 0; servers.is_array() && i < servers.size();
					i++){
				json::Value v = servers.at(i).deepcopy();
				v.set("play", jstr(list, "play"));
				out.append(v);
			}
		}
		return out;
	}

	static sv_<ss_> url_list(const json::Value &v)
	{
		sv_<ss_> r;
		if(v.is_array())
			for(unsigned i = 0; i < v.size(); i++)
				if(v.at(i).is_string())
					r.push_back(norm_url(v.at(i).as_string()));
		return r;
	}

	static ss_ release_key(const json::Value &rel)
	{
		return jstr(rel, "author")+"/"+jstr(rel, "name")+"/"+
				jstr(rel, "version")+" "+jstr(rel, "key");
	}

	// The releases new to this Hearth whose home it is
	// simplified: the whole list of each Aitta every minute; a "since"
	// on Aitta's list is the upgrade once lists are long
	// packages: "author/name" -> the first Aitta that lists it
	sv_<ReleaseFound> poll_releases(const json::Value &src,
			std::set<ss_> known, std::map<ss_, ss_> &packages)
	{
		sv_<ReleaseFound> found;
		const sv_<ss_> addr = url_list(src.get("addresses"));
		const std::set<ss_> addresses(addr.begin(), addr.end());
		// simplified: twenty releases asked for a minute, found or not; the
		// rest the next minute
		int asked = 0;
		for(const ss_ &base : url_list(src.get("aittas"))){
			if(stopping())
				break;
			json::Value list;
			try {
				list = json::load_string(interface::http_get(
						base+"/api/v1/aitta/list", nullptr, &m_rstop).c_str());
			} catch(std::exception &e){
				log_w(MODULE, "Releases from %s: %s", cs(base), e.what());
				continue;
			}
			const json::Value &rels = list.get("releases");
			for(unsigned i = 0; rels.is_array() && i < rels.size(); i++){
				const json::Value &rel = rels.at(i);
				packages.emplace(jstr(rel, "author")+"/"+jstr(rel, "name"),
						base);
				const ss_ key = release_key(rel);
				if(!addresses.count(norm_url(jstr(rel, "home_hearth"))) ||
						known.count(key))
					continue;
				if(asked++ >= 20 || stopping())
					return found;
				// Asked once, found or not; not again until a restart
				// simplified: a failed fetch is not retried until a restart
				known.insert(key);
				forget_release(key);
				const ss_ id = jstr(rel, "author")+"/"+jstr(rel, "name")+
						"/"+jstr(rel, "version");
				if(id.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
						"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/") != ss_::npos)
					continue;
				try {
					const json::Value one = json::load_string(
							interface::http_get(base+"/api/v1/aitta/release?id="+
							id, nullptr, &m_rstop).c_str());
					const json::Value &r = one.get("release");
					if(!one.get("ok").is_true() || !r.is_object() ||
							!addresses.count(norm_url(jstr(r, "home_hearth"))))
						continue;
					known.insert(release_key(r));
					found.push_back({base, r, jstr(one, "changelog")});
				} catch(std::exception &e){
					log_w(MODULE, "The release %s from %s: %s", cs(id),
							cs(base), e.what());
				}
			}
		}
		return found;
	}

	void forget_release(const ss_ &key)
	{
		std::lock_guard<std::mutex> lock(m_rmutex);
		m_rknown.insert(key);
	}

	bool stopping()
	{
		std::lock_guard<std::mutex> lock(m_rmutex);
		return m_rstop;
	}

	void on_tick(const interface::TickEvent &)
	{
		if(m_db && now_s() - m_files_swept >= 3600)
			sweep_files();
		// Read on the module's thread; the poller fetches their lists
		if(m_starports_at < 0 || now_s() - m_starports_at >= 60 ||
				now_s() < m_starports_at){
			m_starports_at = now_s();
			sv_<ss_> urls;
			starport_announce::access(m_server,
					[&](starport_announce::Interface *a){
				urls = a->starports();
			});
			std::lock_guard<std::mutex> lock(m_rmutex);
			if(urls != m_starports){
				m_starports = urls;
				m_rkick = true;
				m_rwake.notify_all();
			}
		}
		sv_<ReleaseFound> found;
		int polls = 0;
		{
			std::lock_guard<std::mutex> lock(m_rmutex);
			found.swap(m_rfound);
			polls = m_rpolls;
		}
		// One line a poll, once its releases are posted: what a check
		// waits on to see that a poll made no thread
		if(polls != m_rpolls_said){
			m_rpolls_said = polls;
			log_i(MODULE, "Hearth: the release sources read, %zu new",
					found.size());
		}
		if(found.empty() || !m_db)
			return;
		for(const ReleaseFound &f : found){
			try {
				exec("BEGIN");
				post_release(f);
				exec("COMMIT");
			} catch(std::exception &e){
				sqlite3_exec(m_db, "ROLLBACK", nullptr, nullptr, nullptr);
				m_new_messages.clear();
				m_notified.clear();
				log_w(MODULE, "The release %s from %s: %s",
						cs(release_key(f.rel)), cs(f.aitta), e.what());
			}
			// Made or refused, not asked for again until a restart
			std::lock_guard<std::mutex> lock(m_rmutex);
			m_rknown.insert(release_key(f.rel));
		}
		push();
	}

	void post_release(const ReleaseFound &f)
	{
		const json::Value &rel = f.rel;
		const ss_ key = release_key(rel);
		Q k(m_db, "SELECT 1 FROM release_threads WHERE release = ?");
		k.b(key);
		if(k.step())
			return;
		const ss_ pkg = jstr(rel, "author")+"/"+jstr(rel, "name");
		const ss_ title = jstr(rel, "name")+" "+jstr(rel, "version");
		const ss_ author = jstr(rel, "author")+" (Aitta)";
		const ss_ subject = pkg+" "+jstr(rel, "key");
		ss_ body = jstr(rel, "description")+"\n\nVersion **"+
				jstr(rel, "version")+"** of `"+pkg+"`, published on "+f.aitta+
				".\n\n";
		// The problems marked fixed in this version, by the same package and
		// key; their reporters and followers are told it is out
		// simplified: the first 50
		sv_<int64_t> fixed;
		Q p(m_db, "SELECT id, title FROM threads WHERE kind = 'problem' AND "
				"status = 'fixed' AND subject = ? AND fixed_in = ? AND "
				"hidden = 0 ORDER BY id LIMIT 50");
		p.b(subject).b(jstr(rel, "version"));
		while(p.step()){
			if(fixed.empty())
				body += "## Problems it fixes\n\n";
			fixed.push_back(p.i(0));
			body += "- "+p.s(1)+" #"+itos(p.i(0))+"\n";
		}
		body += (fixed.empty() ? "" : "\n")+ss_("## Changelog\n\n");
		ss_ log = f.changelog.empty() ? ss_("No changelog came with it.") :
				f.changelog;
		// A CRLF file's \r is a control character to text_ok
		log.erase(std::remove(log.begin(), log.end(), '\r'), log.end());
		if(body.size() + log.size() > BODY_MAX){
			size_t n = BODY_MAX > body.size() + 40 ? BODY_MAX - body.size() - 40 : 0;
			while(n > 0 && (log[n] & 0xc0) == 0x80)
				n--;
			log = log.substr(0, n)+"\n\n(The rest is in the release.)";
		}
		body += log;
		const ss_ why = text_ok(title, TITLE_MAX, false, "the title") +
				text_ok(body, BODY_MAX, true, "the message");
		if(!why.empty())
			throw Exception(why);
		const int64_t topic_id = top_topic("Releases",
				"Packages released on Aitta, posted from there");
		const int64_t t = now_s();
		Q i(m_db, "INSERT INTO threads(topic, title, author, created, last, "
				"subject, kind) VALUES(?, ?, ?, ?, ?, ?, 'release')");
		i.b(topic_id).b(title).b(author).b(t).b(t).b(subject).step();
		const int64_t id = sqlite3_last_insert_rowid(m_db);
		// Whoever publishes on the Aitta mentions no one
		add_message(id, author, body, title, false);
		Q r(m_db, "INSERT INTO release_threads(release, thread) VALUES(?, ?)");
		r.b(key).b(id).step();
		for(int64_t problem : fixed){
			Q w(m_db, "SELECT author FROM threads WHERE id = ? UNION "
					"SELECT account FROM follows WHERE thread = ?");
			w.b(problem).b(problem);
			while(w.step())
				notify(w.s(0), "fixed", problem, 0, author,
						jstr(rel, "version"));
		}
		log_i(MODULE, "The release %s from %s is the thread %lld", cs(key),
				cs(f.aitta), (long long)id);
	}

	// A top-level topic Hearth posts in by itself, made the first time
	int64_t top_topic(const char *name, const char *about)
	{
		Q q(m_db, "SELECT id FROM topics WHERE parent = 0 AND name = ? "
				"ORDER BY id LIMIT 1");
		q.b(ss_(name));
		if(q.step())
			return q.i(0);
		Q i(m_db, "INSERT INTO topics(parent, name, about) VALUES(0, ?, ?)");
		i.b(ss_(name)).b(ss_(about)).step();
		return sqlite3_last_insert_rowid(m_db);
	}

	// [DISCUSS_SERVER] The topic of a category, the first; with none, a
	// top-level one made for it
	int64_t category_topic(const char *category, const char *name,
			const char *about)
	{
		Q q(m_db, "SELECT id FROM topics WHERE category = ? ORDER BY id "
				"LIMIT 1");
		q.b(ss_(category));
		if(q.step())
			return q.i(0);
		const int64_t id = top_topic(name, about);
		Q u(m_db, "UPDATE topics SET category = ? WHERE id = ?");
		u.b(ss_(category)).b(id).step();
		return id;
	}

	void exec(const char *sql)
	{
		Q q(m_db, sql, false);
		q.step();
	}

	// -----------------------------------------------------------------------
	// Reading and writing

	// [HEARTH_NEW_MARKS] Where unread starts for an account: when it first
	// opened Hearth, or its last "Mark all read" on Home
	int64_t since(const ss_ &name)
	{
		Q q(m_db, "SELECT max(first_seen, since) FROM members WHERE account = ?");
		q.b(name);
		return q.step() ? q.i(0) : now_s();
	}
// A thread (the table or alias `t`) is unread to the account ?1 whose
// start is ?2 when it has someone else's visible message after the last
// one read, after the start and after its topic's "Mark all read". The
// thread's last is a cheap first test: the newest message is its time.
#define UNREAD(t) "(" t ".last > ?2 AND EXISTS(SELECT 1 FROM messages m " \
		"WHERE m.thread = " t ".id AND m.hidden = 0 AND m.author != ?1 AND " \
		"m.id > ifnull((SELECT last FROM reads WHERE account = ?1 AND " \
		"thread = " t ".id), 0) AND m.created > max(?2, ifnull((SELECT time " \
		"FROM topic_reads WHERE account = ?1 AND topic = " t ".topic), 0))))"

	// With `name`, each topic's "unread" for that account, its subtopics'
	// threads in
	json::Value topics(const ss_ &name = "")
	{
		json::Value list = json::array();
		const ss_ sql = ss_() + "SELECT t.id, t.parent, t.name, t.about, "
				"(SELECT count(*) FROM threads WHERE topic = t.id AND hidden = 0), "
				"t.tracker, t.category, "
				// The newest thread's last, a top topic's subtopics' with it
				"(SELECT max(last) FROM threads WHERE hidden = 0 AND topic IN "
				"(SELECT id FROM topics WHERE id = t.id OR parent = t.id)), " +
				(name.empty() ? ss_("0 ") : ss_("EXISTS(SELECT 1 FROM threads "
				"WHERE hidden = 0 AND topic IN (SELECT id FROM topics WHERE "
				"id = t.id OR parent = t.id) AND " UNREAD("threads") ") ")) +
				"FROM topics t ORDER BY t.parent, t.id";
		Q q(m_db, sql.c_str());
		if(!name.empty())
			q.b(name).b(since(name));
		while(q.step()){
			json::Value t = json::object();
			t.set("id", q.i(0));
			t.set("parent", q.i(1));
			t.set("name", q.s(2));
			t.set("about", q.s(3));
			t.set("threads", q.i(4));
			t.set("tracker", q.i(5) != 0);
			t.set("category", q.s(6));
			t.set("active", q.i(7));
			if(!name.empty())
				t.set("unread", q.i(8) != 0);
			list.append(t);
		}
		return list;
	}

	json::Value topic(int64_t id)
	{
		Q q(m_db, "SELECT name, about, parent, tracker, category FROM topics "
				"WHERE id = ?");
		q.b(id);
		if(!q.step())
			return json::Value();
		json::Value t = json::object();
		t.set("id", id);
		t.set("name", q.s(0));
		t.set("about", q.s(1));
		t.set("parent", q.i(2));
		t.set("tracker", q.i(3) != 0);
		t.set("category", q.s(4));
		return t;
	}

	json::Value thread_row(Q &q)
	{
		json::Value t = json::object();
		t.set("id", q.i(0));
		t.set("topic", q.i(1));
		t.set("title", q.s(2));
		t.set("author", q.s(3));
		t.set("created", q.i(4));
		t.set("last", q.i(5));
		t.set("subject", q.s(6));
		t.set("messages", q.i(7));
		t.set("answer", q.i(8));
		t.set("hidden", q.i(9) != 0);
		t.set("kind", q.s(10));
		t.set("status", q.s(11));
		t.set("version", q.s(12));
		t.set("fixed_in", q.s(13));
		return t;
	}
#define THREAD_COLUMNS "id, topic, title, author, created, last, subject, " \
		"(SELECT count(*) FROM messages WHERE thread = threads.id), answer, " \
		"hidden, kind, status, version, fixed_in"

	// Answered ones first, then by the latest message
	// simplified: 200; paging when a topic has more
	json::Value threads(int64_t topic_id)
	{
		json::Value list = json::array();
		Q q(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE topic = ? "
				"AND hidden = 0 ORDER BY answer != 0 DESC, last DESC LIMIT 200");
		q.b(topic_id);
		while(q.step())
			list.append(thread_row(q));
		return list;
	}

	json::Value latest_threads(int n)
	{
		json::Value list = json::array();
		Q q(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE hidden = 0 "
				"ORDER BY last DESC LIMIT ?");
		q.b((int64_t)n);
		while(q.step())
			list.append(thread_row(q));
		return list;
	}

	// The thread and its messages after `after` (0: all of them), until
	// their bodies pass THREAD_PART bytes: then "more" is set, and the rest is
	// read on with `after`. A hidden message's body is its author's and the
	// admin's to see
	json::Value thread(int64_t id, int64_t after, const ss_ &viewer = "",
			bool admin = false)
	{
		Q q(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE id = ?");
		q.b(id);
		if(!q.step())
			return json::Value();
		json::Value t = thread_row(q);
		// [HEARTH_NEW_IMAGES]: a new account's images not shown yet are
		// shown to a helper, who says whether everyone sees them
		const bool helper = !viewer.empty() && level(viewer) >= LV_HELPER;
		// The tracker link, where it is shown; the one waiting for its
		// domain to its setter and the admin
		Q l(m_db, "SELECT link, link_by FROM threads WHERE id = ?");
		l.b(id).step();
		const bool shown = link_shown(l.s(0), l.s(1));
		t.set("link", shown ? l.s(0) : ss_());
		t.set("link_waiting", !shown && (admin || viewer == l.s(1)) ?
				l.s(0) : ss_());
		json::Value list = json::array();
		Q m(m_db, "SELECT id, author, body, created, edited, hidden, "
				"hidden_reason, (SELECT count(*) FROM thanks WHERE "
				"message = messages.id AND active = 1), (SELECT count(*) "
				"FROM thanks WHERE message = messages.id AND account = ? AND "
				"active = 1) FROM messages "
				"WHERE thread = ? AND id > ? ORDER BY id");
		m.b(viewer).b(id).b(after);
		size_t bytes = 0;
		bool more = false;
		while(m.step()){
			if(bytes >= THREAD_PART){
				more = true;
				break;
			}
			json::Value v = json::object();
			const bool hidden = m.i(5) != 0;
			v.set("id", m.i(0));
			v.set("author", m.s(1));
			v.set("body", hidden && !admin && viewer != m.s(1) ? ss_() : m.s(2));
			v.set("created", m.i(3));
			v.set("edited", m.i(4));
			v.set("hidden", hidden);
			v.set("hidden_reason", m.s(6));
			// What a moderator's tools offer on it ([HEARTH_MOD_TOOLS])
			v.set("author_level", (int64_t)accounts::level(m_server, m.s(1)));
			// A hidden message's thanks are kept and not shown
			v.set("thanks", hidden ? (int64_t)0 : m.i(7));
			v.set("thanked", m.i(8) != 0);
			if(hidden)
				v.set("hidden_text", hidden_text(m.i(5), m.s(6)));
			v.set("patches", patches_in(jstr(v, "body")));
			v.set("files", files_of(jstr(v, "body"), helper));
			// The client draws the page's own markup ([HEARTH_LINES_CODE])
			v.set("html", interface::markup::to_html(jstr(v, "body")));
			// A message's own bytes besides its body: many short ones fill
			// a part too
			bytes += 256 + jstr(v, "body").size() + jstr(v, "html").size();
			for(unsigned i = 0; i < v.get("patches").size(); i++)
				bytes += jstr(v.get("patches").at(i), "text").size();
			list.append(v);
		}
		t.set("list", list);
		t.set("more", more);
		return t;
	}

	// "author/name", as an Aitta and ContentDB name a package
	static bool is_package(const ss_ &pkg)
	{
		const size_t slash = pkg.find('/');
		return pkg.size() <= 81 && slash != ss_::npos && slash != 0 &&
				slash + 1 != pkg.size() && pkg.find_first_not_of(
				"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
				"0123456789_-/") == ss_::npos && pkg.find('/', slash + 1) ==
				ss_::npos;
	}

	// **What a thread is about, and where it is had** ([HEARTH_VISITOR_FLOW]),
	// by the subject's kind: a server is a play link when a Starport this
	// Hearth announces to lists it, with TLS for an https play page; an
	// app's package links its
	// place here and its Aitta page; a ContentDB game its ContentDB page;
	// anything else is its name. Nothing links a page that is not there.
	ss_ about_html(const ss_ &subject)
	{
		if(subject.rfind("server:", 0) == 0){
			const ss_ hp = subject.substr(7);
			const size_t colon = hp.rfind(':');
			const ss_ host = hp.substr(0, colon);
			const int64_t port = colon == ss_::npos ? 0 :
					atoll(hp.c_str() + colon + 1);
			std::lock_guard<std::mutex> lock(m_rmutex);
			for(unsigned i = 0; i < m_slist.size(); i++){
				const json::Value &v = m_slist.at(i);
				if(jstr(v, "host") == host && jint(v, "port") == port &&
						!play_link(v).empty())
					return "About the server "+play_link(v)+
							", played in your browser";
			}
			return "About the server "+html(hp);
		}
		if(subject.rfind("game:contentdb:", 0) == 0){
			const ss_ pkg = subject.substr(15);
			if(is_package(pkg))
				return "About the game <a href=\"https://content.luanti.org/"
						"packages/"+html(pkg)+"/\" rel=\"nofollow noopener\">"+
						html(pkg)+"</a> on ContentDB"+played_on("game",
						"contentdb:"+pkg);
		}
		if(subject.rfind("game:", 0) == 0)
			return "About the game "+html(subject.substr(
					subject.rfind(':') + 1));
		const ss_ pkg = subject.substr(0, subject.find(' '));
		if(!is_package(pkg))
			return "About "+html(subject);
		ss_ aitta;
		{
			std::lock_guard<std::mutex> lock(m_rmutex);
			auto it = m_rpackages.find(pkg);
			if(it != m_rpackages.end())
				aitta = it->second;
		}
		return "About <a href=\"/p/"+html(pkg)+"\">"+html(pkg)+"</a>"+
				(aitta.empty() ? ss_() : ", <a href=\""+html(aitta)+"/p/"+
				html(pkg)+"\">its page on Aitta</a>")+played_on("package", pkg);
	}

	// A listed server as a link to its Starport's play page, "" where that
	// page cannot join it: a page over https opens only a secure
	// WebSocket, one over http (a local Starport's) a plain one too.
	// Under m_rmutex.
	static ss_ play_link(const json::Value &v)
	{
		const ss_ play = jstr(v, "play");
		const bool secure = play.rfind("https://", 0) == 0;
		if((!secure && play.rfind("http://", 0) != 0) ||
				(secure && !v.get("tls").is_true()))
			return "";
		return "<a href=\""+html(play)+"/?server="+html(jstr(v, "host"))+":"+
				itos(jint(v, "port"))+"\" rel=\"nofollow noopener\">"+
				html(jstr(v, "name"))+"</a>";
	}

	// Up to three listed servers whose `key` is `value`, most players first
	ss_ played_on(const char *key, const ss_ &value)
	{
		std::lock_guard<std::mutex> lock(m_rmutex);
		sv_<const json::Value*> on;
		std::set<ss_> seen; // listed on two Starports, once
		for(unsigned i = 0; i < m_slist.size(); i++){
			const json::Value &v = m_slist.at(i);
			if(jstr(v, key) == value && !play_link(v).empty() &&
					seen.insert(jstr(v, "host")+":"+
					itos(jint(v, "port"))).second)
				on.push_back(&v);
		}
		std::stable_sort(on.begin(), on.end(),
				[](const json::Value *a, const json::Value *b){
			return jint(*a, "players") > jint(*b, "players");
		});
		ss_ out;
		for(size_t i = 0; i < on.size() && i < 3; i++)
			out += (i ? ", " : "<br>Play it on ")+play_link(*on[i])+" ("+
					itos(jint(*on[i], "players"))+" playing)";
		return out;
	}

	// The thread page a message is on: the `after` its link takes, 0 for
	// the first ([HEARTH_VISITOR_FLOW])
	int64_t page_after(int64_t thread_id, int64_t message_id)
	{
		int64_t after = 0;
		for(;;){
			const json::Value t = thread(thread_id, after);
			const json::Value &list = t.get("list");
			if(!t.get("more").is_true() || list.size() == 0 ||
					jint(list.at(list.size() - 1), "id") >= message_id)
				return after;
			after = jint(list.at(list.size() - 1), "id");
		}
	}

	// The address of a message where it is read: its thread's page, at it
	ss_ message_path(int64_t thread_id, int64_t message_id)
	{
		const int64_t after = page_after(thread_id, message_id);
		return "/t/"+itos(thread_id)+(after ? "?after="+itos(after) : ss_())+
				"#m"+itos(message_id);
	}

	// held: a new account's link waiting for approval ([TRUST_LADDER]),
	// in nobody's view, index or notifications but its author's
	// simplified: approved later, it tells no one, as a hide undone does
	int64_t add_message(int64_t thread_id, const ss_ &author, const ss_ &body,
			const ss_ &title, bool mention = true, bool held = false)
	{
		const int64_t t = now_s();
		Q q(m_db, "INSERT INTO messages(thread, author, body, created) "
				"VALUES(?, ?, ?, ?)");
		q.b(thread_id).b(author).b(body).b(t).step();
		const int64_t id = sqlite3_last_insert_rowid(m_db);
		link_files(id, body);
		if(held){
			hold(id, author);
			return id;
		}
		Q s(m_db, "INSERT INTO search(rowid, title, body) VALUES(?, ?, ?)");
		s.b(id).b(title).b(body).step();
		Q u(m_db, "UPDATE threads SET last = ? WHERE id = ?");
		u.b(t).b(thread_id).step();
		// Who is told: those mentioned, then the thread's other followers
		std::set<ss_> told;
		for(const ss_ &n : mention ? mentions(body) : std::set<ss_>()){
			if(n == author || told.count(n))
				continue;
			bool exists = false;
			accounts::access(m_server, [&](accounts::Interface *a){
				exists = a->exists(n);
			});
			if(exists){
				notify(n, "mention", thread_id, id, author);
				told.insert(n);
			}
		}
		Q f(m_db, "SELECT account FROM follows WHERE thread = ?");
		f.b(thread_id);
		while(f.step())
			if(f.s(0) != author && !told.count(f.s(0)))
				notify(f.s(0), "reply", thread_id, id, author);
		Q fo(m_db, "INSERT OR IGNORE INTO follows(account, thread) VALUES(?, ?)");
		fo.b(author).b(thread_id).step();
		m_new_messages.push_back(thread_id);
		m_new_messages.push_back(id);
		return id;
	}

	// "@name" in a message: a name's characters after an @ that does not
	// follow a word (an address's @ is not one)
	static std::set<ss_> mentions(const ss_ &body)
	{
		std::set<ss_> r;
		for(size_t i = 0; i < body.size(); i++){
			if(body[i] != '@' || (i > 0 && (isalnum((unsigned char)body[i - 1]) ||
					body[i - 1] == '_')))
				continue;
			size_t e = i + 1;
			while(e < body.size() && e - i <= NAME_MAX &&
					(isalnum((unsigned char)body[e]) || body[e] == '_' ||
					body[e] == '-'))
				e++;
			if(e > i + 1)
				r.insert(body.substr(i + 1, e - i - 1));
			if(r.size() >= 20)
				break;
		}
		return r;
	}

	void notify(const ss_ &account, const char *kind, int64_t thread_id,
			int64_t message_id, const ss_ &by, const ss_ &note = "")
	{
		Q n(m_db, "INSERT INTO notifications(account, kind, thread, message, "
				"by, time, note) VALUES(?, ?, ?, ?, ?, ?, ?)");
		n.b(account).b(ss_(kind)).b(thread_id).b(message_id).b(by).b(now_s())
				.b(note).step();
		m_notified.insert(account);
	}

	int64_t unseen(const ss_ &account)
	{
		Q q(m_db, "SELECT count(*) FROM notifications WHERE account = ? "
				"AND seen = 0");
		q.b(account);
		q.step();
		return q.i(0);
	}

	// After a commit: "hr:new" to whoever has the thread open, "hr:notify"
	// to whoever was notified, and "hr:activity" {thread, topic, parent,
	// author, time} to every client, which marks its rows by it
	// ([HEARTH_NEW_MARKS])
	void push()
	{
		sv_<std::tuple<network::PeerId, ss_, ss_>> out;
		for(size_t i = 0; i + 1 < m_new_messages.size(); i += 2){
			json::Value v = json::object();
			v.set("thread", m_new_messages[i]);
			v.set("message", m_new_messages[i + 1]);
			const ss_ nv = v.stringify();
			for(auto &pv : m_viewing)
				if(pv.second == m_new_messages[i])
					out.emplace_back(pv.first, "hr:new", nv);
			Q a(m_db, "SELECT t.topic, ifnull(p.parent, 0), m.author, "
					"m.created FROM messages m JOIN threads t ON "
					"t.id = m.thread LEFT JOIN topics p ON p.id = t.topic "
					"WHERE m.id = ? AND t.hidden = 0");
			a.b(m_new_messages[i + 1]);
			if(!a.step())
				continue;
			json::Value act = json::object();
			act.set("thread", m_new_messages[i]);
			act.set("topic", a.i(0));
			act.set("parent", a.i(1));
			act.set("author", a.s(2));
			act.set("time", a.i(3));
			const ss_ av = act.stringify();
			for(network::PeerId p : m_joined)
				out.emplace_back(p, "hr:activity", av);
		}
		for(const ss_ &account : m_notified){
			sv_<network::PeerId> peers;
			accounts::access(m_server, [&](accounts::Interface *a){
				peers = a->find_peers(account);
			});
			json::Value v = json::object();
			v.set("unseen", unseen(account));
			for(network::PeerId p : peers)
				out.emplace_back(p, "hr:notify", v.stringify());
		}
		m_new_messages.clear();
		m_notified.clear();
		network::access(m_server, [&](network::Interface *iface){
			for(auto &o : out)
				iface->send(std::get<0>(o), std::get<1>(o), std::get<2>(o));
		});
	}

	json::Value search(const ss_ &text)
	{
		json::Value list = json::array();
		const ss_ match = fts_query(text);
		if(match.empty())
			return list;
		// simplified: BM25, the title weighed 5 to the body's 1, and an
		// answer counted twice (BM25 is better the more negative); the other
		// signals and recency join it with the computed portal
		Q q(m_db, "SELECT m.id, m.thread, t.title, m.author, m.created, "
				"snippet(search, 1, '\x01', '\x02', '...', 24), t.last "
				"FROM search JOIN messages m ON m.id = search.rowid "
				"JOIN threads t ON t.id = m.thread "
				"WHERE search MATCH ? AND m.hidden = 0 AND t.hidden = 0 "
				"ORDER BY bm25(search, 5.0, 1.0) * "
				"(CASE WHEN t.answer = m.id THEN 2.0 ELSE 1.0 END) LIMIT 50");
		q.b(match);
		while(q.step()){
			json::Value v = json::object();
			v.set("message", q.i(0));
			v.set("thread", q.i(1));
			v.set("title", q.s(2));
			v.set("author", q.s(3));
			v.set("created", q.i(4));
			v.set("snippet", q.s(5));
			v.set("last", q.i(6));
			list.append(v);
		}
		return list;
	}

	// -----------------------------------------------------------------------
	// The HTML face

	void respond(const network::HttpRequest &r, int status, const ss_ &body,
			const ss_ &type = "text/html; charset=utf-8",
			const ss_ &extra_headers = "")
	{
		network::access(m_server, [&](network::Interface *iface){
			iface->http_respond(r.peer, status, type, body, extra_headers);
		});
	}

	// path: the page's own, which "in the browser" opens in the web client
	// ([HEARTH_OPEN_HERE]) where it is a thread's, a message's, a
	// topic's, a package's or an account's
	ss_ page(const ss_ &title, const ss_ &content, const ss_ &path = "")
	{
		ss_ app = "/app";
		for(const char *p : {"/topic/", "/t/", "/m/", "/p/", "/u/"})
			if(path.compare(0, strlen(p), p) == 0 && path.size() > strlen(p))
				app += "#open="+html(path);
		return "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\">"
				"<meta name=\"viewport\" content=\"width=device-width, "
				"initial-scale=1\"><title>"+html(title)+"</title><style>"+
				interface::web_brand::css+".blob{color:#26d9ff}"
				// The message a link pointed at
				".box:target{border:2px solid #8c33f2;background:#2b2638}"
				"</style></head><body><header>"
				"<a class=\"brand\" href=\"/\">"+interface::web_brand::logo+
				"Hearth</a>"
				"<form action=\"/search\"><input name=\"q\" size=\"24\" "
				"aria-label=\"Search\"> <button>Search</button></form>"
				"</header>\n"+content+
				"\n<p class=\"meta\">Posts are CC-BY-SA. To take part, open "
				"this server in the buildat client (<a href=\""+app+"\">"
				"in the browser</a>).</p></body></html>\n";
	}

	ss_ thread_line(const json::Value &t)
	{
		return "<li><a href=\"/t/"+itos(jint(t, "id"))+"\">"+
				html(jstr(t, "title"))+"</a>"+blob(jint(t, "last"))+
				" <span class=\"meta\">"+(kind_text(t).empty() ? ss_() : html(kind_text(t))+", ")+
				(jint(t, "answer") ? "answered, " : "")+
				html(jstr(t, "author"))+", "+itos(jint(t, "messages"))+
				" messages, last "+time_text(jint(t, "last"))+"</span></li>\n";
	}

	ss_ message_box(const json::Value &m, bool answer = false)
	{
		const ss_ id = itos(jint(m, "id"));
		if(m.get("hidden").is_true())
			return "<div class=\"box\" id=\"m"+id+"\"><p class=\"meta\">"+
					html(jstr(m, "hidden_text"))+
					"</p></div>\n";
		return "<div class=\"box"+ss_(answer ? " answer" : "")+"\" id=\"m"+id+
				"\"><p class=\"meta\">"+(jint(m, "thanks") > 0 ?
				"<span style=\"float:right\">+"+itos(jint(m, "thanks"))+
				"</span>" : "")+(answer ? "<b>This answered it:</b> " :
				"")+"<b><a href=\"/u/"+html(jstr(m, "author"))+"\">"+
				html(jstr(m, "author"))+"</a></b>, <a href=\"/m/"+id+"\">"+
				time_text(jint(m, "created"))+"</a>"+(jint(m, "edited") ?
				" (edited "+time_text(jint(m, "edited"))+")" : "")+"</p>"+
				unshown_images(interface::markup::to_html(jstr(m, "body")),
				m.get("files").is_array() ? m.get("files") :
				files_of(jstr(m, "body")))+patches_html(m)+files_html(m)+
				"</div>\n";
	}

	// A message's patches inline, the review being in the thread
	ss_ patches_html(const json::Value &m)
	{
		const json::Value ps = m.get("patches").is_array() ? m.get("patches") :
				patches_in(jstr(m, "body"));
		ss_ out;
		for(unsigned i = 0; i < ps.size(); i++)
			out += "<p class=\"meta\"><a href=\"/f/"+
					itos(jint(ps.at(i), "id"))+"\">"+html(jstr(ps.at(i), "name"))+
					"</a></p><pre><code>"+html(jstr(ps.at(i), "text"))+
					"</code></pre>";
		return out;
	}

	// A file's name as its link ends: what is not a letter, a digit, "."
	// "-" or "_" made "_", as the client writes it; the server reads only
	// the id
	static ss_ url_name(ss_ n)
	{
		for(char &c : n)
			if(!isalnum((unsigned char)c) && c != '.' && c != '-' && c != '_')
				c = '_';
		return n;
	}
	static ss_ file_kind(const ss_ &type)
	{
		return type == "image/png" ? "PNG image" : type == "image/jpeg" ?
				"JPEG image" : "file";
	}
	static ss_ size_text(int64_t b)
	{
		return b < 1024 ? itos(b)+" bytes" : b < 1024 * 1024 ?
				itos((b + 512) / 1024)+" KiB" :
				itos((b + 512 * 1024) / (1024 * 1024))+" MiB";
	}

	// [HEARTH_NEW_IMAGES] What a reader sees for an image not shown yet
	static constexpr const char *NOT_SHOWN = "a new account's image, not "
			"shown until a helper says";

	// [HEARTH_NEW_IMAGES] The message's HTML with its images not shown to
	// this viewer (`files`, files_of's) as a line saying so; the link
	// round one stays, opening it being the reader's own choice
	static ss_ unshown_images(ss_ h, const json::Value &files)
	{
		// Every <img> of /f/, its id read as file_ids() reads it, so that
		// "/f/0<id>", "/f/<id>?" and "/f/<id>#" are the same file
		std::set<int64_t> unshown;
		for(unsigned i = 0; i < files.size(); i++)
			if(!files.at(i).get("shown").is_true())
				unshown.insert(jint(files.at(i), "id"));
		static const ss_ start = "<img src=\"/f/";
		for(size_t at = 0; (at = h.find(start, at)) != ss_::npos;){
			const std::vector<int64_t> ids = file_ids(h.substr(at + 9, 24));
			const size_t e = h.find('>', at);
			if(ids.empty() || !unshown.count(ids[0]) || e == ss_::npos){
				at += start.size();
				continue;
			}
			const ss_ note = "<span class=\"meta\">("+ss_(NOT_SHOWN)+")</span>";
			h.replace(at, e - at + 1, note);
			at += note.size();
		}
		return h;
	}

	// [HEARTH_ATTACHMENTS] A message's files at its end: each a link with
	// its kind and size, and an image the text does not draw its
	// thumbnail beside it
	ss_ files_html(const json::Value &m)
	{
		const json::Value fs = m.get("files").is_array() ? m.get("files") :
				files_of(jstr(m, "body"));
		if(fs.size() == 0)
			return "";
		ss_ out = "<ul class=\"files\">";
		for(unsigned i = 0; i < fs.size(); i++){
			const json::Value &f = fs.at(i);
			const ss_ href = "/f/"+itos(jint(f, "id"))+"/"+
					url_name(jstr(f, "name"));
			out += "<li>";
			const bool shown = f.get("shown").is_true();
			if(f.get("image").is_true() && !f.get("drawn").is_true() && shown)
				out += "<a href=\""+href+"\"><img src=\"/f/"+
						itos(jint(f, "id"))+"/thumb\" alt=\"\" "
						"loading=\"lazy\"></a> ";
			out += "<a href=\""+href+"\">"+html(jstr(f, "name"))+
					"</a> <span class=\"meta\">"+html(file_kind(jstr(f, "type")))+
					", "+size_text(jint(f, "bytes"))+(shown ? "" :
					"; "+ss_(NOT_SHOWN))+"</span></li>";
		}
		return out+"</ul>";
	}

	// The id after a prefix, or -1
	static int64_t path_id(const ss_ &path, const ss_ &prefix)
	{
		if(path.compare(0, prefix.size(), prefix) != 0)
			return -1;
		const ss_ rest = path.substr(prefix.size());
		if(rest.empty() || rest.size() > 15 ||
				rest.find_first_not_of("0123456789") != ss_::npos)
			return -1;
		return atoll(rest.c_str());
	}

	void on_http(const network::HttpRequest &r)
	{
		// Every claimed path is answered, a 404 where nothing is
		bool ours = r.path == "/";
		for(const char *p : CLAIMED)
			ours = ours || r.path.compare(0, strlen(p), p) == 0;
		if(!ours)
			return;
		// [HTML_BRAND]'s font and logo, before the pages' rate: each page
		// fetches them
		if(network::serve_brand(m_server, r))
			return;
		if(!m_db)
			return respond(r, 503, page("Hearth", "<p>Starting.</p>"));
		// By the /64 for v6 ([DUAL_STACK])
		const ss_ from = network::address_key(r.address);
		if((r.path == "/search" && !allowed(from, SEARCHES_A_MINUTE)) ||
				!allowed("page "+from, PAGES_A_MINUTE))
			return respond(r, 429, page("Hearth", "<p>Too many requests "
					"from this address; try again in a minute.</p>"));
		if(r.path == "/api/v1/discussed"){
			if(r.method != "GET")
				return respond(r, 405, "{}", "application/json");
			const ss_ body = discussed(r.host).stringify();
			network::access(m_server, [&](network::Interface *iface){
				iface->http_respond(r.peer, 200, "application/json", body,
						"Access-Control-Allow-Origin: *\r\n"
						"Cache-Control: max-age=600\r\n");
			});
			return;
		}
		if(r.path == "/api/v1/feed"){
			if(r.method != "GET")
				return respond(r, 405, "{}", "application/json");
			const ss_ body = feed(r.host).stringify();
			network::access(m_server, [&](network::Interface *iface){
				iface->http_respond(r.peer, 200, "application/json", body,
						"Access-Control-Allow-Origin: *\r\n"
						"Cache-Control: max-age=60\r\n");
			});
			return;
		}
		// **The launcher's mark** ([FORUM] 4): a POST of {name, token}, the
		// client's kept login for this Hearth, answers {unseen} without a
		// join
		if(r.path == "/unseen"){
			if(r.method != "POST")
				return respond(r, 405, "{}", "application/json");
			const json::Value q = json::load_string(r.body.c_str());
			const ss_ who = jstr(q, "name");
			bool ok = false;
			accounts::access(m_server, [&](accounts::Interface *a){
				ok = !who.empty() && a->check_kept(who, jstr(q, "token"));
			});
			if(!ok)
				return respond(r, 403, "{}", "application/json");
			return respond(r, 200, "{\"unseen\":"+itos(unseen(who))+"}",
					"application/json");
		}
		// [FORUM] step 5: a file's use is a person's fetch, so crawlers are
		// asked to keep off them
		// simplified: by robots.txt alone; one that ignores it counts
		if(r.path == "/robots.txt")
			return respond(r, 200, "User-agent: *\nDisallow: /f/\n",
					"text/plain");
		if(r.path.compare(0, 3, "/f/") == 0 && r.method == "GET"){
			// /f/<id>, and anything after another / is the name it is saved as
			const int64_t id = path_id(r.path.substr(0, r.path.find('/', 3)),
					"/f/");
			// [HEARTH_ATTACHMENTS]: /f/<id>/thumb is an image's thumbnail;
			// a file that is not an image, named "thumb", is itself
			const bool thumb = r.path.size() > 6 &&
					r.path.compare(r.path.size() - 6, 6, "/thumb") == 0 &&
					r.path.find('/', 3) == r.path.size() - 6;
			ss_ type, data;
			if(id >= 0 && file_served(id) && file_data(id, thumb, type, data))
				// An upload is its stored type and nothing a browser
				// guesses ([SEC_RUN4_LEFTOVERS])
				return respond(r, 200, data, type,
						"X-Content-Type-Options: nosniff\r\n");
		}
		ss_ title, body;
		if(r.method == "GET")
			http_page(r.path, r.query, title, body);
		if(body.empty())
			return respond(r, 404, page("Not found", "<p>Nothing is here.</p>"));
		respond(r, 200, page(title, body, r.path));
	}

	void http_page(const ss_ &path, const ss_ &query, ss_ &title, ss_ &body)
	{
		int64_t id;
		if(path == "/"){
			title = "Hearth";
			body = "<h1>Hearth</h1>\n<h2>Topics</h2>\n<ul class=\"list\">\n";
			const json::Value ts = topics();
			for(unsigned i = 0; i < ts.size(); i++){
				const json::Value &t = ts.at(i);
				if(jint(t, "parent") != 0)
					continue;
				body += "<li><a href=\"/topic/"+itos(jint(t, "id"))+"\">"+
						html(jstr(t, "name"))+"</a>"+blob(jint(t, "active"))+
						" <span class=\"meta\">"+html(jstr(t, "about"))+" ("+itos(jint(t, "threads"))+
						" threads)</span>";
				ss_ sub;
				for(unsigned j = 0; j < ts.size(); j++)
					if(jint(ts.at(j), "parent") == jint(t, "id"))
						sub += "<li><a href=\"/topic/"+
								itos(jint(ts.at(j), "id"))+"\">"+
								html(jstr(ts.at(j), "name"))+"</a>"+
								blob(jint(ts.at(j), "active"))+"</li>";
				if(!sub.empty())
					body += "<ul>"+sub+"</ul>";
				body += "</li>\n";
			}
			body += "</ul>\n<h2>Latest</h2>\n<ul class=\"list\">\n";
			const json::Value latest = latest_threads(20);
			for(unsigned i = 0; i < latest.size(); i++)
				body += thread_line(latest.at(i));
			body += "</ul>\n";
		} else if((id = path_id(path, "/topic/")) >= 0){
			const json::Value t = topic(id);
			if(!t.is_object())
				return;
			title = jstr(t, "name")+" - Hearth";
			body = "<h1>"+html(jstr(t, "name"))+"</h1>\n<p>"+
					html(jstr(t, "about"))+"</p>\n<ul class=\"list\">\n";
			const json::Value list = threads(id);
			for(unsigned i = 0; i < list.size(); i++)
				body += thread_line(list.at(i));
			body += "</ul>\n";
		} else if(path.compare(0, 3, "/p/") == 0){
			// A package's place ([PACKAGE_SUBJECT]): the threads about
			// "author/name", as the client's "Discuss" shows them
			// simplified: every key's together; a second key under the same
			// name is noted, not split
			const ss_ pkg = path.substr(3);
			if(!is_package(pkg))
				return;
			Q q(m_db, "SELECT " THREAD_COLUMNS " FROM threads WHERE "
					"substr(subject, 1, ?) = ? AND hidden = 0 "
					"ORDER BY last DESC LIMIT 200");
			q.b((int64_t)pkg.size() + 1).b(pkg+" ");
			ss_ lines;
			std::set<ss_> keys;
			while(q.step()){
				const json::Value t = thread_row(q);
				// A release's key only: a poster names a thread's subject
				if(jstr(t, "kind") == "release")
					keys.insert(jstr(t, "subject"));
				lines += thread_line(t);
			}
			title = pkg+" - Hearth";
			body = "<h1>"+html(pkg)+"</h1>\n";
			if(keys.size() > 1)
				body += "<p class=\"meta\">Published under "+
						itos((int64_t)keys.size())+" keys: the same name, "
						"maybe not the same author.</p>\n";
			body += lines.empty() ? ss_("<p>Nothing about it here yet.</p>\n") :
					"<ul class=\"list\">\n"+lines+"</ul>\n";
		} else if((id = path_id(path, "/t/")) >= 0){
			const ss_ after = network::query_value(query, "after");
			if(after.size() > 15 || after.find_first_not_of("0123456789") !=
					ss_::npos)
				return;
			const json::Value t = thread(id, atoll(after.c_str()));
			if(!t.is_object() || (!after.empty() && t.get("hidden").is_true()))
				return;
			const json::Value top = topic(jint(t, "topic"));
			if(t.get("hidden").is_true()){
				// Its title too, which is what a spammer's thread is
				title = "A hidden thread - Hearth";
				body = "<h1>A hidden thread</h1>\n"+
						message_box(t.get("list").at(0));
				return;
			}
			title = jstr(t, "title")+" - Hearth";
			body = "<p class=\"meta\"><a href=\"/topic/"+
					itos(jint(t, "topic"))+"\">"+html(jstr(top, "name"))+
					"</a></p>\n<h1>"+html(jstr(t, "title"))+"</h1>\n";
			if(!kind_text(t).empty())
				body += "<p class=\"meta\">"+html(kind_text(t))+
						(jstr(t, "version").empty() ? ss_() :
						", reported in "+html(jstr(t, "version")))+"</p>\n";
			if(!jstr(t, "link").empty())
				body += "<p class=\"meta\">Tracker: <a rel=\"nofollow ugc\" "
						"href=\""+html(jstr(t, "link"))+"\">"+html(jstr(t, "link"))+
						"</a></p>\n";
			if(!jstr(t, "subject").empty())
				body += "<p class=\"meta\">"+about_html(jstr(t, "subject"))+
						"</p>\n";
			// The question, its answer, then the rest in order; a later page
			// marks the answer where it is
			// simplified: an answer past the first page is not lifted under
			// the question
			const json::Value &list = t.get("list");
			const int64_t answer = jint(t, "answer");
			const bool first = after.empty();
			for(unsigned i = 0; i < list.size(); i++){
				const bool is_answer = jint(list.at(i), "id") == answer;
				if(first && is_answer)
					continue;
				body += message_box(list.at(i), is_answer);
				for(unsigned j = 0; first && i == 0 && j < list.size(); j++)
					if(jint(list.at(j), "id") == answer)
						body += message_box(list.at(j), true);
			}
			if(t.get("more").is_true())
				body += "<p><a href=\"/t/"+itos(id)+"?after="+
						itos(jint(list.at(list.size() - 1), "id"))+
						"\">Later messages</a></p>\n";
		} else if((id = path_id(path, "/m/")) >= 0){
			Q q(m_db, "SELECT m.id, m.author, m.body, m.created, m.edited, "
					"m.thread, t.title, m.hidden, m.hidden_reason, t.hidden "
					"FROM messages m "
					"JOIN threads t ON t.id = m.thread WHERE m.id = ?");
			q.b(id);
			// A hidden thread is seen on its own page only
			if(!q.step() || q.i(9))
				return;
			json::Value m = json::object();
			m.set("id", q.i(0));
			m.set("author", q.s(1));
			m.set("body", q.i(7) ? ss_() : q.s(2));
			m.set("created", q.i(3));
			m.set("edited", q.i(4));
			m.set("hidden", q.i(7) != 0);
			m.set("hidden_reason", q.s(8));
			m.set("hidden_text", hidden_text(q.i(7), q.s(8)));
			const ss_ thread_title = q.s(6);
			title = thread_title+" - Hearth";
			body = "<p class=\"meta\">In <a href=\""+
					message_path(q.i(5), id)+"\">"+html(thread_title)+
					"</a></p>\n"+
					message_box(m);
		} else if(path.compare(0, 3, "/u/") == 0){
			// **An account's page**, where an @name goes: its last
			// messages that stand, newest first
			// simplified: the last 50 and no more pages; no profile
			const ss_ who = path.substr(3);
			if(who.empty() || who.size() > NAME_MAX ||
					who.find_first_not_of("abcdefghijklmnopqrstuvwxyz"
					"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-") != ss_::npos)
				return;
			title = who+" - Hearth";
			body = "<h1>"+html(who)+"</h1>\n<ul class=\"list\">\n";
			Q q(m_db, "SELECT m.id, m.thread, t.title, m.created, "
					"substr(m.body, 1, 200) FROM messages m "
					"JOIN threads t ON t.id = m.thread WHERE m.author = ? "
					"AND m.hidden = 0 AND t.hidden = 0 "
					"ORDER BY m.id DESC LIMIT 50");
			q.b(who);
			int n = 0;
			while(q.step()){
				body += "<li><a href=\"/t/"+itos(q.i(1))+"#m"+itos(q.i(0))+
						"\">"+html(q.s(2))+"</a> <span class=\"meta\">"+
						html(time_text(q.i(3)))+"</span><br>"+html(q.s(4))+
						"</li>\n";
				n++;
			}
			if(n == 0)
				body += "<li>Nothing written here.</li>\n";
			body += "</ul>\n";
		} else if(path == "/search"){
			const ss_ text = network::query_value(query, "q").substr(0, 200);
			title = text+" - Hearth search";
			body = "<h1>Search: "+html(text)+"</h1>\n<ul class=\"list\">\n";
			const json::Value list = search(text);
			for(unsigned i = 0; i < list.size(); i++){
				const json::Value &v = list.at(i);
				// The marks are bytes no message holds (control bytes are
				// refused), put in after the escaping
				ss_ snip = html(jstr(v, "snippet"));
				for(size_t at; (at = snip.find('\x01')) != ss_::npos;)
					snip.replace(at, 1, "<mark>");
				for(size_t at; (at = snip.find('\x02')) != ss_::npos;)
					snip.replace(at, 1, "</mark>");
				body += "<li><a href=\"/t/"+itos(jint(v, "thread"))+"#m"+
						itos(jint(v, "message"))+"\">"+html(jstr(v, "title"))+
						"</a> <span class=\"meta\">"+html(jstr(v, "author"))+
						"</span><br>"+snip+"</li>\n";
			}
			if(list.size() == 0)
				body += "<li>Nothing found.</li>\n";
			body += "</ul>\n";
		}
	}

	// -----------------------------------------------------------------------
	// The client

	void on_req(const network::Packet &packet)
	{
		ss_ name;
		accounts::access(m_server, [&](accounts::Interface *a){
			name = a->name_of(packet.sender);
		});
		network::answer_request(m_server, packet, "hr:res", name,
				m_db ? "" : "Hearth is not ready", [&](const json::Value &q){
			m_joined.insert(packet.sender);
			try {
				exec("BEGIN");
				const json::Value result = handle(name, level(name), jstr(q, "cmd"),
						q, packet.sender);
				exec("COMMIT");
				return result;
			} catch(std::exception &){
				sqlite3_exec(m_db, "ROLLBACK", nullptr, nullptr, nullptr);
				m_new_messages.clear();
				m_notified.clear();
				throw;
			}
		});
		push();
	}

	// An account's level in accounts; below LV_HELPER a member while
	// trusted -- by ACTIVE_DAYS, which trusts it in accounts from then on,
	// or by an approval -- and no message of it hidden in the last 30 days
	int level(const ss_ &name)
	{
		int lv = accounts::level(m_server, name);
		if(lv >= LV_HELPER || name.empty())
			return lv;
		const json::Value t = trust(name);
		if(lv < LV_MEMBER && jint(t, "days") >= ACTIVE_DAYS){
			accounts::access(m_server, [&](accounts::Interface *a){
				if(a->set_level(name, LV_MEMBER).empty())
					lv = LV_MEMBER;
			});
			log_i(MODULE, "%s is trusted, active on %i days", cs(name),
					ACTIVE_DAYS);
		}
		return lv >= LV_MEMBER && jint(t, "hidden") == 0 ? lv : LV_NEW;
	}

	// [ADMIN_NOTIFY] The moderators' phones told of a new entry in the
	// queue: what kind and how many are open, nothing of it
	void push_queue(const ss_ &what)
	{
		Q o(m_db, "SELECT count(*) FROM reports WHERE state = 'open'");
		const int64_t open = o.step() ? o.i(0) : 0;
		const ss_ base = jstr(setting("public_url"), "url");
		accounts::access(m_server, [&](accounts::Interface *a){
			a->notify(LV_MODERATOR, "Hearth: "+what+", "+itos(open)+" open",
					base);
		});
	}

	// [TRUST_LADDER] A message held: hidden from all but its author, and
	// in the queue for a helper's approval
	void hold(int64_t message_id, const ss_ &author)
	{
		set_hidden(message_id, HELD, "");
		Q i(m_db, "INSERT INTO reports(kind, message, by, reason, time) "
				"VALUES('held', ?, ?, '', ?)");
		i.b(message_id).b(author).b(now_s()).step();
		push_queue("a message held");
	}

	// [TRUST_LADDER] `name` trusted, or no longer, by `by`; an approval is
	// one a day of a helper's APPROVALS_A_DAY
	void trust_account(const ss_ &name, const ss_ &by, int by_lv, bool on,
			int64_t message_id = 0)
	{
		ss_ why;
		if(on){
			Q c(m_db, "SELECT count(*) FROM approvals WHERE by = ? AND "
					"time > ?");
			c.b(by).b(now_s() - 86400).step();
			if(by_lv < LV_MODERATOR && c.i(0) >= APPROVALS_A_DAY)
				throw Exception(itos(APPROVALS_A_DAY)+" approvals a day at "
						"most");
		} else if(by_lv < LV_MODERATOR){
			Q a(m_db, "SELECT 1 FROM approvals WHERE account = ? AND by = ? "
					"AND time > ?");
			a.b(name).b(by).b(now_s() - UNDO_S);
			if(!a.step())
				throw Exception("a "+level_name(LV_HELPER)+" takes back only "
						"its own approval, within 7 days");
		}
		accounts::access(m_server, [&](accounts::Interface *a){
			const int was = a->level(name);
			// Trust is the lowest step: a role above it is taken first
			why = was >= LV_HELPER ? name+" is a "+level_name(was) :
					a->set_level(name, on ? std::max(was, (int)LV_MEMBER) :
					LV_NEW);
		});
		need(why);
		if(on){
			Q i(m_db, "INSERT INTO approvals(account, by, time, message) "
					"VALUES(?, ?, ?, ?)");
			i.b(name).b(by).b(now_s()).b(message_id).step();
		} else {
			Q d(m_db, "DELETE FROM approvals WHERE account = ?");
			d.b(name).step();
		}
		log_i(MODULE, "%s %s %s", cs(by), on ? "trusted" : "no longer trusts",
				cs(name));
	}

	// [TRUST_LADDER] A held message rejected: gone, with its thread if it
	// started one
	void delete_message(int64_t message_id)
	{
		Q m(m_db, "SELECT thread, (SELECT min(id) FROM messages WHERE "
				"thread = m.thread) FROM messages m WHERE id = ?");
		m.b(message_id);
		if(!m.step())
			return;
		const int64_t thread_id = m.i(0);
		const bool first = m.i(1) == message_id;
		for(const char *sql : {"DELETE FROM messages WHERE id = ?",
				"DELETE FROM search WHERE rowid = ?",
				"DELETE FROM edits WHERE message = ?",
				"DELETE FROM notifications WHERE message = ?",
				"DELETE FROM file_links WHERE message = ?"}){
			Q d(m_db, sql);
			d.b(message_id).step();
		}
		if(first)
			for(const char *sql : {"DELETE FROM threads WHERE id = ?",
					"DELETE FROM follows WHERE thread = ?",
					"DELETE FROM notifications WHERE thread = ?",
					"DELETE FROM reads WHERE thread = ?"}){
				Q d(m_db, sql);
				d.b(thread_id).step();
			}
	}

	// What level() is reached by, as counts: the days active, each
	// counted once it is over -- a thread read on it, or a message
	// written on it that stands; more of either on one day is no more
	// trust, so it comes at a day's pace however busy a script is -- and
	// messages hidden or deleted in the last 30 days
	json::Value trust(const ss_ &name)
	{
		const int64_t now = now_s();
		Q hd(m_db, "SELECT count(*) FROM messages WHERE author = ? AND "
				"hidden IN (1, 4) AND created > ?");
		hd.b(name).b(now - 30 * 86400).step();
		Q d(m_db, "SELECT count(*) FROM (SELECT day FROM active_days "
				"WHERE account = ?1 AND day < ?2 UNION SELECT created / 86400 "
				"FROM messages WHERE author = ?1 AND hidden = 0 AND "
				"created / 86400 < ?2)");
		d.b(name).b(now / 86400).step();
		json::Value v = json::object();
		v.set("days", d.i(0));
		v.set("hidden", hd.i(0));
		return v;
	}

	// [HEARTH_UI]: each thread in `list` marked "unread" for `name`
	// (UNREAD), in one query
	void mark_unread(json::Value &list, const ss_ &name)
	{
		ss_ ids;
		for(unsigned i = 0; i < list.size(); i++)
			ids += (i ? "," : "") + itos(jint(list.at(i), "id"));
		std::set<int64_t> unread;
		const ss_ sql = "SELECT id FROM threads WHERE id IN (" + ids + ") AND "
				UNREAD("threads");
		Q q(m_db, sql.c_str(), false);
		q.b(name).b(since(name));
		while(q.step())
			unread.insert(q.i(0));
		for(unsigned i = 0; i < list.size(); i++){
			json::Value t = list.at(i);
			t.set("unread", unread.count(jint(t, "id")) != 0);
			list.set_at(i, t);
		}
	}

	// A message as plain text for another site's line ([HEARTH_DISCUSSED_API]):
	// the Markdown's HTML without its tags (a link its text, code as is, a
	// spoiler "[spoiler]"), whitespace folded, cut on a word near `max`
	// simplified: the five entities the escaping writes are read back; one
	// the author typed ("&copy;") stays as typed
	static ss_ plain_text(const ss_ &md, size_t max = 200)
	{
		const ss_ h = interface::markup::to_html(md);
		ss_ t;
		int spoiler = 0;
		for(size_t i = 0; i < h.size();){
			if(h[i] == '<'){
				const size_t end = h.find('>', i);
				if(end == ss_::npos)
					break;
				const ss_ tag = h.substr(i, end + 1 - i);
				if(tag.compare(0, 20, "<span class=\"spoiler") == 0 ||
						(spoiler && tag.compare(0, 5, "<span") == 0)){
					if(spoiler++ == 0)
						t += " [spoiler] ";
				} else if(spoiler && tag == "</span>"){
					spoiler--;
				} else {
					t += ' ';
				}
				i = end + 1;
				continue;
			}
			if(!spoiler){
				static const char *ent[][2] = {{"&amp;", "&"}, {"&lt;", "<"},
						{"&gt;", ">"}, {"&quot;", "\""}, {"&#39;", "'"}};
				bool done = false;
				for(auto &e : ent)
					if(h.compare(i, strlen(e[0]), e[0]) == 0){
						t += e[1];
						i += strlen(e[0]);
						done = true;
						break;
					}
				if(done)
					continue;
				t += h[i];
			}
			i++;
		}
		ss_ out;
		for(char c : t){
			const bool space = c == ' ' || c == '\n' || c == '\t' || c == '\r';
			if(space && (out.empty() || out.back() == ' '))
				continue;
			out += space ? ' ' : c;
		}
		while(!out.empty() && out.back() == ' ')
			out.pop_back();
		if(out.size() <= max)
			return out;
		size_t cut = out.rfind(' ', max);
		if(cut == ss_::npos || cut < max / 2){
			cut = max;
			// Not inside a UTF-8 sequence
			while(cut > 0 && ((unsigned char)out[cut] & 0xC0) == 0x80)
				cut--;
		}
		return out.substr(0, cut)+"\u2026";
	}

	// [HEARTH_DISCUSSED_API] GET /api/v1/discussed, for www.buildat.org's
	// "Discussed today" line: of the shortest of a day, a week and a month
	// that has two or more, one message at random -- visible, in a visible
	// thread, not empty as text, by a member (LV_MEMBER, the trust ladder)
	// that is not banned. {} when a month has fewer. The pick is kept ten
	// minutes, so the site's visitors cost one query in that time and a
	// reload shows the same one.
	// simplified: uniform; weighting by replies is the upgrade. The last
	// 2000 messages are what is looked at.
	// The links' base is the admin's "public_url" setting, else the
	// request's Host over https (http for a loopback Host).
	json::Value discussed(const ss_ &host)
	{
		const int64_t now = now_s();
		if(m_discussed_at < 0 || now - m_discussed_at >= 600 ||
				now < m_discussed_at){
			m_discussed_at = now;
			m_discussed = json::object();
			std::set<ss_> banned;
			accounts::access(m_server, [&](accounts::Interface *a){
				for(const ss_ &b : a->ban_list())
					banned.insert(b.substr(0, b.find('|')));
			});
			std::map<ss_, bool> member;
			struct Pick { int64_t age; json::Value v; };
			sv_<Pick> picks;
			Q q(m_db, "SELECT m.id, m.author, m.body, m.created, t.id, "
					"t.title, p.id, p.name FROM messages m "
					"JOIN threads t ON t.id = m.thread "
					"JOIN topics p ON p.id = t.topic "
					"WHERE m.hidden = 0 AND t.hidden = 0 AND m.created > ? "
					"ORDER BY m.id DESC LIMIT 2000");
			q.b(now - 30 * 86400);
			while(q.step()){
				const ss_ who = q.s(1);
				if(!member.count(who))
					member[who] = !banned.count(who) &&
							level(who) >= LV_MEMBER;
				const ss_ excerpt = plain_text(q.s(2));
				if(!member[who] || excerpt.empty())
					continue;
				json::Value v = json::object();
				v.set("id", q.i(0));
				v.set("author", who);
				v.set("created", q.i(3));
				v.set("excerpt", excerpt);
				json::Value t = json::object();
				t.set("id", q.i(4));
				t.set("title", q.s(5));
				v.set("thread", t);
				json::Value p = json::object();
				p.set("id", q.i(6));
				p.set("name", q.s(7));
				v.set("topic", p);
				picks.push_back({now - q.i(3), v});
			}
			static std::mt19937_64 rng(std::random_device{}());
			const std::pair<int64_t, const char*> spans[] = {
					{86400, "today"}, {7 * 86400, "this week"},
					{30 * 86400, "this month"}};
			for(const auto &span : spans){
				sv_<const json::Value*> in;
				for(const Pick &p : picks)
					if(p.age <= span.first)
						in.push_back(&p.v);
				if(in.size() < 2)
					continue;
				m_discussed.set("span", span.second);
				m_discussed.set("message", *in[rng() % in.size()]);
				m_discussed_path = message_path(
						jint(m_discussed.get("message").get("thread"), "id"),
						jint(m_discussed.get("message"), "id"));
				break;
			}
		}
		if(!m_discussed.get("message").is_object())
			return json::object();
		const ss_ base = base_url(host);
		json::Value out = m_discussed;
		json::Value m = out.get("message");
		json::Value t = m.get("thread"), p = m.get("topic");
		// Read in its thread, where its replies are; /m/ is its
		// permanent address
		m.set("url", base+m_discussed_path);
		t.set("url", base+"/t/"+itos(jint(t, "id")));
		p.set("url", base+"/topic/"+itos(jint(p, "id")));
		m.set("thread", t);
		m.set("topic", p);
		out.set("message", m);
		return out;
	}

	// [LIVELY_MENU] GET /api/v1/feed, for a launcher's "now" strip and an
	// app's page: {url, announcements, active, packages}. A thread is {id,
	// title, posts, last}, read at url + "/t/" + id. announcements: up to 3
	// of the threads in the topics of category "announcements" written in
	// within 30 days, the latest first; active: up to 5 others with the most
	// messages in the last 7 days; packages: "author/name" -> {posts, last,
	// threads (its 3 latest)}, the 300 packages written about last. Visible
	// threads only, started by a member that is not banned (or a release's,
	// by its Aitta); posts counts the visible messages. Kept a minute.
	json::Value feed(const ss_ &host)
	{
		const int64_t now = now_s();
		if(m_feed_at < 0 || now - m_feed_at >= 60 || now < m_feed_at){
			m_feed_at = now;
			std::set<ss_> banned;
			accounts::access(m_server, [&](accounts::Interface *a){
				for(const ss_ &b : a->ban_list())
					banned.insert(b.substr(0, b.find('|')));
			});
			std::map<ss_, bool> member;
			auto shown = [&](const ss_ &who, const ss_ &kind){
				if(!member.count(who))
					member[who] = !banned.count(who) && level(who) >= LV_MEMBER;
				return member[who] || kind == "release";
			};
			auto row = [](Q &q){
				json::Value t = json::object();
				t.set("id", q.i(0));
				t.set("title", q.s(1));
				t.set("posts", q.i(2));
				t.set("last", q.i(3));
				return t;
			};
#define FEED_COLUMNS "t.id, t.title, (SELECT count(*) FROM messages m " \
		"WHERE m.thread = t.id AND m.hidden = 0), t.last, t.author, t.kind"
			json::Value ann = json::array(), active = json::array();
			Q a(m_db, "SELECT " FEED_COLUMNS " FROM threads t WHERE "
					"t.hidden = 0 AND t.last > ? AND t.topic IN (SELECT id "
					"FROM topics WHERE category = 'announcements' OR parent "
					"IN (SELECT id FROM topics WHERE category = "
					"'announcements')) ORDER BY t.last DESC LIMIT 20");
			a.b(now - 30 * 86400);
			std::set<int64_t> seen;
			while(a.step() && ann.size() < 3)
				if(shown(a.s(4), a.s(5))){
					ann.append(row(a));
					seen.insert(a.i(0));
				}
			Q b(m_db, "SELECT " FEED_COLUMNS " FROM threads t WHERE "
					"t.hidden = 0 AND t.last > ?1 ORDER BY (SELECT count(*) "
					"FROM messages m WHERE m.thread = t.id AND m.hidden = 0 "
					"AND m.created > ?1) DESC, t.last DESC LIMIT 50");
			b.b(now - 7 * 86400);
			while(b.step() && active.size() < 5)
				if(!seen.count(b.i(0)) && shown(b.s(4), b.s(5)))
					active.append(row(b));
			// Every key's together, as /p/ shows them
			json::Value pkgs = json::object();
			int n = 0;
			Q c(m_db, "SELECT " FEED_COLUMNS ", t.subject FROM threads t "
					"WHERE t.hidden = 0 AND instr(t.subject, ' ') > 1 "
					"ORDER BY t.last DESC LIMIT 5000");
			while(c.step()){
				const ss_ s = c.s(6), pkg = s.substr(0, s.find(' '));
				if(!is_package(pkg) || !shown(c.s(4), c.s(5)))
					continue;
				json::Value p = pkgs.get(pkg);
				if(!p.is_object()){
					if(n++ >= 300)
						continue;
					p = json::object();
					p.set("posts", 0);
					p.set("last", c.i(3));
					p.set("threads", json::array());
				}
				p.set("posts", jint(p, "posts") + c.i(2));
				json::Value l = p.get("threads");
				if(l.size() < 3)
					l.append(row(c));
				p.set("threads", l);
				pkgs.set(pkg, p);
			}
#undef FEED_COLUMNS
			m_feed = json::object();
			m_feed.set("announcements", ann);
			m_feed.set("active", active);
			m_feed.set("packages", pkgs);
		}
		json::Value out = m_feed;
		out.set("url", base_url(host));
		return out;
	}

	// The links' base: the admin's "public_url", else the request's Host
	// over https (http for a loopback Host)
	ss_ base_url(const ss_ &host)
	{
		ss_ base = jstr(setting("public_url"), "url");
		if(base.empty()){
			const bool local = host.compare(0, 9, "127.0.0.1") == 0 ||
					host.compare(0, 9, "localhost") == 0 ||
					host.compare(0, 5, "[::1]") == 0;
			base = (local ? "http://" : "https://")+host;
		}
		return base;
	}

	// `who`: an address, "@" and an account, or "page " and an address
	bool allowed(const ss_ &who, int a_minute)
	{
		return m_searches.ok("", who, a_minute, 60);
	}

	// An address in the text, or a link the markup makes ("//host",
	// "mailto:", a reference definition) without one
	static bool has_link(const ss_ &text)
	{
		ss_ t = text;
		for(char &c : t)
			c = tolower((unsigned char)c);
		return t.find("://") != ss_::npos || t.find("www.") != ss_::npos ||
				interface::markup::to_html(text).find("<a href") != ss_::npos;
	}

	// Whether `name` may post this now, by its level; why not. True when
	// it is to be held: a new account's link elsewhere than the tracker
	// domains ([HEARTH_TRACKER]) waits for a helper's approval
	// ([TRUST_LADDER])
	bool check_limits(const ss_ &name, int lv, bool new_thread,
			const ss_ &text)
	{
		const Limits l = limits(lv);
		const ss_ how = lv < LV_MEMBER ? " (a "+level_name(LV_NEW)+"'s "
				"limit, until it has been active on five days or a "+
				level_name(LV_HELPER)+" approves it)" : "";
		bool held = false;
		if(!l.links && has_link(text)){
			const std::set<ss_> domains = tracker_domains();
			for(const ss_ &h : link_hosts(text))
				held = held || !domains.count(h);
			Q w(m_db, "SELECT 1 FROM reports WHERE kind = 'held' AND by = ? "
					"AND state = 'open'");
			w.b(name);
			if(held && w.step())
				throw Exception(ss_("a link of yours is waiting for "
						"approval already")+how);
		}
		// An edit counts as a message: each keeps the old body
		Q m(m_db, "SELECT (SELECT count(*) FROM messages WHERE author = ? "
				"AND created > ?) + (SELECT count(*) FROM edits WHERE "
				"editor = ? AND time > ?)");
		m.b(name).b(now_s() - 3600).b(name).b(now_s() - 3600).step();
		if(m.i(0) >= l.messages_an_hour)
			throw Exception(itos(l.messages_an_hour)+" messages an hour at "
					"most"+how);
		if(new_thread){
			Q t(m_db, "SELECT count(*) FROM threads WHERE author = ? AND "
					"created > ?");
			t.b(name).b(now_s() - 86400).step();
			if(t.i(0) >= l.threads_a_day)
				throw Exception(itos(l.threads_a_day)+" new threads a day at "
						"most"+how);
		}
		return held;
	}

	// [HEARTH_NEW_IMAGES] A new account's images: those of its own uploads
	// `text` names and those its other messages in the thread named, one
	// at most. `thread_id` 0 for a new thread; `except` the message being
	// edited, whose old text does not count
	void check_images(const ss_ &name, int lv, int64_t thread_id,
			int64_t except, const ss_ &text)
	{
		if(lv >= LV_MEMBER)
			return;
		std::set<int64_t> mine;
		for(int64_t id : file_ids(text)){
			Q f(m_db, "SELECT 1 FROM files WHERE id = ? AND uploader = ? AND "
					"lod > 0");
			f.b(id).b(name);
			if(f.step())
				mine.insert(id);
		}
		if(mine.empty())
			return;
		Q o(m_db, "SELECT DISTINCT k.file FROM file_links k JOIN messages m "
				"ON m.id = k.message JOIN files f ON f.id = k.file WHERE "
				"m.thread = ? AND m.author = ? AND m.id != ? AND "
				"f.uploader = ? AND f.lod > 0");
		o.b(thread_id).b(name).b(except).b(name);
		while(o.step())
			mine.insert(o.i(0));
		if(mine.size() > 1)
			throw Exception("one image a thread (a "+level_name(LV_NEW)+
					"'s limit, until it has been active on five days or a "+
					level_name(LV_HELPER)+" approves it)");
	}

	// Hidden or shown again: the message, its thread if it is the first,
	// and the search index
	void set_hidden(int64_t message_id, int hidden, const ss_ &reason)
	{
		// /api/v1/discussed's pick may be this message ([SECURITY_RUN_4]),
		// and the feed's threads
		m_discussed_at = -1;
		m_feed_at = -1;
		Q m(m_db, "SELECT m.thread, m.body, t.title, (SELECT min(id) FROM "
				"messages WHERE thread = m.thread) FROM messages m JOIN threads t "
				"ON t.id = m.thread WHERE m.id = ?");
		m.b(message_id);
		if(!m.step())
			throw Exception("no such message");
		const bool first = m.i(3) == message_id;
		Q u(m_db, "UPDATE messages SET hidden = ?, hidden_reason = ? "
				"WHERE id = ?");
		u.b((int64_t)hidden).b(hidden == HIDDEN || hidden == DELETED ? reason :
				ss_()).b(message_id)
				.step();
		if(first){
			Q t(m_db, "UPDATE threads SET hidden = ? WHERE id = ?");
			t.b((int64_t)hidden).b(m.i(0)).step();
		}
		Q d(m_db, "DELETE FROM search WHERE rowid = ?");
		d.b(message_id).step();
		if(!hidden){
			Q i(m_db, "INSERT INTO search(rowid, title, body) VALUES(?, ?, ?)");
			i.b(message_id).b(first ? m.s(2) : ss_()).b(m.s(1)).step();
		}
	}

	// [HEARTH_MOD_TOOLS] A moderator's Delete: hidden as DELETED with the
	// statement, its open reports upheld, the author told, and the decision
	// in the reports as a queue's is
	void delete_as_moderator(int64_t message_id, int64_t thread_id,
			const ss_ &author, const ss_ &by, const ss_ &reason,
			const ss_ &text)
	{
		if(accounts::level(m_server, author) >= LV_ADMIN)
			throw Exception("the "+level_name(LV_ADMIN)+"'s message is not "
					"deleted");
		const ss_ statement = reason+(text.empty() ? ss_() : ": "+text);
		set_hidden(message_id, DELETED, statement);
		Q u(m_db, "UPDATE reports SET state = 'upheld', handled_by = ?, "
				"handled_time = ?, statement = ?, bin = '' WHERE state = 'open' "
				"AND kind IN ('report', 'held') AND message = ?");
		u.b(by).b(now_s()).b(statement).b(message_id).step();
		Q i(m_db, "INSERT INTO reports(kind, message, by, reason, time, state, "
				"handled_by, handled_time, statement) VALUES('delete', ?, ?, ?, "
				"?, 'upheld', ?, ?, ?)");
		i.b(message_id).b(by).b(reason).b(now_s()).b(by).b(now_s())
				.b(statement).step();
		notify(author, "deleted", thread_id, message_id, by, statement);
	}

	static void need(const ss_ &why)
	{
		if(!why.empty())
			throw Exception(why);
	}

#include "commands.h"
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
// vim: set noet ts=4 sw=4:
