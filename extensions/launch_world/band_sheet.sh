#!/bin/sh
# [SIGIL_ROUND]: the band generator's own sheet -- forty styles from
# forty names, twelve voxels of wall each, four to a row.
#
#     extensions/launch_world/band_sheet.sh [names...]
#
# **It drives the shipped generator**, not a copy of it: ornament.lua
# needs one stub to load outside the client and nothing else, so the
# sheet is always what the room would draw. That is the property the
# mark round's sheet has and the reason this one exists at all -- a
# model of a generator drifts from it, and then the picture that
# settled an argument is a picture of something nobody ships.
#
# Writes local/options_for_LAUNCH_WORLD_sigil/band.pgm and prints each
# style beside its ink share and its seam count. **The seam count is
# the check**: a band whose tiles do not join is broken however it
# looks, and the number is one line of arithmetic that no eye supplies.
set -e
cd "$(dirname "$0")/../.."
out=local/options_for_LAUNCH_WORLD_sigil
mkdir -p "$out"
exec lua - "$@" <<'LUA'
package.loaded["buildat/core/urho3d"] = {Vector3 = true}
local M = dofile("extensions/launch_world/ornament.lua")
local N, TILES = 96, 12
local names = {...}
if #names == 0 then
	for i = 1, 40 do names[i] = "wall " .. i end
end
local W, H = N * TILES, N * #names
local px = {}
for i = 1, W * H do px[i] = 255 end
print(string.format("%-22s %-5s %-14s %6s %8s", "name", "kind", "lattice",
		"ink", "seams"))
local broken = 0
for r, name in ipairs(names) do
	local st = M.band_style(M.seed_of(name))
	local strip = {}
	for i = 1, W * N do strip[i] = 0 end
	for t = 0, TILES - 1 do
		local f = M.band(N, st, t)
		for y = 0, N - 1 do
			for x = 0, N - 1 do
				if M.at(f, x, y) > 0.5 then strip[y * W + t * N + x + 1] = 1 end
			end
		end
	end
	local joins, tot, ink = 0, 0, 0
	for b = 1, TILES - 1 do
		for y = 0, N - 1 do
			local a = strip[y * W + b * N - 1 + 1] > 0.5
			local c = strip[y * W + b * N + 1] > 0.5
			if a or c then
				tot = tot + 1
				if a == c then joins = joins + 1 end
			end
		end
	end
	for i = 1, W * N do if strip[i] > 0.5 then ink = ink + 1 end end
	if joins ~= tot then broken = broken + 1 end
	print(string.format("%-22s %-5s %2dx%-2d .%02d%s %5.1f%% %4d/%-4d%s",
			name:sub(1, 22), st.kind, st.cols, st.rows,
			math.floor(st.fill * 100 + 0.5), st.rails and " rail" or "     ",
			ink / (W * N) * 100, joins, tot,
			joins == tot and "" or "  BROKEN"))
	for y = 0, N - 1 do
		for x = 0, W - 1 do
			px[(r - 1) * N * W + y * W + x + 1] =
					(strip[y * W + x + 1] > 0.5) and 0 or 255
		end
	end
end
local f = io.open("local/options_for_LAUNCH_WORLD_sigil/band.pgm", "wb")
f:write(string.format("P5\n%d %d\n255\n", W, H))
local buf = {}
for i = 1, W * H do buf[i] = string.char(px[i]) end
f:write(table.concat(buf))
f:close()
print("")
print("the sheet: local/options_for_LAUNCH_WORLD_sigil/band.pgm -- a row a "
		.. "name, twelve voxels of wall")
if broken > 0 then
	print(broken .. " of " .. #names .. " do not join; see [SIGIL_ROUND]")
end
LUA
