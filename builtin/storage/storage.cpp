// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "storage/api.h"
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/mutex.h"
#include "interface/os.h"
#include "core/json.h"
#include <sqlite3.h>
#include "core/version.h"
#include <fstream>
#include <sys/stat.h>
#include <cstdio>
#include <map>
#ifdef _WIN32
	#include <direct.h>
#else
	#include <unistd.h>
#endif
#define MODULE "storage"

using interface::Event;

namespace storage {

// One table, so that no module ever runs DDL and the backend stays swappable.
// The keys are strings: Luanti uses an integer primary key for map blocks
// because it has millions of 16^3 ones, and buildat's sections are 2x2x2
// chunks of 32^3, so thousands of "world/x,y,z" rows is not the same problem.
// simplified: the ceiling is an integer key over a hashed position, and the
// upgrade does not change this API.
static const char *SCHEMA =
		"CREATE TABLE IF NOT EXISTS store ("
		"store TEXT NOT NULL, key TEXT NOT NULL, value BLOB,"
		" PRIMARY KEY(store, key))";

// PRAGMA user_version; raised when a save's layout changes
static const int SAVE_FORMAT = 1;

struct CSave;

struct SqliteError: public Exception {
	SqliteError(const ss_ &what): Exception(what){}
};

static void check(sqlite3 *db, int rc, const char *what)
{
	if(rc == SQLITE_OK || rc == SQLITE_ROW || rc == SQLITE_DONE)
		return;
	ss_ msg = ss_()+what+": "+(db ? sqlite3_errmsg(db) : "no connection");
	throw SqliteError(msg);
}

// A prepared statement out of the connection's cache, by the SQL's own
// address (they are string literals): prepared once per connection and
// reset when let go. It used to be prepared per use on the reasoning that
// sqlite's prepare is not the expensive part of a batch, and a perf of
// VoxeLibre's world generation put 8% of the server in sqlite's parser
// under set() ([WORLDGEN_DRIFT], 2026-09-19). Held under the save's mutex
// like every use of the connection, so one statement is in use at a time.
struct StmtCache
{
	std::map<const char*, sqlite3_stmt*> by_sql;
	// Before the connection closes: a statement finalized after that is
	// an error, and one not finalized before it keeps the close from
	// closing
	void finalize_all()
	{
		for(auto &p : by_sql)
			sqlite3_finalize(p.second);
		by_sql.clear();
	}
};
struct Stmt
{
	sqlite3 *db = nullptr;
	sqlite3_stmt *stmt = nullptr;

	Stmt(sqlite3 *db, StmtCache &cache, const char *sql): db(db)
	{
		auto it = cache.by_sql.find(sql);
		if(it != cache.by_sql.end()){
			stmt = it->second;
			return;
		}
		check(db, sqlite3_prepare_v2(db, sql, -1, &stmt, nullptr), sql);
		cache.by_sql[sql] = stmt;
	}
	~Stmt()
	{
		if(stmt){
			sqlite3_reset(stmt);
			sqlite3_clear_bindings(stmt);
		}
	}
	void bind(int i, const ss_ &v)
	{
		check(db, sqlite3_bind_blob(stmt, i, v.c_str(), (int)v.size(),
				SQLITE_TRANSIENT), "bind");
	}
	void bind_text(int i, const ss_ &v)
	{
		check(db, sqlite3_bind_text(stmt, i, v.c_str(), (int)v.size(),
				SQLITE_TRANSIENT), "bind");
	}
	bool step()
	{
		int rc = sqlite3_step(stmt);
		check(db, rc, "step");
		return rc == SQLITE_ROW;
	}
	ss_ column_blob(int i)
	{
		const void *p = sqlite3_column_blob(stmt, i);
		int n = sqlite3_column_bytes(stmt, i);
		if(!p || n <= 0)
			return "";
		return ss_((const char*)p, (size_t)n);
	}
	ss_ column_text(int i)
	{
		const unsigned char *p = sqlite3_column_text(stmt, i);
		int n = sqlite3_column_bytes(stmt, i);
		if(!p || n <= 0)
			return "";
		return ss_((const char*)p, (size_t)n);
	}
};

struct CStore: public Store
{
	CSave *m_save;
	ss_ m_name;

	CStore(CSave *save, const ss_ &name): m_save(save), m_name(name){}

