# skeldat

A bounded world that bones and skeletons are taking over: dig, craft
and burn lanterns to push the bones back, lure the skeletons with their
own marker skulls. Your score is the days until the bones cover the
whole surface: every column's top voxel. What is under it does not
count, and a skeleton beside a deep hole (a shaft dug down, a pit)
sometimes drops a skull into it, which grows bones where it lands.

It began as skelenti ([LUANTI_APP_EXAMPLE], `apps/demo_skelenti`) remade
in Buildat alone ([SKELDAT]): no Luanti game and no builtin/luanti
module under it.

- `main/game.h`: the nodes, the items, the tools, the recipes and the
  inventory rules. Its self test:
  `g++ -std=c++11 -Isrc -DSKELDAT_GAME_TEST -x c++ apps/skeldat/main/game.h -o /tmp/skeldat_game && /tmp/skeldat_game`
- `main/bones.h`: the bones field's rule, how it grows and floods. Its
  self test:
  `g++ -std=c++11 -DSKELDAT_BONES_TEST -x c++ apps/skeldat/main/bones.h -o /tmp/skeldat_bones && /tmp/skeldat_bones`
- `main/main.cpp`: the world (Luanti's valleys mapgen through
  builtin/luanti_mapgen, fed skelenti's biomes, ores and trees; voxelworld
  keeping the light and the save), the bones in it, the players -- where
  they are, what they carry, dig, place, craft and cook, their health and
  breath, the time of day -- and skelenti's mobs, the boar and the
  skeleton, spawning and burning by the bones around them.
- `main/client_lua/`: the client. `player.lua` is builtin/luanti's
  movement, copied; `ui.lua` and `pause.lua` are skelenti's HUD,
  inventory and pause menu (the world menu is builtin/world_menu); `mobs.lua`
  draws the mobs; `sounds.lua` and `music.lua` are skelenti's blip sounds
  and music, copied.
- `main/move_check.h`: the movement check, the engine's voxel pathfinder
  with a rule for a body in the air (self test in the header). Every
  second a player who is not an admin is pulled back where the move could
  not have been walked at twice the walk speed, or, on the board, made at
  the speed the height lost allows.
- The bones' speed, 1x, 2x, 5x or 10x: picked when a world is made
  (Bone speed, beside Size; 128 wide at 1x the defaults) and switched by
  an admin on the Admin... page. It scales the bones' growth, a
  lantern's clearing, the skeletons' bone blocks at night, their marker
  skulls and their skulls down deep holes, not their moving or
  shooting. The score names the lowest speed the world was at. A server
  that falls behind the bones says so in the chat, once a minute.
- The skateboard: walking downhill (ground a voxel lower two ahead, not
  sneaking) puts the player on a board by itself. It rides steps of up
  to 2 as a slope, loses no speed but by climbing and by S (the brake),
  turns toward where the camera looks, flies off crests, jumps twice
  as hard as a walk, and is left for walking at a stop, a wall, water or
  a ladder. The others see a flat box under a player on one.
- The world's edge: the last 16 columns of each side rise up to 12 in
  bone blocks, the outermost column a bone wall nothing digs (made once
  when a world is first in), and bone hills drawn beyond it to the view.
- Items on the ground: Q drops one of the held stack ahead (Ctrl+Q all
  of it), a dig or a kill drops what does not fit, and a death drops half
  the player's stacks at random. A drop lies a game day, kept with the
  world, and a living player within 1.5 voxels takes what fits.
- The bow (three sticks as the arc, three bones down the side): held,
  the left button draws it over a second and the release shoots an
  arrow from the inventory at a speed by the draw (the server times it);
  it digs nothing. An arrow is a bone over a stick (4). A stuck arrow,
  anyone's, is picked up by walking near it, and after a minute is kept
  as a voxel, picked up the same way or dug. The held item is drawn in
  the hand; the bow as a mesh that bends with the draw.
- An admin (accounts' admin, or the launcher's own client) has fly (K),
  fast (J) and noclip (H), and Admin... in the pause menu: each player's
  inventory, an item given or a stack taken, and the player made
  invulnerable (no damage of any kind) or not, into moderation's audit
  log of the world's save, which the menu shows.
- The chat is builtin/chat's: T (or the pause menu's Chat...) opens the
  console, the last lines show over the world for 20 s, and "Who's in the
  chat..." has the moderator's who-may-talk, mute, and reports, and
  everyone's report.

Start it from the launcher, or `buildat_server -m apps/skeldat` and
connect a client. Until a world runs, the first client on the server's
machine picks one: play a save, name and create a new one, or delete one.

A drive's event `skeldat_board <speed>` keeps the player on the board at
that speed along the look, a cheat for the movement check to catch.
A drive's event `skeldat_modes [fly] [fast] [noclip]` sets the modes
whatever the role, as a modified client would.

Knobs for checks: `BUILDAT_SKELDAT_WORLD=<name>` skips the world menu;
`BUILDAT_SKELDAT_SEED=<n>` is a new world's seed; `BUILDAT_SKELDAT_TIME=0..1`
the time of day it starts at (0.5 noon); `BUILDAT_SKELDAT_SPAWN="x z"` a new
world's spawn column, in a danger zone or not, or `"x y z"` a place under
the ground;
`BUILDAT_SKELDAT_TEST="boar 0 3; skeleton 2 9"` no spawning, and those mobs
at x, z from the first player, once (also `bones dx dz value` on the
ground's voxel, `marker dx dz`, a marker skull, `craft i item n`, n
of the item in the player's craft slot i, `give item n k`, k stacks
of n into its inventory, and `place x z`, the player moved onto that
column);
`BUILDAT_SKELDAT_SIZE="<half> <y0> <y1>"` a world's size in sections, over
the size picked in the world menu (512, 1024, 256 or 128 wide; the two
small ones 64 high); `BUILDAT_SKELDAT_SURVEY=1` the generated world's
tops, ores and edge bones logged once it is in;
`BUILDAT_SKELDAT_FILL=1` every voxel made with full bones, `half` those
at x >= 0 (and no piles at x < 0); `BUILDAT_SKELDAT_DAY=<s>` the seconds a day;
`BUILDAT_SKELDAT_EXPAND=<s>` the seconds between a section's expansions;
`BUILDAT_SKELDAT_LIGHT_STEP=<s>` a light skeleton's step;
`BUILDAT_SKELDAT_FAR=1` each far skeletons list sent to a player logged;
`BUILDAT_SKELDAT_SKELETONS=<n>` that many light skeletons added anywhere
when the world is in, and a new world not populated to its target (set,
or TEST); `BUILDAT_SKELDAT_MARKERS="sx sz n"` a footprint's
marker count; `BUILDAT_SKELDAT_LANTERNS="x z coal [block]; ..."` burning
lanterns on those columns, each reported every 10 s.

## Licences

The code is Apache-2.0, as the rest of the tree.

