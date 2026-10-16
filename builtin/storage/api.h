// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/module.h"
#include <functional>
#include <sstream>
#include <cereal/archives/portable_binary.hpp>

namespace storage
{
	// A namespace of keys to blobs inside a save. Created on demand: an empty
	// store and a store that does not exist are the same thing.
	//
	// Every method takes the save's lock, so a Store* stays usable outside the
	// access() that produced it -- which is the point, since voxelworld keeps
	// one for the life of a world. What is not safe is closing a save while
	// another thread is using one of its stores; a save belongs to whoever
	// opened it.
	struct Store
	{
		virtual ~Store(){}
		virtual bool get(const ss_ &key, ss_ &value_out) = 0;
		virtual void set(const ss_ &key, const ss_ &value) = 0;
		virtual void remove(const ss_ &key) = 0;
		// Keys beginning with prefix, in order. "" is all of them.
		virtual sv_<ss_> list(const ss_ &prefix) = 0;
		// One transaction. The only sane way to write more than a few keys:
		// a key at a time outside a transaction is the classic slow save.
		virtual void batch(std::function<void()> writes) = 0;
	};

	struct Save
	{
		virtual ~Save(){}
		virtual Store* store(const ss_ &name) = 0;
		// The save's directory, for things that are not ours: a foreign
		// format, an importer's source, Luanti's core.get_worldpath().
		// Modules use the object store.
		virtual ss_ path() = 0;
		// [SAVE_LIMIT] What it takes on disk now: the database's live pages
		// and every other file in its directory (the -wal, a Luanti mod's own
		// files). simplified: the file keeps its high water mark, which the
		// next writes refill before it grows; a VACUUM gives it back, needing
		// the space twice while it runs.
		virtual int64_t bytes() = 0;
		// [WORLD_TRIM_MOVE] VACUUM: the file shrinks to its live pages, and
		// the writes wait meanwhile, seconds on a large save. "" or why not
		virtual ss_ compact() = 0;
		// A consistent copy of the database into file, which must not
		// exist (VACUUM INTO), for an export. "" or why not
		virtual ss_ copy_to(const ss_ &file) = 0;
	};

	// [SAVE_LIMIT] What the app has written, by the directories its box lets
	// it write: <user>/apps/<id> (its saves and the rest), <user>/shared/<id>
	// (vanilla's games) and <cache>/apps/<id>
	struct Usage
	{
		int64_t saves = 0, shared = 0, cache = 0;
		int64_t total() const { return saves + shared + cache; }
	};

	// storage:over_limit, every 10 s while the app is over the host's
	// max_disk_mb, until it is under 90% of it again
	struct OverLimit: public interface::Event::Private
	{
		Usage usage;
		int64_t limit = 0;
		OverLimit(const Usage &usage, int64_t limit):
			usage(usage), limit(limit){}
	};

	struct SaveInfo
	{
		ss_ name;
		int64_t modified_us = 0;
		// On disk: an open save by its live pages, as Save::bytes()
		int64_t bytes = 0;
	};

	struct Interface
	{
		// Split on purpose: neither call can do the other's job by accident,
		// so a typo in a save name cannot silently start a new game. open()
		// returns nullptr if it is not there; create() returns nullptr if it
		// already is. A game that wants open-or-create writes the two lines
		// itself, where they are visible.
		virtual Save* open(const ss_ &name) = 0;
		virtual Save* create(const ss_ &name) = 0;
		virtual void close(Save *save) = 0;
		virtual sv_<SaveInfo> list() = 0;
		// Deletes the save's directory and everything in it
		virtual void remove(const ss_ &name) = 0;
		// [WORLD_MENU] The save named `to` from now on; false if `from` is no
		// save or is open, or `to` is invalid or taken
		virtual bool rename(const ss_ &from, const ss_ &to) = 0;
		// false if it has a path separator, a leading dot, or anything else
		// that would make it something other than one directory name
		virtual bool valid_name(const ss_ &name) = 0;
		// [SAVE_LIMIT] As last measured: the saves every 10 s, the rest each
		// minute and on remeasure() (after an install)
		virtual Usage usage() = 0;
		virtual int64_t used_bytes() = 0;
		// The host's max_disk_mb, 0 for none
		virtual int64_t limit_bytes() = 0;
		// The limit less what is used; INT64_MAX with no limit
		virtual int64_t room_bytes() = 0;
		virtual void remeasure() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(storage::Interface*)> cb)
	{
		return server->access_module("storage", [&](interface::Module *module){
			auto *iface = (storage::Interface*)module->check_interface();
			cb(iface);
		});
	}

	// A value as a store holds it, and back: cereal's portable binary.
	// unpack() is false for data that does not read as a T
	template<typename T>
	ss_ pack(const T &value)
	{
		std::ostringstream os(std::ios::binary);
		{
			cereal::PortableBinaryOutputArchive ar(os);
			ar(value);
		}
		return os.str();
	}
	template<typename T>
	bool unpack(const ss_ &data, T &value)
	{
		try {
			std::istringstream is(data, std::ios::binary);
			cereal::PortableBinaryInputArchive ar(is);
			ar(value);
			return true;
		} catch(std::exception &e){
			return false;
		}
	}
}

// vim: set noet ts=4 sw=4:
