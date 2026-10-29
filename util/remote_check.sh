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
# lib) by tar over ssh; what is not committed does not go. REMOTE_DIR is
# the copy, ~/buildat_remote by default.
#
# **The machine** (made once; the script only keeps it current):
# - Xvfb and Mesa (software GL); Chromium (CHROME when its binary is not
#   chromium-browser: Debian's is chromium); Firefox 129 or newer (FIREFOX:
#   Debian's is firefox-esr); Node 22 or newer (web_drive.js's WebSocket;
#   Debian 13 has 20); c++ (servers compile their modules at start); CMake
#   3.x (CMake 4 refuses cmake_minimum_required(VERSION 3.2.3)); python3
#   with PIL, numpy, websockets and cryptography; zip, unzip, ImageMagick;
#   zstd; ~/emsdk at the release's version.
# - glibc and libstdc++ at least this machine's: the binaries are copied,
#   not built there. `ldd Build/bin/* ~/projects/luanti/bin/* | grep "not
#   found"` there says what is missing (2026-10-29: GLIBC_2.38,
#   GLIBCXX_3.4.32); a distro may name a library otherwise (Debian's
#   leveldb is .so.1d: a libleveldb.so.1 link).
# - The copy into REMOTE_DIR, by tar | zstd | ssh (about 5.5 GB, 15 min on
#   a LAN): this tree without Build*, cache, local, tmp, .claude and
#   user/screenshots; 3rdparty/Urho3D/Build without objects (module
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
set -eu
[ $# -ge 2 ] || { sed -n '2,8p' "$0" | sed 's/^# *//' >&2; exit 2; }
host=$1; shift
dir=${REMOTE_DIR:-buildat_remote}
cd "$(dirname "$0")/.."
git push -q -f "$host:$dir" HEAD:refs/heads/remote_check
ssh -o BatchMode=yes "$host" "cd $dir && git reset -q --hard remote_check"
# About 390 MB of builds, 136 MB through zstd
tar c --exclude=CMakeFiles --exclude='*.o' Build/bin Build/lib web \
		Build-webserver 3rdparty/Urho3D/Build/lib | zstd -q -T0 -3 |
	ssh -o BatchMode=yes "$host" "zstd -q -dc | tar x -C $dir"
q=$(printf ' %q' "$@")
exec ssh -o BatchMode=yes "$host" "cd $dir &&
	export LD_LIBRARY_PATH=\$PWD/3rdparty/Urho3D/Build/lib
	export CHROME=\${CHROME:-chromium-browser}
	export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
	exec xvfb-run -a -s '-screen 0 1920x1080x24' $q"