	bool get(const ss_ &key, ss_ &value_out);
	void set(const ss_ &key, const ss_ &value);
	void remove(const ss_ &key);
	sv_<ss_> list(const ss_ &prefix);
	void batch(std::function<void()> writes);
};

struct CSave: public Save
{
	ss_ m_path;
	sqlite3 *m_db = nullptr;
	// One connection behind a recursive mutex: the server is multithreaded and
	// voxelworld has a thread of its own, and the writes are batched anyway,
	// so this is the simplest thing that is correct. Recursive because
	// batch()'s callback calls set() on the same store.
	interface::Mutex m_mutex;
	// batch() nests: only the outermost begins and commits, so a save made of
	// batches (a section's) can be one transaction inside a larger one
	int m_batch_depth = 0;
	std::map<ss_, up_<CStore>> m_stores;
	// The prepared statements, finalized before the connection closes
	StmtCache m_stmts;

	// in_memory is for the self-check: everything above the sqlite calls is
	// the same, and nothing is left on anyone's disk.
	CSave(const ss_ &path, bool in_memory = false): m_path(path)
	{
		ss_ db_path = in_memory ? ":memory:" : path+"/save.sqlite";
		int rc = sqlite3_open_v2(db_path.c_str(), &m_db,
				SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nullptr);
		if(rc != SQLITE_OK){
			ss_ msg = m_db ? sqlite3_errmsg(m_db) : "out of memory";
			if(m_db)
				sqlite3_close(m_db);
			m_db = nullptr;
			throw SqliteError("Could not open "+db_path+": "+msg);
		}
		// **A second connection to the same save waits rather than failing.**
		// One is opened whenever anything asks for a save by name -- the
		// launcher reads a gameid out of every save to build its menu, and
		// one of those is the save the world is being written to -- and the
		// schema and pragmas a new connection runs take the write lock for a
		// moment. Without a timeout sqlite answers SQLITE_BUSY there and
		// then: voxelworld's BEGIN IMMEDIATE came back "database is locked"
		// and the server shut down mid-run, which cost this project four
		// reference-shot runs before it was traced. Five seconds is far more
		// than the milliseconds a schema check takes and far less than a
		// human notices.
		//
		// **There is no unit check for this**, and one was written and thrown
		// away: two connections in one thread cannot demonstrate it, because
		// the one holding the write lock cannot commit while the thread is
		// blocked in the other. The real case is two threads -- voxelworld
		// has its own -- and the evidence is the log it came from, where a
		// BEGIN IMMEDIATE failed 3 milliseconds after another connection to
		// the same save was opened.
		sqlite3_busy_timeout(m_db, 5000);
		// **The save's format** ([COMPAT_BREAK_07] 8h): PRAGMA user_version,
		// 1 since 0.7; a newer one is refused before anything is written,
		// and the version that last opened it is a row of "__save"
		int format = 0;
		{
			sqlite3_stmt *st = nullptr;
			check(m_db, sqlite3_prepare_v2(m_db, "PRAGMA user_version", -1,
					&st, nullptr), "user_version");
			if(sqlite3_step(st) == SQLITE_ROW)
				format = sqlite3_column_int(st, 0);
			sqlite3_finalize(st);
		}
		if(format > SAVE_FORMAT){
			sqlite3_close(m_db);
			m_db = nullptr;
			throw SqliteError("The save "+path+" was written by a newer "
					"Buildat (save format "+itos(format)+"; this one, "+
					BUILDAT_VERSION+", reads "+itos(SAVE_FORMAT)+")");
		}
		// A save that a crash interrupted is worth more than the milliseconds
		// a rollback journal would save, and WAL is what lets a reader and a
		// writer overlap at all
		exec("PRAGMA journal_mode=WAL");
		exec("PRAGMA synchronous=NORMAL");
		// The WAL otherwise keeps its largest size until the save closes,
		// and that is room max_disk_mb counts and a trim cannot give back
		exec("PRAGMA journal_size_limit=1048576");
		exec("PRAGMA foreign_keys=ON");
		exec(SCHEMA);
		if(format < SAVE_FORMAT)
			exec(("PRAGMA user_version="+itos(SAVE_FORMAT)).c_str());
		// Written only when it changes: the launcher opens every save to
		// read it, and an open alone leaves the file as it was
		sqlite3_stmt *st = nullptr;
		check(m_db, sqlite3_prepare_v2(m_db, "INSERT OR REPLACE INTO store"
				" SELECT '__save', 'version', ?1 WHERE NOT EXISTS (SELECT 1"
				" FROM store WHERE store = '__save' AND key = 'version' AND"
				" value = ?1)", -1, &st, nullptr), "stamp");
		sqlite3_bind_text(st, 1, BUILDAT_VERSION, -1, SQLITE_STATIC);
		const int stamped = sqlite3_step(st);
		sqlite3_finalize(st);
		check(m_db, stamped, "stamp");
	}
	~CSave()
	{
		m_stores.clear();
		m_stmts.finalize_all();
		if(m_db){
			// Leaves one file instead of three, and is a no-op if anything
			// else still has the database open
			sqlite3_exec(m_db, "PRAGMA wal_checkpoint(TRUNCATE)",
					nullptr, nullptr, nullptr);
			sqlite3_close(m_db);
		}
	}

