#!/bin/bash
# tier: quick
# cost: ~25 s (2026-10-08)
# covers: apps/starport/main/main.cpp
# [SP_AGE_FORM]: the Starport ID's web page asks "Are you 18 or over?"
# first. In headless Chrome, the page held to 360 px
# (apps/starport/test/age_form.js): the year hidden until No, and with No
# the consent on a line of its own above the buttons, which share one line
# unwrapped; No and 2015 without consent refused naming the consent; Yes
# makes the ID with no year sent; the settings' Age box the same.
#
#   apps/starport/age_form_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp starport_age; t=$CHECK_TMP
P=29886

cd "$here/Build"
start_server "$t/sp.log" "setup code" 120 $P \
	bin/buildat_server -m ../apps/starport -D "$t/sp" -l 3 ||
	fail "Starport did not start"
CHECK_PIDS+=($SERVER_PID)

# The half second after the page loads is its script's first frames
python3 -c 'import json, sys
print(json.dumps([["nav", "${URL}id"], ["wait", 500],
	["eval", open(sys.argv[1]).read()]]))' \
	"$here/apps/starport/test/age_form.js" > "$t/steps.json"
WEB_DRIVE_URL="http://127.0.0.1:$P/" "$here/util/web_drive.sh" chrome starport \
	"$t/steps.json" "$t/drive" > "$t/drive.txt" 2>&1 ||
	fail "the drive: $(tail -5 "$t/drive.txt")"
r=$(sed -n 's/^eval: //p' "$t/drive.txt" | python3 -c 'import json, sys; print(json.loads(sys.stdin.read()))')
echo "$r"
want="year shown before an answer: false
layout: ok
2015 without consent: consent: under 13, a parent's consent is needed
year hidden on Yes: true
Yes sent a year: false, settings shown: true
settings 2015 without consent: consent: under 13, a parent's consent is needed
settings Yes: Saved, a year sent: false, band: Now: 18+"
[ "$r" = "$want" ] || fail "the page said otherwise than: $want"
echo "PASS: the age asked as 18 or over first, the year only on a No, the consent and the buttons each on their own line at 360 px"
