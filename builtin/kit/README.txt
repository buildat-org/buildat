builtin/kit -- licences

The code is Apache-2.0, as the rest of the tree.

The voxel textures in client_data (Kit's default material set,
materials.json) are CC BY-SA 4.0. They are byte-for-byte copies of
apps/skeldat's cobble.png, dirt.png, grass_side.png, grass_top.png,
gravel.png, leaves.png, sand.png, stone.png, tree.png, tree_top.png,
water.png and wood.png: from the Pixel Perfection resource pack by XSSheep
(<https://www.planetminecraft.com/texture_pack/131pixel-perfection/>), as
copied into VoxeLibre (<https://git.minetest.land/VoxeLibre/VoxeLibre> --
see its LEGAL.md). grass_top.png, grass_side.png and leaves.png are tinted
with #79c05a and water.png with #3f76e4, as skeldat's are; see
apps/skeldat/README.md.

The plants and moss ([KIT] stage 4f) are not in skeldat; they are from the
same pack in VoxeLibre itself (textures/ of
<https://git.minetest.land/VoxeLibre/VoxeLibre>, commit cfc0913d7bed,
2026-09-17; CC BY-SA 4.0 by its LEGAL.md), byte-for-byte copies, renamed:
dandelion.png (flowers_dandelion_yellow.png), poppy.png
(mcl_flowers_poppy.png), mushroom_red.png (farming_mushroom_red.png),
mushroom_brown.png (farming_mushroom_brown.png) and mossy_cobble.png
(default_mossycobble.png); except tall_grass.png, which is
mcl_flowers_tallgrass.png (grey, tinted by VoxeLibre at run time)
multiplied by #79c05a, the grass's tint.

[KIT_TINT_NATURE] [KIT_TINT_MATERIALS] (2026-11-01) The ones a tint
palette hues (materials.json's "palettes") are no longer byte-for-byte
copies: grass_top.png, grass_side.png's grass, tall_grass.png,
leaves.png, water.png, mossy_cobble.png's moss, wood.png, tree.png,
tree_top.png's bark ring, sand.png and stone.png were re-painted to grey
(each pixel's luminance over its group's brightest), and each palette's
entry 0 fitted (least squares) so that the grey times it is the old
look again. On a solid one the alpha is where the tint applies: 0 on
grass_side.png's dirt, mossy_cobble.png's stones and tree_top.png's
rings, which keep their colours. grass_bottom.png is dirt.png with
alpha 0 (a grass block's bottom, untinted). The same goes for
apps/workbench's brick.png (its mortar alpha 0) and glass.png (grey, its
alpha how much it lets through). Derivatives, under the same licence.

snow.png ([KIT] stage 4g) is a byte-for-byte copy of VoxeLibre 0.92.3's
textures/default_snow.png (the same pack, CC BY-SA 4.0 by its LEGAL.md;
the release's files, as poppy.png and mossy_cobble.png there are the same
bytes as at cfc0913d7bed).

The season textures ([KIT_ENVIRONMENT], materials.json's "seasons") are
made from those above by a script, under the same licences: snow_top.png
is snow.png with alpha 0 (untinted on a grass block's top);
grass_side_snow.png is grass_side.png with snow.png's top four rows (alpha
0); leaves_autumn.png, leaves_winter.png and tall_grass_autumn.png are
leaves.png and tall_grass.png re-coloured by their brightness (autumn's
orange and straw, winter's grey with pale specks), alpha kept.

DiffAlphaMask.xml is Urho3D's Techniques/Diff.xml with ALPHAMASK added
(MIT, as Urho3D).

crack_0.png to crack_9.png ([KIT_DIG_LOOK]) are byte-for-byte copies of
apps/skeldat's: the ten frames of VoxeLibre's crack_anylength.png
(<https://git.minetest.land/VoxeLibre/VoxeLibre>, CC BY-SA 4.0 by its
LEGAL.md; credited as in apps/skeldat/README.md).

The player model ([KIT_PLAYER_MODEL]): player_model.json is
VoxeLibre 0.92.3's mods/ITEMS/mcl_armor/models/mcl_armor_character.b3d
(<https://git.minetest.land/VoxeLibre/VoxeLibre>) converted by
util/kit_player_model.lua (the skin's triangles by bone and the
animations stand, walk, mine and walk_mine as each bone's transform a
frame): CC BY-SA 3.0, VoxeLibre's media licence (LEGAL.md; mcl_armor's
README: "see VoxeLibre license"). By VoxeLibre's git log the model is
3D Armor's 3d_armor_character.b3d by stu (Stuart Jones), itself Minetest
Game's character.b3d by MirceaKitsune (CC BY-SA 3.0, mcl_player's
README), reworked in VoxeLibre by epCode (2020-2021: its bones and
animations) and Johannes Fritz (2022). The conversion is a derivative
under the same licence.

player_skin.png is a byte-for-byte copy of VoxeLibre 0.92.3's
textures/character.png, the Pixel Perfection resource pack's player by
XSSheep (<https://www.planetminecraft.com/texture_pack/131pixel-perfection/>;
"Change player texture to Pixel Perfection", Wuzzy, 2017), CC BY-SA 4.0
by VoxeLibre's LEGAL.md. A team's colour is put on its shirt at run time
(client_lua/players.lua).