	void exec(const char *sql)
	{
		char *err = nullptr;
		int rc = sqlite3_exec(m_db, sql, nullptr, nullptr, &err);
		if(rc != SQLITE_OK){
			ss_ msg = err ? err : "unknown error";
			sqlite3_free(err);
			throw SqliteError(ss_()+sql+": "+msg);
		}
	}

	Store* store(const ss_ &name)
	{
		interface::MutexScope ms(m_mutex);
		auto it = m_stores.find(name);
		if(it != m_stores.end())
			return it->second.get();
		CStore *store = new CStore(this, name);
		m_stores[name] = up_<CStore>(store);
		return store;
	}

	ss_ path(){ return m_path; }

	int64_t pragma(const char *sql)
	{
		Stmt st(m_db, m_stmts, sql);
		return st.step() ? atoll(st.column_text(0).c_str()) : 0;
	}

	int64_t bytes()
	{
		int64_t live = 0;
		if(m_db){
			interface::MutexScope ms(m_mutex);
			live = (pragma("PRAGMA page_count") -
					pragma("PRAGMA freelist_count")) * pragma("PRAGMA page_size");
		}
		if(m_path.empty())
			return live;
		return live + (int64_t)interface::fs::directory_tree_size(m_path) -
				(int64_t)interface::fs::file_size(m_path+"/save.sqlite");
	}

