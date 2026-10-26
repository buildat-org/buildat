#!/usr/bin/env node
// Drives a headless browser through steps, for checks of the web client
// ([WEB_CLIENT]) in a real browser: Firefox over WebDriver BiDi, Chrome over
// the DevTools protocol, with Node's own WebSocket (Node 22 or newer) and no
// packages. util/web_drive.sh starts the server and the browser and runs
// this; it can be run by hand against a browser already listening:
//
//   node util/web_drive.js --browser firefox|chrome --port 9334 \
//       --steps steps.json --log page.log [--var NAME=value ...]
//
// A steps file is a JSON list of steps, each a list:
//   ["nav", url]            open the page, and wait for it to load; the
//                           address gets pref=web_idle_fps=60 (full_rate)
//   ["wait", ms]
//   ["waitlog", regex, s]   until a line of the page's console matches, one
//                           after the last waitlog's, at most s seconds
//                           (default 60); fails the run if none does
//   ["type", text]          as typed, character by character
//   ["key", name]           Tab, Enter, Escape, Space, Backspace, F1..F12,
//                           Up, Down, Left, Right, or one character
//   ["holdkey", name, ms]   a key held down for ms: a car driven
//   ["selall"]              Ctrl+A
//   ["chord", "Ctrl+Shift+z"] a key with Ctrl, Alt and Shift held
//   ["click", x, y]         left button, in CSS pixels
//   ["click", x, y, ms, b]  button b (0 left, 1 middle, 2 right) held ms
//   ["mouse", x, y]         the pointer there, no button
//   ["wheel", x, y, dy]     the mouse wheel turned over x, y by dy CSS
//                           pixels (positive scrolls down); it moves no
//                           pointer, so a "mouse" step there goes first or
//                           the UI looks for what is under the old one
//   ["tap", x, y]           a finger's touch there and up again
//   ["tap", x, y, n]        n taps there with nothing awaited between,
//                           a double tap in time (Chrome only)
//   ["hold", x, y, ms]      a finger held still there for ms
//   ["drag", x0, y0, x1, y1, "touch"]
//                           the left button (or a finger) down at x0, y0,
//                           moved to x1, y1 over half a second, and up
//                           (Chrome: a finger only)
//   ["shot", path]          a PNG of the page
//   ["eval", js]            print what the expression gives
//   ["window", n]           the steps after go to the nth top-level window
//                           (0 the first; one a page opened is 1), Firefox
//                           only
//   ["file", path]          the file the browser's picker gives the next
//                           time the page opens it ([HEARTH_USABILITY]),
//                           Chrome only
//   ["fingers", ax0, ay0, bx0, by0, ax1, ay1, bx1, by1]
//                           two fingers down at a and b, moved together to
//                           their second places over half a second, and up:
//                           a pinch, a two-finger scroll (Chrome only)
//   ["carry", ax0, ay0, ax1, ay1, bx, by, ax2, ay2]
//                           a finger down at a0 and moved to a1, a second
//                           one tapped at b while it is there, the first
//                           moved on to a2 and up: Luanti's right click
//                           while a stack is carried (Chrome only)
//   ["viewport", w, h]      the page that size from here on, as a phone's
//                           on-screen keyboard makes it (Chrome only)
//   ["cpu", rate]           the page's CPU that many times slower, as a
//                           phone's (Chrome only)
//   ["watch", regex, s, ms] until a console line from here on matches, the
//                           page as drawn taken every 500 ms: says each
//                           #status text (the loading stripe's while up) and each stretch over ms where
//                           neither it nor the screen changed, and fails
//                           after the match if there was one (Chrome only)
// ${NAME} in a string is a --var's value. The page's console goes to the
// log, a line each. Exits 1 when a step fails, with the page shot to
// ${OUT}/failed.png.
"use strict";
const fs = require("fs");
// **The drives' pages run at full rate** ([WEB_LINK_BEHIND]): a headless
// browser's page counts as unfocused and ran at web_idle_fps (5 frames a
// second), and a streaming world's packets reached it minutes late. A
// nav's address asks for 60 unless it names web_idle_fps itself.
function full_rate(u) {
	const url = new URL(u);
	if (!url.searchParams.getAll("pref").some(p => p.startsWith("web_idle_fps=")))
		url.searchParams.append("pref", "web_idle_fps=60");
	return url.toString();
}

const args = {vars: {}};
for (let i = 2; i < process.argv.length; i++) {
	const a = process.argv[i];
	if (a === "--var") {
		const [k, ...v] = process.argv[++i].split("=");
		args.vars[k] = v.join("=");
	} else if (a.startsWith("--")) {
		args[a.slice(2)] = process.argv[++i];
	}
}
if (!args.browser || !args.port || !args.steps) {
	console.error("usage: web_drive.js --browser firefox|chrome --port N " +
			"--steps file [--log file] [--var NAME=value ...]");
	process.exit(2);
}
const fill = v => typeof v === "string" ?
		v.replace(/\$\{(\w+)\}/g, (_, k) => k in args.vars ? args.vars[k] : "") : v;
const steps = JSON.parse(fs.readFileSync(args.steps, "utf8")).map(s => s.map(fill));
const logPath = args.log || "/dev/stdout";
const lines = [];
// Where the next waitlog starts looking: past the line the last one matched
let cursor = 0;
function logLine(t) {
	lines.push(t);
	fs.appendFileSync(logPath, t + "\n");
}

// Keys: WebDriver's code points, and the DevTools protocol's key, code
// and Windows key code
const KEYS = {
	Tab: ["", "Tab", 9], Enter: ["", "Enter", 13],
	Escape: ["", "Escape", 27], Space: [" ", "Space", 32],
	Backspace: ["", "Backspace", 8], Up: ["", "ArrowUp", 38],
	Down: ["", "ArrowDown", 40], Left: ["", "ArrowLeft", 37],
	Right: ["", "ArrowRight", 39],
};
// A chord's modifiers: WebDriver's key value, CDP's modifier bit
const MODS = {Alt: ["\uE00A", 1], Ctrl: ["\uE009", 2], Shift: ["\uE008", 8]};
const chordOf = c => {
	const parts = c.split("+");
	const k = parts.pop();
	for (const m of parts)
		if (!MODS[m])
			throw new Error("chord: " + m + " is not Alt, Ctrl or Shift");
	return [parts, k];
};
for (let n = 1; n <= 12; n++)
	KEYS["F" + n] = [String.fromCharCode(0xE031 + n - 1), "F" + n, 111 + n];

function connect(url) {
	const ws = new WebSocket(url);
	let id = 0;
	const pending = {};
	const handlers = [];
	ws.onmessage = m => {
		const d = JSON.parse(m.data);
		if (d.id && pending[d.id]) {
			pending[d.id](d);
			delete pending[d.id];
		} else if (d.method) {
			for (const h of handlers) h(d);
		}
	};
	const send = (method, params = {}, extra = {}) => new Promise((res, rej) => {
		const i = ++id;
		pending[i] = d => d.error ? rej(new Error(method + ": " +
				JSON.stringify(d.error) + " " + (d.message || ""))) : res(d.result);
		ws.send(JSON.stringify(Object.assign({id: i, method, params}, extra)));
	});
	return new Promise((res, rej) => {
		ws.onopen = () => res({ws, send, on: h => handlers.push(h)});
		ws.onerror = e => rej(new Error("cannot connect to " + url));
	});
}

// What each step does, in each protocol
async function firefox() {
	const c = await connect(`ws://127.0.0.1:${args.port}/session`);
	// WEB_DRIVE_INSECURE=1: a certificate of a check's own CA is taken
	// simplified: the browser's override, not the CA put in the profile
	await c.send("session.new", {capabilities: {alwaysMatch:
			{acceptInsecureCerts: !!process.env.WEB_DRIVE_INSECURE}}});
	c.on(d => {
		if (d.method === "log.entryAdded")
			logLine(d.params.text);
	});
	await c.send("session.subscribe", {events: ["log.entryAdded"]});
	const top = async n => (await c.send("browsingContext.getTree",
			{maxDepth: 0})).contexts[n].context;
	let ctx = await top(0);
	// WEB_DRIVE_VIEWPORT=WxH[@dpr]: another screen, a high-DPI one with @2
	const vp = (process.env.WEB_DRIVE_VIEWPORT || "1200x800")
			.match(/^(\d+)x(\d+)(?:@([\d.]+))?$/);
	if (!vp)
		throw new Error("WEB_DRIVE_VIEWPORT is WxH or WxH@dpr");
	await c.send("browsingContext.setViewport", {context: ctx,
			viewport: {width: +vp[1], height: +vp[2]},
			...(vp[3] ? {devicePixelRatio: +vp[3]} : {})});
	const keys = list => c.send("input.performActions", {context: ctx,
			actions: [{type: "key", id: "k", actions: list}]});
	const press = v => [{type: "keyDown", value: v}, {type: "keyUp", value: v}];
	const ops = {
		nav: u => c.send("browsingContext.navigate", {context: ctx, url: u,
				wait: "complete"}),
		type: t => keys([...t].flatMap(press)),
		key: k => keys(press(KEYS[k] ? KEYS[k][0] : k)),
		holdkey: (k, ms) => {
			const v = KEYS[k] ? KEYS[k][0] : k;
			return keys([{type: "keyDown", value: v},
					{type: "pause", duration: ms}, {type: "keyUp", value: v}]);
		},
		chord: ch => {
			const [mods, k] = chordOf(ch);
			const v = mods.map(m => MODS[m][0]);
			return keys([...v.map(x => ({type: "keyDown", value: x})),
					...press(KEYS[k] ? KEYS[k][0] : k),
					...v.reverse().map(x => ({type: "keyUp", value: x}))]);
		},
		selall: () => keys([{type: "keyDown", value: ""},
				...press("a"), {type: "keyUp", value: ""}]),
		click: (x, y, ms = 50, button = 0) => c.send("input.performActions",
				{context: ctx, actions: [{type: "pointer", id: "m", actions: [
				{type: "pointerMove", x, y}, {type: "pointerDown", button},
				{type: "pause", duration: ms}, {type: "pointerUp", button}]}]}),
		mouse: (x, y) => c.send("input.performActions", {context: ctx,
				actions: [{type: "pointer", id: "m", actions: [
				{type: "pointerMove", x, y}]}]}),
		wheel: (x, y, dy) => c.send("input.performActions", {context: ctx,
				actions: [{type: "wheel", id: "w", actions: [
				{type: "scroll", x, y, deltaX: 0, deltaY: dy}]}]}),
		tap: (x, y) => c.send("input.performActions", {context: ctx,
				actions: [{type: "pointer", id: "t", parameters:
				{pointerType: "touch"}, actions: [
				{type: "pointerMove", x, y}, {type: "pointerDown", button: 0},
				{type: "pause", duration: 50}, {type: "pointerUp", button: 0}]}]}),
		hold: (x, y, ms) => c.send("input.performActions", {context: ctx,
				actions: [{type: "pointer", id: "t", parameters:
				{pointerType: "touch"}, actions: [
				{type: "pointerMove", x, y}, {type: "pointerDown", button: 0},
				{type: "pause", duration: ms}, {type: "pointerUp", button: 0}]}]}),
		drag: (x0, y0, x1, y1, kind) => c.send("input.performActions", {
				context: ctx, actions: [{type: "pointer", id: kind === "touch" ?
				"t" : "m", parameters: {pointerType: kind === "touch" ?
				"touch" : "mouse"}, actions: [
				{type: "pointerMove", x: x0, y: y0},
				{type: "pointerDown", button: 0},
				...[1, 2, 3, 4, 5, 6, 7, 8, 9, 10].map(i => ({type: "pointerMove",
					duration: 50, x: Math.round(x0 + (x1 - x0) * i / 10),
					y: Math.round(y0 + (y1 - y0) * i / 10)})),
				{type: "pointerUp", button: 0}]}]}),
		shot: async p => {
			const r = await c.send("browsingContext.captureScreenshot", {context: ctx});
			fs.writeFileSync(p, Buffer.from(r.data, "base64"));
		},
		window: async n => { ctx = await top(n); },
		eval: async js => {
			const r = await c.send("script.evaluate", {expression: js,
					target: {context: ctx}, awaitPromise: true});
			console.log("eval:", JSON.stringify(r.result && r.result.value));
		},
	};
	return {ops, end: async () => {
		await c.send("session.end", {});
		c.ws.close();
	}};
}

async function chrome() {
	const list = await (await fetch(`http://127.0.0.1:${args.port}/json/list`)).json();
	const page = list.find(t => t.type === "page");
	const c = await connect(page.webSocketDebuggerUrl);
	c.on(d => {
		if (d.method === "Runtime.consoleAPICalled")
			logLine(d.params.args.map(a => a.value !== undefined ? a.value :
					a.description).join(" "));
		else if (d.method === "Log.entryAdded")
			logLine("[" + d.params.entry.source + "] " + d.params.entry.text);
	});
	await c.send("Runtime.enable");
	await c.send("Log.enable");
	await c.send("Page.enable");
	// WEB_DRIVE_VIEWPORT as for Firefox, the screen that size too; TOUCH=1
	// a phone's: touch events and (pointer: coarse)
	const vp = (process.env.WEB_DRIVE_VIEWPORT || "1200x800")
			.match(/^(\d+)x(\d+)(?:@([\d.]+))?$/);
	if (!vp)
		throw new Error("WEB_DRIVE_VIEWPORT is WxH or WxH@dpr");
	const touch = process.env.TOUCH === "1";
	const metrics = (w, h) => c.send("Emulation.setDeviceMetricsOverride", {
			width: w, height: h, deviceScaleFactor: +(vp[3] || 1),
			mobile: touch, screenWidth: +vp[1], screenHeight: +vp[2]});
	await metrics(+vp[1], +vp[2]);
	// The picker answered here with the "file" step's path, or with nothing
	let file = null;
	await c.send("Page.setInterceptFileChooserDialog", {enabled: true});
	c.on(d => {
		if (d.method !== "Page.fileChooserOpened")
			return;
		logLine("[web_drive] the file picker opened; " + (file || "nothing"));
		if (file)
			c.send("DOM.setFileInputFiles", {files: [file],
					backendNodeId: d.params.backendNodeId});
		file = null;
	});
	if (touch)
		await c.send("Emulation.setTouchEmulationEnabled", {enabled: true,
				maxTouchPoints: 5});
	// A chord's modifiers as keys of their own: SDL keeps Ctrl's state from
	// its key's events, not from the flag on the key pressed with it
	const MODKEYS = {Alt: ["Alt", "AltLeft", 18], Ctrl: ["Control", "ControlLeft", 17],
		Shift: ["Shift", "ShiftLeft", 16]};
	const key = async (k, mods = [], ms = 0) => {
		// A digit's code is Digit2, not Key2, which SDL maps to nothing; a
		// punctuation mark has neither (its char code as a key is another
		// key: "." is 46, Delete), only its char
		const [, code, vk] = KEYS[k] || (/[0-9a-z]/i.test(k) ? [k,
				(/[0-9]/.test(k) ? "Digit" : "Key") + k.toUpperCase(),
				k.toUpperCase().charCodeAt(0)] : [k, "", 0]);
		const name = KEYS[k] ? (k === "Space" ? " " : code) : k;
		const bits = mods.reduce((a, m) => a | MODS[m][1], 0);
		const base = {key: name, code, windowsVirtualKeyCode: vk, modifiers: bits};
		for (const m of mods)
			await c.send("Input.dispatchKeyEvent", {type: "rawKeyDown", key: MODKEYS[m][0],
					code: MODKEYS[m][1], windowsVirtualKeyCode: MODKEYS[m][2], modifiers: bits});
		await c.send("Input.dispatchKeyEvent", Object.assign({type: "rawKeyDown"}, base));
		if (!KEYS[k] && mods.length === 0)
			await c.send("Input.dispatchKeyEvent", {type: "char", text: k});
		if (ms)
			await new Promise(r => setTimeout(r, ms));
		await c.send("Input.dispatchKeyEvent", Object.assign({type: "keyUp"}, base));
		for (const m of mods.slice().reverse())
			await c.send("Input.dispatchKeyEvent", {type: "keyUp", key: MODKEYS[m][0],
					code: MODKEYS[m][1], windowsVirtualKeyCode: MODKEYS[m][2], modifiers: 0});
	};
	let loaded = null;
	c.on(d => {
		if (d.method === "Page.loadEventFired" && loaded)
			loaded();
	});
	const ops = {
		nav: async u => {
			const done = new Promise(r => loaded = r);
			await c.send("Page.navigate", {url: u});
			await done;
		},
		type: async t => {
			for (const ch of t)
				await key(ch);
		},
		key: k => key(k),
		holdkey: (k, ms) => key(k, [], ms),
		selall: () => key("a", ["Ctrl"]),
		chord: ch => {
			const [mods, k] = chordOf(ch);
			return key(k, mods);
		},
		click: async (x, y, ms = 0, b = 0) => {
			const button = ["left", "middle", "right"][b];
			for (const type of ["mouseMoved", "mousePressed", "mouseReleased"]) {
				if (type === "mouseReleased" && ms)
					await new Promise(r => setTimeout(r, ms));
				await c.send("Input.dispatchMouseEvent", {type, x, y,
						button, clickCount: 1});
			}
		},
		mouse: (x, y) => c.send("Input.dispatchMouseEvent", {type: "mouseMoved",
				x, y}),
		wheel: (x, y, dy) => c.send("Input.dispatchMouseEvent", {
				type: "mouseWheel", x, y, deltaX: 0, deltaY: dy}),
		tap: (x, y, n = 1) => Promise.all(Array.from({length: n}, () => [
			c.send("Input.dispatchTouchEvent", {type: "touchStart",
					touchPoints: [{x, y}]}),
			c.send("Input.dispatchTouchEvent", {type: "touchEnd",
					touchPoints: []})]).flat()),
		file: p => {
			if (!fs.existsSync(p))
				throw new Error("no file " + p);
			file = p;
		},
		hold: async (x, y, ms) => {
			await c.send("Input.dispatchTouchEvent", {type: "touchStart",
					touchPoints: [{x, y}]});
			await new Promise(r => setTimeout(r, ms));
			await c.send("Input.dispatchTouchEvent", {type: "touchEnd",
					touchPoints: []});
		},
		carry: async (ax0, ay0, ax1, ay1, bx, by, ax2, ay2) => {
			const move = async (x0, y0, x1, y1, extra) => {
				for (let i = 1; i <= 5; i++) {
					await new Promise(r => setTimeout(r, 50));
					await c.send("Input.dispatchTouchEvent", {type: "touchMove",
							touchPoints: [{x: x0 + (x1 - x0) * i / 5,
								y: y0 + (y1 - y0) * i / 5, id: 1}, ...extra]});
				}
			};
			const a1 = {x: ax1, y: ay1, id: 1};
			await c.send("Input.dispatchTouchEvent", {type: "touchStart",
					touchPoints: [{x: ax0, y: ay0, id: 1}]});
			await move(ax0, ay0, ax1, ay1, []);
			await new Promise(r => setTimeout(r, 300));
			await c.send("Input.dispatchTouchEvent", {type: "touchStart",
					touchPoints: [a1, {x: bx, y: by, id: 2}]});
			await new Promise(r => setTimeout(r, 100));
			// touchEnd's points are the ones that lift
			await c.send("Input.dispatchTouchEvent", {type: "touchEnd",
					touchPoints: [{x: bx, y: by, id: 2}]});
			await new Promise(r => setTimeout(r, 500));
			await move(ax1, ay1, ax2, ay2, []);
			await new Promise(r => setTimeout(r, 300));
			await c.send("Input.dispatchTouchEvent", {type: "touchEnd",
					touchPoints: []});
		},
		// One finger; a mouse drag is not here yet
		drag: (x0, y0, x1, y1) => ops.fingers(x0, y0, null, null, x1, y1),
		fingers: async (ax0, ay0, bx0, by0, ax1, ay1, bx1, by1) => {
			const a = f => ({x: ax0 + (ax1 - ax0) * f, y: ay0 + (ay1 - ay0) * f,
					id: 1});
			const at = f => bx0 === null ? [a(f)] : [a(f), {x: bx0 +
					(bx1 - bx0) * f, y: by0 + (by1 - by0) * f, id: 2}];
			await c.send("Input.dispatchTouchEvent", {type: "touchStart",
					touchPoints: at(0)});
			for (let i = 1; i <= 10; i++) {
				await new Promise(r => setTimeout(r, 50));
				await c.send("Input.dispatchTouchEvent", {type: "touchMove",
						touchPoints: at(i / 10)});
			}
			await c.send("Input.dispatchTouchEvent", {type: "touchEnd",
					touchPoints: []});
		},
		viewport: (w, h) => metrics(w, h),
		cpu: rate => c.send("Emulation.setCPUThrottlingRate", {rate}),
		// The screen and #status, or the loading stripe's line while it is
		// up ([JOIN_STRIPES]), for watch
		look: async () => {
			const r = await c.send("Page.captureScreenshot", {format: "png"});
			const st = await c.send("Runtime.evaluate", {expression:
					"(function(){ var l = document.getElementById('load');" +
					" if(l && l.style.display !== 'none') return" +
					" document.getElementById('load1').textContent;" +
					" return (document.getElementById('status') || {})" +
					".textContent || ''; })()",
					returnByValue: true});
			return {png: r.data, status: st.result.value};
		},
		shot: async p => {
			const r = await c.send("Page.captureScreenshot", {format: "png"});
			fs.writeFileSync(p, Buffer.from(r.data, "base64"));
		},
		eval: async js => {
			const r = await c.send("Runtime.evaluate", {expression: js,
					awaitPromise: true, returnByValue: true});
			console.log("eval:", JSON.stringify(r.result && r.result.value));
		},
	};
	return {ops, end: async () => c.ws.close()};
}

(async () => {
	const b = args.browser === "firefox" ? await firefox() :
			args.browser === "chrome" ? await chrome() : null;
	if (!b) {
		console.error("web_drive.js: --browser is firefox or chrome");
		process.exit(2);
	}
	let failed = null;
	const out = args.vars.OUT;
	for (const [op, ...args] of steps) {
		const [a, c] = args;
		console.log("step:", op, a !== undefined ? a : "", c !== undefined ? c : "");
		try {
			if (op === "wait") {
				await new Promise(r => setTimeout(r, a));
			} else if (op === "waitlog") {
				const re = new RegExp(a);
				const until = Date.now() + (c || 60) * 1000;
				for (;;) {
					const i = lines.findIndex((l, k) => k >= cursor && re.test(l));
					if (i >= 0) {
						cursor = i + 1;
						break;
					}
					if (Date.now() > until)
						throw new Error("no console line matched /" + a + "/");
					await new Promise(r => setTimeout(r, 200));
				}
			} else if (op === "watch") {
				const re = new RegExp(a);
				const until = Date.now() + (c || 60) * 1000, still = args[2];
				const t0 = Date.now(), at = () => ((Date.now() - t0) / 1000).toFixed(1);
				let last = null, since = Date.now(), status = null, over = 0;
				cursor = lines.length;
				const stretch = () => {
					const ms = Date.now() - since;
					if (ms > still) {
						over++;
						console.log(`watch: still ${(ms / 1000).toFixed(1)} s to ${at()} s` +
								` (status "${status}")`);
					}
				};
				for (;;) {
					const l = await b.ops.look();
					if (l.status !== status)
						console.log(`watch: ${at()} s "${l.status}"`);
					if (last === null || l.png !== last || l.status !== status) {
						stretch();
						since = Date.now();
					}
					last = l.png;
					status = l.status;
					const i = lines.findIndex((l, k) => k >= cursor && re.test(l));
					if (i >= 0) {
						cursor = i + 1;
						stretch();
						break;
					}
					if (Date.now() > until)
						throw new Error("no console line matched /" + a + "/");
					await new Promise(r => setTimeout(r, 500));
				}
				if (over)
					throw new Error(`${over} stretches over ${still} ms with nothing changed`);
			} else if (op === "nav") {
				await b.ops.nav(full_rate(args[0]));
			} else if (b.ops[op]) {
				await b.ops[op](...args);
			} else {
				throw new Error("no such step");
			}
		} catch (e) {
			failed = op + ": " + e.message;
			// What the page showed when it failed: a tap at a stale
			// position reads as "no line matched" otherwise
			if (out)
				await b.ops.shot(out + "/failed.png").catch(() => {});
			break;
		}
	}
	await b.end().catch(() => {});
	if (failed) {
		console.error("web_drive.js: " + failed);
		process.exit(1);
	}
	process.exit(0);
})().catch(e => {
	console.error("web_drive.js: " + e.message);
	process.exit(1);
});
