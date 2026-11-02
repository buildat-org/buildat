#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~1 min, ~2 min with a cold module cache (2026-10-30)
# covers: apps/workbench/** builtin/kit/** extensions/pause_menu/** builtin/world_menu/**
# [KIT] stages 4 and 4b, Workbench and Kit's starter set (kit/*), on
# scripted clients, the server's game clock at CHECK_RATE (the timer's
# seconds are the game's):
#   1. The admin (kitboss, by the setup code) gets to the tools and stops
#      the server by the pause menu's Edit and Stop (Escape;
#      extensions/pause_menu; a fresh save is Running, [KIT] stage 4c),
#      and Escape in the tools cancels a pending link before it opens the
#      menu again (its Play, then Play mode); builds a contraption in Kit's
#      editor, by its packets, Stopped (the door, the gate and the button
#      objects, drawn from the start's state: shut, solid):
#      a spawner, a button, a gate, a lever, a timer, a door, a
#      teleporter, a trigger zone, a scoreboard, a counter, an NPC, an
#      item giver, a key door (taking the key), a dig zone and "Player
#      state between plays" (keeping positions: Play leaves the admin
#      where they are), their parameters set and linked (the button opens the
#      gate and starts the timer, the timer flips the
#      lever three times, the lever opens and shuts the door, the zone
#      scores the players who walk in and counts them, the counter at two
#      makes the NPC speak), and presses Play.
#   2. The admin plays it, by the play rules out of edit mode
#      ([KIT_BUILDER_PLAY_RULES]: a dig sent outside the region refused;
#      the region, 16, a big box round the spawn, digging and placing for
#      all but owners, of whom it has none): looks at the button, shown as used (E does
#      nothing, [KIT] stage 4e2), and clicks it (the gate
#      opens, the timer ticks three times, the lever flips, the door
#      follows, the button comes up again), digs the floor past the
#      button (an object, no voxel) and places a stone, each shown first
#      (the dig's frame, the placement's face), talks to the NPC, takes
#      a key from the item giver (once), and uses the teleporter, which
#      puts them in the zone: scored, counted.
#   3. A second player (kitbob) joins mid-round and is put on the spawner,
#      is shown nothing to click on the floor (no edit rights), is refused
#      a dig sent anyway, but digs in the dig zone, is refused
#      by the key door, takes a key from the item giver and opens the door
#      with it (the key taken), takes the teleporter into the zone
#      (scored, counted: the counter reaches two and the NPC speaks), and
#      walks out of it.
#   4. A restart mid-round: the authored row and the runtime row (the
#      scores, the lever, the door, the key) are the save's, the server
#      Running; the admin is put on the spawner and sees the scoreboard and
#      the key. Then, with "keep inventory" on and "keep position" off:
#      Stop puts back the cell kitbob dug before the restart (the admin
#      digs it again, in the start) and drops the key from play; Play
#      gives it back and the spawner places the admin. A cell dug before
#      "Save as start" stays dug past a Stop, one dug after is put back.
#      "keep inventory" off, the next Play resets the inventory.
#      The origins: the first Stop discards kitbob's dig and the admin's
#      builds, the notice naming both; kitbob's kept by choice, the
#      admin's a moment later; the second Stop's discarded build is gone
#      with the next Play (a keep after the next Stop refused).
#   5. A door placed in the round stops the admin's walk while shut and
#      lets it through into a zone behind it when open (their client's
#      physics on the door's collision shape); with "Always keep builds"
#      the admin's dig is kept at Stop, and no notice.
#   6. ([KIT] stage 4d) A link of mismatched signal types refused;
#      kit/button_door placed, saved as the admin's prefab, a copy of it
#      placed and following its next version but for what was set on the
#      copy; the spawner set to copy it when a button signals (the link
#      line lit, the spawner's log in the editor), at most max, a live
#      edit (on_params), "Restart this" taking the copy back (on_remove),
#      the copies gone at Stop; a wedge kit/part; kit/door's client part
#      swinging a door on use, and the other way once mirrored, live
#      ([KIT_DOOR_MIRROR]), and in Kit's planks ([KIT_LOOK_MATERIAL]).
#      The players' items and scores are on their
#      entities, the zone's members in the runtime row.
#   7. ([KIT] stage 4e2) Kit's editor as floorplanner's, by mouse and by
#      finger: below.
#   8. ([KIT] stage 4g) A builder's voxel type made, drawn by a second
#      client already in, placed and kept over a restart: below.
#   9. ([WORKBENCH_PROJECTS]) The projects, by the launcher's own client;
#      a New project's heightmap walked on and built on: below.
# Parts 1-8 make their project in Manage (New project..., the name
# "project" it offers when there is none), a restart opening it again.
# KEEP_TMP=1 keeps the screenshots: the contraption in edit mode, in play,
# after the restart, and after the Stop; what is pointed at in play; part
# 7's views, drags and menus; part 8's dialog, palette and the type placed.
#
#   util/workbench_check.sh
#   util/workbench_check.sh web    the admin's part in headless Chrome
#   util/workbench_check.sh web_touch   Kit's editor and play by finger
#                                  there (TOUCH=1)
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
# Parts 1-8 build on the stone floor; New's own ground, a heightmap
# ([WB_NEW_PROJECT_GROUND]), is part 9's
export BUILDAT_WORKBENCH_STONE=1
if [ "${1:-}" = web ]; then
	# Workbench in the web client (web/), in headless Chrome at 1200x800:
	# the admin logs in (the setup code), points at the floor ahead in
	# edit mode (545,578: the middle of cell (0,0,5)'s top seen from the
	# spawn; the camera lands a few hundredths off (0.5, 0.5), and 600,600
	# ran along x 0.5 and met the floor at z 4.5, both between cells),
	# places an NPC there, lifts it a cell, leaves edit mode and talks to
	# it with E: the server Running from the start, the NPC placed live
	# ([KIT] stage 4d: restarted by the inspector's "Restart this", its
	# dialog drawn by kit/npc's client part; then kit/button_door placed
	# from the palette). The pause menu ([KIT] 4c, extensions/pause_menu): up at
	# once for the pointer lock not given (skeldat's web_lock_check
	# stand-in in the page from the login on, refusing until the click off
	# the menu that closes it: Chromium under a window manager gave the
	# lock and no menu came up, 2026-11-02); Escape and the menu's Edit (clicked by label, near where
	# the menu's rows are at 1200x800: Kit's top bar has the same labels);
	# a link begun, Escape cancels it, the next Escape the menu;
	# Stop and Play there, and Play mode; ([KIT] stage 4f) a raise stroke
	# dragged in the plan by mouse (T), and Ctrl+Z its undo; ([KIT] stage
	# 4g) "New voxel type...": a PNG uploaded by the browser's picker, the
	# type named frost and made, taken in hand from the Voxel list (Down,
	# Enter: a builder's own come first; the voxels tool on with it, which
	# the first Escape puts away) and placed in play, in a region (6, at
	# about (-1, 1, 2), clicked in from the palette in the plan) letting all
	# place ([KIT_BUILDER_PLAY_RULES]: out of edit mode the admin plays by
	# the rules); the palette's NPC dragged by label ([KIT_SCENES]' Scene
	# dropdown moved its rows)
	check_tmp workbench_web; t=$CHECK_TMP
	stub="(function(){ var held = null, refuse = false;
 Object.defineProperty(document, 'pointerLockElement', {configurable: true, get: function(){ return held; }});
 function set(e){ held = e; document.dispatchEvent(new Event('pointerlockchange')); }
 document.addEventListener('keydown', function(e){ if(e.key === 'Escape') refuse = true; }, true);
 document.addEventListener('mousedown', function(){ refuse = false; }, true);
 HTMLCanvasElement.prototype.requestPointerLock = function(){
  if(refuse || !window.lockOk){ document.dispatchEvent(new Event('pointerlockerror')); return Promise.reject(new Error('refused')); }
  if(held !== this) set(this); return Promise.resolve(); };
 document.exitPointerLock = function(){ if(held) set(null); };
 return 'stub'; })()"
	cat > "$t/steps.json" <<J
