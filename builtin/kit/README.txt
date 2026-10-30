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

DiffAlphaMask.xml is Urho3D's Techniques/Diff.xml with ALPHAMASK added
(MIT, as Urho3D).
