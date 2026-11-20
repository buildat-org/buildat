#!/usr/bin/env python3
"""The names a game's Lua and a C++ module can reach, listed from the
code, so that doc/client_api.txt and doc/server_api.txt can be checked
against them ([CLIENT_API_DOC]).

    util/api_names.py            # the listing, one name per line
    util/api_names.py --check    # names the docs lack, names the docs
                                 # have that the code does not; exit 1
                                 # on either
    util/api_names.py --kit        # [KIT_API_1] Kit API 1's surface
    util/api_names.py --kit-write  # ... into doc/kit_api1.txt
    util/api_names.py --kit-check  # ... against doc/kit_api1.txt: exit 1
                                   # on a removal or change no migration
                                   # or deprecation covers

Client: buildat.* and buildat.safe.* as client/*.lua assign them (a
`function buildat.x` counts too), the sandboxed magic classes and their
members out of client/core/urho3d/safe_classes.lua (util.wc("Name", {
instance = {...}, properties = {...}})) and the globals of
safe_globals.lua, and each extension's .safe members. Server: the
headers under src/interface/ and each builtin's api.h.

simplified: the members are read by regular expression over the Lua
source, so a member built in a loop or by a helper that does not put
its name in the file is not seen; the check then says the doc has a
name the code does not, which is the moment to teach this script.

Kit (--kit*, kit_plan 4z37j (4)): what a Kit game's types and client
parts can reach, and every builtin type's parameters, signals and state,
as doc/kit_api1.txt lists and explains it.
"""
import json
import os
import re
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.dirname(here)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def client_buildat():
    names = set()
    for fn in sorted(os.listdir(os.path.join(root, "client"))):
        if not fn.endswith(".lua"):
            continue
        text = read(os.path.join(root, "client", fn))
        for m in re.finditer(r"^\s*(?:function\s+)?(buildat(?:\.safe)?\.[A-Za-z_]\w*)\s*[=(]",
                text, re.M):
            names.add(m.group(1))
    return names


def block_members(text, start):
    """The keys of the table literal opening at text[start] ('{'),
    top level only. A key is a name and '=' right after '{' or ',':
    a function value's body is at the same depth, and its locals and
    assignments are not keys. Comments are blanked to the same length
    so that the indices stay those of text."""
    text = re.sub(r"--[^\n]*", lambda m: " " * len(m.group(0)), text)
    depth = 0
    keys = set()
    i = start
    line_start = True
    while i < len(text):
        c = text[i]
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return keys, i
        elif depth == 1:
            m = re.match(r"\s*([A-Za-z_]\w*)\s*=", text[i:i + 80])
            if m and text[:i + m.start(1)].rstrip()[-1:] in ("{", ","):
                keys.add(m.group(1))
                i += m.end() - 1
        i += 1
    return keys, i


def client_magic():
    names = set()
    text = read(os.path.join(root, "client/core/urho3d/safe_classes.lua"))
    for m in re.finditer(r'util\.wc\("(\w+)",\s*\{', text):
        cls = m.group(1)
        names.add("magic." + cls)
        members, _ = block_members(text, m.end() - 1)
        for section in ("instance", "properties", "class"):
            sm = re.search(r"\b%s\s*=\s*\{" % section, text[m.end():])
            if not sm:
                continue
            # only the section inside this class's own table
            _, close = block_members(text, m.end() - 1)
            if m.end() + sm.start() > close:
                continue
            keys, _ = block_members(text, m.end() + sm.end() - 1)
            for k in keys:
                names.add("magic.%s.%s" % (cls, k))
    # the constants: safe_globals.lua is a list of quoted names
    text = read(os.path.join(root, "client/core/urho3d/safe_globals.lua"))
    for m in re.finditer(r'^\s*"([A-Z][A-Z0-9_]*)",', text, re.M):
        names.add("magic." + m.group(1))
    for fn in ("safe_globals.lua", "safe_classes.lua"):
        text = read(os.path.join(root, "client/core/urho3d", fn))
        for m in re.finditer(r"^\s*(?:dst|Safe)\.([A-Za-z_]\w*)\s*=", text, re.M):
            names.add("magic." + m.group(1))
    text = read(os.path.join(root, "client/core/urho3d/init.lua"))
    for m in re.finditer(r"^\s*(?:function\s+)?Safe\.([A-Za-z_]\w*)\s*[=(]", text, re.M):
        names.add("magic." + m.group(1))
    return names


