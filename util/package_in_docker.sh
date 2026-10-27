#!/bin/bash
# The archives, made in a container and nowhere else ([PACKAGING]):
#
#   util/package_in_docker.sh linux
#   util/package_in_docker.sh windows
#
# Builds util/docker/<target>'s image, hands it a git archive of HEAD --
# not a mount of the working tree, so the host's Build/ and 3rdparty/Urho3D/
# Build/ take no part and the container builds Urho3D against its own
# libraries -- runs util/package.sh inside, and copies the archives to
# Build/package/out/ on the host. A build that targets packaging runs
# here; the host builds for development and testing only.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
target="${1:-}"
if [ -z "$target" ]; then
	echo "usage: util/package_in_docker.sh <linux|windows>" >&2
	exit 2
fi
if [ ! -f "$here/util/docker/$target/Dockerfile" ]; then
	echo "no image for $target: util/docker/$target/Dockerfile" >&2
	exit 2
fi
image="buildat-package-$target"
out="$here/Build/package/out"
mkdir -p "$out"
docker build -t "$image" "$here/util/docker/$target"
# The tree as committed, including the bundled Urho3D and the other
# 3rdparty sources; anything uncommitted is not in a release
tarball=$(mktemp /tmp/buildat_package_in_docker.XXXXXX)
trap 'rm -f "$tarball"' EXIT
git -C "$here" archive --format=tar HEAD > "$tarball"
# The archive has no .git, so the hash of what it holds goes in by name
hash=$(git -C "$here" rev-parse --short HEAD)
# The compiler cache ([BUILD_TIME]), kept on the host between runs (CI
# keeps the directory)
ccache_dir="${BUILDAT_CCACHE_DIR:-$here/Build/ccache}"
mkdir -p "$ccache_dir"
docker run --rm -i \
	-v "$out:/out:z" \
	-v "$ccache_dir:/ccache:z" -e CCACHE_DIR=/ccache \
	-e "BUILDAT_GIT_HASH=$hash" \
	-e "JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}" \
	-e KEEP_TMP=1 \
	"$image" bash -c "
		set -eu
		trap 'chown -R $(id -u):$(id -g) /ccache 2>/dev/null || true' EXIT
		mkdir -p /work/buildat && cd /work/buildat && tar -xf - &&
		status=0
		if [ "$target" = linux ]; then
			BUILDAT_SMOKE_VIRTUAL=1 xvfb-run -a -s '-screen 0 1280x720x24' util/package.sh $target || status=\$?
		else
			util/package.sh $target || status=\$?
		fi
		cp Build/package/out/* /out/ 2>/dev/null || true
		# And the build trees' logs, for reading a failure from outside
		mkdir -p /out/logs && for d in Build/package/build-*; do
			b=\$(basename \$d); cp \$d/cmake.log /out/logs/\$b.cmake.log 2>/dev/null
			cp \$d/build.log /out/logs/\$b.build.log 2>/dev/null; done
		# The web client's build and the per-game prebuilds ([LINUX_SERVER])
		# (a Windows run has neither; the script is set -e)
		cp Build/package/build_web.log Build/package/build_web_server.log \
			/out/logs/ 2>/dev/null || true
		cp -r Build/package/stage/prebuild-apps-* /out/logs/ 2>/dev/null || true
		# And the smoke tests' leavings, for reading a failure from outside:
		# KEEP_TMP above keeps package.sh's trap from deleting them (the
		# container goes), one directory each ([PACKAGE_070_SMOKE])
		for d in /tmp/buildat_package_smoke_test*/; do
			[ -d \$d ] || continue
			o=/out/smoke/\$(basename \$d); mkdir -p \$o
			cp \$d/shot.png \$d/*.log \$d/*.txt \$o/ 2>/dev/null || true
		done
		exit \$status
	" < "$tarball"
rm -f "$tarball"
# The web archives on a bare box, which only a host with docker can
# make ([LINUX_SERVER]): a slim Debian with the least a server needs
# Its logs in a directory of the host's: out/smoke/ is the container's,
# made by root
if [ "$target" = linux ]; then
	mkdir -p "$out/web-smoke"
	for a in "$out"/buildat-*"$hash"-linux-x86_64-web.tar.gz \
			"$out"/buildat-*"$hash"-linux-x86_64-web-precompiled.tar.gz; do
		SMOKE_LOG="$out/web-smoke/$(basename "$a" .tar.gz).log" \
			"$here/util/smoke_web_archive.sh" "$a"
	done
fi
echo "archives in $out:"
ls -la "$out"
