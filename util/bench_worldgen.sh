#!/bin/bash
# How long a world takes to make itself.
#
#   util/bench_worldgen.sh [game] [runs] [seed] [sections across] [save]
#
# The server alone -- no client, nothing connected -- making a new world out
# of a fixed seed, which is the one phase of a Luanti game that is entirely
# this engine's own work: the mapgen, the light, the serialization and the
# streamer. Every run starts from an empty save and the same seed and asks
# for the same box of sections, so every run does the same work, which is
# what makes two of them comparable.
#
# The box is what makes it a workload rather than a moment: the world around
# the origin is a few dozen sections and over in three seconds, which is
# mostly startup. Six across is 6 x 2 x 6 sections and about half a minute of
# devtest.
#
# What it prints per run is how many sections were generated and how long the
# generation took, and then the median. Read the median: a single run of
# anything here moves by tens of percent with whatever else the machine is
# doing, which is how a "throughput" number that meant nothing got into
# doc/most_important_performance_issues.txt once.
#
# The seed is Luanti's own fixed_map_seed, written into the save's world.mt
# before the server opens it. Anything else that needs to be the same between
# runs goes in the same place.
set -u
. "$(dirname "$0")/check_lib.sh"

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
game="${1:-devtest}"
runs="${2:-3}"
seed="${3:-20260915}"
across="${4:-6}"
save="${5:-bench_worldgen}"
build="$root/Build"
saves="$BUILDAT_USER_PATH/apps/vanilla/saves"
out="$(mktemp -d /tmp/buildat_bench_worldgen.XXXXXX)"
trap '[ -n "${KEEP_TMP:-}" ] && echo "kept $out" >&2 || rm -rf "$out"' EXIT

if [ ! -x "$build/bin/buildat_server" ]; then
	echo "no server at $build/bin/buildat_server" >&2
	exit 1
fi

# The seconds between the first and the last section the generator started,
# out of the log's own timestamps -- which are HH:MM:SS.mmm whatever the
# locale puts in front of them
span_of() {
	awk '/Generating section/ {
			split($3, t, ":")
			s = t[1] * 3600 + t[2] * 60 + t[3]
			if(n == 0) first = s
			last = s
			n++
		}
		END {
			if(n == 0){ print "0 0"; exit }
			printf "%d %.1f\n", n, last - first
		}' "$1"
}

# The workload: a box of sections pinned where the streamer will make them
# and then stop. Written here rather than kept beside the harness, so that
# the box and the run that reads it cannot drift apart.
probe="$out/bench.lua"
cat > "$probe" <<LUA
-- Pinned so that the streamer makes exactly these and stops. A forceload is
-- a section with no radius around it; see __luanti_forceload(). The position
-- is a node's, which is what core.forceload_block() takes, and one per
-- section is all it takes to pin one.
local across = $across
core.after(1, function()
	local size = tonumber(__luanti_section_size) or 64
	local n, taken = 0, 0
	for x = 0, across - 1 do
	for y = -1, 0 do
	for z = 0, across - 1 do
		n = n + 1
		if core.forceload_block({x = x * size, y = y * size, z = z * size}) then
			taken = taken + 1
		end
	end
	end
	end
	core.log("action", "bench: asked for " .. n .. " sections, " .. taken ..
			" taken")
end)
LUA

times=()
for i in $(seq 1 "$runs"); do
	rm -rf "${saves:?}/$save"
	mkdir -p "$saves/$save/luanti"
	{
		printf 'fixed_map_seed = %s\n' "$seed"
		# The builtin keeps sixteen forceloads by default and the workload
		# below is hundreds
		printf 'max_forceloaded_blocks = 100000\n'
	} > "$saves/$save/luanti/world.mt"
	port=$(( 30500 + (RANDOM % 100) ))
	log="$out/run$i.log"
	BUILDAT_LUANTI_GAME="$game" BUILDAT_LUANTI_SAVE="$save" \
		BUILDAT_LUANTI_LUA="$probe" \
		"$build/bin/buildat_server" -u launcher=1 -m "$root/apps/vanilla" \
		-D "$BUILDAT_USER_PATH" -P "$port" -l 4 \
		> "$log" 2>&1 &
	# Generation is over when no new section has been started for a while.
	# Five seconds of quiet, and a cap so that a server that never settles
	# does not hold the whole run.
	quiet=0
	last_n=-1
	for _ in $(seq 1 240); do
		sleep 1
		n=$(grep -c "Generating section" "$log" 2>/dev/null)
		n=${n:-0}
		if [ "$n" -gt 0 ] && [ "$n" -eq "$last_n" ]; then
			quiet=$(( quiet + 1 ))
			[ "$quiet" -ge 5 ] && break
		else
			quiet=0
		fi
		last_n=$n
	done
	check_pkill buildat_server
	sleep 2
	read -r n span <<< "$(span_of "$log")"
	printf 'run %d: %s sections in %s s\n' "$i" "$n" "$span"
	times+=("$span")
done

printf '%s\n' "${times[@]}" | sort -n | awk '
	{ v[NR] = $1 }
	END {
		if(NR == 0) exit
		m = (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2
		printf "median: %.1f s of %d runs\n", m, NR
	}'
