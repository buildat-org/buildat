#!/bin/bash
# tier: full
# cost: ~30 s (2026-10-28)
# covers: builtin/replicate/replicate.cpp builtin/main_context/main_context.cpp
# [SERVER_REPLICATE_DEPTH]: a server module makes a 100000-node chain in
# its replicated scene with a client attached, then a Light of brightness
# 7 on another node. The server lives, the client gets the Light, and
# the server shuts down without a crash.
#   util/replicate_depth_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp replicate_depth; t=$CHECK_TMP
cd "$here/Build"
a=$t/app/main
mkdir -p "$a/client_lua"
cat > "$a/meta.json" <<'EOF'
{"engine_api": 2, "client_main": "init.lua", "dependencies": [
	{"module": "network"}, {"module": "client_lua"}, {"module": "client_data"},
	{"module": "main_context"}, {"module": "replicate"}]}
EOF
cat > "$a/main.cpp" <<'EOF'
#include "core/log.h"
#include "client_file/api.h"
#include "replicate/api.h"
#include "main_context/api.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/os.h"
#include <Scene.h>
#include <Light.h>
#define MODULE "main"
using namespace Urho3D;
using interface::Event;
struct Module: public interface::Module
{
	interface::Server *m_server;
	main_context::SceneReference m_scene;
	float m_since = -1;
	Module(interface::Server *server):
		interface::Module(MODULE), m_server(server){}
	void init()
	{
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:tick"));
		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}
	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
		EVENT_TYPEN("client_file:files_transmitted", on_files,
				client_file::FilesTransmitted)
	}
	void on_start()
	{
		main_context::access(m_server, [&](main_context::Interface *imc){
			m_scene = imc->create_scene();
			imc->check_scene(m_scene)->CreateChild("Lamp");
		});
	}
	void on_files(const client_file::FilesTransmitted &e)
	{
		replicate::access(m_server, [&](replicate::Interface *ir){
			ir->assign_scene_to_peer(m_scene, e.recipient);
		});
		m_since = 0;
	}
	void on_tick(const interface::TickEvent &e)
	{
		if(m_since < 0)
			return;
		const float before = m_since;
		m_since += e.dtime;
		main_context::access(m_server, [&](main_context::Interface *imc){
			Scene *scene = imc->check_scene(m_scene);
			if(before < 1 && m_since >= 1){
				const int64_t t0 = interface::os::time_us();
				// The first node made the deepest: replicate takes dirty
				// nodes in the order they were made, so it meets the chain
				// at its bottom and walks up to the top. (Made top down
				// the chain goes top first and nothing recurses, and every
				// CreateChild walks up the whole chain.)
				Node *n = scene->CreateChild("Chain");
				for(int i = 1; i < CHAIN_N; i++){
					Node *up = scene->CreateChild("Chain");
					up->AddChild(n);
					n = up;
				}
				log_i(MODULE, "CHAIN built: %i nodes in %.1f s", CHAIN_N,
						(interface::os::time_us() - t0) / 1e6);
			}
			if(before < 2 && m_since >= 2)
				scene->GetChild("Lamp")->CreateComponent<Light>()->
						SetBrightness(7);
		});
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
EOF
sed -i "s/CHAIN_N/${CHAIN_N:-100000}/g" "$a/main.cpp"
cat > "$a/client_lua/init.lua" <<'EOF'
local magic = require("buildat/core/urho3d")
local replicate = require("buildat/core/replicate")
local log = buildat.Logger("check")
local seen
magic.SubscribeToEvent("Update", function()
	local n = replicate.main_scene:GetChild("Lamp")
	local l = n and n:GetComponent("Light")
	if l and l.brightness ~= seen then
		seen = l.brightness
		log:info("LAMP brightness "..seen)
	end
end)
EOF
start_server "$t/srv.log" "STATUS Listening" 120 auto \
	bin/buildat_server -m "$t/app" -D "$t/srv" -l 3 ||
	fail "the server did not listen ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
printf 'wait_log_any 60000 LAMP brightness 7\nquit\n' > "$t/seq"
timeout 90 bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$SERVER_PORT \
	-D "$t/cl" -w 640x480 -l 3 -o sound_mute=1 -c @"$t/seq" > "$t/cl.log" 2>&1
rc=$?
grep -aq "CHAIN built" "$t/srv.log" || fail "the chain was not built ($t/srv.log)"
kill -0 $SERVER_PID 2>/dev/null ||
	fail "the server died with the chain in its scene ($t/srv.log)"
grep -av "command: \\|wait_log" "$t/cl.log" | grep -q "LAMP brightness 7" ||
	fail "the Light did not reach the client past the chain ($t/cl.log)"
[ $rc = 0 ] || fail "the drive ($t/cl.log)"
# Dropping the scene at shutdown recursed in Urho3D once per level too
kill $SERVER_PID
for i in $(seq 150); do kill -0 $SERVER_PID 2>/dev/null || break; sleep 0.2; done
wait $SERVER_PID; src=$?
[ $src -lt 128 ] || fail "the server exited by signal $((src - 128)) at shutdown ($t/srv.log)"
echo "PASS: a 100000-node chain in a server module's replicated scene; the server synced it and shut down"