def client_extensions():
    names = set()
    ext_dir = os.path.join(root, "extensions")
    for ext in sorted(os.listdir(ext_dir)):
        path = os.path.join(ext_dir, ext, "init.lua")
        # sandbox_test's extensions are the hunt's, not an API
        if not os.path.isfile(path) or ext.startswith("sandbox_test"):
            continue
        text = read(path)
        for m in re.finditer(r"^\s*(?:function\s+)?M\.safe\.([A-Za-z_]\w*)\s*[=(]", text, re.M):
            names.add("extension.%s.%s" % (ext, m.group(1)))
        for m in re.finditer(r"M\.safe\s*=\s*\{", text):
            keys, _ = block_members(text, m.end() - 1)
            for k in keys:
                names.add("extension.%s.%s" % (ext, k))
    return names


def server_headers():
    names = set()
    for fn in sorted(os.listdir(os.path.join(root, "src/interface"))):
        # buildat_client.h is the client's ([CLIENT_WASM_BINDINGS]),
        # generated, and doc/client_api.txt lists its calls
        if fn.endswith(".h") and fn != "buildat_client.h":
            names.add("interface/" + fn)
    for b in sorted(os.listdir(os.path.join(root, "builtin"))):
        if os.path.isfile(os.path.join(root, "builtin", b, "api.h")):
            names.add("builtin/%s/api.h" % b)
    return names


def cpp_declarations(path):
    """The types and functions a C++ header declares, by name: struct and
    class names, free and member functions (virtual or not), typedefs,
    and the EVENT_ macros. simplified: line-based; a declaration split
    over lines is seen by its first line, which holds the name."""
    text = read(path)
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    names = []
    seen = set()
    for line in text.splitlines():
        line = re.sub(r"//.*", "", line).strip()
        if not line or line.startswith("#"):
            if line.startswith("#define ") and "EVENT_" in line:
                m = re.match(r"#define\s+(\w+)", line)
                if m and m.group(1) not in seen:
                    names.append(m.group(1)); seen.add(m.group(1))
            continue
        m = re.match(r"(?:struct|class)\s+(\w+)\b(?!\s*;)", line)
        if m and m.group(1) not in seen:
            names.append(m.group(1)); seen.add(m.group(1)); continue
        m = re.match(r"typedef\s+.*\b(\w+)\s*;", line)
        if m and m.group(1) not in seen:
            names.append(m.group(1)); seen.add(m.group(1)); continue
        m = re.match(r"(?:virtual\s+|static\s+|inline\s+|explicit\s+)*"
                r"[\w:<>,&*\s]+?[\s&*](~?\w+)\s*\(", line)
        if m and not line.startswith(("return", "if", "for", "while", "else",
                "switch", "throw", "delete", "new")) \
                and m.group(1) not in ("if", "for", "while", "switch", "sizeof",
                "return", "catch") and m.group(1) not in seen:
            names.append(m.group(1)); seen.add(m.group(1))
    return names


def server_listing(server):
    out = []
    for h in sorted(server):
        path = os.path.join(root, "src" if h.startswith("interface/") else "",
                h)
        out.append("%s: %s" % (h, ", ".join(cpp_declarations(path))))
    return "\n".join(out) + "\n"


def doc_names_text(text, prefixes):
    found = set()
    for p in prefixes:
        # Not inside a host name: forum.buildat.org is a URL
        for m in re.finditer(r"(?<![/\w.])" + re.escape(p) + r"[A-Za-z_][\w.]*", text):
            found.add(m.group(0).rstrip("."))
    return found


APPENDIX_BEGIN = "---- generated by util/api_names.py --appendix; do not edit ----"
APPENDIX_END = "---- end of the generated listing ----"


def appendix(client):
    """The sandboxed magic's members and the extensions' safe tables,
    one per line, grouped: what the doc carries verbatim as its last
    section, so that "every registered name is in the file" is a
    diff and not a reading."""
    out = []
    by_class = {}
    for n in sorted(client):
        parts = n.split(".")
        if parts[0] == "magic" and len(parts) == 2 and parts[1][:1].isupper():
            by_class.setdefault(parts[1], [])
        if parts[0] == "magic" and len(parts) == 3:
            by_class.setdefault(parts[1], []).append(parts[2])
    for cls in sorted(by_class):
        out.append("magic.%s: %s" % (cls, ", ".join(sorted(by_class[cls]))))
    globals_ = sorted(n.split(".")[1] for n in client
            if n.startswith("magic.") and n.count(".") == 1
            and not n.split(".")[1][:1].isupper())
    out.append("magic globals: " + ", ".join(globals_))
    constants = sorted(n.split(".")[1] for n in client
            if n.startswith("magic.") and n.count(".") == 1
            and n.split(".")[1].isupper())
    out.append("magic constants: " + ", ".join(constants))
    by_ext = {}
    for n in sorted(client):
        parts = n.split(".")
        if parts[0] == "extension":
            by_ext.setdefault(parts[1], []).append(parts[2])
    for ext in sorted(by_ext):
        out.append("extension.%s: %s" % (ext, ", ".join(sorted(by_ext[ext]))))
    return "\n".join(out) + "\n"


def documented(n, cdoc):
    """A buildat.safe.x is written as buildat.x in the doc's sandbox
    section; a magic member or an extension's member is in the
    appendix as "magic.Class: a, b" / "extension.name: a, b"."""
    parts = n.split(".")
    if parts[0] == "buildat":
        bare = "buildat." + parts[-1]
        return bare in cdoc or n in cdoc
    if parts[0] == "magic" and len(parts) == 2 and not parts[1][:1].isupper():
        for line in cdoc.splitlines():
            if line.startswith("magic globals:"):
                return parts[1] in [x.strip() for x in line[14:].split(",")]
        return False
    if parts[0] == "magic" and len(parts) == 2 and parts[1].isupper():
        for line in cdoc.splitlines():
            if line.startswith("magic constants:"):
                return parts[1] in [x.strip() for x in line[16:].split(",")]
        return False
    if len(parts) == 3:
        head = "%s.%s:" % (parts[0], parts[1])
        for line in cdoc.splitlines():
            if line.startswith(head):
                return parts[2] in [x.strip() for x in line[len(head):].split(",")]
        return False
    return n in cdoc


# ---- [KIT_API_1] Kit API 1's surface (kit_plan 4z37j (4)) ----
KIT = "builtin/kit"
KIT_DOC = "doc/kit_api1.txt"
KIT_BEGIN = "---- generated by util/api_names.py --kit-write; do not edit ----"

# box.c's PRELUDE under luajit, the Lua 5.1 the box is: stdin is frames
# "<length>\n<bytes>", box_math's making, the PRELUDE, then box requests,
# each answered on a line, "O<json>" or "E<error>"
BOX_LUA = r'''
local function frame()
	local n = tonumber(io.read("*l") or "")
	return n and io.read(n)
end
local none = function() end
box_log, box_mark, box_seed, box_cap = none, none, none, none
assert(loadstring(frame(), "=math"))()
assert(loadstring(frame(), "=kit"))()
for s in frame do
	local ok, r = pcall(box_request, s)
	io.write(ok and "O" or "E", (tostring(r):gsub("\n", " ")), "\n")
end
'''


def kit_read(p):
    return read(os.path.join(root, p))


def lua_lit(v):
    if v is None:
        return "nil"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return '"' + "".join(chr(c) if c < 128 and (chr(c).isalnum() or chr(c) in " _-.:/#")
                else "\\%d" % c for c in v.encode("utf-8")) + '"'
    if isinstance(v, list):
        return "{" + ",".join(lua_lit(x) for x in v) + "}"
    return "{" + ",".join("[%s]=%s" % (lua_lit(k), lua_lit(x))
            for k, x in v.items()) + "}"


def kit_prelude(box):
    """box.c's PRELUDE, the C string's Lua"""
    m = re.search(r"static const char PRELUDE\[\] =\n(.*?);\n", box, re.S)
    pre = "".join(re.findall(r'^"(.*)"$', m.group(1), re.M))
    pre = pre.encode("latin-1").decode("unicode_escape")
    return pre


def kit_box(requests):
    """Kit's types as the box defines them: box.c's PRELUDE run under
    luajit with move.lua loaded ("L"), then the requests; [(ok, answer)]"""
    box = kit_read(KIT + "/box/box.c")
    prelude = kit_prelude(box)
    names = re.findall(r'\{"(\w+)", l_\w+\}', box[box.find("luaL_Reg MATH[]"):])
    setup = "box_math = {%s}" % ", ".join("%s = math.%s" % (n, n) for n in names)
    frames = [setup, prelude, "L" + kit_read(KIT + "/client_lua/move.lua")]
    data = b"".join(b"%d\n%s" % (len(f), f) for f in
            (x.encode("utf-8") for x in frames + requests))
    out = subprocess.run(["luajit", "-e", BOX_LUA], input=data,
            capture_output=True, check=True).stdout.decode("utf-8").split("\n")
    if out[0] != "Otrue":
        raise SystemExit("the box did not load move.lua: " + out[0])
    return [(l[:1] == "O", l[1:]) for l in out[1:1 + len(requests)]]


def kit_types():
    """{name: its declaration as the box answers it}"""
    files = sorted(f for f in os.listdir(os.path.join(root, KIT, "types"))
            if f.endswith(".lua") and not f.endswith(".client.lua"))
    srcs = {"kit/" + f[:-4]: kit_read(KIT + "/types/" + f) for f in files}
    answers = kit_box(["D%s\0%s" % kv for kv in srcs.items()])
    out = {}
    for (name, src), (ok, a) in zip(srcs.items(), answers):
        if not ok:
            raise SystemExit("%s does not define: %s" % (name, a))
        out[name] = json.loads(a)
    return out


