sample_voxel_objects -- builtin/voxel_objects ([VOXEL_OBJECTS])

Voxel houses standing turned on builtin/heightmap's hills: a 16^3 house
model shown by 100 objects (BUILDAT_VOXEL_OBJECTS_COPIES on the server
sets how many), each at its own yaw and a slight tilt, a 40x20x40 keep of
four chunks, and a beam floating at 45 degrees over a gravel pad with a
ball resting on its far end. E gives every house a chimney and takes the
beam's end away (the ball falls to the pad); B looks at the beam, H at the
houses; Escape leaves. The models and the map are saved. check.sh is its
check.

The code is Apache-2.0, as the rest of the tree.

The textures in main/client_data (cobble.png, wood.png, tree.png) are
CC BY-SA 4.0: byte copies of apps/skeldat/main/client_data's files of the
same names, from the Pixel Perfection resource pack by XSSheep
(<https://www.planetminecraft.com/texture_pack/131pixel-perfection/>), as
copied into VoxeLibre (<https://git.minetest.land/VoxeLibre/VoxeLibre> --
see its LEGAL.md); see apps/skeldat/README.md.
