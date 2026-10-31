Workbench: the blank app that only hosts Kit and its editor ([KIT],
doc/plan's kit_plan.md). Kit's World (kit/world: a flat stone floor 64
cells a side by default, its generator, size and biome set in the editor),
Kit's starter set of components (builtin/kit/types/) to place, set and link
in the editor (F6), and the voxels to build with (Kit's material set,
Workbench's own, and the builders' own voxel types, made in the editor's
"New voxel type...": a texture, solid, transparent, light, and friction
and a surface tag for what moves on it). main/main.cpp says how it plays.
Its saves are projects: New, Rename, Delete and Open in Manage
(builtin/world_menu), which the launcher's "New workbench project",
"Manage workbench projects" and a project's "Manage..." open.

Licenses of textures and other media:
------------------------------------
main/client_data/*.png, launcher/icon.png
(Kit's voxel textures: builtin/kit/README.txt)
- CC BY-SA 4.0 2026 Perttu Ahola <celeron55@gmail.com>
