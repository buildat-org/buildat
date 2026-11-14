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

A builder's own agentic tool (Claude Code, Codex, Cursor, Gemini CLI...)
edits a project through MCP ([KIT_AGENTS]): the pause menu's My account,
Connect an agent... makes a token (Builder, or Admin for an admin), shown
once in a block to copy with the server's address, a `claude mcp add` line
and an MCP config; the page lists the tokens with their last use and
Revoke. The tool then reaches POST /api/v1/mcp on the server's port as
"<name>'s agent", with that account's rights, its edits in the live round
and logged as the agent's. Its guide, made from the server's own types, is
in the MCP initialize answer (get_guide gives it whole). The tools and the
rules: [KIT_AGENTS] in builtin/kit/kit.cpp. The admin turns it off on the
Accounts page (util/kit_agents_check.sh).

Licenses of textures and other media:
------------------------------------
main/client_data/*.png, launcher/icon.png
(Kit's voxel textures: builtin/kit/README.txt)
- CC BY-SA 4.0 2026 Perttu Ahola <celeron55@gmail.com>
