Buildat: extension/launch_menu
=========================

The launch menu the client shows when it is started with nothing to connect
to: Home with the recent ones, a list per kind (apps, saves, servers,
catalogs) and a typed search over them all. It runs in the sandbox. screens.lua is the local game list, connecting to
a server and the screens a local server starts behind, which every launch UI's
game starts go through (client/launch_grid.lua runs it). `res/` here is also
where the shared UI style lives, which is why several extensions refer to
`launch_menu/res/`.

Resource files:
* res/icon_network.png - http://flaticons.net/customize.php?dir=Application&icon=Network-01.png
* res/icon_local.png - part of buildat, under the same Apache 2.0 license
