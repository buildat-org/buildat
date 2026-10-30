#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min (2026-10-29)
# covers: builtin/voxelworld/persistence.h builtin/voxelworld/api.h builtin/luanti/node_meta.h builtin/luanti/lua/bootstrap.lua
# [KIT] stage 1, voxelworld's voxel owners.
#   1. A server-only app (written here): an owner's entry survives its
#      section's unload and reload and a restart; a routed write to an
#      owned position reaches the owner's handler and leaves the voxel, one
#      to a position nobody owns is written, one to a position whose owner
#      has no handler is refused; an unloaded section's entries are read
#      from the save and replaced there.
#   2. Vanilla on the minimal game, no client: node metadata (a field and
#      an inventory list) at the origin and in a far section a forceload
#      loads and lets go, read back after that section's unload and reload
#      and after a restart; the restart's save has older saves' rows of it
#      put back in (the one blob, and the blob per section), which come
#      out of the migration onto the voxel owners; a field written to far
#      while it is away again and a chest in a section never loaded (far2)
#      are there after the restart ([LUANTI_META_FAR_WRITE]); the save, stamped
#      format 1 as a build before the owners left it, is stamped 2.
#
#   util/voxel_owners_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp voxel_owners; t=$CHECK_TMP
# Under the repo, not /tmp: the boxed server reads nothing in /tmp
app="$here/local/voxel_owners_app"
save="$BUILDAT_USER_PATH/apps/voxel_owners_app/saves/world"
rm -rf "$app" "$save"
mkdir -p "$app/main"
cat > "$app/main/meta.json" <<'JSON'
{
	"engine_api": 2,
	"kind": "check",
	"dependencies": [
		{"module": "main_context"},
		{"module": "storage"},
		{"module": "voxelworld"}
	]
}
JSON
cat > "$app/main/main.cpp" <<'CPP'
// voxel_owners_check.sh's app: OWNERS_MODE is write or read
#include "core/log.h"
#include "main_context/api.h"
#include "storage/api.h"
#include "voxelworld/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/voxel.h"
#include <cstdlib>
#define MODULE "main"
namespace pv = PolyVox;
using interface::Event;
using interface::VoxelInstance;
using voxelworld::Owned;

namespace main {

struct Door: voxelworld::OwnerHandler
{
	int calls = 0;
	void on_write(voxelworld::Instance *world, const pv::Vector3DInt32 &p,
			const VoxelInstance &v, const Owned &owned, const ss_ &by)
	{
		calls++;
		log_i(MODULE, "owners: routed to %s at (%i,%i,%i) by %s, data %s",
				cs(owned.owner), p.getX(), p.getY(), p.getZ(), cs(by),
				cs(owned.data));
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene = 0;
	storage::Save *m_save = nullptr;
	ss_ m_mode;
	int m_ticks = 0;
	bool m_done = false;
	int m_failed = 0;

	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server)
	{}

	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
	}

