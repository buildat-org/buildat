#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# [NO_SOUND] / [ROOM_SOUND]: **does a sound the server asks for reach
# the mixer**. Nothing in this tree could hear, so a room that placed no
# listener played into nowhere until somebody noticed.
#
#   builtin/luanti/test/sound.sh
#
# sound.lua asks for three sounds every four seconds through
# core.sound_play(), which is the one thing that is unambiguously a
# packet.
#
# **Digging and placing do play** (measured 2026-09-25, against this
# file's own earlier note that they were not implemented at all): the
# vendored builtin's node_dig and item_place call core.sound_play with
# the node's `dug` and `place`, and predict.sh's run has the
# luanti:sound packet to show for it. **Footsteps are the ones official
# Luanti plays in its engine** off the player's movement, which nothing
# here did until 2026-09-25; builtin/luanti/test/footstep.sh is that
# one's check.
#
# **No device is opened at all** (the user's rule, 2026-09-24: no
# default script may put audio on the system's actual hardware; only
# when asked, and only for that run). SDL_AUDIODRIVER=disk with
# SDL_DISKAUDIOFILE writes the mix to a file instead -- SDL's disk
# driver is compiled in here -- so there is nothing to leak to the
# speakers, nothing to race another check for the sink, and nothing
# that needs PipeWire running, which is what also makes this work in
# the packaging container.
#
# **SDL_DISKAUDIODELAY stays unset**: at 0 the mixer runs flat out and
# writes 1.4 GB in nine seconds; unset, it writes in real time.
#
# **-o sound_mute=0**: a -c run is muted on purpose (app.cpp:1028, "a
# driven run playing a game's music through the developer's speakers"),
# and with the disk driver there are no speakers to play through.
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/sound"; mkdir -p "$out"
save=buildat_test_sound
port=31998
cd "$here/Build"
[ -d "$BUILDAT_USER_PATH/shared/vanilla/games/devtest" ] || {
	echo "SKIP: devtest is not installed" >&2; exit 77; }
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat server or client is already running" >&2; exit 77
fi
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=$save \
	BUILDAT_LUANTI_LUA="$me/sound.lua" \
	start_server "$out/srv.log" "Running world" 120 "$port" \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -l 3 ||
	[ $? = 1 ] || exit 1 # its own verdict below
srv=$SERVER_PID
if ! grep -aq "Running world" "$out/srv.log"; then
	echo "SKIP: the world did not come up"; kill -9 "$srv" 2>/dev/null; exit 77
fi
# The client only has to stay on; the shell kills it once it has listened
{ echo "delay 90000"; echo "quit"; } > "$out/cmds.txt"
rm -f "$out/mix.raw"
SDL_AUDIODRIVER=disk SDL_DISKAUDIOFILE="$out/mix.raw" \
	timeout 200 bin/buildat -s localhost:"$port" -o sound_mute=0 \
	-w 640x400 -l 3 -L "$out/cli.log" -c @"$out/cmds.txt" > /dev/null 2>&1 &
cli=$!
# The join is a minute of world loading away; the fixture then asks
# every four seconds, so the measurement only has to land inside that
for i in $(seq 1 600); do
	grep -aq "sound check: three asked" "$out/srv.log" && break
	kill -0 "$cli" 2>/dev/null && kill -0 "$srv" 2>/dev/null || break
	sleep 0.2
done
# The disk driver writes the mix in real time: the sounds asked for (3 s
# long) are in the file's tail only after they have played
sleep 6
# **The tail of the mix, not the whole of it**: the client's first
# seconds are silent while it loads, and averaging those in is how a
# level gets read as nothing ([ROOM_SOUND]). A peak needs no rate or
# channel count to be right -- the file is raw 16-bit.
peak=$(python3 - "$out/mix.raw" <<'PYEOF'
import sys, array, os
WINDOW = 4 * 1024 * 1024
try:
    n = os.path.getsize(sys.argv[1])
    take = min(n, WINDOW) // 2 * 2
    with open(sys.argv[1], "rb") as f:
        f.seek(n - take)
        a = array.array("h")
        a.frombytes(f.read(take))
    print(max(max(a), -min(a)) if a else 0)
except Exception:
    print(0)
PYEOF
)
kill -9 "$cli" 2>/dev/null; wait "$cli" 2>/dev/null
kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null
rm -rf "$BUILDAT_USER_PATH/apps/vanilla/saves/$save"
asked=$(grep -ac "sound check: three asked" "$out/srv.log")
echo "the server asked $asked times; the mix peaked at ${peak:-0}"
if [ ! -s "$out/mix.raw" ]; then
	echo "SKIP: the client wrote no mix; this SDL has no disk driver"
	exit 77
fi
if [ "$asked" -lt 1 ]; then
	echo "FAIL: the fixture never asked for a sound"
	exit 1
fi
if [ "${peak:-0}" -lt 200 ]; then
	echo "FAIL: a sound the server asked for came out as silence"
	exit 1
fi
echo "PASS: a sound the server asks for reaches the client's mixer"
