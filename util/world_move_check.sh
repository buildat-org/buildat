#!/bin/bash
# tier: full
# cost: ~5 min (2026-10-11)
# covers: apps/vanilla/main/main.cpp apps/vanilla/main/client_lua/menu.lua src/impl/zip.cpp src/client/app_lua.h client/api.lua client/core/network/init.lua apps/vanilla/main/importer.h apps/vanilla/main/game_settings.h
# [WORLD_TRIM_MOVE] 3-5: a world out as a zip and in again, through the
# launcher's world menu (the native client; its picker is the client's
# own). Vanilla on the minimal game, the server at --max-disk-mb 300.
#   0. A world, wt, with a player's build (a node a chat command placed),
#      an item in their inventory, a position, a privilege and a password.
#   1. Export wt: a zip in the client's exports, which Python's zipfile
#      reads whole, a symlink in the save left out ([SEC_RUN5_LEFTOVERS]). Import it: saved as wt_2, its store the same rows as
#      wt's and its players row marked foreign, and world.mt without wt's admin,
#      privilege and cost settings ([VANILLA_IMPORT_PRIVS]). Bad zips refused, nothing kept: a "../" entry, one whose
#      header says more than the room, one whose stored entry holds more
#      than its header says, and a Luanti world of the leveldb backend
#      (with the --migrate hint), a save with a trigger of its own. A
#      zipped Luanti world (sqlite3) imported and started, a player's
#      list of 2^31-1 slots in it left out.
#   2. wt_2 started: the build is there, the player's item and position
#      too, their privilege and password not ([IMPORT_KEEPS_INVENTORIES]).
#   3. One transfer at a time, on a public server with two admins (on the
#      launcher's a second client is a LAN player with no world menu,
#      [GUEST_NAME_REUSE]): one over a slow link (util/netsim.py) importing
#      a 10 MB zip; the other's export meanwhile refused; the first leaves
#      mid-way, and the server's transfer folder is gone with no save made.
# The refusals name no folder of the server's ([SEC_RUN5_LEFTOVERS]).
# simplified: native only; the web's download of the parts and its picked
# file read in parts are not driven.
#   util/world_move_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] || skip "no display"
check_tmp world_move; t=$CHECK_TMP
trap check_cleanup EXIT
d=$t/s
saves=$d/apps/vanilla/saves
mkdir -p "$saves/wt/luanti" "$d/shared" "$t/nu/exports"
printf 'enable_damage = false\nname = mover\ndefault_privs = server, privs\nbasic_privs = server\nchunksize = 80\n' \
	> "$saves/wt/luanti/world.mt"
cat > "$d/shared/fixture.lua" <<'L'
local M = {x = 3, y = 2, z = 0}
core.register_on_joinplayer(function(player)
	local name = player:get_player_name()
	local pos = vector.round(player:get_pos())
	core.log("action", string.format("wm: joined at %d,%d,%d", pos.x, pos.y, pos.z))
	player:set_physics_override({gravity = 0, speed = 0})
	core.after(2, function()
		core.emerge_area(M, M, function(_, _, left)
			if left == 0 then core.chat_send_player(name, "wm: ready") end
		end)
	end)
end)
core.register_chatcommand("mark", {func = function(name)
	core.set_node(M, {name = "floor:marker"})
	local p = core.get_player_by_name(name)
	p:get_inventory():set_stack("main", 1, "floor:marker 7")
	p:set_pos({x = 6, y = 9, z = -4})
	core.set_player_password(name, "wmhash")
	return true, "wm: marked"
end})
core.register_chatcommand("look", {func = function(name)
	core.log("action", "wm: at the mark " .. core.get_node(M).name)
	local p = core.get_player_by_name(name)
	local pos = vector.round(p:get_pos())
	local e = core.get_auth_handler().get_auth(name) or {}
	local privs = {}
	for k in pairs(e.privileges or {}) do privs[#privs + 1] = k end
	table.sort(privs)
	core.log("action", string.format("wm: player at %d,%d,%d holding %s privs %s password %s",
		pos.x, pos.y, pos.z, p:get_inventory():get_stack("main", 1):to_string(),
		table.concat(privs, ","), tostring(e.password)))
	return true, "wm: looked"
end})
L
serve(){
	local log=$1 kv rc; shift
	for kv in "$@"; do export "$kv"; done
	start_server "$log" "STATUS Listening" 60 auto "$here/Build/bin/buildat_server" \
		-u "launcher=${LAUNCHER-1}" -A 127.0.0.1 -m "$here/apps/vanilla" -D "$d" -C "$t/c" -l 3 \
		--max-disk-mb 300
	rc=$?
	CHECK_PIDS+=($SERVER_PID)
	for kv in "$@"; do unset "${kv%%=*}"; done
	[ $rc = 0 ] || fail "the server ($log)"
}
stop(){ kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; }
# client <log> <cmds> [port]
client(){
	run_client 60 "$1" timeout 300 "$here/Build/bin/buildat" -C "$t/nc" \
		-D "$t/nu" -s 127.0.0.1:${3:-$SERVER_PORT} -w 1100x900 -u 1 -l 3 \
		-o sound_mute=1 -c @"$2" ||
		fail "the drive ($1: $(grep -a "Command sequence failed\|run_client:" "$1" | tail -1))"
}
# The delay after the text: the field has it before Return; the one after
# the answer, the chat closed before the next T
chat(){ printf 'keypress T\nwait_log 5000 chat: the line opened\ntext %s\ndelay 300\nkeypress Return\nwait_log 20000 wm: %s\ndelay 500\n' "$1" "$2"; }

# 0
serve "$t/0.log" BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=wt \
	BUILDAT_LUANTI_LUA="$d/shared/fixture.lua"
{ echo "wait_log 60000 wm: ready"; chat /mark marked; chat /look looked; echo quit; } > "$t/0.cmds"
client "$t/0c.log" "$t/0.cmds"
stop
grep -aq "wm: at the mark floor:marker" "$t/0.log" || fail "no build in wt ($t/0.log)"
# server: wt's default_privs
grep -aq "wm: player at 6,9,-4 holding floor:marker 7 privs .*server.* password wmhash" "$t/0.log" ||
	fail "wt's player not set up: $(grep -a "wm: player" "$t/0.log")"

# 1: a link in wt, which the export does not read through
ln -s /etc/hostname "$saves/wt/luanti/link.txt"
# the zips to import, in the client's exports
python3 - "$t/nu/exports" "$saves/wt/save.sqlite" <<'PY'
import io, sqlite3, struct, sys, tempfile, zipfile, os
out = sys.argv[1]
def db_of(sql, *rows):
    db = tempfile.mktemp()
    c = sqlite3.connect(db)
    c.executescript(sql)
    for r in rows:
        c.execute(*r)
    c.commit(); c.close()
    data = open(db, "rb").read(); os.remove(db)
    return data
# A player whose main list says 2^31-1 slots ([SECURITY_RUN_5]): left out,
# the world comes up
players = db_of("""
CREATE TABLE player (name VARCHAR(60) NOT NULL, pitch NUMERIC(11,4) NOT NULL, yaw NUMERIC(11,4) NOT NULL, posX NUMERIC(11,4) NOT NULL, posY NUMERIC(11,4) NOT NULL, posZ NUMERIC(11,4) NOT NULL, hp INT NOT NULL, breath INT NOT NULL, creation_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, modification_date DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP, PRIMARY KEY (name));
CREATE TABLE player_metadata (player VARCHAR(60) NOT NULL, metadata VARCHAR(256) NOT NULL, value TEXT, PRIMARY KEY(player, metadata));
CREATE TABLE player_inventories (player VARCHAR(60) NOT NULL, inv_id INT NOT NULL, inv_width INT NOT NULL, inv_name TEXT NOT NULL DEFAULT '', inv_size INT NOT NULL, PRIMARY KEY(player, inv_id));
CREATE TABLE player_inventory_items (player VARCHAR(60) NOT NULL, inv_id INT NOT NULL, slot_id INT NOT NULL, item TEXT NOT NULL DEFAULT '', PRIMARY KEY(player, inv_id, slot_id));
""", ("INSERT INTO player (name,pitch,yaw,posX,posY,posZ,hp,breath) VALUES ('ann',0,0,0,100,0,20,10)",),
    ("INSERT INTO player_inventories VALUES ('ann',0,0,'main',2147483647)",))
def luanti_world(backend):
    return {"lw/world.mt": "gameid = minimal\nbackend = %s\nplayer_backend = sqlite3\n" % backend,
            "lw/map.sqlite": db_of("CREATE TABLE blocks (pos INT PRIMARY KEY, data BLOB)"),
            "lw/players.sqlite": players}
def write(name, files, method=zipfile.ZIP_STORED):
    with zipfile.ZipFile(out + "/" + name, "w", method) as z:
        for n, d in files.items():
            z.writestr(n, d)
write("lw.zip", luanti_world("sqlite3"))
write("leveldb.zip", luanti_world("leveldb"))
write("escape.zip", {"../escape.txt": "out"})
# wt's save with a trigger of its own, which would run at every write
tg = tempfile.mktemp()
a = sqlite3.connect("file:%s?mode=ro" % sys.argv[2], uri=True)
b = sqlite3.connect(tg); a.backup(b); a.close()
b.execute("CREATE TRIGGER grow AFTER INSERT ON store BEGIN SELECT 1; END")
b.commit(); b.close()
write("trigger.zip", {"tg/save.sqlite": open(tg, "rb").read(),
        "tg/luanti/world.mt": "gameid = minimal\n"})
os.remove(tg)
# Sizes patched in both headers: the local one at 22, the directory's at 24
def patched(name, files, size):
    b = io.BytesIO()
    with zipfile.ZipFile(b, "w", zipfile.ZIP_STORED) as z:
        for n, d in files.items():
            z.writestr(n, d)
    d = bytearray(b.getvalue())
    d[22:26] = struct.pack("<I", size)
    c = d.find(b"PK\x01\x02")
    d[c + 24:c + 28] = struct.pack("<I", size)
    open(out + "/" + name, "wb").write(bytes(d))
patched("room.zip", {"x/world.mt": "gameid = minimal\n"}, 4000000000)
patched("less.zip", {"x/world.mt": "gameid = minimal\n" + "#" * 1000}, 17)
PY
# The half second after the picker's line: it takes no click in its first
# frames, before its guard has seen it laid out
imp(){ # imp <file> <what the log says after>
	printf 'click Button "Import a world from a zip..."\nwait_log 5000 The file picker at\ndelay 500\nclick Button "%s"\nwait_log 60000 %s\n' "$1" "$2"
}
# Ok on a dialog (a settle for it first) asks for the saves again
ok(){ printf 'delay 500\nclick Button "Ok"\nwait_log 10000 saves, \n'; }
serve "$t/1.log"
{
	echo "wait_log_any 60000 menu: 1 saves"; echo "delay 1000"
	echo 'click Button "wt*"'; echo "wait_log 10000 menu: the world wt shown"
	echo 'click Button "Export..."'; echo "wait_log 60000 menu: Exported wt to"; ok
	# The import's news asks for the saves again
	imp wt.buildat.zip "menu: Imported wt_2"; echo "wait_log 10000 saves, "
	imp escape.zip "failed:"; ok
	imp trigger.zip "failed:"; ok
	imp room.zip "failed:"; ok
	imp less.zip "failed:"; ok
	imp leveldb.zip "failed:"; ok
	imp lw.zip "menu: done; the world is up"
	# a settle after that line: the started world's first frames before
	# the quit
	echo "delay 1500"; echo quit
} > "$t/1.cmds"
client "$t/1c.log" "$t/1.cmds"
stop
grep -a "menu: \(Exported\|Imported\|Importing\|import\|export\)\|failed:" "$t/1c.log" | sed 's/.*menu: /menu: /' | cut -c 1-220
grep -a "Command sequence failed" "$t/1c.log" && fail "the drive ($t/1c.log)"
python3 - "$t/nu/exports/wt.buildat.zip" "$saves/wt/save.sqlite" "$saves/wt_2/save.sqlite" <<'PY' || fail "the export and its import"
import sqlite3, sys, zipfile
z = zipfile.ZipFile(sys.argv[1])
bad = z.testzip()
assert bad is None, "%s does not read" % bad
names = z.namelist()
print("the export: " + ", ".join(names))
assert "wt/save.sqlite" in names and "wt/luanti/world.mt" in names
assert "wt/luanti/link.txt" not in names, "the symlink was read through"
def rows(p):
    c = sqlite3.connect("file:%s?mode=ro" % p, uri=True)
    return list(c.iterdump())
players = "INSERT INTO \"store\" VALUES('luanti','players',"
a, b = rows(sys.argv[2]), rows(sys.argv[3])
print("wt and wt_2: %d and %d rows of dump" % (len(a), len(b)))
assert [r for r in a if r.startswith(players)], "wt has no players row"
foreign = [r for r in b if r.startswith("INSERT INTO \"store\" VALUES('luanti','players_auth_foreign',")]
assert len(foreign) == 1, "wt_2's players row not marked foreign"
assert a == [r for r in b if r not in foreign], "the stores differ"
PY
grep -qE '^(name|default_privs|basic_privs|chunksize) ' "$saves/wt_2/luanti/world.mt" &&
	fail "wt_2's world.mt kept the admin, privileges or cost settings: $(cat "$saves/wt_2/luanti/world.mt")"
grep -q '^enable_damage = false' "$saves/wt_2/luanti/world.mt" ||
	fail "wt_2's world.mt lost its other settings: $(cat "$saves/wt_2/luanti/world.mt")"
for want in "would leave" "room for" "is stored as" "luanti --migrate sqlite3" \
		"trigger.*does not read as a Buildat save"; do
	grep -a "menu: Importing .* failed:" "$t/1c.log" | grep -aq -- "$want" ||
		fail "no refusal saying \"$want\" ($t/1c.log)"
done
grep -a "menu: Importing .* failed:" "$t/1c.log" | grep -aq -- "$t" &&
	fail "a refusal names the server's folders ($t/1c.log)"
grep -aq "ann's list main has 2147483647 slots; left out" "$t/1.log" ||
	fail "the 2^31-1 slot list was not left out ($t/1.log)"
got=$(ls "$saves" | LC_ALL=C sort | tr '\n' ' ')
echo "the saves: $got"
# _chat: builtin/chat's own ([VANILLA_CHAT_MIN]), beside accounts' _server
[ "$got" = "_chat _server lw wt wt_2 " ] || fail "the saves: $got"
[ -e "$t/c/apps/vanilla/vanilla_transfer" ] && fail "the transfer folder was left: $(ls -R "$t/c/apps/vanilla/vanilla_transfer")"
[ -n "$(find "$t" -name escape.txt)" ] && fail "the ../ entry landed"
echo "ok: exported, imported as wt_2 alike but its admin and privileges; the bad zips refused with nothing kept; a Luanti world imported and started"

# 2
serve "$t/2.log" BUILDAT_LUANTI_GAME=minimal BUILDAT_LUANTI_SAVE=wt_2 \
	BUILDAT_LUANTI_LUA="$d/shared/fixture.lua"
{ echo "wait_log 60000 wm: ready"; chat /look looked; echo quit; } > "$t/2.cmds"
client "$t/2c.log" "$t/2.cmds"
stop
grep -aq "wm: at the mark floor:marker" "$t/2.log" || fail "no build in wt_2 ($t/2.log)"
# The import's: the item and the position kept (where the join put them,
# before the client's own fall), the privilege and the password not
grep -aq "wm: joined at 6,9,-4" "$t/2.log" ||
	fail "wt_2's player not where they left: $(grep -a "wm: joined" "$t/2.log")"
grep -a "wm: player" "$t/2.log" | grep -a "holding floor:marker 7 privs" |
	grep -av "server" | grep -aqE "password (nil|)$" ||
	fail "wt_2's player: $(grep -a "wm: player" "$t/2.log")"
python3 - "$saves/wt_2/save.sqlite" <<'PY' || fail "wt_2's players row after a run"
import sqlite3, sys
c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
rows = {k: bytes(v) if not isinstance(v, str) else v.encode() for k, v in
        c.execute("SELECT key, value FROM store WHERE store = 'luanti'")}
p = rows["players"]
assert b"floor:marker 7" in p, "the item is not in the row"
assert b"wmhash" not in p and b"server" not in p, "the auth came back: %r" % p[:300]
assert rows.get("players_auth_foreign", b"") == b"", "the mark stayed"
PY
echo "ok: the build in wt_2, the player's item and position; no privilege or password"

# 3
head -c 10000000 /dev/urandom > "$t/blob"
(cd "$t" && python3 -c 'import zipfile; z = zipfile.ZipFile("nu/exports/big.zip", "w"); z.write("blob", "big/blob")')
# boss the first admin; boss's admin script makes boss2 another
echo "name boss bosspass1" > "$d/first_admin"
serve "$t/3.log" LAUNCHER=0
LINK=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
# A slow link; its --delay 0 is the link's latency, not a wait
python3 "$here/util/netsim.py" --listen "$LINK" --to "127.0.0.1:$SERVER_PORT" \
	--delay 0 --rate 2400 > "$t/netsim.log" 2>&1 &
CHECK_PIDS+=($!)
# Its port, polled
for _ in $(seq 50); do port_taken "$LINK" && break; sleep 0.2; done
port_taken "$LINK" || fail "netsim did not listen ($t/netsim.log)"
# The 25 s after the import began: it still under way over the slow link
# while the second client asks, and then left half done. The picker's
# half second as in imp. An admin's first login asks about ntfy in a
# window over the menu
ntfy='wait_log_any 60000 accounts: ntfy asked\nwait_log_any 5000 server window: the page ntfy\ndelay 300\nclick Button "Don'"'"'t add"\ndelay 500\n'
printf "wait_log_any 60000 admin script: done\n$ntfy"'wait_log_any 60000 menu: 3 saves\ndelay 1000\nclick Button "Import a world from a zip..."\nwait_log 5000 The file picker at\ndelay 500\nclick Button "big.zip"\nwait_log 30000 menu: import big.zip\ndelay 25000\nquit\n' > "$t/3a.cmds"
BUILDAT_JOIN_NAME=boss BUILDAT_JOIN_PASSWORD=bosspass1 \
	BUILDAT_JOIN_ADMIN=$'add boss2 bosspass2\npriv boss2 admin' \
	client "$t/3a.log" "$t/3a.cmds" "$LINK" &
a=$!
wait_for_log "$t/3.log" "Importing big.zip" 120 || fail "no import began ($t/3.log)"
printf "$ntfy"'wait_log_any 60000 menu: 3 saves\ndelay 1000\nclick Button "wt*"\nwait_log 10000 menu: the world wt\nclick Button "Export..."\nwait_log 30000 Another transfer\nquit\n' > "$t/3b.cmds"
BUILDAT_JOIN_NAME=boss2 BUILDAT_JOIN_PASSWORD=bosspass2 \
	run_client 60 "$t/3b.log" timeout 120 "$here/Build/bin/buildat" -C "$t/nc2" \
	-D "$t/nu2" -s 127.0.0.1:$SERVER_PORT -w 1100x900 -u 1 -l 3 -o sound_mute=1 -c @"$t/3b.cmds"
grep -aq "menu: Another transfer is running: an import" "$t/3b.log" ||
	fail "the second transfer was not refused ($t/3b.log)"
wait $a || fail "the importing client's drive ($t/3a.log)"
wait_for_log "$t/3.log" "The transfer's client left" 30 || fail "the leaving was not seen ($t/3.log)"
grep -a "Importing big\|The transfer\|Another transfer" "$t/3.log" | cut -c 30- | head -5
[ -e "$t/c/apps/vanilla/vanilla_transfer" ] && fail "the transfer folder was left"
[ -e "$saves/big" ] && fail "a save was made of half a zip"
stop
echo "PASS: a world exported and imported alike, its build there; a Luanti world zipped in; bad zips refused with nothing kept; one transfer at a time, and one cut off leaves nothing"