	// Under the mutex, so voxelworld's writes wait for it rather than
	// meeting a locked database
	ss_ vacuum(const ss_ &sql)
	{
		interface::MutexScope ms(m_mutex);
		if(!m_db)
			return "no database";
		if(m_batch_depth > 0)
			return "a transaction is open";
		try {
			exec(sql.c_str());
			exec("PRAGMA wal_checkpoint(TRUNCATE)");
		} catch(std::exception &e){
			return e.what();
		}
		return "";
	}
	ss_ compact(){ return vacuum("VACUUM"); }
	ss_ copy_to(const ss_ &file)
	{
		ss_ quoted;
		for(char c : file)
			quoted += c == '\'' ? ss_("''") : ss_(1, c);
		return vacuum("VACUUM INTO '"+quoted+"'");
	}
};

bool CStore::get(const ss_ &key, ss_ &value_out)
{
	interface::MutexScope ms(m_save->m_mutex);
	Stmt st(m_save->m_db, m_save->m_stmts,
			"SELECT value FROM store WHERE store=? AND key=?");
	st.bind_text(1, m_name);
	st.bind_text(2, key);
	if(!st.step())
		return false;
	value_out = st.column_blob(0);
	return true;
}

void CStore::set(const ss_ &key, const ss_ &value)
{
	interface::MutexScope ms(m_save->m_mutex);
	Stmt st(m_save->m_db, m_save->m_stmts,
			"INSERT INTO store (store, key, value) VALUES (?, ?, ?)"
			" ON CONFLICT(store, key) DO UPDATE SET value=excluded.value");
	st.bind_text(1, m_name);
	st.bind_text(2, key);
	st.bind(3, value);
	st.step();
}

void CStore::remove(const ss_ &key)
{
	interface::MutexScope ms(m_save->m_mutex);
	Stmt st(m_save->m_db, m_save->m_stmts, "DELETE FROM store WHERE store=? AND key=?");
	st.bind_text(1, m_name);
	st.bind_text(2, key);
	st.step();
}

sv_<ss_> CStore::list(const ss_ &prefix)
{
	interface::MutexScope ms(m_save->m_mutex);
	// >= prefix and < prefix with its last byte raised is the range a B-tree
	// can seek to, and it does not have to care what LIKE thinks % means
	sv_<ss_> result;
	if(prefix.empty()){
		Stmt st(m_save->m_db, m_save->m_stmts,
				"SELECT key FROM store WHERE store=? ORDER BY key");
		st.bind_text(1, m_name);
		while(st.step())
			result.push_back(st.column_text(0));
		return result;
	}
	ss_ upper = prefix;
	size_t i = upper.size();
	while(i > 0 && (unsigned char)upper[i-1] == 0xff)
		i--;
	if(i == 0){
		// Every byte is 0xff, so there is no next string; fall back to a
		// scan of the store
		Stmt st(m_save->m_db, m_save->m_stmts,
				"SELECT key FROM store WHERE store=? ORDER BY key");
		st.bind_text(1, m_name);
		while(st.step()){
			ss_ key = st.column_text(0);
			if(key.compare(0, prefix.size(), prefix) == 0)
				result.push_back(key);
		}
		return result;
	}
	upper.resize(i);
	upper[i-1] = (char)((unsigned char)upper[i-1] + 1);
	Stmt st(m_save->m_db, m_save->m_stmts,
			"SELECT key FROM store WHERE store=? AND key>=? AND key<?"
			" ORDER BY key");
	st.bind_text(1, m_name);
	st.bind_text(2, prefix);
	st.bind_text(3, upper);
	while(st.step())
		result.push_back(st.column_text(0));
	return result;
}

void CStore::batch(std::function<void()> writes)
{
	interface::MutexScope ms(m_save->m_mutex);
	if(m_save->m_batch_depth > 0){
		// Inside another batch: its transaction, its commit or rollback
		m_save->m_batch_depth++;
		try {
			writes();
		} catch(...){
			m_save->m_batch_depth--;
			throw;
		}
		m_save->m_batch_depth--;
		return;
	}
	// IMMEDIATE takes the write lock up front rather than half way through,
	// which is what turns a busy database into an error here instead of a
	// rollback after the work was done
	m_save->exec("BEGIN IMMEDIATE");
	m_save->m_batch_depth = 1;
	try {
		writes();
	} catch(...){
		m_save->m_batch_depth = 0;
		sqlite3_exec(m_save->m_db, "ROLLBACK", nullptr, nullptr, nullptr);
		throw;
	}
	m_save->m_batch_depth = 0;
	m_save->exec("COMMIT");
}

// Deleting a save deletes a directory the user made. Only names valid_name()
// accepts ever get here, and only under the one saves directory, so this
// cannot be pointed at anything else by a bad name.
static bool remove_directory_tree(const ss_ &path)
{
	bool ok = true;
	for(const interface::fs::Node &n : interface::fs::list_directory(path)){
		if(n.name == "." || n.name == "..")
			continue;
		ss_ sub = path+"/"+n.name;
		if(n.is_directory){
			if(!remove_directory_tree(sub))
				ok = false;
		} else {
			if(::remove(sub.c_str()) != 0)
				ok = false;
		}
	}
#ifdef _WIN32
	if(_rmdir(path.c_str()) != 0)
		ok = false;
#else
	if(::rmdir(path.c_str()) != 0)
		ok = false;
#endif
	return ok;
}

static int64_t file_modified_us(const ss_ &path)
{
	struct stat st;
	if(stat(path.c_str(), &st) != 0)
		return 0;
	return (int64_t)st.st_mtime * 1000000;
}

struct Module: public interface::Module, public Interface
{
	interface::Server *m_server;
	ss_ m_saves_path;
	// Saves this server has open. The pointer a module holds stays valid
	// until it closes it.
	sv_<up_<CSave>> m_open;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
	{
		// One app per server -- it is started -m ../apps/<app> and that is
		// the whole of it -- so the app is not a parameter of any call here,
		// and an app has no way to name another app's saves.
		m_saves_path = m_server->get_config().get<ss_>("user_path")+
				"/apps/"+m_server->get_app_id()+"/saves";
	}

	~Module()
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		check_round_trip();
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_VOIDN("core:tick", on_tick)
	}

	// [SAVE_LIMIT] The host's cap on what the app writes ([SERVER_CAPS]'s
	// max_disk_mb, also --max-world-mb), and what it has written
	Usage m_usage;
	int64_t m_saves_measured_us = 0, m_rest_measured_us = 0;
	bool m_over = false;
	bool m_said_limit = false;

