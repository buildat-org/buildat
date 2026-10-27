#!/usr/bin/env python3
# [NET_SIM]: a lossy link between a client and a server, as a userspace
# TCP proxy. Listens on --listen, forwards both directions to --to, and
# applies per direction a base delay, a bandwidth cap (a token bucket)
# and loss as stalls: with probability --loss percent per kilobyte
# forwarded, that direction is held for an RTO of 200 ms, doubling for
# each further event inside the window, as TCP's retransmission does --
# the wire is TCP, so a lost datagram never reaches a module as a lost
# packet, only as a stall. --seed replays a run.
#
#   util/netsim.py --listen 29900 --to localhost:29800 \
#       --delay 80 --rate 2000 --loss 2 --seed 1
#   util/netsim.py --check      # the self-check, no sockets
#
# It lies only about TCP's congestion window, which the cap stands in
# for. Hundred-odd lines, asyncio, nothing else.
import argparse, asyncio, os, random, socket, sys, time

RTO_MS = 200
CHUNK = 4096


class Link:
    """One direction's shaping. Pure logic over a clock, so it checks."""

    def __init__(self, delay_ms, rate_kbit, loss_pct, rng, clock=time.monotonic):
        self.delay = delay_ms / 1000.0
        self.rate = rate_kbit * 1000.0 / 8.0  # bytes per second, 0 = no cap
        self.loss = loss_pct / 100.0
        self.rng = rng
        self.clock = clock
        self.tokens = self.rate  # a second's worth to start
        self.filled_at = clock()
        self.ready_at = 0.0  # when the direction is free after a stall
        self.rto = RTO_MS / 1000.0
        self.stalls = 0

    def wait_for(self, n):
        """Seconds to hold n bytes before forwarding them: the base
        delay, the cap and any stall this chunk draws."""
        now = self.clock()
        hold = self.delay
        if self.rate > 0:
            self.tokens = min(self.rate, self.tokens + (now - self.filled_at) * self.rate)
            self.filled_at = now
            self.tokens -= n
            if self.tokens < 0:
                hold += -self.tokens / self.rate
        # A loss event per kilobyte, at the given odds
        events = 0
        for _ in range(max(1, n // 1024)):
            if self.rng.random() < self.loss:
                events += 1
        if events:
            self.stalls += events
            # A loss while the last stall still holds doubles the timer,
            # as a retransmission lost again would; one after it clears
            # starts over at the base RTO. (A window past the stall made
            # every loss on a busy link the next doubling, and the link
            # died in a minute, 2026-09-20.)
            if now < self.ready_at:
                self.rto = min(self.rto * 2, 60.0)
            else:
                self.rto = RTO_MS / 1000.0
            self.ready_at = max(now, self.ready_at) + self.rto * events
        if self.ready_at > now:
            hold += self.ready_at - now
        return hold


async def pump(reader, writer, link, name, stats):
    try:
        while True:
            data = await reader.read(CHUNK)
            if not data:
                break
            hold = link.wait_for(len(data))
            if hold > 0:
                await asyncio.sleep(hold)
            writer.write(data)
            await writer.drain()
            stats[name] += len(data)
    except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def serve(args):
    host, port = args.to.rsplit(":", 1)
    rng = random.Random(args.seed)
    stats = {"up": 0, "down": 0}

    async def on_client(cr, cw):
        try:
            sr, sw = await asyncio.open_connection(host, int(port))
            # Small receive buffers on both legs, so the link holds one
            # chunk and not the kernel's megabytes: a lossy link with big
            # buffers is a latency of minutes, which is not what is modelled
            for w in (cw, sw):
                w.get_extra_info("socket").setsockopt(
                    socket.SOL_SOCKET, socket.SO_RCVBUF, 64 * 1024)
        except OSError as e:
            print("netsim: cannot reach %s: %s" % (args.to, e), file=sys.stderr)
            cw.close()
            return
        up = Link(args.delay, args.rate, args.loss, rng)
        down = Link(args.delay, args.rate, args.loss, rng)
        print("netsim: client connected, shaping delay %d ms, rate %d kbit/s, loss %.1f%%"
              % (args.delay, args.rate, args.loss), flush=True)
        await asyncio.gather(pump(cr, sw, up, "up", stats), pump(sr, cw, down, "down", stats))
        print("netsim: client gone; %d up, %d down, stalls %d up %d down"
              % (stats["up"], stats["down"], up.stalls, down.stalls), flush=True)

    server = await asyncio.start_server(on_client, "127.0.0.1", args.listen)
    print("netsim: listening on %d for %s" % (args.listen, args.to), flush=True)
    async with server:
        await server.serve_forever()


def check():
    """The shaping over a fake clock: the delay alone, the cap's
    arithmetic, a stall's doubling inside the window, and a seed's
    replay."""
    t = [0.0]
    clock = lambda: t[0]
    # Delay alone
    l = Link(80, 0, 0, random.Random(1), clock)
    assert abs(l.wait_for(1000) - 0.080) < 1e-9
    # The cap: 2000 kbit/s is 250 kB/s; a second's tokens are there
    # at the start, so 500 kB holds two seconds over the delay
    l = Link(0, 2000, 0, random.Random(1), clock)
    assert abs(l.wait_for(500 * 1000) - 1.0) < 1e-6, l.wait_for(0)
    # Loss at a hundred percent: one stall of an RTO per kilobyte, and
    # a second chunk while the first stall holds doubles it
    l = Link(0, 0, 100, random.Random(1), clock)
    assert abs(l.wait_for(1024) - 0.2) < 1e-9
    t[0] = 0.1
    h = l.wait_for(1024)
    assert abs(h - (0.2 - 0.1 + 0.4)) < 1e-9, h
    # And once it has cleared it starts over
    t[0] = 10.0
    assert abs(l.wait_for(1024) - 0.2) < 1e-9
    # A seed replays
    a = [Link(0, 0, 50, random.Random(7), clock).wait_for(1024) for _ in range(1)]
    b = [Link(0, 0, 50, random.Random(7), clock).wait_for(1024) for _ in range(1)]
    assert a == b
    print("netsim: ok")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--listen", type=int, default=29900)
    ap.add_argument("--to", default="localhost:29800")
    ap.add_argument("--delay", type=float, default=0, help="ms, each way")
    ap.add_argument("--rate", type=float, default=0, help="kbit/s, each way; 0 is no cap")
    ap.add_argument("--loss", type=float, default=0, help="percent per kilobyte, as stalls")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()
    if args.check:
        check()
        return
    # [NETSIM_ORPHANS] Gone with the process that started it: a starter's
    # trap misses a SIGKILL, and three proxies outlived theirs by hours
    # holding check ports (2026-10-27). Linux only; the getppid() check
    # covers a parent that died before the prctl.
    # simplified: a parent dead during interpreter start goes unseen
    # (getppid is then already the reaper); --parent PID if that bites.
    if sys.platform.startswith("linux"):
        import ctypes, signal
        ppid = os.getppid()
        ctypes.CDLL(None, use_errno=True).prctl(1, signal.SIGTERM)  # PR_SET_PDEATHSIG
        if os.getppid() != ppid:
            return
    try:
        asyncio.run(serve(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
