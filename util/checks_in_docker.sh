#!/bin/bash
# A tier of checks, run in the packaging image ([CI_RUNS] (5)):
#
#   util/checks_in_docker.sh quick
#   util/checks_in_docker.sh full
#   ONLY='lua_syntax|sample_lighting_scene' util/checks_in_docker.sh quick
#
# ONLY is run_all.sh's own filter, passed through: the build is what a
# container run costs, so picking a runner out of the tier is how a
# single runner is looked at in the image without another script.
#
# The same image the Linux archives are built in (util/docker/linux), a
# git archive of HEAD rather than a mount of the working tree, a Release
# build, and util/run_all.sh under Xvfb. Everything the
# run wrote under local/ is copied to Build/checks/out/ on the host, so a
# failure can be read from outside the container.
#
# The exit status is the tier's: 0 every runner passed or skipped, 1 any
# failed.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tier="${1:-quick}"
image="buildat-package-linux"
out="$here/Build/checks/out"
# **What the container wrote belongs to the host** ([CI_RUNS]): docker
# runs as root, so last run's artifacts are root-owned and this rm
# fails -- the run below chowns /out on its way out for that reason.
# Failing here rather than on a half-cleared directory.
rm -rf "$out" 2>/dev/null || {
	echo "cannot clear $out; it holds files this user does not own" >&2
	exit 2; }
mkdir -p "$out"
docker build -t "$image" "$here/util/docker/linux"
tarball=$(mktemp /tmp/buildat_checks_in_docker.XXXXXX)
trap 'rm -f "$tarball"' EXIT
git -C "$here" archive --format=tar HEAD > "$tarball"
# BUILDAT_CI: a timing is a row and never a verdict on a machine whose
# speed nobody chose (builtin/luanti/test/verdict.sh)
# The game media the full and long tiers want, from the host rather
# than fetched again per run ([CI_RUNS] (4)): util/media_fetch.sh fills
# it, and CI caches it keyed on the release ids that script prints; it
# goes where util/check_lib.sh puts the checks' user path
media="${BUILDAT_MEDIA_DIR:-$here/user/shared/vanilla}"
mount_media=""
[ -d "$media/games" ] && mount_media="-v $media:/work/buildat/local/check/user/shared/vanilla:z"
# The compiler cache ([BUILD_TIME]), kept on the host between runs (CI
# keeps the directory); the archive has no .git, so the hash by name
ccache_dir="${BUILDAT_CCACHE_DIR:-$here/Build/ccache}"
mkdir -p "$ccache_dir"
# **Nothing leaves the machine in the ci tier** ([CI_TIER]): no network
# but the container's loopback, so a runner that reaches out fails here
net=""
[ "$tier" = ci ] && net="--network none"
docker run --rm -i $net \
	-v "$out:/out:z" \
	-v "$ccache_dir:/ccache:z" -e CCACHE_DIR=/ccache \
	-e "BUILDAT_GIT_HASH=$(git -C "$here" rev-parse --short HEAD)" \
	$mount_media \
	-e "BUILDAT_CI=1" \
	-e "ONLY=${ONLY:-}" \
	-e "JOBS=${JOBS:-$(nproc 2>/dev/null || echo 4)}" \
	"$image" bash -c "
		set -eu
		trap 'chown -R $(id -u):$(id -g) /ccache 2>/dev/null || true' EXIT
		mkdir -p /work/buildat && cd /work/buildat && tar -xf - &&
		mkdir -p Build && cd Build &&
		cmake .. -DCMAKE_BUILD_TYPE=Release > cmake.log 2>&1 ||
			{ tail -20 cmake.log; cp cmake.log /out/
			  chown -R $(id -u):$(id -g) /out 2>/dev/null || true; exit 2; }
		cmake --build . -j \$JOBS > build.log 2>&1 ||
			{ tail -40 build.log; cp build.log /out/
			  chown -R $(id -u):$(id -g) /out 2>/dev/null || true; exit 2; }
		cd /work/buildat
		status=0
		xvfb-run -a -s '-screen 0 1280x720x24' \
			util/run_all.sh $tier || status=\$?
		cp -r local/. /out/ 2>/dev/null || true
		chown -R $(id -u):$(id -g) /out 2>/dev/null || true
		exit \$status
	" < "$tarball"
