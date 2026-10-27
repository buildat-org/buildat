#!/bin/bash
# A web archive on a bare box ([LINUX_SERVER] in
# doc/plan/packaging_plan.md):
#
#   util/smoke_web_archive.sh Build/package/out/buildat-*-web.tar.gz
#
# Unpacks it in debian:bookworm-slim with nothing added but libcurl4 --
# and build-essential for the "web" archive, which compiles the apps on
# the box; the "web-precompiled" one has to start with no compiler and
# compile nothing -- starts apps/floorplanner there, and checks from
# outside with util/test_web_transport.py that it serves the web client's
# page and WebSocket and a native client's TCP. Needs docker, and python3
# with websockets on the host. util/package_in_docker.sh runs it.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
archive=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
port="${PORT:-$(( 29400 + (RANDOM % 90) ))}"
name="buildat-web-smoke-$$"
case "$archive" in
	*-web-precompiled.tar.gz) packages="libcurl4"; precompiled=1 ;;
	*-web.tar.gz) packages="libcurl4 build-essential"; precompiled= ;;
	*) echo "not a web archive: $archive" >&2; exit 2 ;;
esac
log=$(mktemp /tmp/buildat_smoke_web_archive.XXXXXX)
cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT
echo "smoke: $(basename "$archive") in debian:bookworm-slim with $packages, port $port"
# simplified: the image by tag and the packages unpinned; a bare box of the
# day is what the archive meets
docker run -d --name "$name" -p "127.0.0.1:$port:29500" \
	-v "$(dirname "$archive"):/a:ro,z" debian:bookworm-slim bash -c "
		set -e
		apt-get update -qq && apt-get install -y -qq --no-install-recommends $packages >/dev/null
		mkdir /srv/b && tar -C /srv/b -xzf /a/$(basename "$archive") && cd /srv/b/*/
		echo compiler: \$(command -v c++ || echo none)
		exec bin/buildat_server -m apps/floorplanner -l 3
	" >/dev/null
for i in $(seq 1 900); do
	docker logs "$name" > "$log" 2>&1 || true
	grep -q "Listening at" "$log" && break
	if [ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != true ]; then
		echo "smoke: the server stopped; its log's end:" >&2; tail -30 "$log" >&2; exit 1
	fi
	sleep 1
done
grep -q "Listening at" "$log" || { echo "smoke: no Listening in 900 s" >&2; tail -30 "$log" >&2; exit 1; }
python3 "$here/util/test_web_transport.py" "127.0.0.1:$port"
# [WEB_LOCAL_SERVER] An app's own server for the page is there, and its
# page and files are served cross-origin isolated
# simplified: hillclimb's alone, of util/package.sh's WEB_LOCAL_APPS
for u in "/?local=hillclimb" /local/hillclimb/buildat_server.wasm; do
	h=$(curl -s -m 30 -D - -o /dev/null "http://127.0.0.1:$port$u" | tr -d '\r')
	echo "$h" | grep -q "^HTTP/1.1 200" &&
		echo "$h" | grep -qi "^Cross-Origin-Embedder-Policy: require-corp" ||
		{ echo "smoke: $u not served isolated: $(echo "$h" | head -1)" >&2; exit 1; }
done
echo "smoke: web/local/hillclimb served isolated"
# **And the page runs** ([WEB_BLANK]): the transport test passed the 0.5.67
# web client, which came up black -- its scripts raised in the browser's
# Lua. A headless browser loads the page: the game's first script has to
# run, and nothing may fail to. Chrome where there is one, since it draws
# with SwiftShader where there is no GPU (a CI runner, where Firefox's
# WebGL could not make a context); else Firefox. Needs Node 22
# (web_drive.sh); without a browser or it CI fails, and a desk says so and
# goes on.
node_major=$(node --version 2>/dev/null | sed -n 's/^v\([0-9]*\).*/\1/p')
browser=""
if command -v "${CHROME:-google-chrome}" >/dev/null 2>&1; then
	browser=chrome
elif command -v firefox >/dev/null 2>&1; then
	browser=firefox
fi
if [ -n "$browser" ] && [ "${node_major:-0}" -ge 22 ]; then
	page_out=$(mktemp -d /tmp/buildat_smoke_web_page.XXXXXX)
	if ! WEB_DRIVE_URL="http://127.0.0.1:$port/" "$here/util/web_drive.sh" \
			"$browser" floorplanner "$here/util/web_page_smoke.json" "$page_out" ||
			grep -aq "Failed to run" "$page_out/page.log"; then
		echo "smoke: the web client's page did not run its scripts:" >&2
		grep -a "Failed to run\| E \|rror" "$page_out/page.log" | head -10 >&2
		[ -n "${SMOKE_LOG:-}" ] && cp "$page_out"/*.log "$(dirname "$SMOKE_LOG")/" 2>/dev/null || true
		# A failure on CI too: Chrome's "invalid HTTP response" there
		# (0.5.69, 0.5.70, 0.6.105) was its preconnect taken for a native
		# client ([WEB_SNIFF_PRECONNECT])
		exit 1
	fi
	# A failed page on CI has no screenshot
	if [ -n "${SMOKE_LOG:-}" ] && [ -f "$page_out/page.png" ]; then
		cp "$page_out/page.png" "$(dirname "$SMOKE_LOG")/page.png"
	fi
	# Chrome may still be writing its profile as it goes
	rm -rf "$page_out" 2>/dev/null || true
	echo "smoke: the web client's page ran its scripts in $browser"
elif [ -n "${CI:-}" ]; then
	echo "smoke: no browser or no Node 22 here, and the page is not checked" >&2
	exit 1
else
	echo "smoke: no browser or no Node 22 here; the page itself is not checked"
fi
docker logs "$name" > "$log" 2>&1 || true
if [ -n "$precompiled" ]; then
	grep -q "No C++ compiler (c++) found" "$log" ||
		{ echo "smoke: the box had a compiler?" >&2; exit 1; }
	if grep -q "STATUS Compiling" "$log"; then
		echo "smoke: something compiled on a box with no compiler:" >&2
		grep "STATUS Compiling" "$log" >&2; exit 1
	fi
else
	grep -q "STATUS Compiling main" "$log" ||
		{ echo "smoke: the game's module was not compiled on the box" >&2; exit 1; }
fi
[ -n "${SMOKE_LOG:-}" ] && cp "$log" "$SMOKE_LOG"
rm -f "$log"
echo "smoke passed: $(basename "$archive") serves browsers and native clients on a bare box"
