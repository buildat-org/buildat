#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Runs every runner of a tier, one at a time, and says what each did
# ([CI_RUNS] (2)). The tier is named in the runner itself, on a
# "# tier:" line near the top:
#
#   quick  needs no downloaded game -- what a push runs
#   full   wants the game media (mineclone2, VoxeLibre)
#   long   the fuzz, the drives, the reference shots
#   broken a runner that fails for a reason of its own, not the code's
#          ([CHECKS_BROKEN_TIER]); its "# broken:" line says the tier it
#          goes back to and why. Run alone, or as this tier while it is
#          fixed, and in no other tier, --changed's picks included
#
#   ci     not a tier of its own: every runner with a "# ci" line
#          beside its tier line, whatever its tier -- what GitHub's
#          checks workflow runs ([CI_TIER]): devtest the one game
#          (util/media_fetch.sh devtest), nothing leaving the machine;
#          under BUILDAT_CI a client draws unlit and a "# needs: pixels"
#          or "# needs: network" runner skips (util/check_lib.sh)
#
#   util/run_all.sh quick
#   util/run_all.sh full --list
#   ONLY='keys.*|focus' util/run_all.sh quick
#
# **--changed [range] is the regular check** ([SMOKE_PICK]): it takes
# what git says changed and runs the cheapest runners that cover it,
# which is one runner under a minute for most commits. The whole tier
# is what a push runs.
#
#   util/run_all.sh --changed
#   util/run_all.sh --changed origin/dev..HEAD --list
#
# **What a runner covers is where it lives**, so most of them say
# nothing: a check under extensions/<x>/ covers extensions/<x>/**, one
# under apps/<a>/ covers apps/<a>/**, one in util/ itself, and one in
# builtin/luanti/test covers builtin/luanti/**. A "# covers:" line *adds*
# paths a runner also proves -- the client's own sources, mostly -- and
# only the runners that prove something outside their own tree carry one. A
# central table of paths to runners would be a second place to forget.
# **What a runner costs** is measured: every run appends its seconds to
# local/run_all/costs, and a "# cost:" line seeds one that has never
# run here. An unknown runner is assumed to cost a minute.
#
# The exit status is the run's: 0 if every runner passed or skipped, 1 if
# any failed. A runner is never retried -- a check run three times and
# taken at its best is how a real fault becomes a known flake
# ([CI_RUNS] (6)); a known flake is marked "# flaky:" in the runner and
# is run and reported but does not decide the status.
set -u
. "$(dirname "$0")/check_lib.sh"
# builtin/luanti/test's runners are named by their file name alone, as
# they were when this lived there ([RUN_ALL_TO_UTIL])
root=$(cd "$(dirname "$0")/.." && pwd)
luanti_test="$root/builtin/luanti/test"
tier="${1:-quick}"
list_only=""
changed_range=""
changed=""
if [ "$tier" = "--changed" ]; then
	changed=1
	tier="${TIER:-quick}"
	changed_range="${2:-}"
	[ "$changed_range" = "--list" ] && changed_range=""
fi
for a in "$@"; do [ "$a" = "--list" ] && list_only=1; done
case "$tier" in
quick|full|long|broken|ci) ;;
*) echo "run_all: no tier \"$tier\": quick, full, long, broken or ci" >&2
	exit 2;;
esac
out="$root/local/run_all"
mkdir -p "$out"
# **Every runner in the tree** ([CI_RUNS]: "every drive and run on
# CI"): a check under util/, apps/ or extensions/ that names a tier is
# run the same way as builtin/luanti/test's. A runner is named by its
# path from the root, so the kinds are told apart in the output and in
# the log names.
runners=""
# **core.sh beside a check.sh** is the cheap runner an edit runs
# ([CHECK_COST]): where the full one is dear, its tree carries a second
# one, and --changed picks whichever is cheaper for what changed.
# **A runner is a script with a "# tier:" line, wherever it is**
# ([CHECK_COVERAGE]): a list of places missed util/ and apps/, and named
# a games/ that had gone. A tier that is none of the four is an error,
# not a runner nobody runs.
# **Without git too**: util/checks_in_docker.sh runs a `git archive`,
# which has no .git, and every tier found nothing there and passed
tiered() {
	git -C "$root" grep -l '^# tier:' -- '*.sh' 2>/dev/null ||
		(cd "$root" && grep -rl --include='*.sh' \
			--exclude-dir=Build --exclude-dir=3rdparty --exclude-dir=local \
			--exclude-dir=user --exclude-dir=cache '^# tier:' . |
			sed 's|^\./||' | sort)
}
for f in $(tiered); do
	f="$root/$f"
	t=$(sed -n 's/^# tier: *//p' "$f" | head -1)
	case "$t" in
	quick|full|long|broken) ;;
	*) echo "run_all: ${f#"$root"/} has the tier \"$t\": quick, full, long or broken" >&2
		exit 2;;
	esac
	if [ "$tier" = ci ]; then
		[ "$t" != broken ] && grep -q '^# ci$' "$f" || continue
	else
		[ "$t" = "$tier" ] || continue
	fi
	name=${f#"$root"/}
	case "$f" in "$luanti_test"/*) name=$(basename "$f");; esac
	[ -n "${ONLY:-}" ] && { echo "$name" | grep -qE "$ONLY" || continue; }
	runners="$runners $name"
done
costs="$out/costs"
# What a runner covers: where it lives, plus whatever its own header
# adds. "**" is written for readability and is a plain glob here --
# a shell case pattern's * crosses directories already.
covers_of() {   # $1 path, $2 name
	sed -n 's/^# covers: *//p' "$1" | tr ' ' '\n'
	case "$2" in
	extensions/*|apps/*) echo "$(echo "$2" | cut -d/ -f1-2)/**" ;;
	util/*) echo "$2" ;;
	*) echo "builtin/luanti/**" ;;
	esac
}
# What it costs: the last measured run, else its own seed, else a minute
cost_of() {   # $1 path, $2 name
	c=$(grep -a "^$2 " "$costs" 2>/dev/null | tail -1 | awk '{print $2}')
	[ -n "$c" ] || c=$(sed -n 's/^# cost: *\([0-9]*\).*/\1/p' "$1" | head -1)
	echo "${c:-60}"
}
if [ -n "$changed" ]; then
	# **The cheapest runner for each changed file**, and their union is
	# the set: a greedy answer, and the one a person would give. A file
	# nothing covers is reported rather than quietly dropped.
	files=$(git -C "$root" diff --name-only ${changed_range:-HEAD} 2>/dev/null)
	[ -n "$files" ] || files=$(git -C "$root" diff --name-only HEAD~1 HEAD)
	picked=""
	uncovered=""
	# **No globbing while the patterns are handled**: "**" in a covers
	# line would otherwise be expanded against the directory it names
	# the moment it leaves a command substitution
	set -f
	for f in $files; do
		# **A document is not code and wants no runner** ([SMOKE_PICK]):
		# doc/ and the plan are read by people, and listing them as
		# uncovered every time is noise that teaches everyone to skim
		# the line that also names a source file nothing covers
		case "$f" in
		doc/*|*.md|LICENSE*|MIT.txt|CONTRIBUTING*) continue;;
		esac
		best=""; best_cost=999999
		for name in $runners; do
			path="$luanti_test/$name"; [ -f "$path" ] || path="$root/$name"
			for pat in $(covers_of "$path" "$name"); do
				pat=$(echo "$pat" | sed 's/\*\*/*/g')
				# shellcheck disable=SC2254
				case "$f" in
				$pat)
					c=$(cost_of "$path" "$name")
					if [ "$c" -lt "$best_cost" ]; then best=$name; best_cost=$c; fi
					;;
				esac
			done
		done
		if [ -n "$best" ]; then
			echo "$picked" | grep -qx "$best" || picked="$picked
$best"
		else
			uncovered="$uncovered $f"
		fi
	done
	set +f
	# **The always-run ones do not compete, they are appended**: a check
	# cheap enough to run whatever changed -- the tree's Lua parsing, a
	# second -- would otherwise be the cheapest runner covering half the
	# tree and push every deep one out of the pick
	for name in $runners; do
		path="$luanti_test/$name"; [ -f "$path" ] || path="$root/$name"
		grep -q "^# always: *yes" "$path" || continue
		picked="$picked
$name"
	done
	picked=$(echo "$picked" | grep -v '^$' | sort -u)
	if [ -z "$picked" ]; then
		# **Nothing matched**, so the named chain runs instead of the
		# whole tier: a cold client, the room drawn behind a menu, a
		# game started and left. It is a name and not a computed answer.
		picked="${SMOKE_FALLBACK:-extensions/launch_menu_attract/check.sh}"
		echo "nothing the runners cover changed; the named chain instead"
	fi
	[ -n "$uncovered" ] && echo "covered by nothing:$uncovered"
	runners=$picked
	total=0
	for name in $runners; do
		path="$luanti_test/$name"; [ -f "$path" ] || path="$root/$name"
		total=$((total + $(cost_of "$path" "$name")))
	done
	echo "$(echo "$runners" | wc -w) runners, about ${total}s"
	[ "$total" -gt "${BUDGET:-60}" ] &&
		echo "(over the ${BUDGET:-60}s budget; the diff touches that much)"
fi
if [ -n "$list_only" ]; then
	for r in $runners; do echo "$r"; done
	exit 0
