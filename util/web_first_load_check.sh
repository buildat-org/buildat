#!/bin/bash
# tier: full
# ci
# cost: ~20s (2026-10-04)
# covers: builtin/network/network.cpp
# [SELECT_BAD_FD], the second half: the first page load after a start
# deflated the wasm and the data in the network module, about a second
# each, and every peer waited on it -- a page's other requests, the game's
# clients. Now the copies are made on threads of their own, and a file
# goes as it is until its copy is ready.
# A fresh server; the data asked for with deflate, and beside it the page,
# which must come at once. The data is a generated 60 MB, so that its
# deflate takes seconds on any machine, as the real one does on a small
# server's CPU: on this desk the real files deflate in 0.2 s, which a
# stalled page load does not stand out from.
# Needs web/ from util/build_web.sh.
#   util/web_first_load_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -f "$here/web/buildat.wasm" ] || skip "no web/ (util/build_web.sh)"
t=$(mktemp -d)
s=
trap '[ -n "$s" ] && kill $s 2>/dev/null; [ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
mkdir "$t/web"
for f in index.html buildat.js buildat.wasm; do ln -s "$here/web/$f" "$t/web/$f"; done
head -c 45000000 /dev/urandom | base64 > "$t/web/buildat.data"
cd "$here/Build"
P=29584
start_server "$t/srv.log" "STATUS Listening" 60 $P \
	bin/buildat_server -m ../apps/demo_digger -D "$t/srv" -W "$t/web" -l 3 ||
	fail "demo_digger did not start"
s=$SERVER_PID
u=http://127.0.0.1:$P
curl -s -m 20 -H "Accept-Encoding: deflate" -o "$t/data" $u/buildat.data &
c=$!
sleep 0.05 # the data's request in first, as a page load's would be
page=$(curl -s -m 20 -o "$t/index" -w "%{time_total}" $u/index.html)
wait $c
[ "$(stat -c %s "$t/data")" -gt 1000000 ] || fail "the data did not come"
grep -q "<title>" "$t/index" || fail "the page did not come"
awk "BEGIN{exit !($page < 0.3)}" ||
	fail "the page took $page s beside the first data download"
echo "PASS: the page in $page s beside the first data download"
