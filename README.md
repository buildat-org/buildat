![Buildat](client/data/buildat_logo.png)

Buildat
=======
A small engine and platform for networked 3D apps and games. The engine:
the server runs C++ modules it compiles at runtime; the client runs the
app's Lua in a sandbox, sent by the server, so joining a server is all a
player installs. The platform: a public server list and login
(Starport), signed apps (Aitta) and forums (Hearth) -- apps on the same
engine, which anyone can run.

What runs on it:

* **Luanti games** -- `apps/vanilla` runs a Luanti game and world
  (VoxeLibre and others, installed from ContentDB) inside buildat_server,
  and `extensions/luanti_client` plays on a real Luanti server.
* **A web client** -- every server serves a browser client on its own
  port.
* **Starport** (`apps/starport`, https://starport.buildat.org) -- a public
  server list and an optional login, the Starport ID. Both are opt-in and
  designed with privacy in mind; see [doc/starport.txt](doc/starport.txt).
* **Aitta** (`apps/aitta`) -- a registry of signed apps that a server
  installs.
* **Hearth** (`apps/hearth`) -- a forum.
* **Floorplanner** (`apps/floorplanner`).
* Voxel demos: `apps/digger` (a finite world), `apps/infidigger` (an
  infinite one).

Download a build for Linux or Windows from
[Releases](https://github.com/celeron55/buildat/releases), or build it
as below. More at https://www.buildat.org.

The apps
--------
Each directory in `apps/` is an app: pick it in the launch menu, or run
`bin/buildat_server -m ../apps/<name>`. An app says what it is in
`main/meta.json`'s `"kind"` -- world, arena, app, other, experiment or
check -- and the launch menu's "Local app" list is grouped by it; a
Starport listing takes it as its kind unless `starport.json` names one.

* Games (world, arena): `vanilla` (Luanti games), `digger`, `infidigger`,
  `bomber_drone` (a drone over infidigger's terrain), `minigame`,
  `vanilla_voxel_physics` (vanilla with voxel bodies that fall).
* Apps: `starport`, `aitta`, `hearth`, `floorplanner`.
* Other: `play`, which serves the web client and has no game of its own:
  its page starts on the launch menu (a Starport lists its origin in
  `web_clients`, doc/starport.txt).
* Experiments, not developed now: `undermine` (digger's world, which
  collapses), `aggregate` (undermine's world made of mixtures) and
  `aggregate_look`.
* Checks and test scenes: `box_test` (a hostile app the server's
  sandbox must contain), `voxel_lighting`, `multisection_lighting`,
  `voxel_physics`, `geometry`, `geometry2`, `entitytest`, `featuretest`,
  `uitest`, `test`.

Further reading:

* [doc/architecture.txt](doc/architecture.txt) -- what the engine is made of:
  client, server, modules, extensions, the launch grid, the network, voxels
* [doc/conventions.txt](doc/conventions.txt) -- coding style, naming, commit
  messages, coordinates
* [doc/client_api.txt](doc/client_api.txt) -- the Lua API an app's client
  code and an extension see
* [doc/client_commands.txt](doc/client_commands.txt) -- driving the client from
  a command file: keys, mouse, look, screenshot, the scan events
* [doc/luanti_module.txt](doc/luanti_module.txt) -- builtin/luanti: a Luanti
  app running inside buildat_server, and how it is checked
* [doc/luanti_client.txt](doc/luanti_client.txt) -- extensions/luanti_client:
  playing on a real Luanti server over its own protocol
* [doc/aitta.txt](doc/aitta.txt) -- an app packed, signed, published to an
  Aitta registry (apps/aitta) and installed
* [doc/starport.txt](doc/starport.txt) -- the server list and the Starport
  ID: what is opt-in, and what a Starport holds
* [doc/hearth.txt](doc/hearth.txt) -- apps/hearth, a forum: its HTML
  face, the client's requests, its limits, its variables and its check
* [doc/magic.txt](doc/magic.txt) -- Magic, Buildat's fork of Urho3D 1.7.1:
  what it carries that Urho3D does not
* [doc/developer_notes.txt](doc/developer_notes.txt) -- small things worth
  knowing when working on the engine
* [doc/whynot.txt](doc/whynot.txt) -- decisions against, and why

Buildat Linux How-To
====================

Install dependencies
----------------------

	$ # A compiler and cmake, plus the X, sound and GL headers Magic needs
	$ sudo apt-get install build-essential cmake \
	        libx11-dev libxrandr-dev libasound2-dev libgl1-mesa-dev \
	        libcurl4-openssl-dev
	$ sudo dnf install gcc-c++ cmake \
	        libX11-devel libXrandr-devel alsa-lib-devel mesa-libGL-devel \
	        libcurl-devel

The server also needs a C++ compiler at run time, not just at build time: it
compiles app modules as it loads them. It looks for `c++` in PATH.

Build
-------

Magic, Buildat's fork of Urho3D 1.7.1 (doc/magic.txt), is bundled in
`3rdparty/Urho3D` and is configured/built as part of
this project (shared library, Lua, safe Lua). `-DURHO3D_LIB_TYPE=SHARED` is
required for the module interface.

    $ cd $wherever_buildat_is
    $ mkdir Build  # Capital B is a good idea so it stays out of the way in tabcomplete
    $ cd Build
    $ cmake .. -DCMAKE_BUILD_TYPE=Debug
    $ make -j4

You can use -DBUILD_SERVER=false or -DBUILD_CLIENT=false if you don't need the
server or the client, respectively.

`-DPORTABLE=TRUE`, the default, keeps the cache and the user's own things
beside the program, in `cache/` and `user/`. That is what development wants.
`-DPORTABLE=FALSE` puts them where the platform says instead
(`$XDG_DATA_HOME/buildat` and `$XDG_CACHE_HOME/buildat` on Linux,
`%APPDATA%\buildat` and `%LOCALAPPDATA%\buildat\cache` on Windows,
`~/Library/Application Support/buildat` and `~/Library/Caches/buildat` on
macOS), which is what an installed copy wants. A portable build does the
same when a file named `installed` is beside its executable, as the Windows
installer puts it. `-C` and `-D` override either.

The build compiles through ccache when it finds one (not the web build);
`-DBUILDAT_CCACHE=OFF` goes without.

Optional: `-DURHO3D_LUAJIT=TRUE` builds the bundled LuaJIT instead of Lua.
`URHO3D_HOME` still overrides the bundled tree if you need an external build.

### The web client

A server also serves a client for web browsers, on its own port: open
`http://<server>:<port>/` and it connects back to the server it came from.
It is built separately, with
[emsdk](https://emscripten.org/docs/getting_started/downloads.html) 3.1.60:

    $ ~/emsdk/emsdk install 3.1.60 && ~/emsdk/emsdk activate 3.1.60
    $ util/build_web.sh

It builds in `Build-web/` and writes `web/`, which the server serves from by
default; `buildat_server -W <dir>` serves another. Behind an https reverse
proxy the page connects over wss. Its address takes `?log=4` for a verbose
log, `scale=` for the UI scale and `pref=<key>=<value>` (repeatable), and
nothing else of the command line: a link is anybody's to write. The server accepts a WebSocket only from its
own page's origin.

Play
----

    $ $wherever_buildat_is/Build/bin/buildat

The launch menu: a local app, a server to connect to, or one of the
extensions that can be launched on their own -- a Luanti client, so far.
Arrows or the mouse to pick, enter to go.

Keys, in any app -- F9 to F12 are the client's, every other key the
app's, and no script hears these four:

* F9: the client's own overlay -- the Starport trust colour, the IDs
  logged in and a three-character code at its bottom left -- on and off.
  It is shown whenever the launcher comes up and hidden when a game
  starts. No script hears F9, so an overlay that does not go away on it
  is not the client's. The same code is in the window title and at the
  top right of every Starport field; no script can read it.
* F10: on-screen profiler, render and resource stats; Ctrl+F10: draw
  physics debug geometry
* F11: fullscreen on and off
* F12: a screenshot under the user path's `screenshots`; Ctrl+F12: the
  sandbox test extension

Engine settings
---------------

What the user sets once and every app honours: `render_scale` (3D viewports
drawn at a fraction of the window size, with the UI left at native
resolution), `vsync`, `max_fps`, `multisampling`, `sound_volume`,
`sound_mute`, and `default_username`, the name an app offers when it asks for
one. They live in `user/settings.json` beside the remembered
window size; the launch menu's Settings, "Display and sound", edits them, or set
them for one run with `-o`, which is not written back:

    $ bin/buildat -o render_scale=0.5,vsync=0,sound_mute=1

`user/` is where what the user made, chose or downloaded deliberately goes, as
against `cache/`, which is what the program can recreate by itself. In the
default portable build both sit in the buildat directory; `-D` and `-C` move
them, and `-DPORTABLE=FALSE` puts them where the platform says (see Build).

See [doc/client_api.txt](doc/client_api.txt) for what an app does to honour
`render_scale`, and what the client does not get to decide.

Saves
-----

An app can persist its world. `apps/digger` does: it opens or creates the
save `user/apps/digger/saves/world`, and what you dig is there next time.
Delete that directory to start over. Every other app generates and forgets,
which is what they did before saves existed -- persistence is opt-in, and an
arena game whose world is gone when the match ends should not have one.

Behind it is a key-to-blob store per save, in one vendored SQLite database,
namespaced per module. See `builtin/storage/api.h`.

Server and client
-----------------

For development or hosting, run the two binaries separately:

Terminal 1:

    $ $wherever_buildat_is/Build
    $ bin/buildat_server -m ../apps/minigame

Terminal 2:

    $ $wherever_buildat_is/Build
    $ bin/buildat -s localhost

A game started from the launcher listens on 127.0.0.1 only, and the
launcher's client is its owner by a token the two share; apps/vanilla's
pause menu has "Open to LAN", which opens it to the network. A dedicated
server announces itself to the LAN with `--lan-announce NAME` (or
`BUILDAT_LAN_ANNOUNCE`), and the launcher's connect screen lists what it
hears under "On this network". `--compile-only` compiles and loads the
app's modules and exits, 1 naming the module that failed: for a run whose
clock a first compile would eat.

A server with no admin logs a setup code, and the first to join with it
becomes the admin. A script that makes a server names the admin instead
in `<user>/first_admin`, one line, read at the next start and removed:
`name <name> <password>` makes that account the admin, and `code <code>`
(8 or more characters) is the setup code in place of the log's, for a
Starport ID's join too. On a server that has an admin it is ignored.

A server's user directory (`-D`) is the whole of it: saves, accounts,
the Starport listing's secret, installed Aitta apps. It holds no absolute
paths, so a copy runs on another machine as it is (the old one stopped,
or both announce the same listing). Stopped, `cp -a` or a zip copies it.
Running: write an empty `<user>/apps/<app>/save_now`; the server saves
what its games hold and removes the file, and a filesystem or VM
snapshot taken after it loses nothing. A plain copy of a running server
can still catch a save's SQLite database apart from its `-wal`; stop it
for that. The secrets in it: `apps/<app>/saves/_server` (password
hashes, TOTP secrets, the SMTP password), `starport_state.json` and
`starport_claim.txt` (the listing), `health_token.txt`.

On Linux the server confines itself before it loads an app (Landlock and
seccomp): the app writes `<user>/apps/<app>`, its own `<user>/shared/<app>`
and its own cache, reads the install and the other apps' shared
directories, and reaches nothing else of yours. It binds TCP only on its
own port and connects only to ports 80, 443, 465, 587, 29500 and 29595,
plus what `--connect-ports`, `BUILDAT_CONNECT_PORTS` or a line in
`<user>/connect_ports` adds ("any", or "8080,30000"): the
services on 127.0.0.1 are other programs of yours. Where the kernel cannot
make the sandbox the server refuses to start; `--unconfined` (or
`BUILDAT_UNCONFINED=1`) runs it without one. `apps/box_test/check.sh` is
the check.

On Windows (8 or newer) the server restarts itself inside a per-app
AppContainer with a job object, with the same directories. A local
client joins it by a named pipe, since an AppContainer cannot reach
loopback; other players connect over the network as before. A server
started with no desktop, from a service or an SSH login, cannot be
sandboxed yet and says so. `BUILDAT_WINDOWS_SANDBOX=0` turns the sandbox
off. A container has no port rules: a sandboxed server connects to any
host and port until an administrator runs `bin\sandbox_firewall.ps1`
(`-ConnectPorts 8080,30000` for more), which gives each app's sandbox the
Linux ports by a firewall rule. An app's sandbox is made at its first
sandboxed start; the script is run again after it.

Client command sequence (CI / visual checks)
--------------------------------------------

The client can run a one-shot command script and exit. Screenshots, delays,
and injected keyboard/mouse input:

    $ bin/buildat -c $'delay 2000\nscreenshot /tmp/menu.png'
    $ bin/buildat -c @commands.txt

See [doc/client_commands.txt](doc/client_commands.txt).

Modify something and see stuff happen
---------------------------------------

Edit something and then restart the client (CTRL+C in terminal 2):

    $ cd $wherever_buildat_is
    $ vim apps/minigame/main/client_lua/init.lua
    $ vim apps/minigame/main/main.cpp
    $ vim builtin/network/network.cpp

The server can do that part for you while you develop: `-R` makes it restart
a module when its source changes, and `-w` pushes an edited client script to
the clients that have it. Both are off by default -- a restart throws away
whatever the module was holding, and neither belongs in a run whose output
is being measured.

Buildat Windows How-To
======================

The Windows build is a cross build from Linux, made in a container
(Docker):

    $ util/package_in_docker.sh windows

It writes `Build/package/out/buildat-<version>-<hash>-win64.zip`, which
carries the compiler the server needs at run time. Unpack it and run
`bin\buildat.exe`. A native build on Windows (MSYS2, Mingw-w64) is not
tested.

It also writes `buildat-<version>-<hash>-win64-setup.exe` (NSIS,
`util/installer.nsi`): the same build installed for the user alone, no
admin, to `%LOCALAPPDATA%\Programs\Buildat`, with a Start menu entry and
an uninstaller in Add/Remove Programs. The installed copy keeps its data
in `%APPDATA%\buildat` and `%LOCALAPPDATA%\buildat\cache`; the uninstall
leaves them. Neither is signed, so Windows names no publisher.

A crash on Windows writes a minidump into the cache,
`crash-<exe>-<time>.dmp` (the newest five kept, the sandboxed server's
too), and the launcher says so at the next start.
