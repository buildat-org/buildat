#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to long; it asks ContentDB at localhost:30005, which is not
#   there (dev) (local/runs/dev_baseline)
# [FIRST_RUN]: the new user's first hour, driven -- empty user and cache
# paths, VoxeLibre installed from a ContentDB mirror through the client's
# own screens, a new world at seed 5, walked and dug to GOAL 2. Every
# dialog, error line, disconnect and still screen ends it. The sweep's
# runner; the same run by hand is
#
#   MENU_RUN=full SEED=5 MINUTES=10 GOAL=2 builtin/luanti/test/drive.sh
#
# Wants ~250 MB under /tmp for the run's paths, freed at its end.
set -u
here=$(cd "$(dirname "$0")/../../.." && pwd)
MENU_RUN=full SEED="${SEED:-5}" MINUTES="${MINUTES:-10}" GOAL="${GOAL:-2}" \
	exec "$here/builtin/luanti/test/drive.sh"
