#!/bin/bash
# tier: full
# cost: ~40 s (2026-10-10)
# covers: src/server/main.cpp src/impl/fs.cpp
# [USER_DIR_COPY]: an Aitta whose admin came from first_admin, running.
#   1. <user>/apps/aitta/save_now written: gone within seconds, the log
#      saying saving and saved.
#   2. The user directory copied with cp -a while it runs, a second
#      server started on the copy: the admin account came along (no setup
#      code), and its health token is the first one's.
#
#   util/user_dir_copy_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
check_tmp user_dir_copy; t=$CHECK_TMP
trap check_cleanup EXIT
cd "$here/Build"
mkdir -p "$t/a"
echo "name admin checkpass1" > "$t/a/first_admin"
start_server "$t/a.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/a" -l 3 || fail "Aitta did not start"
CHECK_PIDS+=($SERVER_PID)

# 1.
touch "$t/a/apps/aitta/save_now"
for _i in $(seq 50); do [ -e "$t/a/apps/aitta/save_now" ] || break; sleep 0.2; done
[ ! -e "$t/a/apps/aitta/save_now" ] && grep -aq "save_now: saved" "$t/a.log" ||
	fail "save_now ($t/a.log)"
echo "ok: save_now taken and removed"

# 2.
cp -a "$t/a" "$t/b"
start_server "$t/b.log" "Listening at" 120 auto \
	bin/buildat_server -m ../apps/aitta -D "$t/b" -l 3 || fail "the copy did not start"
CHECK_PIDS+=($SERVER_PID)
# The setup code's absence: nothing logs it, so a settle for the
# accounts module's start
sleep 2
grep -aq "setup code" "$t/b.log" && fail "the copy has no admin ($t/b.log)"
cmp -s "$t/a/apps/aitta/health_token.txt" "$t/b/apps/aitta/health_token.txt" ||
	fail "the health token"
grep -aqi "error\|corrupt\|malformed" "$t/b.log" && fail "the copy's log ($t/b.log)"
echo "ok: a server on the copy has the admin and the token"

echo "PASS"
