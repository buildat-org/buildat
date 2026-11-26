#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~2 min (2026-11-24)
# covers: apps/workbench/templates/deepcore/** builtin/kit/types/unit.lua builtin/kit/types/unit_walker.lua
# [KIT_RTS] (kit_plan 4z37zzo) Deepcore's economy and computer player over
# 10 minutes of a match's time: the template made into a project with a
# check type of its own (the watcher), a match against the computer
# started (BUILDAT_WORKBENCH_PLAY), one headless server at --sim-rate 0
# (the game's clock as fast as it goes). Blue has no player: a second
# computer plays it from t=30 (after the watcher's dig), one that builds
# and defends but never attacks. The watcher logs the clock, each side's
# money, Blue's buildings' health and Red's tanks near Blue's HQ every 5 s,
# the map's cells (y 6-17) every 60 s, and orders Blue's digger into the
# rock as a player's order goes (c:order). Then:
#   - no rts type ran past its budget or erred;
#   - Blue's digger dug to its point in the rock;
#   - from minute 3 on, each side's harvesters unloaded in every minute
#     (until it lost a building: the war, not the ore), and each
#     harvester that lived 120 s (a bought one too) unloaded;
#   - no harvester stayed idle ("no reachable ore") while the map showed
#     ore it reaches (this check's own flood: the cells a unit stands in
#     from its refinery, a step up one, a drop of three; buildings' feet
#     left out);
#   - the computer sent an attack, and its tanks reached Blue's base or
#     hurt it, before minute 6;
#   - [KIT_RTS_PLAYTEST_1] (7) a Blue harvester mined down (the watcher's
#     3 x 2 x 3 of ore in the base's floor; Blue's harvesters' down_cost 0,
#     so it is the nearest), stood a level or two under the floor and came
#     back up with its load (unloaded), and every stand there in the last
#     map reaches back to the refinery (this check's flood both ways: a
#     staircase, no pit); (5), (6) the harvesting and digging effects made.
# A minute-by-minute account of the match is printed.
#   util/kit_rts_econ_check.sh            (KEEP_TMP=1: the server's log kept)
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp kit_rts_econ; t=$CHECK_TMP
cd "$here/Build"
check_build
g=$t/game u=$t/user
mkdir -p "$u/shared"
cp -r "$here/apps/workbench/templates/deepcore" "$g"
cat > "$g/types/rts_watch.lua" <<'EOF'
-- A check's: the match watched (see util/kit_rts_econ_check.sh)
local CH = {["air"] = ".", ["kit/ore"] = "o", ["kit/hard_rock"] = "H", [""] = "?"}
return {
	version = 1,
	about = {what = "A check's: Deepcore's match watched."},
	no_position = true,
	reads_units = true,
	reads_teams = true,
	world_voxels = true,
	params = {dig_to = {type = "position", default = {-27, 7, 10}},
		blue_ai = {type = "entity", default = 899}},
	state = {y = {default = 4}, pass = {default = 0}},
	on_start = function(c)
		c:after(5, "dig")
		c:after(1, "look")
		c:after(1, "floor")
		c:after(30, "map")
		c:after(30, "blue")
	end,
	on_timer = function(c, name)
		if name == "floor" then
			-- (7) ore in the floor between Blue's HQ and its east wall, two
			-- deep (after the base's region is written)
			local v = {}
			for x = -30, -28 do
				for z = -5, -3 do
					for y = 5, 6 do
						v[#v + 1] = {x, y, z, "kit/ore"}
					end
				end
			end
			c:set_voxels_at(v)
			c:log("watch: floor ore " .. #v)
		elseif name == "blue" then
			c:send(c.params.blue_ai, "start")
			c:log("watch: Blue's computer started")
		elseif name == "dig" then
			for _, u in ipairs(c.units or {}) do
				if u.team == "Blue" and u.name == "digger" then
					local g = c.params.dig_to
					c:order({u.id}, {at = {g[1], g[2] - 0.5, g[3]}, center = {g[1], g[2] - 0.5, g[3]}})
					c:log(string.format("watch: Blue's digger %d ordered to %d,%d,%d", u.id, g[1], g[2], g[3]))
				end
			end
		elseif name == "look" then
			c:after(5, "look")
			local money, hq, hp, near = {}, nil, 1, 0
			for _, t in ipairs(c.teams or {}) do
				money[t.params.name] = math.floor(t.state.score or 0)
			end
			for _, u in ipairs(c.units or {}) do
				if u.team == "Blue" and u.name == "hq" then
					hq = u
				end
			end
			for _, u in ipairs(c.units or {}) do
				if u.team == "Blue" and (u.name == "hq" or u.name == "refinery" or u.name == "factory") then
					hp = math.min(hp, u.health or 1)
				end
				if hq and u.team == "Red" and u.name == "tank" and
						(u.pos[1] - hq.pos[1]) ^ 2 + (u.pos[3] - hq.pos[3]) ^ 2 < 14 ^ 2 then
					near = near + 1
				end
			end
			c:log(string.format("watch t=%.0f blue=%d red=%d blue_hp=%.2f near=%d",
				c.now, money.Blue or -1, money.Red or -1, hp, near))
		elseif name == "map" then
			c.state.y = 4
			c.state.pass = c.state.pass + 1
			c:after(60, "map")
			c:after(0.1, "dump")
			c:log(string.format("watch: map %d at t=%.0f", c.state.pass, c.now))
		elseif name == "dump" then
			local y = c.state.y
			c.state.y = y + 1
			for _, part in ipairs({{-32, 42}, {10, 22}}) do
				local v = c:voxels_at({-48, y, part[1]}, {96, 1, part[2]})
				for z = 0, part[2] - 1 do
					local r = {}
					for x = 0, 95 do
						local n = v[1 + x + 96 * z] or ""
						r[#r + 1] = CH[n] or "#"
					end
					c:log(string.format("MAP%d y%d z%d %s", c.state.pass, y, part[1] + z, table.concat(r)))
				end
			end
			if c.state.y <= 17 then
				c:after(0.1, "dump")
			end
		end
	end,
}
EOF
python3 -I - "$g/composition.json" "$g/prefabs.json" <<'PY' || fail "the watcher not added"
import json, sys
p = sys.argv[1]
j = json.load(open(p))
j["entities"].append({"id": 900, "parent": 2, "name": "the watcher",
	"components": [{"type": "local/rts_watch", "version": 1, "params": {}}]})
# (Blue played by a computer too, started by the watcher once its digger
# has dug: both sides' economies over the whole match; one that never
# attacks, a player at home: Red's attack is what comes to its base)
j["entities"].append({"id": 899, "parent": 2, "name": "Blue's computer",
	"components": [{"type": "local/rts_ai", "version": 1, "params": {"match": 10,
		"team": "Blue", "enemy": "Red", "base": [-35, 6.5, -5], "enemy_base": [34, 6.5, 4],
		"route": "-30 7 -2, -22 7 0, -10 7 0, 2 7 -1, 14 7 -1, 26 7 -1, 34 7 4",
		"map_x": 44, "map_z": 28, "first_wave": 3600, "aggression": 0, "defence": 30}}]})
j["next_id"] = max(j["next_id"], 901)
json.dump(j, open(p, "w"), indent="\t")
# (7) Blue's harvesters take ore in the floor as near as level ore: the
# watcher's floor ore first
p = sys.argv[2]
j = json.load(open(p))
for c in j["deepcore/harvester_blue"]["entities"][0]["components"]:
	if c["type"] == "local/rts_harvester":
		c.setdefault("params", {})["down_cost"] = 0
json.dump(j, open(p, "w"), indent="\t")
PY
(cd "$g" && zip -qrX "$u/shared/game.zip" .) || fail "not zipped"
SL=$t/srv.log
BUILDAT_WORKBENCH_PROJECT=g BUILDAT_WORKBENCH_FROM=$u/shared/game.zip \
	BUILDAT_WORKBENCH_PLAY="10 vs_computer" \
	start_server "$SL" "Hosted: |Not hosted: |Shutdown: " 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$u" -l 3 --sim-rate 0 ||
	fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
grep -aq "Hosted: " "$SL" || fail "not hosted ($SL)"
wait_for_log "$SL" "match started: computer" 30 "$u" || fail "no match ($SL)"
# 10 minutes of the match, or its end (the clock's seconds, not the wall's)
wait_for_log "$SL" "watch t=6[0-9][0-9] |match over: " 640 "$u" ||
	fail "the match did not reach 10 minutes ($SL)"
kill -INT "$SERVER_PID" 2>/dev/null
wait "$SERVER_PID" 2>/dev/null
python3 -I - "$SL" <<'PY'
import re, sys
from collections import deque
lines = open(sys.argv[1], "rb").read().decode(errors="replace").splitlines()
bad = []
# Each line's game time: the last watcher's line before it
t, now = [], 0.0
team, refinery, hurt_at, near_at, over, sent_at = {}, {}, None, None, None, None
for l in lines:
	if sent_at is None and re.search(r"local/rts_ai 11: (sends \d+ attackers|attacks )", l):
		sent_at = now
	m = re.search(r"watch t=(\d+) blue=(-?\d+) red=(-?\d+) blue_hp=([\d.]+) near=(\d+)", l)
	if m:
		now = float(m.group(1))
		if float(m.group(4)) < 1 and hurt_at is None:
			hurt_at = now
		# (reached: after an attack was sent; a defender chasing a
		# harvester home is none, a scout one)
		if int(m.group(5)) > 1 and near_at is None and sent_at is not None:
			near_at = now
	t.append(now)
	m = re.search(r"made (Blue|Red) (\w+) (\d+) at (\S+)", l)
	if m:
		team[m.group(3)] = m.group(1)
		if m.group(2) == "refinery":
			refinery.setdefault(m.group(1), [float(v) for v in m.group(4).split(",")])
	if "match over: " in l and over is None:
		over = now
	if re.search(r"local/rts_\w+.* ran past its budget|Entity \d+'s local/rts_\w+, \w+: ", l):
		bad.append("an rts type failed: " + l[-200:])
end = over if over is not None else now
print("the match ran to t=%.0f%s" % (end, " (over: %s)" % [l for l in lines if "match over" in l][0].split(": ")[-1] if over is not None else ""))
# The digger ordered into the rock
dig = [l for l in lines if "watch: Blue's digger" in l]
if not dig:
	bad.append("Blue's digger was not ordered")
else:
	d, x, y, z = re.search(r"digger (\d+) ordered to (-?\d+),(-?\d+),(-?\d+)", dig[0]).groups()
	got = [i for i, l in enumerate(lines) if "local/rts_digger %s: dug to %s,%s,%s" % (d, x, y, z) in l]
	if not got:
		why = [l.split(": ", 2)[-1] for l in lines if "local/rts_digger %s:" % d in l][-3:]
		bad.append("Blue's digger did not dig to %s,%s,%s: %s" % (x, y, z, why))
	else:
		print("ok: Blue's digger, ordered into the rock, dug to %s,%s,%s by t=%.0f (%d cells dug)" % (x, y, z, t[got[0]],
			sum(int(n) for n in re.findall(r"rts_digger %s: dug (\d+) cells" % d, "\n".join(lines[:got[0] + 1])))))
# Unloads per side and minute
unl = {"Blue": [], "Red": []}
for i, l in enumerate(lines):
	m = re.search(r"local/rts_harvester (\d+): unloaded (\d+) at (\d+)", l)
	if m and m.group(1) in team:
		unl[team[m.group(1)]].append(t[i])
attack = min(v for v in (hurt_at, near_at, 1e9) if v is not None)
# (a side's checked until it loses a building: the war, not the ore)
built = {}
for l in lines:
	m = re.search(r"made (Blue|Red) (hq|refinery|factory) (\d+) at ", l)
	if m:
		built[m.group(3)] = m.group(1)
broke = {"Blue": 1e9, "Red": 1e9}
for i, l in enumerate(lines):
	m = re.search(r"local/rts_unit (\d+): destroyed", l)
	if m and m.group(1) in built:
		broke[built[m.group(1)]] = min(broke[built[m.group(1)]], t[i])
for side, until in (("Blue", min(end, 600, broke["Blue"])), ("Red", min(end, 600, broke["Red"]))):
	w = 180
	while w + 60 <= until:
		if not [x for x in unl[side] if w <= x < w + 60]:
			bad.append("%s unloaded nothing from t=%d to %d" % (side, w, w + 60))
		w += 60
	print("%s's unloads: %d, by minute %s (checked from 3 to %.1f)" % (side, len(unl[side]),
		[len([x for x in unl[side] if m * 60 <= x < m * 60 + 60]) for m in range(int(end // 60) + 1)], until / 60))
# Each harvester (a bought one too: ordered out of its factory's door) that
# lived 120 s unloaded
for i, l in enumerate(lines):
	m = re.search(r"made (Blue|Red) harvester (\d+) at ", l)
	if not m:
		continue
	h = m.group(2)
	gone = [t[j] for j in range(i, len(lines)) if "local/rts_unit %s: destroyed" % h in lines[j]]
	life = (gone[0] if gone else end) - t[i]
	n = len([1 for x in lines[i:] if "local/rts_harvester %s: unloaded" % h in x])
	print("%s's harvester %s (made at t=%.0f): %d unloads" % (m.group(1), h, t[i], n))
	if life >= 120 and n == 0:
		bad.append("%s's harvester %s unloaded nothing in its %.0f s" % (m.group(1), h, life))
# A harvester with no ore 20 s: its match saw it idle (its player told)
for i, l in enumerate(lines):
	m = re.search(r"local/rts_harvester (\d+): no reachable ore", l)
	if not m or m.group(1) not in team:
		continue
	h, side = m.group(1), team[m.group(1)]
	later = [j for j in range(i + 1, len(lines)) if t[j] <= t[i] + 25]
	if [j for j in later if t[j] <= t[i] + 20 and re.search(r"rts_harvester %s: (ore again|unloaded)|rts_unit %s: destroyed" % (h, h), lines[j])]:
		continue
	if not [j for j in later if "%s's harvester idle" % side in lines[j]] and t[i] + 25 < end and \
			not [j for j in range(i) if t[j] >= t[i] - 20 and "%s's harvester idle" % side in lines[j]]:
		bad.append("%s's harvester %s had no ore from t=%.0f and its match did not tell" % (side, h, t[i]))
print("idle harvesters told: %s" % [l.split(": ")[-1] for l in lines if "harvester idle (" in l])
# The attack
sent = [t[i] for i, l in enumerate(lines) if re.search(r"local/rts_ai 11: (sends \d+ attackers|attacks )", l)]
if not sent:
	bad.append("the computer sent no attack")
# Usually 240-280; a wave first turned on Blue's scout reached at 361 once
if attack > 480:
	bad.append("the computer's tanks neither reached nor hurt Blue's base by t=480 (reached %s, hurt %s)" % (near_at, hurt_at))
else:
	print("ok: the computer's first attack sent at t=%.0f, its tanks at Blue's base at t=%s, Blue hurt at t=%s" % (sent[0], near_at, hurt_at))
# Idle harvesters against the map's reachable ore: each map (its time), the
# cells a unit stands in from the side's refinery, ore beside them
maps = {}
cur = None
for i, l in enumerate(lines):
	m = re.search(r"watch: map (\d+) at t=(\d+)", l)
	if m:
		maps[m.group(1)] = {"t": float(m.group(2)), "g": {}}
	m = re.search(r"MAP(\d+) y(\d+) z(-?\d+) (\S+)", l)
	if m and m.group(1) in maps:
		y, z = int(m.group(2)), int(m.group(3))
		for x, ch in enumerate(m.group(4)):
			maps[m.group(1)]["g"][(x - 48, y, z)] = ch
feet = []
for l in lines:
	m = re.search(r"made \w+ (hq|refinery|factory) \d+ at (\S+)", l)
	if m:
		p = [float(v) for v in m.group(2).split(",")]
		feet.append((round(p[0]), round(p[2])))
def reach(g, start, feet):
	def kind(c):
		return g.get(c, "#")
	def stands(c):
		x, y, z = c
		if kind(c) != "." or kind((x, y - 1, z)) == ".":
			return False
		return not any(abs(x - fx) <= 2 and abs(z - fz) <= 2 for fx, fz in feet)
	seen, q, ore = {start}, deque([start]), set()
	while q:
		x, y, z = q.popleft()
		for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
			n = (x + dx, y, z + dz)
			for dy in (0, 1):
				if kind((n[0], y + dy, n[2])) == "o":
					ore.add((n[0], y + dy, n[2]))
			nxt = None
			if stands(n):
				nxt = n
			elif kind(n) == ".":
				for d in (1, 2, 3):
					f = (n[0], y - d, n[2])
					if stands(f):
						nxt = f
						break
					if kind(f) != ".":
						break
			elif kind((x, y + 1, z)) == "." and stands((n[0], y + 1, n[2])):
				nxt = (n[0], y + 1, n[2])
			if nxt and nxt not in seen:
				seen.add(nxt)
				q.append(nxt)
	return len(seen), ore
idle = {}
for i, l in enumerate(lines):
	m = re.search(r"local/rts_harvester (\d+): (no reachable ore|ore again|unloaded)", l)
	if m:
		if m.group(2) == "no reachable ore":
			idle.setdefault(m.group(1), t[i])
		else:
			idle.pop(m.group(1), None)
	m = re.search(r"watch: map (\d+) at", l)
	if m:
		mp = maps[m.group(1)]
		for side, rp in refinery.items():
			# (the refinery's cell: its feet's, over the floor; buildings
			# left out but where it starts)
			start = (round(rp[0]), int(rp[1] + 0.5), round(rp[2]))
			cells, ore = reach(mp["g"], start, [f for f in feet if f != (start[0], start[2])])
			idlers = [h for h, s in idle.items() if team.get(h) == side and s <= mp["t"] - 25]
			print("map at t=%.0f: %s's refinery reaches %d cells, %d of ore; idle: %s" % (mp["t"], side, cells, len(ore), idlers or "none"))
			if idlers and ore:
				bad.append("%s's harvesters %s idle at t=%.0f with %d ore it reaches: %s" % (side, idlers, mp["t"], len(ore), sorted(ore)[:5]))
# (7) Down by stairs: a Blue harvester mined down, stood under the floor
# (y 7's stands) and unloaded after it
low = {}
for i, l in enumerate(lines):
	m = re.search(r"local/rts_harvester (\d+): mined (-?\d+),(-?\d+),(-?\d+)( down)? from (-?\d+),(-?\d+),(-?\d+)", l)
	if m and team.get(m.group(1)) == "Blue":
		h = m.group(1)
		low.setdefault(h, {"down": None, "under": None, "back": None})
		if m.group(5) and low[h]["down"] is None:
			low[h]["down"] = t[i]
		if int(m.group(7)) < 7 and low[h]["under"] is None:
			low[h]["under"] = (t[i], int(m.group(7)), i)
	m = re.search(r"local/rts_harvester (\d+): unloaded", l)
	if m and m.group(1) in low and low[m.group(1)]["under"] and low[m.group(1)]["back"] is None:
		low[m.group(1)]["back"] = t[i]
ok = [(h, v) for h, v in low.items() if v["down"] is not None and v["under"] and v["back"] is not None]
if not ok:
	bad.append("no Blue harvester mined down, stood under the floor and unloaded: %s" % low)
else:
	h, v = ok[0]
	print("ok: Blue's harvester %s mined down at t=%.0f, mined from a stand at y %d at t=%.0f, unloaded at the refinery at t=%.0f" %
		(h, v["down"], v["under"][1], v["under"][0], v["back"]))
# The cut: every stand round the floor ore in the last map reaches the
# refinery and back (no pit)
if maps and "Blue" in refinery:
	g = maps[max(maps, key=int)]["g"]
	rp = refinery["Blue"]
	start = (round(rp[0]), int(rp[1] + 0.5), round(rp[2]))
	ft = [f for f in feet if f != (start[0], start[2])]
	def stands(c):
		x, y, z = c
		if g.get(c, "#") != "." or g.get((x, y - 1, z), "#") == ".":
			return False
		return not any(abs(x - fx) <= 2 and abs(z - fz) <= 2 for fx, fz in ft)
	def nexts(c):
		x, y, z = c
		out = []
		for dx, dz in ((1, 0), (-1, 0), (0, 1), (0, -1)):
			n = (x + dx, y, z + dz)
			if stands(n):
				out.append(n)
			elif g.get(n, "#") == ".":
				for d in (1, 2, 3):
					f = (n[0], y - d, n[2])
					if stands(f):
						out.append(f)
						break
					if g.get(f, "#") != ".":
						break
			elif g.get((x, y + 1, z), "#") == "." and stands((n[0], y + 1, n[2])):
				out.append((n[0], y + 1, n[2]))
		return out
	seen, q, edges = {start}, deque([start]), {}
	while q:
		c = q.popleft()
		for n in nexts(c):
			edges.setdefault(n, set()).add(c)
			if n not in seen:
				seen.add(n)
				q.append(n)
	back, q = {start}, deque([start])
	while q:
		c = q.popleft()
		for p in edges.get(c, ()):
			if p not in back:
				back.add(p)
				q.append(p)
	cut = [c for c in seen if -32 <= c[0] <= -26 and -7 <= c[2] <= -1]
	low_cut = sorted(c for c in cut if c[1] < 7)
	pits = sorted(c for c in cut if c not in back)
	left = [k for k, ch in g.items() if ch == "o" and -30 <= k[0] <= -28 and -5 <= k[2] <= -3 and k[1] in (5, 6)]
	print("the floor ore's cut: %d stands under the floor %s, %d ore left; stands not back to the refinery: %s" % (len(low_cut), low_cut, len(left), pits or "none"))
	if pits:
		bad.append("a pit at the floor ore: %s reached but no way back" % pits)
	if not low_cut:
		bad.append("no stand under the floor at the floor ore in the last map")
# (5), (6) the effects made
for what, rx in (("harvesting", r"local/rts_harvester \d+: harvesting effect at"), ("digging", r"local/rts_digger \d+: digging effect of kit/")):
	if not [l for l in lines if re.search(rx, l)]:
		bad.append("no %s effect" % what)
print("effects: %s" % [l.split(": ", 2)[-1] for l in lines if re.search(r"rts_(harvester|digger) \d+: (harvesting|digging) effect", l)][:4])
# The match, minute by minute
print("the match, minute by minute:")
for mnt in range(int(end // 60) + 1):
	ev = {}
	for i, l in enumerate(lines):
		if mnt * 60 <= t[i] < mnt * 60 + 60:
			for k, r in [(side + " " + w, r"rts_ai %s: %s" % (ai, rx)) for side, ai in (("Red", 11), ("Blue", 899))
					for w, rx in (("buys", r"buys a (\w+)"), ("sends", r"(sends \d+|attacks \w+)"),
						("digs", r"digs towards \S+ \((\w+)"), ("scouts", r"scouts with (\d+)"))] + [("destroyed", r"local/rts_unit (\d+): destroyed"),
					("idle", r"rts_harvester (\d+): no reachable ore")]:
				m = re.search(r, l)
				if m:
					v = m.group(1)
					if k == "destroyed":
						v = team.get(v, "?")
					ev.setdefault(k, []).append(v)
	w = [l for i, l in enumerate(lines) if "watch t=" in l and mnt * 60 <= t[i] < mnt * 60 + 60]
	money = re.search(r"blue=(-?\d+) red=(-?\d+) blue_hp=(\S+) near=(\d+)", w[-1]).groups() if w else ("?",) * 4
	print("  %d: Blue $%s, Red $%s, Blue's buildings %s, Red tanks near Blue's HQ %s; %s" % (mnt, money[0], money[1], money[2], money[3],
		"; ".join("%s %s" % (k, ",".join(sorted(set(v), key=v.index))) for k, v in ev.items()) or "-"))
if bad:
	print("\n".join("FAIL: " + b for b in bad))
	sys.exit(1)
PY
verdict_keep
[ "${verdict_rc:-0}" = 0 ] || fail "Deepcore's economy and computer ($SL)"
echo "PASS: Deepcore against the computer, 10 minutes or to its end: Blue's digger into the rock, both sides' harvesters unloading every minute from minute 3 (until a building lost), none idle by ore it reaches, the computer's attack at Blue's base before minute 6 ($t)"
