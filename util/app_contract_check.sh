#!/bin/bash
# tier: quick
# cost: ~20 s (2026-10-12)
# covers: builtin/loader/loader.cpp src/impl/aitta.cpp
# [COMPAT_BREAK_07] 8c, the app contract: a server on an app whose module
# says no engine_api, says 1, has a key the loader does not know, or is
# named like a builtin stops at load with the reason; the same app with
# "engine_api": 2 loads.
#   util/app_contract_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp app_contract; t=$CHECK_TMP
cd "$here/Build"

# try <name> <module dir name> <meta.json> <expected log text>
try(){
	local a=$t/$1
	mkdir -p "$a/$2"
	echo "$3" > "$a/$2/meta.json"
	start_server "$t/$1.log" "STATUS Listening|$4" 60 auto \
		bin/buildat_server -m "$a" -D "$t/u_$1" -l 3 2>/dev/null
	CHECK_PIDS+=($SERVER_PID)
	grep -qaF "$4" "$t/$1.log" || fail "$1: no \"$4\" ($t/$1.log)"
	kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null
	echo "ok: $1: $(grep -aoF "$4" "$t/$1.log" | head -1)"
}
try none main '{"disable_cpp": true}' '"engine_api": the engine API it is written for is missing'
try old main '{"engine_api": 1, "disable_cpp": true}' 'made for an older Buildat (engine API 1'
try newer main '{"engine_api": 99, "disable_cpp": true}' 'needs a newer Buildat (engine API 99'
try unknown main '{"engine_api": 2, "disable_cpp": true, "colour": 1}' '"colour" is not a key this Buildat knows'
try builtin storage '{"engine_api": 2, "disable_cpp": true}' 'the app'"'"'s module "storage" has the name of a module Buildat comes with'
try good main '{"engine_api": 2, "disable_cpp": true, "dependencies": [{"module": "network"}]}' 'STATUS Listening'
echo "PASS: no engine_api, 1, 99, an unknown key and a builtin's name refused at load with the reason; engine_api 2 loads"
