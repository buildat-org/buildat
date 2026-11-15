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

A project moves between servers as a template [KIT_PROJECT_EXPORT]: the
editor's palette, New tab, Export this project (a builder's) saves its
start (what Stop goes back to: no round state, no kept state) as
<project>.template.zip, a download on the web and <user>/exports natively;
New's "Start from", From a file... (the browser's picker, natively
<user>/exports) makes a project of one, checked as a template's install is,
opened Stopped in the editor. The zip is a template package (doc/aitta.txt,
Templates), all rights reserved by the exporting account; what it carries
and leaves out: [KIT_PROJECT_EXPORT] in builtin/kit/kit.cpp. Manage's
Copy... copies a project whole, its save as it is (a running round and kept
state with it). Into this tree, keeping a template's own meta.json and
LICENSE (a new one takes the export's and edits them):

        unzip -o X.template.zip -x meta.json LICENSE -d templates/<name>/

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
Accounts page (util/kit_agents_check.sh). export_template answers the
project's export as text (edits.bin and textures base64); list_projects,
copy_project and rename_project are Manage's, so an admin's agent with an
Admin token only, and the running project is not renamed
(util/kit_project_export_check.sh).

A tool that signs in by OAuth (claude.ai's or ChatGPT's connectors) needs
only the URL, https://wb.example.org/api/v1/mcp: it finds the server's
sign-in by MCP's authorization spec, and its page at /api/v1/oauth/authorize
takes the account's password (and TOTP code) or a Starport ID the server is
listed for, then Allow. What the tool gets is an agent token of the account,
listed and revoked as the others ([KIT_AGENTS_OAUTH] in
builtin/accounts/accounts.cpp; util/kit_agents_oauth_check.sh). Behind a
proxy on the same machine (web_trusted_proxies), the sign-in answers only
under a loopback name, an IP address or the server's Public address
(Starport settings; starport.json's "address": "https://wb.example.org"),
so that a page whose name was rebound to 127.0.0.1 gets nothing: a hosted
server sets it, the proxy passing the Host, X-Forwarded-For and
X-Forwarded-Proto.

Licenses of textures and other media:
------------------------------------
main/client_data/*.png, launcher/icon.png
(Kit's voxel textures: builtin/kit/README.txt)
- CC BY-SA 4.0 2026 Perttu Ahola <celeron55@gmail.com>