	ss_ app_user_path()
	{
		return m_server->get_config().get<ss_>("user_path")+"/apps/"+
				m_server->get_app_id();
	}
	// The box sets cache_path to the app's own cache; unconfined it is the
	// shared one, and the app's part of it is where the box would put it
	ss_ app_cache_path()
	{
		const ss_ c = m_server->get_config().get<ss_>("cache_path");
		const ss_ own = "/apps/"+m_server->get_app_id();
		if(c.size() >= own.size() &&
				c.compare(c.size() - own.size(), own.size(), own) == 0)
			return c;
		return c+own;
	}

	void measure(bool all)
	{
		const int64_t now = interface::os::time_us();
		// The app's user directory with each open save at its live bytes
		int64_t saves = (int64_t)interface::fs::directory_tree_size(
				app_user_path());
		set_<ss_> seen; // A save opened twice is one directory
		for(const up_<CSave> &save : m_open){
			if(!seen.insert(save->m_path).second)
				continue;
			saves -= (int64_t)interface::fs::directory_tree_size(save->m_path);
			saves += save->bytes();
		}
		m_usage.saves = std::max<int64_t>(saves, 0);
		m_saves_measured_us = now;
		if(all || now - m_rest_measured_us >= 60000000){
			m_usage.shared = (int64_t)interface::fs::directory_tree_size(
					m_server->get_config().get<ss_>("user_path")+"/shared/"+
					m_server->get_app_id());
			m_usage.cache = (int64_t)interface::fs::directory_tree_size(
					app_cache_path());
			m_rest_measured_us = now;
		}
	}

	void on_tick()
	{
		const int64_t now = interface::os::time_us();
		// On the first tick even when whoever asked usage() first has
		// measured already: the start line comes at the start
		const bool first = !m_said_limit;
		if(!first && now - m_saves_measured_us < 10000000)
			return;
		m_said_limit = true;
		measure(first);
		const int64_t used = m_usage.total(), limit = limit_bytes();
		// Whole MB, 1000000 bytes: the option's own unit
		auto mb = [](int64_t b){ return (long long)((b + 500000) / 1000000); };
		if(first && limit > 0)
			log_i(MODULE, "max_disk_mb %lld: %lld MB written (saves %lld MB, "
					"games and shared %lld MB, cache %lld MB)", mb(limit),
					mb(used), mb(m_usage.saves), mb(m_usage.shared),
					mb(m_usage.cache));
		else if(first)
			log_i(MODULE, "max_disk_mb: none");
		log_v(MODULE, "saves: %lld kB, shared %lld kB, cache %lld kB, of %lld kB",
				(long long)(m_usage.saves / 1024),
				(long long)(m_usage.shared / 1024),
				(long long)(m_usage.cache / 1024), (long long)(limit / 1024));
		if(limit <= 0)
			return;
		if(used >= limit){
			if(!m_over)
				log_w(MODULE, "%lld MB written, over the limit of %lld MB",
						mb(used), mb(limit));
			m_over = true;
		} else if(m_over && used < limit / 10 * 9){
			log_i(MODULE, "%lld MB written, under 90%% of the limit again",
					mb(used));
			m_over = false;
		}
		if(m_over)
			m_server->emit_event("storage:over_limit",
					new OverLimit(m_usage, limit));
	}

	Usage usage()
	{
		if(m_saves_measured_us == 0)
			measure(true);
		return m_usage;
	}
	int64_t used_bytes(){ return usage().total(); }
	int64_t limit_bytes()
	{
		return atoll(m_server->get_config().get<ss_>("max_disk_mb").c_str()) *
				1000000;
	}
	int64_t room_bytes()
	{
		const int64_t limit = limit_bytes();
		return limit > 0 ? limit - used_bytes() : INT64_MAX;
	}
	void remeasure(){ measure(true); }

	void on_start()
	{
	}