fi
# **What the runners leave is pruned by age** ([REWORK_1019_FIXES] build
# 2): the scripted client's cache and the vanilla saves the runners make
# in local/check grew to 12 GB. Files, and save directories, untouched
# for PRUNE_DAYS (7); links are not followed. Its size said before and
# after.
check_dir="$root/local/check"
if [ -d "$check_dir" ]; then
	before=$(du -sh "$check_dir" 2>/dev/null | cut -f1)
	find "$check_dir/cache/scripted" -type f -mtime +"${PRUNE_DAYS:-7}" \
		-delete 2>/dev/null
	find "$check_dir/cache/scripted" -mindepth 1 -type d -empty -delete 2>/dev/null
	find "$check_dir/user/apps/vanilla/saves" -mindepth 1 -maxdepth 1 -type d \
		-mtime +"${PRUNE_DAYS:-7}" -exec rm -rf {} + 2>/dev/null
	echo "local/check: $before, $(du -sh "$check_dir" 2>/dev/null | cut -f1) after" \
		"pruning what is over ${PRUNE_DAYS:-7} days old"
fi
pass=0; fail=0; skip=0; flaky=0
failed_names=""
started=$(date +%s)
for name in $runners; do
	printf '%-34s ' "$name"
	log="$out/$(echo "${name%.sh}" | tr / _).log"
	path="$luanti_test/$name"
	[ -f "$path" ] || path="$root/$name"
	t0=$(date +%s)
	"$path" > "$log" 2>&1
	rc=$?
	t1=$(date +%s)
	# **A runner's leavings are not the next runner's condition.** Every
	# runner refuses to start while a client or a server is up, and one
	# that exits while its own client is still shutting down makes the
	# next one skip -- seven of the eight skips in the first container
	# run of this tier were that, which reads as "not run here" and is
	# really "run too soon after the last". So: wait for the tree to be
	# quiet, and take down what this tier itself started, which is
	# anything younger than the tier. A client somebody else is using is
	# older than that and is left alone ([CI_RUNS] (6): a flake is
	# quarantined, not papered over -- this is neither, it is the
	# harness cleaning up after itself).
	for w in $(seq 1 150); do
		check_pgrep buildat >/dev/null || check_pgrep buildat_server >/dev/null ||
			break
		sleep 0.2
	done
	for p in $(check_pgrep buildat) $(check_pgrep buildat_server); do
		age=$(ps -o etimes= -p "$p" 2>/dev/null | tr -d ' ')
		[ -n "$age" ] || continue
		if [ "$age" -lt "$((t1 - started + 60))" ]; then
			echo "  (the tier's own $p was still up after $name; taken down)" \
				>> "$log"
			kill -9 "$p" 2>/dev/null
		fi
	done
	verdict=$(grep -aE "^(PASS|FAIL|SKIP):" "$log" | tail -1)
	known_flaky=$(grep -c "^# flaky:" "$path")
	# Both the status and the verdict ([RUN_ALL_VERDICT]): a SKIP: line is
	# a skip whatever the status, 77 is the contract's "could not run", a
	# pass is 0 with a PASS: line. 0 with no PASS: or 2 with no SKIP: (bash
	# on a syntax error) fails.
	case "$rc:${verdict%%:*}" in
	*:SKIP|77:*) skip=$((skip + 1)); state=skip ;;
	0:PASS) pass=$((pass + 1)); state=pass ;;
	*) if [ "$known_flaky" -gt 0 ]; then
			flaky=$((flaky + 1)); state=flaky
		else
			fail=$((fail + 1)); state=FAIL
			failed_names="$failed_names $name"
		fi ;;
	esac
	printf '%-6s %4ss  %s\n' "$state" "$((t1 - t0))" "${verdict:-(no verdict line)}"
	# What it cost here, for the next --changed pick
	echo "$name $((t1 - t0))" >> "$costs"
done
echo "---"
echo "$pass passed, $fail failed, $skip skipped, $flaky known-flaky, in $(( $(date +%s) - started ))s"
[ -n "$failed_names" ] && echo "failed:$failed_names"
echo "logs in $out"
what=$([ -n "$changed" ] && echo "set the diff picked" || echo "$tier tier")
# A whole tier that ran nothing is a fault of its own, not a green one
if [ -z "$changed" ] && [ -z "${ONLY:-}" ] && [ $((pass + fail + skip)) -eq 0 ]; then
	echo "FAIL: the $what has no runners here"
	exit 1
fi
[ "$fail" -eq 0 ] && echo "PASS: the $what is green" ||
	echo "FAIL: $fail runners of the $what failed"
exit $([ "$fail" -eq 0 ] && echo 0 || echo 1)
