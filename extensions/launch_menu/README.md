Buildat: extension/launch_menu
=========================

The launch menu the client shows when it is started with nothing to connect
to: Home with the recent games, a list for each kind (apps, saves,
servers, catalogs) and a typed search over them all. It runs in the
sandbox. screens.lua holds the local game list, the connecting screens
and the screens shown while a local server starts; every launch UI
starts its games through it (client/launch_grid.lua runs it). `res/` here is
also where the shared UI style lives, which is why several extensions refer to
`launch_menu/res/`.

Resource files:
* res/icon_network.png - http://flaticons.net/customize.php?dir=Application&icon=Network-01.png
* res/icon_local.png - part of buildat, under the same Apache 2.0 license
