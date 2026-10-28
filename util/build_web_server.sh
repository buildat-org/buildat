#!/bin/bash
# Build the server of one app for the web ([WEB_LOCAL_SERVER] in
# doc/plan/web_client_plan.md): the server and the app's modules in one
# wasm, Build-webserver/bin/buildat_server.{js,wasm,data}, copied to
# web/local/<app>/, where the web client's ?local=<app> finds them. Needs
# emsdk as util/build_web.sh does.
# util/build_web_server.sh [app (hillclimb)] [make arguments]
# [WEB_LOCAL_AITTA] The engine's server for Aitta's packages, which run in
# the page with no build of their own (their modules are .wasm), is
# src/server/web/_aitta, an app of the builtins that keep to the web API:
# util/build_web_server.sh "$PWD/src/server/web/_aitta" into web/local/_aitta/
# [WEB_LOCAL_AITTA_CPP] and its parts into Build-webserver/aitta_kit/, from
# which an Aitta (BUILDAT_AITTA_CPP_KIT) links a release's C++ modules into
# a server of its own for the page (util/aitta_cpp_build.py)
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
# Served beside the web client (builtin/network, /local/<app>/)
out="$ROOT/web/local/$(basename "$APP")"
mkdir -p "$out"
cp bin/buildat_server.js bin/buildat_server.wasm bin/buildat_server.data "$out/"
if [ "$(basename "$APP")" = _aitta ]; then
	python3 -I "$ROOT/util/aitta_cpp_build.py" kit . aitta_kit
fi
ls -la "$out"
