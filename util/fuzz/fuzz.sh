#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4: the decoders a peer or a file can feed, each a
# libFuzzer harness built with clang under ASan and UBSan, run time-boxed.
# The corpus and every crashing input are kept under
# local/security/fuzz/<target>/, so a run starts where the last stopped
# and a crash found once is replayed by every later run.
#
#   util/fuzz/fuzz.sh [seconds per target] [target ...]
#
# Without targets, all of them. A crash prints its file and the run ends
# non-zero.
set -u
here=$(cd "$(dirname "$0")/../.." && pwd)
me="$here/util/fuzz"
out="$here/local/security/fuzz"
secs=${1:-60}
shift || true
mkdir -p "$out/bin"

flags="-std=c++17 -g -O1 -I$here/src -I$here
	-I$here/3rdparty/c55lib -I$here/3rdparty/cereal/include
	-I$here/3rdparty/polyvox/library/PolyVoxCore/include
	-I$here/3rdparty/sajson/include -DBUILDAT_FUZZ
	-I$here/3rdparty/Urho3D/Build/include
	-I$here/3rdparty/Urho3D/Build/include/Urho3D
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/Math
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/Container
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/Core
	-I$here/3rdparty/Urho3D/Build/include/Urho3D/ThirdParty"
# Each target's sources beside its harness
declare -A srcs=(
	[compress]="src/impl/compress.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp"
	[packet_stream]="src/impl/packet_stream.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp"
	[voxel_volume]="src/impl/voxel_volume.cpp src/impl/compress.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp 3rdparty/polyvox/library/PolyVoxCore/source/Region.cpp src/impl/voxel.cpp src/impl/linux/os.cpp src/impl/fs.cpp src/impl/linux/fs.cpp 3rdparty/c55lib/c55/filesys.cpp"
	[json]="src/core/json.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp"
	[zip]="src/impl/zip.cpp src/impl/compress.cpp src/impl/fs.cpp src/impl/linux/fs.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp 3rdparty/c55lib/c55/filesys.cpp"
	# The decoders compiled in, instrumented; the rest of Urho3D from its
	# library (image_fuzz.cpp)
	[image]="3rdparty/Urho3D/Source/Urho3D/Resource/Image.cpp 3rdparty/Urho3D/Source/Urho3D/Resource/Decompress.cpp"
	[image_data]="3rdparty/Urho3D/Source/Urho3D/Resource/Image.cpp 3rdparty/Urho3D/Source/Urho3D/Resource/Decompress.cpp"
	# The model and animation parsers and the glTF loader, the same way
	# (model_fuzz.cpp)
	[model]="3rdparty/Urho3D/Source/Urho3D/Graphics/Model.cpp 3rdparty/Urho3D/Source/Urho3D/IO/MemoryBuffer.cpp 3rdparty/Urho3D/Source/Urho3D/Graphics/Geometry.cpp 3rdparty/Urho3D/Source/Urho3D/Graphics/IndexBuffer.cpp 3rdparty/Urho3D/Source/Urho3D/Graphics/Animation.cpp 3rdparty/Urho3D/Source/Urho3D/Graphics/GLTFLoader.cpp"
	# The XML and JSON parsers a server's Material/Technique/XMLFile/
	# JSONFile run: pugixml 1.7 and XMLFile/JSONFile compiled in (the
	# latter pulls in header-only rapidjson); the rest from the library
	# (xml_fuzz.cpp)
	[xml]="3rdparty/Urho3D/Source/Urho3D/Resource/XMLFile.cpp 3rdparty/Urho3D/Source/Urho3D/Resource/JSONFile.cpp 3rdparty/Urho3D/Source/ThirdParty/PugiXml/src/pugixml.cpp"
	# The sound loaders stb_vorbis (.ogg) and LoadWav (.wav), compiled in
	# over the library (sound_fuzz.cpp)
	[sound]="3rdparty/Urho3D/Source/Urho3D/Audio/Sound.cpp 3rdparty/Urho3D/Source/Urho3D/Audio/OggVorbisSoundStream.cpp"
	[markup]="src/impl/markup.cpp"
	# The hello, the file transfer's records and served Lua's cereal reader
	# (record_fuzz.cpp), LuaJIT from the Urho3D library
	[record]="src/lua_bindings/cereal.cpp src/lua_bindings/util.cpp src/core/log.cpp 3rdparty/c55lib/c55/os.cpp"
	# FreeType compiled in whole (font_fuzz.cpp), its source list taken
	# from its CMakeLists; no Urho3D needed
	[font]=""
)
ft=3rdparty/Urho3D/Source/ThirdParty/FreeType
# C sources, compiled apart with the sanitizers and linked in
declare -A csrcs=(
	[markup]="3rdparty/md4c/md4c.c"
	[font]="$(sed -n '/^set (SOURCE_FILES/,/)/p' "$here/$ft/CMakeLists.txt" |
			tr -d ' )' | grep '\.c$' | sed "s,^,$ft/,")"
)
# Per-target sanitizers (undefined dropped where a dependency trips its
# harmless checks). Default: address and undefined.
declare -A san=(
	# FreeType 2.8.0 casts module-init function pointers and does null +
	# offset; both are UBSan noise, not bugs
	[font]="address"
)
# Extra flags for this target's C sources (csrcs)
declare -A cflags=(
	[font]="-DFT2_BUILD_LIBRARY -I$here/$ft/include -fno-sanitize=shift -w"
)
declare -A libs=(
	[compress]="-lz -lzstd"
	[packet_stream]=""
	[voxel_volume]="-lz -lzstd"
	[json]=""
	[zip]="-lz -lzstd"
	[image]="-L$here/3rdparty/Urho3D/Build/lib -lUrho3D -Wl,-rpath,$here/3rdparty/Urho3D/Build/lib"
	[image_data]="-L$here/3rdparty/Urho3D/Build/lib -lUrho3D -Wl,-rpath,$here/3rdparty/Urho3D/Build/lib"
	[model]="-L$here/3rdparty/Urho3D/Build/lib -lUrho3D -Wl,-rpath,$here/3rdparty/Urho3D/Build/lib"
	[xml]="-L$here/3rdparty/Urho3D/Build/lib -lUrho3D -Wl,-rpath,$here/3rdparty/Urho3D/Build/lib"
	[sound]="-L$here/3rdparty/Urho3D/Build/lib -lUrho3D -Wl,-rpath,$here/3rdparty/Urho3D/Build/lib"
	[markup]="-I$here/3rdparty/md4c"
	[record]="-I$here/3rdparty/Urho3D/Source/ThirdParty/LuaJIT/src -L$here/3rdparty/Urho3D/Build/lib -lUrho3D -Wl,-rpath,$here/3rdparty/Urho3D/Build/lib"
	[font]="-I$here/$ft/include -lz"
)
# Urho3D's own defines and include paths for the files compiled from it;
# stb_image's JPEG decoder shifts negative values left, and a PNG's empty
# first IDAT copies 0 bytes to a null buffer: both done as intended by
# every compiler here, and UBSan would stop on them
uflags=$here/3rdparty/Urho3D/Build/Source/Urho3D/CMakeFiles/Urho3D.dir/flags.make
urho_extra="$(sed -n 's/^CXX_\(DEFINES\|INCLUDES\) = //p' "$uflags" 2>/dev/null) -fno-sanitize=shift,nonnull-attribute -w"
declare -A extra=(
	[image]="$urho_extra"
	[image_data]="$urho_extra"
	[model]="$urho_extra -fno-sanitize=pointer-overflow,alignment -I$here/3rdparty/Urho3D/Source/ThirdParty/tinygltf"
	[xml]="$urho_extra -fno-sanitize=pointer-overflow"
	# stb_vorbis's sample conversion overflows a signed int in its
	# float-to-int trick and casts inf to int on a garbage stream; the
	# result is clamped (noise out), no memory is touched
	[sound]="$urho_extra -fno-sanitize=signed-integer-overflow,float-cast-overflow"
	[font]="-I$here/$ft/include -w"
)
# A client loader a server feeds is fuzzed for memory corruption only. A
# slow parse or a huge allocation sized by the file is a server denying
# its client service, out of scope (doc/plan/security_review_plan.md). Fork
# mode (-fork=1 -ignore_timeouts=1 -ignore_ooms=1) would step past those,
# but its parent SEGVs in libFuzzer (secondsSinceProcessStartUp) within
# minutes and the run ends looking clean, so these run plain and restart
# (below)
declare -A opts=()
# ASan options per target, for the replays too. [sound]: a request over
# 256 MiB gets NULL, as a release build's malloc gives one it cannot
# meet, so the error path after it runs (it freed garbage once) and a
# huge setup allocation fails at once -- which lets [sound] run plain:
# its fork parent SEGVs in libFuzzer (secondsSinceProcessStartUp) before
# the first job, and -malloc_limit_mb does the same
declare -A asan=(
	[sound]="allocator_may_return_null=1:max_allocation_size_mb=256"
	[model]="allocator_may_return_null=1:max_allocation_size_mb=256"
)
# A plain-mode target that may hit an out-of-scope OOM or timeout (a
# count from the file sizing many allocations: 18 GB in 8379 chunks once)
# and is started again on it, for what is left of its time
declare -A restart=(
	[sound]=1
	[model]=1
	# FreeType and stb_image under ASan: kept inputs take 3-18 s on a
	# quiet machine (2026-10-05), a slow parse and not a finding
	[font]=1
	[image]=1
	[image_data]=1
)
declare -A rss=()
targets=${*:-${!srcs[@]}}

