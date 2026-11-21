#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: <1 s (2026-11-20)
# covers: builtin/kit/types/arena.lua
# [KIT_API_1] (decision 7) kit/arena's time_up "most" with no teams,
# offline: the round's tick at its timer's end on a stand-in c, two players
# with kit/score points. A tie goes to overtime; once the points differ the
# player with the most wins, the result's scores the players'.
# [KIT_ARENA_STATUS_LINE] A teams round under each status_line: the HUD's
# line ("full" with " (to 3)", "none" none, "scores" its result at the
# end), the lobby's none under "none", output `status` the full line.
#   util/kit_arena_most_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for lua in luajit lua5.1; do
	command -v $lua >/dev/null && break
done
command -v $lua >/dev/null || skip "no luajit or lua5.1"
cd "$here" && $lua - <<'EOF' || fail "kit/arena's time_up \"most\" with no teams, status_line"
local arena = dofile("builtin/kit/types/arena.lua")
local function player(id, name, score)
	return {id = id, name = name, state = {["kit/score"] = {score = score}}}
end
local ended
local c = {id = 5, session = 1, params = {duration = 60, time_up = "most",
		score_to_win = 0, results = 0},
	state = {result = "", left = 1, overtime = false, assigned = {}},
	players = {player(20, "ann", 2), player(21, "bob", 2)}}
function c:after() end
function c:emit() end
function c:log(...) print("  " .. table.concat({...}, " ")) end
function c:name(id) return tostring(id) end
function c:session_end(id, outcome) ended = outcome end
arena.on_timer(c, "tick")
assert(c.state.overtime and c.state.result == "" and not ended,
	"a tie: overtime, not " .. c.state.result)
c.players[2].state["kit/score"].score = 3
arena.on_timer(c, "tick")
assert(c.state.result == "bob wins!", c.state.result)
assert(ended and ended.winner == "bob" and ended.scores.ann == 2 and
	ended.scores.bob == 3, "the outcome")
print("ok: no teams: a tie overtime, then the player with the most points wins")

-- [KIT_ARENA_STATUS_LINE] the HUD's line (value, own, shown) by
-- status_line, output `status` the full line under each
local function round(how)
	local r = {id = 5, session = 1, session_maker = 5,
		params = {duration = 83, score_to_win = 3, results = 5,
			time_up = "draw", status_line = how},
		state = {result = "", ended = "", left = 0, overtime = false,
			status = "waiting", assigned = {["player:20"] = 6}},
		teams = {{id = 6, params = {name = "Red"}, state = {score = 1}},
			{id = 7, params = {name = "Blue"}, state = {score = 2}}},
		players = {player(20, "ann", 0)}, sent = {}}
	function r:after() end
	function r:emit(o, v) if o == "status" then self.sent[#self.sent + 1] = v end end
	function r:log() end
	function r:name(id) return tostring(id) end
	arena.on_start(r)
	return r
end
local full = "1:23 left|Red 1 : Blue 2 (to 3)"
local function hud(how, want, shown)
	local r = round(how)
	assert(r.state.value == want and r.state.shown == shown,
		how .. ": " .. tostring(r.state.value) .. " shown " .. tostring(r.state.shown))
	local own = r.state.own["player:20"]
	assert(shown and own.value == "Team Red|" .. want or not shown and not own,
		how .. ": own " .. tostring(own and own.value))
	assert(r.sent[1] == full and r.state.status == full,
		how .. ": the output " .. tostring(r.sent[1]))
	return r
end
hud("full", full, true)
hud("time_scores", "1:23 left|Red 1 : Blue 2", true)
hud("time", "1:23 left", true)
hud("none", "", false)
local r = hud("scores", "Red 1 : Blue 2", true)
r.teams[2].state.score = 3
arena.on_timer(r, "tick")
local over = "Blue wins!|Round ended by arena 5: score to win (3)|Red 1 : Blue 3"
assert(r.state.value == over, "scores at the end: " .. r.state.value)
assert(r.sent[2] == over .. " (to 3)", "the output at the end: " .. tostring(r.sent[2]))
local l = {id = 5, session = 0, params = {status_line = "none", maps = "",
		map_pick = "round_robin", players = 2, max_players = 8, ready = 0},
	state = {queue = {20}, rounds = {}, count = 0, last = "", map_at = 1}}
function l:log() end
arena.on_start(l)
assert(l.state.shown == false and l.state.status:find("Waiting for players"),
	"none in the lobby: " .. tostring(l.state.shown))
print("ok: status_line full, time_scores, time, scores (its result) and none (the lobby's too); the output the full line")
-- [KIT_MAP_ROTATION] Before the first round the lobby's next_map (whose
-- teams Kit gives it) is the rotation's first scene
l.params.maps, l.scenes = "nowhere, map", {"map"}
arena.on_start(l)
assert(l.state.next_map == "map", "next_map in the lobby: " .. l.state.next_map)
print("ok: the lobby's next_map the first of maps")
EOF
echo "PASS: kit/arena's time_up \"most\" with no teams, and its status_line"
# vim: set noet ts=4 sw=4:
