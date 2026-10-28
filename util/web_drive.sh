#!/bin/bash
# A game's web client in a headless browser, driven through a steps file
# (util/web_drive.js says what a step is):
#
#   util/web_drive.sh <firefox|chrome|webkit> <game> <steps.json> [out dir]
#   util/web_drive.sh firefox floorplanner apps/floorplanner/test/web_smoke.json
#
# Starts buildat_server with the game on a free port, a user directory of
# its own and the web client from web/ (util/build_web.sh makes it), and the
# browser with a profile of its own; runs the steps with ${URL}, ${OUT} and
# ${SETUP_CODE} (the code the fresh server's first admin joins with) filled
# in; stops the two. What is left is in the out dir: the screenshots the
# steps took, page.log (the page's console), server.log and browser.log.
# Fails when a step does, and when the browser warned about WebGL -- a draw
# it refused is a warning there and nothing on the screen (the plan view's
# grid in Firefox, 2026-10-01).
# Needs Node 22 or newer, and Firefox 129 or newer or Chrome; FIREFOX and
# CHROME name the binaries (firefox, google-chrome). WebKit is Playwright's
# (PLAYWRIGHT_NODE, ~/.local/share/playwright-node by default, with
# `npx playwright install webkit` done there).
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
check_build web
[ $# -ge 3 ] || { sed -n '2,7p' "$0" | sed 's/^# *//' >&2; exit 2; }
browser=$1 game=$2 steps=$(cd "$(dirname "$3")" && pwd)/$(basename "$3")
out=${4:-$(mktemp -d "${TMPDIR:-/tmp}/web_drive.XXXXXX")}
mkdir -p "$out" && out=$(cd "$out" && pwd)
# A port nothing is listening on, from base up to base + 300
free_port(){
	local p
	for _ in $(seq 1 50); do
		p=$(($1 + RANDOM % 300))
		(echo > /dev/tcp/127.0.0.1/$p) 2>/dev/null || { echo $p; return; }
	done
	echo "web_drive: no free port from $1" >&2
	exit 1
}
port=$(free_port 29600)
bport=$(free_port 9400)
pids=()
cleanup(){
	# Each was started in a process group of its own: the whole group goes,
	# the browser's children with it, and nothing else
	for p in "${pids[@]}"; do
		kill -- -"$p" 2>/dev/null
	done
}
trap cleanup EXIT

# WEB_DRIVE_URL: a server already running there (a package's smoke), and
# none started here
url=${WEB_DRIVE_URL:-}
code=""
if [ -z "$url" ]; then
	echo "web_drive: $browser, $game on port $port, out $out"
	cd "$here"
	setsid Build/bin/buildat_server -m "apps/$game" -D "$out/user" -P "$port" \
			-W "$here/web" -l 3 > "$out/server.log" 2>&1 &
	pids+=($!)
	for i in $(seq 1 120); do
		grep -q "Listening at" "$out/server.log" && break
		sleep 1
	done
	grep -q "Listening at" "$out/server.log" ||
		{ echo "web_drive: the server did not start" >&2; tail -20 "$out/server.log" >&2; exit 1; }
	code=$(grep -ao "setup code [A-Z0-9]*" "$out/server.log" | awk '{print $3}' | head -1)
	url="http://127.0.0.1:$port/"
else
	cd "$here"
	echo "web_drive: $browser, the server at $url, out $out"
fi


case "$browser" in
	firefox)
		mkdir -p "$out/profile"
		# Muted, as the native checks' sound_mute=1
		echo 'user_pref("media.volume_scale", "0.0");' > "$out/profile/user.js"
		# TOUCH=1: a phone's pointer -- (pointer: coarse), which the page
		# reads as a touchscreen, and touch events for the "tap" step
		[ "${TOUCH:-}" = 1 ] && printf '%s\n' \
			'user_pref("ui.primaryPointerCapabilities", 1);' \
			'user_pref("dom.w3c_touch_events.enabled", 1);' >> "$out/profile/user.js"
		MOZ_HEADLESS=1 setsid "${FIREFOX:-firefox}" --headless \
				--remote-debugging-port="$bport" --profile "$out/profile" \
				--no-remote about:blank > "$out/browser.log" 2>&1 &
		pids+=($!)
		ready="WebDriver BiDi listening" ;;
	chrome)
		setsid "${CHROME:-google-chrome}" --headless=new --mute-audio \
				--remote-debugging-port="$bport" --user-data-dir="$out/profile" \
				--use-gl=angle --use-angle=swiftshader --enable-unsafe-swiftshader \
				--window-size=1200,800 about:blank > "$out/browser.log" 2>&1 &
		pids+=($!)
		ready="DevTools listening" ;;
	webkit)
		# Started by web_drive.js itself, headless
		export NODE_PATH=${PLAYWRIGHT_NODE:-$HOME/.local/share/playwright-node}/node_modules
		export PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1
		ready="" ;;
	*) echo "web_drive: the browser is firefox, chrome or webkit" >&2; exit 2 ;;
esac
for i in $(seq 1 60); do
	[ -n "$ready" ] || break
	grep -q "$ready" "$out/browser.log" && break
	sleep 0.5
done
[ -z "$ready" ] || grep -q "$ready" "$out/browser.log" ||
	{ echo "web_drive: the browser did not start" >&2; tail -20 "$out/browser.log" >&2; exit 1; }

node "$here/util/web_drive.js" --browser "$browser" --port "$bport" \
		--steps "$steps" --log "$out/page.log" --var "URL=$url" \
		--var "OUT=$out" --var "SETUP_CODE=$code"
status=$?
# Firefox writes its WebGL warnings to its own output, Chrome to the
# page's log. Two kinds draw as they should and are left out: a texture
# drawn before anything was put in it (a render target, the sky's cube) is
# "lazy initialization", a clear; and a shadow map's filtered comparison
# is "implementation-defined". The rest are what was not drawn.
warnings=$(cat "$out/browser.log" "$out/page.log" 2>/dev/null |
		grep -ai "WebGL warning\|GL_INVALID" |
		grep -v "lazy initialization\|implementation-defined" |
		sort | uniq -c | sort -rn)
if [ -n "$warnings" ]; then
	echo "web_drive: the browser warned about WebGL:" >&2
	echo "$warnings" | head -10 >&2
	status=1
fi
[ "$status" = 0 ] && echo "web_drive: ok" || echo "web_drive: failed; see $out" >&2
exit "$status"