def kit_signals(v):
    """A type's inputs or outputs as kit.cpp's signals() reads them,
    {name: value type} (a label, "string:<label>", is the editor's)"""
    out = {}
    if isinstance(v, list):
        for n in v:
            out[n] = "any"
    elif isinstance(v, dict):
        for k, x in v.items():
            if k.isdigit() and isinstance(x, str):
                out[x] = "any"
            else:
                t = x if isinstance(x, str) else (x or {}).get("type", "")
                out[k] = t.split(":")[0]
    return out


def cpp_strings(src, after, until):
    """The quoted names of a C++ table: those between `after` and the
    first `until` past it, comments left out"""
    a = src.index(after)
    body = re.sub(r"//[^\n]*", "", src[a:src.index(until, a)])
    return re.findall(r'"([^"\\]*)"', body)


def kit_surface():
    """[(key, value)] of Kit API 1's surface: "" a key's value when its
    presence is the whole of it. Each list says where it comes from.
    simplified: the box's c, its inventory provider p and its env, the
    client parts' e and kit table, w's methods and kit.cpp's tables are
    read by regular expression from their source (a c field whose
    request value is nil is not there at a run, so a run of the box could
    not list it); the types, math and move.lua's math are run in the box
    (box.c's PRELUDE under luajit). A name made in a loop or by a helper
    is not seen: the check then fails on a removal, the moment to teach
    this script"""
    out = []
    add = lambda k, v="": out.append((k, v))
    kc = kit_read(KIT + "/kit.cpp")
    pre = kit_prelude(kit_read(KIT + "/box/box.c"))
    exp = cpp_strings(kc, "experimental_names()\n", "nullptr")

    def tag(key):
        for n in exp:
            n = n.rstrip("(")
            if key.endswith(n) and key[-len(n) - 1] in " .:":
                return " [internal]" if n.startswith((".", "w:")) else \
                        " [experimental]"
        return ""

    # Levels: src/interface/aitta.h's, jam.cpp's header, blip and weave
    aitta = kit_read("src/interface/aitta.h")
    for k in ("KIT_FORMAT", "KIT_API", "ENGINE_API"):
        add("format " + k, re.search(r"\b%s = (\d+);" % k, aitta).group(1))
    add("format jam", re.search(r'w\[1\] != "(\d+)"',
            kit_read("src/impl/jam.cpp")).group(1))
    for e in ("blip", "weave"):
        add("format " + e, re.search(r"^G\.VERSION = (\d+)", kit_read(
                "extensions/%s/%s_gen.lua" % (e, e)), re.M).group(1))
    # Server: the c a handler gets (box.c's run()), its inventory
    # provider's p (inventory()), a type file's environment (new_env())
    run = pre[pre.index("local function run(req)"):pre.index("local function step(req)")]
    srv = {}
    for mm in re.finditer(r"function c:(\w+)\(([^)]*)\)", run):
        srv.setdefault("server c:" + mm.group(1), "(%s)" % mm.group(2))
    for mm in re.finditer(r"(?<![\w.])((?:c\.\w+\s*,\s*)*c\.\w+)\s*=(?!=)", run):
        for f in re.findall(r"c\.(\w+)", mm.group(1)):
            srv.setdefault("server c." + f, "")
    keys, _ = block_members(run, run.index("local c = {") + 10)
    for f in keys:
        srv.setdefault("server c." + f, "")
    inv = pre[pre.index("local function inventory("):pre.index("local function run(req)")]
    for mm in re.finditer(r"function p:(\w+)\(([^)]*)\)", inv):
        srv["server inventory p:" + mm.group(1)] = "(%s)" % mm.group(2)
    for mm in re.finditer(r"\bp = \{", inv):
        for f in block_members(inv, mm.end() - 1)[0]:
            srv["server inventory p." + f] = ""
    keys, _ = block_members(pre, pre.index("local base = {") + 13)
    env = pre[pre.index("local function new_env("):]
    keys |= set(re.findall(r"^\s*e\.(\w+) = ", env[:env.index("\nend")], re.M))
    for g in keys:
        srv["server env " + g] = ""
    for lib, f in (("string", "lstrlib.c"), ("table", "ltablib.c")):
        src = kit_read(KIT + "/box/lua/" + f)
        for n in re.findall(r'\{"(\w+)", \w+\}', src):
            srv["server env %s.%s" % (lib, n)] = ""
    probe = "local function k(t) local r = {} for n in pairs(t) do " \
            "r[#r + 1] = n end table.sort(r) return r end "
    (ok1, a1), (ok2, a2) = kit_box([
            "Dprobe/env\0%sreturn {m = k(math)}" % probe,
            "Dprobe/move\0%sreturn {movement = {}, step = function() end, "
            "m = k(math)}" % probe])
    if not (ok1 and ok2):
        raise SystemExit("the box's probes: %s %s" % (a1, a2))
    for n in json.loads(a1)["m"]:
        srv["server env math." + n] = ""
    for n in json.loads(a2)["m"]:
        srv["move math." + n] = ""
    for h in cpp_strings(kc, "&handler_names()", "};"):
        srv["server handler " + h] = ""
    for f in cpp_strings(kc, "&type_fields()", "};"):
        srv["server type_field " + f] = ""
    a = kc.index("ss_ check_param(const json::Value &decl")
    for t in set(re.findall(r'\bt == "(\w+)"', kc[a:kc.index("\n\t}\n", a)])):
        srv["server param_type " + t] = ""
    for t in cpp_strings(kc, "SIGNAL_TYPES[] =", "};"):
        srv["server signal_type " + t] = ""
    # Reserved: kit_ in a type's params and state (type_table_faults()),
    # ext's player and kit_ (box.c's ext_ok()), the parameters Kit puts on
    # a type (load_type()), the type fields read as their new names
    a = kc.index("static sv_<ss_> type_table_faults(")
    tf = kc[a:kc.index("\n\t}\n", a)]
    pre_k = re.search(r'compare\(0, \d+, "(\w+)"\)', tf).group(1)
    for k in re.search(r"for\(const char \*k : \{([^}]*)\}\)", tf).group(1).split(","):
        srv["reserved %s.%s*" % (k.strip().strip('"'), pre_k)] = ""
    old_ = re.search(r'if\(([^)]*)\)\n\s*out\.push_back\(k\+" = true is reads_', tf)
    for old in re.findall(r'k == "(\w+)"', old_.group(1)):
        srv["reserved type_field " + old] = "reads_" + old
    ok_ = pre[pre.index("local function ext_ok("):]
    ok_ = ok_[:ok_.index("\n\tend\n")]
    for k in re.findall(r"k == '(\w+)'", ok_):
        srv["reserved ext." + k] = ""
    for k in re.findall(r"k:sub\(1, \d+\) == '(\w+)'", ok_):
        srv["reserved ext.%s*" % k] = ""
    injected = {}
    for p in re.findall(r'\\"(\w+)\\" is Kit\'s parameter', kc):
        at = kc.index('ps.set("%s", ' % p)
        var = re.match(r'ps\.set\("\w+", (\w+)\)', kc[at:]).group(1)
        blk = kc[kc.rindex('ps.get("%s")' % p, 0, at):at]
        d = {k: json.loads(v) for k, v in re.findall(
                r'\b%s\.set\("(type|default)", ([^)]*)\)' % var, blk)}
        injected[p] = {"default": d.get("default"), "kind": d.get("type")}
        srv["reserved param " + p] = json.dumps(injected[p], sort_keys=True)
    # simplified: which types get them, as load_type() decides it, by hand
    on = {"use": lambda d: d.get("usable") is True,
            "own_look": lambda d: isinstance(d.get("look"), dict)}
    if set(injected) != set(on):
        raise SystemExit("kit.cpp puts the parameters %s on types: teach "
                "api_names.py which types" % sorted(injected))
    for k in sorted(srv):
        add(k, (srv[k] + tag(k)).strip())
    # Client parts: their handlers (module.lua's call(), a movement's draw
    # controls.lua's movement_draw()), e (entity_view() and call()), the
    # kit table module.lua returns
    ml = kit_read(KIT + "/client_lua/module.lua")
    ctl = kit_read(KIT + "/client_lua/controls.lua")
    cl = {}
    for mm in re.finditer(r'call\(n, \w+, (?:inside and )?"(on_\w+)"(?: or "(on_\w+)")?', ml):
        for h in mm.groups():
            if h:
                cl["client handler " + h] = ""
    for h in re.findall(r'type\(part\.(\w+)\) == "function"', ctl):
        cl["client handler " + h] = ""
    a = ml.index("local function entity_view(")
    ev = ml[a:ml.index("\nend\n", a)]
    for f in block_members(ev, ev.index("local e = {") + 10)[0]:
        cl["client e." + f] = ""
    for mm in re.finditer(r"function e:(\w+)\(([^)]*)\)", ev):
        cl["client e:" + mm.group(1)] = "(%s)" % mm.group(2)
    a = ml.index("local function call(n, part, fn")
    for lhs in re.findall(r"^\t((?:e\.\w+, )*e\.\w+) = ", ml[a:ml.index("\nend\n", a)], re.M):
        for f in re.findall(r"e\.(\w+)", lhs):
            cl["client e." + f] = ""
    a = ml.index("local API = {")
    lua_src = "\n".join(kit_read(KIT + "/client_lua/" + f) for f in
            sorted(os.listdir(os.path.join(root, KIT, "client_lua"))) if f.endswith(".lua"))
    for k in block_members(ml, a + 12)[0] | set(re.findall(r'"(\w+)"', ml[a:ml.index("do\n", a)])):
        mm = re.search(r"^function M\.%s\(([^)]*)\)" % k, lua_src, re.M)
        cl["client kit." + k] = "(%s)" % mm.group(1) if mm else ""
    for k in sorted(cl):
        add(k, (cl[k] + tag(k)).strip())
    # Movements: the movement declaration's fields as controls.lua's decl()
    # and kit.cpp read them, move.lua's W methods
    mv = kit_read(KIT + "/client_lua/move.lua")
    lua_code = re.sub(r"--[^\n]*", "", lua_src)
    mo = {}
    fs = re.findall(r"decl\(\)\.(\w+)", lua_code) + \
            re.findall(r'"(\w+)"', " ".join(re.findall(r"decl\(\)\[([^]]*)\]", lua_code))) + \
            re.findall(r'get\("movement"\)\.get\("(\w+)"\)', kc) + \
            re.findall(r'jstr\([^;]*\.get\("movement"\), "(\w+)"\)', kc)
    # (local d = decl(): d.x to its function's end)
    for mm in re.finditer(r"local (\w+) = decl\(\)\n", lua_code):
        body = lua_code[mm.end():lua_code.index("\nend", mm.end())]
        fs += re.findall(r"\b%s\.(\w+)" % mm.group(1), body)
    for f in fs:
        mo["move movement." + f] = ""
    for mm in re.finditer(r"^function W:(\w+)\(([^)]*)\)", mv, re.M):
        mo["move w:" + mm.group(1)] = "(%s)" % mm.group(2)
    # simplified: w's fields and s's are the ones move.lua's head comment
    # names (w is copied from W and filled in by M.world(), s is a step's
    # own table: no one place in the code lists them); i's are those
    # controls.lua makes (kit.cpp takes a client's); reading the code is
    # the upgrade
    head = mv[:mv.index("\nlocal ")]
    a = head.index("Kit API 1's w is these")
    for f in re.findall(r"w\.(\w+)", head[a:head.index("(below", a)]):
        mo["move w." + f] = ""
    for f in set(re.findall(r"\bs\.(\w+)", head)):
        mo["move s." + f] = ""
    code = re.sub(r"--[^\n]*", "", ctl)
    a = code.index("local i = {")
    for f in block_members(code, a + 10)[0] | set(re.findall(r"\bi\.(\w+)\s*=(?!=)", code)):
        mo["move i." + f] = ""
    for k in sorted(mo):
        add(k, (mo[k] + tag(k)).strip())
    # The builtin types (as the box defines them), and the prefabs, items,
    # sounds and voxels Kit ships
    for name, d in sorted(kit_types().items()):
        x = " [experimental]" if d.get("experimental") is True else ""
        add("type " + name, "version %s%s" % (d.get("version", 1), x))
        handlers = sorted(d.get("handlers") or [])
        add("type %s handlers" % name, (" ".join(handlers) + x).strip())
        ps = dict(d.get("params") or {})
        ps.update({p: {"type": v["kind"], "default": v["default"]}
                for p, v in injected.items() if on[p](d)})
        for p, pd in sorted(ps.items()):
            pd = pd if isinstance(pd, dict) else {"default": pd}
            v = {"kind": pd.get("type"), "default": pd.get("default")}
            for k in ("min", "max", "choices"):
                if k in pd:
                    v[k] = pd[k]
            k = "type %s param %s" % (name, p)
            add(k, json.dumps(v, sort_keys=True) + (x or tag(k)))
        for io_ in ("input", "output"):
            for s, t in sorted(kit_signals(d.get(io_ + "s")).items()):
                k = "type %s %s %s" % (name, io_, s)
                add(k, t + (x or tag(k)))
        for s, sd in sorted((d.get("state") or {}).items()):
            fl = [k for k in ("shared", "per_player", "kept")
                    if isinstance(sd, dict) and sd.get(k) is True]
            add("type %s state %s" % (name, s), (" ".join(fl) + x).strip())
    tdir = os.listdir(os.path.join(root, KIT, "types"))
    for kind in ("prefab", "item"):
        for f in sorted(tdir):
            if f.endswith(".%s.json" % kind):
                add("builtin %s kit/%s" % (kind, f[:-len(".%s.json" % kind)]))
    for n in sorted(json.loads(kit_read(KIT + "/sounds.json"))["sounds"]):
        add("builtin sound " + n)
    for n in sorted(json.loads(kit_read(KIT + "/materials.json"))["voxels"]):
        add("builtin voxel " + n)
    return out


