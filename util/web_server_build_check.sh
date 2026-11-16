#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~5 min (2026-11-16)
# drives: builtin/*/api.h *_web.cpp src/interface/** src/server/web/** util/web_server.cmake util/build_web_server.sh CMakeLists.txt
# [WEB_SERVER_BUILD_UNCHECKED] The web servers util/package.sh ships (its
# WEB_LOCAL_APPS), each built by util/build_web_server.sh as the package
# run does: alpha.26's package failed on builtin/accounts/accounts_web.cpp
# lacking a pure virtual api.h had gained, which nothing built before
# then. On a "drives:" line, not "covers:", so that --changed picks it for
# those files whatever it costs (a cheaper runner covers most of them). It
# writes Build-webserver/ and web/local/<app>/, as util/build_web_server.sh
# does. Needs emsdk as util/build_web_server.sh does.
#   util/web_server_build_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "${EMSDK:-$HOME/emsdk}/emsdk_env.sh" ] || skip "no emsdk"
apps=$(sed -n 's/^WEB_LOCAL_APPS="\(.*\)"$/\1/p' "$here/util/package.sh")
[ -n "$apps" ] || fail "no WEB_LOCAL_APPS in util/package.sh"
check_tmp web_server_build; t=$CHECK_TMP
for a in $apps; do
	from=$a
	[ "$a" = _aitta ] && from=$here/src/server/web/_aitta
	"$here/util/build_web_server.sh" "$from" -j "${WEB_SERVER_JOBS:-6}" \
		> "$t/$a.log" 2>&1 ||
		fail "the web server of $a did not build ($(grep -m3 -E 'error|Error' "$t/$a.log" || tail -3 "$t/$a.log"))"
	echo "$a: built"
done
echo "PASS: the web servers of $apps built"
