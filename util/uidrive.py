# SPDX-License-Identifier: Apache-2.0 OR MIT
"""A check's UI drive ([CHECK_KIT]): a client started with `-c -` reading
its commands from a fifo, and its log read back for the scans.

    import sys; sys.path.insert(0, "<repo>/util"); import uidrive
    d = uidrive.Drive(cli_log, fifo)
    els = d.scan()
    d.click(d.find(els, "Ok") or d.fail("no Ok; saw " + uidrive.texts(els)))

An element is (kind, x, y, w, h, text, image). Hidden ones are left out
of a scan: what cannot be seen cannot be clicked.
"""
import re
import sys
import time

UI_RE = re.compile(
    r"ui\s+(\w+) at (-?\d+),(-?\d+) size (\d+)x(\d+)(?: text \"(.*?)\")?"
    # A field's cursor and a text's selection ([TEXT_KEYS])
    r"(?: cursor \d+)?(?: selection \d+\+\d+)?"
    r"(?: image (?:\"(.*?)\"|\? \(.*\)))?(?: (hidden))?(?: priority -?\d+)?$")


def parse_ui(lines):
    """The visible `ui ...` elements of a scan block's lines."""
    out = []
    for line in lines:
        m = UI_RE.search(line)
        if m and m.group(8) is None:
            out.append((m.group(1), int(m.group(2)), int(m.group(3)),
                        int(m.group(4)), int(m.group(5)), m.group(6) or "",
                        m.group(7) or ""))
    return out


def find(els, text, kind=None, contains=False):
    """The first element of some size with this text (or containing it,
    case-insensitive), of this kind when one is given."""
    for e in els or []:
        if kind and e[0] != kind:
            continue
        if e[3] <= 0 or e[4] <= 0:
            continue
        if (text.lower() in e[5].lower()) if contains else e[5] == text:
            return e
    return None


def texts(els):
    return ", ".join("%r" % e[5] for e in els or [])[:300]


def centre(e):
    return e[1] + e[3] // 2, e[2] + e[4] // 2


def log_has(path, needle):
    """Whether the file has `needle` (a str, or a compiled regex)."""
    try:
        data = open(path, "rb").read().decode("utf-8", "replace")
    except OSError:
        return False
    return (needle.search(data) is not None) if hasattr(needle, "search") \
        else needle in data


def wait_log(path, needle, timeout=60):
    """Until the file has `needle`; False when it did not in time."""
    t0 = time.time()
    while time.time() - t0 < timeout:
        if log_has(path, needle):
            return True
        time.sleep(0.3)
    return log_has(path, needle)


class Drive:
    def __init__(self, log, fifo):
        self.log = log
        self.w = open(fifo, "w")
        self.seen = 0   # bytes of the log already read by block()

    def write(self, *cmds):
        try:
            for c in cmds:
                self.w.write(c + "\n")
            self.w.flush()
        except (BrokenPipeError, OSError):
            pass

    def block(self, label, timeout=60):
        """The lines of the next `scan <label>:` block, its prefix off, up
        to its `done` line, which is consumed; None on timeout."""
        pre = "scan %s: " % label
        done = re.compile((r"scan %s: done, \d+ lines" % re.escape(label)).encode())
        t0 = time.time()
        while time.time() - t0 < timeout:
            buf = open(self.log, "rb").read()
            m = done.search(buf, self.seen)
            if m:
                data = buf[self.seen:m.end()].decode("utf-8", "replace")
                self.seen = m.end()
                out = []
                for line in data.splitlines():
                    i = line.find(pre)
                    if i >= 0:
                        out.append(line[i + len(pre):])
                return out
            time.sleep(0.3)
        return None

    def scan(self, label="scan", cmd="event scan", timeout=40):
        """A scan's visible elements; None on timeout. Vanilla's scan
        names its lines "scan scan:" whatever the event's label, so the
        default label is that."""
        self.write("delay 800", cmd)
        lines = self.block(label, timeout)
        return None if lines is None else parse_ui(lines)

    def click(self, e, settle_ms=600):
        x, y = centre(e)
        self.write("mouse_pos %d %d" % (x, y), "delay 200",
                   "mouse_click left", "delay %d" % settle_ms)

    def fail(self, why):
        print("FAIL: " + why, flush=True)
        self.write("quit")
        sys.exit(1)


if __name__ == "__main__":
    # The parser's self-check
    els = parse_ui([
        'ui Button at 10,20 size 30x40 text "Ok"',
        'ui Text at 1,2 size 3x4 text "gone" hidden',
        'ui BorderImage at 0,0 size 5x5 image "a.png" priority 2',
        'ui Text at 1,2 size 3x4 text "gone" hidden priority 1',
    ])
    assert els == [("Button", 10, 20, 30, 40, "Ok", ""),
                   ("BorderImage", 0, 0, 5, 5, "", "a.png")], els
    assert find(els, "ok", contains=True)[0] == "Button"
    assert find(els, "ok") is None and centre(els[0]) == (25, 40)
    print("uidrive: ok")
