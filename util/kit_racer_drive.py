# SPDX-License-Identifier: Apache-2.0 OR MIT
# Brimstone Speedway's driver for util/kit_racer_check.sh,
# util/kit_racer_bots_check.sh (its comment there) and (Brimstone Stunts'
# Bone Yard) util/kit_stunts_check.sh: a scripted client's
# keys from its log's body lines, over its command fifo
#   python3 -I util/kit_racer_drive.py <client log> <fifo> <seconds> <stop regex>
# SHOTS "x,z,file ...": a screenshot each within 6 m of its place;
# SHOTS_IN_ORDER=1 ([KIT_STUNTS]): each only after the one before it (a
# place the lap passes twice, over a bridge and under it)
import json, math, os, re, sys, time
log, fifo, secs, stop = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
target = [float(v) for v in os.environ["TARGET"].split(",")] if os.environ.get("TARGET") else None
fire_on = os.environ.get("FIRE_ON")
fire_at = [float(v) for v in os.environ["FIRE_AT"].split(",")] if os.environ.get("FIRE_AT") else None
armed = False
drift = [float(v) for v in os.environ["DRIFT"].split(",")] if os.environ.get("DRIFT") else None
drift_s = float(os.environ.get("DRIFT_S", "0.5"))
drift_shot = os.environ.get("DRIFT_SHOT")
shots = [s.split(",", 2) for s in os.environ.get("SHOTS", "").split()]
in_order = bool(os.environ.get("SHOTS_IN_ORDER"))
aim_file, aim = os.environ.get("AIM_FILE"), None
A_LAT, A_BRAKE, TOP = 8.0, 6.0, 30.0
out = open(fifo, "w", buffering=1)
def rounded(pts):
    """The closed line: straights between the corners, an arc of r round each"""
    n, line = len(pts), []
    for i in range(n):
        (x0, z0, _), (x1, z1, r), (x2, z2, _) = pts[i - 1], pts[i], pts[(i + 1) % n]
        la, lb = math.hypot(x1 - x0, z1 - z0), math.hypot(x2 - x1, z2 - z1)
        ax, az, bx, bz = (x1 - x0) / la, (z1 - z0) / la, (x2 - x1) / lb, (z2 - z1) / lb
        turn = math.atan2(ax * bz - az * bx, ax * bx + az * bz)
        t = r * math.tan(abs(turn) / 2)
        px, pz = x1 - ax * t, z1 - az * t
        s = 1 if turn > 0 else -1
        cx, cz = px - az * r * s, pz + ax * r * s
        a0 = math.atan2(pz - cz, px - cx)
        k = max(1, int(abs(turn) * r / 1.0))
        line += [(cx + r * math.cos(a0 + turn * j / k), cz + r * math.sin(a0 + turn * j / k))
                 for j in range(k + 1)]
    # (1 m apart along the whole loop)
    out1, acc = [line[0]], 0.0
    for i in range(1, len(line) + 1):
        (xa, za), (xb, zb) = line[i - 1], line[i % len(line)]
        d = math.hypot(xb - xa, zb - za)
        while d > 1e-9 and acc + d >= 1.0:
            f = (1.0 - acc) / d
            xa, za = xa + (xb - xa) * f, za + (zb - za) * f
            d -= 1.0 - acc
            acc = 0.0
            out1.append((xa, za))
        acc += d
    return out1
P = rounded([tuple(map(float, c.split(","))) for c in os.environ["PATH_PTS"].split()])
N = len(P)
def radius(i, k=4):
    (xa, za), (xb, zb), (xc, zc) = P[(i - k) % N], P[i], P[(i + k) % N]
    cr = (xb - xa) * (zc - za) - (zb - za) * (xc - xa)
    if abs(cr) < 1e-6:
        return 1e9
    return (math.hypot(xb - xa, zb - za) * math.hypot(xc - xb, zc - zb) *
            math.hypot(xc - xa, zc - za) / (2 * abs(cr)))
V = [min(TOP, math.sqrt(A_LAT * radius(i))) for i in range(N)]
for _ in range(2):
    for i in range(N - 1, -1, -1):
        V[i] = min(V[i], math.sqrt(V[(i + 1) % N] ** 2 + 2 * A_BRAKE))
def send(*cmds):
    out.write("\n".join(cmds) + "\n")
keys = set()
def key(k, on):
    if on and k not in keys:
        send("keydown " + k)
        keys.add(k)
    elif not on and k in keys:
        send("keyup " + k)
        keys.discard(k)
f = open(log, errors="replace")
f.seek(0, 2)
t0, u, x, z, stopped = time.time(), None, None, None, False
slow_since, back_till, drift_till, last, queued = None, 0, None, None, 0
send("event kit_body")
asked = time.time()
while time.time() - t0 < secs:
    line = f.readline()
    if not line:
        # (a sample with no vehicle line -- asked just after a put, before a
        # step -- asks for none after it: asked again)
        if not queued and time.time() - asked > 1.0:
            send("frames 2", "event kit_body")
            asked = time.time()
        time.sleep(0.01)
        continue
    if re.search(stop, line):
        stopped = True
        break
    if fire_on and re.search(fire_on, line):
        fire_on = None
        armed = True
    if armed and (not fire_at or x is not None and math.hypot(fire_at[0] - x, fire_at[1] - z) < 4):
        armed = False
        send("keypress Left Ctrl")
        print("fired", flush=True)
    m = re.search(r"kit: body at (-?[0-9.]+),(-?[0-9.]+),(-?[0-9.]+)", line)
    if m:
        if x is not None and (float(m[1]) - x) ** 2 + (float(m[3]) - z) ** 2 > 64:
            u = None  # (a teleport: found again on the whole loop)
        x, z = float(m[1]), float(m[3])
        continue
    m = re.search(r"kit: vehicle speed (-?[0-9.]+),-?[0-9.]+,(-?[0-9.]+), yaw (-?[0-9.]+)", line)
    if not m or x is None:
        continue
    now = time.time() - t0
    vx, vz, yaw = float(m[1]), float(m[2]), float(m[3])
    v = math.hypot(vx, vz)
    if u is None:
        u = min(range(N), key=lambda q: (P[q][0] - x) ** 2 + (P[q][1] - z) ** 2)
    u = min(range(u - 10, u + 40),
            key=lambda q: (P[q % N][0] - x) ** 2 + (P[q % N][1] - z) ** 2) % N
    tx, tz = target or P[(u + int(5 + 0.35 * v)) % N]
    # (AIM_FILE's place once it is written: driven through when ahead,
    # slowly, toward a point past it on the line from the car through it)
    aiming = False
    if aim is None and aim_file and os.path.exists(aim_file):
        aim = [float(q) for q in open(aim_file).read().split(",")]
    if aim and aim is not True:
        ahead = (aim[0] - x) * math.sin(math.radians(yaw)) + (aim[1] - z) * math.cos(math.radians(yaw))
        d = math.hypot(aim[0] - x, aim[1] - z)
        if d < 25 and ahead > -0.5:
            tx, tz = aim[0] + (aim[0] - x) / d * 6, aim[1] + (aim[1] - z) / d * 6
            aiming = True
        elif ahead <= -0.5 and d < 6:
            aim = True
    bearing = math.degrees(math.atan2(tx - x, tz - z))
    err = (bearing - yaw + 540) % 360 - 180
    # (on the way: the way it goes, a slide's too, less the turning's rate:
    # the keys are on or off and a sample late)
    rate = ((yaw - last[0] + 540) % 360 - 180) / max(0.02, now - last[1]) if last else 0
    last = (yaw, now)
    head = math.degrees(math.atan2(vx, vz)) if v > 3 and not target else yaw
    steer = (bearing - head + 540) % 360 - 180 - 0.2 * rate
    vt = TOP if target else V[(u + 3) % N]
    if aiming:
        vt = min(vt, 7)
    if drift and drift_till is None and math.hypot(drift[0] - x, drift[1] - z) < 35:
        vt = max(vt, 15)  # (into the bend too fast: the handbrake's to turn it)
    if drift and drift_till is None and math.hypot(drift[0] - x, drift[1] - z) < 6:
        drift_till = now + drift_s
        # (the way the bend ahead turns: the line's heading 15 m on against
        # now's; left is the yaw falling, A)
        (xa, za), (xb, zb) = P[u], P[(u + 1) % N]
        (xc, zc), (xd, zd) = P[(u + 15) % N], P[(u + 16) % N]
        drift_left = (xb - xa) * (zd - zc) - (zb - za) * (xd - xc) > 0
        print("drift from %.2f" % now, flush=True)
    for sh in shots[:1] if in_order else shots[:]:
        if math.hypot(float(sh[0]) - x, float(sh[1]) - z) < 6:
            shots.remove(sh)
            send("screenshot " + sh[2])
    if drift_shot and drift_till is not None and now >= drift_till:
        send("screenshot " + drift_shot)
        drift_shot = None
    if drift_till is not None and now < drift_till:
        key("W", False)
        key("S", False)
        key("D", not drift_left)
        key("A", drift_left)
        if drift_till - now > drift_s - 0.001:
            # (the pull's length the client's own: a sample comes some 0.2 s
            # apart, and a tenth of a second more turns it 30 degrees more;
            # a sample each tenth in it, then one after, asked for here)
            k = max(1, round(drift_s / 0.1))
            send("keydown Space", *["delay 100", "event kit_body"] * k,
                 "keyup Space", "frames 2", "event kit_body")
            queued = k + 1
    elif now < back_till:
        key("Space", False)
        key("W", False)
        key("S", True)
        key("D", err < 0)
        key("A", err > 0)
    else:
        key("Space", False)
        # (stuck on something: back off it a second)
        slow_since = (slow_since or now) if v < 0.8 and "W" in keys else None
        if slow_since is not None and now - slow_since > 1.0:
            back_till, slow_since = now + 1.0, None
        # (sliding: hands off, the car's own counter-steer brings it
        # straight; a key's full lock on top swings it the other way)
        sliding = v > 3 and abs((math.degrees(math.atan2(vx, vz)) - yaw + 540) % 360 - 180) > 15
        key("W", v < vt - 0.5 and not sliding)
        key("S", v > vt + 1.0 and not sliding)
        key("D", steer > 3 and not sliding)
        key("A", steer < -3 and not sliding)
    print("t %.2f at %.1f,%.1f v %.1f yaw %.1f vel %.1f keys %s" % (
        now, x, z, v, yaw, math.degrees(math.atan2(vx, vz)) if v > 0.5 else yaw,
        "".join(sorted(keys))), flush=True)
    if queued:
        queued -= 1
    else:
        send("frames 2", "event kit_body")
    asked = time.time()
for k in list(keys):
    key(k, False)
print("stopped" if stopped else "time up", flush=True)
sys.exit(0 if stopped else 1)
