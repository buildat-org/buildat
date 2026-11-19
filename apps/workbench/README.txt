Workbench is a blank app that only hosts Kit and its editor ([KIT],
doc/plan's kit_plan.md). It has Kit's World (kit/terrain: a new game gets
a gentle grassland heightmap 64 cells on a side, an older one a flat
stone floor; the generator, size, surface and biomes are set in the
editor), Kit's starter set of components (builtin/kit/types/) to place,
set and link in the editor (F6), and voxels to build with: Kit's
material set, Workbench's own, and voxel types the builders make with the
editor's "New voxel type..." (a texture, solid, transparent, light,
friction and a surface tag for what moves on it). main/main.cpp
describes how it plays.

Its saves are games. Manage (builtin/world_menu) has New, Rename, Delete
and Open; the launcher's "New Workbench game", "Manage Workbench games"
and a game's "Manage..." open it. In a running game, an admin's pause
menu has Games...: the same list with the running game marked. Play on
another game switches the server to it, and Close game leaves none
running (util/workbench_switch_project_check.sh).

New's "Start from" lists Empty, then the templates here in templates/,
then the installed templates (doc/aitta.txt, Templates). Each directory
in templates/ is a package: meta.json (kind "template"),
composition.json and its own LICENSE. Being in this tree, it works with
no Aitta in reach, and it changes in the same commit as the Kit
components it uses. util/kit_templates_check.sh plays each one to its
end, and util/pack_templates.sh packs them for an Aitta with the
caller's key.

A game moves between servers as a template [KIT_PROJECT_EXPORT]. The
editor's palette has Export this game in its New tab (for builders), and
Games... has it and Publish this game... in its right column for the
running game. Export saves the game's start (what Stop goes back to,
without round state or kept state) as <name>.template.zip: a download on
the web, and a file in <user>/exports natively. New's "Start from", From
a file..., makes a game from one; Games...' Import a game from a file...
opens New with it picked (the browser's file picker, or <user>/exports
natively). The file is checked as an installed template is, and the game
opens Stopped in the editor. The zip is a template package
(doc/aitta.txt, Templates), with all rights reserved by the exporting
account; what it carries and leaves out is described at
[KIT_PROJECT_EXPORT] in builtin/kit/kit.cpp. Manage's Copy... copies a
whole game with its save as it is, a running round and kept state
included. To add an export to this tree and keep a template's own
meta.json and LICENSE (a new template takes the export's and edits
them):

        unzip -o X.template.zip -x meta.json LICENSE -d templates/<name>/

The server can publish as itself [KIT_SERVER_PUBLISH]. The Server
window's Admin / Publishing makes the server's key (one, kept in its
data), lists the Aittas it publishes to and installs from, gives
builders the right to publish as the server, shows the log of who
published what, and installs a template from a listed Aitta into Start
from. A builder with the right publishes a game, a scene or their
prefabs "As this server" from the editor (the only way in the web
client), and the release names their account (doc/aitta.txt, Publishing
as the server; util/kit_server_publish_check.sh).

A builder's own agentic tool (Claude Code, Codex, Cursor, Gemini CLI...)
edits a game through MCP ([KIT_AGENTS]). The pause menu's My account,
Connect an agent..., makes a token (Builder, or Admin for an admin). It
is shown once, in a block to copy, with the server's address, a
`claude mcp add` line and an MCP config; the page lists the tokens with
their last use and a Revoke button. The tool then reaches POST
/api/v1/mcp on the server's port as "<name>'s agent", with that
account's rights; its edits go into the live round and are logged as the
agent's. Its guide, made from the server's own types, is in the MCP
initialize answer (get_guide gives all of it). The tools and the rules
are described at [KIT_AGENTS] in builtin/kit/kit.cpp. The admin turns
agents off on the Accounts page (util/kit_agents_check.sh).
export_template returns the game's export as text (edits.bin and
textures in base64). list_games, copy_game and rename_game are Manage's
actions, so only an admin's agent can use them, with an Admin token (or a
sign-in with the Host's actions allowed), and the running game cannot be
renamed (util/kit_project_export_check.sh).

A tool that signs in by OAuth (claude.ai's or ChatGPT's connectors) needs
only the URL, https://wb.example.org/api/v1/mcp. It finds the server's
sign-in by MCP's authorization spec, and the sign-in page at
/api/v1/oauth/authorize takes the account's password (and TOTP code) or a
Starport ID the server is listed for, then Allow. An admin gets one more
step, an unticked box "Also allow the Host's actions (games: list, copy,
rename...)": the grant is Admin with it ticked and Builder without,
whatever the tool asked for, and connecting the tool again asks again.
The tool gets an agent token of the account, listed and revoked like the
others ([KIT_AGENTS_OAUTH] in builtin/accounts/accounts.cpp;
util/kit_agents_oauth_check.sh). Behind a proxy on the same machine
(web_trusted_proxies), the sign-in answers only under a loopback name, an
IP address or the server's Public address (Starport settings;
starport.json's "address": "https://wb.example.org"), so that a page
whose name was rebound to 127.0.0.1 gets nothing. A hosted server sets
the address, and its proxy passes Host, X-Forwarded-For and
X-Forwarded-Proto.

An agent sees what it built with get_view ([KIT_AGENT_VISUALS] in
builtin/kit/kit.cpp). A client of the agent's own account, connected to
the server, draws a camera of its own (a pose, or that client's view)
off-screen and sends a PNG, which the agent gets as MCP image content.
The client's window is left as it is and shows "Your agent took a
picture". The scene drawn is the one that client is in, as far as it has
loaded it. No other account's client is asked. With no client of the
account there, the agent runs one itself. That client logs in with an
agent token from -T <token> or BUILDAT_AGENT_TOKEN, and neither logs nor
saves it. A builder token works only for an account that is not a Host
or a Steward, an admin token for any account, and neither where that
account's own client is connected. On Linux with no display, the client
draws off-screen with SDL's offscreen driver: EGL with no X server, on
Mesa's software GL where there is no GPU:

    # Debian/Ubuntu: apt-get install libgl1 libegl1 libegl-mesa0 \
    #     libgl1-mesa-dri libcurl4
    # from https://github.com/celeron55/buildat/releases, the
    # linux-x86_64-portable archive, unpacked:
    cd buildat-*-linux-x86_64-portable
    BUILDAT_AGENT_TOKEN=bat_... SDL_VIDEODRIVER=offscreen \
        bin/buildat -s https://wb.example.org -w 640x480 -o sound_mute=1

The token is a bat_ token from My account, Connect an agent...; a
sign-in's (OAuth) token stays inside the tool that made it. The client
logs "Joined as <name>", and get_view then draws from it. Revoking the
token kicks the client (util/kit_get_view_check.sh).

Licenses of textures and other media:
------------------------------------
main/client_data/*.png, launcher/icon.png
(Kit's voxel textures: builtin/kit/README.txt)
- CC BY-SA 4.0 2026 Perttu Ahola <celeron55@gmail.com>
