# Work for the cloud session, on kit (2026-10-31)

One item on the kit branch (Kit, unreleased: no compatibility with older
Kit or Workbench saves is kept). The rules are round 1's
(claude/cloud-tasks): commit on this branch only, as `git -c
user.name=Claude -c user.email=claude@buildat.org commit`, no
Co-Authored-By, the item's tag in the subject, no PROBE lines; the three
BUILDAT_*_DEFAULTs at https://127.0.0.1:9; no check delay over 2 s (wait
on log lines); results below. Other sessions change Kit's editor
meanwhile (builtin/kit/client_lua/editor.lua: the bar, the inspector,
the Terrain panel; kit/world and the heightmap surface): keep editor.lua
changes to the inspector buttons this item needs, and stay out of
builtin/kit/world.h and apps/workbench.

## kit/voxel_replace and kit/voxel_states [KIT_VOXEL_STATES]

Entities whose voxels change between two states, each inside its own
axis-aligned box (a position parameter as its extent, as kit/dig_zone's
and kit/trigger_zone's: 16x16x16 at most). Both have:
- inputs on, off, toggle; a shared state "on" whose start is a
  parameter ("start_on", default no); an output "changed";
- their voxel writes are game changes (End puts the start back), as
  c:set_voxel's are (builtin/kit/api.h);
- a look outlining the box in the editor (as the zones' looks).

**kit/voxel_replace** (builtin/kit/types/voxel_replace.lua): a
find-and-replace in its box, one pair: parameters `find` and `replace`,
two voxel types (either may be air). On: every `find` cell in the box
becomes `replace`, and the cells changed are remembered (runtime state,
not shared). Off: exactly those cells turned back to `find`, and only
those that still hold `replace` -- a cell that was `replace` before On
stays, a cell dug in between stays dug. On while on, off while off: no
change.

**kit/voxel_states** (builtin/kit/types/voxel_states.lua): the box's
voxels recorded for each state, A (off) and B (on). On/off write the
state's pattern into the box.
- The patterns are kept in the entity's parameters (hidden from the
  inspector's fields; a compact encoding, e.g. a palette of voxel names
  plus run-lengths in box order; 4096 cells at most).
- Editing: no redirection of edits. In the inspector, for the selected
  voxel_states: "Capture A" / "Capture B" record the box's current
  voxels as that state; "Show A" / "Show B" write a state's pattern into
  the world for more editing (an edit, undoable as other edits);
  "Fill A" / "Fill B" set that state to one voxel (the palette's voxel
  in hand, or a dropdown). An empty state writes nothing.
- A server call to write a list of cells for a type (kit.cpp: beside
  c:set_voxel; validated: inside the entity's box, known voxel names,
  4096 cells at most), documented in builtin/kit/api.h.

**Checks**: a native check (util/kit_runtime_check.sh's style, or a
part in it): voxel_replace on/off over a box with find cells, a
pre-existing replace cell and a cell dug while on (all three as above);
voxel_states captured A and B, toggled, the box matching each pattern;
End puts the start back. If a native client drive of the inspector
buttons runs there, one for Capture/Show; otherwise list it as not run.
The browser checks can't run there: list which should be run here.

## Results

Commits: c9c10e03 (the code, the check), and this one (Results).

**What changed where**
- builtin/kit/kit.cpp:
  - Two type declaration fields: `voxel_box = "<position param>"` (the
    box, from the entity's cell up and on, 16 a side at most) and
    `reads_voxels = true` (only with voxel_box). The request carries
    `box={sx,sy,sz}`, plus the box's names and ids with reads_voxels.
  - A parameter type "voxels": "" or a pattern, `"<sx> <sy> <sz>;<name>
    ...;<run> ..."`. A run is `i` or `i*n`, where i is the palette's
    index from 0, in box order (x fastest, then z, then y). It is limited
    to 4096 cells, 256 names and 32 KiB, and is checked on every set.
  - The effect `voxels` is handled by set_voxels(). It refuses the whole
    list, logged, when a cell is outside the box or a name isn't
    registered, or when the list is over 4096 cells. The writes are game
    changes, or builds with `builds = true`, the same as c:set_voxel's.
    A cell whose section isn't loaded is queued.
  - The editor op `{"op": "pattern", id, comp, param, action: capture |
    fill | show, voxel}`. Capture and fill set the parameter through
    "set", so they are one undo each. Show writes the pattern into the
    world as an edit (one undo). Show refuses an empty pattern or one of
    another box size.
  - read_box() reads a cell that was never written (id 0) as "air".
- builtin/kit/box/box.c: `c.box`, `c:voxels()` (a copy of the box's
  names, in box order) and `c:set_voxels({{x, y, z, name}, ...})`, with
  x, y, z counted from the box's first cell.
- builtin/kit/types/voxel_replace.lua and voxel_states.lua, as the item
  describes. Both have inputs on/off/toggle, the shared state "on"
  (start_on at the start), the output "changed" and a box gizmo.
  - voxel_replace keeps the cells it changed in a runtime state
    `changed` (box indices, not shared).
  - voxel_states writes only the cells that differ, logs an empty
    state's "nothing written", and refuses a pattern of another box
    size.
- builtin/kit/client_lua/editor.lua, inspector only, plus the box
  outline:
  - "voxels" parameters are left out of the fields.
  - For each one there is a row "A (empty)" / "A" with "Capture A",
    "Show A" and "Fill A".
  - A "Fill with" dropdown lists the voxel types plus air. It starts at
    the voxel in hand.
  - The voxel_box is outlined in purple next to the zones' outlines.
- builtin/kit/api.h: voxel_box, reads_voxels, c.box, c:voxels(),
  c:set_voxels(), the "voxels" type and its encoding, the editor op
  "pattern" and the two types.

**Design choices to review**
- start_on is applied at the start: on_start writes that state.
  voxel_states writes its A or B; voxel_replace does its replace when
  start_on is on. The task only said that the start of "on" is a
  parameter.
- The pattern encoding is text (palette plus runs), so it stays readable
  in a save or export. The editor op is a generic "pattern" op on any
  "voxels" parameter, not one tied to kit/voxel_states.

**Checks**
- New: `util/kit_voxel_states_check.sh` (native; the admin's scripted
  client on sample_kit): **PASS**. The flow:
  - Ended, the start is set by "set" of a pattern as text, then Show.
  - The inspector buttons are driven natively: Capture A, Show B,
    Capture B and Show A are clicked. The Fill button's op is sent as
    the packet the button sends, since choosing "glass" in the dropdown
    isn't scriptable here.
  - voxel_replace On changes 10 cells: nine floor stones and the pillar.
    The glass cell from before is left alone.
  - The pillar is dug, then Off puts back 9 cells. The dug pillar stays
    air and the old glass cell stays glass.
  - voxel_states writes B, then A. Probe entities capture each box at
    each step, and the check decodes the patterns cell by cell from the
    save.
  - After End both boxes are the start again. The pillar stays dug,
    because a build is kept.
  - start_on plus Run turns voxel_replace on at the start.
- `util/run_all.sh --changed fc48cdc4..HEAD`: 3 passed, 1 failed, 0
  skipped.
  - Passed: lua_syntax, kit_controls_check, kit_voxel_states_check.
  - Failed: kit_runtime_check. This container has no sqlite3 command.
- Run by hand with a temporary sqlite3 shim (python3's sqlite3; not
  committed):
  - `util/kit_runtime_check.sh`: parts 1-4 and 6 ok. Part 5 fails on "No
    wasm toolchain" because this container has clang and wasm-ld in
    /usr/bin, so hiding HOME/EMSDK doesn't hide the toolchain. That is
    environmental, not this change.
  - `util/kit_editor_check.sh`: **PASS**. run_all's diff didn't pick it,
    although it drives editor.lua.
- Browser checks: not run here (no browser drive in this container).
  Please run these on your machine:
  - `util/kit_editor_check.sh web`: the editor and inspector in the web
    client.
  - `util/kit_runtime_check.sh local`: the box built with the server in
    the page. It runs box.c's new c:voxels/c:set_voxels code on the
    browser's wasm.
  - `util/workbench_check.sh web` and `util/workbench_check.sh
    web_touch`: they cover builtin/kit/**, including editor.lua.
  - `util/kit_world_check.sh`: it has a headless Chrome part.
  - Ideally also a manual look at a voxel_states in the web editor
    (Capture, Show, and Fill with the dropdown), since the dropdown
    choice wasn't driven anywhere.

**Open (found on the way; not fixed here)**
- On a fresh sample_kit save, the first End takes away the whole stone
  floor. The round's copy of the section is taken at its first write,
  before the app's on_tick merges the floor in with merge_volume(). That
  is a generator's write, which the section watch doesn't see, so the
  copy has no floor. The check sets its boxes' start explicitly while
  Ended for this reason. A fix belongs in voxelworld or in sample_kit:
  update the copy on merge_volume, or lay the floor before Kit starts
  the round. That is out of this item's files.
- An edit made while Running and then overwritten by a game change in
  the same round is lost at End. mark() erases a cell's 'k' mark on a
  'g' write, so End puts back the round's copy from before the edit.
  This affects "Show A/B" while Running followed by a toggle. Keeping
  'k' marks on game writes would fix it, but it changes Kit's
  start/round rules, so it's a decision for you.
- Not covered by a check: set_voxels' refusals (outside the box, unknown
  name, over 4096 cells) and Show's refusal of a pattern of another box
  size.