	// The check: a save's whole life, on a database that is never a file.
	// Everything above the sqlite calls -- the batch, the prefix range, the
	// blob round trip -- is what this is here for.
	void check_round_trip()
	{
		CSave save("", true);
		Store *s = save.store("things");
		ss_ v;
		if(s->get("a", v))
			throw Exception("storage check: a new store had a key in it");
		// A value with a zero byte in it, because these are blobs and a save
		// is full of serialized volumes
		ss_ binary("x\0y", 3);
		s->batch([&](){
			s->set("a", binary);
			s->set("b/1", "one");
			s->set("b/2", "two");
			s->set("c", "three");
		});
		if(!s->get("a", v) || v != binary)
			throw Exception("storage check: value did not survive");
		if(v.size() != 3)
			throw Exception("storage check: value was cut at a zero byte");
		sv_<ss_> keys = s->list("b/");
		if(keys.size() != 2 || keys[0] != "b/1" || keys[1] != "b/2")
			throw Exception("storage check: prefix list");
		if(s->list("").size() != 4)
			throw Exception("storage check: full list");
		s->set("a", "again");
		if(!s->get("a", v) || v != "again")
			throw Exception("storage check: overwrite");
		s->remove("a");
		if(s->get("a", v))
			throw Exception("storage check: remove");
		// Stores are namespaces: the same key in another one is another value
		Store *other = save.store("others");
		if(other->get("c", v))
			throw Exception("storage check: stores are not separate");
		// A failed batch leaves nothing behind
		try {
			s->batch([&](){
				s->set("d", "four");
				throw Exception("deliberate");
			});
			throw Exception("storage check: batch swallowed an exception");
		} catch(Exception &e){
		}
		if(s->get("d", v))
			throw Exception("storage check: a failed batch was not rolled back");
		// [SAVE_LIMIT] Live bytes: up with a large value, down with its delete
		const int64_t b0 = save.bytes();
		s->set("big", ss_(200000, 'x'));
		const int64_t b1 = save.bytes();
		s->remove("big");
		if(!(b1 >= b0 + 150000 && save.bytes() < b1 - 150000))
			throw Exception("storage check: live bytes "+itos(b0)+", "+
					itos(b1)+", "+itos(save.bytes()));
		// Nested: one transaction, the inner's failure the outer's rollback
		s->batch([&](){
			s->set("e", "five");
			other->batch([&](){ other->set("e", "five"); });
		});
		if(!s->get("e", v) || !other->get("e", v))
			throw Exception("storage check: a nested batch was lost");
		try {
			s->batch([&](){
				s->set("f", "six");
				other->batch([&](){ throw Exception("deliberate"); });
			});
		} catch(Exception &e){
		}
		if(s->get("f", v))
			throw Exception("storage check: a nested failure was not rolled back");

		if(valid_name("..") || valid_name("a/b") || valid_name("") ||
				valid_name(".hidden") || valid_name("a\\b"))
			throw Exception("storage check: valid_name accepted a bad name");
		if(!valid_name("my save") || !valid_name("world_1"))
			throw Exception("storage check: valid_name refused a good name");
	}

	// Interface