	void on_start()
	{
		const char *m = getenv("OWNERS_MODE");
		m_mode = m ? m : "";
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
		});
		storage::access(m_server, [&](storage::Interface *istorage){
			m_save = istorage->open("world");
			if(!m_save)
				m_save = istorage->create("world");
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			ivw->create_instance(m_scene, pv::Region(0, 0, 0, 0, 0, 0));
			voxelworld::Instance *world = ivw->get_instance(m_scene);
			interface::VoxelRegistry *reg = world->get_voxel_reg();
			interface::VoxelFormat f;
			f.id = interface::VoxelField{0, 0, 16};
			reg->set_format(f);
			for(const char *name : {"air", "stone"}){
				interface::VoxelDefinition def;
				def.name.block_name = name;
				def.edge_material_id = interface::EDGEMATERIALID_GROUND;
				reg->add_voxel(def);
			}
			world->set_save(m_save, "main");
		});
	}

	void expect(bool ok, const char *what)
	{
		log_i(MODULE, "owners: %s: %s", ok ? "ok" : "FAILED", what);
		if(!ok)
			m_failed++;
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(m_done)
			return;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *world = ivw->get_instance(m_scene);
			const pv::Vector3DInt16 s(0, 0, 0);
			if(++m_ticks < 100 && !world->is_section_loaded(s))
				return;
			const pv::Vector3DInt32 door(3, 4, 5), sign(6, 4, 5),
					free_p(9, 4, 5);
			const VoxelInstance stone(2);
			auto door_data = [&](){
				Owned o;
				return world->get_owned(door, o) && o.owner == "door" ?
						o.data : ss_("(none)");
			};
			auto door_handler = std::make_shared<Door>();
			world->set_owner_handler("door", door_handler);
			if(m_mode == "write"){
				world->set_section_generated(s);
				Owned o;
				o.owner = "door";
				o.data = "open";
				expect(world->set_owned(door, o), "set_owned in a loaded section");
				o.owner = "sign";
				o.data = "hello";
				world->set_owned(sign, o);
				expect(!world->set_owned(pv::Vector3DInt32(0, 400, 0), o),
						"set_owned outside the world refused");
				const VoxelInstance before = world->get_voxel(door);
				expect(world->routed_set_voxel(door, stone, "alice") ==
						voxelworld::Instance::ROUTED && door_handler->calls == 1,
						"a routed write to the door reaches its handler");
				expect(world->get_voxel(door).data == before.data,
						"and the door's voxel is not written");
				expect(world->routed_set_voxel(free_p, stone, "alice") ==
						voxelworld::Instance::WRITTEN &&
						world->get_voxel(free_p).data == stone.data,
						"a routed write nobody owns is written");
				expect(world->routed_set_voxel(sign, stone, "alice") ==
						voxelworld::Instance::REFUSED &&
						world->get_voxel(sign).data != stone.data,
						"an owner with no handler: refused");
				world->set_voxel(sign, stone);
				expect(world->get_voxel(sign).data == stone.data,
						"set_voxel() stays direct on an owned position");
				world->commit();
				world->unload_section(s);
				Owned gone;
				expect(!world->is_section_loaded(s) &&
						!world->get_owned(door, gone), "unloaded: not in memory");
				voxelworld::OwnedList doors = world->get_section_owned(s, "door");
				expect(doors.size() == 1 && doors[0].first == door &&
						doors[0].second == "open", "unloaded: read from the save");
				world->set_section_owned(s, "sign", {});
				expect(world->get_section_owned(s, "sign").empty() &&
						world->get_section_owned(s, "door").size() == 1,
						"unloaded: one owner's replaced, the other's kept");
				world->load_section_no_generate(s);
				expect(door_data() == "open", "reloaded: the door's entry");
				expect(!world->get_owned(sign, gone), "reloaded: no sign");
				expect(world->get_voxel(free_p).data == stone.data,
						"reloaded: the routed write's voxel");
				o.owner = "door";
				o.data = "closed";
				world->set_owned(door, o);
			} else {
				expect(door_data() == "closed", "restarted: the door's entry");
				expect(world->routed_set_voxel(door, stone, "bob") ==
						voxelworld::Instance::ROUTED && door_handler->calls == 1,
						"restarted: a routed write reaches the handler");
			}
			world->set_owner_handler("door", nullptr);
			log_i(MODULE, "owners: %s: %i failed", cs(m_mode), m_failed);
			m_done = true;
			m_server->shutdown(0, "voxel_owners_check");
		});
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
CPP

cd "$here/Build"
run() # <mode>: the app's server, its log in $t/<mode>.log
{
	OWNERS_MODE=$1 timeout 120 bin/buildat_server -m "$app" \
		-P "$((29700 + RANDOM % 300))" > "$t/$1.log" 2>&1
}
for mode in write read; do
	run $mode || fail "$mode exited $? ($t/$mode.log)"
	grep -a "owners: " "$t/$mode.log" | sed 's/.*owners: /  /'
	grep -aq "owners: $mode: 0 failed" "$t/$mode.log" ||
		fail "$mode: $(grep -a 'owners: FAILED\| E ' "$t/$mode.log" | head -3)"
done
rm -rf "$app" "$save"
echo "ok: voxelworld's owners"

# 2. Vanilla's node metadata. The far section: x 1000, which nothing but
# the forceload loads
mkdir -p "$t/u/shared" "$t/u/apps/vanilla/saves/w/luanti"
echo "enable_damage = false" > "$t/u/apps/vanilla/saves/w/luanti/world.mt"
cat > "$t/u/shared/common.lua" <<'L'
near = {x = 2, y = 1, z = 2}
far = {x = 1000, y = 1, z = 2}
far_block = {x = 62, y = 0, z = 0}
-- [LUANTI_META_FAR_WRITE] In a section nothing loads before the restart
far2 = {x = 2000, y = 1, z = 2}
far2_block = {x = 125, y = 0, z = 0}
function say(s) core.log("action", "owners_check: " .. s) end
function meta_of(p)
	local m = core.get_meta(p)
	return m:get_string("kept") .. "/" ..
			m:get_inventory():get_stack("main", 1):to_string()
end
function put(p, v)
	local m = core.get_meta(p)
	m:set_string("kept", v)
	m:get_inventory():set_size("main", 1)
	m:get_inventory():set_stack("main", 1, "floor:glass 3")
end
-- f() every second until it says it is done
function poll(f)
	core.after(1, function() if not f() then poll(f) end end)
end
function loaded(p) return core.get_node(p).name ~= "ignore" end
-- After the world is there: the blocks kept loaded (near's too: a server
-- with no player keeps nothing else), then f() polled
function start(blocks, f)
	core.after(1, function()
		for _, b in ipairs(blocks) do core.__forceload_block_raw(b) end
		poll(f)
	end)
