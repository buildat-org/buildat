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
# apps/hillclimb/main). A Rust wasm/ (Cargo.toml) is built by cargo as the
# server's build_rust() does: BUILDAT_CARGO, else cargo in PATH, else
# ~/.cargo/bin/cargo. --by-name names each <module>.wasm instead, the name
# the static web server looks for (util/web_server.cmake).
import hashlib, os, re, shutil, subprocess, sys, tempfile

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
crate_dir = os.path.join(os.path.abspath(interface), "rust/buildat_wasm")
os.makedirs(out, exist_ok=True)

def collect(d, prefix=""):
    # The server's order: std::sort of the relative names, "/" between
    files = []
    for n in os.listdir(d):
        p = os.path.join(d, n)
        files += collect(p, prefix + n + "/") if os.path.isdir(p) else [prefix + n]
    return files

def keyed(d, files):
    key = b""
    for f in files:
        data = open(os.path.join(d, f), "rb").read()
        key += f.encode() + b"\0" + str(len(data)).encode() + b"\0" + data
    return key

def cargo_build(wasm_dir, files, target):
    cargo = os.environ.get("BUILDAT_CARGO") or shutil.which("cargo") or \
        os.path.expanduser("~/.cargo/bin/cargo")
    with tempfile.TemporaryDirectory() as tmp:
        for f in files:
            os.makedirs(os.path.dirname(os.path.join(tmp, "src", f)), exist_ok=True)
            shutil.copyfile(os.path.join(wasm_dir, f), os.path.join(tmp, "src", f))
        env = dict(os.environ, CARGO_HOME=os.path.join(tmp, "cargo_home"),
            CARGO_ENCODED_RUSTFLAGS=rustflags.replace(" ", "\x1f"))
        env.pop("RUSTFLAGS", None)
        subprocess.run([cargo, "build", "--offline", "--release", "--target", rust_target,
            "--manifest-path", os.path.join(tmp, "src/Cargo.toml"),
            "--target-dir", os.path.join(tmp, "target"),
            "--config", 'patch.crates-io.buildat_wasm.path="%s"' % crate_dir,
            "--config", 'profile.release.panic="abort"'], env=env, check=True)
        rel = os.path.join(tmp, "target", rust_target, "release")
        built = [n for n in os.listdir(rel) if n.endswith(".wasm")]
        if len(built) != 1:
            sys.exit("%s: cargo made %d .wasm files, not one" % (wasm_dir, len(built)))
        shutil.copyfile(os.path.join(rel, built[0]), target)

for module in sys.argv[5:]:
    wasm_dir = os.path.join(module, "wasm")
    files = sorted(collect(wasm_dir), key=lambda s: s.encode())
    rust = os.path.exists(os.path.join(wasm_dir, "Cargo.toml"))
    if rust:
        files = [f for f in files if not f.startswith("target/")]
    key = b"buildat wasm 1\n" + cflags.encode() + b"\n" + ldflags.encode() + b"\n" + api
    key += keyed(wasm_dir, files)
    # The generated bindings, for the modules that include them only
    if any(b"buildat_client.h" in open(os.path.join(wasm_dir, f), "rb").read() for f in files):
        key += b"bindings 1\n" + open(os.path.join(interface, "buildat_client.h"), "rb").read()
    if rust:
        key += b"rust 1\n" + rustflags.encode() + b"\n" + rust_target.encode() + b"\n"
        crate = sorted(collect(crate_dir), key=lambda s: s.encode())
        key += keyed(crate_dir, [f for f in crate if not f.startswith("target/") and f != "Cargo.lock"])
    name = os.path.basename(os.path.normpath(module)) if by_name else hashlib.sha1(key).hexdigest()
    target = os.path.join(out, name + ".wasm")
    if rust:
        cargo_build(wasm_dir, files, target)
        print("%s: %s (%d bytes)" % (module, target, os.path.getsize(target)))
        continue
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
