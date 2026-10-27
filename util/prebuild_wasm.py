#!/usr/bin/env python3
# Each module's wasm/ built into <out>/<hash>.wasm, the name the server
# gives it (src/server/wasm_build.cpp: build_module_wasm), for an archive's
# cache/rccpp_build/wasm/ ([PACKAGE_PREBUILT_WASM]): a packaged server
# without clang and wasm-ld serves these. The key and the flags are the
# server's; the flags are read from its source, so they cannot drift. A key
# that does drift shows as the packaged server not finding the file
# (util/package.sh's smoke greps "wasm/ is in the shared build"). A .wasm is
# the same for every platform, so the Windows archive's are built here too.
#
#   util/prebuild_wasm.py <clang> <wasm-ld> <interface dir> <out dir> <module dir>...
#
# A module dir is one with a wasm/ in it (builtin/voxelworld,
# apps/hillclimb/main).
import hashlib, os, re, subprocess, sys, tempfile

if len(sys.argv) < 6:
    sys.exit("usage: prebuild_wasm.py <clang> <wasm-ld> <interface dir> <out dir> <module dir>...")
cc, ld, interface, out = sys.argv[1:5]
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(here, "src/server/wasm_build.cpp")).read()
cflags = re.search(r'WASM_CFLAGS = "([^"]*)"', src).group(1)
ldflags = re.search(r'WASM_LDFLAGS = "([^"]*)"', src).group(1)
api = open(os.path.join(interface, "wasm_api.h"), "rb").read()
os.makedirs(out, exist_ok=True)

def collect(d, prefix=""):
    # The server's order: std::sort of the relative names, "/" between
    files = []
    for n in os.listdir(d):
        p = os.path.join(d, n)
        files += collect(p, prefix + n + "/") if os.path.isdir(p) else [prefix + n]
    return files

for module in sys.argv[5:]:
    wasm_dir = os.path.join(module, "wasm")
    files = sorted(collect(wasm_dir), key=lambda s: s.encode())
    key = b"buildat wasm 1\n" + cflags.encode() + b"\n" + ldflags.encode() + b"\n" + api
    for f in files:
        data = open(os.path.join(wasm_dir, f), "rb").read()
        key += f.encode() + b"\0" + str(len(data)).encode() + b"\0" + data
    target = os.path.join(out, hashlib.sha1(key).hexdigest() + ".wasm")
    with tempfile.TemporaryDirectory() as tmp:
        objs = []
        for i, f in enumerate(s for s in files if s.endswith((".c", ".cc", ".cpp"))):
            lang = ["-std=c11"] if f.endswith(".c") else ["-std=c++17", "-fno-exceptions", "-fno-rtti"]
            objs.append(os.path.join(tmp, "%d.o" % i))
            subprocess.run([cc] + cflags.split() + lang + ["-I" + os.path.dirname(os.path.abspath(interface)),
                "-c", os.path.join(wasm_dir, f), "-o", objs[-1]], check=True)
        if not objs:
            sys.exit("%s: wasm/ has no .c, .cc or .cpp" % module)
        flavor = ["-flavor", "wasm"] if os.path.basename(ld).startswith("rust-lld") else []
        subprocess.run([ld] + flavor + ldflags.split() + objs + ["-o", target], check=True)
    print("%s: %s (%d bytes)" % (module, target, os.path.getsize(target)))
