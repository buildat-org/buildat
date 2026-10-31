# Work for the cloud session (2026-10-31)

Three dev items from the master plan, chosen for a CPU-only machine and
for not overlapping work running elsewhere. Take them in this order;
each is independent. The plan (doc/plan) is a separate repository and is
not edited here: what you find goes in the Results section below.

## How to work

- Base: this branch, cut from dev. Commit on this branch; do not merge
  or rebase onto dev, and do not push any other branch.
- Commits: `git -c user.name=Claude -c user.email=claude@buildat.org
  commit`, no Co-Authored-By line. The subject is tagged with the item,
  e.g. `... [FORCELOAD_STARVED]`. Plain technical wording. Grep the
  staged diff for PROBE (debug lines) before committing.
- Checks: source util/check_lib.sh in a runner as the others do; export
  `BUILDAT_STARPORT_DEFAULT`, `BUILDAT_AITTA_DEFAULT` and
  `BUILDAT_HEARTH_DEFAULT` as `https://127.0.0.1:9` so nothing announces
  to the real services. No delay over 2 s in a check: wait on a log line.
  Finish each item with `util/run_all.sh --changed <base>..HEAD`.
- Luanti games (mineclone2 is VoxeLibre, devtest is Luanti's) are
  installed from ContentDB / Luanti's repository into the check user
  path's shared/vanilla/games, as README.md describes.
- If a fix is too large or needs a decision, write it up in Results
  instead, with the evidence, and go to the next item.

## 1. Forceloaded sections starved while a player generates [FORCELOAD_STARVED]

Forceloaded and `core.emerge_area` sections far from players stayed
"unloaded" for 2 min while a player generated. Two orders both put them
last: voxelworld's stream budget in `update_load_points`
(builtin/luanti/world.h pushes spawn, then players, then forceloads) and
worldgen's nearest-player order (builtin/worldgen/worldgen.cpp; since
852649334 the nearest Chebyshev ring around a player, within it the
section nearest the last one taken). Pushing player sections to worldgen
first was tried and was no faster. **Do**: give forceloads a share of
both budgets, so a forceloaded section far away is generated and loaded
within a bounded time while a player keeps generating; a check that
shows it (a server-only probe is enough).

## 2. mineclone2's generated sections differ between runs [MCL_GEN_NONDETERMINISTIC]

Two dev runs, mineclone2 seed 5, gave different voxel hashes for 21 of
83 sections, (0,0,0) among them; devtest is the same every run. (The
hash was a temporary log of each generated section's voxels, removed
afterwards; util/bench_worldgen.sh drives a headless generation.) **Do**:
find what differs (an order-dependent decoration, a Lua random, a mapgen
thread race) and whether official Luanti differs too; fix ours.

## 3. Luanti runners wait for the world, not the drawn scene [LUANTI_LOADED_WAITS]

Your finding #2 from claude/cloud-findings. 27 runners take "the server
put the player" and "scene, 0 undrawn within 2" as playable (`grep -rl
"undrawn within 2" --include=*.sh`), and doc/client_commands.txt's
wait_log section says so; since [JOIN_WHEN_LOADED] a Luanti client holds
keys until "load: the world is in". On a slow machine fuzz.sh never
reached "undrawn within 2" within START_WAIT's 60 s (the mesher at "2000
to mesh", settled after 3.4 min). **Do**: the Luanti apps' runners and
the doc wait for "load: the world is in"; the doc names which apps log
"the server put the player". Waits on "undrawn" stay only where a runner
really measures drawing.

## Results

### 1. [FORCELOAD_STARVED]

Commit 4a8dea69.

Cause: the streamer spent its budget on the load points in order (spawn,
players, then forceloads), and worldgen took the queued section nearest a
player. A forceload or emerge_area far from every player only got a turn
once the player's backlog was empty, which never happens while the player
moves. A Luanti mapchunk's sections were also pinned for a player or the
spawn being near; a walking player leaves over a thousand of these, and
they crowded the forceload out of any share.

Fix: half of the streamer's budget per pass (every other pass at a
budget of one) goes to the pinned points first, and every other worldgen
take is the oldest queued pinned section. Sections pinned only because a
player or the spawn is near are LoadPoint::hold_only and get no share. A
chunk completed for a forceload, an emerge or a mod's read is pinned as
asked.

Numbers: builtin/luanti/test/forceload_starved.sh (new) uses devtest on
a Debug build under llvmpipe, with the player moved two sections a
second.

- Before: the forceloaded block never came in, and the emerge_area hit
  its 120 s timeout.
- After, in three runs: the forceload came in at 5.1-5.4 s and the
  emerge at 10.0-10.1 s, with worldgen's queue still at 331-348.

Checks:

- `run_all.sh --changed`: 4 passed, 2 skipped. sample_lighting_scene
  compares pixels and has no reference image here; focus.sh needs an X
  session of its own.
- Also passed: far_spawn, hillclimb_ground, lua_syntax, object_collide,
  rails.

Open: density.sh fails here because it needs an official luanti binary.
Building official Luanti was blocked by auto mode; it needs your OK.

### 2. [MCL_GEN_NONDETERMINISTIC]

Commit 5b1c39eb.

Cause: Schematic::blitToVManip() rolls each slice's and node's
probability with myrand(), which this codebase maps to libc rand()
(vendor/util/numeric.h), one generator for the whole process. A
decoration with probabilities (VoxeLibre's trees, their leaves, fallen
logs) came out depending on what had drawn from rand() before it. The
same chunk then differed between runs and within one run.

Official Luanti 5.17.0 does the same: mg_schematic.cpp:153 and :180, with
myrand seeded from secure random in main.cpp:789. So upstream differs
between runs too. Decoration::mapseed is never set upstream (it is 0).

Fix: DecoSchematic::generate() passes blitToVManip() a PcgRandom seeded
from the world's seed and where the schematic is placed. The world's
seed is a new Decoration::world_seed, set in placeDeco. The decoration's
own pr is not drawn from, so placements and rotations stay where upstream
puts them. Other callers leave the new parameter out and get myrand() as
before. vendor/README.txt lists the change. luanti_mapgen logs a hash of
each chunk it makes (verbose).

Numbers:

- util/bench_worldgen.sh (mineclone2, seed 5, 6 across, two runs):
  before, 82 of 352 chunks differed and 21 differed within one run;
  generated sections, 69 of 233 differed. After: 0 of 379 chunks, 0 of
  247 sections.
- A probe that ran makeChunk twice on the same chunk: thousands of
  voxels differed before, 0 after.
- builtin/luanti/test/mapgen_deterministic.sh (new; tier full, ~1 min):
  PASS with 62 chunks in both runs and 0 differing. With the vendor
  change taken out it fails (the first 8 it compared all differed).

Open: VoxeLibre's Lua still varies, and so does timing. Comparing the
two runs' saves voxel by voxel:

- 32 chunk rows still differ by node id, against ~975 before. These are
  VoxeLibre's on_generated structures: basalt, calcite and amethyst
  geodes, cobble and mossycobble dungeons, chests, and stone turned to
  air. They depend on which neighbouring chunks are in yet (through
  emerge_area callbacks and find_nodes_in_area over neighbours).
  stubs.lua's place_schematic rolls with math.random, which is seeded
  from time, as upstream's is.
- Light differs in 329 of 2223 rows. In the 2x2x2 box, 149 of 576 rows
  differ, 56 of them more than two rows from any id difference: mostly
  the bottom row (y=-2) and the edges, so neighbour presence or timing.

Neither is fixed: making them repeatable would mean ordering the Lua
callbacks or seeding math.random per chunk. That is a behaviour change
against upstream and needs a decision.

Checks: `run_all.sh --changed 4a8dea69..HEAD`: 2 passed (lua_syntax,
mapgen_deterministic), 2 skipped (sample_heightmap with no display, and
focus.sh). sample_heightmap then passed under xvfb-run.

### 3. [LUANTI_LOADED_WAITS]

Commits 568e3e43, a73c66fd (the world-in wait first) and b628e9e0
(predict.sh back to the undrawn wait).

What changed: the runners that waited for "the server put the player"
and then "scene, 0 undrawn within 2" before sending input now wait for
"load: the world is in". The new timeout is the old pair's two added
together. Those runners are beam, cold_cache, drive, fuzz (and verdict's
grep), footstep, form_key, inv_click, itemmeta, leave_world, mobmesh,
vl_inv, and in util/ accounts_lan, game_settings, local_server_reuse,
page_tap_outside, pause_keys, server_window_click and wield_follow.

Where the undrawn wait stays:

- Runners that look at the world's pixels: dawn_light, liquid_shore,
  minimap_exposure, viewkeys, rotate_aspect_check, touch_parity. Those
  that send input also wait for the world in, first.
- dig_swing, for its stated reason.
- predict.sh, which moves the player to a platform. The world-in line is
  said once, at the first spawn and before that move. With it as the
  wait, the right-click went out before the platform was in, and
  "predicted" was not seen.
- drive's "frozen undrawn" fault, which reads the settle lines.

doc/client_commands.txt now:

- names the line, and the apps that log it and "the server put the
  player": the ones running the luanti module (vanilla and the apps
  based on it, such as sample_vanilla_falling_blocks; sample_luanti_glue;
  demo_skelenti);
- says when the undrawn line is still the one to wait for;
- says that wait_log_any looks back only 400 lines (log.cpp's
  RECENT_MAX).

Found on the way: the 400-line limit. liquid_shore's wait_log_any for
the world in, placed after "ready" and the undrawn line, came 50 s and
hundreds of cave gate lines after the world-in line and failed. The
world-in wait is now first wherever it is combined with another.

Checks: `run_all.sh --changed 5b1c39eb..568e3e43` under xvfb-run gave 6
passed, 11 failed and 3 skipped. Then:

- Passed, or passed on rerun after the fixes: cold_cache, form_key,
  itemmeta, lua_syntax, server_window_click, wield_follow, liquid_shore,
  mobmesh, local_server_reuse, beam, predict.
- mobmesh fails at HEAD~ (the undrawn line never comes within 120 s) and
  passes now.
- local_server_reuse failed once in the full run, on its menu wait
  (before this change's line). It passes at HEAD~ and at HEAD.
- Fail the same at HEAD~: game_settings ('no visible, uncovered Button
  "Key bindings..."') and pause_keys ("no conclusive run in 5 tries").
- viewkeys: its kept undrawn wait times out at 60 s, with the mesher at
  "2000 to mesh, 44 undrawn" for the last 30 s. This is the slow-mesher
  case from the finding, in a runner that measures drawing.
- drive and fuzz: the world-in start wait passed and the walks ran. Both
  then fail on [FRAME_PEAK] (frames of 1.0-1.2 s, llvmpipe).
- touch_parity and page_tap_outside: the server, with an empty compile
  cache, does not listen within their 60 s start_server limit. That is
  before any client runs.
- Environment: leave_world needs the sqlite3 CLI, which is not installed.
  verdict.sh is mode 644; run_all ran it as a runner, but it is fuzz's
  helper.
- Skipped: footstep (no minetest_game), inv_click (no official Luanti),
  focus.

Open:

- viewkeys' 60 s undrawn wait on a slow mesher.
- touch_parity and page_tap_outside's server start limit.
- game_settings and pause_keys failing here before this change.
- A "world is in again" line after a server move would let predict-like
  runners stop counting undrawn chunks. It does not exist; adding it is a
  client change and a decision.
