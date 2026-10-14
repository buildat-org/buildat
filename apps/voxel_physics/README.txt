voxel_physics
=============

Falling voxel bodies on a voxelworld: the terrain is generated and meshed by
voxelworld, lit by its skylight and drawn with voxel_shading, and the pieces
that fall on it are drawn with the same shader out of the same voxel registry.

Each piece is a random connected shape inside a 3x3x3 box, grown from the
middle voxel outwards, so what lands interlocks instead of stacking like
boxes.

The scene is one 64x64x64 section, never streamed. The terrain is a bowl
rather than noise: what there is to look at is rigid bodies falling onto voxel
terrain, and a bowl keeps them in frame without anything having to herd them
back.

Physics runs on the server. voxelworld gives its chunk nodes collision shapes,
a piece is a Bullet rigid body carrying one box collision shape per voxel of
the same data the client meshes -- a convex hull would be quicker but wrong,
since the point of these shapes is that they are not convex -- and the client sees the result as replicated node
transforms; it simulates nothing itself. A piece is dropped every 0.7 s and the
oldest of the 24 is reused once they are all out, so the pile neither empties
nor grows without bound.

The pieces are scene nodes carrying their voxel data in node vars, not part of
the voxel world, so the client builds their geometry itself and calls
voxel_shading.apply_to_node() on them. They have no skylight in their vertex
data, which the shader reads as full skylight -- right for something out in the
open, and the reason a piece under a ledge is not darkened by it.

Keys: Tab for free movement (WASD, Space, Shift), R to clear the pieces.

check.txt shoots the pile at three points as it builds and once after it is
cleared; see the file for how to run it.
