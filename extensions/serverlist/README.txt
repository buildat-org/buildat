serverlist
==========

The fetched server list, as launch actions. This extension has no screen
of its own: it fetches the list of servers this client knows about,
keeps the busiest twelve in a file, and offers them to whatever launch
UI is running -- the launch grid's tiles, the room's mirrors on the
floor -- through launcher/init.lua, like any other launcher file.

Launching one hands its address to luanti_client, which opens its
connect dialog on it. Nothing in that extension changed to make this
work: its on_untrusted_launch has taken an address all along.

    <user>/serverlist/serverlist.csv    address|name|players, one per line

Why a cache and not a fetch
---------------------------

The launch grid is built at boot, before a fetch can finish, so a
launcher file cannot wait for one. The rows a launch UI draws are the last
fetch's, and asking for them starts the next.

The player asks first
---------------------

A boot fetches only where this client has already accepted the host, so
a first-time user is not met with a permission dialog before they have
asked anything of the network. The list's own launch action -- "Fetch
the server list" -- is where the asking happens, and the permission is
the same one a socket goes through.

What a launch action says about itself
--------------------------------------

Each row is category = "server" with the player count as its
significance ([LAUNCH_SIGNIFY]), which is what lets a launch UI rank
and scale it without knowing what a server is. The room draws them as
mirrors and drops one of its own placeholder mirrors for each real
one that arrived.

Running its check
-----------------

    extensions/serverlist/check.sh

It serves a list of its own on a port of its own, so no run asks
servers.luanti.org for anything. What it asserts: the fetch caches, the
rows reach a launch UI as ranked actions, the room's placeholders
give way, and a client with no answer on file fetches nothing and shows no
dialog.

    BUILDAT_SERVERLIST_URL   the list to ask, for a check's own list
