#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: full
# ci
# cost: ~40 s (2026-10-14)
# covers: builtin/moderation/moderation.cpp
# [SEC_RUN5_LEFTOVERS] (run 5's F2, drive D5): a report costs the same
# however many there are, and held ones are swept. A Starport on
# --sim-clock, one listing:
#   1. one key's five reports of one text: three open, two held (the
#      text's count a day, not a scan);
#   2. 2000 more of that text from 2000 /24s: the last 500 take less than
#      twice the first 500 (run 5: 0.016 s to 0.144 s a report by 6000);
#   3. 31 days on, a report (a new listing's: the first, unheard, is
#      gone): the held ones are swept, the key's two among them gone
#      from its status, its three open ones kept.
#   builtin/moderation/report_index_check.sh
set -u
. "$(dirname "$0")/../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../.." && pwd)
check_tmp report_index; t=$CHECK_TMP
start_server "$t/sp.log" "setup code" 120 auto \
	"$here/Build/bin/buildat_server" --sim-clock -m "$here/apps/starport" -D "$t/sp" -l 3 ||
	fail "the Starport did not start ($t/sp.log)"
CHECK_PIDS+=($SERVER_PID)
python3 - "$SERVER_PORT" "$t" <<'PY' || fail "the reports ($t/sp.log)"
import json, os, socket, sys, time, urllib.request
port, t = int(sys.argv[1]), sys.argv[2]
B = "http://127.0.0.1:%d/api/v1/" % port
conf = {"name": "Reported", "kind": "app", "audience": "everyone", "access": "open",
        "port": 1, "app": "floorplanner", "version": "x", "players": 0,
        "descriptors": {"violence": "none", "chat": "moderated", "ugc": "none",
        "language": "no", "sexual": "no", "drugs": "no", "purchases": "no",
        "gambling": "no", "personal_data": "no"}}
lid = json.loads(urllib.request.urlopen(B + "announce", json.dumps(conf).encode()).read())["id"]
def post(path, body, src="127.0.0.1"):
    s = socket.socket(); s.settimeout(120); s.bind((src, 0)); s.connect(("127.0.0.1", port))
    b = json.dumps(body).encode()
    s.sendall(b"POST /api/v1/%s HTTP/1.1\r\nHost: x\r\nContent-Length: %d\r\n\r\n"
            % (path.encode(), len(b)) + b)
    out = b""
    while True:
        c = s.recv(65536)
        if not c: break
        out += c
    s.close()
    return json.loads(out.split(b"\r\n\r\n", 1)[1])
text = "the same words, " + "x" * 200
key = os.urandom(32).hex()
def report(src, k=None):
    b = {"listing": lid, "reason": "other", "text": text}
    if k: b["key"] = k
    r = post("report", b, src)
    assert r["ok"], r
    return r["receipt"]
mine = [report("127.0.0.1", key) for _ in range(5)]
def states():
    r = post("report_status", {"key": key, "receipts": mine})
    return {x["receipt"]: x["state"] for x in r["reports"]}
st = states()
assert [st[m] for m in mine] == ["open"] * 3 + ["held"] * 2, st
print("ok: three open, two held")
means = []
for i in range(2000):
    t0 = time.time()
    report("127.%d.%d.1" % (1 + i // 250, i % 250))
    if i % 500 == 0: tsum = 0
    tsum += time.time() - t0
    if i % 500 == 499: means.append(tsum / 500)
print("ok: a report's mean time by 500s: " + " ".join("%.4f" % m for m in means))
assert means[-1] < 2 * means[0], means
open(t + "/sp/sim_clock", "w").write(str(31 * 86400))
for _ in range(100):
    if "sim clock: %ds ahead" % (31 * 86400) in open(t + "/sp.log", errors="replace").read(): break
    time.sleep(0.1)
time.sleep(1)
# The listing, unheard for 31 days, is gone: a new one's report
lid = json.loads(urllib.request.urlopen(B + "announce", json.dumps(conf).encode()).read())["id"]
report("127.200.0.1")
st = states()
assert st == {m: "open" for m in mine[:3]}, st
print("ok: 31 days on, the held reports swept, the open ones kept")
PY
grep -aq "held reports past 30 days swept" "$t/sp.log" || fail "no sweep logged ($t/sp.log)"
echo "PASS: a report's cost flat by the text's count a day; held reports swept after 30 days, open ones kept"
# vim: set noet ts=4 sw=4:
