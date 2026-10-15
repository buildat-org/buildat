#!/usr/bin/env python3
# What Urho3D exposes to Lua, against what client/core/urho3d/safe_classes.lua
# lets a server's Lua reach. Prints the classes that are neither wrapped nor
# refused, per subsystem, so that a whitelist sweep has a finish line and the
# next one starts where the last stopped.
#
# See [URHO_SWEEP] and [WHITELIST_POLICY] in doc/plan/master_plan.md: the
# whitelist is a list of what has been looked at, and a class looked at and
# rejected is worth a line saying so, or the next sweep looks at it again.
#
# Usage: util/whitelist_sweep.py [subsystem ...]
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKGS = os.path.join(ROOT, "3rdparty/Urho3D/Source/Urho3D/LuaScript/pkgs")
SAFE = os.path.join(ROOT, "client/core/urho3d/safe_classes.lua")

# Not in scope, and why; see the plan. Nothing here is counted as missing.
OUT_OF_SCOPE = {
    "Urho2D": "nothing here uses it, so a sweep would be guesswork",
    "Navigation": "nothing here uses it, so a sweep would be guesswork",
    "Script": "loading code is what the sandbox exists to stop",
    "LuaScript": "loading code is what the sandbox exists to stop",
    "Database": "reaches a database of its own",
    "Network": "reaches the network",
}


def exposed():
    """Every class tolua exposes, as {subsystem: [class, ...]}."""
    out = {}
    for sub in sorted(os.listdir(PKGS)):
        d = os.path.join(PKGS, sub)
        if not os.path.isdir(d):
            continue
        names = []
        for f in sorted(os.listdir(d)):
            if not f.endswith(".pkg"):
                continue
            text = open(os.path.join(d, f), encoding="utf-8",
                        errors="replace").read()
            for m in re.finditer(r"^class\s+([A-Za-z_]\w*)", text, re.M):
                names.append(m.group(1))
        if names:
            out[sub] = sorted(set(names))
    return out


def looked_at():
    """Wrapped and refused, out of safe_classes.lua."""
    text = open(SAFE, encoding="utf-8").read()
    wrapped = set(re.findall(r'util\.wc\("([A-Za-z_]\w*)"', text))
    refused = {}
    for m in re.finditer(r"^\s*--\s*refused:\s*([A-Za-z_]\w*)\s*--\s*(.*)$",
                         text, re.M):
        refused[m.group(1)] = m.group(2).strip()
    return wrapped, refused


def main():
    want = set(sys.argv[1:])
    wrapped, refused = looked_at()
    total_missing = 0
    for sub, names in sorted(exposed().items()):
        if want and sub not in want:
            continue
        if sub in OUT_OF_SCOPE and not want:
            print("%s: out of scope -- %s" % (sub, OUT_OF_SCOPE[sub]))
            continue
        missing = [n for n in names
                   if n not in wrapped and n not in refused]
        total_missing += len(missing)
        print("%s: %d of %d looked at%s" % (
            sub, len(names) - len(missing), len(names),
            (", missing " + ", ".join(missing)) if missing else ""))
    if refused:
        print()
        for name in sorted(refused):
            print("refused: %s -- %s" % (name, refused[name]))
    print()
    print("%d classes neither wrapped nor refused" % total_missing)


if __name__ == "__main__":
    main()
