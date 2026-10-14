bomber_drone
============
A fixed-wing drone over infinite voxel terrain. Terrain, worldgen and
rendering are digger's; the drone, the bombs and the two camera views are
this game's.

Controls:
  M          motor on/off
  W / S      pitch (S is nose up)
  A / D      roll
  Space      drop a bomb
  Esc        disconnect

The screen is split: the left view is a gimbal on an imaginary aircraft flying
ahead of the drone, the right one is fixed to the drone's nose.

At cruise speed the drone is close to outrunning terrain streaming: the
generation queue sits at its soft maximum, so a turn into unseen terrain can
still show the streaming edge for a moment before the chunks arrive.

Licenses of textures and other media:
------------------------------------
When not specified separately:
- CC BY-SA 3.0 2014 Perttu Ahola <celeron55@gmail.com>

main/client_data/grass.png
main/client_data/leaves.png
main/client_data/dirt.png
main/client_data/tree.png
main/client_data/tree_top.png
main/client_data/rock.png
- CC BY-SA 3.0 2013 PilzAdam <pilzadam@minetest.net>