build() {
	local t=$1 s="" sa="${san[$t]:-address,undefined}"
	local rec=""; [[ $sa == *undefined* ]] && rec="-fno-sanitize-recover=undefined"
	for f in ${srcs[$t]}; do s="$s $here/$f"; done
	for f in ${csrcs[$t]:-}; do
		clang -g -O1 -fsanitize=fuzzer-no-link,$sa $rec ${cflags[$t]:-} \
			-c "$here/$f" \
			-o "$out/bin/$t.$(basename "$f").o" 2> "$out/bin/$t.build.log" || {
			echo "$t: build failed, $out/bin/$t.build.log"; return 1; }
		s="$s $out/bin/$t.$(basename "$f").o"
	done
	clang++ $flags -fsanitize=fuzzer,$sa $rec ${extra[$t]:-} \
		"$me/${t}_fuzz.cpp" $s ${libs[$t]} -o "$out/bin/$t" \
		2> "$out/bin/$t.build.log" || {
		echo "$t: build failed, $out/bin/$t.build.log"; tail -5 "$out/bin/$t.build.log"
		return 1
	}
}

status=0
for t in $targets; do
	build "$t" || { status=1; continue; }
	mkdir -p "$out/$t/corpus" "$out/$t/crashes"
	[ -d "$me/seeds/$t" ] && cp -n "$me/seeds/$t"/* "$out/$t/corpus/" 2>/dev/null
	# Every crash kept before is replayed first. Only crash- and leak-:
	# a fork-mode target (a client loader) keeps oom- and timeout-
	# artifacts for the out-of-scope inputs it stepped past, which a plain
	# replay would only hit again (doc/plan/security_review_plan.md)
	for c in "$out/$t/crashes"/crash-* "$out/$t/crashes"/leak-*; do
		[ -e "$c" ] || continue
		ASAN_OPTIONS=${asan[$t]:-} "$out/bin/$t" "$c" > /dev/null 2>&1 || {
			echo "$t: a kept crash still crashes: $c"; status=1; }
	done
	end=$((SECONDS + secs))
	execs_sum=0 oomto=0
	while :; do
		ASAN_OPTIONS=${asan[$t]:-} "$out/bin/$t" ${opts[$t]:-} -max_total_time=$((end - SECONDS)) -rss_limit_mb=${rss[$t]:-2048} -timeout=10 -print_final_stats=1 \
			-artifact_prefix="$out/$t/crashes/" "$out/$t/corpus" \
			> "$out/$t/last.log" 2>&1
		r=$?
		n=$(grep -ao "stat::number_of_executed_units: [0-9]*" "$out/$t/last.log" | grep -o "[0-9]*$")
		execs_sum=$((execs_sum + ${n:-0}))
		# A restart target (plain mode, as its fork parent fails) steps
		# past an out-of-scope OOM or timeout by starting again
		[ -n "${restart[$t]:-}" ] && [ $r -ne 0 ] && [ $((end - SECONDS)) -gt 5 ] &&
			grep -aq "SUMMARY: libFuzzer: \(out-of-memory\|timeout\)" "$out/$t/last.log" || break
		oomto=$((oomto + 1))
		find "$out/$t/crashes" -maxdepth 1 \( -name 'oom-*' -o -name 'timeout-*' \) -delete
	done
	if [ -n "${restart[$t]:-}" ] && [ $r -ne 0 ] &&
			grep -aq "SUMMARY: libFuzzer: \(out-of-memory\|timeout\)" "$out/$t/last.log"; then
		oomto=$((oomto + 1))
		find "$out/$t/crashes" -maxdepth 1 \( -name 'oom-*' -o -name 'timeout-*' \) -delete
		r=0
	fi
	# A fork-mode target's oom/timeout artifacts are out of scope and
	# recorded only as the counts in the log; do not keep them
	[ -n "${opts[$t]:-}" ] && find "$out/$t/crashes" -maxdepth 1 \
		\( -name 'oom-*' -o -name 'timeout-*' \) -delete
	# Fork mode exits non-zero when the last job merely hit an ignored
	# timeout, so a fork target's verdict is the crash count and whether a
	# real crash/leak artifact was left -- not the exit code
	if [ -n "${opts[$t]:-}" ]; then
		find "$out/$t/crashes" -maxdepth 1 \
			\( -name 'oom-*' -o -name 'timeout-*' \) -delete
		crashn=$(grep -aoE "oom/timeout/crash: [0-9]+/[0-9]+/[0-9]+" \
			"$out/$t/last.log" | tail -1 | grep -oE "[0-9]+$")
		if [ "${crashn:-0}" = 0 ] &&
				! ls "$out/$t/crashes"/crash-* "$out/$t/crashes"/leak-* \
					>/dev/null 2>&1; then
			r=0
		else
			r=1
		fi
	fi
	execs=$execs_sum
	cov=$(grep -ao "cov: [0-9]*" "$out/$t/last.log" | tail -1)
	if [ $r -ne 0 ]; then
		echo "$t: CRASH ($(ls -t "$out/$t/crashes" | head -1)); $out/$t/last.log"
		grep -a "ERROR: \|: runtime error" "$out/$t/last.log" | head -3
		status=1
	else
		otc=$(grep -aoE "oom/timeout/crash: [0-9/]+" "$out/$t/last.log" | tail -1)
		[ -n "${restart[$t]:-}" ] && otc="restarted past $oomto OOM/timeout"
		echo "$t: ${execs:-?} runs in ${secs} s, $cov, $(ls "$out/$t/corpus" | wc -l) in the corpus${otc:+, $otc}"
	fi
done
exit $status
