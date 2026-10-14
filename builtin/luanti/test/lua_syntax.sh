#!/bin/bash
# **Every Lua file in the tree parses** -- the cheapest coverage there
# is, and the only thing at all that reads most of them: thirteen games'
# `client_lua` is started by no check ([SMOKE_PICK]'s coverage map,
# 2026-09-25), so a file broken by a bulk edit -- a sed over fifteen
# games, say -- sat there until somebody started that game by hand.
#
#   builtin/luanti/test/lua_syntax.sh
#
# **What it is not**: a check that the code works. It parses, nothing
# more. It parses with LuaJIT where the desk has it, which is the
# dialect the game runs; with only luac (5.4), a file using 5.3's `//`
# passes this and fails there.
#
# tier: quick
# ci
# cost: 3s
# always: yes
#
# **No covers line, and always run.** A shallow check that names half
# the tree would win every "cheapest runner that covers this file" race
# and push the deep ones out ([SMOKE_PICK]'s greedy pick): asked for a
# change under games/, it answered "the syntax check, 3 s" instead of
# the runner that starts the game. So it competes for nothing and runs
# anyway, which is what a check costing under a second is for.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
. "$here/util/check_lib.sh"
cd "$here"
# **LuaJIT's own parser first**: it is what the client and the server
# run, and 5.4's luac refuses LuaJIT's 64-bit literals (classes.lua's
# PCG multiplier, `ULL`). The desk's, or the one Urho3D's build makes
# (the CI image has only lua5.1); luac where there is neither. loadfile
# parses without running, and needs none of LuaJIT's jit.* modules.
luajit=$(command -v luajit || ls 3rdparty/Urho3D/Build/bin/luajit 2>/dev/null)
if [ -n "$luajit" ]; then
	parse(){ F="$1" "$luajit" -e 'assert(loadfile(os.getenv("F")))'; }
elif command -v luac >/dev/null 2>&1; then
	parse(){ luac -p "$1"; }
else
	echo "SKIP: no luajit or luac to parse with" >&2; exit 2
fi
# **The tree is not always a git checkout**: the packaging image builds
# from a git archive, where `git ls-files` answers nothing and this
# would have passed on zero files -- a check that cannot fail
files=$(git ls-files '*.lua' 2>/dev/null | grep -v "^3rdparty/")
if [ -z "$files" ]; then
	files=$(find . -name '*.lua' -not -path './3rdparty/*' \
		-not -path './local/*' -not -path './tmp/*' -not -path './cache/*' |
		sed 's|^\./||')
fi
if [ -z "$files" ]; then
	echo "SKIP: no Lua files found to parse" >&2; exit 2
fi
n=0
bad=0
for f in $files; do
	n=$((n + 1))
	if ! out=$(parse "$f" 2>&1); then
		bad=$((bad + 1))
		echo "$out"
	fi
done
echo "$n Lua files in the tree, $bad of them broken"
# A tree this size has hundreds; a handful means the list came from the
# wrong place, which is the way this check would go quiet
if [ "$n" -lt 50 ]; then
	echo "FAIL: only $n Lua files were found, which is not this tree"
	exit 1
fi
if [ "$bad" -gt 0 ]; then
	echo "FAIL: a Lua file does not parse"
	exit 1
fi
echo "PASS: every Lua file in the tree parses"
exit 0
# vim: set noet ts=4 sw=4:
