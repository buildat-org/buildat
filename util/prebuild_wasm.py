#!/usr/bin/env python3
# Each module's wasm/ built into <out>/<hash>.wasm, the name the server
# gives it (src/server/wasm_build.cpp: build_module_wasm), and its server
# .wasm too when its meta.json names a "server_wasm" ([SERVER_WASM]), for an archive's
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
# apps/hillclimb/main) or a "server_wasm" in its meta.json. A Rust crate
# (Cargo.toml) is built by cargo as the server's build_rust() does, the
# module's other crates beside it: BUILDAT_CARGO, else cargo in PATH, else
# ~/.cargo/bin/cargo. --by-name names each <module>.wasm instead, the name
# the static web server looks for (util/web_server.cmake), and builds the
# clients' wasm/ only.
import hashlib, json, os, re, shutil, subprocess, sys, tempfile

by_name = sys.argv[1:2] == ["--by-name"]
if by_name:
    del sys.argv[1]
if len(sys.argv) < 6:
    sys.exit("usage: prebuild_wasm.py [--by-name] <clang> <wasm-ld> <interface dir> <out dir> <module dir>...")
cc, ld, interface, out = sys.argv[1:5]
here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
src = open(os.path.join(here, "src/server/wasm_build.cpp")).read()
cflags = re.search(r'WASM_CFLAGS = "([^"]*)"', src).group(1)
ldflags = re.search(r'WASM_LDFLAGS = "([^"]*)"', src).group(1)
rustflags = re.search(r'RUST_FLAGS = "([^"]*)"', src).group(1)
rust_target = re.search(r'RUST_TARGET = "([^"]*)"', src).group(1)
api = open(os.path.join(interface, "wasm_api.h"), "rb").read()
server_api = open(os.path.join(interface, "wasm_server_api.h"), "rb").read()
crate_dir = os.path.join(os.path.abspath(interface), "rust/buildat_wasm")
server_crate_dir = os.path.join(os.path.abspath(interface), "rust/buildat_wasm_server")
os.makedirs(out, exist_ok=True)

def collect(d, prefix=""):
    # The server's order: std::sort of the relative names, "/" between;
    # its listing leaves out names beginning with "." (an editor's swap file)
    files = []
    for n in os.listdir(d):
        if n.startswith("."):
            continue
        p = os.path.join(d, n)
        files += collect(p, prefix + n + "/") if os.path.isdir(p) else [prefix + n]
    return files

def keyed(d, files):
    key = b""
    for f in files:
        data = open(os.path.join(d, f), "rb").read()
        key += f.encode() + b"\0" + str(len(data)).encode() + b"\0" + data
    return key

def no_target(files):
    return [f for f in files if not f.startswith("target/")]

def engine_crate(d):
    crate = sorted(collect(d), key=lambda s: s.encode())
    return keyed(d, [f for f in no_target(crate) if f != "Cargo.lock"])

def sibling_crates(module, source):
    # The module's other top-level crates, as the server's sibling_crates()
    r = []
    for n in os.listdir(module):
        p = os.path.join(module, n)
        if n == source or n.startswith(".") or not os.path.isdir(p) or \
                not os.path.exists(os.path.join(p, "Cargo.toml")):
            continue
        r.append((n, sorted(no_target(collect(p)), key=lambda s: s.encode())))
    return sorted(r, key=lambda c: c[0].encode())

def cargo_build(module, source, files, target):
    cargo = os.environ.get("BUILDAT_CARGO") or shutil.which("cargo") or \
        os.path.expanduser("~/.cargo/bin/cargo")
    with tempfile.TemporaryDirectory() as tmp:
        for d, fs in sibling_crates(module, source) + [(source, files)]:
            for f in fs:
                to = os.path.join(tmp, "src", d, f)
                os.makedirs(os.path.dirname(to), exist_ok=True)
                shutil.copyfile(os.path.join(module, d, f), to)
        env = dict(os.environ, CARGO_HOME=os.path.join(tmp, "cargo_home"),
            CARGO_ENCODED_RUSTFLAGS=rustflags.replace(" ", "\x1f"))
        env.pop("RUSTFLAGS", None)
        subprocess.run([cargo, "build", "--offline", "--release", "--target", rust_target,
            "--manifest-path", os.path.join(tmp, "src", source, "Cargo.toml"),
            "--target-dir", os.path.join(tmp, "target"),
            "--config", 'patch.crates-io.buildat_wasm.path="%s"' % crate_dir,
            "--config", 'patch.crates-io.buildat_wasm_server.path="%s"' % server_crate_dir,
            "--config", 'profile.release.panic="abort"'], env=env, check=True)
        rel = os.path.join(tmp, "target", rust_target, "release")
        built = [n for n in os.listdir(rel) if n.endswith(".wasm")]
        if len(built) != 1:
            sys.exit("%s/%s: cargo made %d .wasm files, not one" % (module, source, len(built)))
        shutil.copyfile(os.path.join(rel, built[0]), target)

def build(module, source, server):
    wasm_dir = os.path.join(module, source)
    files = sorted(collect(wasm_dir), key=lambda s: s.encode())
    rust = os.path.exists(os.path.join(wasm_dir, "Cargo.toml"))
    if rust:
        files = no_target(files)
    key = b"buildat wasm 1\n" + cflags.encode() + b"\n" + ldflags.encode() + b"\n" + api
    key += keyed(wasm_dir, files)
    # The generated bindings, for the modules that include them only
    if any(b"buildat_client.h" in open(os.path.join(wasm_dir, f), "rb").read() for f in files):
        key += b"bindings 1\n" + open(os.path.join(interface, "buildat_client.h"), "rb").read()
    if rust:
        key += b"rust 1\n" + rustflags.encode() + b"\n" + rust_target.encode() + b"\n"
        key += engine_crate(crate_dir)
        for d, fs in sibling_crates(module, source):
            key += b"crate " + d.encode() + b"\n" + keyed(os.path.join(module, d), fs)
    if server:
        key += b"server 1\n" + server_api
        if rust:
            key += engine_crate(server_crate_dir)
    name = os.path.basename(os.path.normpath(module)) if by_name else hashlib.sha1(key).hexdigest()
    target = os.path.join(out, name + ".wasm")
    if rust:
        cargo_build(module, source, files, target)
        print("%s: %s/: %s (%d bytes)" % (module, source, target, os.path.getsize(target)))
        return
    with tempfile.TemporaryDirectory() as tmp:
        objs = []
        for i, f in enumerate(s for s in files if s.endswith((".c", ".cc", ".cpp"))):
            lang = ["-std=c11"] if f.endswith(".c") else ["-std=c++17", "-fno-exceptions", "-fno-rtti"]
            objs.append(os.path.join(tmp, "%d.o" % i))
            subprocess.run([cc] + cflags.split() + lang + ["-I" + os.path.dirname(os.path.abspath(interface)),
                "-c", os.path.join(wasm_dir, f), "-o", objs[-1]], check=True)
        if not objs:
            sys.exit("%s: %s/ has no .c, .cc or .cpp" % (module, source))
        flavor = ["-flavor", "wasm"] if os.path.basename(ld).startswith("rust-lld") else []
        subprocess.run([ld] + flavor + ldflags.split() + objs + ["-o", target], check=True)
    print("%s: %s/: %s (%d bytes)" % (module, source, target, os.path.getsize(target)))

for module in sys.argv[5:]:
    built = False
    if os.path.isdir(os.path.join(module, "wasm")):
        build(module, "wasm", False)
        built = True
    meta = os.path.join(module, "meta.json")
    source = os.path.exists(meta) and (json.load(open(meta)).get("server_wasm") or {}).get("source")
    if source and not by_name:
        build(module, source, True)
        built = True
    if not built:
        sys.exit("%s: no wasm/%s" % (module, "" if by_name else " and no server_wasm"))
