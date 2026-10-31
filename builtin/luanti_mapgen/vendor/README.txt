Luanti's mapgen, vendored, and the shim under it
================================================

The files here are either Luanti's own, copied without changes, or a shim
written for this module. The shims are what let Luanti's mapgen compile
against buildat instead of against Luanti's engine; they answer the small
part of Luanti's headers that the mapgen actually uses, and no more.

They sit in the same directory as the vendored code on purpose: a
runtime-compiled module gets no include directories of its own, and a
quoted #include looks beside the file that wrote it.

Luanti's own, unchanged (upstream: git master, 2026-09):

    voxel.h, voxel.cpp                  <- compiled
    noise.h, noise.cpp                  <- compiled (replaced an adapter
                                           over buildat's noise in 2026-10,
                                           which made other terrain and
                                           ores; [MAPGEN_DENSITY])
    objdef.h, objdef.cpp                <- vendored, not yet compiled
    mapgen.h, mapgen.cpp                <- vendored, not yet compiled
    mapgen_singlenode, _v5, _v6, _v7, _flat, _fractal, _valleys,
        _carpathian                     <- vendored, not yet compiled
    mg_biome, mg_ore, mg_decoration, mg_schematic,
        cavegen, dungeongen, treegen    <- vendored, not yet compiled
    util/serialize.h, util/serialize.cpp, util/hex.h, util/ieee_float.*
                                        <- vendored, not yet compiled

Changed from upstream, each marked "buildat:" where it is
-------------------------------------------------------------

    mg_schematic.h/.cpp, mg_decoration.h/.cpp  [MCL_GEN_NONDETERMINISTIC]
        Schematic::blitToVManip() takes the PcgRandom it rolls the slice
        and node probabilities with; DecoSchematic::generate() passes one
        seeded from the world's seed and the placement. Upstream rolls
        them with myrand(), one generator for the process (here rand()),
        so the same chunk came out differently between runs and within
        one. The other callers leave it out and get myrand(); Lua's
        core.place_schematic*() are builtin/luanti/lua/stubs.lua's own,
        rolled with math.random as upstream's are with myrand().

Where the port stopped (2026-09-13)
-----------------------------------

luanti_mapgen.cpp compiles the bottom of the tree: the voxel manipulator,
the serialization helpers and the node definitions, all
with the shims under them. What is left out of that list is the generators
themselves and the four managers.

They are much closer than that sounds. With every .cpp in the list,
`mapgen.cpp` and `objdef.cpp` compile clean; the 62 errors that remain are
all in the managers and all of the same kind -- a shim that is missing a
member. The ones the compiler named, in the order it named them:

    myrand_range(min, max)                  util/numeric.h
    MapNode::rotateAlongYAxis()             mapnode.h
    getNodeBlockPos(v3s16)                  util/numeric.h
    NodeResolver::reset()                   nodedef.h
    ServerMap forward-declared globally     voxelalgorithms.h says
                                            voxalgo::ServerMap and means ::
    v3s16 + v3f in cavegen.cpp:467 and 783  irr_v3d.h: the mixed-type
                                            operator+ is there and still
                                            does not match -- look at what
                                            `of` and `rs` really are

mapgen.cpp cannot be compiled without mg_biome.cpp, because it names
BiomeParamsOriginal's vtable; so the set goes in together or not at all,
which is why the includes are where they are.

After the managers compile, what is left before a generated world:

 1. A translation between MMVManip and interface::VoxelVolume, which is a
    loop: both are flat arrays over a box in the same order, and a MapNode
    is what VoxelFormat::luanti() binds.
 2. Filling a NodeDefManager from the content ids luanti_mapgen/api.h
    already carries across, plus the few ContentFeatures fields a mapgen
    reads -- which builtin/luanti has and does not send yet.
 3. A MapgenParams with the seed and the water level, and
    Mapgen::createMapgen() behind create_generator().

Two things that are known and not done: a .mts schematic file is not read
(serialization.cpp says why), and Schematic::placeOnMap() has a ServerMap
that does nothing, which is where a mod's core.place_schematic() will land.
