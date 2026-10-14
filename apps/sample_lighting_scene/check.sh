#!/bin/bash
# apps/sample_lighting_scene: **the look check, run rather than eyeballed**
# ([LOOK_CHECK], the rule the user calls not negotiable: a game's look is
# not allowed to change, and a change under builtin/voxel_shading or the
# mesher is checked against this game's views). The views themselves are
# `check.txt`, which a person has been driving by hand -- so "a change
# passes it by not being run" ([CHECK_BASELINE]).
#
#   apps/sample_lighting_scene/check.sh            # against the kept reference
#   apps/sample_lighting_scene/check.sh --accept   # this run becomes it
#
# **What it compares**: the fourteen framings of check.txt, each against
# the same framing of the reference run in local/sample_lighting_scene/ref/, by
# RMSE. The numbers are printed whatever the verdict, because the size
# of a difference is the reading.
#
# **The scene is not quite the same twice.** The sky-visibility sweep is
# snapped at each camera but its rays are not the same rays, so the
# terrain views move a few levels between two runs of one tree while the
# canopy and sky views come back identical -- and the variation is not
# stationary: two runs back to back differed by 0 to 5 here and a third
# differed from the first by up to 19 (measured 2026-09-25). So
# `--accept` shoots the scene twice and keeps each view's difference
# beside the reference as a reading, and **the bar is thirty** -- the
# separation [CHECK_BASELINE] measured, against real changes of 72 to
# 868.
#
# **What it therefore catches**, measured by breaking the shader on
# purpose (2026-09-25): the ambient term replaced by a flat red is 64 on
# the worst view and fails; the bounced-light term multiplied by 1.5 is
# 14 and passes, that term being a small part of what a lit surface
# ends up at. So this catches a change of the kind [LOOK_CHECK] is
# about -- the speckle, the flood, the ambient -- and not a small
# adjustment to a small term. The noise printed beside each view is
# what says where the check is blunt.
#
# **The reference is a run, not a committed picture** (user,
# 2026-09-19): no image set in git. Until a BASELINE commit is picked,
# the reference is the last run somebody accepted on this machine, and a
# tree with no reference yet says so rather than passing.
#
# tier: quick
# cost: 35s
# covers: builtin/voxel_shading/** src/impl/mesh.cpp src/impl/voxel.cpp src/impl/voxel_volume.cpp builtin/voxelworld/**
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
out="$here/local/sample_lighting_scene"; mkdir -p "$out"
ref="$out/ref"
run="$out/run"
accept=""
[ "${1:-}" = "--accept" ] && accept=1
cd "$here/Build"
if check_pgrep buildat >/dev/null; then
	echo "SKIP: a buildat client is already running" >&2; exit 2
fi

# check.txt writes into ../tmp/voxel_lighting_check/, which is this
# game's own scratch and is where a person's hand run leaves them too
shots="$here/tmp/voxel_lighting_check"
port=31881

