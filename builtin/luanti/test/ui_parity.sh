#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# tier: broken
# broken: back to full; 1 differ; the same on dev (local/runs/dev_baseline)
# [UI_PARITY] 1 and 2: the two coordinate systems and the slot pitch,
# against official Luanti; 3 to 5 a list's stacks; 8 bgcolor[] and
# background9[]; 9 a HUD text's lines; 7 a tooltip, against
# the number in Luanti's source (official Luanti takes no cursor moved by
# xdotool, so it is not shot). ui_parity.lua shows a legacy form and then a
# real_coordinates one, each with three box[]es and a list whose slots
# listcolors makes magenta; both clients are shot (official Luanti's window
# by `import`, on the desktop, as reference_shots does) and every rectangle
# is put in the form's units, from the red box to the green one, so the
# overall scale -- the engine's business -- cancels out. Each number within
# 0.03 units of official's (a pixel and a half) passes. Shots under
# local/ui_parity/. Needs the Luanti checkout's luanti-refshots and devtest.
#
#   builtin/luanti/test/ui_parity.sh
set -u
. "$(dirname "$0")/../../../util/check_lib.sh"
here=$(cd "$(dirname "$0")/../../.." && pwd)
me=$(cd "$(dirname "$0")" && pwd)
out="$here/local/ui_parity"; mkdir -p "$out"
luanti=~/projects/luanti; bin=$luanti/bin/luanti-refshots
W=1024; H=768
if check_pgrep buildat >/dev/null || pgrep -x luanti-refshots >/dev/null; then
	echo "a client or a Luanti server is already running" >&2; exit 2
fi
rm -f "$out"/*.png

# Official Luanti: its own server and client on devtest, the fixture a worldmod
work="$out/luanti_world"
rm -rf "${work:?}"; mkdir -p "$work/worldmods/ui_parity"
printf 'gameid = devtest\nbackend = sqlite3\nplayer_backend = sqlite3\nauth_backend = sqlite3\nmod_storage_backend = sqlite3\ncreative_mode = false\nserver_announce = false\n' > "$work/world.mt"
cp "$me/ui_parity.lua" "$work/worldmods/ui_parity/init.lua"
printf 'name = ui_parity\n' > "$work/worldmods/ui_parity/mod.conf"
printf 'screen_w = %s\nscreen_h = %s\nfullscreen = false\nmute_sound = true\nenable_damage = false\n' \
	$W $H > "$out/luanti.conf"
port=30031
( cd "$luanti" && exec "$bin" --server --world "$work" --port $port \
	--config "$out/luanti.conf" > "$out/luanti_srv.log" 2>&1 ) &
srv=$!
for _ in $(seq 600); do
	grep -q "Server for gameid" "$out/luanti_srv.log" && break
	kill -0 $srv 2>/dev/null || { echo "FAIL: official Luanti's server exited"; exit 1; }
	sleep 0.2
done
grep -q "Server for gameid" "$out/luanti_srv.log" || { echo "FAIL: official Luanti's server did not start"; kill $srv; exit 1; }
( cd "$luanti" && exec "$bin" --go --address 127.0.0.1 --port $port --name uip \
	--config "$out/luanti.conf" > "$out/luanti_cli.log" 2>&1 ) &
cli=$!
trap 'kill $cli $srv 2>/dev/null' EXIT
win=""
# Its window, polled
for _ in $(seq 200); do
	win=$(wmctrl -lp | awk -v p="$cli" '$3 == p {print $1; exit}')
	[ -n "$win" ] && break
	kill -0 $cli 2>/dev/null || break
	sleep 0.2
done
[ -n "$win" ] || { echo "FAIL: no window for official Luanti"; exit 1; }
# Each form on the server's timer; official's client logs nothing as it
# shows one, so the 2 s after the server's line are its drawing
for f in legacy real items bg; do
	for _ in $(seq 300); do grep -q "UIP $f" "$out/luanti_srv.log" && break; sleep 0.2; done
	grep -q "UIP $f" "$out/luanti_srv.log" || { echo "FAIL: official Luanti showed no $f form"; exit 1; }
	sleep 2
	import -window "$win" "$out/official_$f.png"
done
kill $cli $srv; wait $cli $srv 2>/dev/null

# buildat: vanilla on devtest, the fixture as BUILDAT_LUANTI_LUA
t=$(mktemp -d); P=29598; pid=
trap '[ -n "$pid" ] && kill $pid 2>/dev/null; rm -rf "${t:?}"' EXIT
mkdir -p "$t/srv/shared/vanilla"
ln -s "$BUILDAT_USER_PATH/shared/vanilla/games" "$t/srv/shared/vanilla/games"
cp "$me/ui_parity.lua" "$t/srv/shared/"
cd "$here/Build"
BUILDAT_LUANTI_GAME=devtest BUILDAT_LUANTI_SAVE=uip BUILDAT_LUANTI_LUA="$t/srv/shared/ui_parity.lua" \
	start_server "$out/buildat_srv.log" "Mods loaded" 120 $P \
	bin/buildat_server -u launcher=1 -m ../apps/vanilla -D "$t/srv" -l 3 ||
	{ echo "FAIL: the server did not start"; exit 1; }
pid=$SERVER_PID
# Each form as the client opens it; the 1.5 s after the line are its
# pictures loaded and drawn. The tooltip: a move to start the hover, and
# the 2 s are its hover time
f="wait_log 15000 form uip opened\ndelay 1500\n"
printf "wait_log 90000 the server put the player at\n${f}screenshot $out/buildat_legacy.png\n${f}screenshot $out/buildat_real.png\n${f}screenshot $out/buildat_items.png\n${f}mouse_pos 512 384\ndelay 500\nmouse_pos 513 384\ndelay 2000\nscreenshot $out/buildat_tips.png\n${f}screenshot $out/buildat_bg.png\nquit\n" > "$t/c"
timeout 150 bin/buildat -s 127.0.0.1:$P -w ${W}x$H -u 1 -l 3 -o sound_mute=1 \
	-c @"$t/c" > "$out/buildat_cli.log" 2>&1 ||
	{ echo "FAIL: the drive ($out/buildat_cli.log): $(grep -ao 'Command sequence failed.*' "$out/buildat_cli.log" | head -1)"; exit 1; }

python3 - "$out" <<'PY'
import sys, numpy as np
from PIL import Image
out = sys.argv[1]
def rect(m):
	ys, xs = np.nonzero(m)
	return (xs.min(), ys.min(), xs.max() + 1, ys.max() + 1) if len(xs) else None
def runs(v):
	r, start = [], None
	for i, on in enumerate(list(v) + [False]):
		if on and start is None: start = i
		if not on and start is not None: r.append((start, i)); start = None
	return [x for x in r if x[1] - x[0] > 3]
def measure(path, span, vspan, items, tips=False, bg=False):
	# Above the hotbar and the hand; by which channel leads, since a box's
	# colour is drawn blended
	a = np.asarray(Image.open(path).convert("RGB")).astype(int)
	a = a[:int(a.shape[0] * 0.8)]
	r, g, b = a[..., 0], a[..., 1], a[..., 2]
	# The first red block and the last green one: an item's picture may
	# carry either colour
	def block(m, i):
		xs = runs(m.any(axis=0))
		if not xs:
			return None
		x0, x1 = xs[i]
		y0, y1 = runs(m[:, x0:x1].any(axis=1))[i]
		return (x0, y0, x1, y1)
	red = block((r > 120) & (g < 70) & (b < 90), 0)
	green = block((g > 130) & (r < 60) & (b < 60), -1)
	blue = rect((b > 140) & (r < 80) & (g < 80))
	mag = (r > 200) & (g < 60) & (b > 200)
	# The slots below the HUD's texts, which are magenta too
	slotmag = mag.copy()
	slotmag[:int(a.shape[0] * 0.33)] = False
	if not red or not green:
		return None
	ux, uy = (green[0] - red[0]) / span, (green[1] - red[1]) / vspan
	f = lambda q: [(q[0] - red[0]) / ux, (q[1] - red[1]) / uy,
			(q[2] - q[0]) / ux, (q[3] - q[1]) / uy]
	m = {"red": f(red)}
	if blue:
		m["blue"] = f(blue)
	xr, yr = runs(slotmag.any(axis=0)), runs(slotmag.any(axis=1))
	if not items:
		m["slots"] = [len(xr)]
	if xr and yr and not items:
		m["slot 1"] = f((xr[0][0], yr[0][0], xr[0][1], yr[0][1]))
		m["slot 8"] = f((xr[-1][0], yr[0][0], xr[-1][1], yr[0][1]))
	if items:
		# [UI_PARITY] 3 to 5, in units from each slot's drawn corner (its
		# magenta about where the form puts it): the picture's extent, the
		# count's white, the wear bar's colour and black
		def inslot(i, q):
			px, py = red[0] + (0.375 + 1.25 * i) * ux, red[1] + uy
			x0, y0 = int(px - 0.1 * ux), int(py - 0.1 * uy)
			x0, y0, x1, y1 = rect(mag[y0:int(py + 1.1 * uy),
					x0:int(px + 1.1 * ux)]) + np.array([x0, y0, x0, y0])
			if q is bar:
				# its bottom quarter, below the pickaxe's dark lines
				y0 = y1 - (y1 - y0) // 4
			r = rect(q[y0:y1, x0:x1])
			return r and [r[0] / ux, r[1] / uy, r[2] / ux, r[3] / uy]
		white = (r > 215) & (g > 215) & (b > 215)
		bar = ((r > 200) & (g > 120) & (b < 60)) | ((r < 30) & (g < 30) & (b < 30))
		m["node picture"] = inslot(0, ~mag)
		m["count 1"] = [0 if inslot(0, white) is None else 1]
		# its right, top and bottom: the font's face and width are the
		# engine's own
		m["count 5"] = [inslot(1, white)[i] for i in (2, 1, 3)]
		m["count 99"] = [inslot(2, white)[i] for i in (2, 1, 3)]
		m["wear bar"] = inslot(3, bar)
		m["flat picture"] = inslot(4, ~mag)
		# [UI_PARITY] 9: the second HUD text line's centre (the one at
		# 0.3) and right edge (the one at 0.8) from the first's, in units:
		# each line is aligned on its own. Where the block lands is off by
		# the font's ink against its advance, about 0.15 units, which is
		# the engine's font and not measured
		top = mag[:int(a.shape[0] * 0.33)]
		for name, x0, x1, at in (("hud centred", 0, 512, 0.5),
				("hud left of", 512, 1024, 1)):
			lines = runs(top[:, x0:x1].any(axis=1))
			m[name] = []
			for l0, l1 in lines[:2]:
				xs = np.nonzero(top[l0:l1, x0:x1].any(axis=0))[0] + x0
				x = xs.min() + (xs.max() + 1 - xs.min()) * at
				m[name].append(x / ux)
			m[name] = [m[name][1] - m[name][0]] if len(m[name]) == 2 else None
	if tips:
		m = {}
		# [UI_PARITY] 7: the tooltip's corner from the cursor, in units, and
		# that it wears the form's colours
		tip = rect((b > 200) & (r < 60) & (g < 60))
		m["tooltip corner"] = tip and [(tip[0] - 513) / ux, (tip[1] - 384) / uy]
		m["tooltip text"] = [int(((r > 200) & (g > 200) & (b < 60)).any())]
	if bg:
		# [UI_PARITY] 8: the form's colour over the form, the screen's
		# down the left edge, and the background9 between them
		blue = (b > 200) & (r < 60) & (g < 60)
		yellow = (r > 200) & (g > 200) & (b < 60)
		m = {"bgcolor form": f(rect(blue)),
			"bgcolor screen": [round(yellow[50:, 5].mean(), 1)]}
		x0, y0, x1, y1 = rect(blue)
		rest = ~(blue | yellow | ((r > 120) & (g < 70) & (b < 90)) |
				((g > 130) & (r < 60) & (b < 60)))
		rest[:y0], rest[y1:], rest[:, :x0], rest[:, x1:] = False, False, False, False
		m["background9"] = f(rect(rest))
	return m
bad = 0
for form, span, vspan in (("legacy", 7, 5), ("real", 9.75, 6.5),
		("items", 9.75, 2), ("tips", 9.75, 2), ("bg", 9.75, 2)):
	# A tooltip's corner is m_btn_height from the cursor, 15/13 * 0.35 of
	# a unit (guiFormSpecMenu.cpp), in the form's own colours
	o = {"tooltip corner": [15 / 13 * 0.35] * 2, "tooltip text": [1]} \
			if form == "tips" else \
			measure("%s/official_%s.png" % (out, form), span, vspan, form == "items",
					False, form == "bg")
	b = measure("%s/buildat_%s.png" % (out, form), span, vspan, form == "items",
			form == "tips", form == "bg")
	if not o or not b:
		print("FAIL: %s: nothing measured in %s" % (form,
				"official's" if not o else "buildat's"))
		bad += 1
		continue
	for k in o:
		ok = o[k] and b.get(k) and len(b[k]) == len(o[k]) and all(abs(x - y) <= 0.03
				for x, y in zip(o[k], b[k]))
		bad += 0 if ok else 1
		print("%s %-7s official %s buildat %s%s" % (form, k,
				" ".join("%.3f" % x for x in (o[k] or [])),
				" ".join("%.3f" % x for x in (b.get(k) or [])), "" if ok else "  <-- differs"))
print("PASS: both coordinate systems, the slot pitch, the stacks, the tooltip, the backgrounds and the HUD text as official's" if not bad
		else "FAIL: %d differ" % bad)
sys.exit(1 if bad else 0)
PY
