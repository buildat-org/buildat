# Work for the cloud session, on kit (2026-10-31)

Two items on the kit branch, in order (Kit, unreleased: no compatibility with older
Kit or Workbench saves is kept). The rules are round 1's
(claude/cloud-tasks): commit on this branch only, as `git -c
user.name=Claude -c user.email=claude@buildat.org commit`, no
Co-Authored-By, the item's tag in the subject, no PROBE lines; the three
BUILDAT_*_DEFAULTs at https://127.0.0.1:9; no check delay over 2 s (wait
on log lines); results below. Only these two; no other features.

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

## Voxels built on a heightmap World [KIT_HM_VOXELS]

(User, 2026-10-31: "Let's do B for now, to keep things simple"; B is
a voxel world overlaid on the heightmap, against A, a Kit type for
voxel objects, which is not wanted now.) On a heightmap World the usual
voxel tools build on the world's voxel grid on top of the terrain:
the editor's palette placing voxels, walk mode's left dig / right
place (builtin/kit/client_lua/editor.lua, the walk Voxels tool), the
voxel_replace/voxel_states entities and c:set_voxel. Today a place on
the heightmap is refused: "set_voxel: the cell's section is not
loaded" (the user's playtest log).
- The voxel side of a heightmap World is air (the "empty" generator,
  kit.cpp set_world_generator) loaded round the players as a voxel
  World's sections are, so a placed voxel has a loaded section to go
  in; probably the same change as [KIT_HM_WALK]'s fix, do them
  together if so.
- Pointing: a ray hitting the heightmap places on the voxel cell above
  the hit point (the cell whose bottom is at or just above the terrain
  there, so a voxel stands on the ground, not floating or buried
  deeper than the terrain's height within that cell); a ray hitting a
  voxel places on its face as usual. Dig: voxels only, the heightmap
  is not dug (no holes; the Terrain tool still shapes it).
- Only edited sections are saved (set_save_unaltered false for an air
  generator would be the infinite rule; the map is finite: keep the
  save small -- untouched air sections unsaved). End and Running work
  as for a voxel World (copies, marks).
- The heightmap's Terrain tool changing the ground under existing
  voxels: leave them where they are (simplified, say so).

**Checks**: a native drive on a New project's heightmap: place several
voxels by the walk Voxels tool (right click) on the terrain and on each
other, dig one, End, restart the server: they are still there (or,
placed while Running as a build, discarded per the existing rules --
place them in edit mode for the persistence part).

## Results

(Commits, what changed where, checks run and their results, anything
open.)
