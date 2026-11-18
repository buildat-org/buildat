#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: <1 s (2026-11-19)
# covers: apps/workbench/templates/brimstone_speedway/types/brim_car.lua builtin/kit/client_lua/move.lua util/kit_racer_sim_check.lua
# [KIT_TOP_DOWN] Brimstone Speedway's handbrake turn, offline: util/kit_racer_sim_check.lua
#   util/kit_racer_sim_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for lua in luajit lua5.1; do
	command -v $lua >/dev/null && break
done
command -v $lua >/dev/null || skip "no luajit or lua5.1"
(cd "$here" && $lua util/kit_racer_sim_check.lua) || fail "util/kit_racer_sim_check.lua"
echo "PASS: brim_car's handbrake turn stepped offline: a slide of 20...60 degrees, no spin, straight again, at the defaults and a user's tuning, rate 30 x 4 as 60 x 2"
