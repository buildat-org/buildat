#!/bin/bash
# The modding archives ([PACKAGING] in doc/plan/packaging_plan.md):
#
#   util/package.sh linux     -> buildat-<version>-<hash>-linux-x86_64-portable.tar.gz
#                                buildat-<version>-<hash>-linux-x86_64-xdg.tar.gz
#                                buildat-<version>-<hash>-linux-x86_64-web.tar.gz
#                                buildat-<version>-<hash>-linux-x86_64-web-precompiled.tar.gz
#   util/package.sh windows   -> buildat-<version>-<hash>-win64.zip (a cross build)
#
# The version is the VERSION file's and the hash the tree's short git hash
# ([VERSION]); a dirty tree is refused, since its archive would be nobody's
# commit. Outside a checkout (a tarball of the tree) the hash is "unknown".
#
# Configures a build tree per archive under Build/package/, builds, runs the
# install rules into a staging directory, gathers every third-party licence
# into licenses/, writes VERSION, makes the archive under Build/package/out/,
# and smoke-tests it: unpacks into a clean directory, starts buildat_server
# on apps/demo_digger -- which compiles a module at run time through the found
# or bundled compiler -- connects a client that takes one screenshot that is
# not black, and quits. Nothing is packaged by hand. Runs the same inside
# util/docker's images as on a desk.
#
# The two Linux archives differ by one flag: PORTABLE keeps user/ and cache/
# beside the program, xdg puts them where XDG_DATA_HOME and XDG_CACHE_HOME say.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target="${1:-}"
if [ -z "$target" ]; then
	echo "usage: util/package.sh <linux|windows>" >&2
	exit 2
fi
version=$(tr -d '[:space:]' < "$here/VERSION")
# BUILDAT_GIT_HASH is what package_in_docker.sh hands in: the container
# has a git archive, which has no .git
hash="${BUILDAT_GIT_HASH:-$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo unknown)}"
if [ -z "${BUILDAT_GIT_HASH:-}" ] && [ "$hash" != unknown ] &&
		! git -C "$here" diff --quiet HEAD 2>/dev/null; then
	echo "the tree has uncommitted changes; an archive is made from a commit" >&2
	exit 2
fi
version="$version-$hash"
jobs="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
root="$here/Build/package"
# Every temporary directory this makes, removed when the script ends
# however it ends ([TMP_HYGIENE]: 589 smoke directories held 4.7 GB of
# /tmp); KEEP_TMP=1 keeps them and says where
PKG_TMP_DIRS=""
trap 'if [ -n "${KEEP_TMP:-}" ]; then echo "kept:$PKG_TMP_DIRS" >&2; else rm -rf $PKG_TMP_DIRS; fi' EXIT
out="$root/out"
mkdir -p "$out"

# The licences the archive carries: buildat's own, every 3rdparty tree's
# and Urho3D's, and on Windows the compiler's, into one directory
gather_licenses() {
	local stage="$1"
	local lic="$stage/licenses"
	mkdir -p "$lic"
	cp "$here/NOTICE" "$lic/buildat-NOTICE.txt"
	[ -f "$here/LICENSE" ] && cp "$here/LICENSE" "$lic/buildat-LICENSE.txt"
	local d name f
	for d in "$here"/3rdparty/*/; do
		name=$(basename "$d")
		for f in "$d"LICENSE "$d"LICENSE.txt "$d"LICENSE.TXT "$d"COPYING "$d"COPYING.txt "$d"License.txt; do
			[ -f "$f" ] && cp "$f" "$lic/$name-$(basename "$f")"
		done
	done
	# One a tree carries inside it, compiled into the client
	cp "$here/3rdparty/wabt/third_party/picosha2/LICENSE" "$lic/wabt-picosha2-LICENSE"
	[ -d "$stage/compiler/licenses" ] && cp -r "$stage/compiler/licenses" "$lic/mingw-w64"
	return 0
}

# The Windows archive stands alone: every DLL an exe or dll in it imports
# is in the archive or is Windows' own. Wine never proved this -- it
# finds what a DLL wants in the image's mingw bin/ and its own built-ins
# -- and 0.3.1 shipped a libcurl whose DLL failed to initialise on a
# desktop ([WIN_DLL_INIT]). objdump -p lists the imports; the compiler
# tree under compiler/ is a distribution of its own and is left out.
check_imports() {
	local archive="$1"
	local objdump
	objdump=$(command -v x86_64-w64-mingw32-objdump || command -v objdump) || {
		echo "import check: no objdump here; not run"; return 0; }
	local dir
	dir=$(mktemp -d "/tmp/buildat_package_check_imports.XXXXXX")
	PKG_TMP_DIRS="$PKG_TMP_DIRS $dir"
	unzip -q "$archive" -d "$dir" || { echo "import check: cannot unzip $archive" >&2; exit 1; }
	# Windows' own, lower case; the api-ms-win-* set by prefix, except the
	# api-ms-win-crt-* ones: those are the UCRT, and this archive is built
	# on msvcrt -- a DLL importing them brings a second C runtime into the
	# process, which is what 0.3.1's libcurl did
	local own=" kernel32.dll user32.dll gdi32.dll advapi32.dll shell32.dll \
ole32.dll oleaut32.dll ws2_32.dll wsock32.dll opengl32.dll winmm.dll dbghelp.dll \
imm32.dll version.dll setupapi.dll crypt32.dll bcrypt.dll secur32.dll \
iphlpapi.dll msvcrt.dll comdlg32.dll shlwapi.dll uuid.dll rpcrt4.dll \
wldap32.dll normaliz.dll ntdll.dll psapi.dll userenv.dll cfgmgr32.dll \
hid.dll dinput8.dll dxgi.dll d3d11.dll d3d9.dll xinput1_4.dll \
xinput9_1_0.dll dwmapi.dll "
	local bad=0 f name have
	have=$(find "$dir" -path '*/compiler' -prune -o -iname '*.dll' -print \
		| xargs -n1 basename | tr 'A-Z' 'a-z' | sort -u)
	while IFS= read -r f; do
		for name in $("$objdump" -p "$f" 2>/dev/null | awk '/DLL Name:/ {print tolower($3)}'); do
			case "$name" in
			api-ms-win-crt-*)
				echo "import check: ${f#$dir/} imports $name: the UCRT, a second C runtime" >&2
				bad=1; continue ;;
			api-ms-win-*) continue ;;
			esac
			if ! grep -qx "$name" <<<"$have" && [[ "$own" != *" $name "* ]]; then
				echo "import check: ${f#$dir/} imports $name, which the archive does not carry" >&2
				bad=1
			fi
		done
	done < <(find "$dir" -path '*/compiler' -prune -o \( -iname '*.exe' -o -iname '*.dll' \) -print)
	# And no DLL of the archive's own exports what the runtime DLLs
	# export: a static runtime linked into a DLL that exports everything
	# is a second copy of that runtime, and whoever links against the
	# DLL's import library may take it -- libbuildat_core took
	# Urho3D.dll's pthread_once, which had never run its init, and
	# called a null pointer ([WIN8_START] 16)
	local runtime own_exports
	runtime=$(mktemp); own_exports=$(mktemp)
	while IFS= read -r f; do
		local base
		base=$(basename "$f" | tr 'A-Z' 'a-z')
		local into="$own_exports"
		case "$base" in
			libstdc++-6.dll|libgcc_s_seh-1.dll|libwinpthread-1.dll) into="$runtime" ;;
		esac
		"$objdump" -p "$f" 2>/dev/null | awk -v F="$(basename "$f")" '
			/^\[Ordinal\/Name Pointer\] Table/ {t=1; next}
			t && /^\t\[ *[0-9]+\] / {print $NF, F}
			t && /^$/ {t=0}' >> "$into"
	done < <(find "$dir/"*/bin "$dir/"*/cache -iname '*.dll' 2>/dev/null)
	local dup
	# C++-mangled ones (_Z...) are template instantiations the same in
	# every image, the ODR's business; a plain C symbol is the runtime's
	dup=$(awk 'NR==FNR {r[$1]=$2; next} ($1 in r) && $1 !~ /^_Z/ {print $1": "$2" (the runtime\x27s, "r[$1]")"}' "$runtime" "$own_exports" | sort | head -20)
	if [ -n "$dup" ]; then
		echo "import check: a runtime's symbol exported by the archive's own DLL, a runtime linked into it ($(awk 'NR==FNR {r[$1]; next} ($1 in r) && $1 !~ /^_Z/' "$runtime" "$own_exports" | wc -l) of them; the first 20):" >&2
		echo "$dup" | sed 's/^/  /' >&2
		bad=1
	fi
	rm -f "$runtime" "$own_exports"
	rm -rf "$dir"
	[ "$bad" = 0 ] || { echo "import check failed" >&2; exit 1; }
	echo "import check: every import is in the archive or Windows' own, and no symbol is exported twice"
}

