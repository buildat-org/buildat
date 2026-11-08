Workbench: the blank app that only hosts Kit and its editor ([KIT],
doc/plan's kit_plan.md). Kit's World (kit/terrain: a new project's a
gentle grassland heightmap 64 cells a side, an older one's a flat stone
floor; its generator, size, surface and biome set in the editor),
Kit's starter set of components (builtin/kit/types/) to place, set and link
in the editor (F6), and the voxels to build with (Kit's material set,
Workbench's own, and the builders' own voxel types, made in the editor's
"New voxel type...": a texture, solid, transparent, light, and friction
and a surface tag for what moves on it). main/main.cpp says how it plays.
Its saves are projects: New, Rename, Delete and Open in Manage
(builtin/world_menu), which the launcher's "New workbench project",
"Manage workbench projects" and a project's "Manage..." open. In a
running project an admin's pause menu has Projects...: the same list, the
running project marked, its Play on another switching the server to it
and Close project leaving none running (util/workbench_switch_project_check.sh).

New's "Start from" is Empty, then templates/ here, then the templates
installed (doc/aitta.txt, Templates). Each directory in templates/ is a
package: meta.json (kind "template"), composition.json, its own LICENSE. It
works with no Aitta in reach, being in this tree, and changes in the same
commit as the Kit components it uses; util/kit_templates_check.sh plays each
to its end, and util/pack_templates.sh packs them for an Aitta with the
caller's key.

Licenses of textures and other media:
------------------------------------
main/client_data/*.png, launcher/icon.png
(Kit's voxel textures: builtin/kit/README.txt)
- CC BY-SA 4.0 2026 Perttu Ahola <celeron55@gmail.com>
