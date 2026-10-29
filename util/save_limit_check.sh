#!/bin/bash
# tier: full
# cost: ~10 min (2026-10-11)
# covers: builtin/storage/storage.cpp builtin/voxelworld/voxelworld.cpp builtin/luanti/luanti.cpp apps/vanilla/main/main.cpp
# [SAVE_LIMIT]: vanilla on the minimal game with a fixture of its own
# terrain (stone with markers scattered by a hash of the position: the
# same every time, and not compressing to nothing; glass was 13 GB of
# client meshes, a face for each stone beside it) and an area kept loaded
# walking +x across it.
#   0. A first start with no limit says what the app takes (its compiled
#      modules most of it); the run's --max-disk-mb is that plus half a
#      MB over 90%, since a trim goes to 90% of the limit.
#   1. A ContentDB install bigger than the room left (a local server
#      answering ContentDB's API with a zip 1 MB over it) is refused and
#      leaves nothing behind. Before it, on a server with no world
#      started, the log's start line names the limit and the world list
#      at the boot is sent it in bytes ([DISK_LIMIT_SHOWN]).
#   2. A client on: past x 220 its chat command places a node at x 160
#      (altered). Past 2000 the walk waits while the section at x 2000 is
#      hashed and a timer digs a hole in it; past 2600 while a timer pours
#      water at x 2600. Neither is a player's doing.
#   3. The walk goes on past the limit: storage says so, vanilla trims,
#      and the total stays under the limit plus a step.
#   4. The player's node is there; the section at x 2000, walked to again,
#      hashes as before the timer's node (forgotten, made again the same),
#      and the water is gone.
#
#   util/save_limit_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp save_limit; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
mkdir -p "$t/u/shared" "$t/u/apps/vanilla/saves/w/luanti"
echo "enable_damage = false" > "$t/u/apps/vanilla/saves/w/luanti/world.mt"
cat > "$t/u/shared/fixture.lua" <<'L'
local function noise(x, y, z)
	return (x * 73856093 + y * 19349663 + z * 83492791) % 7 == 0
end
core.register_on_generated(function(minp, maxp)
	if maxp.y < -64 or minp.y > 0 then return end
	local vm, emin, emax = core.get_mapgen_object("voxelmanip")
	local area = VoxelArea(emin, emax)
	local data = vm:get_data()
	local stone = core.get_content_id("floor:stone")
	local marker = core.get_content_id("floor:marker")
	for z = minp.z, maxp.z do for y = minp.y, math.min(maxp.y, -1) do
		for x = minp.x, maxp.x do
			data[area:index(x, y, z)] = noise(x, y, z) and marker or stone
		end
	end end
	vm:set_data(data)
	vm:write_to_map()
end)
-- What is in a box of the walked strip from a point: inside what the walk
-- keeps loaded when it stops past the point (x .. x + 47)
local function section_hash(x, y, z)
	local p1 = {x = x, y = -32, z = z}
	local p2 = {x = x + 31, y = -1, z = z + 15}
	local vm = VoxelManip(p1, p2)
	local h = 0
	for zz = p1.z, p2.z do for yy = p1.y, p2.y do for xx = p1.x, p2.x do
		h = (h * 31 + core.get_content_id(vm:get_node_at({x = xx, y = yy, z = zz}).name)) % 2147483647
	end end end
	return h
end
core.register_chatcommand("mark", {func = function(name)
	core.set_node({x = 160, y = 2, z = 0}, {name = "floor:marker"})
	core.log("action", "limit_check: marked by " .. name)
	return true, "marked"
end})
local x, acc, phase, first_hash, paused = 128, 0, "walk", nil, false
local function area(on)
	local bx = math.floor(x / 16)
	for ax = bx - 1, bx + 1 do for ay = -2, 0 do for az = -4, 4 do
		local b = {x = ax, y = ay, z = az}
		if on then core.__forceload_block_raw(b) else core.__forceload_free_block_raw(b) end
	end end end
end
local function go(to) area(false); x = to; area(true) end
local said = {}
local function once(key, f) if not said[key] then said[key] = true; f() end end
local function water() return core.get_node({x = 2600, y = 0, z = 0}).name ..
		" " .. core.get_node({x = 2602, y = 0, z = 0}).name end
core.register_globalstep(function(dtime)
	if #core.get_connected_players() == 0 then return end
	acc = acc + dtime
	if acc < 0.5 then return end
	acc = 0
	if paused then return end
	if phase == "walk" then
		go(x + 16)
		if x > 220 then once("mark", function() core.chat_send_all("limit_check: mark now") end) end
		-- The walk waits while the section is written to and looked at
		if x > 2000 then once("hash", function()
			paused = true
			-- Once it is generated: the spot the timer digs is terrain (not
			-- air, nor ignore), and two looks a second apart agree
			local function look(n, last)
				first_hash = section_hash(2000, -8, 0)
				local at = core.get_node({x = 2010, y = -8, z = 0}).name
				if (at ~= "floor:stone" and at ~= "floor:marker" or
						first_hash ~= last) and n < 180 then
					core.after(1, look, n + 1, first_hash) return end
				core.log("action", "limit_check: first hash " .. first_hash)
				core.after(1, function()
				core.set_node({x = 2010, y = -8, z = 0}, {name = "air"})
				core.after(1, function()
					core.log("action", "limit_check: the timer wrote, hash now " ..
							section_hash(2000, -8, 0))
					paused = false
				end)
				end)
			end
			look(0, nil)
		end) end
		if x > 2600 then once("water", function()
			paused = true
			local function pour(n)
				local under = core.get_node({x = 2600, y = -1, z = 0}).name
				if under ~= "floor:stone" and under ~= "floor:marker" and
						n < 180 then core.after(1, pour, n + 1) return end
				core.set_node({x = 2600, y = 0, z = 0}, {name = "floor:water_source"})
				local function flowed(m)
					if water():find("flowing") == nil and m < 60 then
						core.after(1, flowed, m + 1) return end
					core.log("action", "limit_check: poured, " .. water())
					paused = false
				end
				core.after(1, flowed, 0)
			end
			pour(0)
		end) end
		if x >= 6000 then phase = "back"; go(2000) end
	elseif phase == "back" then
		phase = "wait"
		-- Made again: terrain where the hole was, and two looks agree
		local function look(n, last)
			local h = section_hash(2000, -8, 0)
			local at = core.get_node({x = 2010, y = -8, z = 0}).name
			if (at ~= "floor:stone" and at ~= "floor:marker" or h ~= last) and
					n < 180 then core.after(1, look, n + 1, h) return end
			core.log("action", "limit_check: the hole is " .. at)
			go(2600)
			core.after(6, function()
				core.log("action", "limit_check: hash again " .. h .. " (first " ..
						tostring(first_hash) .. "), water " .. water() ..
						", marker " .. core.get_node({x = 160, y = 2, z = 0}).name)
				core.log("action", "limit_check: done")
			end)
		end
		look(0, nil)
	end
end)
L
server() # log, then the server's own arguments
{
	local log=$1; shift
	BUILDAT_LUANTI_GAME=${GAME-minimal} BUILDAT_LUANTI_SAVE=${SAVE-w} \
		BUILDAT_LUANTI_LUA="$t/u/shared/fixture.lua" \
		start_server "$log" "STATUS Listening" 120 auto bin/buildat_server \
		-u launcher=1 -A 127.0.0.1 -m ../apps/vanilla -D "$t/u" -C "$t/c" -l 4 "$@" ||
		fail "the server did not start ($log)"
	CHECK_PIDS+=($SERVER_PID)
}
kb() # the storage lines' total, kB, one a line
{
	grep -a "storage : saves: " "$1" | sed 's/.*saves: \([0-9]*\) kB, shared \([0-9]*\) kB, cache \([0-9]*\) kB.*/\1 \2 \3/' |
		awk '{ print $1 + $2 + $3 }'
}

