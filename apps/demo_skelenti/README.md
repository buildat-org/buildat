# skelenti

A demo of mixing Luanti and Buildat in one app ([LUANTI_APP_EXAMPLE]),
not a game to play: a small alpha-era Luanti game (dig, craft up to
diamond, mind the skeletons) runs inside it. The game's rules are Luanti
Lua (main/game/); the mobs, the HUD, the inventory's drawing and the
pause menu are Buildat's own (main/main.cpp, main/client_lua/), the
world menu builtin/world_menu's.

Start it from the launcher, or `buildat_server -m apps/demo_skelenti`
and connect a client. Until a world runs, the first client on the
server's machine picks one: play a save, name and create a new one,
rename or delete one. `BUILDAT_SKELENTI_WORLD=<name>` skips the menu.

Each world has its danger zones (main.cpp's danger()). The deeper in, the
thicker the fog, the more skeletons, and the more bones: strewn over the
ground and the sides of blocks (the voxel shader's area field), and piled
up in bone blocks, skulls and loose bones by the mapgen (mobs.lua). From
half danger up, skeletons spawn under the open sky and the sun does not
burn them.

Knobs for checks: `BUILDAT_SKELENTI_TEST="boar 0 3; skeleton 0 9"` puts
those mobs by the first player and turns spawning off;
`BUILDAT_LUANTI_FORCE_TIME=0..23999` pins the hour.

## Licences

The code is Apache-2.0, as the rest of the tree. The sounds and the
music have no files: the client makes them at runtime
(`main/client_lua/sounds.lua` with blip, `main/client_lua/music.lua`).

The textures are CC BY-SA 4.0. They are from the Pixel Perfection
resource pack by XSSheep
(<https://www.planetminecraft.com/texture_pack/131pixel-perfection/>),
as copied into VoxeLibre (<https://git.minetest.land/VoxeLibre/VoxeLibre>
-- see its LEGAL.md). Each is a verbatim copy of a VoxeLibre file,
renamed, except `skelenti_boar.png`, which is VoxeLibre's pig skin
(`mobs_mc_pig.png`) tinted brown, and `skelenti_skull.png`,
`skelenti_skull_front.png` and `skelenti_skulls_front.png`, which are
drawn in the colours of `skelenti_bone_block_side.png`. By file:

- `skelenti_apple.png`: default_apple.png
- `skelenti_arrow_entity.png`: mcl_bows_arrow.png
- `skelenti_arrow.png`: mcl_bows_arrow_inv.png
- `skelenti_arrow_right.png`: gui_crafting_arrow.png
- `skelenti_bone_block_side.png`: mcl_core_bone_block_side.png
- `skelenti_bone_block_top.png`: mcl_core_bone_block_top.png
- `skelenti_bone.png`: mcl_mobitems_bone.png
- `skelenti_bubble.png`: hudbars_icon_breath.png
- `skelenti_coal_ore.png`: mcl_core_coal_ore.png
- `skelenti_coal.png`: default_coal_lump.png
- `skelenti_cobble.png`: default_cobble.png
- `skelenti_crosshair.png`: object_crosshair.png
- `skelenti_diamond_axe.png`: default_tool_diamondaxe.png
- `skelenti_diamond_ore.png`: mcl_core_diamond_ore.png
- `skelenti_diamond_pick.png`: default_tool_diamondpick.png
- `skelenti_diamond.png`: default_diamond.png
- `skelenti_diamond_shovel.png`: default_tool_diamondshovel.png
- `skelenti_diamond_sword.png`: default_tool_diamondsword.png
- `skelenti_dirt.png`: default_dirt.png
- `skelenti_fire_bg.png`: default_furnace_fire_bg.png
- `skelenti_furnace_front_active.png`: default_furnace_front_active.png
- `skelenti_furnace_front.png`: default_furnace_front.png
- `skelenti_furnace_side.png`: default_furnace_side.png
- `skelenti_furnace_top.png`: default_furnace_top.png
- `skelenti_grass_side_overlay.png`: mcl_core_grass_block_side_overlay.png
- `skelenti_grass_top.png`: mcl_core_grass_block_top.png
- `skelenti_gravel.png`: default_gravel.png
- `skelenti_heart.png`: heart.png
- `skelenti_hotbar.png`: mcl_inventory_hotbar.png
- `skelenti_hotbar_selected.png`: mcl_inventory_hotbar_selected.png
- `skelenti_iron_axe.png`: default_tool_steelaxe.png
- `skelenti_iron_ingot.png`: default_steel_ingot.png
- `skelenti_iron_ore.png`: mcl_core_iron_ore.png
- `skelenti_iron_pick.png`: default_tool_steelpick.png
- `skelenti_iron_shovel.png`: default_tool_steelshovel.png
- `skelenti_iron_sword.png`: default_tool_steelsword.png
- `skelenti_leaves.png`: default_leaves.png
- `skelenti_meat_cooked.png`: mcl_mobitems_porkchop_cooked.png
- `skelenti_meat_raw.png`: mcl_mobitems_porkchop_raw.png
- `skelenti_sand.png`: default_sand.png
- `skelenti_skeleton.png`: mobs_mc_skeleton.png
- `skelenti_skull_head.png`: mcl_heads_skeleton.png
- `skelenti_stick.png`: default_stick.png
- `skelenti_stone_axe.png`: default_tool_stoneaxe.png
- `skelenti_stone_pick.png`: default_tool_stonepick.png
- `skelenti_stone.png`: mcl_brewing_base.png
- `skelenti_stone_shovel.png`: default_tool_stoneshovel.png
- `skelenti_stone_sword.png`: default_tool_stonesword.png
- `skelenti_table_front.png`: crafting_workbench_front.png
- `skelenti_table_side.png`: crafting_workbench_front.png
- `skelenti_table_top.png`: crafting_workbench_top.png
- `skelenti_torch.png`: default_torch_on_floor.png
- `skelenti_tree.png`: default_tree.png
- `skelenti_tree_top.png`: default_tree_top.png
- `skelenti_water.png`: mcl_core_water_source_animation.png
- `skelenti_wood_axe.png`: default_tool_woodaxe.png
- `skelenti_wood_pick.png`: default_tool_woodpick.png
- `skelenti_wood.png`: default_wood.png
- `skelenti_wood_shovel.png`: default_tool_woodshovel.png
- `skelenti_wood_sword.png`: default_tool_woodsword.png
