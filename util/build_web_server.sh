#!/bin/bash
# Build the server of one app for the web ([WEB_LOCAL_SERVER] in
# doc/plan/web_client_plan.md): the server and the app's modules in one
# wasm, Build-webserver/bin/buildat_server.{js,wasm,data}. Needs emsdk as
# util/build_web.sh does.
# util/build_web_server.sh [app (hillclimb)] [make arguments]
set -e
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-hillclimb}
shift || true
EMSDK=${EMSDK:-$HOME/emsdk}
source "$EMSDK/emsdk_env.sh" > /dev/null
mkdir -p "$ROOT/Build-webserver"
cd "$ROOT/Build-webserver"
emcmake cmake "$ROOT" -DCMAKE_BUILD_TYPE=Release -DBUILDAT_WEB_SERVER_APP="$APP"
make -j$(nproc) "$@"
ls -la bin/buildat_server.*