	// A save name becomes a directory name, so this is where it stops being
	// whatever a game felt like passing.
	bool valid_name(const ss_ &name)
	{
		if(name.empty() || name.size() > 200)
			return false;
		if(name[0] == '.')
			return false;
		if(name[name.size()-1] == '.' || name[name.size()-1] == ' ')
			return false; // Windows quietly strips these
		for(char c : name){
			unsigned char u = (unsigned char)c;
			if(u < 0x20 || c == '/' || c == '\\' || c == ':' || c == '*' ||
					c == '?' || c == '"' || c == '<' || c == '>' || c == '|')
				return false;
		}
		// Nor a Windows device: "CON" or "nul.txt" is the console or
		// nothing, not a directory ([SECURITY_RUN_1])
		ss_ stem = name.substr(0, name.find('.'));
		for(char &c : stem)
			c = (char)toupper((unsigned char)c);
		if(stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL")
			return false;
		if(stem.size() == 4 && (stem.compare(0, 3, "COM") == 0 ||
				stem.compare(0, 3, "LPT") == 0) && stem[3] >= '0' &&
				stem[3] <= '9')
			return false;
		return true;
	}

	// **The release a save was made with** ([AITTA_MVP]): an app
	// installed from one is "<version> <sha256>" here, read from its own
	// directory, and a tree app is "". A save keeps the release that made
	// it, and another version of the app does not open it -- an update is
	// a new version beside the old, and the save stays with the old.
	ss_ this_release()
	{
		const ss_ dir = m_server->get_modules_path();
		std::ifstream f(dir+"/.aitta_sha256");
		ss_ hash;
		if(!(f>>hash))
			return "";
		json::json_error_t e;
		const json::Value m = json::load_file((dir+"/meta.json").c_str(), &e);
		const json::Value &v = m.get("version");
		return (v.is_string() ? v.as_string() : ss_("?"))+" "+hash;
	}

	// False where the save is another release's
	bool pin(Save *save, const ss_ &name)
	{
		const ss_ release = this_release();
		if(release.empty())
			return true;
		Store *s = save->store("_aitta");
		ss_ was;
		if(!s->get("release", was)){
			s->set("release", release);
			return true;
		}
		if(was == release)
			return true;
		// The player said so: launched with aitta_move_saves=1, from the
		// grid's "move saves here" tile of this version
		const ss_ u = m_server->get_config().get<ss_>("untrusted_launch");
		if(("\n"+u+"\n").find("\naitta_move_saves=1\n") != ss_::npos){
			s->set("release", release);
			log_i(MODULE, "The save \"%s\" moved from release %s to %s",
					cs(name), cs(was), cs(release));
			return true;
		}
		log_w(MODULE, "The save \"%s\" was made with release %s of this app, "
				"and this is %s: not opened", cs(name), cs(was), cs(release));
		return false;
	}

	Save* open(const ss_ &name)
	{
		if(!valid_name(name)){
			log_w(MODULE, "open(): invalid save name \"%s\"", cs(name));
			return nullptr;
		}
		ss_ path = m_saves_path+"/"+name;
		if(!interface::fs::path_exists(path+"/save.sqlite")){
			log_v(MODULE, "open(): no save at [%s]", cs(path));
			return nullptr;
		}
		Save *save = open_at(path);
		if(!pin(save, name)){
			close(save);
			return nullptr;
		}
		return save;
	}

	Save* create(const ss_ &name)
	{
		if(!valid_name(name)){
			log_w(MODULE, "create(): invalid save name \"%s\"", cs(name));
			return nullptr;
		}
		ss_ path = m_saves_path+"/"+name;
		if(interface::fs::path_exists(path+"/save.sqlite")){
			log_w(MODULE, "create(): a save already exists at [%s]", cs(path));
			return nullptr;
		}
		interface::fs::create_directories(path);
		Save *save = open_at(path);
		pin(save, name);
		return save;
	}

	Save* open_at(const ss_ &path)
	{
		CSave *save = new CSave(path);
		m_open.push_back(up_<CSave>(save));
		log_v(MODULE, "Opened save [%s]", cs(path));
		return save;
	}

	void close(Save *save)
	{
		for(auto it = m_open.begin(); it != m_open.end(); it++){
			if(it->get() == save){
				m_open.erase(it);
				return;
			}
		}
		log_w(MODULE, "close(): this save is not open");
	}

	sv_<SaveInfo> list()
	{
		sv_<SaveInfo> result;
		for(const interface::fs::Node &n :
				interface::fs::list_directory(m_saves_path)){
			if(!n.is_directory || n.name == "." || n.name == "..")
				continue;
			ss_ db = m_saves_path+"/"+n.name+"/save.sqlite";
			if(!interface::fs::path_exists(db))
				continue;
			SaveInfo info;
			info.name = n.name;
			info.modified_us = file_modified_us(db);
			const ss_ path = m_saves_path+"/"+n.name;
			info.bytes = (int64_t)interface::fs::directory_tree_size(path);
			for(const up_<CSave> &save : m_open)
				if(save->m_path == path)
					info.bytes = save->bytes();
			result.push_back(info);
		}
		return result;
	}

	void remove(const ss_ &name)
	{
		if(!valid_name(name)){
			log_w(MODULE, "remove(): invalid save name \"%s\"", cs(name));
			return;
		}
		ss_ path = m_saves_path+"/"+name;
		if(!interface::fs::path_exists(path+"/save.sqlite")){
			log_w(MODULE, "remove(): no save at [%s]", cs(path));
			return;
		}
		for(const up_<CSave> &save : m_open){
			if(save->m_path == path){
				log_w(MODULE, "remove(): [%s] is open", cs(path));
				return;
			}
		}
		if(!remove_directory_tree(path))
			log_w(MODULE, "remove(): [%s] was not fully removed", cs(path));
	}

	void* get_interface()
	{
		return dynamic_cast<Interface*>(this);
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_storage(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}

// vim: set noet ts=4 sw=4:
