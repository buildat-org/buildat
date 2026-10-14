sample_lighting_scene
=====================

A static voxel scene for working on voxel lighting. Not a game: there is no
player, no physics and no world streaming, so that a change to the rendering
can be judged from framings that are identical between runs.

One 64x64x64 section is generated with demo_digger's terrain generator, with the
octaves below a wavelength of 64 kept and the amplitude cut to suit a volume
this size. A cave is carved into it with a sphere swept along the camera's
view direction, yawed 20 degrees so it does not run straight away from the
camera.

Eight sections
--------------

Started with the launch param sections=8 (the server's -u sections=8, or the
launch grid's second tile), the same scene is placed in a world of 2x2x2
sections, 128 voxels on a side, so that everything it checks has to work
across section boundaries. That puts three boundary planes through it, at
x=64, y=64 and z=64.

The scene is placed at SCENE_OFFSET in main.cpp rather than rebuilt, so the
terrain under the cave, the cave itself and the two benchmark edits are the
ones the single section has. The offset is what decides where the boundaries
fall through it, and it puts them at scene x=57, y=29 and z=28.

The cave crosses those at roughly a fortieth, an eighth and three quarters of
its length: one boundary two voxels inside the mouth, where the light gradient
is steepest; one just under the surface there; and one far down the tunnel
where there is almost no light left. The cave runs through four sections that
way, and the benchmark shaft crosses the horizontal plane with five voxels
below it and six above.

Putting the mouth on the corner where all eight sections meet looks like the
hardest arrangement and is not. The cave leaves through one octant immediately
and then spends three quarters of its length inside a single section, which is
the case that was already working.

The terrain keeps going past the 64 voxel scene to fill the rest of the world.
That is the visible difference: the same view of the same cave, with terrain
running off the edges of the frame instead of a floating block. The trees do
not land where one section puts them, because they are placed per cell of a
grid over the world rather than by a count per section, which is what makes
one growing over a boundary come out whole from both sides. There is no pond
and so no benchmarks 4 to 7: those are for the materials, and eight sections
are for the light. Rock and dirt keep the static spots they had (0.04 rather
than 0.25), so the eight sections' look stays what it was.

V verifies the skylight over the whole world, so light that should have
crossed a boundary and did not shows up as voxels that differ.

Checking it
-----------

check.sh runs the views of check.txt and compares them against the reference
run in local/sample_lighting_scene/ref/, printing each view's RMSE; check.sh --accept
makes the current run the reference. Two runs of the same code sit under about
12 here and the bar is 30, while a change that moved the lighting measured 72
to 868 ([CHECK_BASELINE]). check.txt is still there to be driven by hand when
what is wanted is a person's eye rather than a number.

check_multisection.txt is the eight sections' views, three benchmarks before
and after the edits, into ../tmp/multisection_lighting_check/; it is driven by
hand against a server started with -u sections=8 (see its header).

Lighting
--------

The server flood fills a 4 bit skylight value into every voxel: full straight
down through air, losing one step per voxel as it spreads sideways and deeper.
The mesher packs that into vertex colors, and chunk geometry is drawn with
PBRVoxel, a technique and shader in the voxel_shading module, which puts them
on each chunk in voxelworld.sub_material_update(). The mesher sets no technique
of its own; interface/mesh.h lists what it does hand a voxel shader. Nothing in
voxel_shading needs a module's privileges, since a module has none a game
lacks; it is a module so that both lighting games can share it. The scene is
rendered in HDR and tonemapped.

The vertex color carries how much sky a surface sees in its alpha and the
light bounced off nearby surfaces in its rgb, and the shader adds them:

    ambient = zone ambient * color.a + color.rgb

so a face that can see the sky gets the zone's blue and one that cannot gets
the near-neutral grey of bounced light. That is what makes a cave look
different from a tree's shadow. Direct sunlight is left out of it, being
shadow mapped already.

Folded into both terms are per-vertex ambient occlusion, from how many of the
three voxels around each quad corner are solid, and a fixed per-face
brightness (top brightest, bottom darkest, the four sides spread either side
of the middle). The latter is for legibility rather than physics: without it,
two faces of a voxel in shadow receive the same light and the edge between
them disappears.

Skylight is opt-in per world: voxelworld.use_skylight, off by default. A world
that does not fill the bits, and any dynamic voxel node meshed by a game
itself, keeps the plain Diff technique and full brightness.

Materials
---------

The same technique also does normal mapping and per-texel roughness, and
reflects an environment cube map. None of the maps are authored: the atlas
derives a normal map and a surface map from each texture as it packs it, from
six numbers a voxel gives with it (interface/atlas.h):

    roughness  how wide the highlight is; the mean over the texture, with
               brighter texels a little smoother and darker ones rougher
    spec_strength  how much of a highlight there is at all
    bumpiness  how much the texture's luminance is read as height
    translucency  how much light passes through from behind, at a spot
    spots      fraction of the surface that is a spot at any one moment
    static_spots  the same, for spots that hold still

The first two are separate because roughness alone cannot make a surface matte.
It sets how wide a highlight is, and everything here except water sits between
0.85 and 0.98, a band across which the difference is barely visible;
spec_strength is what says whether there is a highlight to widen. Rock and dirt
are at 0.15 of it, so they are dull all over, and the tree trunk at 0.35, since
bark is not that shiny. Spots ignore spec_strength and reflect at full
strength, which is the whole point of it: rock can be dull everywhere except at
its crystalline facets, which is not something a single roughness could say.

Rock and dirt take their facets from static_spots, and the number is 0.25 rather
than the 0.04 they carried while the shader spotted every material that named
none: a quarter of the cells, which is a sprinkle rather than a crunch. 1.0 is
what the old behaviour amounted to and it reads as noise on the dirt; 0.04 is
not visible at all. The check images move by 465 to 868 RMSE between 0.04 and
0.25 where two runs of the same code differ by 0 to 29, so this is a change the
check sees easily.

bumpiness is the other half of how busy a surface looks, and the one that is
easy to mistake for gloss. It breaks the light up across the texture, diffuse
as much as specular, so a surface with a high one reads as grainy whether or
not it reflects anything. Rock and dirt were at 2.0 and 2.5 and are now at 0.5
and 0.6; most of what looked like too much shine on them was this. Grass reads
as smooth however many shapes are in it, so its normals are kept low as well;
any more and it turns grainy at a distance.

Grass and leaves keep full spec_strength but get their gloss from their spots,
because a leaf catching the light is a leaf that has turned and a bright texel
sits still. Water is the one surface here shiny enough for its texture's own
roughness to show, and has spots on top of that.

Metalness is not among the numbers. Nothing in this world has been metal, so it
is the material's own constant rather than a per-texel channel, and that channel
carries spec_strength instead.

Spots come in two kinds, and both are worked out from the world position
rather than stored in a map. That is the answer to the maps repeating: a map
lives in one voxel face, so anything in it appears again every voxel, which a
speckle must not do. Making the maps span 4x4 voxels instead would mean the
mesher writing texture coordinates that run across faces, and it still only
moves the repeat further out; a function of the world position has no period at
all. STATIC_SPOT_CELLS and TRANSMISSION_CELLS in PBRVoxel.glsl set how big the
two kinds are, in cells per voxel.

The still kind is on or off with no fade and holds one tilt across its cell, so
it reads as a flat facet with an edge. The moving kind fades in and out. Which
one a material gets is a separate fraction, and a material can have neither.

A spot is one thing with three effects, from one mask: the surface there is
turned away from the face it is on, is glossier than its roughness map says,
and passes translucency. They are the same event seen three ways, and which of
them shows is settled by the geometry, since transmission only appears with the
light behind the surface and a highlight only with it in front.

The turn is what does most of the work. Gloss on its own only shows where the
thing being reflected has contrast in it, and outside the sun disc this cube
map is a smooth gradient, so a sharper reflection of it looks no different from
a blurred one. Turning the normal moves the direct sunlight's
own highlight instead, which is the bright thing in the scene, and that is what
stands in for the animated normal map the water has not got. The turn is taken
across the surface rather than in any direction: a free direction tips some
normals past the horizon, and those reflect the ground half of the cube map as
brown specks on the water.

Grass has the same spots as leaves. Transmission is bright, being the sun
rather than the sky, and grass is usually near the camera, so its specks are
both large and clipped: a blown-out speck is what a gap in a backlit surface
looks like, and dialling the amount down until it stops clipping only makes it
a dull mottle. What is worth keeping down is how many there are, not how bright
each one is.

Leaves are also the one translucent thing here. A backlit leaf gets no direct
sun on the side facing the camera, so without it the only thing lighting the
side you see is the sky, and a canopy against the sun comes out blue. What
makes it warm instead is light coming through the leaf, which is a transmission
term rather than anything to do with reflections: tinting the cube map towards
the sun would not reach it, because in that geometry the surface reflects the
sky behind the camera, away from the sun.

It is a few specks rather than a whole face. A face at a time is a lamp, not a
tree; light gets through a canopy where a leaf happens to have a gap behind it.
Where that is, is not something the leaf texture knows, and it does not hold
still either: in any wind it is a different leaf a moment later. So the spots
are not stored anywhere. The shader dices the world into cells a sixteenth of a
voxel across, gives each one its own cycle from a hash of its position, and
makes it a spot for the material's fraction of that cycle; a slow ramp along
the wind direction is added to the phase, so they cross the surface in gusts
rather than twinkling evenly. The map carries only how much light gets through
and how much of the surface is a spot at once.

The cycle is worked in its own 0..1 position rather than in the height of a
wave. Near the top of a sine the wave is almost flat, so a threshold that fully
opens 4 per cent of cells leaves another 10 per cent hovering just under it,
and the surface hazes over instead of speckling.

What comes through keeps only part of the surface's color. Taking the albedo
raw would apply the leaf's green a second time and the spots would come out as
saturated as the texture; the shader mixes it most of the way to white, since a
gap passes the sun unchanged. TRANSMISSION_TINT in PBRVoxel.glsl is that mix.

What it reflects is the zone's cube map, voxel_shading/VoxelSky.xml,
generated by
make_client_data.py in the same brightness range as the zone's ambient color:
the same sky, seen in a mirror rather than diffusely. It has a sun disc in it,
a few degrees across rather than the half degree the real one is, because at 64
pixels a face a half-degree disc is smaller than a texel. The disc is what
gives a glossy surface something with contrast in it to reflect. The
directional light draws the sun's highlight as well, so a surface facing it
right gets both; the disc is left at the top of the 8 bit range rather than
made an HDR value, so that neither swamps the other.

The same sky is also drawn, by VoxelSkybox.glsl on a skybox, in the gradient
the cube map is baked in so that what a surface reflects agrees with what is
overhead. It has a square sun rather than a disc, since everything else here
is cubic, and a layer of clouds projected onto the sky by direction. The
clouds are noise snapped to a grid of their own and drawn in two flat tones,
so they come out in squares rather than as a gradient. A skybox has no depth
presence, so neither is ever in the way of the ground.

The clouds are the one place the drawn sky and the reflected one knowingly
disagree: they are not in the cube map, so nothing reflects them. Below the
horizon the drawn sky is a neutral haze rather than the cube map's ground
color, since the only time it shows is past the edge of the world.

There is one cube map, and where the sky cannot be seen the shader dims it by
direction rather than reflecting a second, indoor one. How much of the sky the
camera can see is kept as 6x6 values per cube face, 216 in all; the shader
looks the value up along each pixel's reflection direction, bilinear between
cell centers, and multiplies the sky by it. A cell is about 15 degrees across.

The client fills those by marching rays through the voxel data from the camera:
four per cell, thirty-six cells a frame, and two slices kept in flight at once,
so 288 rays a frame and every cell renewed every third. A cell keeps the
average of its four, and that average is eased into what the shader sees.
buildat.cast_voxel_rays() does the marching, on a worker thread -- see its
comment in src/lua_bindings/voxel_volume.cpp -- because the same loop written
in Lua cost half a millisecond a frame for four rays of twenty voxels, and this
wants hundreds of sixty-four.

The values do not go on materials. They go on the render path's scene pass
commands, whose shader parameters Urho hands to every batch the command draws,
so one set of them covers the scene however many chunks are loaded. Giving
every chunk material its own copy cost 5.2 ms a frame -- a streaming world has
hundreds of materials, and a parameter on each costs more than the ray marching
does.

Setting it and declaring it are separate, because they cost differently.
RenderPath:SetShaderParameter() only touches commands that already carry the
name, and is what runs per frame: three calls whatever the render path holds.
Putting the name on the scene passes in the first place means walking the
commands, and every command asked for is a fresh sandbox wrapper, which came to
a third of a millisecond a frame; so that walk happens once a second instead. A
game that swaps its render path gets the name back on the next walk.

Measured in demo_digger, per frame: 0.35 ms for the rays, 0.05 ms for keeping the
list of chunks they may reach, and the parameter too small to measure, so 0.40
ms in all. In sample_lighting_scene, whose world is one section, 0.10 ms. Collecting
the chunks was 0.5 ms until it stopped happening every sweep: the set within
reach of a ray does not change until the camera crosses into another chunk.

A ray answers no if something solid stops it. If nothing does, the answer is
the skylight of the air it ended in, which is 1 for fully lit air and 0 for
dark. Getting its whole length, 64 voxels, is not itself a yes: a ray crossing
sixty-four voxels of unlit cavern has met nothing and seen no sky either, and
calling that sky is how a fixed length goes wrong on its own. The length still
matters -- a ray down demo_digger's tunnel has to reach the far end to find out that
the tunnel is not a way out -- so it is not the thing to economise on.

Skylight is used there and nowhere else along the ray. It says the sky is open
straight up from a point, which is no answer to whether the sky lies along the
ray, and stopping rays wherever they met full skylight looked right and was
badly wrong: at the mouth of demo_digger's tunnel the air is fully lit, so every
direction including the tunnel came back at 1. At the far end of a ray it is
answering about the place the ray reached, which is a question it can answer.
A ray that runs out of loaded chunks part way is read the same way, for the
same reason, and that beats calling the edge of the loaded world sky.

Partial values come from the sampling instead. The rays are jittered inside
their cells and differently each sweep, and each cell keeps an average of its
own rays at 0.15, so a cell settles at the fraction of its directions that see
sky.

Each cell is jittered by an offset of its own, and this matters more than the
number of rays does. With one offset for the whole cube -- which is what it was
at first -- every cell samples the same relative point at the same time and
their errors line up, so a sweep whose offset leans towards the sky brightens
every cell straddling an opening at once and the reflections in the whole scene
move together. Coherent like that it reads as the scene pulsing, which is far
more visible than the same amount of noise spread over cells, and since the
sweep steps by a fixed sequence the pulsing is periodic. Casting more rays does
not help with any of that: it was never a shortage of samples, it was 216 cells
making the same error at the same moment.

Measured at benchmark 3 with the emphasis at 16, over the mouth region, with
6x6 cells and one ray each:

                                    one offset   per cell
    coherent std of the region       0.2049       0.0923
    per-pixel per-sweep |diff|       0.2964       0.1058
    the same on the worst patch      2.32         0.99

Noise falling by 2.8 is what casting eight times the rays would have bought,
for no rays at all. Brightness is unchanged by it: the rim region reads 77.5660
before and 77.5657 after at emphasis 1, over thirty frames each.

Twelve by twelve cells with sixteen rays each measures 0.0097, 0.0028 and 0.05
on those three, which is as still as it gets and far past what is needed. The
settings are 6x6 cells with four rays each, which leaves a slight shimmer that
reads as fine.

What that costs, measured at benchmark 3 over 4800 frames -- marching on its
worker with thread CPU time, the rest on the main thread:

    marching                    0.090 ms/frame   0.31 us/ray, 7.8 steps/ray
    submitting (Lua -> C++)     0.183 ms/frame
    collecting (C++ -> Lua)     0.042 ms/frame
    aiming the directions       0.112 ms/frame
                                -----
                                0.427 ms/frame

The marching is a fifth of it, and the rest is the price of 288 rays crossing
between Lua and C++ every frame: 864 numbers written in Lua to aim them and 864
read back by luabind to cast them. Rays are not what this costs; handing them
over is. It was 0.678 ms before the engine started averaging each cell's rays
itself and before the shader's copy of the cube was repacked once a frame
rather than once per slice -- the second of those was worth more than the
first, since repacking read every cell out of Lua twice a frame to publish a
cube the shader reads once.

Two things follow. Making the marching itself faster -- skipping empty space
with a coarse occupancy mip, say -- would be optimising the fifth, and rays
that die after eight voxels have little empty space to skip. And putting the
rays on a worker thread, which is what happens now, moves that same fifth off
the frame and leaves the rest of it there.

What is left is the direction crossing, and the only way past it is for the
directions not to cross: the engine would have to work them out from the cell
layout rather than being told each one. That is the part a game defines for
itself, so it would have to become something a game opts into rather than
something done to it.

Note also that two slices are kept in flight, so the rays cast per frame are
twice CELLS_PER_UPDATE times RAYS_PER_CELL: 288 here, where the constants read
144.

 That average is also what keeps the speculars still: taking a ray whole
put its own yes-or-no on the screen, which flickered several times a second --
measured over bursts of twelve frames of demo_digger's tunnel wall as the mean
absolute difference between consecutive frames, 1.05 taking rays whole against
0.13 with the average.

A cell is blended in and handed to the shader as its own ray lands, rather than
a whole sweep at a time, on the reasoning that waiting for the sweep steps
every reflection in the scene together, six frames apart, where a cell changing
when its own ray arrives spreads the same change out. That one is not measured:
the runs that were supposed to compare the two turned out to differ in whether
the wind was frozen and whether the camera had reached the benchmark at all, so
the numbers that looked like a verdict were not one. Worth measuring properly
before anyone leans on it.

Resolution is what decides how narrowly this can be aimed. The sky over
demo_digger's spawn tunnel is a few degrees off the tunnel's own direction, and a
3x3 cube's cells are 40 degrees across with the interpolation spreading each
one over most of a face; the self-check's flat ground reads 0.50 to the sides
at 6x6 and 0.92 at 3x3, where the ground and the sky above it fall in one
cell. Looking at a cave from outside with nothing but terrain
in view, nothing reflects a sky that is not there either -- which a baked indoor
map could not get right, since its brighter horizon band assumes windows all
around. Digging the shaft with P lets skylight into the cave and brings the
reflections back, which is the easiest way to see it work.

A direction with no sky visible reflects nothing rather than the rock that is
actually there. That is where a second, indoor cube map used to do some work,
giving a cave wall a dim grey to reflect; it is gone, along with the half of
make_client_data.py that generated it, because a dimmed real sky says the same
thing without having to guess at the geometry. Bounced light is in the vertex
color if a floor for the reflection is ever wanted.

What counts as solid is the voxel registry's own physically_solid, so glass and
water are whatever the world says they are.

The surface's own skylight scales all of this on top of the cube: the cube
answers for the direction and the vertex color for the place. Both matter.
Standing at the mouth of a tunnel, the mirror direction off its walls points
back out at the open sky, so the cube is bright there and it is the wall's own
dim skylight that keeps the reflection down.

Only the specular half of image based lighting is taken. The diffuse half
would be an unoccluded sky added to every surface, which would light the
inside of the cave; the skylight in the vertex color is this scene's ambient
diffuse and it already knows where the sky can be seen from. The specular term
is scaled by that same skylight for the same reason, so the cave reflects
nothing.

A world that sets no zone cube map gets black reflections and is otherwise
unaffected.

Benchmarks
----------

Six fixed camera placements, on the HUD buttons at the top right and on keys
1 to 6. Each is there for something specific, so a rendering change can be
judged against the previous run's images one feature at a time:

  # Name            Frames                      What it is there for
  - --------------  --------------------------  --------------------------
  1 Overview        the whole volume from the   the scene as a whole; the
                    high +X +Y +Z corner        shape of the terrain and
                                                where everything else is
  2 Cave mouth      the cave axis from          skylight falling off into an
                    outside, looking in         opening, and the shape of the
                                                mouth against lit ground
  3 Inside cave     the cave axis from inside,  skylight at its darkest: rock
                    looking back out            that sees no sky at all
                                                around a blown-out opening.
                                                The main one for relighting;
                                                the shaft and slab edits are
                                                shot from here
  4 Pond            across the water from over  the environment cube map. A
                    its far rim                 reflection is strongest at a
                                                grazing angle, and leaves,
                                                grass and dirt are in the
                                                same frame for contrast
  5 Backlit canopy  a tree from back and above  the canopy's directly lit top
                    it, sun behind and above    face against its shaded side,
                                                in one frame
  6 Sun behind      the same tree from below,   light through the leaves at
                    looking up at the sun       its strongest: the leaves
                    through it                  facing the camera have the
                                                sun square behind them. Also
                                                the grass on the terrain
                                                either side

Reading them, 3 is the one that matters for skylight and relighting, 4 to 6
are the ones for materials.

Light through leaves is animated off the scene's clock, so a shot of it comes
out differently every run. F (or the last HUD button) holds the clock at
FROZEN_TIME, and check.txt presses it before it shoots anything. It is a toggle
rather than something the benchmark cameras do by themselves: moving between
cameras should not stop the scene animating, and a frozen scene that nothing
said it had frozen is a confusing thing to land in.

R (or the HUD button beside the wind one) cycles the specular emphasis
through 1, 4, 16 and 64, multiplying the reflected sky and nothing else.

This exists because the reflections are too faint to measure at 1. A change to
voxel_shading's sky visibility sampling moves a cave wall by a fraction of a
value out of 255 -- below what a PNG rounds to -- so bursts of screenshots come
back byte-identical whatever the sampling does, and comparing two approaches by
eye or by ImageMagick says nothing. Turned up, the same change is tens of
values and can be measured.

The pulsation the sampling produces is what this was built to see. At benchmark
3, with the wind frozen and the camera left alone, sampling one frame per sweep
off the brightest patch of the cave mouth's rim:

    16x:  84.8 82.7 83.2 81.9 84.9 84.7 83.0 88.3 86.9 ... 91.0 88.1 87.3
          per-sweep |diff| mean 2.32, max 8.15, on a level of 86
    1x:   per-sweep |diff| mean 0.16, max 0.54

The rim is the whole of it: a per-pixel map of temporal range over the mouth
traces the dirt and rock edges and is black everywhere else. Cells looking at
solid rock sit at 0 and cells looking out of the mouth sit at 1, and neither
varies; the variance is entirely in the cells straddling the rim, where a
cell's rays are a coin flip weighted by how much of it the opening covers.

Emphasis scales the reflection alone, so what it exaggerates is exactly what
that sampling decides. It does also make the VOXELSPOTS sparkle plain, since
those spots reflect the sky too -- worth knowing before reading a screenshot
taken at 64.

The pond is dug rather than found. This terrain is one slope, so a water line
drawn across it fills the low ground at the edge of the volume and reads as a
sea the world runs out of; a basin dug into the flattest ground away from the
cave reads as a pond. POND_CENTRE_X, POND_CENTRE_Z, POND_RADIUS, POND_DEPTH
and WATER_LEVEL in main.cpp were picked off the surface heights the generator
reports, in the same way as GROUND_OFFSET and TERRAIN_AMPLITUDE.

5 and 6 are two framings of the same tree, the one nearest the middle of the
volume. The sun is high, so they cannot be the same camera: standing back from
a tree far enough to see its top means the sun is above it rather than behind
it, and putting a canopy between the camera and the sun means standing under
the tree and looking up.

Tab (or the top HUD button) toggles free move: WASD on the horizontal plane
whatever the camera is pitched at, Space up, Shift down, mouse to look.

Editing
-------

F freezes and unfreezes the wind, whatever mode the camera is in.

In free move, left mouse digs the pointed voxel and right mouse places rock
next to it. P and O (or the last two HUD buttons) make the two fixed edits used
for comparing images.

P digs a 3x3 shaft straight up out of the cave to the open air, starting far
enough in that the skylight there was 0. That is the strong test: a whole part
of the scene that had no skylight at all has to come up to daylight, and
benchmark 3 goes from near-black rock to a lit cave.

O caps the shaft with a 5x2x5 slab filling the two air voxels above the ground,
which takes back the light the shaft let in: benchmark 3 returns to the dark it
started at. The shaft reaches through the cap, so digging again cuts it back
out and the two can be alternated for as long as anyone wants to watch them.

Relighting is voxelworld's, not this game's: it is turned on with
set_skylight_enabled(true) and from then on every set_voxel keeps the light up
to date, generation included. An edit costs well under a millisecond
here, and what it costs depends on how far the light moves rather than on how
big the world is. Lighting the whole section at generation costs 40 ms.

V (or the last HUD button) checks that: it runs a skylight flood fill from
scratch over the whole scene and compares it voxel by voxel against what
voxelworld stored, logging either "skylight verify: ok" or the number of voxels
that differ and the first one. check.txt runs it after generation and after
every edit, so a run says outright whether the incremental relight got the same
answer as doing it all again.

Running
-------

    $ bin/buildat_server -m ../apps/sample_lighting_scene
    $ bin/buildat -s localhost

or with -u sections=8 on the server for the eight sections.

check.txt visits all six benchmarks and screenshots each, for comparing a
rendering change against the previous run:

    $ bin/buildat -s localhost -w 1600x900 \
            -c @../apps/sample_lighting_scene/check.txt

-w gives the run a fixed window size without changing the remembered one, so
the images come out the same size whatever the window was left at last time.
It also shoots both benchmark edits, so a run is: all seven views of the scene
as generated, then three of them after the shaft and after the slab.

The same run at -o render_scale=0.5 and at 1.0 is the check that the client's
undersampling preference is doing what it should: the same scene, one softer,
and the UI text equally sharp in both. This game is a good one for it because
it renders in HDR with a tonemap appended to the render path, which is what
the preference must not disturb.

NOTE: the server reads client_lua and client_data once at startup, so restart
it after editing init.lua, the shader or a cube map, or the client will be
served the previous version. That goes for the voxel_shading module's files as
much as for this game's own.

Tuning
------

The generator logs the noise range and the surface range it produced, and the
cave mouth it chose. GROUND_OFFSET and TERRAIN_AMPLITUDE in main.cpp are set
by reading that, not derived at runtime, so the scene stays put between
changes. The tree seed was picked by eye to keep the cave mouth clear.

Where the cave ended up is sent to the client in main:cave, where benchmark 4's
camera goes in main:water, and which tree benchmarks 5 to 7 look at in main:tree, so
none of those can drift out of sync with what was generated. Benchmark 4's
camera is worked out on the server rather than the client because it needs the
terrain height around the pond to stay above ground; benchmarks 5 to 7 are
worked out on the client because they need the sun direction, which lives
there. VIEW_DIR is the one thing still
duplicated between main.cpp and client_lua/init.lua, and has to be changed in
both: the server carves along it and benchmark 1 looks along it.
