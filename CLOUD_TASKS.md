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

(Commits, what changed where, checks run and their results, anything
open.)