[
	["nav", "\${URL}"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["eval", "$(echo "$stub" | tr "\n" " ")"],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "\${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["click", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["click", "Button", "New project..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["click", "Button", "Create"],
	["waitlog", "player physics enabled", 120],
	["waitlog_any", "pause: the menu shown", 10],
	["eval", "window.lockOk = true, 'lock given from here'"],
	["click", 100, 700], ["waitlog", "pause: the menu closed", 10], ["wait", 1000],
	["waitlog_any", "kit editor: edit rights: yes", 10],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["shot", "\${OUT}/menu.png"],
	["click", "Button", "Edit", 600, 339], ["waitlog", "kit editor: state: 1 entities", 20],
	["key", "F1"], ["waitlog", "kit editor: the view is 2D", 10], ["frames", 3],
	["drag", "Button", "kit/npc", 616, 250], ["waitlog", "kit editor: state: 2 entities, 1 to undo", 10],
	["frames", 3], ["click", 616, 250], ["waitlog", "kit editor: selected 3", 10],
	["key", "PageUp"], ["waitlog", "kit editor: state: 2 entities, 2 to undo", 10],
	["frames", 3], ["shot", "\${OUT}/edit.png"],
	["click", "Button", "Restart this"], ["waitlog", "kit editor: log of 3: .*restarted by webboss", 10],
	["click", "Button", "Link said"], ["waitlog", "kit editor: linking from 3 said", 10],
	["key", "Escape"], ["waitlog", "kit editor: link cancelled", 10],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "End", 600, 380], ["waitlog", "kit editor: the server is Ended .by webboss.", 10],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Run", 600, 380], ["waitlog", "kit editor: the server is Running .by webboss.", 10],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Play mode", 600, 339], ["waitlog", "kit editor: edit mode off", 10],
	["frames", 3], ["shot", "\${OUT}/npc.png"],
	["click", 600, 400], ["waitlog", "kit: entity 3 shows .Bob: Hello!.", 10],
	["waitlog_any", "kit: entity 3's client part: dialog: Bob: Hello!", 10],
	["frames", 5], ["shot", "\${OUT}/play.png"],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Edit", 600, 339], ["waitlog", "kit editor: state: 2 entities", 10],
	["click", "Button", "[kit/button_door]"], ["waitlog", "kit editor: placing .kit/button_door", 10],
	["click", 800, 550], ["waitlog", "kit editor: state: 4 entities", 10],
	["key", "t"], ["waitlog", "kit editor: tool terrain", 10], ["frames", 3],
	["drag", 450, 620, 650, 620], ["waitlog", "kit editor: terrain: raise", 10],
	["waitlog", "kit editor: the stroke ended", 10], ["frames", 5],
	["shot", "\${OUT}/terrain.png"],
	["chord", "Ctrl+z"], ["sync", 5000],
	["key", "t"], ["waitlog", "kit editor: tool select", 10], ["frames", 5],
	["click", "Button", "New voxel type..."], ["frames", 5],
	["file", "$t/frost.png"], ["click", "Button", "Upload a PNG..."],
	["waitlog", "kit editor: uploaded kit/up/", 10], ["frames", 3],
	["click", "LineEdit", "my_voxel"], ["key", "End"], ["key", "Backspace"], ["key", "Backspace"],
	["key", "Backspace"], ["key", "Backspace"], ["key", "Backspace"],
	["key", "Backspace"], ["key", "Backspace"], ["key", "Backspace"],
	["type", "frost"], ["frames", 2],
	["click", "LineEdit", "1", 717, 562], ["selall"], ["type", "0.2"], ["frames", 2],
	["shot", "\${OUT}/voxel_dialog.png"],
	["click", "Button", "Make"], ["waitlog", "kit editor: [0-9]+ voxels to place", 10],
	["frames", 3],
	["click", "DropDownList", "▼", 203, 449], ["frames", 5], ["shot", "\${OUT}/voxel_list.png"],
	["key", "Down"], ["key", "Enter"],
	["waitlog", "kit editor: in hand webboss/frost", 10],
	["waitlog", "kit editor: tool voxels", 10],
	["key", "Escape"], ["waitlog", "kit editor: tool select", 10],
	["click", "Button", "kit/region"], ["waitlog", "kit editor: placing kit/region", 10],
	["click", 560, 340], ["waitlog", "kit editor: placed kit/region at", 10],
	["key", "Escape"], ["waitlog", "kit editor: placing nothing", 10],
	["click", 560, 340], ["waitlog", "kit editor: selected 6", 10], ["frames", 3],
	["click", "DropDownList", "▼", 1162, 428], ["waitlog", "ui_utils: dropdown_[0-9]+ open", 10],
	["key", "Home"], ["key", "Enter"], ["waitlog", "kit editor: 6/1 place = all", 10],
	["click", "Button", "Apply"], ["sync", 5000], ["frames", 3],
	["shot", "\${OUT}/region.png"],
	["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["click", "Button", "Play mode", 600, 339], ["waitlog", "kit editor: edit mode off", 10], ["frames", 5],
	["mouse", 600, 400], ["frames", 2], ["mouse", 600, 560], ["frames", 5],
	["shot", "\${OUT}/voxel_aim.png"],
	["click", 600, 560, 100, 2], ["sync", 5000], ["frames", 5],
	["shot", "\${OUT}/voxel_placed.png"]
]
J
	cp "$here/apps/workbench/main/client_data/lever_on.png" "$t/frost.png"
	"$here/util/web_drive.sh" chrome workbench "$t/steps.json" "$t/out" ||
		fail "the web drive ($t/out)"
	grep -aq "kit/npc 3: says to webboss" "$t/out/server.log" ||
		fail "the NPC said nothing to webboss ($t/out/server.log)"
	# [KIT] stage 4d: Restart this, the NPC's client part, a prefab placed
	# from the palette
	for w in "webboss restarts entity 3's kit/npc from the start" \
			"placed prefab kit/button_door as 4...5" \
			"Terrain by webboss: raise at" \
			"An undo by webboss: a terrain stroke" \
			"webboss uploaded texture kit/up/" \
			"webboss made voxel type webboss/frost version 1 (kit/up/" \
			"An edit by webboss: set 6's kit/region place to \"all\"" \
			"workbench: webboss placed webboss/frost ("; do
		grep -aqF "$w" "$t/out/server.log" || fail "no \"$w\" in $t/out/server.log"
	done
	# The first Escape in the tools took the link, not the menu
	awk '/kit editor: linking from 3/ { l = 1 } l && /pause: the menu shown/ { exit !c } l && /link cancelled/ { c = 1 } END { exit !c }' "$t/out/page.log" ||
		fail "Escape did not cancel the link before opening the menu ($t/out/page.log)"
	echo "PASS: Workbench in the web client: the pause menu's Edit, End, Run and Play mode, Escape cancelling a link first; the admin places an NPC in Kit's editor and talks to it; a terrain stroke by mouse and its undo; a voxel type made from an uploaded PNG and placed"
	exit 0
fi
if [ "${1:-}" = web_touch ]; then
	# ([KIT] stage 4e2) Workbench in the web client as a phone (TOUCH=1,
	# 1000x500, headless Chrome): the admin logs in, the touch bar's Menu
	# and Edit; in the plan (F1) the palette (folded on a narrow screen,
	# its toggle tapped) dragged from by finger, a tap selects, a drag
	# moves it 3 cells, a finger held is its menu (Duplicate), two fingers
	# pinch; ([KIT_SELECT_BURIED]) five more copies (Ctrl+D) listed with
	# the list's Positioned tab, the list bounded under the bar (it
	# scrolls), the copies undone; ([KIT_BUILDER_PLAY_RULES]) a region
	# tapped in from the palette at (-1, 1, 1), a cell down, digging and
	# placing for all in the inspector, each list's row tapped: the UI fit
	# holds while a list is up, which takes the inspector off the root
	# ([TOUCH_UI_SCALE_JUMP]: the fit went back to x1 and the list opened
	# off the screen), and a row found by label is on it; the inspector
	# scrolls ([KIT_INSPECTOR_OFF_SCREEN]: its foot was off the screen),
	# its bar's down arrow tapped to the two rows and a finger dragged
	# to Apply, tapped by label: the
	# admin plays by the rules out of
	# edit mode; ([KIT] stage 4f) a finger dragged with the terrain tool (T)
	# paints a raise stroke, undone; Play mode, and in play a tap uses the button, a tap digs and
	# a finger held places. The stroke (x -7 to -4, z 1, 50 px a cell
	# after the pinch, radius 3) keeps off the player at (0.5, 0.5): ground
	# raised into the body shoved it up to 2 cells aside, the undo did not
	# put it back, and the play taps pointed past the button. The player
	# still settles a few hundredths off (0.5, 0.5): the taps are where the
	# use (566, 389) and the dig of (1, 0, 3) under the button (575, 470)
	# hit the same with the eye 0.15 off either way. The open palette (470
	# tall in a root of 400) makes the UI fit shrink it; the screen still
	# reads narrow ([KIT_NARROW_RESCALE]), so the bar's Palette stays and
	# is tapped by label, and the drag starts at kit/button after the fit,
	# by label too ([KIT_SCENES]' Scene dropdown moved the palette's rows).
	check_tmp workbench_web_touch; t=$CHECK_TMP
	cat > "$t/steps.json" <<'J'
[
	["nav", "${URL}"],
	["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
	["key", "Tab"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Tab"], ["frames", 2], ["key", "Enter"], ["wait", 1000],
	["selall"], ["frames", 2], ["type", "webboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "checkpass12"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["type", "${SETUP_CODE}"], ["frames", 2], ["key", "Tab"], ["frames", 2],
	["key", "Enter"], ["waitlog", "Joined as webboss", 30],
	["waitlog_any", "server window: the page ntfy", 30], ["frames", 3],
	["tap", "Button", "Don't add"], ["frames", 3],
	["waitlog_any", "world_menu: the list shown, 0 worlds", 30], ["frames", 3],
	["tap", "Button", "New project..."],
	["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
	["tap", "Button", "Create"],
	["waitlog", "player physics enabled", 120], ["frames", 10],
	["waitlog_any", "kit editor: edit rights: yes", 10], ["frames", 10],
	["tap", "Button", "Menu"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["tap", "Button", "Edit", 500, 174], ["waitlog", "kit editor: state: 1 entities", 20],
	["key", "F1"], ["waitlog", "kit editor: the view is 2D", 10], ["frames", 5],
	["shot", "${OUT}/plan.png"],
	["tap", "Button", "Palette"],
	["waitlog", "UI scale fitted to the screen: x0", 5], ["frames", 3],
	["shot", "${OUT}/palette.png"],
	["drag", "Button", "kit/button", 572, 198, "touch"],
	["waitlog", "kit editor: state: 2 entities, 1 to undo", 10],
	["tap", "Button", "Palette"], ["frames", 3],
	["tap", 572, 198], ["waitlog", "kit editor: selected 3", 10], ["frames", 3],
	["drag", 572, 198, 510, 198, "touch"],
	["waitlog", "kit editor: moved 1 by -3, 0", 10], ["frames", 5],
	["hold", 510, 198, 800], ["waitlog", "kit editor: the menu of 3", 10],
	["frames", 3], ["shot", "${OUT}/menu.png"],
	["tap", "Button", "Duplicate"], ["waitlog", "kit editor: state: 3 entities", 10],
	["chord", "Ctrl+d"], ["waitlog", "kit editor: state: 4 entities", 10],
	["chord", "Ctrl+d"], ["waitlog", "kit editor: state: 5 entities", 10],
	["chord", "Ctrl+d"], ["waitlog", "kit editor: state: 6 entities", 10],
	["chord", "Ctrl+d"], ["waitlog", "kit editor: state: 7 entities", 10],
	["chord", "Ctrl+d"], ["waitlog", "kit editor: state: 8 entities", 10],
	["tap", "Button", "Positioned (*"],
	["waitlog", "kit editor: list Positioned", 10],
	["waitlog", "kit editor: the list ", 10], ["frames", 5],
	["shot", "${OUT}/list.png"],
	["tap", "Button", "Scene (*"], ["waitlog", "kit editor: list Scene", 10],
	["tap", "Button", "Game-wide (*"],
	["waitlog", "kit editor: list Game-wide", 10],
	["chord", "Ctrl+z"], ["waitlog", "kit editor: state: 7 entities", 10],
	["chord", "Ctrl+z"], ["waitlog", "kit editor: state: 6 entities", 10],
	["chord", "Ctrl+z"], ["waitlog", "kit editor: state: 5 entities", 10],
	["chord", "Ctrl+z"], ["waitlog", "kit editor: state: 4 entities", 10],
	["chord", "Ctrl+z"], ["waitlog", "kit editor: state: 3 entities", 10],
	["frames", 3],
	["tap", "Button", "Palette"], ["frames", 3],
	["tap", "Button", "kit/region"], ["waitlog", "kit editor: placing kit/region", 10],
	["tap", 469, 240], ["waitlog", "kit editor: state: 4 entities", 10],
	["key", "Escape"], ["frames", 3],
	["tap", "Button", "Palette"], ["frames", 3],
	["tap", 469, 240], ["waitlog", "kit editor: selected 10", 10],
	["key", "PageDown"], ["waitlog", "kit editor: state: 4 entities, 5 to undo", 10],
	["tap", "Button", "Inspector"], ["frames", 5],
	["waitlog", "kit editor: the inspector [0-9]+ of [0-9]+ tall", 10],
	["shot", "${OUT}/inspector.png"],
	["tap", 972, 394], ["frames", 3],
	["tap", 972, 394], ["frames", 3],
	["tap", 972, 394], ["frames", 3],
	["tap", 972, 394], ["frames", 3],
	["tap", 972, 394], ["frames", 3],
	["tap", 972, 394], ["frames", 3],
	["tap", "DropDownList", "▼", 960, 183], ["waitlog", "ui_utils: dropdown_[0-9]+ open", 10],
	["frames", 3], ["shot", "${OUT}/dropdown.png"],
	["tap", "Text", "all", 930, 205], ["waitlog", "kit editor: 10/1 dig = all", 10],
	["tap", "DropDownList", "▼", 960, 355], ["waitlog", "ui_utils: dropdown_[0-9]+ open", 10],
	["frames", 3],
	["tap", "Text", "all", 930, 377], ["waitlog", "kit editor: 10/1 place = all", 10],
	["drag", 515, 380, 515, 120, "touch"], ["frames", 10],
	["drag", 515, 380, 515, 120, "touch"], ["wait", 1000],
	["shot", "${OUT}/inspector_foot.png"],
	["tap", "Button", "Apply"], ["waitlog", "kit editor: state: 4 entities, 7 to undo", 10],
	["frames", 3], ["shot", "${OUT}/region.png"],
	["tap", "Button", "Inspector"], ["frames", 3],
	["fingers", 450, 250, 550, 250, 350, 250, 650, 250],
	["waitlog", "kit editor: two fingers let go: the plan", 10],
	["frames", 5], ["shot", "${OUT}/pinched.png"],
	["key", "t"], ["waitlog", "kit editor: tool terrain", 10], ["frames", 3],
	["drag", 100, 250, 250, 250, "touch"],
	["waitlog", "kit editor: terrain: raise", 10],
	["waitlog", "kit editor: the stroke ended", 10], ["frames", 5],
	["shot", "${OUT}/painted.png"],
	["chord", "Ctrl+z"], ["sync", 5000], ["key", "t"], ["frames", 3],
	["tap", "Button", "Menu"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
	["tap", "Button", "Play mode", 500, 174], ["waitlog", "kit editor: edit mode off", 10],
	["frames", 10], ["shot", "${OUT}/play.png"],
	["hold", 566, 389, 300], ["waitlog", "kit: use 3", 10],
	["hold", 575, 470, 300], ["waitlog_any", "kit: points at dig", 10], ["sync", 5000],
	["hold", 575, 470, 900], ["sync", 5000],
	["frames", 5], ["shot", "${OUT}/placed.png"]
]
J
	TOUCH=1 WEB_DRIVE_VIEWPORT=1000x500@1 \
		"$here/util/web_drive.sh" chrome workbench "$t/steps.json" "$t/out" ||
		fail "the web drive ($t/out)"
	# The UI scale held from the first list up until the second's pick
	awk '/kit editor: selected 10/ { s = 1 } !s { next }
		/UI scale fitted/ { if (o) exit }
		/ui_utils: dropdown_[0-9]+ open/ { o = 1 }
		/kit editor: 10\/1 place = all/ && o { ok = 1; exit }
		END { exit !ok }' "$t/out/page.log" ||
		fail "the UI scale moved with the inspector's lists up ($t/out/page.log)"
	# [KIT_BAR_SERVER_OVERLAP] The bar's first row clear of the Server
	# button at every width the fit gave it
	awk '/kit editor: bar.s first row ends at/ { n++; e = $(NF - 5) + 0;
			l = $NF + 0; if (e >= l) { print; bad = 1 } }
		END { exit bad || !n }' "$t/out/page.log" ||
		fail "the bar's first row under the Server button ($t/out/page.log)"
	# [KIT_LIST_TABS] Each tab lists its own: the seven kit/buttons
	# placed, nothing game-wide nor of the scene
	for w in "kit editor: list Positioned (7): 3, 4, 5, 6, 7, 8, 9" \
			"kit editor: list Scene (0): " "kit editor: list Game-wide (0): "; do
		grep -aq "$w\$" "$t/out/page.log" || fail "no \"$w\" in $t/out/page.log"
	done
	# [KIT_EDIT_NOTICE_SERVER] "You may edit here" under it too
	awk '/ui_utils: notification: from y/ { n++; y = $(NF - 6) + 0;
			f = $NF + 0; if (y <= f) { print; bad = 1 } }
		END { exit bad || !n }' "$t/out/page.log" ||
		fail "a notice over the Server button ($t/out/page.log)"
	for w in "An edit by webboss: placed kit/button 3 at [4,1,3]" \
			"An edit by webboss: moved 3 to [1,1,3]" \
			"kit/button 3: pressed by webboss" \
			"An edit by webboss: set 10's kit/region dig to \"all\"" \
			"An edit by webboss: set 10's kit/region place to \"all\"" \
			"workbench: webboss dug (1,0,3): written" \
			"workbench: webboss placed kit/stone (1,0,3): written" \
			"Terrain by webboss: raise at" \
			"An undo by webboss: a terrain stroke"; do
		grep -aqF "$w" "$t/out/server.log" || fail "no \"$w\" in $t/out/server.log"
	done
	echo "PASS: Workbench in the web client by finger: Kit's editor's palette drag, tap, drag, held menu and pinch, a terrain stroke painted and undone; in play a tap uses and digs, a finger held places"
	exit 0
fi
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp workbench; t=$CHECK_TMP
save="$t/user/apps/workbench/saves/project"
cd "$here/Build"

server() # <n> [user dir]
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -m ../apps/workbench -D "${2:-$t/user}" -l 3 \
		--sim-rate "$CHECK_RATE" ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
client() # <name>: its commands in $t/<name>.cmds; BUILDAT_JOIN_* its login
{
	sed -i "s|@T@|$t|g" "$t/$1.cmds"
	run_client 60 "$t/$1.log" timeout 240 bin/buildat -C "$t/client_cache" \
		-D "$t/cu_$1" -s localhost:$SERVER_PORT -w 1024x700 -l 3 \
		-c @"$t/$1.cmds" ||
		fail "client $1 failed ($t/$1.log, $t/srv*.log)"
}
stop()
{
	kill -INT "$SERVER_PID" 2>/dev/null
	wait "$SERVER_PID" 2>/dev/null
}
want() # <log> <text>...
{
	local log=$1 w
	shift
	for w in "$@"; do
		grep -aqF -- "$w" "$log" || fail "no \"$w\" in $log"
	done
}
export BUILDAT_JOIN_PASSWORD=checkpass12 BUILDAT_JOIN_CREATE=1

# Each edit as the editor sends it, and its answer: the undo count
n=0
edit() # <json>
{
	n=$((n + 1))
	printf 'event kit_edit %s\nwait_log 10000 entities, %d to undo\n' "$1" "$n"
}
{
	cat <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 30000 world_menu: the list shown, 0 worlds
frames 3
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress Escape
wait_log 10000 pause: the menu shown
frames 3
screenshot @T@/menu.png
click Button "Edit"
wait_log 10000 kit editor: state: 1 entities, 0 to undo
keypress Escape
wait_log 10000 pause: the menu shown
click Button "End" 512 350
wait_log 10000 kit editor: the server is Ended (by kitboss)
EOF
	# 3 spawner, 4 button, 5 gate, 6 lever, 7 timer, 8 door, 9 teleporter,
	# 10 trigger zone, 11 scoreboard, 12 counter, 13 npc, 14 item giver,
	# 15 key door, 16 region (digging for all), 17 player state (on the app root)
	for p in 'kit/spawner [0, 1, -4]' 'kit/button [2, 1, 2]' 'kit/gate [4, 1, 6]' \
			'kit/lever [-2, 1, 2]' 'kit/timer [-3, 1, 2]' 'kit/door [-4, 1, 6]' \
			'kit/teleporter [0, 1, -1]' 'kit/trigger_zone [6, 1, -10]' \
			'kit/scoreboard [6, 1, -4]' 'kit/counter [5, 1, -4]' 'kit/npc [2, 1, -3]' \
			'kit/item_giver [-2, 1, -3]' 'kit/key_door [2, 1, -5]' \
			'kit/region [-10, -1, -13]' 'kit/player_state [0, 1, 0]'; do
		edit "{\"op\": \"place\", \"type\": \"${p%% *}\", \"pos\": ${p#* }}"
	done
	# [KIT_SPAWNER_PLAYERS] The spawner places players (off by default)
	# and faces +x: who it puts there looks that way, level
	edit '{"op": "move", "ids": [3], "by": [0, 0, 0], "turn": 90}'
	for s in '3 players true' '7 interval 1' '7 repeats 3' '9 to [8, 1, -8]' '10 size [5, 2, 5]' \
			'12 target 2' '13 name "Ada"' '13 lines "Welcome!|Two came through."' \
			'15 take true' '16 size [13, 3, 15]' '16 dig "others"' '16 place "others"' '17 keep_position true'; do
		set -- $s
		v=${s#* * }
		edit "{\"op\": \"set\", \"id\": $1, \"comp\": 0, \"param\": \"$2\", \"value\": $v}"
	done
	for l in '4 pressed 5 toggle' '4 pressed 7 start' '7 tick 6 toggle' \
			'6 on 8 open' '6 off 8 close' '10 entered 11 add' \
			'10 entered 12 count' '12 reached 13 say'; do
		set -- $l
		edit "{\"op\": \"link\", \"id\": $1, \"comp\": 0, \"output\": \"$2\", \"to\": $3, \"input\": \"$4\"}"
	done
	# The objects drawn from the start's state, Stopped: shut, solid
	cat <<'EOF'
wait_log_any 10000 kit: entity 8 drawn 1x2x0.2 at 0,0.5,0, solid
wait_log_any 10000 kit: entity 5 drawn 3x3x0.3 at 1,1,0, solid
wait_log_any 10000 kit: entity 4 drawn 0.4x0.4x0.15 at 0,0,0
keydown shift
keypress Tab
keyup shift
wait_log 10000 kit editor: selected 3
click Button "Link spawned"
wait_log 10000 kit editor: linking from 3 spawned
keypress Escape
wait_log 10000 kit editor: link cancelled
wait_log_absent 500 pause: the menu shown
keypress Escape
wait_log 10000 pause: the menu shown
click Button "Run" 512 350
wait_log 10000 kit editor: the server is Running (by kitboss)
frames 5
screenshot @T@/edit.png
keypress Escape
wait_log 10000 pause: the menu shown
click Button "Play mode" 512 350
wait_log 10000 kit editor: edit mode off
event workbench_build {"p": [6, 0, 6], "voxel": "air"}
look_dir 1.5 -1.1 1.5
wait_log_any 5000 kit: points at use 4
frames 3
screenshot @T@/point_use.png
keypress e
wait_log_absent 500 kit: use 4
mouse_click left
wait_log 10000 kit: use 4
wait_log 10000 kit: entity 7 shows "3"
look_dir 0.4 -1 0
wait_log_any 5000 kit: points at dig 1,0,1, place 1,1,1
frames 3
screenshot @T@/point_dig.png
mouse_click left
wait_log 5000 kit: points at dig 2,0,1, place 1,0,1
mouse_click right
wait_log 5000 kit: points at dig 1,0,1, place 1,1,1
look_dir 1.5 -1.1 -3.5
wait_log_any 5000 kit: points at use 13
mouse_click left
wait_log 10000 kit: entity 13 shows "Ada: Welcome!"
event kit_use 14
wait_log 10000 kit: items: key x1
event kit_use 14
look_dir 1 -0.3 -1
frames 5
screenshot @T@/play.png
event kit_use 9
wait_log 10000 the server put the player at (8, 1.4, -8)
wait_log_any 10000 kit: the screen says "Score: kitboss 1 |
wait_log 60000 kit: the screen says "Score: kitbob 1, kitboss 1 |
wait_log_any 30000 kit: entity 13 shows "Ada: Two came through."
look_dir -1 -0.4 1
frames 5
screenshot @T@/scored.png
quit
EOF
} > "$t/boss.cmds"
cat > "$t/bob.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 the server put the player at (0, 1.4, -4) facing 90
wait_log_any 60000 player physics enabled
look_dir 1 -0.25 0
wait_log_any 5000 kit: points at nothing
frames 3
screenshot @T@/point_none.png
event workbench_build {"p": [6, 0, 6], "voxel": "air"}
look_dir 0 -1 -0.5
wait_log_any 5000 kit: points at dig 0,0,-5
mouse_click left
event kit_use 15
frames 2
event kit_use 14
wait_log 10000 kit: items: key x1
event kit_use 15
frames 2
event kit_use 9
wait_log 10000 the server put the player at (8, 1.4, -8)
look_dir 1 0 1
keydown W
delay 1200
keyup W
sync 5000
quit
EOF
server 1
wait_for_log "$t/srv1.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv1.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv1.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client boss &
boss=$!
wait_for_log "$t/boss.log" 'the screen says "Score: kitboss 1 [|]' 240 ||
	fail "the admin did not get as far as the zone ($t/boss.log)"
BUILDAT_JOIN_NAME=kitbob client bob
wait $boss || fail "the admin's client ($t/boss.log)"
stop
s=$t/srv1.log
grep -a " kit \| main " "$s" | grep -v "A . call" | sed 's/^.*\(kit\|main\) *: /  /' |
	grep -a "Entity\|teleport\|gives\|workbench: [a-z]\|joined\|refused" | cut -c1-140
want "$s" "A fresh save: Running" "kitboss is in edit mode" \
	"Stop by kitboss: 0 kept cells (edits, builds always kept) put back in, 0 builds discarded" \
	"An edit by kitboss: placed kit/spawner 3 at [0,1,-4]" \
	"An edit by kitboss: placed kit/item_giver 14 at [-2,1,-3]" \
	"An edit by kitboss: placed kit/player_state 17 on the app root" \
	"An edit by kitboss: set 9's kit/teleporter to to [8,1,-8]" \
	"An edit by kitboss: linked 12.reached -> 13.say" \
	"Play by kitboss: a round from the start" \
	"kitboss goes through the round's start: inventory reset"
# Play kept the admin where they were (keep position): no spawn
grep -a "spawner teleports kitboss\|kitboss to the app's default spawn" "$s" &&
	fail "Play moved the admin, with keep position on ($s)"
echo "ok: the admin builds the contraption in Kit's editor, Stopped, and plays it"
want "$s" "kit/button 4: pressed by kitboss times 1" \
	"kit/gate 5: opened by kitboss" \
	"kit/timer 7: started by kitboss" "kit/timer 7: tick 3" \
	"kit/timer 7: stopped: its repeats done after 3 ticks" \
	"kit/lever 6: flipped on by kitboss" "kit/lever 6: flipped off by kitboss" \
	"kit/door 8: opened by kitboss" "kit/door 8: shut by kitboss" \
	"workbench: kitboss placed kit/stone" \
	"kit/npc 13: says to kitboss \"Welcome!\"" \
	"kit/item_giver 14: gives kitboss 1 key" \
	"kit/item_giver 14: kitboss has had theirs" \
	"Entity 14's kit/item_giver: kitboss has {\"key\":1}" \
	"kit/teleporter 9: used by kitboss to 8 1 -8" \
	"Entity 9's kit/teleporter teleports kitboss to (8, 1, -8)" \
	"kit/trigger_zone 10: kitboss entered; 1 inside" \
	"kit/scoreboard 11: Score: kitboss 1" "kit/counter 12: count 1 by kitboss"
[ "$(grep -ac "kit/lever 6: flipped" "$s")" = 3 ] || fail "the lever did not flip three times ($s)"
[ "$(grep -ac "kit/gate 5: opened" "$s")" = 1 ] || fail "the gate opened other than once ($s)"
# The button an object now: the dig past it is the floor's, a build
grep -aq "workbench: kitboss dug .*: written" "$s" ||
	fail "the admin's dig past the button was not written ($s)"
# [KIT_BUILDER_PLAY_RULES] out of edit mode the admin plays by the rules:
# a dig outside the region refused
grep -aq "workbench: a build by kitboss refused: not in edit mode and not allowed at (6,0,6): Protected: no digging here" "$s" ||
	fail "the admin out of edit mode was let dig outside every region ($s)"
grep -aq "routed to its owner" "$s" && fail "a write was routed: the starter objects own no voxels ($s)"
echo "ok: the admin plays it: the button opens the gate and starts the timer, which flips the lever, which moves the door; the NPC, the item giver, the teleporter into the zone"
want "$s" "kitbob goes through the round's start: inventory reset" \
	"kit/spawner 3: spawns kitbob" \
	"Entity 3's kit/spawner teleports kitbob to (0, 1, -4) facing 90" \
	"workbench: a build by kitbob refused: not in edit mode and not allowed at (6,0,6): Protected: no " \
	"kit/region 16: holds dig others, place others, enter all, pvp all, damage all, use all" \
	"kit/key_door 15: locked to kitbob who has no key" \
	"kit/item_giver 14: gives kitbob 1 key" \
	"kit/key_door 15: opened by kitbob taking their key" \
	"Entity 15's kit/key_door: kitbob has {}" \
	"kit/trigger_zone 10: kitbob entered; 2 inside" \
	"kit/scoreboard 11: Score: kitbob 1, kitboss 1" \
	"kit/counter 12: count 2 by kitbob" "kit/counter 12: reached 2" \
	"kit/npc 13: says to kitbob \"Two came through.\"" \
	"kit/trigger_zone 10: kitbob left; "
[ "$(grep -ac "kit/trigger_zone 10: kitbob entered" "$s")" = 1 ] ||
	fail "kitbob entered the zone other than once ($s)"
[ "$(grep -ac "kit/trigger_zone 10: kitboss entered" "$s")" = 1 ] ||
	fail "kitboss entered the zone other than once ($s)"
grep -a "kitbob left; \|workbench: kitbob left" "$s" | head -1 | grep -q "zone" ||
	fail "kitbob did not walk out of the zone before leaving the server ($s)"
grep -aq "workbench: kitbob dug (0,0,-5): written" "$s" ||
	fail "kitbob did not dig in the dig zone ($s)"
# [KIT] 4d's answer: leaving the server left the zone (the admin quit in it)
awk '/workbench: kitboss left/ { q = 1 } q && /kit\/trigger_zone 10: kitboss left; / { f = 1 } END { exit !f }' "$s" ||
	fail "the admin's leaving the server did not leave the zone ($s)"
echo "ok: a second player is put on the spawner, may not build but digs in the dig zone, opens the key door with a key from the item giver, which it takes, is teleported into the zone (scored, counted, the NPC speaks) and walks out"

db="$save/save.sqlite"
for k in authored runtime; do
	sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = '$k'" > "$t/$k.json"
done
# The restart mid-round, Stop, Play and Save as start. From the spawner
# (0, 1, -4): down and back is the dig zone's (0, 0, -5), which kitbob dug
# (a click there meets no voxel: no dig); down and on is (0, 0, -3), down
# and right (1, 0, -4)
cat > "$t/again.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 the server put the player at (0, 1.4, -4) facing 90
wait_log_any 30000 kit: the screen says "Score: kitbob 1, kitboss 1 | Items: key x1"
wait_log_any 60000 player physics enabled
look_dir 0.6 -0.25 1
frames 10
screenshot @T@/again.png
keypress F6
wait_log 10000 kit editor: state: 16 entities, 0 to undo
event kit_edit {"op": "set", "id": 17, "comp": 0, "param": "keep_inventory", "value": true}
wait_log 10000 kit editor: state: 16 entities, 1 to undo
event kit_edit {"op": "set", "id": 17, "comp": 0, "param": "keep_position", "value": false}
wait_log 10000 kit editor: state: 16 entities, 2 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0 -1 -0.5
mouse_click left
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
wait_log_any 10000 kit: items: none
wait_log_any 10000 kit: builds discarded: Builds while playing were discarded (kitbob 1, you
frames 5
look_dir 0.6 -0.25 1
frames 10
screenshot @T@/stopped.png
# Ended: the admin digs the start by an edit in edit mode
# ([KIT_BUILDER_PLAY_RULES]: out of it, the play rules: no build)
keypress F6
wait_log 10000 kit editor: state: 16 entities, 2 to undo
event kit_edit {"op": "set_voxel", "pos": [0, 0, -5], "voxel": "air"}
wait_log 10000 kit editor: state: 16 entities, 3 to undo
event kit_edit {"op": "keep", "names": ["kitbob"]}
frames 5
delay 1500
event kit_edit {"op": "keep", "names": ["kitboss"]}
frames 5
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
keypress F6
wait_log 10000 kit editor: edit mode off
frames 10
look_dir 0 -1 0.5
mouse_click left
frames 3
keypress F6
wait_log 10000 kit editor: state: 16 entities, 3 to undo
event kit_edit {"op": "save_start"}
wait_log 10000 kit editor: state: 16 entities, 3 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0.5 -1 0
mouse_click left
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
frames 5
keypress F6
wait_log 10000 kit editor: state: 16 entities, 3 to undo
event kit_edit {"op": "set_voxel", "pos": [1, 0, -4], "voxel": "air"}
wait_log 10000 kit editor: state: 16 entities, 4 to undo
event kit_edit {"op": "set_voxel", "pos": [0, -1, -3], "voxel": "air"}
wait_log 10000 kit editor: state: 16 entities, 5 to undo
event kit_edit {"op": "set", "id": 17, "comp": 0, "param": "keep_inventory", "value": false}
wait_log 10000 kit editor: state: 16 entities, 6 to undo
keypress F6
wait_log 10000 kit editor: the server is Running (by kitboss)
wait_log 10000 kit editor: edit mode off
keypress F6
wait_log 10000 kit editor: state: 16 entities, 6 to undo
frames 10
event kit_edit {"op": "place", "type": "kit/teleporter", "pos": [2, 1, -2]}
wait_log 10000 kit editor: state: 17 entities, 7 to undo
event kit_edit {"op": "set", "id": 18, "comp": 0, "param": "to", "value": [-10, 1, -1]}
wait_log 10000 kit editor: state: 17 entities, 8 to undo
event kit_edit {"op": "place", "type": "kit/door", "pos": [-10, 1, -4]}
wait_log 10000 kit editor: state: 18 entities, 9 to undo
event kit_edit {"op": "place", "type": "kit/trigger_zone", "pos": [-11, 1, -12]}
wait_log 10000 kit editor: state: 19 entities, 10 to undo
event kit_edit {"op": "set", "id": 20, "comp": 0, "param": "size", "value": [3, 2, 6]}
wait_log 10000 kit editor: state: 19 entities, 11 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
wait_log_any 10000 kit: entity 19 drawn 1x2x0.2 at 0,0.5,0, solid
event kit_use 18
wait_log 10000 the server put the player at (-10, 1.4, -1)
frames 20
look_dir 0 0 -1
keydown W
delay 1500
keyup W
frames 20
event kit_use 19
wait_log 10000 kit: entity 19 drawn 0.2x2x1 at -0.4,0.5,0.4
# On into the zone, short of region 16's far edge (z -13), where the
# dig below is let through by the play rules: a 1.5 s walk went past it
# now and then ([KIT_BUILDER_PLAY_RULES])
look_dir 0 0 -1
keydown W
delay 1200
keyup W
frames 20
sync 5000
keypress F6
wait_log 10000 kit editor: state: 19 entities, 11 to undo
event kit_edit {"op": "always_keep", "on": true}
wait_log 10000 kit editor: state: 19 entities, 12 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0 -1 -0.6
mouse_click left
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
wait_log_absent 1500 kit: builds discarded
event kit_edit {"op": "keep"}
wait_log 10000 kit editor: refused: keep: no builds discarded since the last Run
keypress F6
wait_log 10000 kit editor: state: 19 entities
event kit_edit {"op": "link", "id": 4, "comp": 0, "output": "pressed", "to": 12, "input": "add"}
wait_log 10000 kit editor: refused: link: pressed sends a none, add takes a number
event kit_edit {"op": "place", "prefab": "kit/button_door", "pos": [1, 1, -2]}
wait_log 10000 kit editor: state: 21 entities
event kit_edit {"op": "set", "id": 21, "comp": 0, "param": "close_after", "value": 7}
wait_log 10000 kit editor: state: 21 entities
event kit_edit {"op": "save_prefab", "ids": [21, 22], "name": "door2"}
wait_log 10000 kit editor: state: 21 entities
event kit_edit {"op": "place", "prefab": "kitboss/door2", "pos": [5, 1, 3]}
wait_log 10000 kit editor: state: 23 entities
event kit_edit {"op": "set", "id": 23, "comp": 0, "param": "close_after", "value": 4}
wait_log 10000 kit editor: state: 23 entities
event kit_edit {"op": "set", "id": 21, "comp": 0, "param": "close_after", "value": 9}
wait_log 10000 kit editor: state: 23 entities
event kit_edit {"op": "set", "id": 21, "comp": 0, "param": "hold", "value": 2}
wait_log 10000 kit editor: refused: set: kit/door has no parameter "hold"
event kit_edit {"op": "set", "id": 22, "comp": 0, "param": "hold", "value": 2}
wait_log 10000 kit editor: state: 23 entities
event kit_edit {"op": "save_prefab", "ids": [21, 22], "name": "door2"}
wait_log 10000 kit editor: state: 23 entities
event kit_edit {"op": "place", "type": "kit/button", "pos": [-1, 1, -3]}
wait_log 10000 kit editor: state: 24 entities
event kit_edit {"op": "set", "id": 25, "comp": 0, "param": "hold", "value": 0.1}
wait_log 10000 kit editor: state: 24 entities
event kit_edit {"op": "link", "id": 25, "comp": 0, "output": "pressed", "to": 3, "input": "spawn"}
wait_log 10000 kit editor: state: 24 entities
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "prefab", "value": "kitboss/door2"}
wait_log 10000 kit editor: state: 24 entities
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "max", "value": 1}
wait_log 10000 kit editor: state: 24 entities
event kit_edit {"op": "place", "type": "kit/part", "pos": [-2, 1, -6]}
wait_log 10000 kit editor: state: 25 entities
event kit_edit {"op": "set", "id": 26, "comp": 0, "param": "shape", "value": "wedge"}
wait_log 10000 kit editor: state: 25 entities
event kit_edit {"op": "set", "id": 26, "comp": 0, "param": "size", "value": [2, 1, 1.5]}
wait_log_any 10000 kit: entity 26 drawn 2x1x1.5 at 0,0,0, solid, a wedge
event kit_edit {"op": "play"}
wait_log 10000 kit editor: the server is Running (by kitboss)
wait_log_any 10000 the server put the player at (0, 1.4, -4)
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir -1.5 -0.6 -1.5
frames 10
screenshot @T@/wedge.png
keypress F6
wait_log 10000 kit editor: state:
event kit_edit {"op": "focus", "sel": 3}
event kit_use 25
wait_log 10000 kit editor: signal 25.pressed -> 3.spawn
wait_log_any 10000 kit: entity 28 drawn
wait_log_any 10000 kit editor: log of 3:
delay 400
event kit_use 25
wait_log 10000 kit editor: log of 3:
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "max", "value": 2}
wait_log 10000 kit editor: log of 3:
event kit_edit {"op": "restart", "id": 3, "comp": 0}
wait_log 10000 kit editor: log of 3:
event kit_use 21
wait_log 10000 kit: entity 21's client part: swung to -90
# [KIT_DOOR_MIRROR] Mirrored while open, live: drawn at its back, the
# client part swinging it the other way
event kit_edit {"op": "set", "id": 21, "comp": 0, "param": "mirror", "value": true}
wait_log 10000 kit: entity 21 drawn 0.2x2x1 at -0.4,0.5,-0.4
wait_log 10000 kit: entity 21's client part: swung to 90
# [KIT_LOOK_MATERIAL] In Kit's planks
event kit_edit {"op": "set", "id": 21, "comp": 0, "param": "material", "value": "kit/planks"}
wait_log 10000 kit: entity 21 wears kit/planks
sync 5000
event kit_use 25
wait_log_any 10000 kit: entity 30 drawn
event kit_edit {"op": "stop"}
wait_log 10000 kit editor: the server is Ended (by kitboss)
sync 5000
quit
EOF
server 2
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CREATE= client again
stop
s2=$t/srv2.log
grep -a " kit \| main " "$s2" | grep -v "A . call" | sed 's/^.*\(kit\|main\) *: /  /' |
	grep -a "Stop by\|Play by\|Saved\|round's start\|dug\|sections\|spawner\|Running" | cut -c1-140
want "$s2" "Hosted: 17 entities, 15 instances" \
	"The server is Running (by kitboss): " \
	"Entity 3's kit/spawner teleports kitboss to (0, 1, -4) facing 90" \
	"sections put back (0 wait for their load), each instance at its start, inventories put aside" \
	"A voxel edit by kitboss: dug at (0,0,-5)" \
	"kitboss goes through the round's start: inventory kept" \
	"Saved as the start by kitboss" \
	"workbench: kitboss dug (0,0,-3): written" \
	"kitboss goes through the round's start: inventory reset"
grep -aq "the composition's first start" "$s2" && fail "the composition was read again ($s2)"
# The dig at (0, 0, -5) before the Stop met nothing (kitbob's dig, in the
# round restored over the restart); after it, the cell put back, an edit's
# dig ([KIT_BUILDER_PLAY_RULES]: Ended, a builder digs by edits only).
# (1, 0, -4), dug after Save as start, was put back by the Stop: dug in
# play, then by an edit; (0, 0, -3), dug before it, stayed dug: once
[ "$(grep -ac "kitboss dug (0,0,-5)" "$s2")" = 0 ] ||
	fail "the click at (0,0,-5) before the Stop dug ($s2)"
want "$s2" "A voxel edit by kitboss: dug at (1,0,-4)" "A voxel edit by kitboss: dug at (0,-1,-3)"
[ "$(grep -ac "kitboss dug (1,0,-4)" "$s2")" = 1 ] ||
	fail "the cell dug after Save as start was not put back by the Stop ($s2)"
[ "$(grep -ac "kitboss dug (0,0,-3)" "$s2")" = 1 ] ||
	fail "the cell dug before Save as start did not stay dug ($s2)"
# Play after the Stop: the spawner placed the admin (keep position off)
awk '/Play by kitboss/ { p = 1 } p && /spawner teleports kitboss/ { f = 1 } END { exit !f }' "$s2" ||
	fail "the spawner did not place the admin at Play ($s2)"
want "$s2" "sections copied out"
# The origins over the restart: the first Stop discarded kitbob's dig in
# the dig zone and the admin's builds of round one (the restart kept their
# marks), told the admin; kitbob's chosen, the admin's kept a moment
# later; at the second Stop the dig after Save as start discarded, then
# gone with the next Play
want "$s2" "builds discarded: kitbob 1, kitboss " \
	"kitboss keeps the builds of kitbob 1: 1 cells put into the start" \
	"kitboss keeps the builds of kitboss " \
	"1 builds discarded: kitboss 1" "The builds of kitboss 1 discarded for good" \
	"An edit (keep) by peer"
want "$t/again.log" "kit: builds discarded: Your builds while playing were discarded."
# The door placed in the round: shut, it stopped the admin's walk short of
# the zone behind it; open, the walk went through into the zone
awk '/kit\/door 19: opened by kitboss/ { o = NR } /kit\/trigger_zone 20: kitboss entered/ { if(!o) bad = 1; e = NR } END { exit !(o && e > o && !bad) }' "$s2" ||
	fail "the shut door did not stop the walk, or the open one did not let it through ($s2)"
grep -a "kit: entity 19 drawn\|the server put the player at (-10" "$t/again.log" | sed 's/^.*: kit/  kit/' | cut -c1-120
# Always keep builds: the admin's dig kept at Stop, no notice
want "$s2" "Stop by kitboss: 1 kept cells (edits, builds always kept) put back in, 0 builds discarded"
# What the admin's client was told of their items as the state changed:
# none at each Stop, the key kept at the next Play, none at the last
python3 -I - "$t/again.log" <<'EOF' || fail "the items over Stop and Play ($t/again.log)"
import re, sys
seen = []
for l in open(sys.argv[1], errors="replace"):
	m = re.search(r"kit editor: the server is (\w+)|kit: items: (.*)", l)
	if m:
		seen.append(m.group(1) or "items " + m.group(2).strip())
at = seen.index("Ended")
seen = seen[at:]
print("  from the first Stop:", seen)
want = ["Ended", "items none", "Running", "items key x1", "Ended",
	"items none", "Running", "items none"]
it = iter(seen)
assert all(w in it for w in want), seen
EOF
# 6. ([KIT] stage 4d) A typed link refused; prefabs placed, saved, and a
# copy following the next version (but for what was set on it); the
# spawner's copies by a button's signal (its line lit, its log in the
# editor), at most max, taken back by "Restart this" (on_remove) after
# a live edit (on_params), gone at Stop; a wedge part; the door's client
# part swinging it on use, the other way mirrored
want "$s2" "placed prefab kit/button_door as 21...22" \
	"saved prefab kitboss/door2 version 1 of 2 entities (0 entities of other copies follow it)" \
	"placed prefab kitboss/door2 as 23...24" \
	"saved prefab kitboss/door2 version 2 of 2 entities (2 entities of other copies follow it)" \
	"kit/spawner 3: made 27 for kitboss" "kit/spawner 3: has 1 copies: no more" \
	"kit/spawner 3: parameters changed: max" "kit/spawner 3: took away 1 copies" \
	"kit/spawner 3: made 29 for kitboss" "The round's entities: 2 made gone, 0 removed back"
want "$t/boss.log" "client part: your score 1" \
	"kit: entity 13's client part: dialog: Ada: Welcome!"
want "$t/again.log" "kit editor: signal 25.pressed -> 3.spawn" \
	"kit editor: log of 3: " "kit: entity 21's client part: swung to -90" \
	"kit: entity 21 drawn 0.2x2x1 at -0.4,0.5,-0.4" \
	"kit: entity 21's client part: swung to 90" \
	"kit: entity 21 wears kit/planks"
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'authored'" > "$t/authored2.json"
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'runtime'" > "$t/runtime2.json"
sqlite3 "$db" "SELECT value FROM store WHERE store = 'kit' AND key = 'prefab:kitboss/door2'" > "$t/prefab2.json"
python3 -I - "$t/authored2.json" "$t/runtime2.json" "$t/prefab2.json" <<'EOF' || fail "the rows of stage 4d ($t)"
import json, sys
a, r, pf = (json.loads(open(f).read()) for f in sys.argv[1:4])
e = {x["id"]: x for x in a["entities"]}
p = lambda i: e[i]["components"][0]["params"]
assert pf["author"] == "kitboss" and pf["name"] == "door2" and pf["version"] == 2, pf
assert [m["components"][0]["type"] for m in pf["entities"]] == ["kit/door", "kit/button"], pf
assert e[23]["prefab"]["of"] == "kitboss/door2" and e[23]["prefab"]["version"] == 2, e[23]
assert p(21)["close_after"] == 9 and p(23)["close_after"] == 4, (p(21), p(23))
assert p(24)["hold"] == 2, p(24)
assert e[24]["components"][0]["links"] == [{"output": "pressed", "to": 23, "input": "open"}], e[24]
assert p(26)["shape"] == "wedge" and p(26)["size"] == [2, 1, 1.5], p(26)
assert not any(i in e for i in (27, 28, 29, 30)), sorted(e)
assert not r.get("made"), r.get("made")
print("  rows: the prefab's version 2, its copies, the part; nothing made left after Stop")
EOF
echo "ok: a typed link refused, prefabs placed and saved (a copy follows), the spawner's copies by a signal, Restart this, a wedge part, the door's client part"
echo "ok: a restart mid-round, then Stop puts back what the round dug before it; inventory put aside and given back at Play, reset without keep; the spawner places at Play; Save as start keeps what was dug before it"
python3 -I - "$t/authored.json" "$t/runtime.json" <<'EOF' || fail "the rows ($t)"
import json, sys
a = json.loads(open(sys.argv[1]).read())
r = json.loads(open(sys.argv[2]).read())
e = {x["id"]: x for x in a["entities"]}
assert [x["components"][0]["type"] for x in a["entities"] if x["id"] > 2] == [
	"kit/" + t for t in ["spawner", "button", "gate", "lever", "timer", "door", "teleporter",
	"trigger_zone", "scoreboard", "counter", "npc", "item_giver", "key_door",
	"region", "player_state"]], a
assert e[17]["parent"] == 1 and "pos" not in e[17], e[17]
assert e[9]["components"][0]["params"]["to"] == [8, 1, -8], e[9]
assert len([l for x in a["entities"] for c in x["components"] for l in c["links"]]) == 8
st = lambda i: r[str(i)][0]["state"]
assert st(11)["text"] == "Score: kitbob 1, kitboss 1", st(11)
assert st(6)["on"] is True and st(8)["open"] is True, (st(6), st(8))
assert st(5)["open"] is True and st(12)["count"] == 2, (st(5), st(12))
assert st(7)["ticks"] == 3 and st(7)["running"] is False, st(7)
# [KIT] stage 4d: the items and the scores on the players' entities, and
# the zone's members saved: none (kitboss left the server in it, which
# leaves it; kitbob walked out). No guest's entity kept (p1...: dropped
# as they logged in)
pid = lambda n: r["players"][n]["id"]
assert not [n for n in r["players"] if n[:1] == "p" and n[1:].isdigit()], r["players"]
pl = lambda n: {k: v for c in r[str(pid(n))] for k, v in c["state"].items()}
assert pl("kitboss")["items"] == {"key": 1}, pl("kitboss")
assert not pl("kitbob")["items"], pl("kitbob")  # an empty table: [] or {}
assert pl("kitboss")["score"] == 1 and pl("kitbob")["score"] == 1, (pl("kitboss"), pl("kitbob"))
assert pid("kitboss") >= 1000000, r["players"]
assert not r["10"][0].get("inside"), r["10"]
assert st(15)["open"] is True and st(16)["rules"]["dig"] == "others", (st(15), st(16))
print("  rows: 15 instances, 8 links, the scores, the lever on, the doors and the gate open, the key")
EOF
# 7. ([KIT] stage 4e2) Kit's editor as floorplanner's, on fresh saves at
# 1024x700. With the mouse: the plan (F1), kit/button dragged onto it
# from the palette (its second tile, after kit/action) (its ghost), a
# click selects, a drag moves it by whole cells, the knob
# turns it by the angle step, an armed palette item placed by a click
# (Escape: no longer), a link dragged from an out port onto an in port, a
# box selects two, a right click's menu duplicates them; ([KIT_PLAYTEST_TWEAKS])
# Tab in the order last accessed: Shift+Tab after the duplicate the oldest
# (the door: the button was clicked and linked after it), Tab round to the
# copies, a nudge of one (undone) puts it at the top; 3D (F2), where
# a right drag orbits and opens no menu, and walking (F3), where a click
# goes into the crosshair and Escape comes out of it before the menu;
# the inspector's x typed in and Move, a kit/world placed (game-wide), selected
# from the list and deleted by the inspector's Delete, and the undo.
# ([KIT_EDIT_VOXELS]) The voxels tool (V): a voxel placed by a click at the
# pointer in 3D, and walking at the crosshair as in play
# ([KIT_PLAYTEST_TWEAKS]) one placed (right), dug (left) and the dig undone
# (Ctrl+Z), each one undo; Escape out of the crosshair, then the tool away.
# ([KIT_SELECT_BURIED]) A dig zone under the ground: the hover and a click
# in the plan go through the ground to it; the list's Positioned tab has
# it, its Select selects it; a link ("Link pressed") to it
# by a click through the ground.
# By finger (BUILDAT_TOUCH=1, finger_*): in play a tap digs, a finger
# held places, a tap uses the button; in the plan the palette (folded on
# a narrow screen) dragged from, a tap selects, a drag moves, a drag from
# the out port links (onto the door: its inputs shown, onto toggle), a
# finger held is the menu, two fingers pinch the plan
cat > "$t/ed.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 30000 world_menu: the list shown, 0 worlds
frames 3
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities
keypress F1
wait_log 5000 kit editor: the view is 2D
frames 3
mouse_pos 195 71
mouse_down left
frames 2
mouse_pos 300 200
frames 2
mouse_pos 556 306
frames 3
screenshot @T@/palette_drag.png
mouse_up left
wait_log_any 10000 kit editor: state: 2 entities
wait_log_any 5000 kit: entity 3 drawn
frames 5
mouse_pos 556 306
frames 3
mouse_click left
wait_log 5000 kit editor: selected 3
frames 5
screenshot @T@/selected.png
mouse_down left
frames 2
mouse_pos 580 306
frames 2
mouse_pos 614 306
frames 2
screenshot @T@/dragging.png
mouse_up left
wait_log_any 10000 kit editor: state: 2 entities, 2 to undo
frames 5
screenshot @T@/moved.png
mouse_pos 614 271
frames 3
mouse_down left
frames 2
mouse_pos 630 290
frames 2
mouse_pos 660 306
frames 2
screenshot @T@/turning.png
mouse_up left
wait_log_any 10000 kit editor: state: 2 entities, 3 to undo
frames 20
screenshot @T@/turned.png
click Button "kit/door"
wait_log 5000 kit editor: placing kit/door
mouse_pos 439 306
frames 3
screenshot @T@/placing.png
mouse_click left
wait_log_any 10000 kit editor: state: 3 entities
keypress Escape
wait_log 5000 kit editor: placing nothing
frames 3
mouse_pos 614 306
mouse_click left
wait_log 5000 kit editor: selected 3
frames 3
screenshot @T@/ports.png
mouse_pos 663 297
frames 2
mouse_down left
frames 2
mouse_pos 600 300
frames 2
mouse_pos 520 306
frames 2
mouse_pos 439 306
wait_log 5000 kit editor: in ports of 4
frames 3
mouse_pos 394 322
frames 3
screenshot @T@/linking.png
mouse_up left
frames 3
wait_log_any 5000 kit editor: state: 3 entities, 5 to undo
frames 3
screenshot @T@/linked.png
mouse_pos 380 380
mouse_down left
frames 2
mouse_pos 500 330
frames 2
mouse_pos 700 250
frames 2
screenshot @T@/boxing.png
mouse_up left
wait_log 5000 kit editor: a box selected 2
frames 3
screenshot @T@/boxed.png
mouse_pos 439 306
mouse_click right
wait_log 5000 kit editor: the menu of 4
frames 3
screenshot @T@/menu.png
click Button "Duplicate"
wait_log_any 5000 kit editor: state: 5 entities
frames 3
screenshot @T@/duplicated.png
keydown shift
keypress Tab
keyup shift
wait_log 5000 kit editor: selected 4
keypress Tab
wait_log 5000 kit editor: selected 6
keypress Tab
wait_log 5000 kit editor: selected 5
keypress Right
wait_log 5000 kit editor: state: 5 entities, 7 to undo
keydown ctrl
keypress z
keyup ctrl
wait_log 5000 kit editor: state: 5 entities, 6 to undo
keypress Tab
wait_log 5000 kit editor: selected 6
keydown shift
keypress Tab
wait_log 5000 kit editor: selected 5
keypress Tab
keyup shift
wait_log 5000 kit editor: selected 4
keypress F2
wait_log 5000 kit editor: the view is 3D
mouse_pos 600 400
frames 5
screenshot @T@/view_3d.png
mouse_down right
frames 2
mouse_pos 650 400
frames 2
mouse_pos 700 400
frames 2
mouse_up right
wait_log_absent 300 kit editor: the menu of
mouse_down middle
frames 2
mouse_pos 650 450
frames 2
mouse_pos 700 500
frames 2
mouse_up middle
wait_log 5000 kit editor: panned in 3D from
keypress F3
wait_log 5000 kit editor: the view is Walk
frames 5
screenshot @T@/view_walk.png
mouse_click left
wait_log 5000 kit editor: into the crosshair
frames 5
screenshot @T@/view_crosshair.png
keypress Escape
wait_log 5000 kit editor: out of the crosshair
wait_log_absent 300 pause: the menu shown
keypress F1
wait_log 5000 kit editor: the view is 2D
mouse_pos 614 306
mouse_click left
wait_log 5000 kit editor: selected 3
frames 3
click LineEdit "4"
keypress End
keypress Backspace
text 6
frames 2
screenshot @T@/inspector_pos.png
click Button "Move"
wait_log 5000 kit editor: moved 1 by 2, 0, 0 from the inspector
wait_log_any 5000 kit editor: state: 5 entities, 7 to undo
click Button "kit/world"
wait_log 5000 kit editor: placing kit/world
mouse_pos 300 450
mouse_click left
wait_log_any 5000 kit editor: state: 6 entities, 8 to undo
frames 3
click Button "Scene (*"
wait_log 5000 kit editor: list Scene
click Button "Select*"
wait_log 5000 (kit/world
frames 3
screenshot @T@/inspector_world.png
click Button "Delete"
wait_log_any 5000 kit editor: state: 5 entities, 9 to undo
click Button "Undo"
wait_log_any 5000 kit editor: state: 6 entities, 8 to undo
keypress V
wait_log 5000 kit editor: tool voxels
keypress F2
wait_log 5000 kit editor: the view is 3D
mouse_pos 512 560
wait_log 5000 kit editor: guide: Left: place kit/cobble at
frames 3
screenshot @T@/voxel_3d.png
mouse_click left
wait_log 5000 kit editor: state: 6 entities, 9 to undo
keypress F3
wait_log 5000 kit editor: the view is Walk
mouse_click left
wait_log 5000 kit editor: into the crosshair
look_dir 0 -1 0.6
frames 5
wait_log_any 5000 kit editor: guide: Left: dig
mouse_click right
wait_log 5000 kit editor: state: 6 entities, 10 to undo
frames 3
screenshot @T@/voxel_dig.png
mouse_click left
wait_log 5000 kit editor: state: 6 entities, 11 to undo
keydown ctrl
keypress z
keyup ctrl
wait_log 5000 kit editor: state: 6 entities, 10 to undo
keypress Escape
wait_log 5000 kit editor: out of the crosshair
keypress Escape
wait_log 5000 kit editor: tool select
keypress F1
wait_log 5000 kit editor: the view is 2D
event kit_edit {"op": "place", "type": "kit/region", "pos": [2, -1, -2]}
wait_log 10000 kit editor: state: 7 entities, 11 to undo
mouse_pos 556 422
wait_log 5000 kit editor: guide: Left: select kit/region
frames 3
screenshot @T@/buried_hover.png
mouse_click left
wait_log 5000 kit editor: selected 8 (kit/region 8)
mouse_pos 700 520
mouse_click left
wait_log 5000 kit editor: selected none
click Button "Positioned (*"
wait_log 5000 kit editor: list Positioned
frames 3
screenshot @T@/list_all.png
mouse_pos 150 600
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 2
mouse_wheel -1
frames 3
screenshot @T@/list_scrolled.png
click Button "select 8"
wait_log 5000 kit editor: selected 8 (kit/region 8)
mouse_pos 672 306
mouse_click left
wait_log 5000 kit editor: selected 3
click Button "Link pressed"
wait_log 5000 kit editor: linking from 3 pressed
mouse_pos 556 422
mouse_click left
wait_log 5000 kit editor: selected 8
frames 3
screenshot @T@/buried_link.png
click Button "To enable"
wait_log 5000 kit editor: state: 7 entities, 12 to undo
quit
EOF
cat > "$t/touch.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 30000 world_menu: the list shown, 0 worlds
frames 3
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities
event kit_edit {"op": "place", "type": "kit/button", "pos": [1, 1, 3]}
wait_log_any 10000 kit: entity 3 drawn
# [KIT_BUILDER_PLAY_RULES] a region round the tap's cells: digging and
# placing for all (the admin plays by the rules out of edit mode)
event kit_edit {"op": "place", "type": "kit/region", "pos": [0, -1, 0]}
wait_log 10000 kit editor: state: 3 entities
event kit_edit {"op": "set", "id": 4, "comp": 0, "param": "dig", "value": "all"}
event kit_edit {"op": "set", "id": 4, "comp": 0, "param": "place", "value": "all"}
wait_log 10000 kit editor: state: 3 entities, 3 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
frames 5
finger_down 1 700 615
wait_log 5000 kit: points at dig 2,0,3, place 2,1,3
frames 3
screenshot @T@/t_dig.png
finger_up 1
wait_log 5000 kit: points at nothing
finger_down 1 700 615
wait_log 5000 kit: points at dig 2,0,4, place 2,0,3
wait_log 3000 kit: points at dig 2,0,3, place 2,1,3
finger_up 1
wait_log 5000 kit: points at nothing
finger_down 1 605 545
wait_log 5000 kit: points at use 3
frames 3
screenshot @T@/t_use.png
finger_up 1
wait_log 5000 kit: use 3
tap Button "Menu"
wait_log 5000 pause: the menu shown
frames 3
click Button "Edit"
wait_log 10000 kit editor: state: 3 entities
event kit_edit {"op": "place", "type": "kit/door", "pos": [9, 1, 5]}
wait_log 10000 kit editor: state: 4 entities
keypress F1
wait_log 5000 kit editor: the view is 2D
frames 3
tap Button "Palette"
frames 5
finger_down 1 Button "kit/button"
frames 2
finger_move 1 300 250
frames 2
finger_move 1 600 300
frames 2
finger_move 1 700 300
frames 3
screenshot @T@/t_ghost.png
finger_up 1
wait_log 10000 kit editor: state: 5 entities
wait_log_any 5000 kit: entity 6 drawn
tap Button "Palette"
frames 5
tap 700 300
wait_log 5000 kit editor: selected 6
frames 3
finger_down 1 700 300
frames 2
finger_move 1 730 300
frames 2
finger_move 1 790 300
frames 3
screenshot @T@/t_moving.png
finger_up 1
wait_log 10000 kit editor: moved 1 by 3, 0
frames 5
screenshot @T@/t_ports.png
finger_down 1 903 285
frames 2
finger_move 1 850 260
frames 2
finger_move 1 760 222
wait_log 5000 kit editor: in ports of 5
frames 3
finger_move 1 700 240
frames 2
finger_move 1 656 256
frames 3
screenshot @T@/t_linking.png
finger_up 1
wait_log 5000 kit editor: link dropped on 5 toggle
wait_log_any 10000 kit editor: state: 5 entities, 8 to undo
finger_down 1 790 305
wait_log 3000 kit editor: the menu of 6
finger_up 1
frames 3
screenshot @T@/t_menu.png
click Button "Duplicate"
wait_log 5000 kit editor: state: 6 entities
finger_down 1 600 400
finger_down 2 800 400
frames 2
finger_move 1 550 400
finger_move 2 850 400
frames 2
finger_move 1 500 400
finger_move 2 900 400
frames 2
finger_up 1
finger_up 2
wait_log 5000 kit editor: two fingers let go: the plan 12.0 across
frames 3
screenshot @T@/t_pinched.png
quit
EOF
for r in ed touch; do
	n=$([ $r = ed ] && echo 3 || echo 4)
	server $n "$t/user$n"
	wait_for_log "$t/srv$n.log" "setup code [A-Z0-9]+" 30
	code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv$n.log" | head -1)
	[ -n "$code" ] || fail "no setup code ($t/srv$n.log)"
	if [ $r = touch ]; then export BUILDAT_TOUCH=1; fi
	BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
		BUILDAT_JOIN_ADMIN="setting open_registration on" client $r
	unset BUILDAT_TOUCH
	stop
done
want "$t/srv3.log" "An edit by kitboss: placed kit/button 3 at [2,1,2]" \
	"An edit by kitboss: moved 3 to [4,1,2]" \
	"An edit by kitboss: placed kit/door 4 at [-2,1,2]" \
	"An edit by kitboss: linked 3.pressed -> 4.toggle" \
	"An edit by kitboss: moved 3 to [6,1,2]" \
	"An edit by kitboss: placed kit/world 7 on the scene world" \
	"An edit by kitboss: deleted 7" \
	"An undo by kitboss: 1 entities put back" \
	"An edit by kitboss: placed kit/region 8 at [2,-1,-2]" \
	"An edit by kitboss: linked 3.pressed -> 8.enable"
want "$t/ed.log" "kit editor: turned 1 by 90" "kit editor: a box selected 2, 2 in the selection"
# The 3D middle drag pans over the ground (user's playtest, 2026-10-31):
# the camera's height kept, its x and z moved
pan=$(grep -aoP 'kit editor: panned in 3D from \K.*' "$t/ed.log" | head -1)
echo "$pan" | awk -F'[ ,]' '{d=($1-$5)^2+($3-$7)^2; exit !($2 == $6 && d > 0.01)}' ||
	fail "the 3D pan is not over the ground: $pan ($t/ed.log)"
# The voxels: the walk's place dug again, and the dig undone
placed=$(grep -aoP 'A voxel edit by kitboss: placed kit/cobble at \K\([-0-9,]+\)' "$t/srv3.log")
[ "$(echo "$placed" | wc -l)" = 2 ] || fail "not two voxels placed ($t/srv3.log)"
want "$t/srv3.log" "A voxel edit by kitboss: dug at $(echo "$placed" | tail -1) (11 to undo)" \
	"An undo by kitboss: a voxel edit, 1 cells"
want "$t/srv4.log" "kit/button 3: pressed by kitboss" \
	"An edit by kitboss: linked 6.pressed -> 5.toggle"
grep -aq "workbench: kitboss dug (2,0,3): written" "$t/srv4.log" ||
	fail "the tap did not dig ($t/srv4.log)"
grep -aq "workbench: kitboss placed kit/stone (2,0,3): written" "$t/srv4.log" ||
	fail "the finger held did not place ($t/srv4.log)"
echo "ok: Kit's editor by mouse (the plan: a palette drag, select, a snapped move, a turn, an armed place, a link dragged, a box, the menu; 3D and walking; voxels placed, dug and undone; an entity under the ground selected through it, from the list, and linked to through it) and by finger (tap, hold, drags, a link, the menu, a pinch)"
# 8. ([KIT] stage 4g) A builder's voxel type: with kitbob joined, the
# admin uploads a PNG from their exports (the client's file picker) in
# Kit's editor's "New voxel type...", names the type frost, sets its
# friction, makes it, takes it in hand from the Voxel list and places it in
# play; kitbob's client reads the registry again and draws it. A restart:
# the type registered before the save's sections load (not adopted).
cat > "$t/maker.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 30000 server window: the page ntfy
frames 3
click Button "Don't add"
wait_log_any 30000 world_menu: the list shown, 0 worlds
frames 3
click Button "New project..."
wait_log 5000 world_menu: the name screen shown
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state: 1 entities
wait_log_any 120000 kit editor: people: kitbob
frames 3
click Button "New voxel type..."
frames 3
click Button "Upload a PNG..."
wait_log 10000 The file picker at
frames 3
click Button "frost.png"
wait_log 10000 kit editor: uploaded kit/up/
frames 3
click LineEdit "my_voxel"
keypress End
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
keypress Backspace
text frost
frames 2
click LineEdit "1"
keypress End
keypress Backspace
text 0.2
frames 3
screenshot @T@/voxel_dialog.png
click Button "Make"
wait_log 10000 voxels to place
frames 3
click DropDownList "▼" 51 226
frames 3
click Text "kitboss/frost"
wait_log 5000 kit editor: in hand kitboss/frost
frames 3
screenshot @T@/voxel_palette.png
# [KIT_BUILDER_PLAY_RULES] a region: placing for all round the spawn
event kit_edit {"op": "place", "type": "kit/region", "pos": [-2, -1, -2]}
wait_log 10000 kit editor: state: 2 entities
event kit_edit {"op": "set", "id": 3, "comp": 0, "param": "place", "value": "all"}
wait_log 10000 kit editor: state: 2 entities, 2 to undo
keypress F6
wait_log 10000 kit editor: edit mode off
look_dir 0 -1 0.6
wait_log_any 5000 kit: points at place
mouse_click right
sync 5000
frames 10
screenshot @T@/voxel_placed.png
quit
EOF
cat > "$t/watcher.cmds" <<'EOF'
wait_log_any 60000 Joined as kitbob
wait_log_any 60000 player physics enabled
wait_log_any 10000 the voxel registry from the served file
wait_log 120000 the voxel registry from the served file
look_dir 0 -1 0.6
wait_log 60000 drawn again
frames 10
screenshot @T@/voxel_watched.png
quit
EOF
cat > "$t/again.cmds" <<'EOF'
wait_log_any 60000 Joined as kitboss
wait_log_any 60000 player physics enabled
look_dir 0 -1 0.6
frames 10
screenshot @T@/voxel_again.png
quit
EOF
mkdir -p "$t/cu_maker/exports"
cp "$here/apps/workbench/main/client_data/lever_on.png" "$t/cu_maker/exports/frost.png"
server 5 "$t/user5"
wait_for_log "$t/srv5.log" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$t/srv5.log" | head -1)
[ -n "$code" ] || fail "no setup code ($t/srv5.log)"
BUILDAT_JOIN_NAME=kitboss BUILDAT_JOIN_CODE=$code \
	BUILDAT_JOIN_ADMIN="setting open_registration on" client maker &
maker=$!
wait_for_log "$t/maker.log" "kit editor: state: 1 entities" 120 ||
	fail "the admin did not get to the editor ($t/maker.log)"
BUILDAT_JOIN_NAME=kitbob client watcher
wait $maker || fail "the admin's client ($t/maker.log)"
stop
want "$t/srv5.log" "kitboss uploaded texture kit/up/" \
	"kitboss made voxel type kitboss/frost version 1 (kit/up/" \
	"solid, light 0, friction 0.2, surface \"\")" \
	"workbench: kitboss placed kitboss/frost ("
server 6 "$t/user5"
BUILDAT_JOIN_NAME=kitboss client again
stop
want "$t/srv6.log" "Builders' voxel types: 1, uploaded textures: 1"
grep -a "which this game does not register" "$t/srv6.log" &&
	fail "the builder's type was adopted, not registered ($t/srv6.log)"
echo "ok: a builder's voxel type made in Kit's editor from an uploaded PNG, drawn by a client already in, placed, and registered again at a restart"

# 9. ([WORKBENCH_PROJECTS]) The projects, on the launcher's own server and
# client (-u launcher=1): an old save "world" (part 1's project copied)
# beside them. The launcher's entries (luajit): the tile and Manage are
# menu=projects, New menu=new, a save's Manage... project=<it>. menu=new:
# the name screen at once, "alpha" typed and made, Workbench in it.
# ([KIT_HM_VOXELS]) On its heightmap, the editor's walk with the voxels
# tool: a voxel placed on the ground (in the cell the surface cuts
# through), one on its face, a third placed and
# dug, the heightmap not dug; End. ([KIT_HM_WALK]) In play w, a, s and d
# each walk several metres, no corrections; ([KIT_HM_FREE]) w on to the
# map's edge, stopped there; no voxel section loaded but the edits' few.
# Opened again
# (save=alpha): the two voxels at the crosshair, their section in
# the save.
# menu=projects project=world: Manage with "world" selected, renamed
# "first", "alpha" moved to the trash, "first" opened. save=first: open
# with no Manage.
luajit -e "local e = dofile('$here/apps/workbench/launcher/init.lua')({launch = function(a) got = a end})
	local want = {play = 'projects', new = 'new', manage = 'projects', manage_project = 'projects'}
	for _, x in ipairs(e) do
		got = nil; x.run('w1')
		assert(got.app == 'workbench' and got.params.menu == want[x.id], x.id)
		assert((got.params.project == 'w1') == (x.for_save == true), x.id)
		want[x.id] = nil
	end
	assert(next(want) == nil, 'missing ' .. tostring(next(want)))" ||
	fail "the launcher's entries"
mkdir -p "$t/user9/apps/workbench/saves"
cp -r "$save" "$t/user9/apps/workbench/saves/world"
local_server() # <n> <-u lines>
{
	start_server "$t/srv$1.log" "Listening at" 300 auto \
		bin/buildat_server -u "$2" -m ../apps/workbench -D "$t/user9" -l 3 ||
		fail "the server did not come up ($t/srv$1.log)"
	CHECK_PIDS+=($SERVER_PID)
}
cat > "$t/new9.cmds" <<'EOF'
wait_log_any 60000 world_menu: the name screen shown
frames 3
screenshot @T@/p_new.png
text alpha
click Button "Create"
wait_log_any 60000 player physics enabled
wait_log_any 30000 heightmap: terrain built
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state:
event wb_column
keypress V
wait_log 5000 kit editor: tool voxels
keypress F3
wait_log 5000 kit editor: the view is Walk
mouse_click left
wait_log 5000 kit editor: into the crosshair
look_dir 2.5 -1 0
frames 30
mouse_click right
wait_log 5000 kit editor: place
frames 10
mouse_click right
wait_log 5000 kit editor: place
frames 10
look_dir 1.5 -1 1
frames 30
mouse_click right
wait_log 5000 kit editor: place
wait_log 5000 kit editor: guide: Left: dig
mouse_click left
wait_log 5000 kit editor: dig at
look_dir 0 -1 1
frames 30
mouse_click left
wait_log 5000 kit editor: dig: the heightmap is not dug
look_dir 2.5 -1 0
frames 30
screenshot @T@/hm_built.png
keypress Escape
wait_log 5000 kit editor: out of the crosshair
click Button "End"
wait_log 10000 kit editor: the server is Ended
keypress F6
wait_log 10000 kit editor: the server is Running
look_dir 0 0 1
frames 30
event kit_body
keydown w
frames 120
keyup w
event kit_body
keydown a
frames 120
keyup a
event kit_body
keydown s
frames 120
keyup s
event kit_body
keydown d
frames 60
keyup d
event kit_body
keydown w
frames 900
keyup w
event kit_body
quit
EOF
BUILDAT_WORKBENCH_STONE= local_server 9 "$(printf 'launcher=1\nmenu=new')"
client new9
stop
# [WB_NEW_PROJECT_GROUND] New's project on a 64x64 grassland heightmap, no
# voxel ground, the player at its middle
want "$t/srv9.log" 'world_menu: made "alpha"' 'workbench: the project "alpha" opens' \
	'World: noise 64x64, seed 0, biome grassland, a heightmap,' ' put at (0.5, ' \
	'World: the heightmap from (-32,-32) to (31,31)'
grep -aq "World: the save holds\|biome grassland, voxels\|biome rock" "$t/srv9.log" &&
	fail "the new project has voxel ground ($t/srv9.log)"
want "$t/new9.log" "heightmap: terrain built"
# [KIT_HM_NO_SEA] The voxels on a heightmap all air: no sea over the
# voxel map's square (not loaded, too: [KIT_HM_FREE])
want "$t/new9.log" "workbench: column 5,5: "
grep -a "workbench: column 5,5: " "$t/new9.log" | grep -aq " air, 0 voxels" ||
	fail "voxels in column 5,5 on the heightmap ($t/new9.log)"
grep -aq "world_menu: the list shown" "$t/new9.log" &&
	fail "menu=new showed the list first ($t/new9.log)"
# The walk: each leg several metres its way (w +z, a -x, s -z, d +x), no
# corrections; ([KIT_HM_FREE]) then w on to the map's edge (z 31, the
# body's radius in; [KIT_HM_ORIGIN] the map centred), stopped there (d
# the shorter leg: w then goes clear of the voxels built at x 3)
grep -a "kit: body at" "$t/new9.log" | sed 's/.*body at \([^,]*\),[^,]*,\([^,]*\), .* \([0-9]*\) corrections.*/\1 \2 \3/' > "$t/walk9"
[ $(wc -l < "$t/walk9") = 6 ] || fail "not 6 body positions ($t/new9.log)"
awk 'NR == 6 { if ($2 < 30 || $2 > 31 || $3 != c) { print "edge leg " $0; bad = 1 }; next }
	NR == 1 { x = $1; z = $2; c = $3; next }
	{ dx = $1 - x; dz = $2 - z; leg = NR - 1
	  if (leg == 1 && dz < 3 || leg == 2 && dx > -3 || leg == 3 && dz > -3 || leg == 4 && dx < 3) bad = bad " leg " leg
	  if ($3 != c) bad = bad " corrections in leg " leg
	  x = $1; z = $2; c = $3 }
	END { if (bad) { print bad; exit 1 } }' "$t/walk9" ||
	fail "walking on the heightmap: $(tr '\n' ';' < "$t/walk9") ($t/new9.log)"
# [KIT_HM_FREE] No voxel section made for walking: those loaded only the
# edits' (made for them), a few
want "$t/srv9.log" "World: a heightmap's section "
grep -a "of the heightmap's voxel sections loaded" "$t/srv9.log" |
	sed 's/.*World: \([0-9]*\) of.*/\1/' | awk '$1 > 3 { bad = 1 } END { exit bad }' ||
	fail "more than 3 heightmap sections loaded ($t/srv9.log)"
# The voxels built over it: three placed, the top one dug, the ground not
cells=$(grep -a "kit editor: place kit/cobble at" "$t/new9.log" | sed 's/.* at //')
[ $(echo "$cells" | wc -l) = 3 ] || fail "not 3 placed ($t/new9.log)"
# The first on the ground, the second on its face
a=$(echo "$cells" | sed -n 1p); top=$(echo "$cells" | sed -n 2p)
# The first in the cell the terrain cuts through (partly sunken, at least
# barely seen)
h=$(grep -a "kit editor: on the heightmap, its surface at" "$t/new9.log" | head -1 | sed 's/.* at //')
[ -n "$h" ] || fail "the first voxel not on the heightmap ($t/new9.log)"
echo "$a $h" | awk -F'[, ]' '{ y = $2; h = $4; exit !(y - 0.5 < h + 0.0002 && y + 0.5 > h) }' ||
	fail "the first voxel ($a) not the cell the surface at $h cuts through ($t/new9.log)"
# (its top or its side: the first is partly sunken)
echo "$a,$top" | awk -F, '{ d = ($4 - $1) ^ 2 + ($5 - $2) ^ 2 + ($6 - $3) ^ 2
	exit !(d == 1 && $5 >= $2) }' ||
	fail "the second voxel ($top) not on the first's face ($a) ($t/new9.log)"
want "$t/new9.log" "kit editor: dig at $(echo "$cells" | sed -n 3p)" "kit editor: dig: the heightmap is not dug"
grep -a "set_voxel" "$t/srv9.log" | grep -aq "refus\|not loaded" && fail "a set_voxel refused ($t/srv9.log)"
# ... and over a restart (the project opened again): the save holds them
cat > "$t/again9.cmds" <<EOF
wait_log_any 60000 player physics enabled
wait_log_any 30000 heightmap: terrain built
wait_log_any 10000 kit editor: edit rights: yes
keypress F6
wait_log 10000 kit editor: state:
keypress V
wait_log 5000 kit editor: tool voxels
keypress F3
wait_log 5000 kit editor: the view is Walk
mouse_click left
wait_log 5000 kit editor: into the crosshair
look_dir 2.5 -1 0
frames 30
wait_log_any 5000 kit editor: guide: Left: dig $top |
quit
EOF
local_server 9b "$(printf 'launcher=1\nsave=alpha')"
client again9
stop
want "$t/srv9b.log" "World: 1 edited voxel sections over the heightmap"
cat > "$t/manage9.cmds" <<'EOF'
wait_log_any 60000 world_menu: the list shown, 2 worlds
wait_log_any 5000 world_menu: world selected
frames 3
screenshot @T@/p_manage.png
click Button "Rename..."
wait_log 5000 world_menu: the name screen shown
text first
frames 3
screenshot @T@/p_rename.png
click Button "Rename"
wait_log 10000 world_menu: the list shown, 2 worlds
click Button "alpha"
wait_log 5000 world_menu: the list shown, 2 worlds
click Button "Delete..."
frames 3
screenshot @T@/p_delete.png
click Button "Move to the trash"
wait_log 10000 world_menu: the list shown, 1 worlds, 1 in the trash
click Button "first"
wait_log 5000 world_menu: the list shown, 1 worlds
frames 3
screenshot @T@/p_trashed.png
click Button "Play"
wait_log_any 60000 player physics enabled
quit
EOF
local_server 10 "$(printf 'launcher=1\nmenu=projects\nproject=world')"
client manage9
stop
want "$t/srv10.log" 'world_menu: "world" selected' 'world_menu: "world" renamed "first"' \
	'world_menu: "alpha" moved to the trash' 'workbench: the project "first" opens'
cat > "$t/save9.cmds" <<'EOF'
wait_log_any 60000 player physics enabled
quit
EOF
local_server 11 "$(printf 'launcher=1\nsave=first')"
client save9
stop
grep -aq "world_menu: the list shown" "$t/save9.log" &&
	fail "save=first showed Manage ($t/save9.log)"
want "$t/srv11.log" 'workbench: the project "first" opens' 'biome rock, voxels'
echo "ok: projects: the launcher's New and Manage, a name typed and made (on a grassland heightmap), the old \"world\" renamed (still stone), one deleted to the trash, a listed one opened, save= opened with no Manage"
echo "PASS: Workbench: the admin builds a contraption of Kit's starter set in its editor, Stopped, and plays it, a second player joins the round, may build only in the dig zone and uses a key; a restart mid-round keeps the rows, Stop puts the start back, Play gives a kept inventory back and places players, Save as start keeps the round's voxels"
# vim: set noet ts=4 sw=4:
