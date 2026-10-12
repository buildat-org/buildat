#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [SECURITY_RUN_1] phase 4: the shapes of an app's packets, taken from a
# real client rather than written out per packet. A proxy between one
# client and the server that passes everything on and writes down what
# the client sent, a record per packet: the name (u16 length, bytes) and
# the payload (u32 length, bytes). proto_fuzz.py takes the file as a
# corpus: it replays a session's first packet of each name to get where
# the client got, then sends recorded payloads mutated.
#
#   record_proxy.py <listen port> <server port> <out file>
import socket, struct, sys, threading

listen_port, server_port, out_path = int(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
srv = socket.socket()
srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", listen_port))
srv.listen(1)
cli, _ = srv.accept()
up = socket.create_connection(("127.0.0.1", server_port))

def down():
    try:
        while True:
            d = up.recv(65536)
            if not d:
                break
            cli.sendall(d)
    except OSError:
        pass
    cli.close()
threading.Thread(target=down, daemon=True).start()

names, buf, n = {}, b"", 0
with open(out_path, "wb") as out:
    try:
        while True:
            d = cli.recv(65536)
            if not d:
                break
            up.sendall(d)
            buf += d
            while len(buf) >= 7:
                t, flags, size = struct.unpack("<HBI", buf[:7])
                if len(buf) < 7 + size:
                    break
                data, buf = buf[7:7 + size], buf[7 + size:]
                if t == 0:
                    # A definition: the type number and its name
                    i, nl = struct.unpack("<HI", data[:6])
                    names[i] = data[6:6 + nl]
                elif t in names:
                    out.write(struct.pack("<H", len(names[t])) + names[t] +
                            struct.pack("<I", len(data)) + data)
                    n += 1
    except OSError:
        pass
up.close()
print("recorded %d packets of %d names" % (n, len(names)))
