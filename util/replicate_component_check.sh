#!/bin/bash
# tier: full
# cost: ~40 s (2026-10-12)
# covers: src/client/state.cpp builtin/replicate/replicate.cpp
# [COMPAT_BREAK_07] 8e: a component added to a node the client already has
# (replicate:create_component) and a change to its attributes after
# (replicate:component_delta_update) reach the client. An app adds a Light
# of brightness 2 to a node once the client has it, then makes it 5.
#   util/replicate_component_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || { echo "SKIP: no display"; exit 0; }
check_tmp replicate_component; t=$CHECK_TMP
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
			Node *n = imc->check_scene(m_scene)->GetChild("Lamp");
			if(before < 3 && m_since >= 3)
				n->CreateComponent<Light>()->SetBrightness(2);
			if(before < 6 && m_since >= 6)
				n->GetComponent<Light>()->SetBrightness(5);
		});
	}
};
extern "C" {
	BUILDAT_EXPORT void* createModule_main(interface::Server *server){
		return (void*)(new Module(server));
	}
}
EOF
cat > "$a/client_lua/init.lua" <<'EOF'
local magic = require("buildat/extension/urho3d")
local replicate = require("buildat/extension/replicate")
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
printf 'delay 12000\nquit\n' > "$t/seq"
timeout 60 bin/buildat -o launch_ui=launch_menu -s 127.0.0.1:$SERVER_PORT \
	-D "$t/cl" -w 640x480 -l 3 -o sound_mute=1 -c @"$t/seq" > "$t/cl.log" 2>&1
grep -q "LAMP brightness 2" "$t/cl.log" ||
	fail "the added Light did not reach the client ($t/cl.log)"
grep -q "LAMP brightness 5" "$t/cl.log" ||
	fail "the Light's change did not reach the client ($t/cl.log)"
echo "PASS: a component added to a node the client has, and its change after, replicated"
