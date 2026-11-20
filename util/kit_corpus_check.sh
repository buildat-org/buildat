#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: 30 s (2026-11-20)
# covers: builtin/kit/kit.cpp builtin/kit/box/box.c builtin/kit/types/** builtin/kit/materials.json builtin/kit/sounds.json apps/workbench/main/main.cpp src/interface/aitta.h src/impl/aitta.cpp src/impl/jam.cpp util/kit_corpus/** util/kit_api1_alpha47.json
# [KIT_API1_CORPUS] (kit_plan 4z37j (5)) Kit API 1's corpus: games saved
# and exported by earlier Buildats, loaded and played by this one, each
# against what was recorded of it (util/kit_corpus/expected/). A game
# saved today loads and plays the same on later builds; a fixture never
# changes after it is added, a template's change goes into the next
# release's set.
#   api1/      the templates of 0.8.0-alpha.51, Kit API 1's baseline
#   alpha47/   those of 0.8.0-alpha.47, before API 1 (no "kit", no
#              component versions; the renamed params): A's and B's
#              migrates
#   made/      games a builder made: export_check (kit_project_export_check's
#              project, exported: a voxel type with a recipe texture and
#              an uploaded one, an item, a sound, a prefab, a heightmap
#              stroke and cells in edits.bin, a timer and counter, a custom
#              type with a client part), relay (a runner -- a bot -- to
#              a goal, a timer counting, a custom type keeping the rounds
#              as kept state and the score, a generator building live at
#              the round's start, a jam1 song)
#   saves/     a save's rows: relay_api1 (relay's after its first round,
#              its kept state), and alpha.47's Crag Trial
#              (util/kit_api1_alpha47.json)
# Each on Workbench's headless server of its own (up to CORPUS_JOBS, 3,
# at once), on the game's clock (--sim-rate 0): an export made a project
# as New's From a file... makes one (BUILDAT_WORKBENCH_FROM), a save's
# rows put in its database; then a round (BUILDAT_WORKBENCH_PLAY: Stop
# if Running, Play, the fixture's inputs by app -- a bots' spawner's
# "spawn", a timer's "start") until its line comes (or +N game seconds
# pass), the server stopped. Compared with the record:
#   - warnings: Kit's warnings and errors (Kit's, the box's, Workbench's),
#     their numbers as N, none it did not have (one gone is said);
#   - composition: the authored row after the load, each entity's
#     components as type@version, a hash of each one's links and of its
#     params by the keys recorded for its type (keys a type gained since
#     are not read), the params old_params kept; the count; the game's
#     own rows (types, voxels, items, sounds, weaves, prefabs, textures);
#   - round: the box's c:log lines and Kit's Hosted, Play, World and
#     "steps in play" lines, in order, until the round's line.
# simplified: Kit's warnings of time (took, budget, slow) are not
# compared, a loaded machine's, nor kit/symmetry's of cells unlike their
# image at Play (they come and go with the world's generation). A round
# with two bots is cut before they walk far: when a walker arrives varies
# with when the world's sections load, and two of them race (CTF's,
# Airships', Brimstone's); a bot's aim is a random draw besides. Ship's
# two and relay's one finish as recorded so far; a flake there is the
# same race
#   util/kit_corpus_check.sh             all, against the records
#   util/kit_corpus_check.sh api1/ship   those whose names begin so
#   RECORD=1 util/kit_corpus_check.sh    the records written (a fixture
#                                        added, a change meant)
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
C=$here/util/kit_corpus
if check_pgrep buildat_server >/dev/null; then
	skip "a buildat server is already running"
fi
check_tmp kit_corpus; t=$CHECK_TMP
cd "$here/Build"
check_build
JOBS=${CORPUS_JOBS:-3}
ONLY=${1:-}

