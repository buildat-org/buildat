#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: ~1s (2026-11-20)
# always: yes
# covers: util/api_names.py
# [KIT_API_1] (kit_plan 4z37j (4)) Kit API 1's surface: the code against
# doc/kit_api1.txt's listing (util/api_names.py --kit-check; no server).
# Then the check itself, in a copy of the files it reads: a parameter's
# default changed, a c: method removed and a parameter renamed without a
# migrate each fail; the rename with a raised version and a migrate, the
# removal under a deprecation of this level, and an added parameter pass.
#   util/kit_api1_surface_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
command -v luajit >/dev/null || skip "no luajit"
out=$(python3 "$here/util/api_names.py" --kit-check 2>&1) ||
	fail "the code against doc/kit_api1.txt:
$out"
echo "$out"
check_tmp kit_api1_surface; t=$CHECK_TMP
(cd "$here" && cp --parents -r builtin/kit/kit.cpp builtin/kit/box/box.c \
	builtin/kit/box/lua/lstrlib.c builtin/kit/box/lua/ltablib.c \
	builtin/kit/client_lua builtin/kit/types builtin/kit/sounds.json \
	builtin/kit/materials.json src/interface/aitta.h src/impl/jam.cpp \
	extensions/blip/blip_gen.lua extensions/weave/weave_gen.lua \
	util/api_names.py doc/kit_api1.txt "$t") || fail "the copy"
# case <exit wanted> <what its output says> <file> <sed script>: the file
# changed, the check run, the file put back
case_() {
	local want=$1 says=$2 f=$t/$3 got
	cp "$f" "$f.was"
	sed -i "$4" "$f"
	cmp -s "$f" "$f.was" && fail "$3: \"$4\" changed nothing"
	got=$(python3 "$t/util/api_names.py" --kit-check 2>&1)
	local status=$?
	mv "$f.was" "$f"
	[ $status = "$want" ] && echo "$got" | grep -qF -- "$says" ||
		fail "$3 by \"$4\": exit $status (want $want), not \"$says\":
$got"
	echo "ok: $3 by \"$4\": exit $status, \"$says\""
}
E=builtin/kit/types/effect.lua C=builtin/kit/types/counter.lua
case_ 1 "FAULT: type kit/effect param count: changed" $E \
	's/type = "number", default = 12, min = 0, max = 256/type = "number", default = 13, min = 0, max = 256/'
case_ 1 "makes count null, not the old default 12" $E \
	's/type = "number", default = 12, min = 0, max = 256/type = "number", default = 13, min = 0, max = 256/; s/^\tversion = 2,/\tversion = 3,/'
case_ 1 "FAULT: server c:name: removed" builtin/kit/box/box.c \
	's/function c:name(by)/local function c_name(by)/'
case_ 1 "FAULT: type kit/counter param target: removed" $C \
	's/params = {target = {/params = {goal = {/'
case_ 0 "type kit/counter param target (migrated)" $C \
	's/params = {target = {/params = {goal = {/; s/^\tversion = 1,/\tversion = 2,\n\tmigrate = function(params, from) if from < 2 then params.goal, params.target = params.target, nil end return params end,/'
case_ 0 "1 additions" $C \
	's/min = 0, max = 1000000}},/min = 0, max = 1000000}, step = {type = "number", default = 1}},/'
# a deprecation: the removal passes at its level, fails before it
sed -i "/^The listing$/i deprecated: server c:name | 1 | c:x" "$t/doc/kit_api1.txt"
case_ 0 "0 faults" builtin/kit/box/box.c \
	's/function c:name(by)/local function c_name(by)/'
sed -i 's/^deprecated: server c:name | 1 /deprecated: server c:name | 2 /' "$t/doc/kit_api1.txt"
case_ 1 "FAULT: server c:name: removed" builtin/kit/box/box.c \
	's/function c:name(by)/local function c_name(by)/'
echo "PASS: Kit API 1's surface is the listing's; removals, renames and default changes fail without a migrate or a deprecation, additions pass"