The textures are CC BY-SA 4.0. They are skelenti's: from the Pixel
Perfection resource pack by XSSheep
(<https://www.planetminecraft.com/texture_pack/131pixel-perfection/>),
as copied into VoxeLibre (<https://git.minetest.land/VoxeLibre/VoxeLibre>
-- see its LEGAL.md). Each is a verbatim copy of a VoxeLibre file,
renamed, except:

- `boar.png`: VoxeLibre's pig skin (`mobs_mc_pig.png`) tinted brown;
- `skull.png`, `skull_front.png` and `skulls_front.png`: drawn in the
  colours of `bone_block_side.png`;
- `grass_top.png` and `leaves.png`: multiplied by #79c05a, the tint
  skelenti's game gave them;
- `grass_side.png`: `dirt.png` with mcl_core_grass_block_side_overlay.png
  multiplied by #79c05a over it;
- `water.png`: the first 16x16 frame of the animation, multiplied by
  #3f76e4;
- `skull_item.png`: the face, cell (1,1) of the 8x4 grid of
  `skull_head.png`;
- `crown.png`: `bone_block_top.png` with that face over it;
- `marker_skull.png` and `marker_skull_front.png`: `skull.png` and
  `skull_front.png` in red;
- `lantern.png`, `lantern_active.png` and `lantern_top.png`: drawn for
  skeldat;
- `stuck_arrow.png`: drawn for skeldat in `arrow_entity.png`'s colours;
- `crack_0.png` to `crack_9.png`: the ten frames of `crack_anylength.png`.

By file:

- `apple.png`: default_apple.png
- `arrow_entity.png`: mcl_bows_arrow.png
- `arrow.png`: mcl_bows_arrow_inv.png
- `arrow_right.png`: gui_crafting_arrow.png
- `bone_block_side.png`: mcl_core_bone_block_side.png
- `bone_block_top.png`: mcl_core_bone_block_top.png
- `bone.png`: mcl_mobitems_bone.png
- `bow.png`: mcl_bows_bow.png
- `bubble.png`: hudbars_icon_breath.png
- `coal_ore.png`: mcl_core_coal_ore.png
- `coal.png`: default_coal_lump.png
- `cobble.png`: default_cobble.png
- `crosshair.png`: object_crosshair.png
- `diamond_axe.png`: default_tool_diamondaxe.png
- `diamond_ore.png`: mcl_core_diamond_ore.png
- `diamond_pick.png`: default_tool_diamondpick.png
- `diamond.png`: default_diamond.png
- `diamond_shovel.png`: default_tool_diamondshovel.png
- `diamond_sword.png`: default_tool_diamondsword.png
- `dirt.png`: default_dirt.png
- `fire_bg.png`: default_furnace_fire_bg.png
- `furnace_front_active.png`: default_furnace_front_active.png
- `furnace_front.png`: default_furnace_front.png
- `furnace_side.png`: default_furnace_side.png
- `furnace_top.png`: default_furnace_top.png
- `grass_top.png`: mcl_core_grass_block_top.png (tinted)
- `gravel.png`: default_gravel.png
- `heart.png`: heart.png
- `hotbar.png`: mcl_inventory_hotbar.png
- `hotbar_selected.png`: mcl_inventory_hotbar_selected.png
- `iron_axe.png`: default_tool_steelaxe.png
- `iron_ingot.png`: default_steel_ingot.png
- `iron_ore.png`: mcl_core_iron_ore.png
- `iron_pick.png`: default_tool_steelpick.png
- `iron_shovel.png`: default_tool_steelshovel.png
- `iron_sword.png`: default_tool_steelsword.png
- `leaves.png`: default_leaves.png (tinted)
- `meat_cooked.png`: mcl_mobitems_porkchop_cooked.png
- `meat_raw.png`: mcl_mobitems_porkchop_raw.png
- `sand.png`: default_sand.png
- `skeleton.png`: mobs_mc_skeleton.png
- `skull_head.png`: mcl_heads_skeleton.png
- `stick.png`: default_stick.png
- `stone_axe.png`: default_tool_stoneaxe.png
- `stone_pick.png`: default_tool_stonepick.png
- `stone.png`: mcl_brewing_base.png
- `stone_shovel.png`: default_tool_stoneshovel.png
- `stone_sword.png`: default_tool_stonesword.png
- `table_front.png`: crafting_workbench_front.png
- `table_side.png`: crafting_workbench_front.png
- `table_top.png`: crafting_workbench_top.png
- `torch.png`: default_torch_on_floor.png
- `tree.png`: default_tree.png
- `tree_top.png`: default_tree_top.png
- `water.png`: mcl_core_water_source_animation.png (one frame, tinted)
- `wood_axe.png`: default_tool_woodaxe.png
- `wood_pick.png`: default_tool_woodpick.png
- `wood.png`: default_wood.png
- `wood_shovel.png`: default_tool_woodshovel.png
- `wood_sword.png`: default_tool_woodsword.png
