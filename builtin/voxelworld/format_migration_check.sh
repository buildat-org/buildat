#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: 10s
# [VOXELFORMAT_PRESETS]: a saved world whose id field is widened, through
# voxelworld's save. A server-only app (written here) writes 1000 voxel types
# with a 16-bit id, then reopens the world with a 20-bit id and the game's
# zero-extending VoxelMigration: every id comes through and the section is
# written back in the new format, which a third open reads with no
# migration at all. A copy of the 16-bit save reopened with 20 bits and no
# migration is refused, and nothing is written to it. A world that sets no
# format at all exits non-zero, naming set_format(). Prints PASS or FAIL.
#
#   builtin/voxelworld/format_migration_check.sh
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp format_migration
# Under the repo, not /tmp: the boxed server reads nothing in /tmp
app="$here/local/format_migration"
save="$BUILDAT_USER_PATH/apps/format_migration/saves/world"
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
// format_migration_check.sh's app: FORMAT_MIGRATION_MODE is write16,
// read20 (with the game's migration), read20_bare (without) or noformat
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
using interface::VoxelField;
using interface::VoxelFormat;
using interface::VoxelInstance;
using interface::VoxelVolume;

namespace main {

static const int N = 1000;

static VoxelFormat format(int id_bits)
{
	VoxelFormat f;
	f.id = VoxelField{0, 0, (uint8_t)id_bits};
	f.light_sky = VoxelField{0, (uint8_t)id_bits, 4};
	return f;
}

// The game's: the id zero-extended into the wider field
struct Widen: interface::VoxelMigration
{
	VoxelFormat from, to;
	bool begin(const VoxelFormat &f, const VoxelFormat &t){
		from = f; to = t;
		return true;
	}
	void migrate(const VoxelVolume &old, VoxelVolume &moved){
		const pv::Vector3DInt32 lc = old.getEnclosingRegion().getLowerCorner();
		const pv::Vector3DInt32 uc = old.getEnclosingRegion().getUpperCorner();
		for(int32_t z = lc.getZ(); z <= uc.getZ(); z++)
		for(int32_t y = lc.getY(); y <= uc.getY(); y++)
		for(int32_t x = lc.getX(); x <= uc.getX(); x++){
			uint32_t w = moved.plane_at(0, x, y, z);
			to.id.set(w, from.id.get(old.plane_at(0, x, y, z)));
			moved.set_plane_at(0, x, y, z, w);
		}
	}
};

struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene = 0;
	storage::Save *m_save = nullptr;
	ss_ m_mode;
	VoxelFormat m_format;
	Widen m_widen;
	int m_ticks = 0;
	bool m_done = false;

	Module(interface::Server *server):
		interface::Module(MODULE),
		m_server(server)
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

	pv::Vector3DInt32 pos(int i, const pv::Region &r)
	{
		return r.getLowerCorner() + pv::Vector3DInt32(i % 16, (i / 16) % 16,
				i / 256);
	}

	void on_start()
	{
		const char *m = getenv("FORMAT_MIGRATION_MODE");
		m_mode = m ? m : "";
		m_format = format(m_mode == "write16" ? 16 : 20);
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
			if(m_mode != "noformat")
				reg->set_format(m_format);
			for(int i = 1; i <= N; i++){
				interface::VoxelDefinition def;
				def.name.block_name = "t"+itos(i);
				reg->add_voxel(def);
			}
			if(m_mode == "read20")
				world->set_migration(&m_widen);
			world->set_save(m_save, "main");
		});
	}

	void on_tick(const interface::TickEvent &event)
	{
		if(m_done)
			return;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivw){
			voxelworld::Instance *world = ivw->get_instance(m_scene);
			const pv::Vector3DInt16 s(0, 0, 0);
			const pv::Region r = world->get_section_region_voxels(s);
			if(m_mode == "write16"){
				world->set_section_generated(s);
				for(int i = 1; i <= N; i++){
					uint32_t w = 0;
					m_format.id.set(w, i);
					m_format.light_sky.set(w, i % 16);
					world->set_voxel(pos(i, r), VoxelInstance(w));
				}
				world->commit();
				world->save();
				log_i(MODULE, "fmt: write16: wrote %i", N);
				finish(0);
				return;
			}
			if(++m_ticks < 100 && !world->is_section_loaded(s))
				return;
			int intact = 0;
			for(int i = 1; i <= N; i++){
				VoxelInstance v = world->get_voxel(pos(i, r), true);
				if(m_format.id_of(v.data) == (interface::VoxelTypeId)i &&
						m_format.light_sky.get(v.data) == (uint32_t)(i % 16))
					intact++;
			}
			log_i(MODULE, "fmt: %s: %i of %i intact", cs(m_mode), intact, N);
			finish(0);
		});
	}

	void finish(int status)
	{
		m_done = true;
		m_server->shutdown(status, "format_migration_check");
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
# One server run of the app, its log in $CHECK_TMP/<mode>.log
run()
{
	FORMAT_MIGRATION_MODE=$1 timeout 120 bin/buildat_server -m "$app" \
		-P "$((29700 + RANDOM % 300))" > "$CHECK_TMP/$2.log" 2>&1
}
run write16 write16 || fail "write16 exited $? ($CHECK_TMP/write16.log)"
grep -aq "fmt: write16: wrote 1000" "$CHECK_TMP/write16.log" ||
	fail "write16 wrote nothing ($CHECK_TMP/write16.log)"
cp "$save/save.sqlite" "$CHECK_TMP/save16.sqlite"

run read20 read20 || fail "read20 exited $?"
grep -aq "fmt: read20: 1000 of 1000 intact" "$CHECK_TMP/read20.log" ||
	fail "with the migration: $(grep -a 'fmt: \| E ' "$CHECK_TMP/read20.log" | head -3)"
# Written back in the new format: no migration needed the third time
run read20_bare again || fail "the third open exited $?"
grep -aq "fmt: read20_bare: 1000 of 1000 intact" "$CHECK_TMP/again.log" ||
	fail "the third open: $(grep -a 'fmt: \| E ' "$CHECK_TMP/again.log" | head -3)"

# The 16-bit save again, with no migration: refused, and left as it was
cp "$CHECK_TMP/save16.sqlite" "$save/save.sqlite"
run read20_bare bare
grep -aq "id field is 16 bits in the save and 20 in this world" "$CHECK_TMP/bare.log" ||
	fail "no refusal without the migration: $(grep -a 'fmt: \| E ' "$CHECK_TMP/bare.log" | head -3)"
cmp -s "$save/save.sqlite" "$CHECK_TMP/save16.sqlite" ||
	fail "the refused save was written to"
# A fresh world that says nothing about its format
rm -rf "$save"
run noformat noformat && fail "a world with no format exited 0"
grep -aq "the voxel registry has no format: call set_format()" "$CHECK_TMP/noformat.log" ||
	fail "no format: $(grep -a ' E \|W __state' "$CHECK_TMP/noformat.log" | head -2)"
rm -rf "$app" "$save"
echo "PASS: id 16 to 20 bits: every id through the game's migration, written back, read again without it; refused without it, the save untouched; no format, no start"
# vim: set noet ts=4 sw=4:
