#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: <1 s (2026-11-20)
# covers: builtin/kit/types/arena.lua
# [KIT_API_1] (decision 7) kit/arena's time_up "most" with no teams,
# offline: the round's tick at its timer's end on a stand-in c, two players
# with kit/score points. A tie goes to overtime; once the points differ the
# player with the most wins, the result's scores the players'.
#   util/kit_arena_most_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for lua in luajit lua5.1; do
	command -v $lua >/dev/null && break
done
command -v $lua >/dev/null || skip "no luajit or lua5.1"
cd "$here" && $lua - <<'EOF' || fail "kit/arena's time_up \"most\" with no teams"
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
EOF
echo "PASS: kit/arena's time_up \"most\" with no teams"
# vim: set noet ts=4 sw=4:
