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

Commits (claude/cloud-hm-walk, on c94504b3): a238801a (both items' code
and checks; one change, so one commit with both tags), 4c803673
(workbench_check part 9: the project reopened as "alpha").

**[KIT_HM_WALK]**
- Cause, as suspected: kit.cpp world_load_points' heightmap branch added
  no load points, so no voxel section was ever loaded over a heightmap.
  Every cell read unloaded, and unloaded is solid to the movement
  (move.lua M.UNKNOWN, controls.lua's id 0, the server's step snapshot).
  Reproduced natively with your drive: the body stayed within
  32.5 +/- 0.55 on x and z, 0 corrections.
- Fix (server side): a heightmap World loads its voxel side (the
  "empty" generator's air) round the spawn and each player, as an
  infinite World does. world_peer now tracks players on a heightmap too
  (it returned early for any finite World). The radius is one section
  (32) round a player, not the infinite World's two. Each loaded
  section's chunks are the client's to mesh, empty or not: at two
  sections kit_world_check part 5's `idle 3000` timed out with ~1200
  air chunks queued. A voxel World's "not loaded: solid" is unchanged.
- Why kit_world_check missed it: it never walked on a heightmap. Part 4
  only idled, looked and took a screenshot, on a freshly started server
  with no voxel section loaded. Part 4 now walks w, a, s, d (60 frames
  each) and asserts each leg moved >= 2 m its way with no corrections.
  Against the old kit.cpp it fails ("128.50 128.50; 128.50 129.05;
  ..."); with the fix it passes.
- workbench_check part 9 (New's 64x64 heightmap) walks w, a, s, d,
  120 frames each, asserting >= 3 m a leg and no corrections (about
  8-9 m a leg here).

**[KIT_HM_VOXELS]**
- With the sections loaded, set_voxel, c:set_voxel and
  voxel_replace/voxel_states work on a heightmap as on a voxel World:
  same voxelworld, same copies and marks, End and Running unchanged. As
  on an infinite World, a cell far from every player is "not loaded".
- Save: set_save_unaltered(false) for a heightmap, so only edited
  sections are saved; untouched air sections are not. At the start the
  server logs "World: N edited voxel sections over the heightmap" (a
  separate line, since part 9 asserts a new project has no "World: the
  save holds").
- Pointing (client, builtin/kit/client_lua/module.lua):
  - kit.terrain_cell(x, y, z): a cell whose bottom is under the
    terrain at its middle.
  - kit.place_front: on a terrain hit, the cell over the hit point,
    y = ceil(h + 0.5), so its bottom is at or just above the terrain
    there; on a voxel hit, the face's cell as before.
  - kit.with_terrain wraps an app's solid().
  - Used in play_target (play's dig/place), the editor's voxels tool
    (walk and 3D) and palette placement (place_cell). Workbench's solid
    is now terrain_cell or a voxel (it was y < h, which could sink a
    placed voxel up to half a cell).
  - Dig: voxels only. A terrain cell is not dug: the editor logs "kit
    editor: dig: the heightmap is not dug, at x,y,z"; play offers no
    dig there.
- Simplified:
  - The Terrain tool changing the ground leaves voxels where they are
    (floating or buried).
  - A voxel buried by a later raise can't be dug by click (it reads as
    terrain).
- Open, your call: switching a World from voxels to a heightmap keeps
  the voxel ground's edited sections in the save (as before, the
  "edited kept" rule). Before this change they never loaded; now those
  near a player load and show over the heightmap: a dug hole's section
  appears as a block of voxel ground. Dropping them at the switch would
  lose them for a switch back.
- Check: workbench_check part 9, on New's heightmap in the editor's
  walk view with the voxels tool:
  - a voxel placed on the ground (32,6,29 on the terrain at 5);
  - one on its face (32,6,30);
  - a third placed and dug;
  - a left click on the terrain: "the heightmap is not dug";
  - End.
  The project is then opened again (save=alpha, a new server): the
  guide at the same aim says "Left: dig 32,6,30", and the server logs
  "World: 1 edited voxel sections over the heightmap".

**Checks run here** (native, xvfb; the sqlite3 CLI is missing here, so
a python stand-in was on PATH):
- kit_world_check: all 7 native parts pass (3 full runs); only its web
  part fails (no Chrome).
- kit_controls_check: PASS.
- workbench_check (native): PASS.
- `util/run_all.sh --changed c94504b3..HEAD`: lua_syntax,
  kit_publish_check, kit_voxel_states_check and workbench_check pass.
  kit_runtime_check fails its part 5 "No wasm toolchain" (environmental:
  clang and wasm-ld are installed here). kit_world_check failed once in
  that run at part 6 (below); it passed in the 3 other runs.
- Flakes found:
  - Part 7's wait for "kit: World: generated again" was a `wait_log`
    started after the packet could already have come. It failed every
    run here, base sources included. Now `wait_log_any` (the only one in
    that client's log).
  - Part 6 (1 failure in 4 runs): regen_w's `wait_log ... generated
    again` can match the previous regeneration's late packet
    (decorations, then biome), so `column 8 8` reads before the biome's
    sections. Not fixed: it needs a per-regeneration id or count in
    kit:regenerated.

**Browser checks to run there**:
- `util/kit_world_check.sh` (its web part: the heightmap save in the
  web client);
- `util/workbench_check.sh web` and `util/workbench_check.sh web_touch`
  (Kit's editor and play by finger: pointing changed);
- `util/kit_editor_check.sh web`;
- `util/kit_runtime_check.sh local` (part 5 needs a host without the
  wasm toolchain).
- Also worth a manual look in a browser: a New project's heightmap
  walked on and built on, and the client's frame time with the air
  chunks meshed (27 sections, about 430 chunks, round the player).