# 0.
server "$t/s0.log"
wait_for_log "$t/s0.log" "The world is up" 120 || fail "no world ($t/s0.log)"
n=$(grep -ac "storage : saves: " "$t/s0.log")
for i in $(seq 30); do [ "$(grep -ac "storage : saves: " "$t/s0.log")" -gt "$n" ] && break; sleep 1; done
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null
first=$(kb "$t/s0.log" | tail -1)
[ -n "$first" ] || fail "no measure ($t/s0.log)"
# A trim goes to 90% of the limit less the rest: 90% of it is the first
# start and half a MB, so that a trim leaves little more than what is
# loaded and the walk's land behind it is what goes
limit=$(( (first * 1024 + 500000) * 10 / 9 / 1000000 + 1 ))
room=$(( limit * 1000000 - first * 1024 ))
echo "ok: the first start takes $first kB; the limit is $limit MB, $room bytes left"

# A server with the limit and no world started: the start line, and the
# world list the client is shown at the boot
GAME= SAVE= server "$t/sw.log" --max-disk-mb $limit
wait_for_log "$t/sw.log" "storage : max_disk_mb" 30
grep -aEq "storage : max_disk_mb $limit: [0-9]+ MB written \(saves [0-9]+ MB, games and shared [0-9]+ MB, cache [0-9]+ MB\)" "$t/sw.log" ||
	fail "the start line: $(grep -a "max_disk_mb" "$t/sw.log" | head -1)"
# The world list's Disk line: main:disk's limit is the option's MB
printf 'wait_log 30000 menu: disk\nframes 3\nscreenshot %s\nquit\n' "$t/worlds.png" > "$t/w.cmds"
timeout 90 bin/buildat -C "$t/cc" -D "$t/uc" -s 127.0.0.1:"$SERVER_PORT" \
	-w 640x400 -u 1 -l 3 -o sound_mute=1 -c @"$t/w.cmds" > "$t/worlds.log" 2>&1 ||
	fail "the world list's drive ($t/worlds.log)"
grep -aEq "menu: disk [0-9]+ of ${limit}000000$" "$t/worlds.log" ||
	fail "main:disk: $(grep -a "menu: disk" "$t/worlds.log") ($t/worlds.log)"
echo "ok: the start line says max_disk_mb $limit, and main:disk the same"
kill $SERVER_PID; wait $SERVER_PID 2>/dev/null

# 1.
mkdir -p "$t/m/api/packages/a/big/releases"
echo '[{"url": "/big.zip"}]' > "$t/m/api/packages/a/big/releases/index.html"
(cd "$t/m" && mkdir -p big && head -c $((room + 1000000)) /dev/urandom > big/blob && zip -q0 -r big.zip big && rm -r big)
mport=$((29400 + RANDOM % 200))
(cd "$t/m" && exec python3 -m http.server -b 127.0.0.1 $mport > "$t/m.log" 2>&1) &
CHECK_PIDS+=($!)
for i in $(seq 20); do curl -s -o /dev/null "http://127.0.0.1:$mport/big.zip" && break; sleep 0.5; done

# The 300 ms: the text in the field before Return. The last delay keeps the
# client on for the walk; the check's end stops it.
cat > "$t/c.cmds" <<'C'
wait_log 120000 limit_check: mark now
delay 1000
keypress T
wait_log 5000 chat: the line opened
text /mark
# the typing taken in the frames before Return
delay 300
keypress Return
wait_log 10000 chat: marked
keypress T
wait_log 5000 chat: the line opened
text /mark
# the typing taken in the frames before Return
delay 300
keypress Return
# on for the walk until the check's end stops it
delay 1500000
quit
C
BUILDAT_CONTENTDB_URL="http://127.0.0.1:$mport" BUILDAT_CONNECT_PORTS=$mport \
	BUILDAT_CONTENTDB_INSTALL_ONCE=a/big server "$t/s.log" --max-disk-mb $limit
