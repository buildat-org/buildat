#!/usr/bin/env python3
# Checks a running server's one port for HTTP, WebSocket and the native
# protocol ([WEB_CLIENT]). Usage: util/test_web_transport.py host:port
# The web directory needs index.html for the 200 check.
import asyncio, socket, struct, sys, urllib.error, urllib.request
import websockets

host, port = sys.argv[1].rsplit(":", 1)
base = f"http://{host}:{port}"

def status(path):
    try:
        return urllib.request.urlopen(base + path, timeout=5).status
    except urllib.error.HTTPError as e:
        return e.code

# A packet header is type (u16 le), flags (u8) and size (u32 le); the first
# packet each way is core:hello, type 2, a record (interface/protocol.h)
def first_type(data):
    assert len(data) >= 7, data
    return data[0] | data[1] << 8

def packet(t, data):
    return struct.pack("<HBI", t, 0, len(data)) + data

def hello(pmin=1, pmax=1):
    v = b"0.7.0"
    body = struct.pack("<IIQ", pmin, pmax, len(v)) + v + \
            struct.pack("<IQ", 2, 0)
    return packet(2, b"\1\1\0" + bytes([len(body)]) + body)  # its length a one-byte varint

assert status("/index.html") == 200, "index.html"
assert status("/?x=1") == 200, "/ with a query"
assert status("/nope") == 404, "missing path"
print("http ok")

# The same file again with its ETag is a 304; deflate is what was asked for
import zlib
r = urllib.request.urlopen(urllib.request.Request(base + "/index.html",
        headers={"Accept-Encoding": "deflate"}), timeout=5)
assert r.headers["Content-Encoding"] == "deflate", r.headers
assert b"<html" in zlib.decompress(r.read()), "deflated index.html"
etag = r.headers["ETag"]
assert etag, "no ETag"
try:
    code = urllib.request.urlopen(urllib.request.Request(base + "/index.html",
            headers={"If-None-Match": etag}), timeout=5).status
except urllib.error.HTTPError as e:
    code = e.code
assert code == 304, code
print("etag and deflate ok")

async def ws():
    async with websockets.connect(f"ws://{host}:{port}/",
            subprotocols=["binary"], max_size=None) as c:
        assert c.subprotocol == "binary", c.subprotocol
        await c.send(hello())
        data = await asyncio.wait_for(c.recv(), 5)
        assert isinstance(data, bytes) and first_type(data) == 2, data[:16]
        # A core:define_packet_type over 64 KiB (a 64 bit frame length),
        # sent as a message of three frames; harmless to the game
        name = b"test:" + b"x" * 70000
        body = bytes([200, 0]) + len(name).to_bytes(4, "little") + name
        pkt = packet(0, body)
        await c.send([pkt[:3], pkt[3:10], pkt[10:]])
        await asyncio.wait_for(await c.ping(), 5)
        print("websocket ok:", len(data), "bytes, pong")
asyncio.run(ws())

# An oversized request is dropped
s = socket.create_connection((host, int(port)), timeout=5)
s.sendall(b"GET / HTTP/1.1\r\nX: " + b"x" * 9000)
assert s.recv(100) == b"", "oversized request not dropped"
s.close()
print("oversized request dropped")

# A browser's preconnect is quiet until it has a request: a connection is
# sorted by its first bytes, however late ([WEB_SNIFF_PRECONNECT])
import time
s = socket.create_connection((host, int(port)), timeout=5)
time.sleep(1)
s.sendall(b"GET /index.html HTTP/1.1\r\nHost: x\r\n\r\n")
data = s.recv(100)
assert data.startswith(b"HTTP/1.1 200"), data
s.close()
print("quiet then GET ok")

# A native client speaks first, with its hello, and is answered with one
s = socket.create_connection((host, int(port)), timeout=5)
s.sendall(hello())
data = s.recv(65536)
assert first_type(data) == 2, data[:16]
s.close()
print("native ok:", len(data), "bytes")

# A refused peer is kept open for 10 s after its goodbye (network.cpp,
# linger_until_us): read until the goodbye has come, not to the end
def until(s, text):
    data = b""
    while text not in data:
        d = s.recv(65536)
        if not d:
            break
        data += d
    return data

# A client of another protocol is told why, in a network:goodbye
s = socket.create_connection((host, int(port)), timeout=5)
s.sendall(hello(9, 9))
data = until(s, b"newer than this one")
assert b"network:goodbye" in data and b"newer than this one" in data, data
s.close()
print("another protocol refused")

# A 0.6 client, whose first packet is a definition in the framing before
# the flags byte, is told why in that framing
s = socket.create_connection((host, int(port)), timeout=5)
name = b"core:request_files"
body = bytes([100, 0]) + len(name).to_bytes(4, "little") + name
s.sendall(bytes([0, 0]) + len(body).to_bytes(4, "little") + body)
data = until(s, b"update Buildat")
assert data[:2] == bytes([0, 0]) and b"network:goodbye" in data, data[:40]
n = 6 + int.from_bytes(data[2:6], "little")
assert data[n:n + 2] == bytes([100, 0]) and b"update Buildat" in data[n:], data
s.close()
print("a 0.6 client refused in its own framing")
