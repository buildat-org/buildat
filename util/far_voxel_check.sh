#!/bin/bash
# tier: full
# cost: ~40 s (2026-10-16)
# covers: builtin/voxelworld/voxelworld.cpp
# [SEC_RUN6_LEFTOVERS]: a voxel far past 32768 sections (int16 section
# coordinates) is read as undefined and written nowhere. Before, its
# section coordinate wrapped to another section's, voxelworld looked for
# the chunk there and threw "does not contain chunk" -- a client's dig at
# y 5e8 in skeldat did it. A module of this check's own, no client: one
# section at the origin, then a get and a set 65536 sections away on each
# axis, whose coordinates wrapped to the origin's section.
#   util/far_voxel_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp far_voxel; t=$CHECK_TMP
a=$t/far_voxel
mkdir -p "$a/main"
cat > "$a/main/meta.json" <<'J'
{"engine_api": 2, "kind": "check", "dependencies": [
	{"module": "main_context"}, {"module": "voxelworld"}]}
J
cat > "$a/main/main.cpp" <<'C'
#include "core/log.h"
#include "main_context/api.h"
#include "voxelworld/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include <Scene.h>
#define MODULE "main"
namespace pv = PolyVox;
using interface::Event;
namespace main {
struct Module: public interface::Module
{
	interface::Server *m_server;
	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server){}
	void init(){ m_server->sub_event(this, Event::t("core:start")); }
	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
	}
	void on_start()
	{
		main_context::SceneReference scene = nullptr;
		main_context::access(m_server, [&](main_context::Interface *i){
			scene = i->create_scene();
		});
		voxelworld::access(m_server, [&](voxelworld::Interface *i){
			i->create_instance(scene, pv::Region(0, 0, 0, 0, 0, 0));
		});
		int undefined = 0, threw = 0;
		voxelworld::access(m_server, scene, [&](voxelworld::Instance *w){
			w->load_section_no_generate(pv::Vector3DInt16(0, 0, 0));
			// 65536 sections of 32 voxels on: the int16 wrapped to 0, the
			// section that is there
			const int W = 65536 * 32;
			for(const pv::Vector3DInt32 &p : {pv::Vector3DInt32(0, W * 16, 0),
					pv::Vector3DInt32(0, -W * 16, 0),
					pv::Vector3DInt32(W * 100, 0, 0)}){
				try {
					w->set_voxel(p, interface::VoxelInstance(2), true);
					if(w->get_voxel(p, true).data ==
							interface::VOXELTYPEID_UNDEFINED)
						undefined++;
				} catch(std::exception &e){
					log_w(MODULE, "far_voxel: threw: %s", e.what());
					threw++;
				}
			}
		});
		log_w(MODULE, "far_voxel: 3 far, %i undefined, %i threw",
				undefined, threw);
		m_server->shutdown(0, "far_voxel: done");
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
C
cd "$here/Build"
timeout 300 bin/buildat_server -m "$a" -D "$t/u" -C "$t/c" -P $((29700 + RANDOM % 200)) -l 3 \
	> "$t/s.log" 2>&1
grep -a "far_voxel:" "$t/s.log" | sed 's/.*far_voxel: /  /'
grep -aq "far_voxel: 3 far, 3 undefined, 0 threw" "$t/s.log" ||
	fail "a far voxel ($t/s.log)"
echo "PASS: voxels past the int16 sections read as undefined and are written nowhere"
# vim: set noet ts=4 sw=4:
