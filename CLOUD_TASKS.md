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

(Fill in per item: commits, cause, numbers, checks run and their
results, anything left open.)