wait_for_log "$t/s.log" "Installing big failed" 60 || fail "the install did not end ($t/s.log)"
grep -aq "Installing big failed: Not enough room" "$t/s.log" ||
	fail "the install: $(grep -a "Installing big" "$t/s.log")"
left=$(find "$t/u" "$t/c" -iname "*big*")
[ -z "$left" ] || fail "the install left $left"
echo "ok: an install of the room and 1 MB refused, nothing left"

# 2.
# In a scope of its own with a memory cap where there is one: a client
# that grew to 13 GB here once took the desktop's other programs with it
cap=
systemd-run --user --scope -q -p MemoryMax=200M true 2>/dev/null &&
	cap="systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0"
$cap timeout 1500 bin/buildat -C "$t/cc" -D "$t/uc" -s 127.0.0.1:"$SERVER_PORT" \
	-w 640x400 -u 1 -l 3 -o sound_mute=1 -c @"$t/c.cmds" > "$t/client.log" 2>&1 &
cpid=$!
CHECK_PIDS+=($cpid)
# A line in the server's log while the client walks: the walk stops with it
walk_wait() # regex seconds
{
	local i
	for i in $(seq $(($2 * 5))); do
		grep -qaE "$1" "$t/s.log" && return 0
		kill -0 $cpid 2>/dev/null || break
		sleep 0.2
	done
	grep -qaE "$1" "$t/s.log"
}
walk_wait "limit_check: marked by" 150 || fail "no mark ($t/client.log)"
walk_wait "limit_check: the timer wrote" 400 || fail "no timer write ($t/s.log, $t/client.log)"
grep -a "limit_check: the timer wrote, hash now" "$t/s.log" | grep -q "now $(grep -a "limit_check: first hash" "$t/s.log" | sed 's/.*first hash //')$" &&
	fail "the timer's node did not change the hash"
walk_wait "limit_check: poured" 400 || fail "no water ($t/s.log, $t/client.log)"
grep -aq "limit_check: poured, floor:water_source floor:water_flowing" "$t/s.log" ||
	fail "the water: $(grep -a "limit_check: poured" "$t/s.log")"
echo "ok: a player's node, a timer's, and water flowing"

# 3.
walk_wait "limit_check: done" 900 || fail "the walk did not end ($t/s.log, $t/client.log)"
grep -aq "storage : .* over the limit" "$t/s.log" || fail "never over ($t/s.log)"
trims=$(grep -ac "main    : trimmed: [1-9]" "$t/s.log")
[ "$trims" -ge 2 ] || fail "$trims trims ($t/s.log)"
most=$(awk '/main    : trimmed: [1-9]/ { on = 1 } on && /storage : saves: / { print }' "$t/s.log" |
	sed 's/.*saves: \([0-9]*\) kB, shared \([0-9]*\) kB, cache \([0-9]*\) kB.*/\1 \2 \3/' |
	awk '{ print $1 + $2 + $3 }' | sort -n | tail -1)
[ -n "$most" ] && [ "$most" -lt $(( (limit * 1000000 + 1000000) / 1024 )) ] ||
	fail "after the first trim the app had ${most:-?} kB of $limit MB"
echo "ok: over, $trims trims, at most $most kB after the first"

# 4.
grep -aq "limit_check: the hole is floor:\(stone\|marker\)" "$t/s.log" ||
	fail "the timer's section was not forgotten: $(grep -a "the hole is" "$t/s.log")"
line=$(grep -a "limit_check: hash again" "$t/s.log" | sed 's/.*hash again //')
case "$line" in
	*"marker floor:marker") ;;
	*) fail "the player's node: $line" ;;
esac
case "$line" in
	*"water air air,"*) ;;
	*) fail "the water stayed: $line" ;;
esac
h1=$(echo "$line" | sed 's/ .*//'); h0=$(echo "$line" | sed 's/.*(first \([0-9]*\)).*/\1/')
[ "$h1" = "$h0" ] || fail "made again differently: $line"
echo "ok: the player's node kept; the walked land and the water's made again as generated"
echo "PASS: every step above held"
