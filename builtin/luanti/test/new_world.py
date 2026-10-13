# SPDX-License-Identifier: Apache-2.0 OR MIT
"""[NEW_WORLD_FORM]: the new-world screen driven -- a name already taken
leaves it standing with what was typed, a seed pasted with Ctrl+V lands in
the name field, and the mapgen picked is the one written into world.mt."""
import os, re, sys, time
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import menu_drive
import uidrive  # menu_drive put util on the path
from menu_drive import Screen, click, type_into

log, fifo, saves = sys.argv[1:4]
d = uidrive.Drive(log, fifo)
write, read_block = d.write, d.block
def say(s):
    print(s, flush=True)

GAME = "mineclone2"

def offered_mapgens():
    """The mapgens the menu lists for GAME, in its order: main.cpp's
    game_mapgens, read from the same game.conf and minetest.conf."""
    game = os.path.join(saves, "..", "..", "..", "shared", "vanilla", "games", GAME)
    def conf(name, key):
        try:
            for line in open(os.path.join(game, name)):
                k, _, v = line.partition("=")
                if k.strip() == key:
                    return v.strip()
        except IOError:
            pass
        return ""
    def names(key):
        return set(n.strip() for n in conf("game.conf", key).split(",") if n.strip())
    allowed, disallowed = names("allowed_mapgens"), names("disallowed_mapgens")
    out = [n for n in ("v7", "v5", "valleys", "carpathian", "flat", "fractal",
                       "v6", "singlenode")
           if (not allowed or n in allowed) and n not in disallowed]
    chosen = conf("minetest.conf", "mg_name")
    if chosen in out:
        out.remove(chosen); out.insert(0, chosen)
    return out
phase = 0
notes = {}
n = 0
t0 = time.time()
while time.time() - t0 < 180:
    n += 1
    label = "n%d" % n
    write("event scan 8 %s" % label)
    lines = read_block(label)
    if lines is None:
        say("FAIL: no scan block (phase %d)" % phase); write("quit"); sys.exit(1)
    s = Screen(lines)
    name = s.name or ""
    if phase >= 3:
        break
    if name.endswith("launch_menu") or name.endswith("local_game"):
        e = menu_drive.find_game(write, s, GAME)
        if e: click(write, e)
    elif "vanilla menu: saves" in name:
        e = s.find("New world", "Text") or s.find("New save", "Text")
        if e: click(write, e)
    elif "which game?" in name:
        e = s.find(GAME, "Text")
        if e:
            click(write, e)
        elif s.edits():
            type_into(write, s.edits()[0], GAME)
            write("keypress Return", "delay 300")
    elif "New save, playing" in name:
        edits = s.edits()
        if len(edits) < 2:
            say("FAIL: the name screen has %d fields" % len(edits))
            write("quit"); sys.exit(1)
        if phase == 0:
            # A name that is already taken, and a seed beside it
            type_into(write, edits[0], "taken")
            type_into(write, edits[1], "2845188330406634615")
            e = s.find("Create and play", "Text")
            click(write, e)
            phase = 1
            # The refusal, which draws the screen again with its error line
            if not uidrive.wait_log(log, "menu: There is already a save", 10):
                say("FAIL: the taken name was not refused"); write("quit"); sys.exit(1)
        elif phase == 1:
            # The screen has to be this one still, with an error line on
            # it and both fields as they were
            err = [e[5] for e in s.ui if e[0] == "Text" and
                   "already a save" in e[5]]
            notes["error"] = err[0] if err else ""
            notes["name"] = edits[0][5]
            notes["seed"] = edits[1][5]
            say('after the refused create: error %r, name %r, seed %r' % (
                notes["error"], notes["name"], notes["seed"]))
            # The seed selected and copied, then pasted into the name: the
            # fields do Ctrl+C and Ctrl+V themselves once they are told to.
            # The 200 and 400 ms put the selection, the copy and the paste
            # in frames of their own.
            click(write, edits[1])
            write("keypress End", "keydown Left Shift", "keypress Home",
                  "keyup Left Shift", "delay 200",
                  "keydown Left Ctrl", "keypress C", "keyup Left Ctrl",
                  "delay 200")
            click(write, edits[0])
            write("keypress End", *(["keypress Backspace"] * 40))
            write("keydown Left Ctrl", "keypress V", "keyup Left Ctrl",
                  "delay 400")
            phase = 2
        elif phase == 2:
            notes["pasted"] = edits[0][5]
            say("Ctrl+V put %r in the name field" % notes["pasted"])
            type_into(write, edits[0], "mgtest")
            # A dropdown since [UI_DROPDOWN], whose list the scan does not
            # see: opened, and valleys picked by the keys at its place in
            # what the game offers
            label = s.find("Mapgen", "Text")
            drops = [d for d in s.ui if d[0] == "DropDownList" and label and
                     abs(d[2] - label[2]) < 10]
            if not drops:
                say("FAIL: no mapgen dropdown on the screen")
                write("quit"); sys.exit(1)
            order = offered_mapgens()
            if "valleys" not in order:
                say("FAIL: %s offers no valleys: %s" % (GAME, order))
                write("quit"); sys.exit(1)
            # simplified: the 500 ms is for the list to open, which logs
            # nothing, and the 150s pace the keys through it
            click(write, drops[0])
            write("delay 500", *(["keypress Down", "delay 150"] * order.index("valleys")))
            write("keypress Return", "delay 500")
            e = s.find("Create and play", "Text")
            click(write, e)
            phase = 3
            break
    elif name.endswith("show_message_dialog"):
        said = " ".join(e[5] for e in s.ui if e[0] == "Text" and e[5] not in ("", "Ok"))
        say("FAIL: a dialog took the screen away: %s" % said)
        write("quit"); sys.exit(1)
    # simplified: a screen changed by the step above is scanned again
    # 1.2 s later, not on a line of its own; each screen's draw logging its
    # name would let this wait for the next one
    write("delay 1200")

# The world is being made; world.mt is written before it is loaded
mt = os.path.join(saves, "mgtest", "luanti", "world.mt")
for _ in range(300):
    if os.path.exists(mt):
        break
    time.sleep(0.2)
write("quit")
text = open(mt).read() if os.path.exists(mt) else ""
mg = re.search(r"^mg_name\s*=\s*(\S+)", text, re.M)
say("world.mt says mg_name = %s" % (mg.group(1) if mg else "nothing"))
ok = (notes.get("error") and notes.get("name") == "taken" and
      notes.get("seed") == "2845188330406634615" and
      notes.get("pasted") == "2845188330406634615" and
      mg and mg.group(1) == "valleys")
say("PASS: the screen stood, the paste landed and the mapgen was written"
    if ok else "FAIL: %r" % notes)
sys.exit(0 if ok else 1)
