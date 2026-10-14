demo_undermine
==============

Digger's world, but it does not hold itself up. Rock spans a gap, dirt does
not, a timber prop holds a ceiling until too much weight stands on it, and
rubble holds nothing. Dig badly and the mine comes down on you.

The mine, for now
-----------------

The world is generated the way demo_digger's is -- fbm noise, a grass surface over
dirt over rock, ponds in the hollows with sand shores, trees scattered over
it -- with bedrock at the bottom as the one thing that cannot be dug and the
thing support ultimately comes from.

A tree is scenery that the same rules apply to: its trunk stands on the
ground and its leaves hang off the trunk, so cutting through a trunk drops
what is above the cut.

Left button digs, right button places, and keys 1 to 5 pick what it places:
rock, timber, brick, dirt, water. The line under the position says what the pointed
voxel is made of and what the simulation thinks of it.

B opens a menu of structures the server will put up where you stand: a
chamber whose roof is wider than rock will span, a cathedral on pillars, a
bridge on piers, a mineshaft with timber props. Finding out what happens when
a pillar is cut should not start with an hour of bricklaying.

Tab is a free camera: it goes where it is pointed, through anything, and
nothing pulls it down. Turn it on before placing a structure and the camera
takes itself somewhere the whole thing is in frame.

V cycles the views: off, load, support, danger. The same voxels are drawn as
a gradient from green to red -- how much of what a voxel can carry is on it,
how far it is from something holding it up, or the worse of the two. All
three cost no storage at all, and how is worth reading if you are here for
the voxel format: the param carries both numbers and each view's registry
decodes them its own way. See build_view_registry() in main/main.cpp.

The rules
---------

Three, and they are all the physics there is.

Support is how far a voxel is from something holding it up. Bedrock has all of
it; a voxel standing on something supported has all of it too, because a
column carries straight down; and a voxel with nothing under it reaches out
sideways from its neighbours, losing one step per voxel and never further than
its material's span. Nothing left to reach means it fails. That is a
distance-from-the-nearest-wall rule rather than statics, and it is the right
kind of wrong: a tunnel wider than twice the material's span caves in the
middle, which is legible from inside the tunnel.

Load is the weight resting on a voxel: the column immediately above it, as far
as LOAD_DEPTH. Over its material's capacity and it fails. That is what makes a
prop under thirty voxels of rock snap and a brick pillar under the same rock
hold.

Water gets into what is porous. Moisture is how near a voxel is to water --
full next to it, one less per step away -- and dirt that has taken any of it
is wet dirt, which holds nothing out over a gap and carries half of what dry
dirt does. So digging under a pond floods and then collapses, and pouring
water next to a wall is a way to find that out on purpose. Take the water
away and the moisture runs back down and it dries.

What fails falls: down one voxel a tick, and becomes what its material falls
as. Rock and brick come apart into rubble, which spans nothing, so a pile of
it holds no roof up and a cave-in carries on rather than plugging itself. The
materials that are already loose heaps stay themselves -- dirt falls as dirt
and sand as sand -- and turf that has come off and landed is dirt, not turf.

The whole thing is one queue of voxels whose numbers are out of date, walked
with a budget per tick, so a change costs what it actually reaches: a dig into
solid rock settles in a handful of voxels, and a dig that takes a roof away
walks as far as the roof reached. It is the same shape as voxelworld's own
skylight flood, which is where it was copied from.

Materials carry three numbers the simulation reads: span, how far the
material reaches out over nothing before it fails; density, what a voxel of
it weighs; and capacity, how much weight it carries before it is crushed.
Timber spans far and carries little, brick spans little and carries a
mountain, and that pair is most of the game. See MATERIAL in main/main.cpp.

Why this game exists
--------------------

It is the sample game for a voxel format a game chooses for itself. Its
voxels are cut up like this:

    id 0...7, light_sky 8...11, param 12...19, moisture 20...23

-- eight bits of material id, with room for the nature and everything else a
game like this grows, four of skylight, and eight for the simulation: how
much of what a voxel can carry is already on it in one nibble, and how far it
is from something holding it up in the other.

One field rather than two, and bound as the engine's `param` role, because
the role is the only thing the mesher can read and the views need both
numbers. The load is kept as a fraction of the voxel's own capacity rather
than as a weight, which is the normalisation a view wants anyway and is what
lets one nibble do; nothing needs the weight itself, since it is worked out
from the column whenever the rules ask. Twenty bits of thirty-two are spent.

No lamp light. A lamp here is a light in the scene, which is what the
player's own lamp is, and the shader lights the geometry from it; the
engine's lamp-light role is for a world whose server bakes that per voxel and
sends it, which is what a Luanti server does.

The engine knows the param is there and hands it to a definition; what the
two nibbles in it mean is entirely the game's, which is the point. Moisture
is not a role at all -- the engine neither knows nor cares -- and adding it
after the game was already playable changed the format not at all.

What it did need was a material: both nibbles of the param were spoken for,
and a definition's variants are indexed by the param, so the only way for
the mesher to see wetness was for wet dirt to be its own material with its
own texture and its own numbers. Which is the better answer anyway -- wet
dirt is a different thing from dirt -- but it is worth knowing that the wall
was the param and not the width of the word. Eight bits are still spare.

Licenses of textures and other media
------------------------------------
When not specified separately:
- CC BY-SA 3.0 2014 Perttu Ahola <celeron55@gmail.com>

main/client_data/grass.png
main/client_data/leaves.png
main/client_data/dirt.png
main/client_data/tree.png
main/client_data/tree_top.png
main/client_data/rock.png
- CC BY-SA 3.0 2013 PilzAdam <pilzadam@minetest.net>

main/client_data/bedrock.png
main/client_data/sand.png
main/client_data/rubble.png
main/client_data/timber.png
main/client_data/brick.png
- Generated by make_client_data.py beside this file

main/client_data/water.png
- Copied from apps/sample_lighting_scene, where make_client_data.py generates it