# The fixtures: name, inputs (";" between, "-" none), until (a round's
# line, or +N game seconds)
FIXTURES='
api1/airships|50 spawn;50 spawn|kit: Entity 56'"'"'s kit/creature_walker steps in play
api1/arena|-|kit/goal 85: waits for activate
api1/brimstone_speedway|1328 spawn;1328 spawn|local/brim_race 137: Driver 1332 is on the grid, slot 2
api1/crag_trial|-|kit/sign 63: shows "Best times?" by app
api1/ctf|61 spawn;61 spawn|kit/bot 76: goal 64 reach ""
api1/puzzle_room|52 spawn|kit/ui_text 50: show for Bot 56
api1/ship|48 spawn;48 spawn|kit/ui_text 46: show for everyone
api1/survival|-|+5
alpha47/airships|50 spawn;50 spawn|kit: Entity 56'"'"'s kit/creature_walker steps in play
alpha47/arena|-|kit/goal 85: waits for activate
alpha47/brimstone_speedway|1328 spawn;1328 spawn|local/brim_race 137: Driver 1332 is on the grid, slot 2
alpha47/crag_trial|-|kit/sign 63: shows "Best times?" by app
alpha47/ctf|61 spawn;61 spawn|kit/bot 76: goal 64 reach ""
alpha47/puzzle_room|52 spawn|kit/ui_text 50: show for Bot 56
alpha47/ship|48 spawn;48 spawn|kit/ui_text 46: show for everyone
alpha47/survival|-|+5
made/export_check|4 start|kit/counter 5: reached 3
made/relay|6 spawn|kit/ui_text 13: show for Bot 17
saves/relay_api1|6 spawn|kit/ui_text 13: show for Bot 22
saves/alpha47_crag|-|kit/sign 63: shows "Best times?" by app
'

# What a run left, as the record's text: <log> <save.sqlite> [<record>:
# its keys by type, read for the hashes] (python3 -I)
cat > "$t/record.py" <<'PY'
import hashlib, json, re, sqlite3, sys
log, save = sys.argv[1], sys.argv[2]
keys = {}
if len(sys.argv) > 3:
	sec = None
	for l in open(sys.argv[3]):
		l = l.rstrip("\n")
		if l.startswith("["):
			sec = l
		elif sec == "[keys]" and l:
			k = l.split(" ")
			keys[k[0]] = k[1:]
out = {"[warnings]": set(), "[composition]": [], "[rows]": [], "[round]": []}
# (and kit/symmetry's cells unlike their image at Play: which sections
# were generated by then)
TIME = re.compile(r"\b(took|budget|slow)\b|differ from their source's image")
for l in open(log, errors="replace"):
	m = re.match(r"^\S+ +\d+ [\d:.]+ (\w) (\S+) *: (.*)", l.rstrip("\n"))
	if not m:
		continue
	lv, mod, s = m.groups()
	if lv in "WE" and (mod in ("kit", "wasm") or s.startswith("workbench:")) \
			and not TIME.search(s):
		# (counts of a world being generated vary: numbers as N)
		out["[warnings]"].add(lv + " " + mod + ": " + re.sub(r"\d+", "N",
			re.sub(r"/tmp/\S+", "<t>", s)))
	if mod == "wasm" and re.match(r"wasm kit: \S+/\S+ \d+: ", s):
		out["[round]"].append(s[10:].rstrip())
	elif mod == "kit" and lv == "I":
		s = re.sub(r", \d+ types", "", s)
		s = re.sub(r" \(authored [0-9a-f]+, start [0-9a-f]+\)", "", s)
		if re.match(r"Hosted: |Play by |Entity \d+'s \S+ steps in play$", s) or (
				s.startswith("World: ") and not re.search(
				r"generated since|sections loaded|copied", s)):
			out["[round]"].append("kit: " + s)
db = sqlite3.connect(save)
a = json.loads(db.execute("select value from store where store='kit' and key='authored'").fetchone()[0])
seen = {}
def h(x):
	return hashlib.sha1(json.dumps(x, sort_keys=True).encode()).hexdigest()[:8]
comp = out["[composition]"]
comp.append("entities %d (kit %s, api %s)" % (len(a["entities"]), a.get("kit"), a.get("api")))
for e in a["entities"]:
	w = ["%d" % e["id"], "%d" % e.get("parent", 0)]
	if e.get("kind"):
		w.append(e["kind"])
	for c in e.get("components", []):
		p = c.get("params", {})
		k = keys.get(c["type"]) or sorted(p)
		seen.setdefault(c["type"], k)
		x = "%s@%s#%s/%s" % (c["type"], c.get("version"),
			h([p.get(n, "<none>") for n in k]), h(c.get("links", [])))
		if c.get("old_params"):
			x += "+old_params:" + ",".join(sorted(c["old_params"]))
		w.append(x)
	comp.append(" ".join(w))
for (k,) in db.execute("select key from store where store='kit' order by key"):
	if k.split(":")[0] in ("type", "voxel", "item", "sound", "weave", "prefab",
			"texture", "package"):
		out["[rows]"].append(k)
for sec in ("[warnings]", "[composition]", "[rows]", "[round]"):
	print(sec)
	for l in (sorted(out[sec]) if sec == "[warnings]" else out[sec]):
		print(l)
print("[keys]")
for k in sorted(seen):
	print(k, *seen[k])
PY
# The record against the expected: what differs (python3 -I)
cat > "$t/compare.py" <<'PY'
import difflib, sys
def read(f):
	r, sec = {}, None
	for l in open(f):
		l = l.rstrip("\n")
		if l.startswith("[") and l.endswith("]"):
			sec = r.setdefault(l, [])
		elif sec is not None and not l.startswith("#"):
			sec.append(l)
	return r
want, got = read(sys.argv[1]), read(sys.argv[2])
bad = []
new = sorted(set(got["[warnings]"]) - set(want["[warnings]"]))
gone = sorted(set(want["[warnings]"]) - set(got["[warnings]"]))
if new:
	bad.append("new warnings:\n  " + "\n  ".join(new))
if gone:
	print("  (warnings gone: %s)" % "; ".join(gone))
for sec in ("[composition]", "[rows]", "[round]"):
	if want[sec] != got[sec]:
		d = list(difflib.unified_diff(want[sec], got[sec], "recorded", "now",
			n=1, lineterm=""))
		bad.append("%s differs:\n  " % sec + "\n  ".join(d[:40]) +
			("\n  ..." if len(d) > 40 else ""))
for b in bad:
	print("  " + b)
sys.exit(1 if bad else 0)
PY

