#!/bin/bash
# apps/sample_wasm_ui: [CLIENT_WASM_BINDINGS]' first user, a module whose
# client is C++ only, written against interface/buildat_client.h (the Lua
# sandbox's classes as wasm imports) and run by the engine's default
# client_main: a window with a button (Urho3D's UI), a cube it builds, a
# key and packets both ways. The button is clicked: its Released event
# reaches the module's queue, the module sets the button's text, reads it
# back, and sends "main:click", which echo/ answers; space recolours the
# cube and sends "main:key". Two screenshots: the cube orange, then green.
# A value's methods, Matrix4's constructor, and the calls that return a
# table (Octree:GetDrawables, Skeleton:GetBone, Skeleton.rootBone) read
# by table_get. buildat.* verbs (time, version, sha1, storage, parse_json),
# the magic table's (fov_for, render_scene_to_texture), a global event
# subscribed and unsubscribed. Event payloads: Update's TimeStep,
# SliderChanged's Element (a handle) and Value. Then the C++ twin of extensions/sandbox_test's refusals
# for the calls the bindings cover (main/wasm/main.cpp's refuse()), each a
# trap with its reason; and two modules refused at the load, one importing a call the
# list does not name (unlisted/), one a call of it with another signature
# (wrong_sig/). deep/ makes 12000 nodes in chains (the c key) natively,
# and its camera still holds them ([HOLD_REF_UAF]); on the web its w key
# recurses until the module's count of the browser's stack traps, and a
# binding at the bottom of a recursion just under that depth has room
# ([WASM_WEB_CALL_DEPTH]). Natively twice,
# compiled and in the interpreter; `web` in headless Chrome. Natively the
# s key starts the C++ twin of sandbox_test's secret-field cases: keys
# typed into the Starport ID dialog reach the module by no event or poll,
# and its password field is read as "" and not written, renamed or
# focused away from. budget/'s b
# key: a call of nothing but bindings is stopped by its budget near 50000
# of them (BINDING_COST), and main/ logs what a binding costs. The
# generated files (and client_api.txt's C++ spellings) are checked
# against the generator.
#
#   apps/sample_wasm_ui/check.sh          # the native client
#   apps/sample_wasm_ui/check.sh web      # the web client, headless Chrome
#
# tier: quick
# cost: 100s (2026-10-28)
# covers: util/gen_wasm_bindings.lua doc/client_api.txt src/interface/rust/buildat_wasm/src/client.rs src/interface/buildat_client.h src/lua_bindings/wasm_bindings.inc src/lua_bindings/wasm.cpp src/wasm/** builtin/client_lua/client_lua/wasm_main.lua client/core/urho3d/** client/api.lua src/interface/wasm_api.h apps/sample_wasm_ui/**
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
app=sample_wasm_ui
web=0
for a in "$@"; do
	case "$a" in
		web) web=1 ;;
		*) echo "usage: $0 [web]" >&2; exit 2 ;;
	esac
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp $app
t=$CHECK_TMP

# The generated bindings are what the generator makes of the list now
lua=$(command -v luajit || command -v lua)
if [ -n "$lua" ]; then
	(cd "$here" && "$lua" util/gen_wasm_bindings.lua --check > "$t/gen.log" 2>&1) ||
		{ cat "$t/gen.log"; fail "the generated bindings are stale: run util/gen_wasm_bindings.lua"; }
else
	echo "(no luajit or lua: the generated files not compared)"
fi

