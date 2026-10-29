#!/bin/bash
# A check, or run_all, on another Linux machine: this tree's commit and its
# builds there, the command under Xvfb, its output here.
#
#   util/remote_check.sh <host> <command...>
#   util/remote_check.sh buildbox util/serverless_check.sh
#   util/remote_check.sh buildbox env TIER=full util/run_all.sh --changed v0.7.95..HEAD
#
# The commit goes by git push (to refs/heads/remote_check, the copy reset
# to it); the builds (Build/bin and lib, web/, Build-webserver/, Urho3D's
# lib) by tar over ssh; what is not committed does not go. CHROME and
# FIREFOX name the browsers there (chromium-browser and firefox);
# REMOTE_DIR is the copy, ~/buildat_remote by default.
# **Slots** (REMOTE_SLOTS, 2 by default): REMOTE_DIR and its git worktrees
# REMOTE_DIR_2...; a run takes the first free one (a flock there for the
# run's length) and waits while all are busy. A slot is a worktree of the
# first (`git worktree add --detach`) with 3rdparty/Urho3D's ignored files
# (its builds, Assimp) copied in and the absolute symlinks repointed into
# it: the sandboxed server reads nothing through a link out of its root.
# A check with a fixed port (apps/aitta/check.sh) clashes with itself in
# another slot.
#
# **The machine** (made once; the script only keeps it current):
# - Xvfb and Mesa (software GL); Chromium (CHROME when its binary is not
#   chromium-browser: Debian's is chromium); Firefox 129 or newer (FIREFOX:
#   Debian's is firefox-esr); Node 22 or newer (web_drive.js's WebSocket;
#   Debian 13 has 20); c++ (servers compile their modules at start); CMake
#   3.x (CMake 4 refuses cmake_minimum_required(VERSION 3.2.3) unless
#   CMAKE_POLICY_VERSION_MINIMUM=3.5 is set); python3
#   with PIL, numpy, websockets and cryptography; zip, unzip, ImageMagick;
#   zstd; luajit (the apps' Lua parse checks); sqlite3; ~/emsdk at the release's version;
#   xdotool and openbox for
#   builtin/luanti/test/focus.sh (minimize, activate: a window manager in
#   the run's Xvfb, started by this script when there is one).
# - glibc and libstdc++ at least this machine's: the binaries are copied,
#   not built there. `ldd Build/bin/* ~/projects/luanti/bin/* | grep "not
#   found"` there says what is missing (2026-10-29: GLIBC_2.38,
#   GLIBCXX_3.4.32); a distro may name a library otherwise (Debian's
#   leveldb is .so.1d: a libleveldb.so.1 link).
# - The copy into REMOTE_DIR, by tar | zstd | ssh (about 5.5 GB, 15 min
#   from a home connection): this tree without Build*, cache, local, tmp,
#   .claude and user/screenshots; 3rdparty/Urho3D/Build without objects (module
#   compiles need its headers, which this script does not send);
#   ~/projects/luanti without its worlds and .git (its games/ are what the
#   Luanti checks use); ~/.local/share/playwright-node and
#   ~/.cache/ms-playwright, then `playwright install-deps webkit` and
#   `cp -an libs/. <webkit>/minibrowser-gtk/sys/lib/` (ICU 74, libjpeg8);
#   ~/emsdk.
# - Urho3D's include tree and others are absolute symlinks into
#   ~/projects/buildat: with the same user and home, one link
#   ~/projects/buildat -> REMOTE_DIR covers them all. Where that path is
#   taken (another copy of the tree there), repoint the links instead: the
#   sandboxed server reads nothing through a link out of its root.
# **Host-sensitive checks**: timing limits (web_join_check), short-lived
# screenshots (particle_draw_check) and server-start timeouts (lan_check)
# fail more on a slower or software-GL machine; run them here before
# blaming the code. The machine's own RAM: check_lib's limits apply there
# as here unless it has room to spare.
set -eu -o pipefail
[ $# -ge 2 ] || { sed -n '2,8p' "$0" | sed 's/^# *//' >&2; exit 2; }
host=$1; shift
base=${REMOTE_DIR:-buildat_remote}
slots=${REMOTE_SLOTS:-2}
cd "$(dirname "$0")/.."
# A slot, held for the whole run: a remote flock whose ssh stays open until
# this script ends (its stdin closing lets the lock go, a dead ssh too)
take_slot(){
	coproc LOCK { ssh -o BatchMode=yes "$host" "
		for i in \$(seq $slots); do
			d=$base; [ \$i = 1 ] || d=${base}_\$i
			[ -d ~/\$d ] || continue
			exec 9> ~/\$d/.remote_check.lock
			if flock -n 9; then echo \$i \$d; cat > /dev/null; exit; fi
		done
		echo busy"; }
	read -r slot dir <&"${LOCK[0]}" || slot=busy
}
take_slot
while [ "$slot" = busy ]; do
	echo "remote_check: every slot on $host is busy; waiting" >&2
	sleep 20
	take_slot
done
echo "remote_check: $host:$dir" >&2
# The commit into the slot's repository (the first slot's; the others
# are its worktrees), a branch a slot
git push -q -f "$host:$base" HEAD:refs/heads/remote_check_$slot
ssh -o BatchMode=yes "$host" "cd $dir && git reset -q --hard remote_check_$slot"
# About 390 MB of builds, 136 MB through zstd
tar c --exclude=CMakeFiles --exclude='*.o' Build/bin Build/lib web \
		Build-webserver 3rdparty/Urho3D/Build/lib | zstd -q -T0 -3 |
	ssh -o BatchMode=yes "$host" "zstd -q -dc | tar x -C $dir"
q=$(printf ' %q' "$@")
ssh -o BatchMode=yes "$host" "cd $dir &&
	export LD_LIBRARY_PATH=\$PWD/3rdparty/Urho3D/Build/lib
	export CHROME=$(printf %q "${CHROME:-chromium-browser}")
	export FIREFOX=$(printf %q "${FIREFOX:-firefox}")
	export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
	exec xvfb-run -a -s '-screen 0 1920x1080x24' bash -c '
		if command -v openbox > /dev/null; then
			openbox > /dev/null 2>&1 & sleep 1
			export BUILDAT_FOCUS_X11=1  # a display of this run alone
		fi
		exec \"\$@\"' _ $q"