# One fixture: its run, record and verdict in $t/<n>/ (result: ok, or
# why not)
one() # <name> <inputs> <until>
{
	local n=$1 in=$2 until=$3 d u log want got secs re
	d=$t/${1//\//_} u=$d/user log=$d/srv.log
	want=$C/expected/${1//\//_}.txt got=$d/record.txt
	mkdir -p "$u/shared"
	[ "$in" = - ] && in=
	local env=(BUILDAT_WORKBENCH_PLAY="$in" BUILDAT_WORKBENCH_PROJECT=g)
	case "$n" in
	saves/*)
		local rows=$C/$n.json
		[ "$n" = saves/alpha47_crag ] && rows=$here/util/kit_api1_alpha47.json
		mkdir -p "$u/apps/workbench/saves/g"
		python3 -I - "$rows" "$u/apps/workbench/saves/g/save.sqlite" <<'PY' ||
import base64, json, sqlite3, sys
db = sqlite3.connect(sys.argv[2])
db.execute("CREATE TABLE store (store TEXT NOT NULL, key TEXT NOT NULL, value BLOB, PRIMARY KEY(store, key))")
for s, k, v in json.load(open(sys.argv[1]))["rows"]:
	v = base64.b64decode(v["b64"]) if isinstance(v, dict) else v.encode()
	db.execute("insert into store values (?, ?, ?)", (s, k, v))
db.commit()
PY
			{ echo "the rows of $rows" > "$d/result"; return; }
		;;
	*)
		[ -f "$C/$n/composition.json" ] || { echo "no $C/$n" > "$d/result"; return; }
		# (a confined server reads only <user>/shared)
		(cd "$C/$n" && zip -qrX "$u/shared/game.zip" .) ||
			{ echo "not zipped" > "$d/result"; return; }
		env+=(BUILDAT_WORKBENCH_FROM="$u/shared/game.zip")
		;;
	esac
	case "$until" in
	+*) secs=${until#+} re="Not hosted: |Shutdown: |NOTHING-COMES";;
	*) secs=120 re="$(printf '%s' "${until#kit: }" | sed 's/[][\.*^$?+(){}|]/\\&/g')|Not hosted: |Shutdown: ";;
	esac
	local port i
	for i in $(seq 50); do
		port=$((29000 + RANDOM % 700))
		port_taken $port || break
	done
	env "${env[@]}" bin/buildat_server -m ../apps/workbench -D "$u" -l 3 \
		--sim-rate 0 -P "$port" < /dev/null > "$log" 2>&1 &
	local pid=$!
	echo "$pid" > "$d/pid"
	if ! wait_for_log "$log" "Hosted: |Not hosted: |Shutdown: " 300; then
		kill -INT "$pid" 2>/dev/null; wait "$pid"
		echo "not hosted in 300 s ($log)" > "$d/result"
		return
	fi
	wait_for_log "$log" "$re" "$secs" "$u"
	local reached=$?
	kill -INT "$pid" 2>/dev/null
	wait "$pid"
	if grep -aqE "$_CHECK_CRASH_RE" "$log"; then
		echo "the server crashed ($log)" > "$d/result"
		return
	fi
	if grep -aqE "Not hosted: |Shutdown: workbench" "$log"; then
		echo "not hosted: $(grep -aoE "(Not hosted|Shutdown): .*" "$log" | head -1) ($log)" > "$d/result"
		return
	fi
	case "$until" in
	+*) ;;
	*) [ $reached = 0 ] || { echo "no \"$until\" in $secs game seconds ($log)" > "$d/result"; return; };;
	esac
	python3 -I "$t/record.py" "$log" "$u/apps/workbench/saves/g/save.sqlite" \
		$([ -z "${RECORD:-}" ] && [ -f "$want" ] && echo "$want") > "$got" 2> "$d/record.err" ||
		{ echo "no record: $(tail -1 "$d/record.err") ($log)" > "$d/result"; return; }
	# (the round's lines up to its line)
	case "$until" in
	+*) ;;
	*) python3 -I - "$got" "$until" <<'PY'
import sys
f, until = sys.argv[1], sys.argv[2]
out, sec, cut = [], None, False
for l in open(f).read().splitlines():
	if l.startswith("["):
		sec = l
	elif sec == "[round]" and cut:
		continue
	elif sec == "[round]" and until in l:
		cut = True
	out.append(l)
open(f, "w").write("\n".join(out) + "\n")
PY
	;;
	esac
	if [ -n "${RECORD:-}" ]; then
		mkdir -p "$C/expected"
		{ echo "# util/kit_corpus_check.sh's record of $n (RECORD=1 writes it)"; cat "$got"; } > "$want"
		echo "recorded" > "$d/result"
	elif [ ! -f "$want" ]; then
		echo "no record ($want; RECORD=1)" > "$d/result"
	elif python3 -I "$t/compare.py" "$want" "$got" > "$d/diff"; then
		echo "ok$(cat "$d/diff")" > "$d/result"
	else
		{ echo "differs from $want ($log):"; cat "$d/diff"; } > "$d/result"
	fi
}

names=()
while IFS='|' read -r n in until; do
	[ -n "$n" ] || continue
	[ -z "$ONLY" ] || [ "${n#"$ONLY"}" != "$n" ] || continue
	names+=("$n")
	while [ "$(jobs -rp | wc -l)" -ge "$JOBS" ]; do sleep 0.2; done
	mkdir -p "$t/${n//\//_}"
	one "$n" "$in" "$until" &
	CHECK_PIDS+=($!)
done <<< "$FIXTURES"
[ ${#names[@]} -gt 0 ] || fail "no fixture named $ONLY*"
wait
failed=0
for n in "${names[@]}"; do
	r=$(cat "$t/${n//\//_}/result" 2>/dev/null || echo "no result")
	case "$r" in
	ok*|recorded) echo "$n: $r";;
	*) echo "FAILED $n: $r"; failed=$((failed + 1));;
	esac
done
[ $failed = 0 ] || fail "$failed of ${#names[@]} fixtures"
echo "PASS: Kit API 1's corpus: ${#names[@]} games (templates of API 1 and of alpha.47, a builder's exports, saves) loaded with no new warnings, their composition after migrate and their rounds as recorded"
