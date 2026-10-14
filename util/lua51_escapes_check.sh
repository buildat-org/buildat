#!/bin/bash
# tier: quick
# ci
# cost: 1s (2026-10-08)
# covers: util/lua51_escapes.cmake
# [LUA51_ESCAPES]: the build's scan refuses \u{..}, \xXX and \z at their
# lines, and passes an escaped backslash before the same letters.
set -u
tmp=$(mktemp -d "/tmp/buildat_l51.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/a.lua" <<'L'
local a = "\u{2191}"
local b = "\\u{2191} \\x41 \\z"
local c = "x\x41"
local d = "\\\z"
local e = "[;]" .. "\z"
L
out=$(cmake "-DFILES=$tmp/a.lua" -P "$(dirname "$0")/lua51_escapes.cmake" 2>&1) &&
	{ echo "FAIL: passed"; exit 1; }
lines=$(echo "$out" | grep -o 'a.lua:[0-9]*' | cut -d: -f2 | tr '\n' ' ')
[ "$lines" = "1 3 4 5 " ] || { echo "FAIL: lines $lines"; echo "$out"; exit 1; }
echo "PASS: LuaJIT's escapes refused at their lines, escaped backslashes passed"
