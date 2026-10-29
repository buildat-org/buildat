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
# simplified: the copy was made once by hand (a tar of this tree, the
# absolute symlinks into it repointed; ~/emsdk and Playwright's WebKit
# copied); a new machine needs that first, and Xvfb and Chromium installed.
# The machine's own RAM: check_lib's limits apply there as here.
set -eu
[ $# -ge 2 ] || { sed -n '2,8p' "$0" | sed 's/^# *//' >&2; exit 2; }
host=$1; shift
dir=${REMOTE_DIR:-buildat_remote}
cd "$(dirname "$0")/.."
git push -q -f "$host:$dir" HEAD:refs/heads/remote_check
ssh -o BatchMode=yes "$host" "cd $dir && git reset -q --hard remote_check"
tar c --exclude=CMakeFiles --exclude='*.o' Build/bin Build/lib web \
		Build-webserver 3rdparty/Urho3D/Build/lib |
	ssh -o BatchMode=yes "$host" "tar x -C $dir"
q=$(printf ' %q' "$@")
exec ssh -o BatchMode=yes "$host" "cd $dir &&
	export LD_LIBRARY_PATH=\$PWD/3rdparty/Urho3D/Build/lib
	export CHROME=\${CHROME:-chromium-browser}
	export BUILDAT_STARPORT_DEFAULT=https://127.0.0.1:9
	exec xvfb-run -a -s '-screen 0 1920x1080x24' $q"
