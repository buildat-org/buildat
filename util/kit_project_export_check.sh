#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# cost: ~5 min (2026-11-15)
# covers: builtin/kit/kit.cpp extensions/weave/init.lua builtin/kit/client_lua/editor.lua builtin/kit/client_lua/editor_input.lua builtin/world_menu/** apps/workbench/main/main.cpp src/impl/aitta.cpp src/client/web/index.html util/web_drive.js
# [KIT_PROJECT_EXPORT] A Workbench project exported as a template and made
# a project again, copied and renamed. One server, kitboss (the admin) on a
# headless weston's Xwayland of the check's own (its clipboard carries the
# agent tokens), through the GUI and MCP:
#   1. New "crag" from Crag Trial; a Builder and an Admin token by My
#      account; export_template's composition.json and types/ semantically
#      equal to apps/workbench/templates/crag_trial's (each param its type's
#      default where not written; how the text differs is printed).
#   2. New "project" (Empty, a heightmap) over it, the switch; a voxel type,
#      an item type and a sound by the editor's ops, a heightmap stroke;
#      by MCP a timer linked to a counter, a custom type local/beacon (a
#      client part too) placed, a prefab saved, a box of the voxel type set
#      (one cell tinted), an uploaded texture and a recipe one (on a type's
#      top) each worn by a cell (4z17: the import's line counts them, and
#      is not said for a template with no export's files). The palette's New tab, Export this game: the
#      file in <user>/exports, its files those export_template answers. The
#      file unzipped packs (`buildat aitta pack`) and installs; with a
#      texture not named by its hash, refused at pack.
#   3. Games..., New "imported", Start from: From a file..., Create, the
#      picker, the file: the server switches; the project opens Stopped in
#      the editor, its entities, links, type, rows and voxels the export's,
#      and its own export semantically the first one (edits.bin's cells and
#      heightmap samples the same). Export this game there too.
#   4. Games..., "project", Copy...: the name prefilled (project_1), Copy;
#      the copy's rows the original's. By MCP with the Builder token,
#      list_games refused; with the Admin one listed, the running project
#      copied (its rows), a taken name and the running one's rename refused,
#      project_1 renamed.
#   5. [KIT_EXPORT_WEB_CHECK] The web client (headless Chrome; skipped
#      without web/ or Chrome), kitboss in "imported": Export this game
#      caught as the browser's download, byte for byte 3.'s native export of
#      it; Games..., New "webimport", From a file..., the browser's
#      picker given the download: the server switches, and the page again
#      finds it Stopped in the editor, its entities, links, type, rows and
#      voxels the first export's (as 3.).
# Screenshots, kept with KEEP_TMP=1: $t/export_entry.png (the palette's
# New tab), $t/import_page.png (New, From a file...), $t/imported.png (the
# imported project in the editor), $t/copy.png (Copy...), and the web's:
# $t/web_export.png (Exported), $t/web_import_page.png,
# $t/web_imported.png
#   util/kit_project_export_check.sh
set -u
. "$(dirname "$0")/check_lib.sh"
here=$(cd "$(dirname "$0")/.." && pwd)
for c in weston xclip unzip; do
	command -v $c > /dev/null || skip "no $c"
done
if check_pgrep buildat_server >/dev/null || check_pgrep buildat >/dev/null; then
	skip "a buildat server or client is already running"
fi
check_tmp kit_project_export; t=$CHECK_TMP
cd "$here/Build"
export BUILDAT_JOIN_PASSWORD=checkpass12
check_build
b="$here/Build/bin/buildat"
sock=buildat-export-$$
weston --backend=headless --xwayland --socket=$sock --width=1100 \
	--height=1000 > "$t/weston.log" 2>&1 &
CHECK_PIDS+=($!)
for i in $(seq 50); do
	d=$(grep -ao "xserver listening on display :[0-9]*" "$t/weston.log" | grep -o ":[0-9]*$")
	[ -n "$d" ] && break
	sleep 0.2
done
[ -n "$d" ] || fail "weston's Xwayland ($t/weston.log)"
SL=$t/srv.log
mark() { wc -c < "$1"; }
await() # <log> <offset> <seconds> <regex>
{
	local i
	for i in $(seq $(($3 * 5))); do
		tail -c +$(($2 + 1)) "$1" | grep -qaE "$4" && return 0
		kill -0 $CLIENT 2>/dev/null || fail "the client is gone ($CL)"
		sleep 0.2
	done
	fail "no \"$4\" in $1 in $3 s ($SL, $CL)"
}
cmd() { printf '%s\n' "$@" >&3; }
step() # <seconds> <regex in the client's log> <command>...
{
	local s=$1 re=$2 m
	shift 2
	m=$(mark "$CL")
	cmd "$@"
	await "$CL" "$m" "$s" "$re"
}
srv() # <seconds> <regex in the server's log after <offset>> <offset>
{
	await "$SL" "$3" "$1" "$2"
}
web=""
if command -v "${CHROME:-google-chrome}" > /dev/null && [ -f "$here/web/buildat.wasm" ]; then
	web="-W $here/web"
fi
start_server "$SL" "Listening at" 300 auto \
	bin/buildat_server -m ../apps/workbench -D "$t/user" -l 3 $web \
	--sim-rate "$CHECK_RATE" || fail "the server did not come up ($SL)"
CHECK_PIDS+=($SERVER_PID)
wait_for_log "$SL" "setup code [A-Z0-9]+" 30
code=$(grep -aoP 'setup code \K[A-Z0-9]+' "$SL" | head -1)
[ -n "$code" ] || fail "no setup code ($SL)"
client() # <n>: kitboss, its commands from the fifo $t/c<n>.cmd, its log $t/boss<n>.log
{
	exec 3>&-
	mkfifo "$t/c$1.cmd"
	sleep 900 > "$t/c$1.cmd" &
	CHECK_PIDS+=($!)
	DISPLAY=$d WAYLAND_DISPLAY= SDL_VIDEODRIVER=x11 BUILDAT_JOIN_NAME=kitboss \
		timeout 600 bin/buildat -C "$t/client_cache" -D "$t/cu" \
		-s localhost:$SERVER_PORT -w 1024x700 -l 3 -o sound_mute=1 -c - \
		< "$t/c$1.cmd" > "$t/boss$1.log" 2>&1 &
	CLIENT=$!
	CHECK_PIDS+=($CLIENT)
	CL=$t/boss$1.log
	exec 3> "$t/c$1.cmd"
	await "$CL" 0 120 "Joined as kitboss"
}
switched() # <project>: the switch's goodbye, the client gone (it leaves by itself), the project up
{
	await "$CL" 0 60 "Disconnected from server: The server switches to the game $1"
	exec 3>&-
	wait $CLIENT
	wait_for_log "$SL" "workbench: switched to \"$1\"" 120 || fail "$1 did not start ($SL)"
}
menu() # Escape until the pause menu is up (the editor's own Escapes first)
{
	local i k m
	for i in 1 2 3; do
		m=$(mark "$CL")
		cmd "frames 3" "keypress Escape"
		for k in $(seq 15); do
			tail -c +$((m + 1)) "$CL" | grep -qa "pause: the menu shown" && return 0
			sleep 0.2
		done
	done
	fail "no pause menu ($CL)"
}
clip() # <last>: the clipboard once it holds a token other than <last>
{
	local i got
	for i in $(seq 50); do
		got=$(DISPLAY=$d xclip -selection clipboard -o 2>/dev/null)
		[[ $got =~ ^bat_[0-9a-f]{64}$ ]] && [ "$got" != "$1" ] && break
		sleep 0.2
	done
	printf '%s' "$got"
}
new_project() # <name> [<Start from's label> <its value>]: Empty without
{
	step 10 "world_menu: the name screen shown" "frames 3" 'click Button "New game..."'
	cmd "frames 3" "keydown ctrl" "keypress a" "keyup ctrl" "text $1" "frames 2"
	[ $# -gt 1 ] || return 0
	# (the one nearest the middle: the editor's view has one too)
	cmd 'click DropDownList "▼" 512 350' "delay 300" "frames 3"
	step 10 "world_menu: template picked: $3" "click Text \"$2\""
}
url=http://localhost:$SERVER_PORT/api/v1/mcp
cat > "$t/mcp.py" <<'PY'
import base64, json, os, re, sqlite3, struct, sys, urllib.error, urllib.request, zlib
phase, url, tok = sys.argv[1:4]
args = sys.argv[4:]
def post(token, msg):
    h = {"Content-Type": "application/json",
         "Accept": "application/json, text/event-stream",
         "Authorization": "Bearer " + token}
    req = urllib.request.Request(url, data=json.dumps(msg).encode(), headers=h)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, r.read().decode()
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()
n = 0
def rpc(token, method, params=None):
    global n
    n += 1
    m = {"jsonrpc": "2.0", "id": n, "method": method}
    if params is not None:
        m["params"] = params
    s, b = post(token, m)
    assert s == 200, (method, s, b)
    return json.loads(b)
def call(name, a={}, error=False, token=None):
    r = rpc(token or tok, "tools/call", {"name": name, "arguments": a})["result"]
    text = r["content"][0]["text"]
    assert r["isError"] == error, (name, a, text[:2000])
    print(" ", name, json.dumps(a)[:100], "->", text[:120].replace("\n", " "))
    return text
rpc(tok, "initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
    "clientInfo": {"name": "kit_project_export_check", "version": "1"}})
def state():
    return json.loads(call("get_state"))
def stopped():
    if state()["running"]:
        assert call("stop").startswith("Ended")
def placed(text):
    return int(re.search(r"placed \S+ (\d+)", text)[1])
def png(w, h, rgb):
    """A plain RGB PNG of one colour"""
    def chunk(t, d):
        return struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d))
    rows = b"".join(b"\0" + bytes(rgb) * w for _ in range(h))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h,
        8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b""))
# An export written out: its files, the base64 ones decoded, and each of
# its types' params' defaults on this server (list_types)
def export(to):
    x = json.loads(call("export_template"))
    for k, v in list(x["files"].items()) + [(k, base64.b64decode(v))
            for k, v in x["base64"].items()]:
        os.makedirs(os.path.dirname(os.path.join(to, k)), exist_ok=True)
        with open(os.path.join(to, k), "wb") as f:
            f.write(v.encode() if isinstance(v, str) else v)
    defaults(to + "/composition.json", to + ".defaults.json")
    return x
def defaults(comp, out):
    d = {}
    for e in json.load(open(comp))["entities"]:
        for c in e.get("components", []):
            if c["type"] not in d:
                ps = json.loads(call("list_types", {"type": c["type"]})).get("params", {})
                d[c["type"]] = {k: p.get("default") for k, p in ps.items()}
    json.dump(d, open(out, "w"))
# A composition as Kit loads it: by id, the parent 1 where not written, a
# turn of 0 or empty links left out, each param its type's default where
# not written, numbers to 4 places
def rounded(v):
    if isinstance(v, float):
        return round(v, 4)
    if isinstance(v, list):
        return [rounded(x) for x in v]
    if isinstance(v, dict):
        return {k: rounded(x) for k, x in v.items()}
    return v
def loaded(comp, defs):
    out = {}
    for e in comp["entities"]:
        e = dict(e)
        e.setdefault("parent", 1)
        for k in ("yaw", "pitch", "roll"):
            if e.get(k, 0) == 0:
                e.pop(k, None)
        cs = []
        for c in e.pop("components", []):
            c = dict(c)
            p = dict(defs.get(c["type"], {}))
            p.update(c.pop("params", {}))
            c["params"] = p
            if not c.get("links"):
                c.pop("links", None)
            # (a template's version is its type's, a missing one too)
            c.pop("version", None)
            cs.append(c)
        e["components"] = cs
        out[e.pop("id")] = rounded(e)
    return out, comp.get("next_id")
def same_composition(a, da, b, db, what):
    A = loaded(json.load(open(a)), json.load(open(da)))
    B = loaded(json.load(open(b)), json.load(open(db)))
    for i in sorted(set(A[0]) | set(B[0])):
        assert A[0].get(i) == B[0].get(i), (what, i, A[0].get(i), B[0].get(i))
    assert A[1] == B[1], (what, "next_id", A[1], B[1])
    ta, tb = open(a).read(), open(b).read()
    la, lb = ta.splitlines(), tb.splitlines()
    print("%s: %d entities semantically equal; the text %s (%d and %d lines, "
        "%d lines differ)" % (what, len(A[0]), "the same" if ta == tb else
        "differs", len(la), len(lb), sum(1 for x, y in zip(la, lb) if x != y)
        + abs(len(la) - len(lb))))
def files(d):
    return sorted(os.path.relpath(os.path.join(r, f), d)
        for r, _, fs in os.walk(d) for f in fs)
def edits(d):
    p = d + "/edits.bin"
    return json.loads(zlib.decompress(open(p, "rb").read())) if os.path.exists(p) else None
def rows(db):
    c = sqlite3.connect("file:" + db + "?mode=ro", uri=True)
    r = dict(((s, k), v) for s, k, v in c.execute("SELECT store, key, value FROM store"))
    c.close()
    return r
if phase == "crag":
    out, repo = args
    stopped()
    export(out)
    defaults(repo + "/composition.json", out + ".repo_defaults.json")
    same_composition(repo + "/composition.json", out + ".repo_defaults.json",
        out + "/composition.json", out + ".defaults.json", "Crag Trial's composition.json")
    t = [f for f in files(repo) if f.startswith("types/")]
    assert t == [f for f in files(out) if f.startswith("types/")], (t, files(out))
    for f in t:
        assert open(repo + "/" + f, "rb").read() == open(out + "/" + f, "rb").read(), f
    print("Crag Trial's types/: %d files byte-equal" % len(t))
    meta = json.load(open(out + "/meta.json"))
    assert meta["kind"] == "template" and meta["author"] == "kitboss" and meta["title"] == "crag", meta
elif phase == "build":
    stopped()
    T = placed(call("place", {"type": "kit/timer", "pos": [4, 9, 4]}))
    call("set_param", {"id": T, "param": "interval", "value": 0.5})
    C = placed(call("place", {"type": "kit/counter", "pos": [6, 9, 4], "params": {"target": 3}}))
    call("rename", {"id": C, "name": "Score"})
    assert "linked %d.tick -> %d.count" % (T, C) in call("link",
        {"id": T, "output": "tick", "to": C, "input": "count"})
    src = 'return {version = 1, about = {group = "Building", what = "A beacon"},\n' \
        '\tlook = {shape = "box", size = 0.3, color = "#40c0ff"},\n' \
        '\tparams = {glow = {type = "number", default = 2}}}\n'
    call("put_type", {"name": "beacon", "source": src,
        "client": "return {on_add = function(e) e:log(\"beacon added\") end}\n"})
    B = placed(call("place", {"type": "local/beacon", "pos": [8, 9, 4]}))
    call("set_param", {"id": B, "param": "glow", "value": 5})
    assert "saved prefab kitboss/pair" in call("save_prefab", {"ids": [C], "name": "pair"})
    box = {"at": [2, 12, 2], "size": [3, 2, 3]}
    assert "in 18 of 18 cells" in call("set_voxels", dict(box, voxel="kitboss/brick"))
    assert "in 1 of 1 cells" in call("set_voxels", {"at": [3, 14, 3], "size": [1, 1, 1],
        "voxel": "kitboss/brick", "tint": 5})
    # [KIT_TEXTURE_DESIGNER] an uploaded texture and a recipe one (the
    # grass preset, on a type's top), each worn by a cell
    r = call("put_texture", {"png": base64.b64encode(png(16, 16, (200, 60, 60))).decode(),
        "voxel": {"name": "redstone"}})
    assert "voxel type kitboss/redstone wears it" in r, r
    grass = json.loads(call("list_textures"))["presets"]["grass"]
    r = call("put_texture", {"name": "moss", "recipe": grass, "voxel": {"name": "mossy",
        "face": "top", "texture": "kit/stone.png"}})
    assert "voxel type kitboss/mossy wears it on its top" in r, r
    for x, v in ((6, "redstone"), (7, "mossy")):
        assert "in 1 of 1 cells" in call("set_voxels", {"at": [x, 12, 2],
            "size": [1, 1, 1], "voxel": "kitboss/" + v})
    json.dump({"T": T, "C": C, "B": B, "state": state(), "grass": grass},
        open(args[0], "w"))
elif phase == "export":
    out, gui = args
    export(out)
    # The file Export this game saved: the same files
    assert files(out) == files(gui), (files(out), files(gui))
    for f in files(gui):
        assert open(out + "/" + f, "rb").read() == open(gui + "/" + f, "rb").read(), f
    # (the upload by its hash)
    tx = [f for f in files(out) if f.startswith("textures/")]
    assert len(tx) == 1 and re.fullmatch(r"textures/[0-9a-f]{16}\.png", tx[0]), files(out)
    want = sorted(["LICENSE", "composition.json", "edits.bin", "items.json", "meta.json",
        "prefabs.json", "sounds.json", "types/beacon.client.lua", "types/beacon.lua",
        "voxels.json", "weaves.json"] + tx)
    assert files(out) == want, files(out)
    e = edits(out)["scenes"]["world"]
    cells = [e["cells"][i:i + 5] for i in range(0, len(e["cells"]), 5)]
    brick = [c for c in cells if e["names"][c[3]] == "kitboss/brick"]
    print("the export: %s; edits.bin: %d cells (%d of kitboss/brick), %d heightmap "
        "samples" % (", ".join(files(out)), len(cells), len(brick), len(e["hm"]) // 19))
    # (a heightmap's voxels are air: no sea in the generator's to differ from)
    assert len(cells) == 21 and len(brick) == 19 and \
        len([c for c in brick if c[4]]) == 1 and e["hm"], e
elif phase == "after":
    first, out, built, title = args
    built = json.load(open(built))
    st = state()
    assert st["running"] is False, "the import opened Running"
    a = {e["id"]: e for e in built["state"]["entities"]}
    b = {e["id"]: e for e in st["entities"]}
    for i in (built["T"], built["C"], built["B"]):
        x, y = a[i], b[i]
        assert x["name"] == y["name"] and x.get("pos") == y.get("pos") and \
            [(c["type"], c.get("params"), c.get("links")) for c in x["components"]] == \
            [(c["type"], c.get("params"), c.get("links")) for c in y["components"]], (x, y)
    print("the imported project: Stopped; the timer, counter and beacon as built, the link kept")
    assert json.loads(call("list_types", {"type": "local/beacon"})).get("custom")
    assert "kitboss/blade" in json.loads(call("list_items"))
    assert any(v["name"] == "kitboss/brick" for v in json.loads(call("list_voxel_types")))
    assert any(p["prefab"] == "kitboss/pair" for p in json.loads(call("list_prefabs")))
    # [KIT_TEXTURE_DESIGNER] the recipe texture, and the types wearing it
    # and the upload
    r = {x["name"]: x for x in json.loads(call("list_textures"))["recipes"]}
    vt = {v["name"]: v for v in json.loads(call("list_voxel_types"))}
    assert r["kitboss/moss"]["recipe"] == built["grass"] and \
        vt["kitboss/mossy"]["top"] == r["kitboss/moss"]["texture"] and \
        re.fullmatch(r"kit/up/[0-9a-f]{16}\.png", vt["kitboss/redstone"]["texture"]), \
        (r, vt.get("kitboss/mossy"), vt.get("kitboss/redstone"))
    g = json.loads(call("get_voxels", {"at": [2, 12, 2], "size": [3, 2, 3]}))
    k = [c for c, n in g["key"].items() if n == "kitboss/brick"]
    assert k and g["layers"] == [[k[0] * 3] * 3] * 2, g
    export(out)
    assert files(out) == files(first), (files(out), files(first))
    same_composition(first + "/composition.json", first + ".defaults.json",
        out + "/composition.json", out + ".defaults.json", "the import's composition.json")
    for f in files(first):
        # (meta.json and LICENSE name the project)
        if f in ("meta.json", "LICENSE", "composition.json", "edits.bin"):
            continue
        A, B = open(first + "/" + f, "rb").read(), open(out + "/" + f, "rb").read()
        if f.endswith(".json"):
            A, B = json.loads(A), json.loads(B)
        assert A == B, (f, A, B)
    assert edits(first) == edits(out), "edits.bin differs"
    ma, mb = json.load(open(first + "/meta.json")), json.load(open(out + "/meta.json"))
    assert mb["title"] == title and mb["author"] == "kitboss", mb
    print("the import's export: types, items, sounds, voxels, prefabs and edits.bin the first's")
elif phase == "projects":
    admin, saves = args
    assert "an admin's" in call("list_games", error=True)
    assert "an admin's" in call("rename_game", {"name": "project_1", "to": "x"}, error=True)
    def listed():
        return {p["name"]: p for p in json.loads(call("list_games", token=admin))}
    l = listed()
    assert set(l) == {"crag", "project", "project_1", "imported"} and l["imported"]["running"] \
        and not l["project"]["running"] and l["project"]["bytes"] > 0, l
    # The GUI's copy: the rows the original's
    assert rows(saves + "/project_1/save.sqlite") == rows(saves + "/project/save.sqlite")
    assert "Copied imported as imported_2" in call("copy_game",
        {"name": "imported", "to": "imported_2"}, token=admin)
    ra, rb = rows(saves + "/imported/save.sqlite"), rows(saves + "/imported_2/save.sqlite")
    # (a row the round wrote since may be in the original only)
    assert ra[("kit", "authored")] == rb[("kit", "authored")] and set(rb) <= set(ra) \
        and len(rb) > 10, set(rb) - set(ra)
    assert "taken" in call("copy_game", {"name": "project", "to": "crag"}, error=True, token=admin)
    assert "running" in call("rename_game", {"name": "imported", "to": "x"}, error=True, token=admin)
    assert "Renamed" in call("rename_game", {"name": "project_1", "to": "renamed"}, token=admin)
    l = listed()
    assert set(l) == {"crag", "project", "renamed", "imported", "imported_2"}, l
    print("projects: list, copy (the running one's rows), rename; the Builder token refused")
PY
mcp() # <phase> <token> <args...>
{
	local p=$1
	shift
	python3 -I "$t/mcp.py" "$p" "$url" "$@" > "$t/mcp_$p.log" 2>&1 ||
		fail "the MCP $p run: $(tail -5 "$t/mcp_$p.log") ($t/mcp_$p.log, $SL)"
	grep -v "^  " "$t/mcp_$p.log"
}

# 1. Crag Trial
BUILDAT_JOIN_CODE=$code BUILDAT_JOIN_CREATE=1 client 1
cmd "wait_log_any 30000 server window: the page ntfy" "frames 3" 'click Button "Don'"'"'t add"'
await "$CL" 0 30 "world_menu: the list shown"
new_project crag "Crag Trial" crag_trial
step 60 "kit editor: edit mode on" "frames 3" 'click Button "Create"'
menu
step 10 "accounts: agents: 0 tokens, on" "frames 3" 'click Button "My account*"' \
	"frames 5" 'click Button "Connect an agent..."'
step 10 "accounts: agents: a token made, builder" "frames 3" \
	'click Button "Make a token..."' "frames 3" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
tok=$(clip "")
[[ $tok =~ ^bat_ ]] || fail "no Builder token on the clipboard: $tok"
cmd "frames 3" 'click Button "Done"' "frames 3" 'click Button "Scope: Builder*"' \
	"frames 3" 'click LineEdit "My agent"' "delay 300" "keydown ctrl" \
	"keypress a" "keyup ctrl" "text admin agent" "frames 2"
step 10 "accounts: agents: a token made, admin" 'click Button "Make a token"'
step 10 "accounts: agents: the token copied" "frames 3" 'click Button "copy token"'
adm=$(clip "$tok")
[[ $adm =~ ^bat_ ]] || fail "no Admin token on the clipboard: $adm"
cmd "frames 3" 'click Button "Done"'
step 10 "pause: the menu shown" "frames 3" "keypress Escape"
mcp crag "$tok" "$t/crag" "$here/apps/workbench/templates/crag_trial"
echo "ok: Crag Trial exported back as it is in the repo"

# 2. A project of the builder's, exported
step 10 "world_menu: the list shown, 1 worlds" "frames 3" 'click Button "Games..."'
new_project project
cmd "expect_error Disconnected from server: The server switches" 'click Button "Create"'
switched project
client 2
await "$CL" 0 60 "player physics enabled"
await "$CL" 0 30 "kit editor: edit rights: yes"
step 20 "kit editor: edit mode on" "frames 3" "keypress F6"
m=$(mark "$SL")
cmd 'event kit_edit {"op": "stop"}' \
	'event kit_edit {"op": "voxel", "name": "brick", "texture": "kit/stone.png"}' \
	'event kit_edit {"op": "item", "name": "blade", "preset": "kit/sword", "damage": 20}' \
	'event kit_edit {"op": "sound", "name": "chime", "params": "blip1:AAALvAABrNYAAf_f_AAAAf_AAUNf_AAf_f___f_AAGaf_gA4DbW"}'
srv 10 "kitboss made voxel type kitboss/brick version 1" $m
srv 10 "kitboss made item type kitboss/blade version 1" $m
srv 10 "kitboss made sound kitboss/chime version 1" $m
step 10 "kit editor: terrain: " \
	'event kit_edit {"op": "terrain", "tool": "raise", "x": 4, "y": 0, "z": 4, "size": 2, "strength": 5, "stroke": 1}'
mcp build "$tok" "$t/built.json"
# (the tab asks the Aitta, a closed port: the question declined)
step 10 "Asking the user about " "frames 3" 'click Button "New"'
step 10 "The user declined " "frames 3" 'click Button "Decline"'
cmd "frames 5" "screenshot $t/export_entry.png"
step 20 "kit editor: Exported to " 'click Button "Export this game"'
z=$t/cu/exports/project.template.zip
[ -s "$z" ] || fail "no $z ($CL)"
mkdir "$t/gui"
unzip -q "$z" -d "$t/gui" || fail "the export does not unzip ($z)"
mcp export "$tok" "$t/first" "$t/gui"
"$b" aitta keygen "$t/key" > "$t/pub" 2>/dev/null || fail "keygen"
zip=$("$b" aitta pack "$t/gui" "$t/key" "$t/out" 2> "$t/pack.err") || fail "the pack ($t/pack.err)"
"$b" aitta install "$zip" "$t/inst" > "$t/install.txt" 2>&1 || fail "the install ($t/install.txt)"
cp -r "$t/gui" "$t/bad"
printf 'x' > "$t/bad/textures/Not_a_hash.png"
if "$b" aitta pack "$t/bad" "$t/key" "$t/out_bad" > /dev/null 2> "$t/bad.err"; then
	fail "packed with textures/Not_a_hash.png"
fi
grep -qF "a template's textures are <16 hex digits>.png" "$t/bad.err" ||
	fail "refused, but not for the texture's name: $(cat "$t/bad.err")"
echo "ok: the project exported (the editor's file and export_template's the same); packed, installed; a bad texture name refused"

# 3. Imported from the file
menu
step 10 "world_menu: the list shown, 2 worlds" "frames 3" 'click Button "Games..."'
new_project imported "From a file..." file
cmd "frames 5" "screenshot $t/import_page.png"
step 10 "The file picker at .*/exports" 'click Button "Create"'
cmd "delay 500" "expect_error Disconnected from server: The server switches"
step 30 "world_menu: create imported from project.template.zip \([0-9]+ bytes\)" \
	'click Button "project.template.zip"'
switched imported
grep -aqE 'workbench: the project "imported" from a file \([0-9]+ bytes, "project"\)' "$SL" ||
	fail "no import line ($SL)"
grep -aqE "The template's export: 1 textures, 7 rows \(0 left out\), [1-9][0-9]* heightmap samples" "$SL" ||
	fail "the rows not all taken: $(grep -a "The template's export" "$SL") ($SL)"
grep -aqE "World world: the template's 21 edited cells in 1 sections \(0 left out\)" "$SL" ||
	fail "the cells not all taken: $(grep -a "edited cells" "$SL") ($SL)"
# [4z17] Said for the export's template only: Crag Trial's and Empty's
# have none of an export's files
[ "$(grep -ac "The template's export: " "$SL")" = 1 ] ||
	fail "the export's line not for the export only: $(grep -a "The template's export: " "$SL") ($SL)"
client 3
await "$CL" 0 60 "kit editor: edit mode on"
await "$CL" 0 30 "kit: entity [0-9]+'s client part: beacon added"
cmd "delay 1000" "frames 10" "screenshot $t/imported.png"
mcp after "$tok" "$t/first" "$t/second" "$t/built.json" imported
# Its export by the editor, for the web's download (5.)
step 10 "Asking the user about " "frames 3" 'click Button "New"'
step 10 "The user declined " "frames 3" 'click Button "Decline"'
step 20 "kit editor: Exported to .*imported.template.zip" 'click Button "Export this game"'
echo "ok: imported, opened Stopped in the editor, its export the first's"

# 4. Copy and rename
menu
step 10 "world_menu: the list shown, 3 worlds" "frames 3" 'click Button "Games..."'
step 10 "world_menu: the list shown" "frames 3" 'click Button "project"'
step 10 "world_menu: the copy screen shown" "frames 3" 'click Button "Copy..."'
cmd "frames 5" "screenshot $t/copy.png"
m=$(mark "$SL")
step 20 "world_menu: the list shown, 4 worlds" 'click Button "Copy"'
srv 10 'workbench: the project "project" copied as "project_1"' $m
mcp projects "$tok" "$adm" "$t/user/apps/workbench/saves"
cmd "quit"
wait $CLIENT

# 5. The web: kitboss's page in "imported", its export the browser's
# download; then imported from it as "webimport"
page() # <name>: its steps after the login in $t/<name>.steps, its out dir $t/<name>
{
	{
		printf '[["nav", "${URL}"], ["waitlog", "accounts: the login page shown", 120], ["wait", 1000],
 ["selall"], ["frames", 2], ["type", "kitboss"], ["frames", 2], ["key", "Tab"], ["frames", 2],
 ["type", "checkpass12"], ["frames", 2], ["key", "Enter"], ["waitlog", "Joined as kitboss", 30],\n'
		cat "$t/$1.steps"
	} > "$t/$1.json"
	WEB_DRIVE_VIEWPORT=1024x700@1 WEB_DRIVE_URL="http://127.0.0.1:$SERVER_PORT/" \
		"$here/util/web_drive.sh" chrome workbench "$t/$1.json" "$t/$1" > "$t/$1.txt" 2>&1 ||
		fail "the page's $1: $(tail -2 "$t/$1.txt") ($t/$1/page.log, $SL)"
}
webpass=""
if [ -n "$web" ]; then
	# (no longer the first builder in "imported": the pause menu's Edit)
	cat > "$t/web1.steps" <<'J'
 ["waitlog_any", "pause: the menu shown", 30], ["frames", 3],
 ["click", "Button", "Edit"], ["waitlog_any", "kit editor: edit mode on", 20], ["frames", 10],
 ["click", "Button", "New"], ["waitlog", "Asking the user about ", 10], ["frames", 3],
 ["click", "Button", "Decline"], ["waitlog", "The user declined ", 10], ["frames", 3],
 ["click", "Button", "Export this game"],
 ["waitlog", "kit editor: Exported imported.template.zip \\([0-9]+ KiB\\): see your downloads", 20],
 ["downloaded", "imported.template.zip", 20], ["frames", 3],
 ["shot", "${OUT}/web_export.png"],
 ["key", "Escape"], ["waitlog", "pause: the menu shown", 10], ["frames", 3],
 ["click", "Button", "Games..."], ["waitlog", "world_menu: the list shown, 5 worlds", 10], ["frames", 3],
 ["click", "Button", "New game..."], ["waitlog", "world_menu: the name screen shown", 10], ["frames", 3],
 ["selall"], ["frames", 2], ["type", "webimport"], ["frames", 2],
 ["click", "DropDownList", "▼", 512, 350], ["wait", 300], ["frames", 3],
 ["click", "Text", "From a file..."], ["waitlog", "world_menu: template picked: file", 10], ["frames", 3],
 ["shot", "${OUT}/web_import_page.png"],
 ["file", "${OUT}/imported.template.zip"],
 ["click", "Button", "Create"],
 ["waitlog", "world_menu: create webimport from imported.template.zip \\([0-9]+ bytes\\)", 30],
 ["waitlog", "Disconnected from server: The server switches to the game webimport", 60]
]
J
	page web1
	cmp "$t/web1/imported.template.zip" "$t/cu/exports/imported.template.zip" ||
		fail "the web's download is not the native export ($t/web1, $t/cu/exports)"
	echo "ok: the web's Export this game, the browser's download byte for byte the native export ($(wc -c < "$t/web1/imported.template.zip") bytes)"
	wait_for_log "$SL" 'workbench: switched to "webimport"' 120 || fail "webimport did not start ($SL)"
	grep -aqE 'workbench: the project "webimport" from a file \([0-9]+ bytes, "imported"\)' "$SL" ||
		fail "no web import line ($SL)"
	cat > "$t/web2.steps" <<'J'
 ["waitlog_any", "kit editor: edit mode on", 60],
 ["waitlog_any", "kit: entity [0-9]+'s client part: beacon added", 30],
 ["frames", 10], ["shot", "${OUT}/web_imported.png"]
]
J
	page web2
	mcp after "$tok" "$t/first" "$t/third" "$t/built.json" webimport
	cp "$t"/web1/web_*.png "$t"/web2/web_*.png "$t/"
	echo "ok: the download imported on the web through New's From a file..., opened Stopped in the editor, its export the first's"
	webpass=" On the web too: the export the browser's download, byte for byte the native one, imported through the picker."
else
	echo "SKIPPED: 5., the web: no Chrome or web/buildat.wasm"
fi
grep -aqF "${tok#bat_}" "$SL" "$t"/boss*.log && fail "a token is in a log"
echo "PASS: a project exported as a template (the editor's and MCP's), imported from the file as a new project (Stopped, in the editor, its export the first's), Crag Trial exported back as in the repo; Copy... and the MCP list, copy and rename.$webpass Screenshots in $t"
