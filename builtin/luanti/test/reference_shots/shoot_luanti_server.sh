#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [OFFICIAL_SHOTS]: the reference shot set's Luanti-server half, taken by a
# script rather than by hand. See doc/plan/rendering_plan.md, [REFVIEWS_MOD].
#
#   CLIENT=luanti|extension MODE=shadows|unlit \
#   builtin/luanti/test/reference_shots/shoot_luanti_server.sh reference
#
# Stands up `luanti --server` on the reference world and puts one client in
# front of it: official Luanti (the default) or extensions/luanti_client,
# both being Luanti clients of the same server and the same worldmod. The
# module's client has no Luanti server and shoot_buildat_server.sh beside
# this is its runner. The set lands in $REFSHOT_SHOTS_DIR/<client>_<mode>_r<RANGE>.
#
# A fixture is a seed and its mapgen settings, never a world directory -- see
# "A fixture is a seed, never a copy" -- and the settings are the whole of
# map_meta.txt beside this file rather than a few keys out of it. The world
# is generated into a cache under $REFSHOT_WORLDS_DIR and reused if it is
# already there, so a bulk session pays for the terrain once. The worldmod in
# it is build.sh's, the same fixture the module runs, so the two sides line
# up by construction rather than by aim.
#
# It waits for the fixture's own "REFSHOT <n> <name>" line in the server log
# and shoots within a second of it, rather than counting seconds: the aim is
# re-asserted every second, so a shot taken right after one is the one least
# likely to have been spoiled by the desktop's real mouse.
set -u
. "$(dirname "$0")/../../../../util/check_lib.sh"

# The repository root, from builtin/luanti/test/reference_shots/
here=$(cd "$(dirname "$0")/../../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
fixture="${1:?reference | check <dir> | shoot <log> <pid> <dir>}"
# Every copy of every fact comes out of build.sh; see [REFVIEWS_MOD]
# No sparkle in a reference set (user, 2026-09-18): the path-traced
# reference does not render the spots, so both clients leave them off
# under this variable and the comparison is of what both can draw
export BUILDAT_LUANTI_NO_SPOTS=1
# And no tonemap curve on pbr: the render's PNG is the metered frame
# clipped, and the probes compare linear to linear until the fit's last
# term ([PBR_FIT]) has a curve to compare. The parity modes have none.
export BUILDAT_VOXEL_LINEAR=1
built=$(mktemp -d /tmp/refshots_build.XXXXXX)
"$me/build.sh" "$built" || exit 2
. "$built/env.sh"
RANGE=$REFSHOT_RANGE
conf="$built/luanti.conf"
# Roots, not leaves: the set's name is always derived, so a redirected run
# keeps the structure and probes.sh reads what the runners wrote
shots_root="${REFSHOT_SHOTS_DIR:-$here/local/reference_shots}"
worlds_root="${REFSHOT_WORLDS_DIR:-$here/local/reference_worlds}"
CLIENT="${CLIENT:-luanti}"
MODE="${MODE:-shadows}"
case "$CLIENT" in
luanti) set_name="official_${MODE}_r$RANGE" ;;
extension) set_name="extension_${MODE}_r$RANGE" ;;
*) echo "CLIENT must be luanti or extension, got: $CLIENT" >&2; exit 2 ;;
esac
out="$shots_root/$set_name"
luanti=~/projects/luanti
# The patched client, branch buildat-refshots: no mouse look, no pointer grab,
# no pausing when unfocused, no damage. A run shares the desktop, and every
# one of those cost pictures before the branch existed. Build it with
# `git checkout buildat-refshots && make -j` and keep bin/luanti as it was.
bin=${LUANTI_BIN:-./bin/luanti-refshots}

# The shooting half, which is the same whichever client is on screen: find its
# window, learn how many states the fixture has, and photograph each one late
# in its hold. shoot_buildat_server.sh calls it through
#
#   shoot_luanti_server.sh shoot <server log> <client pid> <dir>
#
# rather than carrying a second copy of it. Reads $log, $cli and $out.

# One picture of the client's window. Three tries, because `import` fails on
# a window that is being resized or restacked and the state is still there a
# moment later, and the window is looked up again between them in case the
# client made a new one -- a stale id fails forever and reads as a client
# that has stopped drawing. What it could not do is reported rather than
# swallowed: a run of MISSED lines with no reason behind them cost two runs
# to tell apart from a client that had died.
take_picture()
{
	local try
	for try in 1 2 3; do
		import -window "$win" "$1" 2>"$imperr" && return 0
		sleep 0.4
		local again
		again=$(wmctrl -lp 2>/dev/null | awk -v p="$cli" '$3 == p {print $1; exit}')
		if [ -n "$again" ] && [ "$again" != "$win" ]; then
			echo "the client's window is now $again, was $win" >&2
			win="$again"
		fi
	done
	return 1
}

shoot_states()
{
	# The window, by the client's own pid rather than by its title. `xdotool
	# search` walks the whole window tree and hangs on this desktop; wmctrl -lp
	# is one EWMH query. By pid also cannot photograph the wrong renderer, which
	# a title match can when a buildat client is on screen at the same time.
	win=""
	for i in $(seq 1 40); do
		sleep 1
		win=$(wmctrl -lp 2>/dev/null | awk -v p="$cli" '$3 == p {print $1; exit}')
		[ -n "$win" ] && break
	done
	if [ -z "$win" ]; then
		echo "no window for pid $cli after 40s" >&2
		kill "$cli" "${srv:-}" 2>/dev/null; exit 1
	fi
	echo "window=$win  log=$log  out=$out"
	imperr=$(mktemp /tmp/refshots_import.XXXXXX)

	# Wait for the fixture to say how many states this world has rather than
	# guessing: a wrong count makes the deadline wrong, and an over-long deadline
	# is what let a third cycle overwrite a good set with a spoiled one.
	total=""
	for i in $(seq 1 60); do
		total=$(grep -o "REFSHOT world seed .*, [0-9]* states" "$log" | \
				grep -o "[0-9]* states" | grep -o "[0-9]*" | tail -1)
		[ -n "$total" ] && break
		sleep 1
	done
	total=${total:-16}
	echo "states=$total"
	# **And for the fixture to say its viewpoints are loaded**, which is a
	# signal where this used to guess: it forceloads what it will photograph
	# and logs when the sections are there. A fixture that does not say so --
	# an older one, or official Luanti's copy of it -- just does not hold this
	# up. See [KEEP_LOADED] in doc/plan/rendering_plan.md.
	for i in $(seq 1 150); do
		grep -q "REFSHOT ready\|REFSHOT failed" "$log" 2>/dev/null && break
		grep -q "REFSHOT pinned" "$log" 2>/dev/null || break
		sleep 2
	done
	grep -a "REFSHOT ready\|REFSHOT failed\|REFSHOT pinned" "$log" \
			2>/dev/null | tail -2
	# The fixture exits rather than photographing a world with holes in it, so
	# there is nothing here to wait for either
	if grep -q "REFSHOT failed" "$log" 2>/dev/null; then
		echo "the fixture gave up on loading the world; nothing was shot" >&2
		return 1
	fi
	# Two full cycles, overwriting: the world generates lazily as the player is
	# teleported, so the first pass through a viewpoint can photograph terrain
	# that has not arrived. The second cycle overwrites it with a warm one, which
	# is cheaper than a separate warm-up run -- a cycle is only four seconds a
	# state.
	#
	# And the shot is taken in the middle of the hold rather than right after the
# aim.
	# "Within a second of the aim" existed only to dodge the desktop's real
	# mouse; inside a granted window, settled terrain is worth more.
	# Exactly two cycles' worth of shots, counted rather than timed: the first
	# pass through a viewpoint can photograph terrain that has not arrived, the
	# second overwrites it warm, and a third is only a chance to overwrite a good
	# picture with a spoiled one.
	# Cycles, overwriting: the first pass through a viewpoint can photograph
	# terrain that has not arrived and the next overwrites it warm. Two is
	# enough for a client that was handed a cached world; a client that has
	# just imported one is still meshing it through the second, which is why
	# shoot_buildat_server.sh asks for three.
	want=$(( total * ${CYCLES:-2} ))
	taken=0
	# Which states were actually photographed, so one that was dropped in both
	# cycles is reported rather than left as whatever an older run put there
	# under that name. A stale picture of the right place is the other thing
	# the two cheap tests cannot see.
	shotlist=$(mktemp /tmp/refshots_taken.XXXXXX)
	# Two bounds, neither of them a guess at how long a state takes. That
	# guess was wrong twice: a formula of SHOT_AT times three cut a run off
	# at nineteen minutes with four of its twenty states never photographed,
	# and the client's SIGTERM at the end of it read as an outside killer.
	# What a state costs here is anything from nine seconds to thirty-three,
	# because the server loads a world around a player it teleports.
	#
	# So: the run ends when it stops making progress, or at the outer cap.
	# STALL is reset by every picture taken; before the first one it is
	# longer, because the client is importing a world and that is minutes.
	cap=$(( $(date +%s) + ${REFSHOT_CAP:-2700} ))
	stall=$(( $(date +%s) + ${REFSHOT_FIRST:-420} ))
	last=""
	while [ "$taken" -lt "$want" ] && [ "$(date +%s)" -lt "$stall" ] &&
			[ "$(date +%s)" -lt "$cap" ]; do
		line=$(grep -o "REFSHOT [0-9]* [0-9a-z_]*_\(none\|rain\)" "$log" | tail -1)
		name=$(echo "$line" | cut -d' ' -f3)
		if [ -n "$name" ] && [ "$name" != "$last" ]; then
			# Two thirds of the way into the hold, which is where the aim has
			# settled and the state has not moved on. SHOT_AT follows the
			# fixture's HOLD when a calibration run halves it.
			sleep "${SHOT_AT:-4}"
			# The name was read before the exposure. If the fixture moved on
			# during it the picture is of the next state, and saving it under
			# this name is the one failure the two cheap tests below cannot
			# see -- it is a good picture of the wrong thing. A state is four
			# seconds when the server is warm and fifteen while it loads a
			# world around a teleporting player, so this is checked rather
			# than assumed; the state comes round again next cycle.
			now=$(grep -o "REFSHOT [0-9]* [0-9a-z_]*_\(none\|rain\)" "$log" | tail -1 | \
					cut -d' ' -f3)
			if [ "$now" != "$name" ]; then
				echo "moved during $name, dropped" >&2
				last="$name"
				sleep 0.5
				continue
			fi
			if take_picture "$out/$name.png"; then
				taken=$((taken + 1))
				echo "$name" >> "$shotlist"
				stall=$(( $(date +%s) + ${REFSHOT_STALL:-150} ))
				echo "shot $name"
			else
				echo "MISSED $name: $(tail -1 "$imperr")" >&2
			fi
			last="$name"
		fi
		sleep 0.5
		kill -0 "$cli" 2>/dev/null || break
	done
	got=$(sort -u "$shotlist" 2>/dev/null | wc -l)
	# What this run shot, so the check reads those rather than the whole
	# directory: a probe cycle re-takes two of twenty and the other eighteen
	# are last round's, which are not this change's to answer for
	shot_names=$(sort -u "$shotlist" 2>/dev/null)
	rm -f "$shotlist" "$imperr"
	if [ "$got" -lt "$total" ]; then
		echo "only $got of $total states were shot; the rest are stale" >&2
		# By name, because which ones matters: four rain states missing is a
		# fixture that never reached them, and four scattered ones is a
		# shooter dropping pictures. The count alone says neither.
		for n in $(grep -o "REFSHOT [0-9]* [0-9a-z_]*_\(none\|rain\)" "$log" | \
				cut -d' ' -f3 | sort -u); do
			echo "$shot_names" | grep -qx "$n" || echo "  never shot: $n" >&2
		done
	fi
	# Nothing at all is a run that did not happen -- the server lost a race for
	# the save's sqlite, or the client never drew. The caller retries on it.
	[ "$got" -gt 0 ]
}

# Two cheap tests, which catch every failure this run has actually had: the
# "You died" dialog fills the screen centre with one flat grey, and a player
# who fell through unloaded ground photographs flat sky. Neither catches the
# failure that cost the most -- a world that generated fine and is simply not
# the right world -- so one look per viewpoint stays part of the recipe.
#
#   shoot_luanti_server.sh check <dir>
#
# is the whole check over whatever is in a set's directory, without taking
# the pictures again.
check_shots()
{
	local bad=0 f mean sd
	local files=""
	if [ -n "${shot_names:-}" ]; then
		for f in $shot_names; do files="$files $out/$f.png"; done
	else
		files="$out"/*.png
	fi
	for f in $files; do
		[ -f "$f" ] || continue
		read -r mean sd < <(magick "$f" -gravity center \
				-crop 200x200+0+0 +repage -colorspace Gray \
				-format "%[fx:mean] %[fx:standard_deviation]" info:)
		# A flat frame is a falling player's sky -- unless it is dark, which
		# is what a cave viewpoint is supposed to answer (vp8 reads 3, 3, 2)
		if awk "BEGIN{exit !($sd < 0.01 && $mean > 0.05)}"; then
			echo "FLAT SKY  $(basename "$f")  sd=$sd" >&2
			bad=$((bad + 1))
		elif awk "BEGIN{exit !($mean > 0.75 && $mean < 0.86 && $sd < 0.10)}"
		then
			echo "YOU DIED  $(basename "$f")  mean=$mean" >&2
			bad=$((bad + 1))
		fi
	done
	# And against the reference set for this mode, which is the test that
	# catches what the two above cannot: a picture that is dark but not flat,
	# where the sky arrived and the terrain did not. The same state in the
	# reference is the same world at the same hour, so a frame three times
	# brighter or darker than it is not a rendering difference. Every set
	# is <client>_<mode>_r<RANGE>, so the reference is official_<mode> at
	# the same range; pbr has no official set and official is its own.
	local ref=""
	case "$(basename "$out")" in
	official_*|*_pbr_r*) ref="" ;;
	*) ref="$(dirname "$out")/official_$(basename "$out" | sed 's/^[a-z]*_//')" ;;
	esac
	if [ -n "$ref" ] && [ -d "$ref" ]; then
		for f in $files; do
			[ -f "$f" ] || continue
			local r="$ref/$(basename "$f")"
			[ -f "$r" ] || continue
			read -r a b < <(magick "$f" -colorspace Gray \
					-format "%[fx:mean] " info: && magick "$r" \
					-colorspace Gray -format "%[fx:mean]" info:)
			if awk "BEGIN{exit !($a > $b * 3 || $a < $b / 3)}"; then
				echo "OFF BY A LOT  $(basename "$f")  $a against the" \
						"reference's $b" >&2
				bad=$((bad + 1))
			fi
		done
	fi
	if [ -n "${shot_names:-}" ]; then
		echo "$(echo "$shot_names" | wc -w) pictures checked in $out, $bad suspect"
	else
		echo "$(ls "$out" | wc -l) pictures in $out, $bad suspect"
	fi
	[ "$bad" -eq 0 ]
}

case "$fixture" in
check)
	out="${2:?set directory}"; check_shots; exit $? ;;
shoot)
	log="$2"; cli="$3"; out="${4:?set directory}"
	mkdir -p "$out"; shoot_states; check_shots; exit $? ;;
reference)
	meta="$me/map_meta.txt"
	;;
snow)
	echo "the snow viewpoint is viewpoint 5 of the reference world now;" >&2
	echo "run: $0 reference" >&2
	exit 2
	;;
*)
	echo "unknown fixture: $fixture" >&2; exit 2 ;;
esac

# The fixture is the whole parameter file, not a seed and a few keys. The
# mgvalleys_* scalars in it decide where snow sits, and a world generated
# without them is not a nearby world, it is an unrelated one -- which is what
# the sixteen superseded pictures were of. The seed is build.sh's reading of
# that file, and the fixture refuses any other world's.
seed=$REFSHOT_SEED

# And a seed reproduces a world only under the game that made it: five minor
# versions of biome changes put a flower meadow where the reference has snow.
# Checked rather than trusted, because generating a different world silently is
# the worst failure available here -- the pictures look fine.
want_vl=$REFSHOT_VL_VERSION
have_vl=$(sed -n 's/^version *= *//p' "$luanti/games/mineclone2/game.conf")
if [ -n "$want_vl" ] && [ "$want_vl" != "$have_vl" ]; then
	echo "the fixture was generated by VoxeLibre $want_vl, the game here is" >&2
	echo "$have_vl: the set has to be re-taken rather than patched." >&2
	exit 2
fi

# MODE=unlit is the same twenty with Luanti's dynamic shadows off --
# [NON_PBR]'s half of this session -- and build.sh's conf carries that line.
# Shaders themselves have no switch left to throw; 5.18 dropped
# enable_shaders.

# The cache. Kept, not deleted: a bulk session generates the terrain once.
work="$worlds_root/$seed"
if [ ! -d "$work" ] && [ -n "${src_world:-}" ]; then
	echo "copying $(eval echo "$src_world") into $work  (cannot be regenerated; see the snow case)"
	mkdir -p "$(dirname "$work")"
	cp -r "$(eval echo "$src_world")" "$work"
elif [ ! -d "$work" ]; then
	echo "generating $seed into $work"
	mkdir -p "$work"
	cat > "$work/world.mt" <<-EOF
		gameid = mineclone2
		backend = sqlite3
		player_backend = sqlite3
		auth_backend = sqlite3
		mod_storage_backend = sqlite3
		world_name = refshots_$seed
		creative_mode = false
		enable_damage = false
		server_announce = false
	EOF
	# Copied in whole, every line of it. Deleting map.sqlite from a cache
	# and letting it regenerate gives the same world back; that is the check
	# to repeat whenever the fixture is touched.
	cp "$meta" "$work/map_meta.txt"
else
	echo "reusing cached world $work"
fi

mkdir -p "$out" "$work/worldmods"
# A leftover worldmod in the cache (a probe that shuts the server down)
# is otherwise loaded next to this one.
find "$work/worldmods" -mindepth 1 -maxdepth 1 ! -name refviews -exec rm -rf {} +
# The mod form of the fixture. PROBE=1 shoots only the states probes.sh
# reads -- fifteen seconds against two minutes, which is what a tuning
# cycle wants -- and build.sh wrote that into it; see [PROBE_CYCLE].
rm -rf "$work/worldmods/refviews"
cp -r "$built/refviews" "$work/worldmods/refviews"

log=$(mktemp /tmp/refshots_srv.XXXXXX.log)
# A leftover official run still holds the world sqlite. Kill it rather
# than start a second one on a different port into the same files.
if pgrep -x luanti-refshots >/dev/null || pgrep -x luanti >/dev/null; then
	echo "killing leftover luanti" >&2
	killall -TERM luanti-refshots luanti 2>/dev/null || true
	sleep 1
	killall -KILL luanti-refshots luanti 2>/dev/null || true
	sleep 1
fi
# A port the client's own sandbox has already been told about. The extension
# goes through client/core/network, which asks the user before a script opens a
# socket and remembers the answer for a week; a fresh random port every run
# would put that dialog in front of every run, and the harness is not the
# thing to answer it. 30030 is one the user has accepted for a local Luanti
# server. When the week runs out the dialog comes back and wants one click.
if [ "$CLIENT" = "extension" ]; then
	port=${PORT:-30030}
else
	port=${PORT:-$(( 31000 + (RANDOM % 200) ))}
fi
cd "$luanti"
"$bin" --server --world "$work" --port "$port" --config "$conf" \
	> "$log" 2>&1 &
srv=$!
# A mineclone2 world takes more than five seconds to load, and a freshly
# generated one takes longer than a cached one
for i in $(seq 1 300); do
	grep -q "Server for gameid" "$log" 2>/dev/null && break
	sleep 1
done
sleep 5

# Which client is in front of the server. The extension is a Luanti client of
# its own -- it speaks the protocol to an unmodified server -- so it takes its
# half of the set through this same server and this same worldmod, which is
# what makes the three sets comparable. See "The other two clients shoot the
# same set" in doc/plan/rendering_plan.md. The module's half is the odd one
# out and has a script of its own, because it runs the game itself.
if [ "$CLIENT" = "extension" ]; then
	# Three passes rather than two: this client fetches the server's media and
	# meshes the world as it goes, so the second is still catching up
	CYCLES="${CYCLES:-3}"
	# Nothing to click: BUILDAT_LUANTI_CONNECT skips the extension's connect
	# dialog, whose focus sits in a LineEdit that swallows Return. The command
	# file only has to keep the client alive -- the shooter below decides when
	# the run is over.
	cmds=$(mktemp /tmp/refshots_ext.XXXXXX.txt)
	{ echo "delay 1800000"; echo "quit"; } > "$cmds"
	BUILDAT_LUANTI_ADDRESS="127.0.0.1:$port" BUILDAT_LUANTI_NAME=ref \
		BUILDAT_LUANTI_CONNECT=1 BUILDAT_RENDER_MODE="$MODE" \
		"$here/Build/bin/buildat" -m luanti_client -w "${REFSHOT_W}x$REFSHOT_H" -l 3 \
		-c @"$cmds" > /tmp/refshots_ext.log 2>&1 &
	cli=$!
else
	"$bin" --go --address 127.0.0.1 --port "$port" --name ref \
		--config "$conf" > /tmp/refshots_cli.log 2>&1 &
	cli=$!
fi

shoot_states

kill "$cli" 2>/dev/null
sleep 1
kill "$srv" 2>/dev/null
for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
kill -9 "$srv" 2>/dev/null
echo -n "done: "
check_shots
