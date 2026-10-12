#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4, the client's side: a hostile server. It takes
# a client's connection and sends it every packet name the client's own
# code handles (src/client/state.cpp), with payloads that are random,
# shaped like cereal's portable binary, or shaped like Urho3D's scene
# replication -- a node or component id the scene may hold, then VLE
# counts, string hashes and variants cut anywhere -- for <seconds> per
# connection, then closes it. It watches nothing; client_fuzz.sh watches
# the client.
#
# With a Lua file as a fourth argument it sends only that, as
# core:run_script with SEED set, a run every half a second.
#
#   client_fuzz.py <port> <seconds per connection> <seed> [script.lua]
import os, random, socket, struct, sys, time

port, seconds = int(sys.argv[1]), float(sys.argv[2])
rnd = random.Random(int(sys.argv[3]))
script = open(sys.argv[4], "rb").read() if len(sys.argv) > 4 else None

NAMES = ["core:announce_files", "core:file_contents", "core:run_script",
        "core:tell_after_all_files_transferred", "core:unordered",
        "network:keepalive", "replicate:component_delta_update",
        "replicate:create_component", "replicate:create_node",
        "replicate:latest_component_data", "replicate:latest_node_data",
        "replicate:node_delta_update", "replicate:remove_component",
        "replicate:remove_node"]

# [u16 type][u8 flags][u32 size]; the first packet each way is core:hello
def packet(t, data):
    return struct.pack("<HBI", t, 0, len(data)) + data

def hello():
    v = b"0.7.0"
    body = b"\1" + struct.pack("<IIQ", 1, 1, len(v)) + v + \
            struct.pack("<IQ", 2, 0)
    return packet(2, b"\1\1\0" + struct.pack("<Q", len(body)) + body)

def u64(n):
    return struct.pack("<Q", n)

def vle(n):
    out = b""
    while True:
        b = n & 0x7f
        n >>= 7
        if n:
            out += bytes([b | 0x80])
        else:
            return out + bytes([b])

def netid():
    # Urho3D's ReadNetID: three bytes; the scene is 1
    return struct.pack("<I", rnd.choice([1, 2, 3, 4, 5, 0, 0xffffff,
            rnd.randrange(1 << 24)]))[:3]

def variant():
    t = rnd.randrange(0, 30)
    return bytes([t]) + os.urandom(rnd.choice([0, 1, 4, 8, 12, 16, 64]))

def replicated():
    out = netid()
    for _ in range(rnd.randrange(0, 4)):
        k = rnd.randrange(5)
        if k == 0:
            out += vle(rnd.choice([0, 1, 3, 1000, 2**28]))
        elif k == 1:
            out += os.urandom(4)            # a string hash, a type
        elif k == 2:
            out += variant()
        elif k == 3:
            out += netid()
        else:
            out += os.urandom(rnd.randrange(1, 40))
    return out

def cereal():
    out = bytes([1])
    for _ in range(rnd.randrange(1, 5)):
        k = rnd.randrange(4)
        if k == 0:
            s = rnd.choice([b"", b"a", b"../x", b"\0", os.urandom(30)])
            out += u64(len(s)) + s
        elif k == 1:
            out += u64(rnd.choice([2**31, 2**63, 10**6]))
        elif k == 2:
            out += u64(rnd.randrange(4)) + os.urandom(rnd.randrange(30))
        else:
            out += os.urandom(rnd.randrange(1, 16))
    return out

def payload(name):
    if name.startswith("replicate:") and rnd.random() < 0.8:
        return replicated()
    k = rnd.randrange(4)
    if k == 0:
        return b""
    if k == 1:
        return os.urandom(rnd.randrange(1, 200))
    if name == "core:run_script" and rnd.random() < 0.5:
        return cereal()[:1] + u64(5) + b"x.lua" + u64(20) + \
                rnd.choice([b"error('x')     ", b"while true do end   ",
                b"return (nil)()      "])
    return cereal()

srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", port))
srv.listen(4)
sent = 0
while True:
    c, _ = srv.accept()
    c.setblocking(False)
    types, nxt = {}, 100
    end = time.time() + seconds
    c.sendall(hello())
    try:
        while time.time() < end:
            try:
                while c.recv(65536):
                    pass
            except BlockingIOError:
                pass
            out = b""
            if script:
                if "core:run_script" not in types:
                    types["core:run_script"] = nxt
                    n = b"core:run_script"
                    out += packet(0, struct.pack("<HI", nxt, len(n)) + n)
                    nxt += 1
                seed = b"SEED = %d\n" % rnd.randrange(1, 2**31)
                out += packet(types["core:run_script"], seed + script)
                sent += 1
                c.setblocking(True)
                c.sendall(out)
                c.setblocking(False)
                time.sleep(0.5)
                continue
            for _ in range(rnd.randrange(1, 10)):
                name = rnd.choice(NAMES)
                if name not in types:
                    types[name] = nxt
                    n = name.encode()
                    out += packet(0, struct.pack("<HI", nxt, len(n)) + n)
                    nxt += 1
                out += packet(types[name], payload(name))
                sent += 1
            c.setblocking(True)
            c.sendall(out)
            c.setblocking(False)
            time.sleep(0.005)
    except OSError:
        pass
    c.close()
    print("sent %d packets" % sent, flush=True)
