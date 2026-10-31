# Work for the cloud session, on kit (2026-10-31)

One fault on the kit branch (Kit, unreleased: no compatibility with older
Kit or Workbench saves is kept). The rules are round 1's
(claude/cloud-tasks): commit on this branch only, as `git -c
user.name=Claude -c user.email=claude@buildat.org commit`, no
Co-Authored-By, the item's tag in the subject, no PROBE lines; the three
BUILDAT_*_DEFAULTs at https://127.0.0.1:9; no check delay over 2 s (wait
on log lines); results below. Fix only this; no other features.

## The walker boxed in on a heightmap World [KIT_HM_WALK]

The user's playtest: a new Workbench project (Manage's New: kit/world's
surface a 64x64 grassland heightmap, [WB_NEW_PROJECT_GROUND]) -- the
player can walk only a little, as if walled in.

Reproduced (native, this probe; the terrain draws fine):

    BUILDAT_WORKBENCH_STONE= bin/buildat_server \
        -u "$(printf 'launcher=1\nmenu=new')" -m ../apps/workbench -D <user> -l 3
    client drive: wait_log_any "world_menu: the name screen shown", text
    alpha, click Button "Create", wait_log_any "heightmap: terrain built",
    then event kit_body; keydown w, frames 120, keyup w; event kit_body;
    the same with a, s, d

    kit: body at 32.50,5.18,32.50, 6 acks, 0 corrections   (put at 32.5, 5.655, 32.5)
    kit: body at 32.50,5.50,33.05   (after W)
    kit: body at 31.95,5.50,33.05   (after A)
    kit: body at 31.95,5.50,32.95   (after S, twice as long)
    kit: body at 32.05,5.50,32.95   (after D, twice as long)

The body (r 0.45) stays inside about [31.5, 33.5] on x and z: the cells
next to the one it stands in act solid. No corrections, so the server's
step and the client's prediction agree. Hypothesis, not verified: the
heightmap World's voxel side (set_world_generator with no Heights: the
"empty" generator, builtin/kit/kit.cpp ~3446) has no loaded sections
round the player, and a cell not loaded is solid for movement
(builtin/kit/client_lua/move.lua:113 M.UNKNOWN; controls.lua world()
`id == 0 -> MV.UNKNOWN`; kit.cpp's per-step cells snapshot "?" ). Check
that first; the fix may be on either side (sections loaded/generated as
air round the player, or a heightmap World treating unloaded cells above
the map's ground as air), your call -- keep a voxel World's "not loaded:
solid" as it is. kit_world_check covers walking on a heightmap and
passed: find out why it misses this (a different setup, or a walk too
short) and make the check catch it.

**Checks**: a native check part that walks several metres each way on a
New project's heightmap (workbench_check part 9 or kit_world_check), and
the existing kit_world_check, kit_controls_check, workbench_check
(native) passing. The browser checks can't run there: list which should
be run here.

## Results

(Commits, what changed where, checks run and their results, anything
open.)
