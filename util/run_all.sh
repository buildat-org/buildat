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
# is what a push runs. It picks from every tier up to TIER (full by
# default; quick < full < long, broken never) ([RUN_ALL_PICK]); a changed
# runner picks itself; a file the web client runs too (client/,
# extensions/, src/client/, a client_lua/ or client_data/, the network
# module, the page) gets the cheapest native runner and the cheapest web
# one -- a web runner is one that uses util/web_drive.
#
#   util/run_all.sh --changed
#   util/run_all.sh --changed origin/dev..HEAD --list
#   REMOTE=<host> util/run_all.sh --changed   # browsers, dear ones there
#
# **What a runner covers is where it lives**, so most of them say
# nothing: a check under extensions/<x>/ covers extensions/<x>/**, one
# under apps/<a>/ covers apps/<a>/**, one in util/ itself, and one in
# builtin/luanti/test covers builtin/luanti/**. A "# covers:" line *adds*
# paths a runner also proves -- the client's own sources, mostly -- and
# only the runners that prove something outside their own tree carry one. A
# central table of paths to runners would be a second place to forget.
# **What a runner read is measured too** ([RUN_ALL_PICK] 2): a pass
# records the tree's files its buildat processes opened in
# local/run_all/touched/, and a file no runner says it covers goes to the
# cheapest runner that read it.
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
	tier="${TIER:-full}"
	changed_range="${2:-}"
	[ "$changed_range" = "--list" ] && changed_range=""
fi
for a in "$@"; do [ "$a" = "--list" ] && list_only=1; done
case "$tier" in
quick|full|long|broken|ci|any) ;;
*) echo "run_all: no tier \"$tier\": quick, full, long, broken, ci or any" >&2
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
	elif [ -n "$changed" ]; then
		# Every tier up to the asked one ([RUN_ALL_PICK]): quick alone
		# never saw a full check, so its own edit was "covered by nothing"
		case "$tier:$t" in
		"$tier:$tier"|full:quick|long:quick|long:full) ;;
		*) continue;;
		esac
	elif [ "$tier" = any ]; then
		# Any tier but broken: what ONLY names (REMOTE's runs below)
		[ "$t" != broken ] || continue
	else
		[ "$t" = "$tier" ] || continue
	fi
	name=${f#"$root"/}
	case "$f" in "$luanti_test"/*) name=$(basename "$f");; esac
	[ -n "${ONLY:-}" ] && { echo "$name" | grep -qE "$ONLY" || continue; }
	runners="$runners $name"
done
costs="$out/costs"
# **What a runner read, measured** ([RUN_ALL_PICK] 2): every source file
# a buildat or buildat_server opened during the runner's last pass here,
# one a line from the root, in touched/<its log's name> -- the client's
# Lua and data, the modules' C++, headers and client_lua the server
# compiles and sends. util/run_all_touched.c, preloaded into what the
# runner starts, writes it. --changed takes a runner whose record has a
# file as covering it, beside its covers: lines and where it lives: those
# stay, since a browser's page, a compiler, node or the drive's own
# files are not seen, and src/'s C++ is in the binaries.
touched="$out/touched"
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
# What it costs: the last measured run, else its own seed, else a minute.
# The log read once ([REWORK_1019_PERF] build 9)
declare -A last_cost
if [ -f "$costs" ]; then
	while read -r n c _; do
		last_cost[$n]=$c
	done < "$costs"
fi
cost_of() {   # $1 path, $2 name
	c=${last_cost[$2]:-}
	# "~3 min (date)" as 180, "~20s" as 20
	[ -n "$c" ] || c=$(sed -n 's/^# cost: *~\{0,1\}\([0-9][0-9]*\) *min.*/\1*60/p
		s/^# cost: *~\{0,1\}\([0-9][0-9]*\).*/\1/p' "$1" | head -1)
	[ -n "$c" ] && c=$((c))
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
	# Each runner's patterns ("**" as "*") and cost once, not per file
	# ([REWORK_1019_PERF] build 9: 7.8 s for 27 files when per file)
	declare -A pats cost web rec
	for name in $runners; do
		rec[$name]=$(echo "${name%.sh}" | tr / _)
		path="$luanti_test/$name"; [ -f "$path" ] || path="$root/$name"
		pats[$name]=$(covers_of "$path" "$name" | sed 's/\*\*/*/g')
		cost[$name]=$(cost_of "$path" "$name")
		web[$name]=$(grep -q web_drive "$path" && echo 1)
	done
	# **A changed runner picks itself**, whatever its tier but broken, and
	# is no other file's pick ([RUN_ALL_PICK]): a check edited beside the
	# code proves what its author thought of, and the [LIVELY_MENU] merge's
	# own check passed on the web regression its client Lua made, which
	# aitta_web_check and serverless_check saw
	declare -A self
	for f in $files; do
		[ -f "$root/$f" ] && grep -qE '^# tier: *(quick|full|long)' "$root/$f" || continue
		name=$f
		case "$f" in builtin/luanti/test/*) name=${f##*/};; esac
		self[$f]=1; self[$name]=1
		picked="$picked
$name"
	done
	for f in $files; do
		# **A document is not code and wants no runner** ([SMOKE_PICK]):
		# doc/ and the plan are read by people, and listing them as
		# uncovered every time is noise that teaches everyone to skim
		# the line that also names a source file nothing covers
		case "$f" in
		doc/*|*.md|LICENSE*|MIT.txt|CONTRIBUTING*) continue;;
		esac
		[ -n "${self[$f]:-}" ] && continue
		# The runners whose last pass here read the file (their records'
		# names, a space either side)
		read_by=" $(grep -rlxF --exclude='*.new' -- "$f" "$touched" 2>/dev/null |
			sed 's|.*/||' | tr '\n' ' ')"
		# **A file both clients run gets both** ([RUN_ALL_PICK]): the
		# [LIVELY_MENU] merge's client Lua got a native check and broke
		# the web play. What the page's bundle packs (CMakeLists.txt's
		# WEB_PRELOAD), the client's C++, what the server sends a client,
		# and the network module that serves the page. Anything else, the
		# cheaper of the two
		both=""
		case "$f" in
		client/*|extensions/*|src/client/*|src/lua_bindings/*|*/client_lua/*|*/client_data/*|builtin/network/*|src/server/web/*) both=1;;
		esac
		# The cheapest native runner and the cheapest web one. **What a
		# runner says it covers comes first**, what it only read second: a
		# launcher check of seconds reads every client file and proves
		# few, and would otherwise be every client file's pick; a record
		# answers for a kind nothing says it covers
		bn=""; bn_cost=999999; bw=""; bw_cost=999999
		for by in said read; do
			said_n=$bn said_w=$bw
			for name in $runners; do
				[ -n "${self[$name]:-}" ] && continue
				m=""
				if [ $by = read ]; then
					case "$read_by" in *" ${rec[$name]} "*) m=1;; esac
				else
					for pat in ${pats[$name]}; do
						# shellcheck disable=SC2254
						case "$f" in $pat) m=1; break;; esac
					done
				fi
				[ -n "$m" ] || continue
				c=${cost[$name]}
				if [ -n "${web[$name]}" ]; then
					[ -z "$said_w" ] && [ "$c" -lt "$bw_cost" ] && { bw=$name; bw_cost=$c; }
				else
					[ -z "$said_n" ] && [ "$c" -lt "$bn_cost" ] && { bn=$name; bn_cost=$c; }
				fi
			done
			[ -n "$bn$bw" ] && [ -z "$both" ] && break
		done
		if [ -z "$both" ]; then
			if [ "$bw_cost" -lt "$bn_cost" ]; then bn=""; else bw=""; fi
		fi
		if [ -n "$bn$bw" ]; then
			picked="$picked
$bn
$bw"
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
# The preload, built when its source is newer; without a compiler,
# nothing is recorded
mkdir -p "$touched"
touched_so="$out/touched.so"
{ [ "$touched_so" -nt "$root/util/run_all_touched.c" ] ||
	cc -shared -fPIC -O2 -o "$touched_so" "$root/util/run_all_touched.c" -ldl; } ||
	touched_so=""
# The paths opened, as files in the tree from its root; what the build,
# the checks' user and cache and the web bundle hold is not source
touched_norm() {   # $1 the paths written
	local r p
	r=$(realpath "$root")
	sort -u "$1" | tr '\n' '\0' | xargs -0 -r realpath -m -- | sort -u |
	while IFS= read -r p; do
		case "$p" in
		"$r"/Build*|"$r"/local/*|"$r"/user/*|"$r"/cache/*|"$r"/web/*|"$r"/.git/*) ;;
		"$r"/*) [ -f "$p" ] && echo "${p#"$r"/}" ;;
		esac
	done
}
# **REMOTE=<host>: the dear runners on another machine at once** (user,
# 2026-10-30: the wall clock, and no browser runs here: they max out
# this machine's CPU). A runner that drives a browser, or costs
# REMOTE_MIN (300) s or more here, goes to util/remote_check.sh's
# slots, half to each, while the rest runs here; their lines and counts
# join this run's. They run the committed HEAD, as remote_check does.
# simplified: the split is by this machine's costs, not balanced; a
# timing limit that fails on a slower machine is [CHECK_TIMING_LIMITS]'s.
remote_logs=""; remote_pids=""
if [ -n "${REMOTE:-}" ]; then
	near=""; far=(""  "")
	k=0
	for name in $runners; do
		path="$luanti_test/$name"; [ -f "$path" ] || path="$root/$name"
		if grep -q web_drive "$path" ||
				[ "$(cost_of "$path" "$name")" -ge "${REMOTE_MIN:-300}" ]; then
			far[$k]="${far[$k]} $name"; k=$((1 - k))
		else
			near="$near $name"
		fi
	done
	for k in 0 1; do
		[ -n "${far[$k]}" ] || continue
		re="^($(echo ${far[$k]} | sed 's/\./\\./g; s/ /|/g'))\$"
		echo "on $REMOTE:${far[$k]}"
		"$root/util/remote_check.sh" "$REMOTE" env ONLY="$re" \
			util/run_all.sh any > "$out/remote_$k.log" 2>&1 &
		remote_pids="$remote_pids $!"; remote_logs="$remote_logs $out/remote_$k.log"
		sleep 2   # the two take their slots in turn
	done
	runners=$near
fi
pass=0; fail=0; skip=0; flaky=0
failed_names=""
started=$(date +%s)
for name in $runners; do
	printf '%-34s ' "$name"
	log="$out/$(echo "${name%.sh}" | tr / _).log"
	path="$luanti_test/$name"
	[ -f "$path" ] || path="$root/$name"
	tf="$touched/$(echo "${name%.sh}" | tr / _)"
	rm -f "$tf.new"
	t0=$(date +%s)
	if [ -n "$touched_so" ]; then
		BUILDAT_TOUCHED="$tf.new" LD_PRELOAD="$touched_so${LD_PRELOAD:+:$LD_PRELOAD}" \
			"$path" > "$log" 2>&1
	else
		"$path" > "$log" 2>&1
	fi
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
	wait_quiet 30 2>/dev/null
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
	# And what it read, when it passed; a failed run may have stopped short
	[ "$state" = pass ] && [ -f "$tf.new" ] && touched_norm "$tf.new" > "$tf"
	rm -f "$tf.new"
done
for p in $remote_pids; do wait "$p"; done
for l in $remote_logs; do
	# Its runner lines, and its counts into these; no count line is a
	# remote run that broke, a failure
	grep -aE '^[^ ]+ +(pass|FAIL|skip|flaky) ' "$l" | sed 's/$/  (remote)/'
	n=$(grep -aE '^[0-9]+ passed, ' "$l" | tail -1)
	if [ -z "$n" ]; then
		fail=$((fail + 1)); failed_names="$failed_names $l"
		echo "remote run broke: $(tail -1 "$l")"
		continue
	fi
	set -- $n
	pass=$((pass + $1)); fail=$((fail + $3)); skip=$((skip + $5)); flaky=$((flaky + $7))
	f=$(sed -n 's/^failed://p' "$l" | tail -1)
	failed_names="$failed_names$f"
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
