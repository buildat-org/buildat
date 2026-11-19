#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: quick
# cost: <1 s (2026-11-19)
# covers: apps/workbench/templates/brimstone_speedway/types/brim_car.lua builtin/kit/client_lua/move.lua util/kit_racer_sim_check.lua builtin/kit/types/bot.lua apps/workbench/templates/brimstone_speedway/types/brim_yard.lua
# [KIT_TOP_DOWN] Brimstone Speedway's handbrake turn, (4z37f) its run-off's
# gravel and (4z37i (4)) a driving bot's lap of the Bone Yard (kit/bot's
# controller on brim_yard's racing line), offline: util/kit_racer_sim_check.lua
#   util/kit_racer_sim_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for lua in luajit lua5.1; do
	command -v $lua >/dev/null && break
done
command -v $lua >/dev/null || skip "no luajit or lua5.1"
(cd "$here" && $lua util/kit_racer_sim_check.lua) || fail "util/kit_racer_sim_check.lua"
echo "PASS: brim_car's handbrake turn stepped offline: a slide of 20...60 degrees, no spin, straight again, at the defaults and a user's tuning, rate 30 x 4 as 60 x 2; on the run-off's gravel slower than on dirt, faster than on mud, never stuck; a bot's lap of the Bone Yard's racing line at skill 0, 50 and 100, on the road, no wall hit, faster by skill"