# The Windows archive under Wine: the half that says the archive works
# where it is going -- buildat_server.exe compiling every module of a game
# with the compiler the archive ships -- and not yet the client, which
# wants GL under Wine on top. Skipped with a word where there is no wine.
smoke_test_wine() {
	local archive="$1"
	if ! command -v wine64 >/dev/null 2>&1 && ! command -v wine >/dev/null 2>&1; then
		echo "smoke test under Wine: no wine here; not run"
		return 0
	fi
	local wine
	wine=$(command -v wine64 || command -v wine)
	local dir
	dir=$(mktemp -d "/tmp/buildat_package_smoke_test_wine.XXXXXX")
	PKG_TMP_DIRS="$PKG_TMP_DIRS $dir"
	(cd "$dir" && unzip -q "$archive")
	local unpacked
	unpacked=$(ls -d "$dir"/*/ | head -1)
	local port=$(( 29600 + (RANDOM % 90) ))
	echo "smoke test under Wine in $unpacked"
	export WINEDEBUG=-all WINEPREFIX="$dir/wine"
	# A crash's report and not its dialog: winedbg shows a "Program
	# Error" box on the display first and writes the backtrace when it
	# is closed, which nobody does on the virtual display -- the smoke's
	# client sat in it until its timeout and the log ended on "starting
	# debugger..." ([WIN_SMOKE_STALL])
	"$wine" reg add 'HKCU\Software\Wine\WineDbg' /v ShowCrashDialog /t REG_DWORD /d 0 /f > /dev/null 2>&1 || true
	# One virtual display for the whole of it: the wineserver the server's
	# run starts is the one the client's run finds, and it keeps the
	# display it was started without
	local xvfb_pid=""
	if [ -z "${DISPLAY:-}" ] && command -v Xvfb >/dev/null 2>&1; then
		Xvfb :97 -screen 0 1280x720x24 > /dev/null 2>&1 &
		xvfb_pid=$!
		export DISPLAY=:97
		sleep 2
	fi
	# With TEMP and TMP unset, as a desktop with nothing set ([WIN_TMP]);
	# Wine gives its own from the registry, so this proves less than a
	# desktop does, and the desktop is the done-when
	rm -f "$unpacked"/cache/rccpp_build/client_file*
	# **Unboxed, and joined by the pipe** ([PROCESS_SANDBOX] B): Wine has
	# no AppContainer, so the box cannot be made under it; BUILDAT_PIPE=1
	# has the server listen on a pipe outside any container's namespace
	# as well, and the client joins by it -- the transport a boxed local
	# server is joined by on Windows
	(cd "$unpacked" && env -u TEMP -u TMP -u TMPDIR BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=smoke \
		BUILDAT_LUANTI_FETCH_ONCE=1 BUILDAT_CONTENTDB_URL="file://Z:$dir/nowhere" \
		BUILDAT_UNCONFINED=1 BUILDAT_PIPE=1 \
		"$wine" bin/buildat_server.exe -u launcher=1 -m apps/vanilla -P "$port" -l 4 > "$dir/srv.log" 2>&1) &
	local srv=$!
	local i
	wait_for_vanilla "$dir/srv.log" "$srv" "smoke test under Wine" || {
		kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true; exit 1; }
	if ! grep -q "STATUS Compiling client_file" "$dir/srv.log"; then
		echo "smoke test under Wine: the shipped compiler built nothing (client_file was taken out of the cache)" >&2
		"$wine"server -k 2>/dev/null || true; exit 1
	fi
	# [PACKAGE_PREBUILT_WASM] No clang for Windows here: the archive's own
	if ! grep -q "voxelworld: wasm/ is \(built (cache hit)\|in the shared build\)" "$dir/srv.log"; then
		echo "smoke test under Wine: voxelworld's .wasm not served from the archive's cache:" >&2
		grep "voxelworld: wasm/\|has wasm/" "$dir/srv.log" | head -5 >&2
		"$wine"server -k 2>/dev/null || true; exit 1
	fi
	if ! wait_for_line "$dir/srv.log" "$srv" "contentdb: fetched once" 60; then
		echo "smoke test under Wine: the server's one ContentDB fetch never answered (http_get died or hangs)" >&2
		"$wine"server -k 2>/dev/null || true; exit 1
	fi
	# And the client, on the virtual display through Wine's GL, which is
	# software rendering; what it has to have done is what the Linux smoke
	# asks: joined, drawn a chunk, run its commands to the end
	sleep 5
	printf 'delay 25000\nscreenshot %s/shot.png\nquit\n' "Z:$dir" > "$dir/cmds.txt"
	# Under the server's stall rule: a dialog or a deadlock -- winedbg's
	# crash box before ShowCrashDialog was off -- costs half a minute,
	# not the ceiling
	(cd "$unpacked" && "$wine" bin/buildat.exe -s "pipe:\\\\.\\pipe\\buildat-$port" -w 640x360 -l 3 -c "@Z:$dir/cmds.txt" > "$dir/cli.log" 2>&1) &
	local cli=$!
	wait_for_line "$dir/cli.log" "$cli" "Command sequence complete" 180 || true
	sleep 5
	kill -9 "$cli" 2>/dev/null || true; wait "$cli" 2>/dev/null || true
	kill -INT "$srv" 2>/dev/null || true; sleep 3; kill -9 "$srv" 2>/dev/null || true
	wait "$srv" 2>/dev/null || true
	"$wine"server -k 2>/dev/null || true
	[ -n "$xvfb_pid" ] && kill "$xvfb_pid" 2>/dev/null
	if ! grep -q "Connect succeeded" "$dir/cli.log" ||
			! grep -q "drawn again\|Node update\|player physics enabled\|chunks in scene" "$dir/cli.log"; then
		echo "smoke test under Wine: the client did not join and draw; its log:" >&2
		tail -40 "$dir/cli.log" >&2
		exit 1
	fi
	# Whether it ran its commands to the end is reported and not a
	# verdict: the luanti client joined, drew and then page-faulted in
	# Wine's software GL two seconds in ([WIN_MAPGEN_BUILD], 2026-09-20),
	# which the desktop is the place to read
	if ! grep -q "Command sequence complete" "$dir/cli.log"; then
		echo "smoke test under Wine: the client joined and drew but did not finish its commands; its log's end:" >&2
		tail -20 "$dir/cli.log" >&2
		read_crash "$dir/cli.log" || exit 1
	fi
	# Reported, not a verdict, as the commands' end above
	echo "smoke test under Wine: the client's voxelworld wasm: $(grep -o "wasm voxelworld: [a-z (]*" "$dir/cli.log" | tr '\n' ';')"
	echo "smoke test under Wine passed: the server compiled every module and generated a section, the client joined and drew"
}

# One archive: a build tree configured for it, the install rules into a
# staging directory named as the archive is, and the archive out of that
make_one() {
	local name="$1"; shift
	local build="$root/build-$name"
	local stage="$root/stage/$name"
	rm -rf "$stage"
	mkdir -p "$build" "$stage"
	(cd "$build" && cmake "$here" -DCMAKE_BUILD_TYPE=Release "$@" > cmake.log 2>&1) || {
		echo "configure failed; see $build/cmake.log" >&2; exit 1; }
	(cd "$build" && cmake --build . -j "$jobs" > build.log 2>&1) || {
		echo "build failed; see $build/build.log" >&2; exit 1; }
	(cd "$build" && cmake --install . --prefix "$stage" > install.log 2>&1) || {
		echo "install failed; see $build/install.log" >&2; exit 1; }
	gather_licenses "$stage"
	echo "$version" > "$stage/VERSION"
	# No CPU-specific code in what ships ([WIN_MARCH]): Urho3D's CMake
	# compiles for the building machine unless told otherwise, and a DLL
	# with AVX-512 in a static initialiser dies on any other box before the
	# smoke, which runs on the same machine, can see it. Every shipped exe,
	# DLL and .so disassembled; a %zmm register, a %ymm one or vpternlog
	# fails the packaging. A register only, with its %: a bare "ymm" is
	# also in a symbol name, psa_asymmetric_encrypt.
	if ! command -v objdump >/dev/null 2>&1; then
		echo "package.sh: no objdump to check the shipped binaries with (binutils)" >&2
		return 1
	fi
	{
		bad=""
		while IFS= read -r f; do
			n=$(objdump -d "$f" 2>/dev/null | grep -cE '%[yz]mm|vpternlog' || true)
			[ "$n" -gt 0 ] && bad="$bad $(basename "$f")=$n"
		done < <(find "$stage" -type f \( -name '*.exe' -o -name '*.dll' -o -name '*.so' -o -name '*.so.*' -o -name 'buildat' -o -name 'buildat_server' \) )
		if [ -n "$bad" ]; then
			echo "package.sh: CPU-specific code in what would ship:$bad" >&2
			echo "  (Urho3D's URHO3D_DEPLOYMENT_TARGET is not generic, or a compiler flag has -march)" >&2
			return 1
		fi
		echo "no zmm, ymm or vpternlog in the shipped binaries" >&2
	}
	# What built it ([WIN_DLL_INIT]): the toolchain packages' versions, into
	# the archive and the build log, so the next difference between two
	# archives of one source is read off two text files
	if command -v dpkg >/dev/null 2>&1; then
		{ echo "built $(date -u +%Y-%m-%dT%H:%MZ) from ${BUILDAT_GIT_HASH:-?}"
		  cat /etc/apt/sources.list 2>/dev/null | grep -v '^#'
		  dpkg -l 'mingw-w64*' 'gcc-mingw-w64*' 'binutils-mingw-w64*' \
			'gcc' 'g++' 'libc6' 'libstdc++6' 'cmake' 2>/dev/null \
			| awk '/^ii/ {print $2, $3}'
		  echo "march: generic (URHO3D_DEPLOYMENT_TARGET=generic; buildat's own binaries carry no -march)"
		} > "$stage/bin/TOOLCHAIN"
		# To stderr: this function's stdout is the archive's path
		echo "toolchain:" >&2; sed 's/^/  /' "$stage/bin/TOOLCHAIN" >&2
	fi
	# The builtin modules compiled into the archive ([PRECOMPILED]): a
	# portable archive carries its cache, and a module's output is named
	# by the sha1 of its source, includes and flags, so a cache filled
	# here is used as is on the box -- a cold start was 114 s of
	# compiling there. The staged tree's own server, on the shipped
	# compiler (under Wine for the Windows one), with apps/vanilla and
	# the minimal game, until it listens; then everything but
	# rccpp_build/ goes out of the cache again. The smoke keeps the
	# compiler's proof by building one module (see there).
	case "$name" in
		*portable*|*win64*)
			prebuild_wasm "$stage" >&2 || return 1
			prebuild_modules "$stage" "$name" >&2 || return 1 ;;
	esac
	case "$name" in
		*win64*)
			(cd "$stage/.." && rm -f "$out/$name.zip" && zip -qr "$out/$name.zip" "$name")
			echo "$out/$name.zip" ;;
		*)
			tar -C "$stage/.." -czf "$out/$name.tar.gz" "$name"
			echo "$out/$name.tar.gz" ;;
	esac
}

# [PACKAGE_PREBUILT_WASM] Each builtin's and extension's wasm/ (and
# [SERVER_WASM] server .wasm, by cargo for Rust) built into
# the stage's cache/rccpp_build/wasm/, which a packaged server reads as its
# shared build: one without clang and wasm-ld serves these (the client's
# fast path) instead of none. util/prebuild_wasm.py names each as the
# server does; a .wasm is the same on every platform, so the Windows
# archive's are built here by Linux tools. Linux's image has emsdk's clang
# and wasm-ld, Windows' Debian's clang and lld.
# simplified: not the apps' (hillclimb's car): a game's own builds on a
# server with the tools, as before; its dir in the find is the upgrade
prebuild_wasm() {
	local stage="$1" cc ld d mods=""
	local em="${EMSDK:-$HOME/emsdk}/upstream/bin"
	cc=${BUILDAT_WASM_CC:-$(command -v clang || echo "$em/clang")}
	ld=${BUILDAT_WASM_LD:-$(command -v wasm-ld || ls /usr/lib/llvm-*/bin/wasm-ld 2>/dev/null | tail -1 || true)}
	[ -n "$ld" ] || ld="$em/wasm-ld"
	for d in "$stage"/builtin/* "$stage"/extensions/*; do
		# A client's wasm/, or a server module's .wasm ([SERVER_WASM])
		{ [ -d "$d/wasm" ] || grep -qs '"server_wasm"' "$d/meta.json"; } &&
			mods="$mods $d"
	done
	[ -n "$mods" ] || { echo "prebuild wasm: no wasm/ in the stage"; return 1; }
	echo "prebuild wasm: $cc, $ld"
	# shellcheck disable=SC2086 # the module dirs, split
	python3 -I "$here/util/prebuild_wasm.py" "$cc" "$ld" "$stage/src/interface" \
		"$stage/cache/rccpp_build/wasm" $mods
}

# [WIN_INSTALLER]: the per-user installer out of a Windows archive's stage
# (util/installer.nsi): its top-level entries but user/ and cache/ as File
# lines, the same as removals for an upgrade and the uninstall, and the
# stage's prebuilt modules for the installed copy's cache
make_installer() {
	local name="$1"
	local stage="$root/stage/$name" files="$root/installer-$name"
	local exe="$out/$name-setup.exe"
	rm -rf "$files"; mkdir -p "$files"
	: > "$files/install.nsh"; : > "$files/remove.nsh"
	local p n
	for p in "$stage"/*; do
		n=$(basename "$p")
		case "$n" in user|cache) continue ;; esac
		if [ -d "$p" ]; then
			# Inside it: "File /r <dir>" takes a directory of that name at
			# any depth (user/apps for apps)
			printf 'SetOutPath "$INSTDIR\\%s"\nFile /r "%s/*"\n' "$n" "$p" \
				>> "$files/install.nsh"
			echo "RMDir /r \"\$INSTDIR\\$n\"" >> "$files/remove.nsh"
		else
			printf 'SetOutPath "$INSTDIR"\nFile "%s"\n' "$p" >> "$files/install.nsh"
			echo "Delete \"\$INSTDIR\\$n\"" >> "$files/remove.nsh"
		fi
	done
	makensis -V2 -DVERSION="$version" -DSTAGE="$stage" -DFILES="$files" \
		-DOUT="$exe" "$here/util/installer.nsi" > "$files/makensis.log" 2>&1 || {
		echo "makensis failed; see $files/makensis.log" >&2; return 1; }
	echo "$exe"
}

# The Luanti-only archive out of the full one's build tree and stage:
# a reconfigure with BUILDAT_LUANTI_ONLY, an install to its own stage,
# and the full stage's compiled modules copied in
make_luanti_only() {
	local full="$1" name="$2"; shift 2
	local build="$root/build-$full"
	local stage="$root/stage/$name"
	rm -rf "$stage"; mkdir -p "$stage"
	# The full build's own arguments again with the option: a bare
	# reconfigure of a cross build lost its toolchain in the container
	(cd "$build" && cmake "$here" "$@" -DBUILDAT_LUANTI_ONLY=TRUE > cmake-luanti.log 2>&1) || {
		echo "configure (luanti only) failed; see $build/cmake-luanti.log:" >&2
		tail -20 "$build/cmake-luanti.log" >&2; exit 1; }
	(cd "$build" && cmake --install . --prefix "$stage" > install-luanti.log 2>&1) || {
		echo "install (luanti only) failed; see $build/install-luanti.log" >&2; exit 1; }
	# The full archive's option back, so a later install of it is the full one
	(cd "$build" && cmake "$here" "$@" -DBUILDAT_LUANTI_ONLY=FALSE > /dev/null 2>&1) || true
	[ -d "$stage/compiler" ] && { echo "luanti only: compiler/ is in the archive" >&2; exit 1; }
	[ -d "$stage/apps/demo_digger" ] && { echo "luanti only: apps/demo_digger is in the archive" >&2; exit 1; }
	if [ -d "$root/stage/$full/cache/rccpp_build" ]; then
		mkdir -p "$stage/cache"
		cp -r "$root/stage/$full/cache/rccpp_build" "$stage/cache/"
	else
		echo "luanti only: the full stage has no prebuilt modules; the archive cannot start a game" >&2
	fi
	cp "$root/stage/$full/bin/TOOLCHAIN" "$stage/bin/" 2>/dev/null || true
	(cd "$stage/.." && rm -f "$out/$name.zip" && zip -qr "$out/$name.zip" "$name")
	echo "$out/$name.zip"
}

# The Luanti-only archive's smoke ([LUANTI_BUILD]): vanilla with the
# minimal game comes up on the prebuilt modules, the compiler is absent
# and the log says so
smoke_test_wine_luanti() {
	local archive="$1"
	if ! command -v wine64 >/dev/null 2>&1 && ! command -v wine >/dev/null 2>&1; then
		echo "luanti-only smoke under Wine: no wine here; not run"
		return 0
	fi
	local wine
	wine=$(command -v wine64 || command -v wine)
	local dir
	dir=$(mktemp -d "/tmp/buildat_package_smoke_test_wine_luanti.XXXXXX")
	PKG_TMP_DIRS="$PKG_TMP_DIRS $dir"
	(cd "$dir" && unzip -q "$archive")
	local unpacked
	unpacked=$(ls -d "$dir"/*/ | head -1)
	[ -d "$unpacked/compiler" ] && { echo "luanti-only smoke: compiler/ is present" >&2; exit 1; }
	local port=$(( 29600 + (RANDOM % 90) ))
	echo "luanti-only smoke under Wine in $unpacked"
	export WINEDEBUG=-all WINEPREFIX="$dir/wine"
	(cd "$unpacked" && env -u TEMP -u TMP -u TMPDIR BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=smoke \
		BUILDAT_LUANTI_FETCH_ONCE=1 BUILDAT_CONTENTDB_URL="file://Z:$dir/nowhere" \
		BUILDAT_UNCONFINED=1 \
		"$wine" bin/buildat_server.exe -u launcher=1 -m apps/vanilla -P "$port" -l 4 > "$dir/srv.log" 2>&1) &
	local srv=$!
	# -l 4, as the full smoke: the section line it waits for is logged there
	wait_for_vanilla "$dir/srv.log" "$srv" "luanti-only smoke under Wine" || {
		kill -9 "$srv" 2>/dev/null; wait "$srv" 2>/dev/null || true; exit 1; }
	if ! grep -q "No C++ compiler found: this archive ships none" "$dir/srv.log"; then
		echo "luanti-only smoke under Wine: the no-compiler line is not in the log" >&2
		"$wine"server -k 2>/dev/null || true; exit 1
	fi
	if grep -q "STATUS Compiling" "$dir/srv.log"; then
		echo "luanti-only smoke under Wine: something compiled, with no compiler?" >&2
		"$wine"server -k 2>/dev/null || true; exit 1
	fi
	"$wine"server -k 2>/dev/null || true
	wait "$srv" 2>/dev/null || true
	echo "luanti-only smoke under Wine: ok (vanilla up on the prebuilt modules, no compiler)"
	rm -rf "$dir"
}

