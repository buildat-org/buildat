#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4, protocol fuzzing: a raw client sending every
# packet name a server module listens for, with payloads that are random or
# shaped like cereal's portable binary and then broken (lengths in the
# gigabytes, cut short, wrong types), over a few connections at once,
# reconnecting when the server drops one. It watches nothing itself;
# proto_fuzz.sh watches the server.
#
# With a words file (floorplanner's schema: a line per type, its name and
# then its fields), each connection logs in as a local user and opens a plan first,
# and a third of what it sends is fp:batch or fp:import shaped like the
# real thing: valid cereal around entities of those types with those
# fields and values at the edges, so the checks past the decoding are
# what is driven.
#
# CORPUS=<file> (record_proxy.py's) is every app's shapes the same way: a
# connection first replays the session's first packet of each name, in
# order -- the login and the join -- and half of what it sends is a
# recorded payload mutated (bits flipped, edge values written over it,
# cut, grown, spliced).
#
#   proto_fuzz.py <port> <seconds> <names file> [seed] [words file]
import os, random, socket, struct, sys, time

port, seconds = int(sys.argv[1]), float(sys.argv[2])
names = [l.strip() for l in open(sys.argv[3]) if l.strip()]
rnd = random.Random(int(sys.argv[4]) if len(sys.argv) > 4 else None)
words = None
if len(sys.argv) > 5:
    words = {l.split()[0]: l.split()[1:] for l in open(sys.argv[5])
            if l.split()}
    all_fields = sorted(set(f for v in words.values() for f in v))

corpus = []
if os.environ.get("CORPUS"):
    d = open(os.environ["CORPUS"], "rb").read()
    i = 0
    while i < len(d):
        nl = struct.unpack("<H", d[i:i + 2])[0]
        name = d[i + 2:i + 2 + nl].decode()
        i += 2 + nl
        size = struct.unpack("<I", d[i:i + 4])[0]
        corpus.append((name, d[i + 4:i + 4 + size]))
        i += 4 + size
    firsts, seen = [], set()
    for name, data in corpus:
        if name not in seen:
            seen.add(name)
            firsts.append((name, data))

# [u16 type][u8 flags][u32 size]; the first packet each way is core:hello
def packet(t, data):
    return struct.pack("<HBI", t, 0, len(data)) + data

def hello():
    v = b"0.7.0"
    body = struct.pack("<IIQ", 1, 1, len(v)) + v + \
            struct.pack("<IQ", 2, 0)
    return packet(2, b"\1\1\0" + bytes([len(body)]) + body)  # its length a one-byte varint

def define(t, name):
    n = name.encode()
    return packet(0, struct.pack("<HI", t, len(n)) + n)

def u64(n):
    return struct.pack("<Q", n)

def cereal_value(depth=0):
    k = rnd.randrange(8)
    if k == 0:   # a string
        s = os.urandom(rnd.choice([0, 1, 5, 40, 300]))
        return u64(len(s)) + s
    if k == 1:   # a string that says it is huge
        return u64(rnd.choice([2**31, 2**32 + 5, 2**63, 2**64 - 1])) + b"ab"
    if k == 2:   # a vector of values
        n = rnd.choice([0, 1, 3, 10])
        out = u64(n)
        for _ in range(n):
            out += cereal_value(depth + 1) if depth < 3 else b"\x00"
        return out
    if k == 3:   # a vector that says it is huge
        return u64(rnd.choice([10**6, 2**40, 2**64 - 1]))
    if k == 4:
        return struct.pack("<i", rnd.randrange(-2**31, 2**31))
    if k == 5:
        return struct.pack("<d", rnd.choice([0.0, -1.0, 1e308, float("nan"),
                float("inf")]))
    if k == 6:
        return bytes([rnd.randrange(256)])
    return os.urandom(rnd.randrange(0, 16))

def payload():
    k = rnd.randrange(5)
    if k == 0:
        return b""
    if k == 1:
        return os.urandom(rnd.randrange(1, 200))
    # A portable binary archive: the endianness byte, then values
    out = bytes([1]) + b"".join(cereal_value() for _ in range(rnd.randrange(1, 6)))
    if k == 3 and len(out) > 2:   # cut short
        out = out[:rnd.randrange(1, len(out))]
    if k == 4:                    # a byte flipped
        b = bytearray(out)
        b[rnd.randrange(len(b))] ^= 1 << rnd.randrange(8)
        out = bytes(b)
    return out

def s_(b):
    if isinstance(b, str):
        b = b.encode()
    return u64(len(b)) + b

def i32(n):
    return struct.pack("<i", n)

def edge_int():
    return rnd.choice([0, 1, -1, 2, 7, 100, 1000, 2**31 - 1, -2**31,
            rnd.randrange(-2**31, 2**31), rnd.randrange(-50, 50)])

def entity():
    t = rnd.choice(list(words))
    fields = words[t] if words[t] and rnd.random() < 0.9 else all_fields
    out = i32(rnd.choice([rnd.randrange(-5, 40), edge_int()]))
    out += s_(t if rnd.random() < 0.95 else "x")
    n = rnd.randrange(0, 8)
    out += u64(n) + b"".join(s_(rnd.choice(fields)) + i32(edge_int())
            for _ in range(n))
    n = rnd.randrange(0, 3)
    out += u64(n) + b"".join(s_(rnd.choice(fields)) +
            s_(rnd.choice(["", "a", "x" * 300, "\u00e4", "../../x"]))
            for _ in range(n))
    n = rnd.randrange(0, 3)
    out += u64(n)
    for _ in range(n):
        k = rnd.randrange(0, 6)
        out += s_(rnd.choice(fields)) + u64(k) + b"".join(
                i32(edge_int()) for _ in range(k))
    return out

def ops(n):
    return u64(n) + b"".join(bytes([rnd.randrange(5)]) + entity()
            for _ in range(n))

def plan_file():
    out = bytes([1]) + s_("buildat-floorplan") + i32(rnd.choice([1, 1, 2])) + \
            i32(rnd.choice([3, 3, 3, 2, 99]))
    n = rnd.randrange(0, 12)
    out += u64(n) + b"".join(entity() for _ in range(n))
    n = rnd.randrange(0, 3)
    out += u64(n)
    for _ in range(n):
        k = rnd.randrange(0, 5)
        out += i32(edge_int()) + u64(k) + b"".join(
                i32(edge_int()) + i32(edge_int()) for _ in range(k))
    n = rnd.randrange(0, 3)
    out += u64(n)
    for _ in range(n):
        out += s_(rnd.choice(["a.png", "b.jpg", "../c.png", ".png", "d.PNG"]))
        out += s_(rnd.choice([b"\x89PNG\r\n\x1a\n" + os.urandom(20),
                b"\xff\xd8\xff" + os.urandom(10), b""]))
    return out

def mutate(data):
    b = bytearray(data)
    for _ in range(rnd.choice([1, 1, 2, 4])):
        k = rnd.randrange(6)
        at = rnd.randrange(len(b) + 1)
        if k == 0 and b:
            b[min(at, len(b) - 1)] ^= 1 << rnd.randrange(8)
        elif k == 1:
            v = rnd.choice([struct.pack("<i", edge_int()), u64(rnd.choice(
                    [0, 2**31, 2**32 + 5, 2**63, 2**64 - 1])),
                    struct.pack("<d", rnd.choice([float("nan"), 1e308,
                    -1e308, float("inf")])), bytes([rnd.randrange(256)])])
            b[at:at + len(v)] = v
        elif k == 2:
            del b[at:]
        elif k == 3:
            b[at:at] = os.urandom(rnd.choice([1, 8, 100]))
        elif k == 4:
            other = rnd.choice(corpus)[1]
            b[at:] = other[rnd.randrange(len(other) + 1):]
    return bytes(b)

def shaped():
    if rnd.random() < 0.5:
        return "fp:batch", bytes([1]) + i32(edge_int()) + \
                ops(rnd.choice([0, 1, 3, 10]))
    return "fp:import", bytes([1]) + s_("i%d" % rnd.randrange(1000)) + \
            s_(plan_file())

class Conn:
    def __init__(self):
        self.s = socket.create_connection(("127.0.0.1", port), timeout=5)
        self.s.setblocking(False)
        self.types = {}
        self.next = 100
        self.s.sendall(hello())
        if words:
            # A local peer's login takes any new name and no password
            self.send("accounts:login", bytes([1]) +
                    s_("fz%d" % rnd.randrange(10**6)) + s_("") + s_("") +
                    s_("") + b"\0" + s_("") + s_(""))
            self.send("fp:open", bytes([1]) + s_("p%d" % rnd.randrange(5)) +
                    bytes([rnd.randrange(2)]))
            self.send("fp:set_editing", bytes([1, 1]))
        for name, data in firsts if corpus else []:
            self.send(name, data)

    def send(self, name, data):
        out = b""
        if name not in self.types:
            self.types[name] = self.next
            out += define(self.next, name)
            self.next += 1
        out += packet(self.types[name], data)
        self.s.sendall(out)

    def drain(self):
        try:
            while self.s.recv(65536):
                pass
        except BlockingIOError:
            pass

conns, sent, dropped = [], 0, 0
end = time.time() + seconds
while time.time() < end:
    while len(conns) < 3:
        try:
            conns.append(Conn())
        except OSError:
            time.sleep(0.5)
            break
    for c in list(conns):
        try:
            c.drain()
            for _ in range(rnd.randrange(1, 20)):
                if words and rnd.random() < 0.33:
                    c.send(*shaped())
                elif corpus and rnd.random() < 0.5:
                    name, data = rnd.choice(corpus)
                    c.send(name, mutate(data))
                else:
                    c.send(rnd.choice(names), payload())
                sent += 1
        except (OSError, BrokenPipeError, ConnectionResetError):
            conns.remove(c)
            dropped += 1
    time.sleep(0.01)
print("sent %d packets, %d connections dropped by the server" % (sent, dropped))
