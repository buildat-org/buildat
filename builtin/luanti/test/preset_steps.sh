#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 7 min (two runs of three minutes, 2026-10-09)
# covers: apps/vanilla/main/main.cpp builtin/luanti/lua/entity.lua
# [SERVER_PRESETS]: the server's step times under the "VPS / Raspberry Pi"
# preset against "Desktop". A fresh VoxeLibre world of a fixed seed, three
# clients, and the fixture moving each player 160 nodes further out every
# 8 s, each in its own direction, so the mapgen and the sends never rest.
# The server is held to two cores (taskset), a small VPS's share; the
# clients have the rest. What it prints per preset: the steps, how many
# went over the 90 ms slot, their median, 95th percentile and worst, and
# the worst work between steps (a section's on_generated) by phase.
#
# Both worlds are the launcher's kind (-u launcher=1), whose clients join
# without accounts; the VPS one has its preset written in its world.mt
# before it starts, which is what the form writes.
#
#   SECONDS_EACH=180 builtin/luanti/test/preset_steps.sh
set -u
. "$(dirname "$0")/../../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
out="$here/local/preset_steps"; mkdir -p "$out"
SECONDS_EACH="${SECONDS_EACH:-180}"
cd "$here/Build"
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "a buildat server or client is already running" >&2; exit 2
fi
{ echo "local SECONDS_EACH = $SECONDS_EACH"; cat <<'LUA'
core.settings:set("fixed_map_seed", "5")
local dirs = {{1, 0}, {-1, 0}, {0, 1}}
local players, leg = {}, 0
core.register_on_joinplayer(function(player)
	players[#players + 1] = player:get_player_name()
	core.log("action", "preset_steps: joined " .. #players)
end)
local function move()
	leg = leg + 1
	for i, name in ipairs(players) do
		local p = core.get_player_by_name(name)
		local d = dirs[i] or {1, 1}
		if p then
			p:set_pos({x = d[1] * 160 * leg, y = 40, z = d[2] * 160 * leg})
		end
	end
	core.after(8, move)
end
-- Every step's own time and the worst work between steps, said once a
-- second (an interrupted server runs no on_shutdown)
local steps, since, measured = {}, 0, 0
core.register_globalstep(function(dtime)
	local _, _, latest = core.get_server_step_peak()
	if #players >= 3 then
		steps[#steps + 1] = string.format("%.4f", latest)
		-- The shell ends the run on this line
		measured = measured + dtime
		if measured >= SECONDS_EACH and measured - dtime < SECONDS_EACH then
			core.log("action", "preset_steps: done")
		end
	end
	since = since + dtime
	if since >= 1 then
		since = 0
		local s, phase = core.get_server_step_worst()
		if #players >= 3 then
			core.log("action", string.format("preset_steps: worst %.3f %s",
					s, phase))
			core.log("action", "preset_steps: steps " ..
					table.concat(steps, " "))
		end
		steps = {}
	end
end)
local started = false
core.register_on_joinplayer(function()
	if not started and #players >= 3 then
		started = true
		core.after(2, move)
	end
end)
LUA
} > "$out/fixture.lua"

# Waits for a line in a log, up to some seconds, while the server lives
wait_line() { # log text seconds srv
	local i
	for ((i = 0; i < $3 * 5; i++)); do
		grep -aq "$2" "$1" && return 0
		kill -0 "$4" 2>/dev/null || return 1
		sleep 0.2
	done
	return 1
}

run() { # tag preset-line-or-empty
	local tag=$1 save=buildat_test_preset_steps_$1 port=29791
	local d="$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
	rm -rf "$d"
	if [ -n "$2" ]; then
		mkdir -p "$d/luanti"
		printf '%s\n' "$2" > "$d/luanti/world.mt"
	fi
	BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$out/fixture.lua" \
		start_server "$out/srv_$tag.log" "Mods loaded" 400 $port \
		taskset -c 0,1 bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
		{ echo "FAIL: the server did not start"; exit 1; }
	local srv=$SERVER_PID
	local cl=() n ok=1
	for n in 1 2 3; do
		# The clients run until the measuring ends; timeout is their cap
		taskset -c 2-$(( $(nproc) - 1 )) timeout $((SECONDS_EACH + 300)) \
			bin/buildat -s localhost:$port -w 320x240 -l 3 \
			-o sound_mute=1 -o default_username=ps$n \
			> "$out/cli_${tag}_$n.log" 2>&1 &
		cl+=($!)
		# One join at a time, as before
		wait_line "$out/srv_$tag.log" "preset_steps: joined $n" 120 $srv ||
			{ echo "FAIL $tag: client $n did not join ($out/cli_${tag}_$n.log)"; ok=; break; }
	done
	[ -n "$ok" ] && { wait_line "$out/srv_$tag.log" "preset_steps: done" \
			$((SECONDS_EACH + 120)) $srv ||
		{ echo "FAIL $tag: the measuring did not end ($out/srv_$tag.log)"; ok=; }; }
	kill "${cl[@]}" 2>/dev/null
	for p in "${cl[@]}"; do wait "$p"; done
	kill -INT "$srv" 2>/dev/null
	for _i in $(seq 1 300); do kill -0 "$srv" 2>/dev/null || break; sleep 0.2; done
	[ -n "$ok" ] || return 1
	grep -a "^buildat_preset\|^max_block" "$d/luanti/world.mt" | tr '\n' ' '; echo
	python3 - "$out/srv_$tag.log" "$tag" <<'PY'
import sys, re
log = open(sys.argv[1], errors="replace").read()
m = " ".join(re.findall(r"preset_steps: steps ([\d. ]*)", log)).split()
worst = re.findall(r"preset_steps: worst ([\d.]+) (\S*)", log)
joined = max([int(j) for j in re.findall(r"preset_steps: joined (\d+)", log)] or [0])
if not m:
	print("FAIL %s: no steps recorded (%d joined)" % (sys.argv[2], joined))
	sys.exit(1)
s = sorted(float(v) for v in m)
over = sum(1 for v in s if v > 0.09)
by = {}
for v, ph in worst:
	v = float(v)
	if v > 0.09:
		by[ph] = by.get(ph, 0) + 1
print("%s: %d steps, %d over 90 ms (%.1f%%), median %.0f ms, p95 %.0f ms, "
		"worst %.0f ms; seconds with work over the slot by phase: %s" % (
		sys.argv[2], len(s), over, 100.0 * over / len(s),
		1000 * s[len(s) // 2], 1000 * s[int(len(s) * 0.95)], 1000 * s[-1],
		", ".join("%s %d" % kv for kv in sorted(by.items(),
				key=lambda kv: -kv[1])) or "none"))
PY
}
run vps "$(printf '%s\n' "buildat_preset = VPS / Raspberry Pi" \
	"max_block_send_distance = 4" "max_block_generate_distance = 4" \
	"active_object_send_range_blocks = 4" "liquid_loop_max = 5000" \
	"item_entity_ttl = 300")" || exit 1
run desktop "" || exit 1
echo "PASS: both presets' step times are above"
