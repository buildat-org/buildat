#!/bin/bash
# Build the web client ([WEB_CLIENT] in doc/plan/web_client_plan.md) into
# web/, where the server serves it from by default. Needs emsdk: EMSDK, or
# ~/emsdk, with the version doc/plan/web_client_plan.md names activated.
# Two builds: buildat.* in Build-web, and buildat_mt.* with threads in
# Build-web-mt, which a cross-origin isolated page runs
# ([WEB_MESH_OFF_THREAD]).
# util/build_web.sh [make arguments]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
EMSDK=${EMSDK:-$HOME/emsdk}
source "$EMSDK/emsdk_env.sh" > /dev/null
for b in web web-mt; do
	mkdir -p "$ROOT/Build-$b"
	cd "$ROOT/Build-$b"
	emcmake cmake "$ROOT" -DCMAKE_BUILD_TYPE=Release \
		-DBUILDAT_WEB_THREADS=$([ $b = web-mt ] && echo TRUE || echo FALSE)
	make -j$(nproc) "$@"
done
ls -la "$ROOT/web"