def kit_listing(surface):
    return "".join(k + (" | " + v if v else "") + "\n" for k, v in surface)


def kit_parse(text):
    """The doc's listing and deprecations: {key: value}, {key: level}"""
    a = text.index(KIT_BEGIN)
    listing = {}
    for l in text[a + len(KIT_BEGIN):text.index(APPENDIX_END, a)].split("\n"):
        if not l:
            continue
        k, _, v = l.partition(" | ")
        listing[k] = v
    dep = {m.group(1): int(m.group(2)) for m in re.finditer(
            r"^deprecated: (.+?) \| (\d+)\b", text[:a], re.M)}
    return listing, dep


def kit_check():
    """The code's surface against the doc's: 0 when nothing promised went
    away or changed, 1 with each fault said"""
    text = read(os.path.join(root, KIT_DOC))
    old, dep = kit_parse(text)
    new = dict(kit_surface())
    level = int(new["format KIT_API"])
    faults, notes, migrates = [], [], []

    def free(k, v):
        # experimental or internal, or under an experimental type
        t = re.match(r"type (\S+)", k)
        return v.endswith(("[experimental]", "[internal]")) or \
                (t and old.get("type " + t.group(1), "").endswith("[experimental]"))

    def covered(k):
        return k in dep and dep[k] <= level

    def gone_type(k):
        # a key of a type that is gone: the type's own key says it
        t = re.match(r"type (\S+) ", k)
        return t and "type " + t.group(1) not in new

    for k, v in old.items():
        nv = new.get(k)
        if nv == v or free(k, v) or covered(k) or gone_type(k):
            if nv != v:
                notes.append(k)
            continue
        pm = re.match(r"type (\S+) param (\S+)$", k)
        if pm:
            migrates.append((pm.group(1), pm.group(2), json.loads(v),
                    json.loads(nv.removesuffix(" [experimental]"))
                    if nv is not None else None))
        elif nv is None:
            faults.append("%s: removed (a deprecation in %s at level <= %d "
                    "covers a removal)" % (k, KIT_DOC, level))
        elif re.match(r"type \S+ (input|output) ", k):
            faults.append("%s: its value type was %s, is %s" % (k, v, nv))
        elif k.startswith("format ") and int(nv) < int(v) or \
                re.match(r"type \S+$", k) and int(nv.split()[1]) < int(v.split()[1]):
            faults.append("%s: went down, %s to %s" % (k, v, nv))
        else:
            notes.append(k)
    adds = [k for k in new if k not in old]
    # A parameter's change: covered by its type's version raised and a
    # migrate that takes an old instance forward
    reqs, cases = [], []
    srcs = {}
    inf = float("inf")
    ch = lambda d: None if "choices" not in d else set(map(json.dumps, d["choices"]))
    for t, p, o, n in migrates:
        # (it takes every value it did: the same kind and default, its
        # range and choices no narrower)
        if n is not None and (n["kind"], n["default"]) == (o["kind"], o["default"]) and \
                n.get("min", -inf) <= o.get("min", -inf) and \
                n.get("max", inf) >= o.get("max", inf) and \
                (ch(n) is None or ch(o) is not None and ch(o) <= ch(n)):
            notes.append("type %s param %s" % (t, p))
            continue
        ov = int(old["type " + t].split()[1])
        nv_ = int(new["type " + t].split()[1])
        if nv_ <= ov or "migrate" not in new.get("type %s handlers" % t, "").split():
            faults.append("type %s param %s: %s, and %s (a raised version and a "
                    "migrate(params, from) take an old instance forward)" % (
                    t, p, "removed" if n is None else "changed to " +
                    json.dumps(n, sort_keys=True), "its version is still %d" % ov
                    if nv_ <= ov else "it has no migrate"))
            continue
        src = srcs.setdefault(t, read(os.path.join(root, KIT, "types", t[4:] + ".lua")))
        # (an old instance: every parameter the listing has at its default,
        # p left out where its default changed)
        given = {q[len("type %s param " % t):]: json.loads(v_.removesuffix(
                " [experimental]"))["default"] for q, v_ in old.items()
                if q.startswith("type %s param " % t)}
        if n is not None and n["kind"] == o["kind"]:
            del given[p]
        elif given[p] is None:
            given[p] = "x"
        reqs.append("Mreturn {type=%s,from=%d,params=%s}" % (lua_lit(t), ov, lua_lit(given)))
        cases.append((t, p, o, n, given))
    if reqs:
        defs = ["D%s\0%s" % kv for kv in srcs.items()]
        answers = kit_box(defs + reqs)[len(defs):]
        for (t, p, o, n, given), (ok, a) in zip(cases, answers):
            # (the box's JSON of an empty table is [])
            got = (json.loads(a) or {}) if ok else None
            if got is None:
                why = "its migrate failed: " + a
            elif n is None:
                why = "" if p not in got else "migrate keeps %s, which it no " \
                        "longer declares" % p
            elif p in given:
                why = "" if got.get(p) != given[p] else "migrate leaves the " \
                        "old value of the old kind as it was"
            elif n["default"] != o["default"]:
                why = "" if got.get(p) == o["default"] else "migrate from %d of {} " \
                        "makes %s %s, not the old default %s" % (
                        int(old["type " + t].split()[1]), p, json.dumps(got.get(p)),
                        json.dumps(o["default"]))
            else:
                why = ""  # simplified: a narrowed range or choices: the
                # version raised and a migrate, which is not run on a value
            if why:
                faults.append("type %s param %s: %s" % (t, p, why))
            else:
                notes.append("type %s param %s (migrated)" % (t, p))
    for f in faults:
        print("FAULT: " + f)
    if adds or notes:
        print("%d additions, %d other changes (%s): within Kit API 1, regenerate "
                "with util/api_names.py --kit-write" % (len(adds), len(notes),
                ", ".join((adds + notes)[:6]) + (", ..." if len(adds + notes) > 6 else "")))
    print("%d faults" % len(faults))
    return 1 if faults else 0


def main():
    if "--kit" in sys.argv:
        sys.stdout.write(kit_listing(kit_surface()))
        return 0
    if "--kit-write" in sys.argv:
        path = os.path.join(root, KIT_DOC)
        text = read(path)
        a, b = text.find(KIT_BEGIN), text.find(APPENDIX_END)
        text = text[:a + len(KIT_BEGIN)] + "\n" + kit_listing(kit_surface()) + text[b:]
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return 0
    if "--kit-check" in sys.argv:
        return kit_check()
    client = client_buildat() | client_magic() | client_extensions()
    server = server_headers()
    cpath = os.path.join(root, "doc/client_api.txt")
    spath = os.path.join(root, "doc/server_api.txt")
    if "--appendix" in sys.argv:
        sys.stdout.write(appendix(client))
        sys.stdout.write(server_listing(server))
        return 0
    if "--write-appendix" in sys.argv:
        for path, body in ((cpath, appendix(client)),
                (spath, server_listing(server))):
            text = read(path)
            a, b = text.find(APPENDIX_BEGIN), text.find(APPENDIX_END)
            if a < 0 or b < 0:
                print("no appendix markers in %s" % path, file=sys.stderr)
                return 1
            text = text[:a + len(APPENDIX_BEGIN)] + "\n" + body + text[b:]
            with open(path, "w", encoding="utf-8") as f:
                f.write(text)
        return 0
    if "--check" not in sys.argv:
        for n in sorted(client) + sorted(server):
            print(n)
        return 0
    bad = 0
    cdoc = read(cpath)
    for n in sorted(client):
        if not documented(n, cdoc):
            print("client_api.txt lacks %s" % n)
            bad += 1
    body = cdoc.split(APPENDIX_BEGIN)[0]
    in_doc = doc_names_text(body, ["buildat.", "magic.", "extension."])
    registered_bare = set("buildat." + n.split(".")[-1] for n in client
            if n.startswith("buildat."))
    registered_bare.add("buildat.is_in_sandbox")  # set in sandbox.lua by another path
    for n in sorted(in_doc):
        if n in client or n in registered_bare:
            continue
        if any(c.startswith(n + ".") for c in client):
            continue
        # a field of a registered table or class: buildat.VOXEL_RAY.BLOCKED,
        # magic.ui.root -- the parent is what the code registers
        parent = n.rsplit(".", 1)[0]
        if parent in client or parent in registered_bare:
            continue
        print("client_api.txt names %s, which the code does not" % n)
        bad += 1
    sdoc = read(spath) if os.path.isfile(spath) else ""
    sbody = sdoc.split(APPENDIX_BEGIN)[0]
    for n in sorted(server):
        if n not in sbody:
            print("server_api.txt lacks a section for %s" % n)
            bad += 1
    # the listing is what the code declares now
    if APPENDIX_BEGIN in sdoc:
        have = sdoc.split(APPENDIX_BEGIN)[1].split(APPENDIX_END)[0].strip()
        if have != server_listing(server).strip():
            print("server_api.txt's listing is stale: run --write-appendix")
            bad += 1
    if APPENDIX_BEGIN in cdoc:
        have = cdoc.split(APPENDIX_BEGIN)[1].split(APPENDIX_END)[0].strip()
        if have != appendix(client).strip():
            print("client_api.txt's listing is stale: run --write-appendix")
            bad += 1
    print("%d findings" % bad)
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
