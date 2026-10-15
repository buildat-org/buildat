# skeldat

skelenti ([LUANTI_APP_EXAMPLE], `apps/demo_skelenti`) made in Buildat
alone ([SKELDAT]): no Luanti game and no builtin/luanti module under it.
Dig, craft up to diamond, cook in a furnace, mind the bones.

- `main/game.h`: the nodes, the items, the tools, the recipes and the
  inventory rules. Its self test:
  `g++ -std=c++11 -Isrc -DSKELDAT_GAME_TEST -x c++ apps/demo_skeldat/main/game.h -o /tmp/skeldat_game && /tmp/skeldat_game`
- `main/main.cpp`: the world (Luanti's v7 mapgen through
  builtin/luanti_mapgen, fed skelenti's biomes, ores and trees; voxelworld
  keeping the light and the save) and the players: where they are, what
  they carry, dig, place, craft and cook, their health and breath, the
  time of day.
- `main/client_lua/`: the client. `player.lua` is builtin/luanti's
  movement, copied; `ui.lua` and `pause.lua` are skelenti's HUD,
  inventory and pause menu; `worlds.lua` the world dialog.

Start it from the launcher, or `buildat_server -m apps/demo_skeldat` and
connect a client. Until a world runs, the first client on the server's
machine picks one: play a save, name and create a new one, or delete one.

Knobs for checks: `BUILDAT_SKELDAT_WORLD=<name>` skips the dialog;
`BUILDAT_SKELDAT_SEED=<n>` is a new world's seed; `BUILDAT_SKELDAT_TIME=0..1`
the time of day it starts at (0.5 noon).

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
- `crown.png`: `bone_block_top.png` with that face over it.

By file:

- `apple.png`: default_apple.png
- `arrow_entity.png`: mcl_bows_arrow.png
- `arrow.png`: mcl_bows_arrow_inv.png
- `arrow_right.png`: gui_crafting_arrow.png
- `bone_block_side.png`: mcl_core_bone_block_side.png
- `bone_block_top.png`: mcl_core_bone_block_top.png
- `bone.png`: mcl_mobitems_bone.png
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