prebuild_modules() {
	local stage="$1" name="$2"
	local port=$(( 29700 + (RANDOM % 90) ))
	local log="$stage/../prebuild-$name.log"
	local srv wine=""
	case "$name" in
		*win64*)
			if ! command -v wine64 >/dev/null 2>&1 && ! command -v wine >/dev/null 2>&1; then
				echo "prebuild: no wine here; the Windows archive ships no compiled modules"
				return 0
			fi
			wine=$(command -v wine64 || command -v wine)
			export WINEDEBUG=-all WINEPREFIX="$stage/../wine-prebuild"
			(cd "$stage" && env -u TEMP -u TMP -u TMPDIR BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=prebuild \
				BUILDAT_UNCONFINED=1 \
				"$wine" bin/buildat_server.exe -u launcher=1 -m apps/vanilla -P "$port" -l 3 > "$log" 2>&1) &
			;;
		*)
			# Unboxed ([PROCESS_SANDBOX]): this run is what writes the shared
			# build, which a boxed server only reads
			(cd "$stage" && BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=prebuild \
				BUILDAT_UNCONFINED=1 \
				bin/buildat_server -u launcher=1 -m apps/vanilla -P "$port" -l 3 > "$log" 2>&1) &
			;;
	esac
	srv=$!
	echo "prebuild: compiling the builtin modules into the archive's cache ($log)"
	if ! wait_for_line "$log" "$srv" "Listening at" 900; then
		kill -9 "$srv" 2>/dev/null
		# [WIN_PREBUILD_AS] A compiler that could not start a program of
		# its own ("cannot execute 'as'" under Wine, one module of 17 in
		# v0.7.31's run, the same compiler having built the rest): the run
		# once more, the modules built kept in the cache; a second such
		# failure fails as any other
		if [ -z "${PREBUILD_RETRIED:-}" ] && grep -q "cannot execute" "$log"; then
			echo "prebuild: a compile could not start a program; once more:"
			grep "cannot execute" "$log" | head -3
			mv "$log" "$log.first"
			[ -n "$wine" ] && { "$wine"server -k 2>/dev/null || true; }
			PREBUILD_RETRIED=1 prebuild_modules "$stage" "$name"
			return $?
		fi
		echo "prebuild: the server did not listen; its log's end:"
		tail -20 "$log"
		return 1
	fi
	if grep -q "Failed to build module" "$log"; then
		echo "prebuild: a module failed to build:"; grep "Failed to build" "$log"
		kill -9 "$srv" 2>/dev/null
		return 1
	fi
	kill -INT "$srv" 2>/dev/null || true
	local i
	for i in $(seq 1 30); do
		kill -0 "$srv" 2>/dev/null || break
		sleep 1
	done
	kill -9 "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
	[ -n "$wine" ] && { "$wine"server -k 2>/dev/null || true; rm -rf "$stage/../wine-prebuild"; }
	# Only the built modules stay: no logs, no compile output, no save
	find "$stage/cache" -mindepth 1 -maxdepth 1 ! -name rccpp_build -exec rm -rf {} +
	rm -f "$stage"/cache/rccpp_build/*.compile.log
	rm -rf "$stage/user/apps/vanilla/saves/prebuild"
	rm -f "$stage"/user/shared/vanilla/settings.json
	local n
	n=$(ls "$stage"/cache/rccpp_build/ 2>/dev/null | grep -c "\.\(so\|dll\)$" || true)
	echo "prebuild: $n modules in the archive's cache"
	[ "$n" -gt 0 ] || { echo "prebuild: nothing was built"; return 1; }
	return 0
}

# What both smoke tests wait for from the server ([WIN_MAPGEN_BUILD]):
# apps/vanilla with the bundled minimal game, so that every builtin --
# luanti and luanti_mapgen above all, the modules a player uses -- is
# compiled by the shipped compiler, the game's mods load and one section
# generates. apps/demo_digger before never compiled either, and a mapgen that
# did not build under mingw shipped in 0.4.2.
# The CPU time, in seconds, of a process and everything under it, and of
# every Windows process there is: under Wine each process is reparented
# to pid 1 -- the server, its compiler, conhost -- so the tree says
# nothing there and the .exe's are counted wherever they hang. A Windows
# process is told by its command line: comm is cut at 15 bytes, and
# "buildat_server.exe" is "buildat_server." there, so the server's own
# work before its first compile counted for nothing and a slow runner
# failed it as a hang ([WIN_PREBUILD_STALL]). simplified: on a host
# running other Wine programs their CPU counts too; the container runs
# nothing else
tree_cpu() {
	ps -eo pid=,ppid=,times=,args= | awk -v root="$1" '
		{ pp[$1] = $2; t[$1] = $3; exe[$1] = (tolower($0) ~ /\.exe( |$)/) }
		END {
			for (p in pp) {
				q = p
				while (q != root && (q in pp)) q = pp[q]
				if (q == root || exe[p]) s += t[p]
			}
			print s + 0
		}'
}

# Wait for $pattern in $log while the server is alive and doing something:
# a log that has not grown and a process tree whose CPU time has not
# moved for 30 s is a hang -- an idle select, a build step stuck, a Wine
# dialog nobody can click -- and is failed on the spot rather than at the
# end of the ceiling ([WIN_SMOKE_STALL]). A compile keeps the CPU moving,
# worldgen keeps the log moving. A progress line every 30 s says which.
wait_for_line() {
	local log="$1" srv="$2" pattern="$3" ceiling="$4"
	local i size cpu last_size=-1 last_cpu=-1 still=0
	for i in $(seq 1 "$ceiling"); do
		grep -q "$pattern" "$log" 2>/dev/null && return 0
		kill -0 "$srv" 2>/dev/null || return 1
		size=$(stat -c %s "$log" 2>/dev/null || echo 0)
		cpu=$(tree_cpu "$srv")
		if [ "$size" = "$last_size" ] && [ "$cpu" = "$last_cpu" ]; then
			still=$((still + 1))
		else
			still=0; last_size=$size; last_cpu=$cpu
		fi
		if [ "$still" -ge 30 ]; then
			echo "waited ${i}s: no log or CPU movement for 30 s; the server hangs" >&2
			return 1
		fi
		if [ $((i % 30)) -eq 0 ]; then
			echo "waited ${i}s, cpu ${cpu}s, last line: $(tail -n 1 "$log" 2>/dev/null | cut -c1-120)"
		fi
		sleep 1
	done
	return 1
}

# A crash in the client's log, read rather than passed over
# ([WIN_SMOKE_STALL]): winedbg's report names the module of every frame,
# and the topmost frame's module is the answer to whether the desktop
# has the same crash. Wine's own -- its GL, its window server, its
# libc -- is Wine's and is reported (return 0); anything else is
# buildat's and is a failed smoke (return 1). No report at all is
# reported too. The Linux client says only "Segmentation fault", which
# is printed for what it is.
read_crash() {
	local log="$1" frame
	if grep -q "Unhandled page fault\|Unhandled exception" "$log"; then
		echo "the client crashed; the report:" >&2
		grep -B8 -A20 "Unhandled page fault\|Unhandled exception" "$log" | head -60 >&2
		frame=$(grep -m1 "^=>0 " "$log" || true)
		if [ -z "$frame" ]; then
			echo "the client crashed and left no backtrace" >&2
			return 0
		fi
		if echo "$frame" | grep -qi " in \(opengl32\|wined3d\|winex11\|win32u\|gdi32\|user32\|ntdll\|kernel32\|kernelbase\|ucrtbase\|msvcrt\|winevulkan\|dxgi\|d3d[0-9]*\|mesa\|libgl[a-z0-9_]*\|swrast[a-z0-9_]*\|llvmpipe\)"; then
			echo "the client crashed in Wine's own code; reported, not a verdict" >&2
			return 0
		fi
		echo "the client crashed in buildat's own code: $frame" >&2
		return 1
	fi
	if grep -q "Segmentation fault\|SIGSEGV" "$log"; then
		echo "the client crashed:" >&2
		grep -B2 -A2 "Segmentation fault\|SIGSEGV" "$log" | head -10 >&2
	fi
	return 0
}

wait_for_vanilla() {
	local log="$1" srv="$2" what="$3"
	if ! wait_for_line "$log" "$srv" "Listening at" 900; then
		echo "$what: the server did not come up; its log:" >&2
		tail -40 "$log" >&2
		return 1
	fi
	if ! wait_for_line "$log" "$srv" "Generating section\|on_generated" 300; then
		echo "$what: the game loaded no world; its log:" >&2
		tail -40 "$log" >&2
		return 1
	fi
	if grep -q "Failed to build module" "$log"; then
		echo "$what: a module did not build; its log:" >&2
		grep -n "Failed to build\|error" "$log" | head -20 >&2
		return 1
	fi
	echo "$what: the server compiled every module, loaded the game and generated a section"
}

# The archive unpacked into a clean directory and run: the server on
# apps/vanilla with the bundled game through the found compiler, a client connected for one
# screenshot, which must not be black. The one check that says the archive
# starts on the machine it is on.
# The web client ([WEB_CLIENT]), built into the tree's web/ before the
# archives, whose install rule carries it; emsdk is util/docker/linux's
build_web() {
	if [ -z "${EMSDK:-}" ] && [ ! -d "$HOME/emsdk" ]; then
		echo "package.sh: no emsdk (EMSDK) for the web client" >&2
		return 1
	fi
	local log="$root/build_web.log"
	echo "web client: util/build_web.sh ($log)" >&2
	"$here/util/build_web.sh" -j "$jobs" > "$log" 2>&1 || {
		echo "the web client did not build; its log's end:" >&2
		tail -30 "$log" >&2; return 1; }
	for f in index.html buildat.js buildat.wasm buildat.data buildat_mt.js \
			buildat_mt.wasm buildat_mt.data; do
		[ -s "$here/web/$f" ] || { echo "web client: no web/$f" >&2; return 1; }
	done
	# [WEB_LOCAL_SERVER] Each app in WEB_LOCAL_APPS gets its own server in
	# web/local/<app>/, which the page runs at ?local=<app>
	local a
	log="$root/build_web_server.log"
	: > "$log"
	for a in $WEB_LOCAL_APPS; do
		echo "web server: util/build_web_server.sh $a ($log)" >&2
		# [WEB_LOCAL_AITTA] _aitta, the server for Aitta's packages, is
		# the engine's own
		local from=$a
		[ "$a" = _aitta ] && from=$here/src/server/web/_aitta
		"$here/util/build_web_server.sh" "$from" -j "$jobs" >> "$log" 2>&1 || {
			echo "the web server of $a did not build; its log's end:" >&2
			tail -30 "$log" >&2; return 1; }
		for f in js wasm data; do
			[ -s "$here/web/local/$a/buildat_server.$f" ] ||
				{ echo "web server: no web/local/$a/buildat_server.$f" >&2; return 1; }
		done
	done
}

# The apps whose modules all build for the web ("web": true in their
# meta.json; util/web_server.cmake refuses the others), and _aitta, the
# server that runs Aitta's packages in the page ([WEB_LOCAL_AITTA])
# simplified: named here; an app newly marked is added by hand
WEB_LOCAL_APPS="hillclimb demo_aggregate skeldat _aitta"

# The apps web-precompiled carries compiled ([LINUX_SERVER]), chosen one by
# one (user, 2026-09-29): the others ship as source, and on a box with no
# compiler do not start
WEB_PRECOMPILED_APPS="floorplanner vanilla demo_aggregate demo_bomber_drone"

# Those apps' modules compiled into a stage's cache: each game started once
# on the staged server until it listens, with a user directory of its own
# that is thrown away, so only cache/rccpp_build/ keeps anything. A game that
# does not start fails the packaging.
prebuild_apps() {
	local stage="$1" name="$2"
	local logs="$stage/../prebuild-apps-$name"
	local g log port=29799 srv udir failed=""
	mkdir -p "$logs"
	for g in $WEB_PRECOMPILED_APPS; do
		[ -d "$stage/apps/$g" ] || { echo "prebuild: no apps/$g"; failed="$failed $g"; continue; }
		log="$logs/$g.log"
		# A port of its own, counted up past any that is taken: one drawn
		# at random came out the same for game after game, and the last
		# game's server still had it
		port=$((port + 1))
		while (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; do port=$((port + 1)); done
		udir=$(mktemp -d "/tmp/buildat_package_prebuild_apps.XXXXXX")
		PKG_TMP_DIRS="$PKG_TMP_DIRS $udir"
		(cd "$stage" && BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=prebuild \
			BUILDAT_UNCONFINED=1 \
			bin/buildat_server -m "apps/$g" -D "$udir" -P "$port" -l 3 > "$log" 2>&1) &
		srv=$!
		if wait_for_line "$log" "$srv" "Listening at" 900 >/dev/null &&
				! grep -q "Failed to build module" "$log"; then
			echo "prebuild: $g built and listens"
		else
			echo "prebuild: $g did not start"; failed="$failed $g"
		fi
		kill -INT "$srv" 2>/dev/null || true
		for i in $(seq 1 30); do kill -0 "$srv" 2>/dev/null || break; sleep 1; done
		kill -9 "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
	done
	find "$stage/cache" -mindepth 1 -maxdepth 1 ! -name rccpp_build -exec rm -rf {} +
	rm -f "$stage"/cache/rccpp_build/*.compile.log
	if [ -n "$failed" ]; then
		echo "prebuild: apps that did not start:$failed (see $logs/)"
		return 1
	fi
	echo "prebuild: $(ls "$stage"/cache/rccpp_build/ | grep -c '\.so$') modules in the cache"
}

# The shared libraries a bare box lacks, into the stage's lib/
# ([LINUX_SERVER]): what the shipped ELF files need, less glibc,
# libstdc++/libgcc_s and libcurl with everything libcurl needs, which
# stays the system's (its OpenSSL finds CA certificates where its distro
# keeps them). What is left is GL, GLX and X11's, which the server loads
# and never draws with. The binaries' RPATH is $ORIGIN/../lib.
bundle_libs() {
	local stage="$1"
	local elfs curl_deps f lib path
	elfs=$(find "$stage/bin" "$stage/lib" -maxdepth 1 -type f \( -name 'buildat*' -o -name '*.so*' \))
	curl_deps=$(ldd "$(ldconfig -p | awk '/libcurl.so.4 / {print $NF; exit}')" 2>/dev/null |
		awk '{print $1}')
	for lib in $(for f in $elfs; do ldd "$f" 2>/dev/null; done |
			awk '$3 ~ /^\// {print $1" "$3}' | sort -u | awk '{print $1"="$2}'); do
		f=${lib%%=*}; path=${lib#*=}
		case "$f" in
			libc.so*|libm.so*|libdl.so*|libpthread.so*|librt.so*|ld-linux*|libresolv.so*|\
			libutil.so*|libstdc++.so*|libgcc_s.so*|libcurl.so*) continue ;;
		esac
		echo "$curl_deps" | grep -qx "$f" && continue
		[ -e "$stage/lib/$f" ] && continue
		cp -L "$path" "$stage/lib/$f"
		echo "bundled $f"
	done
	# Each library looks beside itself: an executable's search path covers
	# only its own dependencies once a library has a RUNPATH of its own, as
	# libUrho3D.so's is, and libUrho3D.so's libGL.so.1 and libGL's
	# libGLdispatch.so.0 were not found in lib/
	for f in "$stage"/lib/*.so*; do
		[ -L "$f" ] && continue
		patchelf --set-rpath '$ORIGIN' "$f"
	done
}

# The web archives ([LINUX_SERVER]), out of another archive's stage:
# "web" is the portable archive's with the libraries a bare box lacks,
# and compiles the apps on the box with its c++; "web-precompiled" is
# the web archive's with every game's modules prebuilt as well, and
# starts on a box with no compiler
make_web_archive() {
	local from="$1" name="$2" precompiled="${3:-}"
	local src="$root/stage/$from" stage="$root/stage/$name"
	rm -rf "$stage"; cp -a "$src" "$stage"
	[ -s "$stage/web/buildat.wasm" ] || { echo "web archive: no web/ in the stage" >&2; return 1; }
	for a in $WEB_LOCAL_APPS; do
		[ -s "$stage/web/local/$a/buildat_server.wasm" ] ||
			{ echo "web archive: no web/local/$a in the stage" >&2; return 1; }
	done
	if [ -n "$precompiled" ]; then
		prebuild_apps "$stage" "$name" >&2 || return 1
	else
		bundle_libs "$stage" >&2
	fi
	tar -C "$stage/.." -czf "$out/$name.tar.gz" "$name"
	echo "$out/$name.tar.gz"
}

smoke_test() {
	local archive="$1"
	local dir
	dir=$(mktemp -d "/tmp/buildat_package_smoke_test.XXXXXX")
	PKG_TMP_DIRS="$PKG_TMP_DIRS $dir"
	tar -C "$dir" -xzf "$archive"
	local unpacked
	unpacked=$(ls -d "$dir"/*/ | head -1)
	local port=$(( 29600 + (RANDOM % 90) ))
	echo "smoke test in $unpacked"
	# The compiler's proof with a prebuilt cache ([PRECOMPILED]): one
	# module's output taken out, so the start has to build it
	rm -f "$unpacked"/cache/rccpp_build/*client_file*
	# [PACKAGE_PREBUILT_WASM] With no wasm toolchain (the image's emsdk
	# hidden), as on a box without clang: voxelworld's .wasm is the cache's
	(cd "$unpacked" && BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=smoke \
		BUILDAT_LUANTI_FETCH_ONCE=1 BUILDAT_CONTENTDB_URL="file://$dir/nowhere" \
		EMSDK="$dir/nowhere" RUSTUP_HOME="$dir/nowhere" BUILDAT_WASM_CC= BUILDAT_WASM_LD= \
		bin/buildat_server -u launcher=1 -m apps/vanilla -P "$port" -l 4 > "$dir/srv.log" 2>&1) &
	local srv=$!
	local i
	# The server compiles every module it loads through the compiler
	# the archive found, which is minutes on a first run; the client
	# joins once the server listens and the world is there
	wait_for_vanilla "$dir/srv.log" "$srv" "smoke test" || {
		kill -9 "$srv" 2>/dev/null; exit 1; }
	if ! grep -q "STATUS Compiling client_file" "$dir/srv.log"; then
		echo "smoke test: the shipped compiler built nothing (client_file was taken out of the cache)" >&2
		kill -9 "$srv" 2>/dev/null; exit 1
	fi
	# http_get ran once ([WIN8_START] 16): a fetch that answered, with an
	# error or not, is a fetch whose call_once did not die
	if ! wait_for_line "$dir/srv.log" "$srv" "contentdb: fetched once" 60; then
		echo "smoke test: the server's one ContentDB fetch never answered (http_get died or hangs)" >&2
		kill -9 "$srv" 2>/dev/null; exit 1
	fi
	sleep 5
	printf 'delay 25000\nscreenshot %s/shot.png\nquit\n' "$dir" > "$dir/cmds.txt"
	# Software GL where there is no GPU (the container); harmless with one
	(cd "$unpacked" && LIBGL_ALWAYS_SOFTWARE=1 timeout 120 bin/buildat -o launch_ui=launch_menu -s "localhost:$port" -w 640x360 -l 3 -c @"$dir/cmds.txt" > "$dir/cli.log" 2>&1) || true
	kill -INT "$srv" 2>/dev/null || true
	for i in $(seq 1 30); do
		kill -0 "$srv" 2>/dev/null || break
		sleep 1
	done
	kill -9 "$srv" 2>/dev/null || true; wait "$srv" 2>/dev/null || true
	if [ ! -f "$dir/shot.png" ]; then
		echo "smoke test: no screenshot; see $dir/cli.log and $dir/srv.log; the client's log's end:" >&2
		tail -40 "$dir/cli.log" >&2
		exit 1
	fi
	# What the archive has to have done: joined, drawn the world -- the
	# client says when a chunk was drawn -- and run its commands to the
	# end. The screenshot's mean is read beside that: under a virtual
	# display with software GL the readback has come out black on a
	# frame the client drew, so it is reported and not a verdict there.
	if ! grep -q "Connect succeeded" "$dir/cli.log" ||
			! grep -q "Command sequence complete" "$dir/cli.log" ||
			! grep -q "drawn again\|Node update\|player physics enabled\|chunks in scene" "$dir/cli.log"; then
		echo "smoke test: the client did not join, draw and finish; see $dir/cli.log" >&2
		tail -40 "$dir/cli.log" >&2
		read_crash "$dir/cli.log"
		exit 1
	fi
	if ! grep -q "No wasm toolchain" "$dir/srv.log"; then
		echo "smoke test: a wasm toolchain in PATH here; the prebuilt .wasm not proven"
	elif ! grep -q "voxelworld: wasm/ is \(built (cache hit)\|in the shared build\)" "$dir/srv.log" ||
			! grep -q "wasm voxelworld: \(ready (compiled)\|moved to the compiled module\|compiled module from the cache\)" "$dir/cli.log"; then
		echo "smoke test: voxelworld's .wasm not served from the archive's cache, or not compiled by the client:" >&2
		grep -h "voxelworld: wasm/\|wasm voxelworld\|No wasm toolchain" "$dir/srv.log" "$dir/cli.log" | head -10 >&2
		exit 1
	else
		echo "smoke test: with no wasm toolchain the server served voxelworld's prebuilt .wasm, the client ran it compiled"
	fi
	local mean
	mean=$(magick "$dir/shot.png" -format '%[fx:mean]' info: 2>/dev/null || echo 0)
	if awk -v m="$mean" 'BEGIN{exit !(m < 0.01)}'; then
		if [ -n "${DISPLAY:-}" ] && [ -z "${BUILDAT_SMOKE_VIRTUAL:-}" ]; then
			echo "smoke test: the screenshot is black (mean $mean)" >&2
			exit 1
		fi
		echo "smoke test: joined, drew and finished; the screenshot is black under the virtual display (mean $mean)"
	else
		echo "smoke test passed (screenshot mean $mean)"
	fi
}

case "$target" in
# The Windows smoke alone on an archive already made, for reading its
# leavings without the build: util/package.sh smoke out/x.zip
smoke)
	smoke_test_wine "$2"
	;;
linux)
	build_web
	a=$(make_one "buildat-$version-linux-x86_64-portable" -DPORTABLE=TRUE)
	b=$(make_one "buildat-$version-linux-x86_64-xdg" -DPORTABLE=FALSE)
	c=$(make_web_archive "buildat-$version-linux-x86_64-portable" \
		"buildat-$version-linux-x86_64-web")
	d=$(make_web_archive "buildat-$version-linux-x86_64-web" \
		"buildat-$version-linux-x86_64-web-precompiled" precompiled)
	smoke_test "$a"
	echo "archives:"; echo "  $a"; echo "  $b"; echo "  $c"; echo "  $d"
	# The web archives on a bare box are util/smoke_web_archive.sh's,
	# run by util/package_in_docker.sh outside this container
	;;
windows)
	# The cross build: Urho3D's own MinGW toolchain file, with Debian's
	# x86_64-w64-mingw32 tools (util/docker/windows); CMAKE_TOOLCHAIN_FILE
	# and MINGW_PREFIX (a path prefix, /usr/bin/x86_64-w64-mingw32) in the
	# environment override for another toolchain
	tc="${CMAKE_TOOLCHAIN_FILE:-$here/3rdparty/Urho3D/CMake/Toolchains/MinGW.cmake}"
	# and the native tree the archive ships under compiler/, which the
	# image unpacks to /opt/winlibs/mingw64
	# and libcurl's static build (util/docker/windows builds it into
	# /opt/curlwin/curl); CURLWIN in the environment overrides
	cw="${CURLWIN:-/opt/curlwin/curl}"
	win_args=(-DPORTABLE=TRUE \
		-DCMAKE_TOOLCHAIN_FILE="$tc" \
		-DMINGW_PREFIX="${MINGW_PREFIX:-/usr/bin/x86_64-w64-mingw32}" \
		-DBUILDAT_SHIP_COMPILER="${BUILDAT_SHIP_COMPILER:-/opt/winlibs/mingw64}" \
		-DCURL_INCLUDE_DIR="$cw/include" -DCURL_LIBRARY="$cw/lib/libcurl.a")
	a=$(make_one "buildat-$version-win64" "${win_args[@]}")
	echo "archive: $a"
	check_imports "$a"
	smoke_test_wine "$a"
	i=$(make_installer "buildat-$version-win64") || exit 1
	echo "installer: $i"
	# The "Luanti only" archive ([LUANTI_BUILD]): the same build tree
	# installed again with BUILDAT_LUANTI_ONLY (apps/vanilla alone, no
	# compiler), and the modules the full archive's prebuild compiled
	# copied into its cache, since it cannot compile them itself
	c=$(make_luanti_only "buildat-$version-win64" "buildat-$version-win64-luanti" \
		-DCMAKE_BUILD_TYPE=Release "${win_args[@]}")
	echo "archive: $c"
	check_imports "$c"
	smoke_test_wine_luanti "$c"
	;;
*)
	echo "unknown target $target" >&2; exit 2 ;;
esac
