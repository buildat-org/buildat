sample_material_wall
====================

The demo_aggregate app's look spike: a wall of samples with their voxel
fields set by hand, to find out whether a mixture of materials reads on
screen before anything is built that stores one.

Fifty samples, ten columns by five rows, standing at one z so that the grid
is read like a chart rather than walked through. Bottom row first, because
that is the order the camera sees them in:

  sag_top 0 -> full             the geometry modifier: how far the top face
                                sinks into the voxel
  rock -> sand, dry             the base look chosen by a threshold over the
                                sand fraction, with grain saying how much
                                sand is in it either side of the threshold
  rock -> sand, soaked          the same, wet
  tint + wetness, dry -> soaked the albedo tint along the definition's ramp,
                                and the wetness the shader darkens with
  gloss (binder) 0 -> full

Nothing is simulated and nothing is derived: the worldgen writes the fields.
The format binds tint, wetness, grain and gloss -- which is all four surface
modifiers there is room for -- plus sag_top, and the client switches
voxel_shading to PBRVoxelModifiers, the reference consumption of them.

**There is no voxel type id in this world.** Every voxel carries how much of
it is rock and how much is sand, two bits each, and the registry's look
rules pick the definition from a threshold over those: rock first, then
sand, then air for everything left. The one id role bound is written as 1
everywhere, because that is how voxelworld tells a generated voxel from one
nothing has got to yet, and it says nothing about what the voxel is.

What it answered, in short:
the tint, the wetness and the sag read at a glance; the grain does not, and
the threshold between two base looks carries nearly all of the signal.

Run it:

    bin/buildat_server -m ../apps/sample_material_wall
    bin/buildat -s localhost -w 1600x900 -c @../apps/sample_material_wall/check.txt

Tab is free move, so a sample can be walked up to.
