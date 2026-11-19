Workbench: the blank app that only hosts Kit and its editor ([KIT],
doc/plan's kit_plan.md). Kit's World (kit/terrain: a new game's a
gentle grassland heightmap 64 cells a side, an older one's a flat stone
floor; its generator, size, surface and biome set in the editor),
Kit's starter set of components (builtin/kit/types/) to place, set and link
in the editor (F6), and the voxels to build with (Kit's material set,
Workbench's own, and the builders' own voxel types, made in the editor's
"New voxel type...": a texture, solid, transparent, light, and friction
and a surface tag for what moves on it). main/main.cpp says how it plays.
Its saves are games: New, Rename, Delete and Open in Manage
(builtin/world_menu), which the launcher's "New workbench game",
"Manage workbench games" and a game's "Manage..." open. In a
running game an admin's pause menu has Games...: the same list, the
running game marked, its Play on another switching the server to it
and Close game leaving none running (util/workbench_switch_project_check.sh).

New's "Start from" is Empty, then templates/ here, then the templates
installed (doc/aitta.txt, Templates). Each directory in templates/ is a
package: meta.json (kind "template"), composition.json, its own LICENSE. It
works with no Aitta in reach, being in this tree, and changes in the same
commit as the Kit components it uses; util/kit_templates_check.sh plays each
to its end, and util/pack_templates.sh packs them for an Aitta with the
caller's key.

A game moves between servers as a template [KIT_PROJECT_EXPORT]: the
editor's palette, New tab, Export this game (a builder's; Games...' right
column has it and Publish this game... for the running game) saves its
start (what Stop goes back to: no round state, no kept state) as
<name>.template.zip, a download on the web and <user>/exports natively;
New's "Start from", From a file... (Games...' Import a game from a
file... opens New with it picked; the browser's picker, natively
<user>/exports) makes a game of one, checked as a template's install is,
opened Stopped in the editor. The zip is a template package (doc/aitta.txt,
Templates), all rights reserved by the exporting account; what it carries
and leaves out: [KIT_PROJECT_EXPORT] in builtin/kit/kit.cpp. Manage's
Copy... copies a game whole, its save as it is (a running round and kept
state with it). Into this tree, keeping a template's own meta.json and
LICENSE (a new one takes the export's and edits them):

        unzip -o X.template.zip -x meta.json LICENSE -d templates/<name>/

The server publishes as itself [KIT_SERVER_PUBLISH]: the Server window's
Admin / Publishing makes its key (one, kept in its data), lists the Aittas
it publishes to and installs from, gives builders the right to publish as
it, shows the log of who published what, and installs a template from a
listed Aitta into Start from. A builder with the right publishes a game,
a scene or their prefabs "As this server" from the editor (the web
client's only way), their account named in the release (doc/aitta.txt,
Publishing as the server; util/kit_server_publish_check.sh).

A builder's own agentic tool (Claude Code, Codex, Cursor, Gemini CLI...)
edits a game through MCP ([KIT_AGENTS]): the pause menu's My account,
Connect an agent... makes a token (Builder, or Admin for an admin), shown
once in a block to copy with the server's address, a `claude mcp add` line
and an MCP config; the page lists the tokens with their last use and
Revoke. The tool then reaches POST /api/v1/mcp on the server's port as
"<name>'s agent", with that account's rights, its edits in the live round
and logged as the agent's. Its guide, made from the server's own types, is
in the MCP initialize answer (get_guide gives it whole). The tools and the
rules: [KIT_AGENTS] in builtin/kit/kit.cpp. The admin turns it off on the
Accounts page (util/kit_agents_check.sh). export_template answers the
game's export as text (edits.bin and textures base64); list_games,
copy_game and rename_game are Manage's, so an admin's agent with an
Admin token (or a sign-in with the Host's actions allowed) only, and the
running game is not renamed
(util/kit_project_export_check.sh).

A tool that signs in by OAuth (claude.ai's or ChatGPT's connectors) needs
only the URL, https://wb.example.org/api/v1/mcp: it finds the server's
sign-in by MCP's authorization spec, and its page at /api/v1/oauth/authorize
takes the account's password (and TOTP code) or a Starport ID the server is
listed for, then Allow. An admin then has a step of its own, a box "Also
allow the Host's actions (games: list, copy, rename...)", unticked: the
grant is Admin with it ticked and Builder without, whatever the tool asked
for; connecting the tool again chooses again. What the tool gets is an
agent token of the account, listed and revoked as the others ([KIT_AGENTS_OAUTH] in
builtin/accounts/accounts.cpp; util/kit_agents_oauth_check.sh). Behind a
proxy on the same machine (web_trusted_proxies), the sign-in answers only
under a loopback name, an IP address or the server's Public address
(Starport settings; starport.json's "address": "https://wb.example.org"),
so that a page whose name was rebound to 127.0.0.1 gets nothing: a hosted
server sets it, the proxy passing the Host, X-Forwarded-For and
X-Forwarded-Proto.

An agent sees what it built with get_view ([KIT_AGENT_VISUALS] in
builtin/kit/kit.cpp): a client of its own account connected to the server
draws a camera of its own (a pose, or that client's view) off-screen and
sends a PNG, which the agent gets as MCP image content; the client's
window is left as it is and shows "Your agent took a picture". The scene
drawn is the one that client is in, as far as it has loaded it. No other
account's client is asked. With no client of the account there, the agent
runs one itself: a client logs in with an agent token (the token's
account; a builder token only for an account that is no Host and no
Steward, an admin token for any; never where that account's own client
is) from -T <token> or BUILDAT_AGENT_TOKEN, neither of which it logs or
saves, and on Linux with no display it draws off-screen with SDL's
offscreen driver: EGL with no X server, on Mesa's software GL where
there is no GPU:

    # Debian/Ubuntu: apt-get install libgl1 libegl1 libegl-mesa0 \
    #     libgl1-mesa-dri libcurl4
    # from https://github.com/celeron55/buildat/releases, the
    # linux-x86_64-portable archive, unpacked:
    cd buildat-*-linux-x86_64-portable
    BUILDAT_AGENT_TOKEN=bat_... SDL_VIDEODRIVER=offscreen \
        bin/buildat -s https://wb.example.org -w 640x480 -o sound_mute=1

The token is a bat_ one from My account, Connect an agent...; a sign-in's
(OAuth) stays inside the tool that made it. The client says "Joined as
<name>" in its log; get_view then draws from it. Revoking the token kicks
the client (util/kit_get_view_check.sh).

Licenses of textures and other media:
------------------------------------
main/client_data/*.png, launcher/icon.png
(Kit's voxel textures: builtin/kit/README.txt)
- CC BY-SA 4.0 2026 Perttu Ahola <celeron55@gmail.com>