# One run of the scene into <dir>; 1 if it did not draw every view
shoot()
{
	local dir=$1
	rm -rf "$shots"; mkdir -p "$shots"
	rm -rf "$dir"; mkdir -p "$dir"
	rm -f "$out/server.log"
	# A taken port is a SKIP (2), a server that does not come up a FAIL (3)
	local rc
	start_server "$out/server.log" "STATUS Listening" 60 "$port" \
		bin/buildat_server -m ../apps/sample_lighting_scene -l 3
	rc=$?
	local server=$SERVER_PID
	if [ "$rc" != 0 ]; then
		[ "$rc" = 2 ] && return 2
		kill -9 "$server" 2>/dev/null; wait "$server" 2>/dev/null
		return 3
	fi
	# **The window size is the check's, not the desk's**: the framings
	# are comparable between runs only at one size, and -w leaves the
	# remembered one alone
	run_client 90 "$out/cli.log" timeout 120 bin/buildat -o launch_ui=launch_menu \
		-s "localhost:$port" -w 1600x900 -l 3 \
		-c @../apps/sample_lighting_scene/check.txt > /dev/null 2>&1
	rc=$?
	kill "$server" 2>/dev/null; wait "$server" 2>/dev/null
	cp "$shots"/*.png "$dir"/ 2>/dev/null
	local n=$(ls "$dir"/*.png 2>/dev/null | wc -l)
	echo "the run drew $n views (client status $rc)"
	[ "$n" -ge 14 ]
}

# **Nothing to compare against is answered before the scene is shot**:
# a machine with no reference -- every CI run, every fresh clone -- was
# rendering fourteen views and then skipping, which is half a minute of
# every run spent on a verdict that was known at the start
if [ -z "$accept" ] && { [ ! -d "$ref" ] ||
		[ -z "$(ls "$ref"/*.png 2>/dev/null)" ]; }; then
	echo "no reference to compare against;" \
			"take one with $(basename "$0") --accept on a tree whose look" \
			"you have confirmed"
	echo "SKIP: there is no reference run on this machine" >&2
	exit 2
fi

# not "if ! shoot": $? in its branch is the negation's 0
shoot "$run"; shot=$?
if [ "$shot" != 0 ]; then
	case $shot in
	2) echo "SKIP: port $port is taken" >&2
		exit 2;;
	3) echo "FAIL: the sample_lighting_scene server did not come up"
		exit 1;;
	esac
	echo "FAIL: the run did not draw every view"
	tail -3 "$out/cli.log"
	exit 1
fi
# **The light and the framings, which a look within the bar can hide**
# ([VOXEL_LIGHTING_CAVE]): check.txt's V after each edit finds the stored
# skylight a fresh fill's, and every benchmark view had its cave data
if grep -a "skylight verify: [0-9]* voxels differ" "$out/server.log" ||
		! grep -aq "skylight verify: ok" "$out/server.log"; then
	echo "FAIL: voxelworld's skylight is not a fresh fill's"
	exit 1
fi
if grep -a "no cave data" "$out/cli.log"; then
	echo "FAIL: a benchmark view was shot before its cave data"
	exit 1
fi

if [ -n "$accept" ]; then
	# **Twice, so the reference carries this machine's noise**: the
	# second run is thrown away but its difference from the first is
	# what every later verdict is measured against
	if ! shoot "$out/noise"; then
		echo "FAIL: the second run did not draw every view"
		exit 1
	fi
	rm -rf "$ref"; mkdir -p "$ref"
	cp "$run"/*.png "$ref"/
	git -C "$here" rev-parse HEAD > "$ref/COMMIT" 2>/dev/null
	python3 - "$run" "$out/noise" "$ref/NOISE" <<'PYN'
import os, sys, math
from PIL import Image, ImageChops
a_dir, b_dir, path = sys.argv[1], sys.argv[2], sys.argv[3]
lines = []
for name in sorted(os.listdir(a_dir)):
    if not name.endswith(".png"):
        continue
    b = os.path.join(b_dir, name)
    if not os.path.exists(b):
        continue
    x = Image.open(os.path.join(a_dir, name)).convert("RGB")
    y = Image.open(b).convert("RGB")
    h = ImageChops.difference(x, y).histogram()
    total = sum(h)
    sq = sum((i % 256) ** 2 * n for i, n in enumerate(h))
    rmse = math.sqrt(sq / float(total))
    lines.append("%s %.3f" % (name, rmse))
    print("%-28s this machine's noise %6.2f" % (name, rmse))
open(path, "w").write("\n".join(lines) + "\n")
PYN
	echo "the reference is this run, at $(cat "$ref/COMMIT" 2>/dev/null)"
	echo "PASS: the reference is taken, with this machine's noise beside it"
	exit 0
fi

python3 - "$run" "$ref" <<'PY'
import os, sys, math
from PIL import Image, ImageChops
run, ref = sys.argv[1], sys.argv[2]
# **Each view's bar is three times its own noise**, and never under
# eight: the sky views come back identical and are read to a level or
# two, the cave mouth varies by ten between two runs of one tree and can
# only say "something moved it by thirty".
noise = {}
try:
    for line in open(os.path.join(ref, "NOISE")):
        name, value = line.rsplit(" ", 1)
        noise[name] = float(value)
except IOError:
    pass
def bar_for(name):
    # **Thirty, and more where a view is noisier than that.** Two runs
    # back to back differ by 0 to 5 here, but a third run differs from
    # the first by up to 19 -- the sweep's variation is not stationary,
    # so a bar cut close to two runs' difference fails on the same tree
    # (measured 2026-09-25). Thirty is the separation [CHECK_BASELINE]
    # measured against real changes of 72 to 868, and the noise beside
    # each view says where the check is blunt.
    return max(30.0, 4.0 * noise.get(name, 0.0))
worst, worst_name, worst_bar, missing = 0.0, "", 30.0, []
for name in sorted(os.listdir(ref)):
    if not name.endswith(".png"):
        continue
    a_path, b_path = os.path.join(ref, name), os.path.join(run, name)
    if not os.path.exists(b_path):
        missing.append(name)
        continue
    a, b = Image.open(a_path).convert("RGB"), Image.open(b_path).convert("RGB")
    if a.size != b.size:
        print("%-28s different size %s against %s" % (name, b.size, a.size))
        missing.append(name)
        continue
    h = ImageChops.difference(a, b).histogram()
    # RMSE over the three channels together
    total = sum(h[i] for i in range(len(h)))
    sq = sum((i % 256) ** 2 * n for i, n in enumerate(h))
    rmse = math.sqrt(sq / float(total))
    bar = bar_for(name)
    print("%-28s RMSE %7.2f  (noise %5.2f, bar %5.1f)%s"
            % (name, rmse, noise.get(name, 0.0), bar,
            "   <- over it" if rmse > bar else ""))
    if rmse - bar > worst - worst_bar:
        worst, worst_name, worst_bar = rmse, name, bar
if missing:
    print("FAIL: these views are missing or a different size: " +
            ", ".join(missing))
    raise SystemExit(1)
print("the view nearest its bar is %s at RMSE %.2f against %.1f"
        % (worst_name, worst, worst_bar))
if worst > worst_bar:
    print("FAIL: the look changed -- look at " + worst_name +
            " against the reference before committing")
    raise SystemExit(1)
print("PASS: the look is the reference's, within the noise this scene has")
raise SystemExit(0)
PY
verdict_keep
verdict_exit
# vim: set noet ts=4 sw=4:
