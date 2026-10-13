#!/bin/bash
# tier: quick
# cost: 3s (llvmpipe in a container, 2026-09-24; local/run_all/costs corrects it per machine)
# covers: client/sandbox.lua client/api.lua client/extensions/urho3d/** src/lua_bindings/**
# (client/api.lua is the sandbox's own surface -- every verb this check
# tries to reach past, and the ones wrapped.lua exercises)
# [LAUNCH_SANDBOX]: **the hostile launch UI**. The launch UI is a slot
# anybody can fill, so what has to be true is that what fills it cannot
# reach past the verbs. extensions/sandbox_test is a launch UI that
# spends its boot trying: the standard libraries, the client's trusted
# API, and every verb asked for more than it gives. Prints the count and
# PASS or FAIL.
#
#   extensions/sandbox_test/check.sh
#
# The client is driven by a command sequence and takes no mouse or
# keyboard from the desk it shares.
set -u
. "$(dirname "$0")/../../util/check_paths.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/sandbox_test"; mkdir -p "$out"
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi
# "q" pressed on the launch UI, then "w" and "e" into the Starport ID
# dialog's fields (the overlay's "Starport ID..." at the top right). The
# safe tests' meshes and broken images log Urho3D errors on purpose. The
# half second at the end is the frames a poll of w or e would be logged
# in; a "polled" line is what the verdict below looks for.
cat > "$out/cmds.txt" <<EOF
expect_error Used vertex range can only be queried
expect_error Could not load texture from image resource
wait_log_any 30000 reaches tried
keypress q
wait_log 5000 launch sandbox: polled q
mouse_pos 542 9
mouse_click left
wait_log 5000 starport: the ID login shown
keypress w
keypress Tab
keypress e
delay 500
quit
EOF
bin/buildat -m sandbox_test -w 640x360 -l 3 \
	-c @"$out/cmds.txt" > "$out/cli.log" 2>&1 ||
	fail "the drive ($out/cli.log): $(grep -ao 'Command sequence failed.*' "$out/cli.log" | head -1)"
if grep -aq "Crash: SIG" "$out/cli.log"; then
	echo "FAIL: the client crashed --" \
			"$(grep -a "Crash: SIG" "$out/cli.log" | head -1)"
	exit 1
fi
# **And what the whitelist does let through works** ([URHO_SWEEP]): the
# same boot runs tests/safe.lua, so a class wrapped and silently doing
# nothing is a failure here rather than a surprise in a game
safe=$(grep -ac "launch sandbox: the safe tests passed" "$out/cli.log")
if [ "$safe" -lt 1 ]; then
	echo "FAIL: the safe tests did not pass --" \
			"$(grep -a "safe.lua\|the safe tests" "$out/cli.log" | tail -2 |
				tr '\n' ' ')"
	exit 1
fi
line=$(grep -a "launch sandbox: .* reaches tried" "$out/cli.log" | tail -1 |
	sed 's/.*sandbox_[a-z]*: //')
echo "${line:-(the hostile launch UI said nothing)}"
if [ -z "$line" ]; then
	echo "FAIL: the hostile launch UI did not run"
	exit 1
fi
# **Its own canary**: a check that cannot fail is not a check. The file
# is asserted to still hold every attempt it was written with, so a
# refusal that became an empty list would not read as a pass.
tried=$(echo "$line" | sed -n 's/.*: \([0-9]*\) reaches tried.*/\1/p')
tried=${tried:-$(echo "$line" | sed -n 's/^\([0-9]*\) reaches tried.*/\1/p')}
if [ "${tried:-0}" -lt 20 ]; then
	echo "FAIL: only ${tried:-0} reaches were tried; the attack list shrank"
	exit 1
fi
if ! echo "$line" | grep -q "0 got through"; then
	echo "FAIL: a launch UI reached past the verbs -- $line"
	exit 1
fi
# **Polling the keys** ([SANDBOX_API_AUDIT]): the attack's Update handler
# saw "q", so the poll works; "w" and "e" went into the client's own
# fields, which nobody else hears, by event or by GetKeyPress
if ! grep -aq "sandbox_.*: launch sandbox: polled q" "$out/cli.log"; then
	echo "FAIL: the key poll did not see q on the launch UI"
	exit 1
fi
if grep -aq "launch sandbox: polled [we]" "$out/cli.log"; then
	echo "FAIL: a script polled a key typed into the Starport ID dialog"
	exit 1
fi
# vim: set noet ts=4 sw=4:
echo "PASS: a hostile launch UI reaches nothing past the verbs, and polls no key typed into the Starport ID dialog"
exit 0
