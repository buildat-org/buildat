demo_aggregate
==============

demo_undermine's world, made of mixtures instead of materials. Every voxel holds a
portion of rock, sand, water, fibre and binder, and **there is no voxel type
id anywhere**: what a voxel looks like, whether it is solid, whether it holds
anything up, are all read off the fractions through the registry's look
rules.

It plays the same as demo_undermine on purpose. The scenario works, so reusing it
means the model underneath is the only variable, and what the mixture model
costs and buys shows up as a diff rather than as an argument. Play both and
notice nothing; then dig into what soil actually is.

Digger's world, but it does not hold itself up. Rock spans a gap, soil does
not, a timber prop holds a ceiling until too much weight stands on it, and
anything with nothing holding it together holds nothing. Dig badly and the
mine comes down on you.

What is different under the hood, in one list:

- **No voxel type id.** The registry's look rules pick a definition out of
  the fractions: thirteen base looks from sixteen ordered thresholds. The id
  role is bound to two bits that say only whether a voxel has been generated
  at all, which is what voxelworld needs and nothing else.
- **Span, capacity, density and porosity are derived** from what a voxel is
  made of, where demo_undermine looked them up in a table by material.
- **Falling breaks the bond** instead of turning what fell into rubble, so
  soil that falls is still soil and merely holds nothing up. Rock that falls
  is gravel, because that is what unbonded rock is.
- **Wet is water in the mixture**, not a wet_dirt material: it darkens
  through the tint modifier and takes half the capacity away.
- **Turf is soil with something alive in it** and leaves are living fibre
  with no mineral under it, which is the same two fields saying two things.
- A view mode is three definitions and three rules rather than sixteen
  variants on each of twelve materials.

And what demo_undermine has no answer to at all:

- **A fraction is solid volume, not heap volume.** A voxel of loose sand at
  nine fifteenths is six fifteenths void, and that void is the only place
  water can be. So saturation is how much of the *void* is taken: soil has
  little room and is soaked by a little water where gravel takes four times
  as much before it gives.
- **Water has a rate, not only an amount.** How fast it crosses a boundary
  is read off the composition, because rock, sand and binder are size
  classes and the finest material present throttles the flow -- a little
  clay in gravel ruins its drainage. So a bucket poured on turf pools and
  soaks away over half a minute, where without a rate it was inside the
  ground before the next frame. A tick is the step: a voxel moves water
  once per tick however many times the relaxation looks at it.
- **A part-full voxel is drawn part full.** Water is the one thing with a
  level, and the sag_top geometry modifier puts its top face where its
  contents reach, so a film of water on the ground is a film and not a cube
  of water.
- **Water moves and is conserved.** Down into whatever room is under it,
  then sideways, then up -- the last being capillary rise, which is why the
  ground over a water table is damp and a pond has a damp shore. Rise is
  diffusion towards field capacity rather than pressure: it moves water
  from whichever holds more of its own capacity to whichever holds less and
  never past that capacity, so it comes to rest where a head would not.
  Water is held against gravity up to what the mixture's capillarity holds -- only what is over that runs off, which is why damp
  ground stays damp instead of draining into the bottom of the world.
  Anything with set binder in it is closed to water, so brick and concrete
  keep it out and wood does not.
- **A heap carries what it is packed to.** Capacity is what the material
  would carry solid, scaled by how near the voxel is to its own packing
  limit, so a spoonful of leaf mould lying in a voxel carries almost
  nothing where before it carried half of what soil does. And a heap with
  no bond sinks into whatever room is under it, which is the other end of
  the same transfer that pushes material out of an overfull voxel -- so
  what a rotted tree leaves becomes part of the ground instead of standing
  on it.
- **A heap cannot be packed past its own limit, and a graded mix can.**
  Rounded mineral grains leave about a third of the space between them
  however hard they are pressed, which is why sand and gravel hold water
  even when fully compacted -- but a finer material fits between those
  grains, so sand full of sand still has room for binder. That is why soil
  is denser than the sand it is made of and concrete denser than its
  gravel, and it is what lets what a rotted tree leaves sink into a sand
  bank and turn it into soil. Bond raises the limit too, because material
  held together is a piece of something rather than a heap of it -- so when
  bond goes away a collapse *bulks*, and the rubble takes up more room than
  the rock did.
- **The wood cycle.** Life is how far living wood is from water it can
  drink, so a tree standing in wet soil is alive and cutting its trunk
  browns everything above the cut. Wood does not come back to life. Dead
  fibre lying wet rots -- a fibre becomes a binder, which is composting --
  and binder in sand is soil. A fallen tree becomes ground.

What it deliberately cannot say: how finely divided a material is. A log and
a heap of sawdust are the same fibre at a different bond, and fluffy sand
and packed sand are the same sand. The look spike says to take that loss --
they look the same in life too, which is why sand is dangerous.

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

Water is the one thing you pour at nothing in particular, so with water
selected and nothing in reach, right button puts it a couple of voxels in
front of you rather than doing nothing.

B opens a menu of structures the server will put up where you stand: a
chamber whose roof is wider than rock will span, a cathedral on pillars, a
bridge on piers, a mineshaft with timber props. Finding out what happens when
a pillar is cut should not start with an hour of bricklaying.

Tab is a free camera: it goes where it is pointed, through anything, and
nothing pulls it down. Turn it on before placing a structure and the camera
takes itself somewhere the whole thing is in frame.

G goes to the next place worth testing at: the pool site at (-79, 62, 167),
a hollow where water can be poured and watched, and an overlook the spawn
and anything built there is in frame from. See PLACES in
main/client_lua/init.lua.

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
