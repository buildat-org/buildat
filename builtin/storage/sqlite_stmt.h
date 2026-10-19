// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
// SPDX-License-Identifier: Apache-2.0 OR MIT
#pragma once
// **One prepared-statement wrapper** ([REWORK_1019_FIXES] apps 10): the
// storage module's, Hearth's and the Luanti import's. Header only; the
// includer links sqlite, as each of them already does.
//
// A statement from a Cache is prepared once per connection and reset when
// let go. Preparing per use was 8% of a server's time in sqlite's parser
// under storage's set() ([WORLDGEN_DRIFT], 2026-09-19), and Hearth prepared
// every one of its statements on every use. One in use and asked for again
// (a nested query of the same text) is prepared apart for that use. A
// Cache belongs to one connection and one thread at a time, and is
// finalize_all()ed before the connection closes. SQL made at run time with
// values in it (an IN list) is not cached: pass no Cache, or the cache
// grows by one statement per distinct text.
#include "core/types.h"
#include <sqlite3.h>
#include <unordered_map>

namespace sqlite_stmt
{
	struct Cache
	{
		struct Entry {
			sqlite3_stmt *st = nullptr;
			bool busy = false;
		};
		std::unordered_map<ss_, Entry> by_sql;
		void finalize_all()
		{
			for(auto &p : by_sql)
				sqlite3_finalize(p.second.st);
			by_sql.clear();
		}
	};

	// Values bound in order, columns read by index. A failed prepare or step
	// throws Exception with `who` before sqlite's message; a bind is not
	// checked (a wrong one fails the step), as Hearth's never were.
	struct Stmt
	{
		sqlite3 *db = nullptr;
		sqlite3_stmt *st = nullptr;
		Cache::Entry *entry = nullptr;
		const char *who = "";
		int n = 0;

		// For prepare() by hand, where a failed prepare is an answer (a
		// schema that is not there)
		Stmt() = default;
		Stmt(sqlite3 *db, Cache *cache, const ss_ &sql, const char *who):
			db(db), who(who)
		{
			if(cache){
				Cache::Entry &e = cache->by_sql[sql];
				if(e.st && !e.busy){
					st = e.st;
					e.busy = true;
					entry = &e;
					return;
				}
				if(!e.st){
					fail_if(sqlite3_prepare_v2(db, sql.c_str(), -1, &e.st,
							nullptr), sql.c_str());
					st = e.st;
					e.busy = true;
					entry = &e;
					return;
				}
			}
			fail_if(sqlite3_prepare_v2(db, sql.c_str(), -1, &st, nullptr),
					sql.c_str());
		}
		Stmt(const Stmt&) = delete;
		Stmt& operator=(const Stmt&) = delete;
		~Stmt()
		{
			if(entry){
				sqlite3_reset(st);
				sqlite3_clear_bindings(st);
				entry->busy = false;
			} else {
				sqlite3_finalize(st);
			}
		}
		// sqlite's code, nothing thrown; uncached
		int prepare(sqlite3 *with, const char *sql)
		{
			sqlite3_finalize(st);
			st = nullptr;
			db = with;
			return sqlite3_prepare_v2(db, sql, -1, &st, nullptr);
		}
		operator sqlite3_stmt*() const { return st; }

		void fail_if(int rc, const char *what)
		{
			if(rc != SQLITE_OK && rc != SQLITE_ROW && rc != SQLITE_DONE)
				throw Exception(ss_(who)+(db ? sqlite3_errmsg(db) :
						"no connection")+" in "+what);
		}
		Stmt& b(int64_t v)
		{
			sqlite3_bind_int64(st, ++n, v);
			return *this;
		}
		Stmt& b(const ss_ &v)
		{
			sqlite3_bind_text(st, ++n, v.data(), (int)v.size(), SQLITE_TRANSIENT);
			return *this;
		}
		Stmt& blob(const ss_ &v)
		{
			sqlite3_bind_blob(st, ++n, v.data(), (int)v.size(), SQLITE_TRANSIENT);
			return *this;
		}
		// A row (true) or the end (false)
		bool step()
		{
			const int rc = sqlite3_step(st);
			fail_if(rc, "step");
			return rc == SQLITE_ROW;
		}
		int64_t i(int col){ return sqlite3_column_int64(st, col); }
		ss_ s(int col)
		{
			const char *p = (const char*)sqlite3_column_text(st, col);
			return p ? ss_(p, sqlite3_column_bytes(st, col)) : ss_();
		}
		ss_ blob_at(int col)
		{
			const char *p = (const char*)sqlite3_column_blob(st, col);
			const int len = sqlite3_column_bytes(st, col);
			return p && len > 0 ? ss_(p, (size_t)len) : ss_();
		}
	};
}
// vim: set noet ts=4 sw=4:
