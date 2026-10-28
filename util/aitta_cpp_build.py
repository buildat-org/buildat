#!/usr/bin/env python3
# [WEB_LOCAL_AITTA_CPP] Aitta's build of a release's C++ server for the page:
# the engine's server for packages (src/server/web/_aitta, web/local/_aitta)
# linked again with the release's C++ modules in it, by a fixed script, no
# flag of the author's.
#
#   util/aitta_cpp_build.py kit <build dir> <kit dir>
#     After util/build_web_server.sh built _aitta in <build dir>
#     (Build-webserver): its objects, libraries, flags, headers, packed files
#     and outputs copied into <kit dir>, which an Aitta names in
#     BUILDAT_AITTA_CPP_KIT. kit/emsdk is a link to the emsdk it was built
#     with, kit/build.py this script. Made on the Aitta host itself: the
#     emsdk's cache there must have what the link reads (it cannot write
#     there).
#   python3 -I <kit>/build.py build <kit dir> <job dir>
#     In the build's box (src/server/confine.cpp, build_wasm_job()): the
#     release in <job>/src; each C++ module compiled, the module table made
#     and the server linked with the kit's flags into <job>/bin/
#     buildat_server.{js,wasm}. Aitta then checks them against
#     <kit>/ref/ (apps/aitta/main/main.cpp, cpp_server_check()).
import json, os, re, shlex, shutil, subprocess, sys

PLAIN = re.compile(r"^[A-Za-z0-9_]{1,64}$")
HEADERS = (".h", ".hh", ".hpp", ".hxx", ".inl", ".ipp", ".tcc", ".inc")

def die(why):
    print("cpp build: " + why, flush=True)
    sys.exit(1)

def make_kit(build, kit):
    build, kit = os.path.abspath(build), os.path.abspath(kit)
    d = os.path.join(build, "CMakeFiles/buildat_server.dir")
    table = open(os.path.join(build, "web_server_modules.cpp")).read()
    if not table.split("\n")[0].endswith("/src/server/web/_aitta"):
        die(build + " is not a build of src/server/web/_aitta")
    if os.path.exists(kit):
        shutil.rmtree(kit)
    for sub in ("obj", "lib", "inc", "share", "pre", "ref"):
        os.makedirs(os.path.join(kit, sub))
    k = {"builtins": re.findall(r'\{"([A-Za-z0-9_]+)", createModule_', table)}
    # The objects, the table's own left out (each build makes it again)
    k["objects"] = []
    # The objects' file as link.txt names it: objects1.rsp, or objects1
    # in an older CMake (packaging's 3.25)
    rsp = [a[1:] for a in shlex.split(open(os.path.join(d, "link.txt")).read())
            if a.startswith("@") and os.path.basename(a).startswith("objects")]
    if len(rsp) != 1:
        die("link.txt names %d objects files" % len(rsp))
    for i, o in enumerate(shlex.split(open(os.path.join(build, rsp[0])).read())):
        if o.endswith("/web_server_modules.cpp.o"):
            k["objects"].append("@TABLE@")
            continue
        to = "obj/%03d_%s" % (i, os.path.basename(o))
        shutil.copyfile(os.path.join(build, o), os.path.join(kit, to))
        k["objects"].append(to)
    k["libs"] = []
    for i, l in enumerate(shlex.split(open(os.path.join(d, "linkLibs.rsp")).read())):
        if l.startswith("-"):
            k["libs"].append(l)
            continue
        to = "lib/%02d_%s" % (i, os.path.basename(l))
        shutil.copyfile(os.path.join(build, l), os.path.join(kit, to))
        k["libs"].append(to)
    # The headers of each include directory (one inside another already
    # copied is a path in that copy); the app's own directory is the
    # release's
    inc = shlex.split(open(os.path.join(d, "includes_CXX.rsp")).read())
    dirs, flags = {}, []
    i = 0
    while i < len(inc):
        f = inc[i]
        if f == "-isystem":
            flag, p = "-isystem", inc[i + 1]
            i += 2
        elif f.startswith("-I"):
            flag, p = "-I", f[2:]
            i += 1
        else:
            die("an include flag not understood: " + f)
        p = os.path.normpath(p)
        if p.endswith("/src/server/web/_aitta"):
            flags += [flag, "@APP@"]
            continue
        flags += [flag, p]
        dirs[p] = None
    for n, p in enumerate(sorted(dirs)):
        outer = [q for q in sorted(dirs) if p.startswith(q + "/") and dirs[q]]
        if outer:
            dirs[p] = dirs[outer[0]] + p[len(outer[0]):]
            continue
        dirs[p] = "inc/%02d" % n
        for root, _, files in os.walk(p):
            for f in files:
                if f.endswith(HEADERS):
                    to = os.path.join(kit, dirs[p], os.path.relpath(root, p), f)
                    os.makedirs(os.path.dirname(to), exist_ok=True)
                    shutil.copyfile(os.path.join(root, f), to)
    k["includes"] = [dirs.get(f, f) for f in flags]
    fm = open(os.path.join(d, "flags.make")).read()
    get = lambda n: shlex.split(re.search(r"^%s = (.*)$" % n, fm, re.M).group(1))
    k["cxxflags"] = get("CXX_DEFINES") + get("CXX_FLAGS")
    k["cflags"] = get("C_DEFINES") + get("C_FLAGS")
    # The link: its flags as they are, the packed directories and the
    # scripts copied, in the same order; its output's name the same, which
    # the .js names (PACKAGE_NAME)
    link = shlex.split(open(os.path.join(d, "link.txt")).read())[1:]
    k["link"] = []
    i = 0
    while i < len(link):
        f = link[i]
        if f.startswith("@"):
            i += 1
        elif f == "-o":
            if link[i + 1] != "bin/buildat_server.js":
                die("the link's output is " + link[i + 1])
            i += 2
        elif f in ("--pre-js", "--post-js"):
            to = "pre/" + os.path.basename(link[i + 1])
            shutil.copyfile(link[i + 1], os.path.join(kit, to))
            k["link"] += [f, to]
            i += 2
        elif f == "--preload-file":
            src, dst = link[i + 1].rsplit("@", 1)
            to = "share/%02d" % len([x for x in k["link"] if x == "--preload-file"])
            shutil.copytree(src, os.path.join(kit, to))
            k["link"] += [f, to + "@" + dst]
            i += 2
        else:
            k["link"].append(f)
            i += 1
    for f in ("buildat_server.js", "buildat_server.wasm"):
        shutil.copyfile(os.path.join(build, "bin", f), os.path.join(kit, "ref", f))
    emsdk = os.environ.get("EMSDK", "")
    if not os.path.isfile(os.path.join(emsdk, ".emscripten")):
        die("no emsdk in EMSDK (" + emsdk + ")")
    os.symlink(os.path.realpath(emsdk), os.path.join(kit, "emsdk"))
    json.dump(k, open(os.path.join(kit, "kit.json"), "w"), indent=1)
    shutil.copyfile(os.path.abspath(__file__), os.path.join(kit, "build.py"))
    print("kit: " + kit)

def run(args, cwd):
    p = subprocess.run(args, cwd=cwd, stdin=subprocess.DEVNULL)
    if p.returncode != 0:
        die("%s failed (%d)" % (os.path.basename(args[0]), p.returncode))

def build(kit, job):
    kit, job = os.path.abspath(kit), os.path.abspath(job)
    k = json.load(open(os.path.join(kit, "kit.json")))
    emsdk = os.path.realpath(os.path.join(kit, "emsdk"))
    em = os.path.join(emsdk, "upstream/emscripten")
    # The emsdk's cache read where it is, but its locks and the link's
    # symbol lists written: a cache of the job's own beside it
    cache = os.path.join(job, "emcache")
    os.makedirs(cache, exist_ok=True)
    real = os.path.join(em, "cache")
    for n in os.listdir(real):
        if n == "symbol_lists":
            shutil.copytree(os.path.join(real, n), os.path.join(cache, n))
        elif os.path.isdir(os.path.join(real, n)):
            os.symlink(os.path.join(real, n), os.path.join(cache, n))
        elif not n.endswith(".lock"):
            shutil.copyfile(os.path.join(real, n), os.path.join(cache, n))
    # node reads /etc/ssl/openssl.cnf, which the box does not let it
    os.environ.update({"EM_CONFIG": os.path.join(emsdk, ".emscripten"),
        "EM_CACHE": cache, "EMSDK": emsdk, "OPENSSL_CONF": "/dev/null"})
    src = os.path.join(job, "src")
    obj = os.path.join(job, "obj")
    os.makedirs(obj, exist_ok=True)
    os.makedirs(os.path.join(job, "bin"), exist_ok=True)
    kp = lambda p: os.path.join(kit, p)
    inc = [src if f == "@APP@" else kp(f) if f.startswith("inc/") else f
            for f in k["includes"]]
    # The release's C++ modules, as util/web_server.cmake takes a module's
    # source: <name>_web.cpp where there is one, else <name>.cpp, and the C
    # and C++ of its wasm/ (with -ffp-contract=off, as its clients build it)
    mods, objs = [], []
    for name in sorted(os.listdir(src)):
        d = os.path.join(src, name)
        if not os.path.isfile(os.path.join(d, "meta.json")) or not os.path.isdir(d):
            continue
        if not PLAIN.match(name):
            die("a module's name is not [A-Za-z0-9_]: " + name[:64])
        m = json.load(open(os.path.join(d, "meta.json")))
        if m.get("disable_cpp") or (m.get("server_wasm") or {}).get("source"):
            continue
        if name in k["builtins"]:
            die("the module %s has a builtin's name" % name)
        main = os.path.join(d, name + "_web.cpp")
        if not os.path.isfile(main):
            main = os.path.join(d, name + ".cpp")
        if not os.path.isfile(main):
            die("the module %s has no %s.cpp" % (name, name))
        files = [main]
        extra = []
        if os.path.isdir(os.path.join(d, "wasm")):
            extra = ["-ffp-contract=off"]
            for root, _, fs in sorted(os.walk(os.path.join(d, "wasm"))):
                files += [os.path.join(root, f) for f in sorted(fs)
                        if f.endswith((".c", ".cc", ".cpp"))]
        for f in files:
            o = os.path.join(obj, "%03d.o" % len(objs))
            c = f.endswith(".c")
            run([os.path.join(em, "emcc" if c else "em++")] +
                    (k["cflags"] if c else k["cxxflags"]) + inc +
                    ["-DBUILDAT_WEB_MODULE"] + extra + ["-c", f, "-o", o], job)
            objs.append(o)
        mods.append(name)
    if not mods:
        die("no C++ module")
    names = k["builtins"] + mods
    t = os.path.join(obj, "table.cpp")
    open(t, "w").write("#include \"server/static_modules.h\"\nextern \"C\" {\n" +
        "".join("\tvoid* createModule_%s(interface::Server*);\n" % n for n in names) +
        "}\nnamespace server {\nconst StaticModule g_static_modules[] = {\n" +
        "".join("\t{\"%s\", createModule_%s},\n" % (n, n) for n in names) +
        "\t{nullptr, nullptr},\n};\n}\n")
    run([os.path.join(em, "em++")] + k["cxxflags"] + inc +
            ["-c", t, "-o", os.path.join(obj, "table.o")], job)
    objects = [os.path.join(obj, "table.o") if o == "@TABLE@" else kp(o)
            for o in k["objects"]] + objs
    link = []
    for f in k["link"]:
        if f.startswith(("pre/", "share/")):
            f = kp(f)
        link.append(f)
    libs = [kp(l) if l.startswith("lib/") else l for l in k["libs"]]
    run([os.path.join(em, "em++")] + link + objects +
            ["-o", "bin/buildat_server.js"] + libs, job)
    print("cpp build: %s linked" % ", ".join(mods), flush=True)

if len(sys.argv) == 4 and sys.argv[1] == "kit":
    make_kit(sys.argv[2], sys.argv[3])
elif len(sys.argv) == 4 and sys.argv[1] == "build":
    build(sys.argv[2], sys.argv[3])
else:
    sys.exit("usage: aitta_cpp_build.py kit <build dir> <kit dir> | build <kit dir> <job dir>")
