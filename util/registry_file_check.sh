#!/bin/bash
# tier: full
# cost: ~3 min (2026-10-12)
# covers: builtin/voxelworld/voxelworld.cpp builtin/voxelworld/client_lua/module.lua
# [REGISTRY_FILE]: the voxel registry is a file of client_file's.
#   1. Vanilla on VoxeLibre, a join with an empty cache: the server says
#      the file's size; the client reads the registry from the served
#      file. A second join with that cache asks for no file and reads it
#      again; the time from the announce to the world in is said (2.7 s
#      on the desk, 2026-10-12, before [LOADING_PIC_DECODE] took a second
#      off it).
#   2. aggregate_look with a voxel type added 8 s after a client joined (a
#      dirty registry): the joined client reads the file again, larger.
#   util/registry_file_check.sh
set -u
. "$(dirname "$0")/check_paths.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
G="$BUILDAT_USER_PATH/shared/vanilla/games/mineclone2"
[ -d "$G" ] || skip "no mineclone2"
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp registry_file; t=$CHECK_TMP
b="$here/Build/bin/buildat"

# 1.
mkdir -p "$t/srv/apps/vanilla/saves/rf/luanti" "$t/srv/shared/vanilla/games"
cp -r "$G" "$t/srv/shared/vanilla/games/"
echo "enable_damage = false" > "$t/srv/apps/vanilla/saves/rf/luanti/world.mt"
BUILDAT_LUANTI_GAME=mineclone2 BUILDAT_LUANTI_SAVE=rf start_server "$t/srv.log" \
	"STATUS Listening" 180 auto "$here/Build/bin/buildat_server" -u launcher=1 \
	-A 127.0.0.1 -m "$here/apps/vanilla" -D "$t/srv" -C "$t/srv.cache" -l 3 ||
	fail "the server ($t/srv.log)"
CHECK_PIDS+=($SERVER_PID)
# The delay: the player's join changes luanti's object_props file; quit
# before it came, the second join asks for it
printf "wait_log 300000 load: the world is in\ndelay 3000\nquit\n" > "$t/cmds"
for n in 1 2; do
	run_client 60 "$t/$n.log" timeout 300 "$b" -C "$t/c" -D "$t/u" -w 800x450 -l 3 \
		-o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$t/cmds"
	grep -aq "load: the world is in" "$t/$n.log" || fail "join $n not loaded ($t/$n.log)"
	grep -aq "voxelwor: the voxel registry from the served file, [0-9]* bytes" "$t/$n.log" ||
		fail "join $n: the registry not from the file ($t/$n.log)"
done
grep -a "The voxel registry served as" "$t/srv.log" | sed 's/.*voxelwor: //'
grep -aq "The voxel registry served as voxelworld/voxel_registry.bin: [0-9]* bytes" "$t/srv.log" ||
	fail "no size said ($t/srv.log)"
grep -aq "announced files are cached, [1-9][0-9]* asked for" "$t/1.log" || fail "join 1 asked for nothing ($t/1.log)"
grep -aq "announced files are cached, 0 asked for" "$t/2.log" || fail "join 2 asked for files ($t/2.log)"
grep -a "announced files are cached, [1-9]" "$t/2.log" && fail "join 2 asked for files ($t/2.log)"
python3 - "$t/2.log" <<'PY'
import re, sys
def secs(l):
    h, m, s = re.search(r"(\d\d):(\d\d):(\d\d\.\d+)", l).groups()
    return int(h) * 3600 + int(m) * 60 + float(s)
log = open(sys.argv[1], errors="replace").read().splitlines()
a = [secs(l) for l in log if "announced files are cached" in l][0]
w = [secs(l) for l in log if "vanilla : load: the world is in" in l][0]
print("join 2: the world in %.1f s after the announce" % (w - a))
PY
echo "ok: the registry a file, cached at the second join"

# 2.
a=$t/al
cp -r "$here/apps/aggregate_look" "$a"
python3 - "$a/main/main.cpp" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
def put(old, new):
    global s
    assert s.count(old) == 1, old
    s = s.replace(old, new)
put('''		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
	}''', '''		m_server->sub_event(this, Event::t("client_file:files_transmitted"));
		m_server->sub_event(this, Event::t("core:tick"));
	}''')
put('''		EVENT_VOIDN("core:continue", on_continue)
''', '''		EVENT_VOIDN("core:continue", on_continue)
		EVENT_TYPEN("core:tick", on_tick, interface::TickEvent)
''')
put('''	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{''', '''	float m_after_join = -1;
	void on_tick(const interface::TickEvent &event)
	{
		if(m_after_join < 0)
			return;
		m_after_join += event.dtime;
		if(m_after_join < 8)
			return;
		m_after_join = -1;
		voxelworld::access(m_server, [&](voxelworld::Interface *ivoxelworld){
			add_voxel(ivoxelworld->get_instance(m_main_scene)->get_voxel_reg(),
					"later", "main/rock.png", true);
		});
		log_i(MODULE, "registry_file_check: a voxel type added");
	}

	void on_files_transmitted(const client_file::FilesTransmitted &event)
	{
		if(m_after_join < 0)
			m_after_join = 0;''')
open(p, "w").write(s)
PY
start_server "$t/al.log" "STATUS Listening" 300 auto "$here/Build/bin/buildat_server" \
	-m "$a" -D "$t/al.srv" -C "$t/al.cache" -l 3 || fail "aggregate_look ($t/al.log)"
CHECK_PIDS+=($SERVER_PID)
printf "wait_log 60000 the voxel registry from the served file\nwait_log 60000 the voxel registry from the served file\ndelay 500\nquit\n" > "$t/al.cmds"
run_client 60 "$t/al_c.log" timeout 120 "$b" -C "$t/alc" -D "$t/alu" -w 800x450 -l 3 \
	-o sound_mute=1 -s "127.0.0.1:$SERVER_PORT" -c @"$t/al.cmds"
grep -aq "registry_file_check: a voxel type added" "$t/al.log" || fail "no voxel added ($t/al.log)"
sizes=$(grep -a "voxelwor: the voxel registry from the served file" "$t/al_c.log" | grep -o "[0-9]* bytes" | cut -d' ' -f1 | tr '\n' ' ')
set -- $sizes
[ $# = 2 ] && [ "$2" -gt "$1" ] || fail "the registry read at join and again larger: $sizes ($t/al_c.log)"
echo "PASS: the registry is a cached file; a change reaches a joined client ($1 then $2 bytes)"