# The cube in a screenshot: the middle of the picture orange (red over
# green), then green
cube_is()
{
	python3 - "$1" "$2" <<'EOF' || fail "$1: the cube is not $2"
import sys
from PIL import Image
im = Image.open(sys.argv[1]).convert("RGB")
w, h = im.size
r = g = b = n = 0
for y in range(h * 2 // 5, h * 3 // 5):
	for x in range(w * 2 // 5, w * 3 // 5):
		p = im.getpixel((x, y))
		r, g, b, n = r + p[0], g + p[1], b + p[2], n + 1
r, g, b = r / n, g / n, b / n
print("%s: the middle is %.0f %.0f %.0f" % (sys.argv[1].split("/")[-1], r, g, b))
want = sys.argv[2]
ok = r > 1.3 * g and r > 20 if want == "orange" else g > 1.3 * r and g > 20
sys.exit(0 if ok else 1)
EOF
}

# The module's lines, natively and on the web (the logger's tag is the
# module's name), the refusals' traps and the two modules refused
client_lines()
{
	local log=$1 want
	grep -aE "wasm (main|unlisted|wrong_sig): " "$log" | sed 's/.*wasm \([a-z_]*\): /\1: /' | cut -c1-160
	for want in "wasm main: drew a cube and a window" \
			"wasm main: the camera is at y*10: 15" \
			"wasm main: SetLayout: the second child at y 14" \
			"wasm main: the button was released: presses 1" \
			"wasm main: the button reads: Pressed 1" \
			"wasm main: the server answered echo: click 1" \
			"wasm main: space: the colour is now 1" \
			"wasm main: the server answered echo: key 1" \
			"wasm main: refusals: tried 15, got through: 0" \
			"wasm main: values: 5 1 90 3 10" \
			"wasm main: matrix4: 5 6 7 1" \
			"wasm main: GetDrawables: the cube's node among " \
			"wasm main: GetRootBone: none with no model, bones 0" \
			"wasm main: GetBone(1): Bip01_Footsteps" \
			"wasm main: GetBone(1)'s node: Bip01_Footsteps" \
			"wasm main: rootBone: Bip01" \
			"wasm main: verbs: a time and a version, sha1(abc) a9993e364706816aba3e25717850c26c9cd0d89d" \
			"wasm main: storage: wrote, read back stored 1" \
			"wasm main: parse_json: a has 3" \
			"wasm main: magic: fov_for(60), a texture's width, a viewport generation: 60 64 1" \
			"trap: buildat.buildat.SubscribeToEvent(string):string: " \
			"wasm main: SliderChanged: value*10 25, element sample slider" \
			"wasm main: global Update: its TimeStep in the payload" \
			"trap: buildat.UI.scale=any: " \
			"UI.scale is read-only" \
			"trap: buildat.UIElement:SetStyleAuto(): not called on a UIElement" \
			"trap: buildat.Node.position:Vector3: handle 2130707455 is not this module's" \
			"is stale (dropped)" \
			"trap: buildat.buildat.SubscribeToEvent(UIElement|Node|Component,string): " \
			"Event type is not whitelisted: \"NotAnEvent\"" \
			"constant(Node): not a number or a string of the sandbox's" \
			"trap: buildat.Node.position:Vector3: more than 32 values" \
			"trap: buildat.magic.ui:UI: its results are 6 bytes, past the buffer's 1" \
			"trap: buildat.buildat.table_get(table,any):any: not called on a table a call returned" \
			"trap: buildat.UIElement:GetName():string: " \
			"UIElement \"held\" was removed" \
			"wasm unlisted: refused: imports \"buildat.Image:FlipHorizontal():boolean\", which is not one of" \
			"wasm wrong_sig: refused: imports \"buildat.Node.position:Vector3\", which is not one of"; do
		grep -aqF "$want" "$log" || fail "no \"$want\" in $log"
	done
	[ "$(grep -ac "wasm main: refusal: refused by its answer" "$log")" -eq 4 ] ||
		fail "not the four refused by their answers, the cache's and get_env's ($log)"
	grep -aqE "wasm main: global Update: unsubscribed at 3, more after: [01]$" "$log" ||
		fail "the global Update not unsubscribed after 3 ($log)"
	grep -a "GOT THROUGH" "$log" && fail "a refusal got through ($log)"
	grep -aq "presses 2" "$log" && fail "one click read as two ($log)"
	return 0
}

# budget/'s b key: bindings until the call's budget stops it, near 50000
# (BINDING_COST), on whichever engine ran it
budget_stopped()
{
	local log=$1
	grep -a "wasm budget: trap: " "$log" | head -1 | sed 's/.*wasm budget: /budget: /' | cut -c1-160
	grep -aq "wasm budget: trap: buildat.Node:GetID():number: past the call's budget" "$log" ||
		fail "budget/'s bindings not stopped by the budget ($log)"
	# (the interpreter's budget, a sixteenth, also pays its own code's
	# share of a call unscaled: there a few thousand fewer)
	grep -aq "budget: 35000 calls" "$log" ||
		fail "budget/ stopped before 35000 bindings ($log)"
	grep -a "budget: [0-9]* calls" "$log" | tail -1 | sed 's/.*wasm budget: /budget: the last line: /'
	grep -aqE "budget: (55000 calls|NOT STOPPED)" "$log" &&
		fail "budget/ ran past 55000 bindings ($log)"
	return 0
}

# The secret field's twin (main.cpp's secret_frame(), natively: the web
# client has no Starport ID dialog): q seen all four ways, w and e typed
# into the dialog by none, each attempt on its password field refused
secret_kept()
{
	local log=$1 how
	for how in "polled" "by the client_main's KeyDown" "by a KeyDown subscription" \
			"by TextInput"; do
		grep -aq "wasm main: secret: q $how" "$log" ||
			fail "q not seen $how before the dialog ($log)"
	done
	grep -aqE "wasm main: secret: [we] " "$log" &&
		fail "a key typed into the Starport ID dialog reached the module ($log)"
	grep -aq "wasm main: secret: tried 7, got through: 0" "$log" ||
		fail "not the secret field's 7 attempts all refused ($log)"
	[ "$(grep -ac "wasm main: secret: refused by its answer" "$log")" -eq 4 ] ||
		fail "not the four refused by their answers ($log)"
	[ "$(grep -ac "trap: .*a client's secret field is not a script's to write" "$log")" -ge 3 ] ||
		fail "not the three writes trapped ($log)"
	return 0
}

if [ $web = 1 ]; then
	# The button is the top left third of the screen: clicked in its middle
	cat > "$t/steps.json" <<'EOF'
[
	["viewport", 960, 600],
	["nav", "${URL}"],
	["waitlog", "drew a cube and a window", 120],
	["waitlog", "refusals: tried", 30],
	["wait", 500],
	["shot", "${OUT}/before.png"],
	["mouse", 240, 100],
	["click", 240, 100],
	["waitlog", "the server answered echo: click", 30],
	["key", "Space"],
	["waitlog", "the server answered echo: key", 30],
	["wait", 500],
	["shot", "${OUT}/after.png"],
	["key", "w"],
	["waitlog", "deep: limit", 60],
	["waitlog", "deep: alive, root width", 60],
	["key", "Space"],
	["waitlog", "the server answered echo: key 2", 10],
	["key", "m"],
	["waitlog", "cost \\(m\\): ", 10],
	["key", "b"],
	["waitlog", "wasm budget: stopped: ", 10]
]
EOF
	# deep/'s w key: a recursion until it traps, then a sweep down from
	# that depth, each a binding at the bottom. The trap is the module's
	# own count of the browser's stack ([WASM_WEB_CALL_DEPTH]), not the
	# browser's RangeError, and it leaves room for the binding: the stack
	# never runs out inside the client ([WASM_WEB_IMPORT_DEPTH] stopped the
	# module there), the sweep ends, and main/ still answers a key
	"$here/util/web_drive.sh" chrome $app "$t/steps.json" "$t/web" > "$t/drive.log" 2>&1 ||
		{ tail -20 "$t/drive.log"; fail "the web drive failed ($t/web)"; }
	grep -a " I echo *: " "$t/web/server.log" | sed 's/.*echo *: //'
	client_lines "$t/web/page.log"
	budget_stopped "$t/web/page.log"
	grep -aq "wasm deep: frame: trap: call stack exhausted (past the web client's" \
		"$t/web/page.log" || fail "deep/'s recursion not stopped by the stack count ($t/web)"
	grep -aE "wasm deep: .*(RangeError|the stack ran out)" "$t/web/page.log" &&
		fail "the browser's stack ran out in deep/ ($t/web)"
	grep -aq "wasm main: ready (the browser's instance)" "$t/web/page.log" ||
		fail "not the browser's own instance"
	grep -aq "click from the client's wasm: 1" "$t/web/server.log" ||
		fail "the server did not get the module's click"
	cube_is "$t/web/before.png" orange
	cube_is "$t/web/after.png" green
	echo "PASS: $app on the web: a C++ client through the bindings (a window, a button clicked, a cube, a key, packets both ways), the refusals refused"
	exit 0
fi

cd "$here/Build"
# run <n> <a command before quit> <env...>
run()
{
	local n=$1 last=$2
	shift 2
	start_server "$t/srv$n.log" "Listening at" 120 auto bin/buildat_server \
			-m ../apps/$app -l 3 || fail "the server did not come up"
	CHECK_PIDS+=($SERVER_PID)
	cat > "$t/cmds$n.txt" <<EOF
expect_error the default client_main: no wasm: refused
expect_error frame: wasm main: frame: trap
expect_error the default client_main stopped the module
wait_log 60000 drew a cube and a window
wait_log 30000 refusals: tried
delay 500
screenshot $t/before$n.png
click Button "Press me"
wait_log 10000 the server answered echo: click
keypress space
wait_log 10000 the server answered echo: key
delay 500
screenshot $t/after$n.png
keypress c
wait_log 60000 deep: chains done
keypress b
wait_log 10000 wasm budget: stopped:
$last
keypress s
wait_log 5000 secret: watching
keypress q
wait_log 5000 secret: q polled
text q
wait_log 5000 secret: q by TextInput
keypress F9
delay 300
click Button "Starport ID..."
wait_log 5000 starport: the ID login shown
wait_log 10000 secret: tried
keypress w
text w
keypress Tab
keypress e
text e
delay 500
quit
EOF
	# The Starport ID dialog asks no real Starport
	run_client 60 "$t/cli$n.log" timeout 120 env \
			BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9 "$@" bin/buildat -C "$t/client_cache" \
			-s localhost:$SERVER_PORT -w 640x480 -l 3 -c @"$t/cmds$n.txt"
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
	# The module's storage_write, kept per server address: removed
	rm -f "$BUILDAT_USER_PATH/servers/localhost_$SERVER_PORT/wasm_ui_check"
	rmdir "$BUILDAT_USER_PATH/servers/localhost_$SERVER_PORT" 2>/dev/null
	echo "-- run $n"
	grep -a " I echo *: " "$t/srv$n.log" | sed 's/.*echo *: //'
	client_lines "$t/cli$n.log"
	budget_stopped "$t/cli$n.log"
	secret_kept "$t/cli$n.log"
	grep -aq "click from the client's wasm: 1" "$t/srv$n.log" ||
		fail "the server did not get the module's click"
	cube_is "$t/before$n.png" orange
	cube_is "$t/after$n.png" green
	# [HOLD_REF_UAF] deep/'s 12000 nodes in chains: the client lives, and
	# the module's scene with them
	grep -aq "Crash: SIG" "$t/cli$n.log" && fail "the client crashed ($t/cli$n.log)"
	grep -aq "deep: chains done, on the camera 12$" "$t/cli$n.log" ||
		fail "not 12 chains on deep's camera: $(grep -a "chains done" "$t/cli$n.log")"
}
# The compile (about a second) is waited for, so that the move is seen
run 1 "wait_log 60000 ; ready (compiled)
keypress m
wait_log 10000 cost (m): "
grep -aqE "wasm main: (moved to the compiled module|compiled module from the cache)" "$t/cli1.log" ||
	fail "not compiled in run 1 ($t/cli1.log)"
run 2 "delay 0" BUILDAT_CHECK_WASM_INTERPRETER=1
grep -aq "wasm main: ready (interpreter): no C compiler" "$t/cli2.log" ||
	fail "not the interpreter in run 2 ($t/cli2.log)"
echo "PASS: $app natively, compiled and in the interpreter: a C++ client through the bindings (a window, a button clicked, a cube, a key, packets both ways), the refusals refused"
