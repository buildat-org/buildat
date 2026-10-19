#!/bin/bash
# tier: full
# cost: 30s (2026-10-09)
# covers: client/core/aitta/publish.lua
# [PUBLISH_FILES]: the publish page's "Goes in" files, every one, a line
# each, in a list the wheel scrolls. A copy of Genvaders with 50 more files
# in a scratch user directory, its page 2, the wheel a page at a time:
# every file but aitta_page/ (which pack leaves out) is read inside the list
# in some scan (a scan leaves out what is below the screen), the last one
# at the end, and Pack and publish is under the list in the window.
# Screenshots in $t (KEEP_TMP=1 keeps it).
#
#   util/publish_files_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
t=$(mktemp -d)
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $t" || rm -rf "${t:?}"' EXIT
fail(){ echo "FAIL: $*"; KEEP_TMP=1; exit 1; }
a=$t/u/dev_apps/genvaders
mkdir -p "$t/u/dev_apps"
cp -r "$here/user/dev_apps/genvaders" "$a" 2>/dev/null ||
	skip "no user/dev_apps/genvaders"
rm -rf "$a/.git"
mkdir -p "$a/many"
for i in $(seq -w 1 50); do echo x > "$a/many/f$i.txt"; done
want=$(cd "$a" && find . -type f ! -path '*/.*' ! -path './aitta_page/*' | wc -l)
# A page of the list at a time: 4 wheel clicks of 44 px are its 8 rows;
# the 300 ms after them is the list moved before its scan
cat > "$t/p.cmds" <<C
wait_log_any 30000 rows in
text Publish an
wait_log 10000 rows for "Publish an"
keypress Return
wait_log 10000 aitta publish: the package page
click Button "Next: key and publish"
wait_log 10000 aitta publish: the key page
delay 500
screenshot $t/top.png
event scan
mouse_pos 550 560
$(for _ in $(seq 14); do printf 'mouse_wheel -1\nmouse_wheel -1\nmouse_wheel -1\nmouse_wheel -1\ndelay 300\nevent scan\n'; done)
screenshot $t/end.png
quit
C
cd "$here/Build"
timeout 90 bin/buildat -o launch_ui=launch_menu -w 1100x900 -l 3 \
	-o sound_mute=1 -C "$t/c" -D "$t/u" -c @"$t/p.cmds" > "$t/log" 2>&1
grep -aq "Command sequence complete" "$t/log" ||
	fail "the drive ($(grep -a "Command seq\|rror" "$t/log" | tail -2))"
# The list: 8 rows of 22 px from where the first file is before a scroll
first=$(cd "$a" && find . -type f ! -path '*/.*' ! -path './aitta_page/*' | sed 's|^\./||' | LC_ALL=C sort | head -1)
top=$(awk -v s="text \"$first\"" '/^scan scan: ui +Text at/ && index($0, s){split($6, p, ","); print p[2]; exit}' "$t/log")
[ -n "$top" ] || fail "no row for $first"
# Every name seen inside the list in some scan
seen=$(awk -v top="$top" '/^scan scan: ui +Text at/{split($6, p, ",")
	if(p[2] >= top && p[2] < top + 8 * 22){sub(/.*text "/, ""); sub(/"$/, ""); print}}' "$t/log" | LC_ALL=C sort -u)
missing=$(cd "$a" && find . -type f ! -path '*/.*' ! -path './aitta_page/*' | sed 's|^\./||' | LC_ALL=C sort | LC_ALL=C comm -23 - <(echo "$seen" | LC_ALL=C sort))
[ -z "$missing" ] || fail "not read in the list: $(echo $missing | head -c 300)"
# The last scan's last file, inside the list
last=$(awk '/^scan scan: ui +Text at .* text "many\/f50.txt"/{split($6, p, ","); y = p[2]} END{print y}' "$t/log")
[ -n "$last" ] && [ "$last" -ge "$top" ] && [ "$last" -lt $((top + 8 * 22)) ] ||
	fail "the last file not in the list at the end (y $last, the list from $top)"
pack=$(awk '/^scan scan: ui +Text at .* text "Pack and publish"/{split($6, p, ","); y = p[2]} END{print y}' "$t/log")
[ -n "$pack" ] && [ "$pack" -gt $((top + 8 * 22)) ] && [ "$pack" -lt 900 ] ||
	fail "Pack and publish not under the list in the window (y $pack)"
echo "PASS: all $want files read in the list, scrolled to the last, the buttons under it"
