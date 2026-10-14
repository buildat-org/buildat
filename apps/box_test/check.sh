#!/bin/bash
# tier: quick
# cost: 10s (a first run compiles the app, 2026-10-02)
# covers: src/server/confine.cpp src/server/main.cpp apps/box_test/**
# [PROCESS_SANDBOX]: **the hostile app**. apps/box_test spends its start
# trying to reach past the server's box -- $HOME, a file outside it,
# another app's directories and cache, the shared module build, the D-Bus
# and X11 sockets, the parent process -- and says how many got through,
# and whether its own save and shared directory still work. PASS is none
# through and its own working, with the box's own log line there.
#
#   apps/box_test/check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/box_test"
rm -rf "$out"; mkdir -p "$out/user/apps/vanilla" "$out/user/shared/vanilla"
# A link back above the user path, which the box's rules are cut around:
# it recursed without end and the server died at start ([SEC_RUN5_LEFTOVERS])
ln -s .. "$out/loop"
# A file the box must not read: outside the user path, the cache and the
# install, which is where everything of the user's is. Not under local/:
# in the development tree that is the install directory, which the box
# reads.
secret_dir=$(mktemp -d)
trap 'rm -rf "$secret_dir"' EXIT
echo "secret" > "$secret_dir/secret"
cd "$here/Build"
BUILDAT_BOX_TEST_SECRET="$secret_dir/secret" timeout 300 bin/buildat_server \
	-m ../apps/box_test -D "$out/user" -P 29871 -l 3 > "$out/srv.log" 2>&1
if ! grep -aq "The server is sandboxed" "$out/srv.log"; then
	echo "FAIL: the server was not boxed --" \
			"$(grep -a "sandbox could not\|confine" "$out/srv.log" | head -1)"
	exit 1
fi
line=$(grep -a "box_test: .* reaches tried" "$out/srv.log" | tail -1 |
	sed 's/.*box_test: //')
echo "${line:-(the hostile app said nothing)}"
tried=$(echo "$line" | sed -n 's/^\([0-9]*\) reaches tried.*/\1/p')
# **Its own canary**: a list that shrank to nothing would read as a pass
if [ "${tried:-0}" -lt 22 ]; then
	echo "FAIL: only ${tried:-0} reaches were tried"
	exit 1
fi
if ! echo "$line" | grep -q " 0 got through"; then
	echo "FAIL: the hostile app reached past the sandbox"
	exit 1
fi
if ! echo "$line" | grep -q "its own files work"; then
	echo "FAIL: the sandbox keeps the app from its own files"
	exit 1
fi
echo "PASS: a hostile app reaches nothing past the sandbox, and its own files work"
exit 0
# vim: set noet ts=4 sw=4:
