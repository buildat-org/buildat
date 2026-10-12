#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [STARPORT] load: how many of each API call a Starport takes, and what
# its stores' sizes do to that. Starts a Starport of its own in a
# temporary directory on ports of its own, and stops it at the end.
#
#   apps/starport/load_test.py ids 100,1000,20000
#       registrations, ID logins and tokens at each count of IDs
#   apps/starport/load_test.py listings 100,1000,5000
#       new listings, announces again and /api/v1/list at each count
#   apps/starport/load_test.py mixed 1000
#       /api/v1/list's latency while ID logins run, with 1000 IDs
#
# Each client address is a fake one in X-Forwarded-For (loopback is a
# trusted proxy by default), so the per-address limits don't cap the
# rates; a name's 10 logins an hour are kept to. Every row is the server
# at one core: it answers on one thread. Latencies are with WORKERS
# requests waiting at once, so a p50 is the queue's, not one request's.
# Results of 2026-10-02: doc/plan/starport_plan.md, 11.
import http.client, json, os, random, shutil, subprocess, sys, tempfile
import threading, time, hmac, hashlib
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
SP = int(os.environ.get("SP_PORT", "29661"))
RESP_PORT = SP + 1
WORKERS = int(os.environ.get("WORKERS", "16"))

addr_n = [0]
addr_lock = threading.Lock()
def fake_addr():
    with addr_lock:
        addr_n[0] += 1
        n = addr_n[0]
    return "10.%d.%d.%d" % ((n >> 16) & 255, (n >> 8) & 255, n & 255)

def call(path, body=None):
    c = http.client.HTTPConnection("127.0.0.1", SP, timeout=120)
    c.request("POST" if body is not None else "GET", path,
              json.dumps(body) if body is not None else None,
              {"X-Forwarded-For": fake_addr()})
    r = json.loads(c.getresponse().read())
    c.close()
    return r

def ok_or_error(r):
    return True if r.get("ok") else r.get("error")

# -- The Starport

server = None
def start():
    global server
    tmp = tempfile.mkdtemp(prefix="buildat_starport_load.")
    log = open(tmp + "/sp.log", "w")
    server = subprocess.Popen([ROOT + "/Build/bin/buildat_server", "-m",
                               "apps/starport", "-D", tmp + "/sp", "-P",
                               str(SP), "-l", "2"], cwd=ROOT, stdout=log,
                              stderr=subprocess.STDOUT)
    server.tmp = tmp
    for _ in range(120):
        if "setup code" in open(tmp + "/sp.log").read():
            return
        if server.poll() is not None:
            break
        time.sleep(1)
    sys.exit("the Starport did not start: " + tmp + "/sp.log")

def stop():
    server.terminate()
    server.wait()
    if os.environ.get("KEEP_TMP"):
        print("kept", server.tmp)
    else:
        shutil.rmtree(server.tmp)

def cpu_s():
    f = open("/proc/%d/stat" % server.pid).read().rsplit(")", 1)[1].split()
    return (int(f[11]) + int(f[12])) / os.sysconf("SC_CLK_TCK")

def rss_mb():
    for line in open("/proc/%d/status" % server.pid):
        if line.startswith("VmRSS"):
            return int(line.split()[1]) / 1024

def run(label, jobs, fn):
    """fn(job) is True or an error; one row of rate, CPU and latency"""
    lat, errs, ok = [], {}, [0]
    lock = threading.Lock()
    def one(job):
        t = time.time()
        try:
            e = fn(job)
        except Exception as x:
            e = "exception " + type(x).__name__
        with lock:
            lat.append(time.time() - t)
            if e is True:
                ok[0] += 1
            else:
                errs[e] = errs.get(e, 0) + 1
    c0, t0 = cpu_s(), time.time()
    with ThreadPoolExecutor(WORKERS) as ex:
        list(ex.map(one, jobs))
    dt, dc = time.time() - t0, cpu_s() - c0
    lat.sort()
    p = lambda q: lat[min(len(lat) - 1, int(q * len(lat)))] * 1000
    print("%-26s n=%6d ok=%6d %8.1f/s %8.0f/min  cpu %3.0f%%  p50 %6.1fms "
          "p99 %7.1fms  rss %.0fMB %s" % (
              label, len(jobs), ok[0], ok[0] / dt, ok[0] / dt * 60,
              100 * dc / dt, p(.5), p(.99), rss_mb(),
              ("errors " + json.dumps(errs)) if errs else ""), flush=True)
    if server.poll() is not None:
        sys.exit("the Starport stopped: " + server.tmp + "/sp.log")

# -- The challenge's answers, so that the listings are verified

secrets = {}
class Challenge(BaseHTTPRequestHandler):
    def do_GET(self):
        q = parse_qs(urlparse(self.path).query)
        s = secrets.get(q.get("listing", [""])[0], "")
        out = json.dumps({"response": hmac.new(bytes.fromhex(s),
            q.get("nonce", [""])[0].encode(), hashlib.sha256).hexdigest()})
        self.send_response(200)
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out.encode())
    def log_message(self, *a):
        pass

# -- Listings

DESC = {"violence": "none", "chat": "moderated", "ugc": "none",
        "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
        "gambling": "no", "personal_data": "no"}
listing_ids = []
def announce_body(i, lid=None):
    b = {"name": "Load %d" % i, "kind": "app", "audience": "everyone",
         "access": "open", "descriptors": DESC, "port": RESP_PORT,
         "address": "127.0.0.1", "app": "floorplanner", "players": i % 20,
         "players_max": 20}
    if lid:
        b["id"], b["secret"] = lid, secrets[lid]
    return b

def new_listing(i):
    r = call("/api/v1/announce", announce_body(i))
    if r.get("ok"):
        secrets[r["id"]] = r["secret"]
        listing_ids.append(r["id"])
    return ok_or_error(r)

def reannounce(lid):
    return ok_or_error(call("/api/v1/announce", announce_body(0, lid)))

def grow_listings(count):
    if count > len(listing_ids):
        run("new listings to %d" % count,
            list(range(len(listing_ids), count)), new_listing)

# -- IDs

names, sessions, logins = [], {}, {}
def register(name):
    r = call("/api/v1/id/register", {"name": name, "password": "pass-" + name,
                                  "adult": True})
    if r.get("ok"):
        sessions[name] = r["result"]["session"]
        names.append(name)
    return ok_or_error(r)

def login(name):
    r = call("/api/v1/id/login", {"name": name, "password": "pass-" + name})
    if r.get("ok"):
        sessions[name] = r["result"]["session"]
    return ok_or_error(r)

def token(name):
    return ok_or_error(call("/api/v1/id/token", {
        "session": sessions[name], "listing": random.choice(listing_ids),
        "name": name}))

def grow_ids(count):
    if count > len(names):
        run("register to %d" % count,
            ["u%d" % k for k in range(len(names), count)], register)

def login_names(n):
    # 9 at most a name: a name's limit is 10 an hour, its registration
    # being the first
    out = []
    for x in random.sample(names, len(names)):
        if len(out) >= n:
            break
        if logins.get(x, 1) < 9:
            logins[x] = logins.get(x, 1) + 1
            out.append(x)
    return out

def list_latency(label):
    ms = []
    for _ in range(20):
        t = time.time()
        call("/api/v1/list")
        ms.append((time.time() - t) * 1000)
    ms.sort()
    print("%-26s /api/v1/list p50 %.1f ms, max %.1f ms" % (label, ms[10],
                                                         ms[-1]), flush=True)

# -- The modes

def ids(levels):
    grow_listings(50)
    for level in levels:
        grow_ids(level)
        run("login @%d IDs" % len(names), login_names(600), login)
        run("token @%d IDs" % len(names),
            random.sample(list(sessions), min(2000, len(sessions))), token)

def listings(levels):
    for level in levels:
        grow_listings(level)
        # Each listing once, after its 1 announce in 20 s has passed
        time.sleep(21)
        run("announce @%d listings" % len(listing_ids), list(listing_ids),
            reannounce)
        run("list @%d listings" % len(listing_ids), list(range(50)),
            lambda _: ok_or_error(call("/api/v1/list")))

def mixed(levels):
    grow_listings(50)
    grow_ids(levels[0])
    list_latency("idle")
    for streams in (1, 4, 16):
        stop_streams = [False]
        def stream():
            while not stop_streams[0]:
                for x in login_names(1):
                    login(x)
        ts = [threading.Thread(target=stream) for _ in range(streams)]
        for t in ts:
            t.start()
        time.sleep(1)
        list_latency("during %d login streams" % streams)
        stop_streams[0] = True
        for t in ts:
            t.join()

modes = {"ids": ids, "listings": listings, "mixed": mixed}
if len(sys.argv) != 3 or sys.argv[1] not in modes:
    sys.exit("usage: %s ids|listings|mixed <count>[,<count>...]" %
             sys.argv[0])
threading.Thread(target=ThreadingHTTPServer(("127.0.0.1", RESP_PORT),
                                            Challenge).serve_forever,
                 daemon=True).start()
start()
try:
    modes[sys.argv[1]]([int(x) for x in sys.argv[2].split(",")])
finally:
    stop()
