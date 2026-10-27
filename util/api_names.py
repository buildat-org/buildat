#!/usr/bin/env python3
"""The names a game's Lua and a C++ module can reach, listed from the
code, so that doc/client_api.txt and doc/server_api.txt can be checked
against them ([CLIENT_API_DOC]).

    util/api_names.py            # the listing, one name per line
    util/api_names.py --check    # names the docs lack, names the docs
                                 # have that the code does not; exit 1
                                 # on either

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
"""
import os
import re
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
        if not os.path.isfile(path):
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
        for m in re.finditer(r"(?<![/\w])" + re.escape(p) + r"[A-Za-z_][\w.]*", text):
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


def main():
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