end
L
cat "$t/u/shared/common.lua" - > "$t/u/shared/write.lua" <<'L'
-- far in a section the forceload loads, lets go and loads again
start({{x = 0, y = 0, z = 0}, far_block}, function()
	if not loaded(near) or not loaded(far) then return false end
	put(near, "near")
	put(far, "far")
	core.__forceload_free_block_raw(far_block)
	say("written, far let go")
	poll(function()
		if loaded(far) then return false end
		-- A second for the module to hear of the unload
		core.after(1, function()
			say("far unloaded, meta in memory: " .. #core.find_nodes_with_meta(
					{x = 990, y = -10, z = -10}, {x = 1010, y = 10, z = 10}))
			core.__forceload_block_raw(far_block)
			poll(function()
				if not loaded(far) then return false end
				say("reloaded: far " .. meta_of(far))
				-- [LUANTI_META_FAR_WRITE] Writes while far is away again
				-- and to far2, never loaded: kept, along with what far had
				core.__forceload_free_block_raw(far_block)
				poll(function()
					if loaded(far) then return false end
					core.get_meta(far):set_string("late", "yes")
					put(far2, "far2")
					say("written while away")
					core.request_shutdown("owners_check")
					return true
				end)
				return true
			end)
		end)
		return true
	end)
	return true
end)
L
cat "$t/u/shared/common.lua" - > "$t/u/shared/read.lua" <<'L'
local old_sec = {x = -70, y = 1, z = 3}
start({{x = 0, y = 0, z = 0}, far_block, {x = -5, y = 0, z = 0}, far2_block},
		function()
	if not loaded(near) or not loaded(far) or not loaded(old_sec) or
			not loaded(far2) then
		return false
	end
	say("restarted: near " .. meta_of(near) .. ", far " .. meta_of(far) ..
			" late " .. core.get_meta(far):get_string("late") ..
			", far2 " .. meta_of(far2) ..
			", old_blob " .. meta_of({x = 3, y = 1, z = 3}) ..
			", old_section " .. meta_of(old_sec))
	core.request_shutdown("owners_check")
	return true
end)
L
vrun() # <write|read>: vanilla on the save with that fixture, to its stop
{
	BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=w \
		BUILDAT_LUANTI_LUA="$t/u/shared/$1.lua" \
		start_server "$t/v_$1.log" "STATUS Listening" 120 auto \
		bin/buildat_server -A 127.0.0.1 -m ../apps/vanilla -D "$t/u" \
		-C "$t/c" -l 4 || fail "vanilla did not start ($t/v_$1.log)"
	CHECK_PIDS+=($SERVER_PID)
	wait_for_log "$t/v_$1.log" "owners_check: (restarted|written while away)" 120
	for _i in $(seq 150); do kill -0 $SERVER_PID 2>/dev/null || break; sleep 0.2; done
	grep -a "owners_check: " "$t/v_$1.log" | sed 's/.*owners_check: /  /'
	kill -0 $SERVER_PID 2>/dev/null && fail "vanilla did not stop ($t/v_$1.log)"
}
vrun write
grep -aq "owners_check: far unloaded, meta in memory: 0" "$t/v_write.log" ||
	fail "the far section's metadata stayed in memory ($t/v_write.log)"
grep -aq "owners_check: reloaded: far far/floor:glass 3" "$t/v_write.log" ||
	fail "lost over the unload ($t/v_write.log)"
# An older save's rows of it, in the luanti module's own store: the one
# blob and a blob per section (x -70 is section -2 of 64)
db="$t/u/apps/vanilla/saves/w/save.sqlite"
[ -f "$db" ] || db=$(ls "$t"/u/apps/vanilla/saves/w/*.sqlite | head -1)
sqlite3 "$db" "INSERT OR REPLACE INTO store (store, key, value) VALUES
	('luanti', 'node_meta', CAST('return {[\"3,1,3\"] = {fields = {kept = \"old\"}, inventory = {main = {\"floor:glass 3\"}}}}' AS BLOB)),
	('luanti', 'node_meta/-2,0,0', CAST('return {[\"-70,1,3\"] = {fields = {kept = \"oldsec\"}, inventory = {main = {\"floor:glass 3\"}}}}' AS BLOB));" ||
	fail "could not write the old rows into $db"
sqlite3 "$db" "PRAGMA user_version = 1; UPDATE store SET value = '0.7.0' WHERE store = '__save' AND key = 'version';" ||
	fail "could not stamp $db as format 1"
vrun read
grep -aq "Moving 2 node metadata out of 2 rows" "$t/v_read.log" ||
	fail "no migration logged ($t/v_read.log)"
grep -aq "owners_check: restarted: near near/floor:glass 3, far far/floor:glass 3 late yes, far2 far2/floor:glass 3, old_blob old/floor:glass 3, old_section oldsec/floor:glass 3" "$t/v_read.log" ||
	fail "lost over the restart ($t/v_read.log)"
[ -z "$(sqlite3 "$db" "SELECT key FROM store WHERE store = 'luanti' AND key LIKE 'node_meta%'")" ] ||
	fail "the old rows are still there"
[ "$(sqlite3 "$db" "PRAGMA user_version")" = 2 ] ||
	fail "the migrated save is not stamped format 2"
[ "$(sqlite3 "$db" "SELECT value FROM store WHERE store = '__save' AND key = 'version'")" != 0.7.0 ] ||
	fail "the migrated save's version row is not this build's"
echo "PASS: owners kept over unload, reload and restart; routed writes to the handler, written or refused; vanilla's metadata over an unload and a restart and written to sections away, older saves' rows migrated and the save stamped format 2"
# vim: set noet ts=4 sw=4:
