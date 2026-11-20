-- Buildat: extensions/jam/music_edit.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [JAM_EDITOR] **The music editor**: a kit/music song (jam1, doc/client_api.txt)
-- in views over its text, opened by Kit's inspector's "Edit..." under the song
-- field (builtin/kit/client_lua/editor.lua's song_section) and by the jam app
-- ([JAM_APP], app.lua): one copy, run by jam.editor(A) for each. **The text is the song**: every edit of a
-- view rewrites the lines it changes (the others as they were, comments and
-- spacing too) and the views are drawn again from the text, so a text typed
-- (the Text view, or the inspector's field) shows in them at once and an agent's
-- text over MCP reads as a builder's. The edits go into the inspector's pending
-- values: Apply (here or the inspector's) sends them; Undo steps back through
-- this editor's own edits. Each plays through jam, as the players hear it.
--   - **The transport** (top): Play/Stop (the song, or the loop picked: a
--     section or the pattern shown, looping), tempo and swing (- and +, the
--     tempo and swing lines), the place (bar, time), the moods (heard from
--     the next bar), Analyze (jam's measures and the render's hash, the
--     agents' analyze_music); a text changed while playing plays on from the
--     same place.
--   - **Song**: the play order, each section's entries (patterns layered, a
--     repeat), the loop's marked; the playing entry lit. A section: Play from
--     here, Loop it (the preview), Loop here (the song's loop line); an entry:
--     its patterns (a click opens one), its repeat - and +, removed; Add a
--     pattern to the section.
--   - **Pattern** (the step grid, two bars a page as fit): its lanes by steps.
--     A click on an empty step places a hit (drums: x) or a note (the lane's
--     note before it) and selects it, plays it; a click on the selected one
--     takes it out. The selected step's row below: drums their hit (X x g o O
--     f); notes the pitch (-12 -1 +1 +12), velocity (? 0.5, - +, ! 1), length
--     (- +: its holds), slide, palm mute, staccato and the token typed; a
--     param lane's value. A lane copied ("= gtl") is drawn dim, its own once
--     edited; a lane shorter than the pattern drawn repeating, written out
--     once edited. + lane (a track not in it), + param (an instrument
--     parameter's lane for the selected lane's track), the lane taken out.
--   - **Roll** (a melodic lane): pitches by steps, the key guessed from the
--     song's notes (its scale's rows lit). A click on nothing places a note,
--     a drag from nothing draws one as long as the drag (the mouse); a note
--     dragged moves, its right end dragged resizes; a click on a note selects
--     it, on the selected one takes it out. The rows below: move (< > Up
--     Dn), the grid's note buttons; Up and Down (top) move the pitch window.
--   - **Instrument**: the instruments, one's source and its parameters (the
--     ones its source uses, as blip's designer's sliders, - and +, x back to
--     jam's default), a note auditioned on each change through the track's
--     inserts and the buses; the notes it plays to audition.
--   - **Mixer**: a column a track (and the buses'): gain, pan, the inserts
--     (amp, eq, comp, sends, tremolo), then a row a mood with its gains. A
--     cell picked: its parameters below (sliders), a mood's off, dB - and +.
--   - **Text**: the text itself, read as it is typed.
-- Keys: Escape closes, Ctrl+Z undoes, Space plays or stops, Delete takes the
-- selected step or note out, the arrows move it (Up and Down: a semitone).
-- Logs "kit editor: music ..." (A.log_prefix the "kit editor: music " part).
-- **Touch**: every action is a click (a tap) on a target at least SH.TOUCH
-- across in the touch mode, nothing on hover; what is not touch-ready: the
-- roll's drags (the buttons below do the same), the sliders' fine steps
-- (the - and + do), and the Text view's typing (the screen keyboard covers
-- the half of it).
-- simplified: one editor open at a time; the song changed by someone else
-- while it is open is not merged (Apply sends this one's); no redo; no meters,
-- mute or solo; a section's entries are not dragged (removed and added); the
-- piano roll shows one lane at a time; the step grid is not scrolled (a
-- pattern of more lanes than the window's height is cut); Analyze renders
-- on the main thread (3.5 s for Scrap Heat's 65 s, the client stalls)
local J = {}

-- ---- The text model: lines, and what the views read of them

local NOTE = {C = 0, D = 2, E = 4, F = 5, G = 7, A = 9, B = 11}
local NAMES = {"C", "C#", "D", "Eb", "E", "F", "F#", "G", "G#", "A", "Bb", "B"}
J.DRUMS = {kick = true, snare = true, hat = true, cymbal = true}

function J.name(midi)
	return NAMES[midi % 12 + 1] .. (math.floor(midi / 12) - 1)
end

-- A number as the text writes it: no exponent, three figures
function J.fmt(v)
	if v == math.floor(v) and math.abs(v) < 1e9 then
		return string.format("%d", v)
	end
	if math.abs(v) >= 1000 then
		return string.format("%d", math.floor(v + 0.5))
	end
	local s = string.format("%.3g", v)
	if s:find("e") then
		s = string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", "")
	end
	return s
end

local function split_lines(text)
	local lines, i = {}, 1
	while true do
		local j = text:find("\n", i, true)
		if not j then
			lines[#lines + 1] = text:sub(i)
			return lines
		end
		lines[#lines + 1] = text:sub(i, j - 1)
		i = j + 1
	end
end

-- A line without its comment ("#" at its start or after a space; C#3 a note)
local function code_of(s)
	local i = 1
	while true do
		local h = s:find("#", i, true)
		if not h then
			return s
		end
		if h == 1 or s:sub(h - 1, h - 1):match("%s") then
			return s:sub(1, h - 1)
		end
		i = h + 1
	end
end

-- {{word, from, to}...}, from `from` on
local function words(s, from)
	local out, d = {}, (from or 1) - 1
	for a, w, b in s:sub(d + 1):gmatch("()(%S+)()") do
		out[#out + 1] = {w, a + d, b - 1 + d}
	end
	return out
end

local function kv(w, from)
	local t = {}
	for i = from, #w do
		local k, v = w[i][1]:match("^([^=]+)=(.+)$")
		if k then
			t[k] = v
		end
	end
	return t
end

-- Into list and by name (a name again replaces it in place, as jam does)
local function add(list, by, item)
	local old = by[item.name]
	if old then
		for i, x in ipairs(list) do
			if x == old then
				list[i] = item
			end
		end
	else
		list[#list + 1] = item
	end
	by[item.name] = item
end

-- The song's text read: m.lines, and what each view draws with each thing's
-- line (ln) to rewrite. Nothing here judges the text (jam does that): a
-- line it cannot place is left out
function J.read(text)
	local m = {text = text, lines = split_lines(text), steps = 16, beat = 4,
		tempo = 120, swing = 0, title = "", head = {}, insts = {}, inst = {},
		tracks = {}, track = {}, patterns = {}, pattern = {}, sections = {},
		section = {}, play = {}, play_lns = {}, moods = {}, mood = {}, defs = {}}
	local cur = nil
	for ln, raw in ipairs(m.lines) do
		local s = code_of(raw)
		local w = words(s)
		local w1 = w[1] and w[1][1]
		if not w1 then
		elseif w1 == "jam" then
			-- [KIT_API_1] the format's line: what is added goes after it
			m.head.jam = ln
		elseif w1 == "title" then
			m.title = s:match("^%s*title%s+(.-)%s*$") or ""
			m.head.title = ln
		elseif w1 == "tempo" or w1 == "steps" or w1 == "beat" or w1 == "swing" then
			m[w1] = tonumber(w[2] and w[2][1]) or m[w1]
			m.head[w1] = ln
		elseif w1 == "reverb" or w1 == "delay" or w1 == "master" then
			m.head[w1] = ln
		elseif w1 == "inst" and w[3] then
			local base = m.inst[w[3][1]]
			local own = kv(w, 4)
			add(m.insts, m.inst, {name = w[2][1], ln = ln, base = base and base.name,
				src = own.src or (base and base.src) or w[3][1]})
		elseif w1 == "track" and w[2] then
			local own = kv(w, 3)
			add(m.tracks, m.track, {name = w[2][1], ln = ln, inst = own.inst})
		elseif w1 == "def" and w[3] then
			m.defs[w[2][1]] = w[3][1]
		elseif w1 == "pattern" and w[2] then
			local bars = tonumber(kv(w, 3).bars) or 1
			cur = {name = w[2][1], ln = ln, last = ln, bars = bars,
				len = bars * m.steps, lanes = {}, lane = {}}
			add(m.patterns, m.pattern, cur)
		elseif w1 == "section" then
			local colon = s:find(":", 1, true)
			local name = colon and s:sub(1, colon - 1):match("^%s*section%s+(%S+)%s*$")
			if name then
				local sec = {name = name, ln = ln, colon = colon, entries = {}}
				for _, e in ipairs(words(s, colon + 1)) do
					local body, rep = e[1]:match("^(.-)%*(%d+)$")
					local en = {raw = e[1], layer = {}, rep = tonumber(rep) or 1}
					for p in (body or e[1]):gmatch("[^+]+") do
						en.layer[#en.layer + 1] = p
					end
					sec.entries[#sec.entries + 1] = en
				end
				add(m.sections, m.section, sec)
			end
			cur = nil
		elseif w1 == "play" then
			for i = 2, #w do
				m.play[#m.play + 1] = w[i][1]
			end
			m.play_lns[#m.play_lns + 1] = ln
		elseif w1 == "loop" then
			m.loop, m.loop_ln = w[2] and w[2][1], ln
		elseif w1 == "mood" and w[2] then
			add(m.moods, m.mood, {name = w[2][1], ln = ln, gains = kv(w, 3)})
		elseif w1:sub(-1) == ":" and #w1 > 1 and cur then
			J.read_lane(m, cur, ln, s, w1:sub(1, -2))
		end
	end
	m.loop = m.loop or m.play[1]
	return m
end

-- A track's instrument's source ("" when it has none)
function J.src_of(m, track)
	local t = m.track[track]
	local i = t and t.inst and m.inst[t.inst]
	return i and i.src or ""
end

function J.read_lane(m, p, ln, s, key)
	local tr, param = key:match("^([^~]*)~(.+)$")
	tr = tr or key
	local lane = p.lane[key]
	if not lane then
		lane = {key = key, track = tr, param = param, lines = {}, toks = {},
			drum = not param and J.DRUMS[J.src_of(m, tr)] or false}
		p.lanes[#p.lanes + 1] = lane
		p.lane[key] = lane
	end
	lane.lines[#lane.lines + 1] = ln
	p.last = ln
	local at = s:find(":", 1, true) + 1
	local rest = s:sub(at)
	local rw = words(rest)
	local copy = (#rw == 2 and rw[1][1] == "=" and rw[2][1]) or (#rw == 1 and
			#rw[1][1] > 1 and rw[1][1]:sub(1, 1) == "=" and rw[1][1]:sub(2)) or nil
	local toks = lane.toks
	if copy then
		local from = p.lane[copy]
		lane.copies = lane.copies or {}
		lane.copies[#lane.copies + 1] = {ln = ln, from = copy}
		for _, t in ipairs(from and from.toks or {}) do
			toks[#toks + 1] = {s = t.s, copy = copy}
		end
	elseif lane.drum then
		for i = 1, #rest do
			local c = rest:sub(i, i)
			if not c:match("[%s|]") then
				toks[#toks + 1] = {s = c, ln = ln, a = at + i - 1, b = at + i - 1}
			end
		end
	else
		for a, t, b in rest:gmatch("()([^%s|]+)()") do
			toks[#toks + 1] = {s = t, ln = ln, a = at + a - 1, b = at + b - 2}
		end
	end
end

-- A lane's steps as jam plays them: 1..len, each {s, copy, rep (a repeat of
-- a shorter lane), the token's place}
function J.steps(p, lane)
	local out, n = {}, #lane.toks
	for i = 1, p.len do
		local t = n > 0 and lane.toks[(i - 1) % n + 1] or {s = "."}
		out[i] = i > n and {s = t.s, copy = t.copy, rep = true} or t
	end
	return out
end

-- A melodic token's notes (MIDI), modifiers and velocity; nil for a rest or
-- a hold. A def's name stays as `def` (the token says it until its notes
-- change)
function J.note(m, tok)
	if tok == "." or tok == "-" then
		return nil
	end
	local tk, def = tok, nil
	for k = #tk, 1, -1 do
		local d = m.defs[tk:sub(1, k)]
		if d then
			tk, def = d .. tk:sub(k + 1), tok:sub(1, k)
			break
		end
	end
	local notes, pos = {}, 1
	while true do
		local l, acc, neg, oct, p = tk:match("^([A-G])([#b]?)(%-?)(%d)()", pos)
		if not l then
			break
		end
		notes[#notes + 1] = 12 * ((neg == "-" and -1 or 1) * tonumber(oct) + 1) +
				NOTE[l] + (acc == "#" and 1 or acc == "b" and -1 or 0)
		pos = p
		if tk:sub(pos, pos) == "+" then
			pos = pos + 1
		end
	end
	if #notes == 0 then
		return nil
	end
	local mods = tk:sub(pos)
	local vel = 0.8
	if mods:find("!", 1, true) then vel = 1 end
	if mods:find("?", 1, true) then vel = 0.5 end
	local v = tonumber(mods:match("@([%d.]+)") or "")
	return {notes = notes, mods = mods, vel = v or vel, def = def,
		slide = mods:find("~", 1, true) ~= nil, mute = mods:find("m", 1, true) ~= nil,
		stacc = mods:find("'", 1, true) ~= nil}
end

-- A note back into a token: its def's name while its notes are the def's
function J.token(n, notes)
	if n.def and not notes then
		return n.def .. n.mods
	end
	local t = {}
	for i, x in ipairs(notes or n.notes) do
		t[i] = J.name(x)
	end
	return table.concat(t, "+") .. n.mods
end

function J.with_vel(mods, v)
	mods = mods:gsub("[!?]", ""):gsub("@[%d.]*", "")
	if math.abs(v - 0.8) < 1e-6 then
		return mods
	elseif v >= 1 then
		return mods .. "!"
	elseif math.abs(v - 0.5) < 1e-6 then
		return mods .. "?"
	end
	return mods .. "@" .. J.fmt(v)
end

function J.toggle_mod(mods, c)
	local i = mods:find(c, 1, true)
	if i then
		return mods:sub(1, i - 1) .. mods:sub(i + 1)
	end
	return mods .. c
end

-- ---- Rewriting lines

-- The text again with lines set ({[ln] = line, or false: gone}) and lines
-- put after others ({[ln] = {line...}}; 0 before the first)
local function rewrite(m, set, ins)
	local out = {}
	for _, x in ipairs(ins and ins[0] or {}) do
		out[#out + 1] = x
	end
	for ln, s in ipairs(m.lines) do
		local v = set and set[ln]
		if v == nil then
			out[#out + 1] = s
		elseif v then
			out[#out + 1] = v
		end
		for _, x in ipairs(ins and ins[ln] or {}) do
			out[#out + 1] = x
		end
	end
	return table.concat(out, "\n")
end
J.rewrite = rewrite

-- line's from..to as new, the columns after it kept where the spaces allow
-- (a token shorter padded, one longer eating the spaces after it but one;
-- plain: neither, for a key=value)
local function replace(line, a, b, new, plain)
	local old_n, new_n = b - a + 1, #new
	local after = line:sub(b + 1)
	if plain then
	elseif new_n < old_n and after:match("^ ") then
		after = string.rep(" ", old_n - new_n) .. after
	elseif new_n > old_n then
		local eat = math.min(#(after:match("^ +") or "") - 1, new_n - old_n)
		if eat > 0 then
			after = after:sub(eat + 1)
		end
	end
	return line:sub(1, a - 1) .. new .. after
end

-- A key=value word of line (words from `from` on) set, added before the
-- comment, or (value nil) taken out
function J.kv_line(line, from, key, value)
	local w = words(code_of(line))
	for i = from, #w do
		if w[i][1]:match("^([^=]+)=") == key then
			if value == nil then
				local a = w[i][2]
				while a > 1 and line:sub(a - 1, a - 1):match("%s") do
					a = a - 1
				end
				return line:sub(1, a - 1) .. line:sub(w[i][3] + 1)
			end
			return replace(line, w[i][2], w[i][3], key .. "=" .. value, true)
		end
	end
	if value == nil then
		return line
	end
	local code = code_of(line)
	local body = code:gsub("%s+$", "")
	return body .. " " .. key .. "=" .. value .. line:sub(#body + 1)
end

-- word i of line as new
function J.word_line(line, i, new)
	local w = words(code_of(line))
	if not w[i] then
		local code = code_of(line)
		local body = code:gsub("%s+$", "")
		return body .. " " .. new .. line:sub(#body + 1)
	end
	return replace(line, w[i][2], w[i][3], new, true)
end

-- A setting line's (tempo, swing) number, the line added after the title's
-- (or first) when there is none
function J.set_head(m, key, value)
	local ln = m.head[key]
	if ln then
		return rewrite(m, {[ln] = J.word_line(m.lines[ln], 2, value)})
	end
	return rewrite(m, nil, {[m.head.title or m.head.jam or 0] = {key .. " " .. value}})
end

-- A bus's (reverb, delay, master) key, its line added after the settings'
function J.set_bus(m, bus, key, value)
	local ln = m.head[bus]
	if ln then
		return rewrite(m, {[ln] = J.kv_line(m.lines[ln], 2, key, value)})
	end
	if value == nil then
		return m.text
	end
	local after = m.head.swing or m.head.beat or m.head.steps or m.head.tempo or
			m.head.title or m.head.jam or 0
	return rewrite(m, nil, {[after] = {bus .. " " .. key .. "=" .. value}})
end

function J.set_inst(m, name, key, value)
	local i = m.inst[name]
	local line = m.lines[i.ln]
	if key == "src" and not i.base and not kv(words(code_of(line)), 4).src then
		return rewrite(m, {[i.ln] = J.word_line(line, 3, value)})
	end
	return rewrite(m, {[i.ln] = J.kv_line(line, 4, key, value)})
end

function J.set_track(m, name, key, value)
	local t = m.track[name]
	return rewrite(m, {[t.ln] = J.kv_line(m.lines[t.ln], 3, key, value)})
end

-- A mood's gain for a track: "off", dB, or nil (0 dB, taken out)
function J.set_mood(m, name, track, value)
	local md = m.mood[name]
	return rewrite(m, {[md.ln] = J.kv_line(m.lines[md.ln], 3, track, value)})
end

-- An instrument's values: its base's, then its own line's
function J.inst_values(m, name, seen)
	local i = m.inst[name]
	if not i then
		return {}
	end
	seen = seen or {}
	if seen[name] then
		return {}
	end
	seen[name] = true
	local t = i.base and J.inst_values(m, i.base, seen) or {}
	for k, v in pairs(kv(words(code_of(m.lines[i.ln])), 4)) do
		t[k] = v
	end
	t.src = i.src
	return t
end

function J.own_values(m, ln, from)
	return kv(words(code_of(m.lines[ln])), from)
end

-- ---- Lanes

-- line renamed from lane `from` to lane `to` ("gtl:  E2" -> "gtr:  E2")
local function renamed(line, from, to)
	local lead, rest = line:match("^(%s*)" .. from:gsub("%p", "%%%0") .. ":(.*)$")
	if not lead then
		return line
	end
	local d = #to - #from
	if d < 0 and rest:match("^ ") then
		rest = string.rep(" ", -d) .. rest
	elseif d > 0 then
		local eat = math.min(#(rest:match("^ +") or "") - 1, d)
		if eat > 0 then
			rest = rest:sub(eat + 1)
		end
	end
	return lead .. to .. ":" .. rest
end

-- The lane its own and as long as its pattern: a copy ("= gtl") written as
-- the lines it copies, a shorter lane's lines written again until it is
-- (nil: it is already)
local function own_lane(m, p, lane)
	if lane.copies then
		local set, ins = {}, {}
		for _, c in ipairs(lane.copies) do
			local out = {}
			for _, sl in ipairs(p.lane[c.from] and p.lane[c.from].lines or {}) do
				if sl < c.ln then
					out[#out + 1] = renamed(code_of(m.lines[sl]):gsub("%s+$", ""),
							c.from, lane.key)
				end
			end
			set[c.ln] = out[1] or false
			ins[c.ln] = {}
			for i = 2, #out do
				ins[c.ln][i - 1] = out[i]
			end
		end
		return rewrite(m, set, ins)
	end
	local n = #lane.toks
	if n > 0 and n < p.len then
		local more = {}
		for _ = 2, p.len / n do
			for _, sl in ipairs(lane.lines) do
				more[#more + 1] = m.lines[sl]
			end
		end
		return rewrite(m, nil, {[lane.lines[#lane.lines]] = more})
	end
end

-- The tokens of steps changed in a lane ({[step] = token}); the lane made its
-- own first. Returns the text
function J.set_steps(m, pname, key, toks)
	local p = m.pattern[pname]
	local lane = p and p.lane[key]
	if not lane then
		return m.text
	end
	local own = own_lane(m, p, lane)
	if own then
		return J.set_steps(J.read(own), pname, key, toks)
	end
	local per = {}
	for step, tok in pairs(toks) do
		local t = lane.toks[step]
		if t and t.ln and t.s ~= tok then
			per[t.ln] = per[t.ln] or {}
			table.insert(per[t.ln], {t.a, t.b, tok})
		end
	end
	local set = {}
	for ln, list in pairs(per) do
		table.sort(list, function(x, y) return x[1] > y[1] end)
		local line = m.lines[ln]
		for _, r in ipairs(list) do
			line = replace(line, r[1], r[2], r[3])
		end
		set[ln] = line
	end
	return rewrite(m, set)
end

-- A copied lane made its own (nil: it is no copy)
function J.unlink(m, pname, key)
	local p = m.pattern[pname]
	local lane = p and p.lane[key]
	return lane and lane.copies and own_lane(m, p, lane) or nil
end

-- A new lane in a pattern (a track's, or key "track~param"): a line a bar of
-- rests, its tokens in the column the pattern's first lane has
function J.add_lane(m, pname, key)
	local p = m.pattern[pname]
	if not p or p.lane[key] then
		return m.text
	end
	local col = 0
	local first = p.lanes[1] and p.lanes[1].lines[1]
	if first then
		local c = code_of(m.lines[first])
		local colon = c:find(":", 1, true)
		col = (c:find("%S", colon + 1) or colon + 2) - 1
	end
	local head = key .. ":"
	head = head .. string.rep(" ", math.max(1, col - #head))
	local rests = {}
	for i = 1, m.steps do
		rests[i] = "."
	end
	local out = {}
	for b = 1, p.bars do
		out[b] = head .. table.concat(rests, " ")
	end
	return rewrite(m, nil, {[p.last] = out})
end

-- A lane taken out (nil and why: another copies it)
function J.remove_lane(m, pname, key)
	local p = m.pattern[pname]
	local lane = p and p.lane[key]
	if not lane then
		return nil, "no lane " .. key
	end
	for _, l in ipairs(p.lanes) do
		for _, c in ipairs(l.copies or {}) do
			if c.from == key then
				return nil, l.key .. " copies it"
			end
		end
	end
	local set = {}
	for _, ln in ipairs(lane.lines) do
		set[ln] = false
	end
	return rewrite(m, set)
end

-- The note that a new step of a lane gets: the one before it, else after it
-- (no modifiers), else C3 (drums x)
function J.new_token(m, p, lane, step)
	if lane.drum then
		return "x"
	end
	if lane.param then
		return "0"
	end
	local st = J.steps(p, lane)
	for d = 1, p.len - 1 do
		for _, i in ipairs({step - d, step + d}) do
			local n = st[i] and J.note(m, st[i].s)
			if n then
				return J.token({notes = n.notes, mods = ""})
			end
		end
	end
	return "C3"
end

-- Steps from `step` that a note there lasts (its holds after it)
function J.length(st, step)
	local j = step + 1
	while st[j] and st[j].s == "-" do
		j = j + 1
	end
	return j - step
end

-- The note at step made `len` steps long: holds after it, a hold past the
-- new end a rest. Returns the step changes
function J.len_toks(p, st, step, len)
	len = math.max(1, math.min(len, p.len - step + 1))
	local t, old = {}, J.length(st, step)
	for i = step + 1, step + len - 1 do
		t[i] = "-"
	end
	for i = step + len, step + old - 1 do
		t[i] = "."
	end
	return t
end

-- A step's token taken out: a note and its holds rests
function J.clear_toks(p, st, step)
	local t = {[step] = "."}
	if st[step].s ~= "-" then
		for i = step + 1, step + J.length(st, step) - 1 do
			t[i] = "."
		end
	end
	return t
end

-- ---- Sections and the play order

local function entry_text(e)
	return e.raw or (table.concat(e.layer, "+") .. (e.rep > 1 and "*" .. e.rep or ""))
end

-- A section's entries written again (the line's head and comment kept)
function J.set_entries(m, name, entries)
	local sec = m.section[name]
	local line = m.lines[sec.ln]
	local code = code_of(line)
	local first = code:find("%S", sec.colon + 1)
	local head = first and code:sub(1, first - 1) or code:sub(1, sec.colon) .. " "
	local parts = {}
	for i, e in ipairs(entries) do
		parts[i] = entry_text(e)
	end
	local tail = code:match("%s*$")
	local comment = line:sub(#code + 1)
	return rewrite(m, {[sec.ln] = head .. table.concat(parts, " ") ..
			(comment ~= "" and (tail ~= "" and tail or " ") .. comment or "")})
end

function J.set_loop(m, name)
	if m.loop_ln then
		return rewrite(m, {[m.loop_ln] = J.word_line(m.lines[m.loop_ln], 2, name)})
	end
	return rewrite(m, nil, {[m.play_lns[#m.play_lns] or #m.lines] = {"loop " .. name}})
end

-- The play order as entries in steps: {section, k (its place in the play
-- order), entry (its index), rep, at, len, layer}
function J.timeline(m, play)
	local out, at = {}, 0
	for ki, sn in ipairs(play or m.play) do
		for ei, e in ipairs(m.section[sn] and m.section[sn].entries or {}) do
			local len = 0
			for _, pn in ipairs(e.layer) do
				len = math.max(len, m.pattern[pn] and m.pattern[pn].len or 0)
			end
			for r = 1, e.rep do
				out[#out + 1] = {section = sn, k = ki, entry = ei, rep = r, at = at,
					len = len, layer = e.layer}
				at = at + len
			end
		end
	end
	return out, at
end

-- The text with its play order replaced (play and loop lines out, the new
-- ones and `extra` lines at its end): a section looped, a pattern, an
-- audition
local function arranged(m, extra, play, loop)
	local set = {}
	for _, ln in ipairs(m.play_lns) do
		set[ln] = false
	end
	if m.loop_ln then
		set[m.loop_ln] = false
	end
	local t = rewrite(m, set)
	return t .. "\n" .. table.concat(extra, "\n") .. "\nplay " .. play ..
			"\nloop " .. loop .. "\n"
end

function J.loop_text(m, section)
	return arranged(m, {}, section, section)
end

function J.pattern_text(m, pname)
	return arranged(m, {"section jam__p: " .. pname}, "jam__p", "jam__p")
end

-- One note (a token) on a track for two bars, then rests: an audition (an
-- instrument on no track: on a track of its own, with no inserts)
function J.audition_text(m, track, tok, drum, inst)
	local toks = {tok}
	for i = 2, 2 * m.steps do
		toks[i] = (not drum and i <= m.beat) and "-" or "."
	end
	local extra = {}
	if not track then
		track = "jam__t"
		extra[1] = "track jam__t inst=" .. inst
	end
	extra[#extra + 1] = "pattern jam__a bars=2"
	extra[#extra + 1] = track .. ": " .. table.concat(toks, " ")
	extra[#extra + 1] = "section jam__a: jam__a"
	return arranged(m, extra, "jam__a", "jam__a")
end

-- The key the song's notes fit best: {root, minor, name, has = {[pc] = true}}
local SCALES = {{false, {0, 2, 4, 5, 7, 9, 11}}, {true, {0, 2, 3, 5, 7, 8, 10}}}
function J.key_of(m)
	local count = {}
	for pc = 0, 11 do
		count[pc] = 0
	end
	for _, p in ipairs(m.patterns) do
		for _, lane in ipairs(p.lanes) do
			if not lane.drum and not lane.param then
				for _, t in ipairs(lane.toks) do
					local n = J.note(m, t.s)
					for _, x in ipairs(n and n.notes or {}) do
						count[x % 12] = count[x % 12] + 1
					end
				end
			end
		end
	end
	local best, best_score = nil, -1
	for root = 0, 11 do
		for _, sc in ipairs(SCALES) do
			local score = count[root] * 0.5
			for _, d in ipairs(sc[2]) do
				score = score + count[(root + d) % 12]
			end
			if score > best_score then
				best_score = score
				best = {root = root, minor = sc[1], steps = sc[2]}
			end
		end
	end
	best.has = {}
	for _, d in ipairs(best.steps) do
		best.has[(best.root + d) % 12] = true
	end
	best.name = NAMES[best.root + 1] .. (best.minor and " minor" or " major")
	return best
end

-- ---- What the instrument and mixer views edit: jam's parameters with their
-- ranges and defaults (src/impl/jam.cpp's INST_KEYS, TRACK_KEYS, the buses';
-- util/kit_music_edit_check.sh checks the ranges against jam)
J.INST = {
	all = {{"gain", -60, 24, 0}, {"vels", 0, 1, 0.7}, {"a", 0, 30, 0.002},
		{"d", 0, 60, 0.3}, {"s", 0, 1, 1}, {"r", 0, 60, 0.08}, {"gate", 0, 4, 0.92},
		{"glide", 0, 10, 0.05}, {"vib", 0, 1200, 0}, {"vibrate", 0, 50, 5.5},
		{"vibdelay", 0, 30, 0.25}, {"tune", -1200, 1200, 0}, {"strum", 0, 1, 0},
		{"spread", -100, 100, 0}, {"drive", 0, 60, 0}},
	filter = {{"cut", 10, 20000, 2000}, {"res", 0, 0.98, 0.2}, {"fenv", -10, 10, 0},
		{"fa", 0, 30, 0.002}, {"fd", 0, 60, 0.3}, {"fs", 0, 1, 0}, {"fr", 0, 60, 0.1},
		{"ktrack", -2, 2, 0.5}, {"velf", -4, 4, 0.5}, {"flfo", -8, 8, 0},
		{"flforate", 0, 20, 0.1}},
	osc = {{"mix2", 0, 1, 0.5}, {"detune2", -1200, 1200, 7}, {"oct2", -4, 4, 0},
		{"pw", 0, 1, 0.5}, {"pwm", 0, 1, 0}, {"pwmrate", 0, 50, 0.5}, {"sub", 0, 2, 0},
		{"noise", 0, 2, 0}},
	pluck = {{"bright", 0, 1, 0.7}, {"decay", 0.01, 60, 3}, {"pick", 0, 0.5, 0.15},
		{"mdecay", 0.01, 60, 0.18}, {"mbright", 0, 1, 0.25}, {"rdecay", 0.001, 60, 0.05}},
	fm = {{"ratio", 0, 32, 1}, {"index", 0, 50, 2}, {"idecay", 0, 60, 0.6},
		{"ifloor", 0, 1, 0.3}, {"tine", 0, 2, 0.3}, {"tratio", 0, 64, 7},
		{"tdecay", 0, 60, 0.08}},
	kick = {{"tone", 1, 20000, 50}, {"pdrop", 1, 20, 3}, {"pdecay", 0, 10, 0.04},
		{"click", 0, 4, 0.4}},
	snare = {{"tone", 1, 20000, 50}, {"pdrop", 1, 20, 3}, {"pdecay", 0, 10, 0.04},
		{"snappy", 0, 1, 0.7}, {"ndecay", 0, 10, 0.15}, {"nfreq", 20, 20000, 3000}},
	hat = {{"tone", 1, 20000, 50}, {"metal", 0, 4, 1}, {"noise", 0, 2, 0},
		{"nfreq", 20, 20000, 3000}, {"odecay", 0, 20, 0.4}, {"bell", 0, 4, 0}},
}
J.INST.tom, J.INST.cymbal = J.INST.snare, J.INST.hat
J.CHOICES = {src = {"osc", "pluck", "fm", "kick", "snare", "tom", "hat", "cymbal"},
	wave = {"saw", "square", "pulse", "tri", "sine", "none"},
	wave2 = {"none", "saw", "square", "pulse", "tri", "sine"},
	ftype = {"none", "lp", "bp", "hp"}, poles = {"2", "4"}}
J.CHOICE_DEFAULT = {wave = "saw", wave2 = "none", ftype = "none", poles = "2"}
-- The mixer's rows: a track's parameters by group (the first row's cells
-- open the group)
J.TRACK = {
	{"gain", {{"gain", -60, 24, 0}}},
	{"pan", {{"pan", -1, 1, 0}}},
	{"amp", {{"amp", 0, 60, 0}, {"bias", -2, 2, 0.2}, {"tight", 10, 2000, 90},
		{"hump", -24, 24, 6}, {"mid", 100, 10000, 850}, {"fizz", 500, 20000, 6500},
		{"cab", 500, 20000, 4800}, {"thump", -24, 24, 4}, {"thumpf", 20, 1000, 120},
		{"mud", -24, 24, 3}, {"presence", -24, 24, 3}, {"ampout", -60, 24, -8},
		{"blend", 0, 1, 1}}},
	{"eq", {{"hp", 10, 20000, 0}, {"lp", 10, 20000, 0}, {"lo", -24, 24, 0},
		{"hi", -24, 24, 0}, {"lof", 20, 20000, 150}, {"hif", 20, 20000, 5000}}},
	{"comp", {{"comp", -60, 0, 0}, {"ratio", 1, 20, 4}, {"catk", 0.0001, 5, 0.005},
		{"crel", 0.001, 5, 0.1}, {"makeup", -24, 24, 0}}},
	{"rev", {{"rev", 0, 2, 0}}},
	{"dly", {{"dly", 0, 2, 0}}},
	{"trem", {{"trem", 0, 1, 0}, {"tremsteps", 0.25, 256, 2}}},
	{"more", {{"mono", 0, 1, 0}, {"choke", 0, 1, 0}, {"transpose", -48, 48, 0},
		{"tune", -1200, 1200, 0}, {"hum", 0, 100, 0}, {"velr", 0, 1, 0},
		{"seed", 0, 1e9, 0}}},
}
J.BUS = {
	reverb = {{"size", 0.1, 1.4, 0.8}, {"decay", 0.1, 20, 1.6}, {"damp", 0, 1, 0.4},
		{"predelay", 0, 0.18, 0.012}, {"lowcut", 20, 2000, 180}, {"gain", -60, 12, 0}},
	delay = {{"time", 0, 64, 3}, {"feedback", 0, 0.95, 0.35}, {"tone", 20, 20000, 2500},
		{"gain", -60, 12, 0}},
	master = {{"comp", -60, 0, 0}, {"ratio", 1, 20, 2}, {"catk", 0.0001, 5, 0.01},
		{"crel", 0.001, 5, 0.15}, {"ceiling", -24, 0, -1}, {"gain", -60, 24, 0},
		{"release", 0.001, 2, 0.08}},
}
-- Whole numbers only
J.WHOLE = {oct2 = true, transpose = true, seed = true, mono = true, choke = true,
	time = true}

-- An instrument parameter's {name, lo, hi, default}
function J.param_def(k)
	for _, g in pairs(J.INST) do
		for _, d in ipairs(g) do
			if d[1] == k then
				return d
			end
		end
	end
end

-- A slider's place (0..1) for a value and back: a range over two decades on
-- a log scale, one from 0 up to 10 or more on a cube's, else straight
function J.to_slider(d, v)
	local lo, hi = d[2], d[3]
	if lo > 0 and hi / lo >= 100 then
		return math.log(math.max(lo, v) / lo) / math.log(hi / lo)
	elseif lo == 0 and hi >= 10 then
		return (math.max(0, v) / hi) ^ (1 / 3)
	end
	return (v - lo) / (hi - lo)
end

function J.from_slider(d, x)
	x = math.max(0, math.min(1, x))
	local lo, hi, v = d[2], d[3], nil
	if lo > 0 and hi / lo >= 100 then
		v = lo * (hi / lo) ^ x
	elseif lo == 0 and hi >= 10 then
		v = hi * x ^ 3
	else
		v = lo + (hi - lo) * x
	end
	if J.WHOLE[d[1]] then
		v = math.floor(v + 0.5)
	end
	return tonumber(J.fmt(math.max(lo, math.min(hi, v))))
end

-- ---- The editor
return function(A)
if not A then
	-- (the text model alone, for a test by hand)
	return J
end
local K, NT = A.K, A.NT
local magic, ui_utils, log = A.magic, A.ui_utils, A.log
local PRE = A.log_prefix or "kit editor: music "
local text, edit = K.text, K.edit
-- Buttons as wide as their text and rows of one height: a row's layout
-- spread a window's room over them
local function button(parent, s, fn, down)
	local b, t = K.button(parent, s, fn, down)
	b.maxWidth = b.minWidth
	return b, t
end
local function row(parent)
	local r = K.row(parent)
	r:SetFixedHeight(NT.sh.on() and 32 or 28)
	return r
end
local DIM, WARN = K.DIM, K.WARN
local jam = require("buildat/extension/jam")
local network = require("buildat/extension/network")
local uistack = require("buildat/core/uistack")
local now_us = buildat.get_time_us

-- The editor's state: the text (MU.text, read as MU.m and by jam as MU.song),
-- the view and what is selected in each, the preview's player
local MU = {view = "song", undo = {}}
NT.mu = MU
function MU.on()
	return MU.win ~= nil
end

local VIEWS = {{"song", "Song"}, {"pattern", "Pattern"}, {"roll", "Roll"},
	{"inst", "Instrument"}, {"mixer", "Mixer"}, {"text", "Text"}}
local FOCUS = magic.Color(ui_utils.rgb("focus"))
local function rgb(r, g, b)
	return magic.Color(r, g, b)
end
local EMPTY, BEAT, BAR = rgb(0.16, 0.16, 0.19), rgb(0.21, 0.21, 0.25), rgb(0.27, 0.27, 0.32)
local HITS = {X = rgb(1, 0.55, 0.12), x = rgb(0.78, 0.42, 0.1), g = rgb(0.45, 0.28, 0.1),
	o = rgb(0.2, 0.62, 0.72), O = rgb(0.3, 0.85, 1), f = rgb(0.68, 0.4, 0.9)}
local NOTE_C, HOLD_C, PARAM_C = rgb(0.25, 0.52, 0.9), rgb(0.17, 0.34, 0.6),
		rgb(0.55, 0.52, 0.2)
local SCALE_C, OUT_C, ROOT_C = rgb(0.2, 0.2, 0.25), rgb(0.13, 0.13, 0.15),
		rgb(0.3, 0.25, 0.17)
local function dim(c)
	return magic.Color(c.r * 0.5 + 0.06, c.g * 0.5 + 0.06, c.b * 0.5 + 0.06)
end
local function brighter(c, v)
	local k = 0.6 + 0.4 * math.max(0, math.min(1, v))
	return magic.Color(c.r * k, c.g * k, c.b * k)
end

local function say(s)
	MU.status = s
	log:info(PRE .. s)
end

-- The text read again: the model, and jam's song or the reason it is none
local function read(t)
	MU.text, MU.m = t, J.read(t)
	local song, err = jam.song(t)
	MU.song, MU.err, MU.key = song, song == nil and tostring(err) or nil, nil
end

-- An edit: the new text read, given to the inspector's field, played on
-- from where the preview was; the views drawn again unless quiet (a slider
-- moving, the text being typed)
local function set_text(t, what, quiet)
	if t == MU.text then
		return
	end
	MU.undo[#MU.undo + 1] = MU.text
	if #MU.undo > 200 then
		table.remove(MU.undo, 1)
	end
	read(t)
	MU.opts.on_text(t)
	log:info(PRE .. "edit " .. what .. ": " .. (MU.err and
			"Error: " .. MU.err or "parses") .. ", " .. #t .. " bytes")
	MU.status = what
	if MU.player then
		MU.restart_us = now_us() + 300000
	end
	if not quiet then
		MU.draw()
	end
end

local function undo()
	local t = table.remove(MU.undo)
	if not t then
		say("nothing to undo")
		return
	end
	read(t)
	MU.opts.on_text(t)
	say("undone, " .. #t .. " bytes")
	if MU.player then
		MU.restart_us = now_us()
	end
	MU.draw()
end

-- ---- The preview: the song, a section looped or the pattern shown

local function preview()
	local m, mode = MU.m, MU.loop or "song"
	if mode == "pattern" and m.pattern[MU.pat or ""] then
		return J.pattern_text(m, MU.pat), {{at = 0, len = m.pattern[MU.pat].len,
			layer = {MU.pat}}}
	end
	local sec = mode:match("^s:(.+)$")
	if sec and m.section[sec] then
		return J.loop_text(m, sec), (J.timeline(m, {sec}))
	end
	return MU.text, (J.timeline(m))
end

local function stop_audition()
	if MU.aud then
		MU.aud:stop()
		MU.aud = nil
	end
end

local function stop()
	if MU.player then
		MU.player:stop()
		MU.player = nil
		say("stopped")
	end
end

-- From at seconds on the preview's timeline
local function play(at)
	stop_audition()
	local t, tl = preview()
	local song, err = jam.song(t)
	if not song then
		say("not played: " .. tostring(err))
		return
	end
	if MU.player then
		MU.player:stop()
	end
	MU.player, MU.pinfo, MU.ptl = jam.play(song, {at = at or 0}), song:info(), tl
	if MU.mood then
		MU.player:mood(MU.mood, true)
	end
	say(string.format("playing %s from %.2f s, mood %s",
			(MU.loop or "song"):gsub("^s:", "section "), at or 0, MU.mood or "all"))
end

-- One note (a token, a drum's hit) on a track, as the song's buses hear it;
-- not over the preview playing
local function audition(track, tok, inst)
	if MU.player or (not track and not inst) then
		return
	end
	local m = MU.m
	local src = track and J.src_of(m, track) or (m.inst[inst] or {}).src
	local song = jam.song(J.audition_text(m, track, tok, J.DRUMS[src], inst))
	if not song then
		return
	end
	stop_audition()
	MU.aud = jam.play(song)
	MU.aud_stop = now_us() + math.min(3, 2 * song:info().bar) * 1e6
	log:info(PRE .. "audition " .. tostring(track or inst) .. " " .. tok)
end

-- ---- Sizes: cells, rows; the touch mode's bigger

local function sizes()
	local r = magic.ui.root
	MU.touch = NT.sh.on()
	MU.CW = MU.touch and 32 or 26
	MU.CH = MU.touch and 32 or 22
	MU.LW = 80
	-- (Kit's guide hidden meanwhile: editor_input.lua's draw_guide)
	MU.W, MU.H = r.width - 16, r.height - 16 - (MU.opts.top or 0)
end

-- A cell: a coloured box at x, y in a free parent, named for a drive
local mono = nil
local function cell(parent, name, x, y, w, h, c, s)
	local b = parent:CreateChild("BorderImage")
	b:SetName(name)
	b:SetPosition(x, y)
	b:SetFixedSize(w, h)
	b.color = c
	b.enabled = true
	if s then
		mono = mono or magic.cache:GetResource("Font", buildat.font_mono)
		local t = b:CreateChild("Text")
		t:SetFont(mono, h >= 30 and 13 or 10)
		t:SetText(s)
		t:SetAlignment(magic.HA_CENTER, magic.VA_CENTER)
	end
	return b
end

local function at(el, x, y, w, h)
	el:SetPosition(x, y)
	el:SetFixedSize(w, h)
	return el
end

local function lit(b, t, on)
	if on and t then
		t:SetColor(FOCUS)
	end
	return b, t
end

-- A dropdown of {label, value}, named for a drive ("music <name>: <label>")
local function choose(parent, name, list, cur, fn, label)
	local d = ui_utils.dropdown(parent, list, cur, function(v)
		if v ~= cur then
			fn(v)
		end
	end, {label = label, name = "music " .. name})
	return d
end

-- A parameter's row: its name, - and +, a slider, its value, x (back to jam's
-- default) when the line sets it. on_set(v[, quiet]); d {name, lo, hi, default}
local function param_row(parent, d, v, own, on_set, prefix)
	local r = row(parent)
	r:SetFixedHeight(MU.touch and 32 or 26)
	local name = prefix .. " " .. d[1]
	local t = text(r, d[1])
	t:SetFixedWidth(80)
	local cur = tonumber(v) or d[4]
	local function step(dir)
		local x
		if J.WHOLE[d[1]] or (d[2] < 0 and d[3] > 0 and d[3] - d[2] >= 20) then
			x = math.max(d[2], math.min(d[3], math.floor(cur + 0.5) + dir))
		else
			x = J.from_slider(d, J.to_slider(d, cur) + dir * 0.02)
		end
		on_set(x)
	end
	button(r, "-", function() step(-1) end):SetName(name .. " -")
	local sl = r:CreateChild("Slider")
	sl:SetStyleAuto()
	sl.range = 1
	sl:SetFixedSize(MU.touch and 140 or 180, 16)
	sl.value = math.max(0, math.min(1, J.to_slider(d, cur)))
	sl:SetName(name .. " slider")
	button(r, "+", function() step(1) end):SetName(name .. " +")
	local vt = text(r, J.fmt(cur) .. (own and "" or " (default)"), own and nil or DIM)
	vt:SetFixedWidth(110)
	local skip = true
	magic.SubscribeToEvent(sl, "SliderChanged", function(_, _, data)
		if skip then
			return
		end
		cur = J.from_slider(d, data:GetFloat("Value"))
		vt:SetText(J.fmt(cur))
		on_set(cur, true)
	end)
	skip = false
	if own then
		button(r, "x", function() on_set(nil) end):SetName(name .. " x")
	end
	return r
end

-- ---- Song: the play order, the sections' entries

local function draw_song(body)
	local m = MU.m
	local view = body:CreateChild("ScrollView")
	view:SetStyleAuto()
	view.scrollBarsAutoVisible = true
	view:SetFixedSize(MU.W - 20, MU.bh - 2 * ((MU.touch and 32 or 28) + 4) - 8)
	local page = view:CreateChild("UIElement")
	page:SetLayout(magic.LM_VERTICAL, 3, magic.IntRect(0, 0, 0, 0))
	view.contentElement = page
	MU.playing_texts = {}
	local seen, shown = {}, {}
	-- An entry as wide as it is long (its longest pattern, repeated), the
	-- longest section the window's width
	local function steps_of(e)
		local n = 0
		for _, pn in ipairs(e.layer) do
			n = math.max(n, (m.pattern[pn] or {len = m.steps}).len)
		end
		return n * e.rep
	end
	local most = 1
	for _, sec in ipairs(m.sections) do
		local n = 0
		for _, e in ipairs(sec.entries) do
			n = n + steps_of(e)
		end
		most = math.max(most, n)
	end
	local per_step = (MU.W - 60 - 120) / most
	local function sec_row(sn, k)
		local sec = m.section[sn]
		local r = row(page)
		r:SetFixedHeight(MU.touch and 40 or 34)
		local mark = (sn == m.loop and not seen[sn]) and " (loop)" or ""
		seen[sn] = true
		local sel = MU.ssel and MU.ssel.section == sn and MU.ssel.k == k
		local b, t = button(r, sn .. mark, function()
			MU.ssel = {section = sn, k = k}
			say("section " .. sn)
			MU.draw()
		end)
		b:SetName("music section " .. sn .. " " .. tostring(k))
		b:SetFixedWidth(116)
		-- (4z37h) things to pick, Kit's lists' look
		ui_utils.selectable(b, t, sel and not MU.ssel.entry)
		for ei, e in ipairs(sec and sec.entries or {}) do
			local eb, et = button(r, table.concat(e.layer, "+") ..
					(e.rep > 1 and " x" .. e.rep or ""), function()
				MU.ssel = {section = sn, k = k, entry = ei}
				say("entry " .. sn .. " " .. ei .. ": " .. (e.raw or ""))
				MU.draw()
			end)
			eb:SetName("music entry " .. sn .. " " .. ei)
			eb:SetFixedWidth(math.max(eb.minWidth, math.floor(steps_of(e) * per_step) - 4))
			ui_utils.selectable(eb, et, sel and MU.ssel.entry == ei)
			if k then
				MU.playing_texts[k .. " " .. ei] = et
			end
		end
	end
	text(page, "Play order: a+b plays two patterns together, x2 plays an entry twice",
			DIM)
	for k, sn in ipairs(m.play) do
		sec_row(sn, k)
		shown[sn] = true
	end
	for _, sec in ipairs(m.sections) do
		if not shown[sec.name] then
			if not shown[""] then
				text(page, "Not in the play order", DIM)
				shown[""] = true
			end
			sec_row(sec.name, nil)
		end
	end
	-- The selection's row: a section's, an entry's
	local s = MU.ssel and m.section[MU.ssel.section]
	if not s then
		text(body, "Pick a section or an entry", DIM)
		return
	end
	local d = row(body)
	if not MU.ssel.entry then
		text(d, "Section " .. s.name .. ":")
		button(d, "Play from here", function()
			local tl = J.timeline(m)
			local step_s = 60 / m.tempo / m.beat
			MU.loop = "song"
			for _, it in ipairs(tl) do
				if it.k == MU.ssel.k then
					play(it.at * step_s)
					break
				end
			end
			MU.draw()
		end):SetName("music play from")
		button(d, "Loop this section", function()
			MU.loop = "s:" .. s.name
			play()
			MU.draw()
		end):SetName("music loop it")
		button(d, "Loop the song from here", function()
			set_text(J.set_loop(m, s.name), "loop " .. s.name)
		end):SetName("music loop here")
		local pats = {}
		for _, p in ipairs(m.patterns) do
			pats[#pats + 1] = {p.name, p.name}
		end
		choose(d, "add entry", pats, nil, function(pn)
			local en = {}
			for i, e in ipairs(s.entries) do
				en[i] = e
			end
			en[#en + 1] = {layer = {pn}, rep = 1}
			set_text(J.set_entries(m, s.name, en), "section " .. s.name .. " + " .. pn)
		end, "Add a pattern")
		return
	end
	local ei = MU.ssel.entry
	local e = s.entries[ei]
	if not e then
		MU.ssel.entry = nil
		return
	end
	text(d, s.name .. " " .. ei .. ":")
	for _, pn in ipairs(e.layer) do
		button(d, "Open " .. pn, function()
			MU.pat, MU.page, MU.sel = pn, 1, nil
			MU.view = "pattern"
			say("view pattern " .. pn)
			MU.draw()
		end):SetName("music open " .. pn)
	end
	local function entries(fn, what)
		local en = {}
		for i, x in ipairs(s.entries) do
			en[i] = x
		end
		fn(en)
		set_text(J.set_entries(m, s.name, en), "section " .. s.name .. " " .. what)
	end
	button(d, "x-", function()
		entries(function(en) en[ei] = {layer = e.layer, rep = math.max(1, e.rep - 1)} end,
				ei .. " repeat " .. math.max(1, e.rep - 1))
	end):SetName("music rep -")
	text(d, "x" .. e.rep)
	button(d, "x+", function()
		entries(function(en) en[ei] = {layer = e.layer, rep = math.min(64, e.rep + 1)} end,
				ei .. " repeat " .. math.min(64, e.rep + 1))
	end):SetName("music rep +")
	button(d, "<", function()
		if ei > 1 then
			MU.ssel.entry = ei - 1
			entries(function(en) en[ei], en[ei - 1] = en[ei - 1], en[ei] end,
					ei .. " earlier")
		end
	end):SetName("music entry <")
	button(d, ">", function()
		if ei < #s.entries then
			MU.ssel.entry = ei + 1
			entries(function(en) en[ei], en[ei + 1] = en[ei + 1], en[ei] end,
					ei .. " later")
		end
	end):SetName("music entry >")
	button(d, "Remove", function()
		if #s.entries > 1 then
			MU.ssel.entry = nil
			entries(function(en) table.remove(en, ei) end, ei .. " removed")
		else
			say("a section needs at least one entry")
		end
	end):SetName("music entry remove")
end

-- ---- Pattern: the step grid

-- The steps a page shows: the whole pattern, or as many bars (else beats)
-- as fit at the smallest cell; the cells (MU.CW) then as wide as fills the
-- window
local function page_steps(p)
	local m = MU.m
	local avail = MU.W - 40 - MU.LW
	local minw = MU.touch and 32 or 22
	local per = p.len
	if per * minw > avail then
		local bars = math.floor(avail / minw / m.steps)
		per = bars >= 1 and bars * m.steps or
				math.max(m.beat, math.floor(avail / minw / m.beat) * m.beat)
	end
	MU.CW = math.max(minw, math.min(160, math.floor(avail / per)))
	return per
end

local function cur_pattern()
	local m = MU.m
	local p = m.pattern[MU.pat or ""] or m.patterns[1]
	MU.pat = p and p.name
	return p
end

local function pattern_head(body, p, roll)
	local m = MU.m
	local r = row(body)
	local pats = {}
	for _, x in ipairs(m.patterns) do
		pats[#pats + 1] = {x.name .. " (" .. x.bars .. ")", x.name}
	end
	choose(r, "pattern", pats, p.name, function(v)
		MU.pat, MU.page, MU.sel, MU.rsel = v, 1, nil, nil
		say("view " .. MU.view .. " " .. v)
		MU.draw()
	end, "Pattern")
	local per = page_steps(p)
	local pages = math.ceil(p.len / per)
	MU.page = math.max(1, math.min(MU.page or 1, pages))
	if pages > 1 then
		button(r, "<", function()
			MU.page = math.max(1, MU.page - 1)
			MU.draw()
		end):SetName("music page <")
		text(r, string.format("steps %d-%d of %d", (MU.page - 1) * per + 1,
				math.min(p.len, MU.page * per), p.len))
		button(r, ">", function()
			MU.page = math.min(pages, MU.page + 1)
			MU.draw()
		end):SetName("music page >")
	end
	button(r, "Loop this pattern", function()
		MU.loop = "pattern"
		play()
		MU.draw()
	end):SetName("music loop pattern")
	return r, per
end

-- Toggle by a click: an empty step placed (and selected, heard), the
-- selected one taken out, another selected
local function grid_press(lane, step)
	local m = MU.m
	local p = m.pattern[MU.pat]
	local st = J.steps(p, lane)
	local tok = st[step].s
	local sel = MU.sel
	if sel and sel.lane == lane.key and sel.step == step and tok ~= "." and tok ~= "-" then
		MU.sel = {lane = lane.key}
		set_text(J.set_steps(m, p.name, lane.key, lane.param and {[step] = "."} or
				J.clear_toks(p, st, step)), "cleared " .. p.name .. " " .. lane.key ..
				" step " .. step)
	elseif tok == "." or (tok == "-" and not lane.drum) then
		local new = J.new_token(m, p, lane, step)
		if lane.param then
			local d = J.param_def(lane.param)
			new = J.inst_values(m, (m.track[lane.track] or {}).inst or "")[lane.param] or
					(d and J.fmt(d[4])) or "0"
		end
		MU.sel = {lane = lane.key, step = step}
		set_text(J.set_steps(m, p.name, lane.key, {[step] = new}), "placed " .. new ..
				" at " .. p.name .. " " .. lane.key .. " step " .. step)
		if not lane.param then
			audition(lane.track, new)
		end
	else
		MU.sel = {lane = lane.key, step = step}
		say("selected " .. p.name .. " " .. lane.key .. " step " .. step .. ": " .. tok)
		MU.draw()
	end
end

-- A note's token changed by fn(note) -> notes (nil: the same), mods
local function retoken(lane, step, fn, what)
	local m = MU.m
	local p = m.pattern[MU.pat]
	local st = J.steps(p, lane)
	local n = J.note(m, st[step].s)
	if not n then
		return
	end
	local notes, mods = fn(n)
	local tok = J.token({notes = n.notes, mods = mods or n.mods, def = n.def}, notes)
	set_text(J.set_steps(m, p.name, lane.key, {[step] = tok}), what .. ": " ..
			p.name .. " " .. lane.key .. " step " .. step .. " " .. tok)
	return tok
end

local function shifted(n, d)
	local out = {}
	for i, x in ipairs(n.notes) do
		out[i] = math.max(0, math.min(127, x + d))
	end
	return out
end

-- The selected note's buttons, the grid's and the roll's: pitch, velocity,
-- length, slide, mute, staccato
local function note_row(parent, lane, step, n, len)
	local m = MU.m
	local p = m.pattern[MU.pat]
	local r = row(parent)
	for _, d in ipairs({-12, -1, 1, 12}) do
		button(r, (d > 0 and "+" or "") .. d, function()
			-- (the roll's selection with it, before it is drawn again)
			if MU.view == "roll" and MU.rsel then
				MU.rsel.pitch = math.max(0, math.min(127, MU.rsel.pitch + d))
			end
			local tok = retoken(lane, step, function(x) return shifted(x, d) end, "pitch")
			if tok then
				audition(lane.track, tok)
			end
		end):SetName("music pitch " .. d)
	end
	text(r, " velocity " .. J.fmt(n.vel))
	for _, v in ipairs({{"?", 0.5}, {"-", math.max(0.05, n.vel - 0.1)},
			{"+", math.min(1, n.vel + 0.1)}, {"!", 1}}) do
		button(r, v[1], function()
			retoken(lane, step, function(x) return nil, J.with_vel(x.mods, v[2]) end,
					"velocity")
		end):SetName("music vel " .. v[1])
	end
	text(r, " length " .. len)
	for _, dl in ipairs({-1, 1}) do
		button(r, dl < 0 and "-" or "+", function()
			local st = J.steps(p, lane)
			set_text(J.set_steps(m, p.name, lane.key, J.len_toks(p, st, step,
					J.length(st, step) + dl)), "length " .. (J.length(st, step) + dl) ..
					": " .. p.name .. " " .. lane.key .. " step " .. step)
		end):SetName("music len " .. (dl < 0 and "-" or "+"))
	end
	for _, md in ipairs({{"~", "slide", n.slide}, {"m", "mute", n.mute},
			{"'", "staccato", n.stacc}}) do
		lit(button(r, md[2], function()
			retoken(lane, step, function(x) return nil, J.toggle_mod(x.mods, md[1]) end,
					md[2])
		end, md[3])):SetName("music " .. md[2])
	end
	return r
end

-- A token typed for the selected step (Enter puts it in)
local function token_field(r, lane, step, cur)
	local f = edit(r, cur, function() end)
	f:SetName("music token")
	f.minWidth = 90
	magic.SubscribeToEvent(f, "TextFinished", function()
		local s = f:GetText():gsub("%s", "")
		if s ~= "" and s ~= cur then
			local m = MU.m
			set_text(J.set_steps(m, MU.pat, lane.key, {[step] = s}), "typed " .. s ..
					": " .. MU.pat .. " " .. lane.key .. " step " .. step)
		end
	end)
end

local function draw_grid(body)
	local m = MU.m
	local p = cur_pattern()
	if not p then
		text(body, "No patterns", DIM)
		return
	end
	local head, per = pattern_head(body, p)
	-- + lane: a track not in it; + param: the selected lane's track's
	local free = {}
	for _, t in ipairs(m.tracks) do
		if not p.lane[t.name] then
			free[#free + 1] = {t.name, t.name}
		end
	end
	if #free > 0 then
		choose(head, "add lane", free, nil, function(v)
			set_text(J.add_lane(m, p.name, v), "lane " .. v .. " added to " .. p.name)
		end, "+ lane")
	end
	local sel_lane = MU.sel and p.lane[MU.sel.lane]
	if sel_lane then
		local tr = sel_lane.track
		local list = {}
		local src = J.src_of(m, tr)
		for _, g in ipairs({"all", "filter", src}) do
			for _, d in ipairs(J.INST[g] or {}) do
				if not p.lane[tr .. "~" .. d[1]] then
					list[#list + 1] = {d[1], d[1]}
				end
			end
		end
		choose(head, "add param", list, nil, function(v)
			set_text(J.add_lane(m, p.name, tr .. "~" .. v), "lane " .. tr .. "~" .. v ..
					" added to " .. p.name)
		end, "+ " .. tr .. "~")
	end
	local first = (MU.page - 1) * per + 1
	local n = math.min(per, p.len - first + 1)
	-- The rows as tall as fills the body above the selection's two rows
	local rh = (MU.touch and 32 or 28) + 4
	MU.CH = math.max(MU.touch and 32 or 26, math.min(96,
			math.floor((MU.bh - 3 * rh - 24) / math.max(1, #p.lanes))))
	local CW, CH, LW, HH = MU.CW, MU.CH, MU.LW, 16
	local g = body:CreateChild("UIElement")
	g:SetFixedSize(LW + n * CW, HH + #p.lanes * CH)
	for c = 0, n - 1 do
		local s = first + c - 1
		if s % m.beat == 0 then
			local t = text(g, tostring(math.floor(s / m.beat) % (m.steps / m.beat) + 1) ..
					(s % m.steps == 0 and "|" or ""), DIM)
			t:SetPosition(LW + c * CW + 2, 0)
		end
	end
	for r, lane in ipairs(p.lanes) do
		local y = HH + (r - 1) * CH
		local copy = lane.copies and " =" .. lane.copies[1].from or ""
		local lb, lt = button(g, lane.key .. copy, function()
			MU.sel = {lane = lane.key}
			say("lane " .. p.name .. " " .. lane.key)
			MU.draw()
		end)
		at(lb, 0, y, LW - 4, CH - 1):SetName("music lane " .. lane.key)
		if MU.sel and MU.sel.lane == lane.key and not MU.sel.step then
			lt:SetColor(FOCUS)
		end
		local st = J.steps(p, lane)
		for c = 0, n - 1 do
			local s = first + c
			local t = st[s]
			local bg = (s - 1) % m.steps == 0 and BAR or (s - 1) % m.beat == 0 and BEAT or EMPTY
			local col, label = bg, nil
			if lane.drum then
				col = HITS[t.s] or bg
			elseif lane.param then
				if t.s ~= "." then
					col, label = PARAM_C, t.s
				end
			elseif t.s == "-" then
				col = HOLD_C
			elseif t.s ~= "." then
				local nt = J.note(m, t.s)
				col = brighter(NOTE_C, nt and nt.vel or 0.8)
				label = nt and (nt.def or J.name(nt.notes[1]) .. (#nt.notes > 1 and "+" or ""))
						or t.s
				if nt and #label < 4 then
					label = label .. (nt.slide and "~" or nt.mute and "m" or "")
				end
			end
			if (t.copy or t.rep) and col ~= bg then
				col = dim(col)
			end
			if MU.sel and MU.sel.lane == lane.key and MU.sel.step == s then
				col = FOCUS
			end
			cell(g, "music step " .. lane.key .. " " .. s, LW + c * CW, y, CW - 1, CH - 1,
					col, label)
		end
	end
	MU.grid = {el = g, x0 = LW, y0 = HH, first = first, n = n, rows = #p.lanes,
		press = function(r, s) grid_press(p.lanes[r], s) end}
	MU.ph = cell(g, "music playhead", 0, HH, CW - 1, #p.lanes * CH, magic.Color(1, 1, 1, 0.22))
	MU.ph.blendMode = magic.BLEND_ALPHA
	MU.ph.enabled = false
	MU.ph.priority = 2
	MU.ph.visible = false
	-- The selection's row
	local d = row(body)
	if not sel_lane then
		text(d, "Click an empty step to fill it, a filled one to select it, the " ..
				"selected one to clear it", DIM)
		return
	end
	local step = MU.sel.step
	local st = J.steps(p, sel_lane)
	if not step then
		text(d, sel_lane.key .. ":")
		if sel_lane.copies then
			button(d, "Unlink from " .. sel_lane.copies[1].from, function()
				set_text(J.unlink(m, p.name, sel_lane.key) or m.text, "lane " ..
						sel_lane.key .. " unlinked in " .. p.name)
			end):SetName("music unlink")
		end
		if not sel_lane.drum and not sel_lane.param then
			button(d, "Roll", function()
				MU.view, MU.roll_lane, MU.rsel = "roll", sel_lane.key, nil
				say("view roll " .. p.name .. " " .. sel_lane.key)
				MU.draw()
			end):SetName("music to roll")
		end
		button(d, "Remove lane", function()
			local t, why = J.remove_lane(m, p.name, sel_lane.key)
			if not t then
				say("not removed: " .. why)
				MU.draw()
				return
			end
			MU.sel = nil
			set_text(t, "lane " .. sel_lane.key .. " removed from " .. p.name)
		end):SetName("music remove lane")
		return
	end
	local tok = st[step].s
	text(d, sel_lane.key .. " step " .. step .. ": " .. tok)
	if sel_lane.drum then
		for _, h in ipairs({"X", "x", "g", "o", "O", "f"}) do
			lit(button(d, h, function()
				set_text(J.set_steps(m, p.name, sel_lane.key, {[step] = h}), "hit " .. h ..
						": " .. p.name .. " " .. sel_lane.key .. " step " .. step)
				audition(sel_lane.track, h)
			end, h == tok)):SetName("music hit " .. h)
		end
	elseif sel_lane.param then
		local dd = J.param_def(sel_lane.param)
		if dd and tonumber(tok) then
			for _, dir in ipairs({-1, 1}) do
				button(d, dir < 0 and "-" or "+", function()
					local v = J.from_slider(dd, J.to_slider(dd, tonumber(tok)) + dir * 0.02)
					set_text(J.set_steps(m, p.name, sel_lane.key, {[step] = J.fmt(v)}),
							"value " .. J.fmt(v) .. ": " .. p.name .. " " .. sel_lane.key ..
							" step " .. step)
				end):SetName("music value " .. (dir < 0 and "-" or "+"))
			end
		end
	else
		local nt = J.note(m, tok)
		if nt then
			note_row(body, sel_lane, step, nt, J.length(st, step))
		end
	end
	token_field(d, sel_lane, step, tok)
	button(d, "Remove", function()
		MU.sel = {lane = sel_lane.key}
		set_text(J.set_steps(m, p.name, sel_lane.key, sel_lane.param and {[step] = "."}
				or J.clear_toks(p, st, step)), "cleared " .. p.name .. " " ..
				sel_lane.key .. " step " .. step)
	end):SetName("music remove")
end

-- ---- Roll: a melodic lane's notes by pitch

local function melodic_lanes(p)
	local out = {}
	for _, l in ipairs(p.lanes) do
		if not l.drum and not l.param then
			out[#out + 1] = l
		end
	end
	return out
end

-- Its notes: {step, len, pitch, n, rep}
local function roll_notes(p, lane)
	local m, out = MU.m, {}
	local st = J.steps(p, lane)
	for s = 1, p.len do
		local n = J.note(m, st[s].s)
		if n then
			local len = J.length(st, s)
			for _, x in ipairs(n.notes) do
				out[#out + 1] = {step = s, len = len, pitch = x, n = n,
					dim = st[s].rep or st[s].copy}
			end
		end
	end
	return out, st
end

-- Steps' tokens changed on a copy of st (the moves' second half reads the
-- first's)
local function applied(st, t)
	local out = {}
	for i, x in ipairs(st) do
		out[i] = {s = t[i] or x.s}
	end
	return out
end

local function merge(a, b)
	for k, v in pairs(b) do
		a[k] = v
	end
	return a
end

-- A note placed at step (a chord with what starts there), len steps
local function place_toks(p, st, step, pitch, len, mods)
	local m = MU.m
	local n = J.note(m, st[step].s)
	if n then
		for _, x in ipairs(n.notes) do
			if x == pitch then
				return {}
			end
		end
		local notes = {}
		for i, x in ipairs(n.notes) do
			notes[i] = x
		end
		notes[#notes + 1] = pitch
		return {[step] = J.token(n, notes)}
	end
	local t = {[step] = J.name(pitch) .. (mods or "")}
	return merge(t, J.len_toks(p, applied(st, t), step, len))
end

-- The note hit out of its token: a chord's one pitch, else the step
local function remove_toks(p, st, hit)
	local n = hit.n
	if #n.notes > 1 then
		local notes = {}
		for _, x in ipairs(n.notes) do
			if x ~= hit.pitch then
				notes[#notes + 1] = x
			end
		end
		return {[hit.step] = J.token(n, notes)}
	end
	return J.clear_toks(p, st, hit.step)
end

-- Moved dc steps and dr semitones: only up or down, its pitch alone; else the
-- whole token
local function move_toks(p, st, hit, dc, dr)
	local n = hit.n
	if dc == 0 then
		local notes = {}
		for i, x in ipairs(n.notes) do
			notes[i] = x == hit.pitch and math.max(0, math.min(127, x + dr)) or x
		end
		return {[hit.step] = J.token(n, notes)}
	end
	local to = math.max(1, math.min(p.len, hit.step + dc))
	local t = J.clear_toks(p, st, hit.step)
	local st2 = applied(st, t)
	local tok = J.token({notes = n.notes, mods = n.mods, def = n.def},
			dr ~= 0 and shifted(n, dr) or nil)
	t[to] = tok
	return merge(t, J.len_toks(p, applied(st2, {[to] = tok}), to, hit.len))
end

local function roll_edit(p, lane, t, what, sel)
	MU.rsel = sel
	set_text(J.set_steps(MU.m, p.name, lane.key, t), what .. ": " .. p.name .. " " ..
			lane.key)
end

local function roll_press(p, lane, pitch, step, x, y, dx)
	-- (the notes drawn, with their boxes to drag)
	local notes, st = MU.roll_els, J.steps(p, lane)
	local hit = nil
	for _, nt in ipairs(notes) do
		if nt.pitch == pitch and step >= nt.step and step < nt.step + nt.len then
			hit = nt
		end
	end
	local pr = {x = x, y = y}
	MU.press = pr
	local g = MU.grid
	local CW, CH = MU.CW, MU.CH
	if not hit then
		-- A new note drawn: as long as the drag
		pr.el = cell(g.el, "music ghost", g.x0 + (step - g.first) * CW, g.y0 +
				(g.top - pitch) * CH, CW - 1, CH - 1, FOCUS)
		pr.el.priority = 2
		pr.drag = function(dc)
			pr.el:SetFixedSize(math.max(1, dc + 1) * CW - 1, CH - 1)
		end
		pr.done = function(dc)
			local len = math.max(1, dc + 1)
			local t = place_toks(p, st, step, pitch, len)
			roll_edit(p, lane, t, "note " .. J.name(pitch) .. " at step " .. step ..
					", length " .. len, {step = step, pitch = pitch})
			audition(lane.track, J.name(pitch))
		end
		return
	end
	local resize = step == hit.step + hit.len - 1 and dx > CW / 2
	pr.el = hit.el
	local p0 = hit.el and hit.el.position
	local x0, y0, w0 = p0 and p0.x, p0 and p0.y, hit.el and hit.el.width
	pr.drag = function(dc, dr)
		if not hit.el then
			return
		end
		if resize then
			hit.el:SetFixedSize(math.max(CW - 1, w0 + dc * CW), CH - 1)
		else
			hit.el:SetPosition(x0 + dc * CW, y0 - dr * CH)
		end
	end
	pr.done = function(dc, dr)
		if dc == 0 and dr == 0 then
			local sel = MU.rsel
			if sel and sel.step == hit.step and sel.pitch == pitch then
				roll_edit(p, lane, remove_toks(p, st, hit), "note " .. J.name(pitch) ..
						" at step " .. hit.step .. " removed", nil)
			else
				MU.rsel = {step = hit.step, pitch = pitch}
				say("selected note " .. J.name(pitch) .. " at " .. p.name .. " " ..
						lane.key .. " step " .. hit.step)
				MU.draw()
			end
		elseif resize then
			local len = math.max(1, hit.len + dc)
			roll_edit(p, lane, J.len_toks(p, st, hit.step, len), "note at step " ..
					hit.step .. ", length " .. len, {step = hit.step, pitch = pitch})
		else
			local to = math.max(1, math.min(p.len, hit.step + dc))
			roll_edit(p, lane, move_toks(p, st, hit, dc, dr), "note " ..
					J.name(pitch) .. " moved to step " .. to .. " as " .. J.name(pitch + dr),
					{step = to, pitch = pitch + dr})
			audition(lane.track, J.name(pitch + dr))
		end
	end
end

local function draw_roll(body)
	local m = MU.m
	local p = cur_pattern()
	if not p then
		text(body, "No patterns", DIM)
		return
	end
	local head, per = pattern_head(body, p, true)
	local lanes = melodic_lanes(p)
	local lane = p.lane[MU.roll_lane or ""]
	if not lane or lane.drum or lane.param then
		lane = lanes[1]
	end
	if not lane then
		text(body, p.name .. " has no melodic lanes. Its drums are in the Pattern view.",
				DIM)
		return
	end
	MU.roll_lane = lane.key
	local list = {}
	for _, l in ipairs(lanes) do
		list[#list + 1] = {l.key, l.key}
	end
	choose(head, "lane", list, lane.key, function(v)
		MU.roll_lane, MU.rsel = v, nil
		say("view roll " .. p.name .. " " .. v)
		MU.draw()
	end, "Lane")
	MU.CH = MU.touch and 32 or 22
	MU.key = MU.key or J.key_of(m)
	local key = MU.key
	text(head, "Key: " .. key.name .. " (guessed)", DIM)
	local notes, st = roll_notes(p, lane)
	local rows = math.max(12, math.min(48, math.floor((MU.bh - 3 * ((MU.touch and 32 or
			28) + 4) - 24) / MU.CH)))
	if not MU.roll_top or MU.roll_for ~= p.name .. lane.key then
		local lo, hi = 127, 0
		for _, nt in ipairs(notes) do
			lo, hi = math.min(lo, nt.pitch), math.max(hi, nt.pitch)
		end
		if hi < lo then
			lo, hi = 48, 60
		end
		MU.roll_top = math.min(127, math.floor((lo + hi) / 2 + rows / 2))
		MU.roll_for = p.name .. lane.key
	end
	button(head, "Scroll up", function()
		MU.roll_top = math.min(127, MU.roll_top + 12)
		MU.draw()
	end):SetName("music roll up")
	button(head, "Scroll down", function()
		MU.roll_top = math.max(rows - 1, MU.roll_top - 12)
		MU.draw()
	end):SetName("music roll down")
	local top = MU.roll_top
	local first = (MU.page - 1) * per + 1
	local n = math.min(per, p.len - first + 1)
	local CW, CH, LW, HH = MU.CW, MU.CH, MU.LW, 16
	local g = body:CreateChild("UIElement")
	g:SetFixedSize(LW + n * CW, HH + rows * CH)
	for c = 0, n - 1 do
		local s = first + c - 1
		if s % m.beat == 0 then
			text(g, tostring(math.floor(s / m.beat) % (m.steps / m.beat) + 1), DIM):SetPosition(
					LW + c * CW + 2, 0)
		end
	end
	for r = 1, rows do
		local pitch = top - r + 1
		local pc = pitch % 12
		local y = HH + (r - 1) * CH
		local bg = pc == key.root and ROOT_C or key.has[pc] and SCALE_C or OUT_C
		local t = text(g, J.name(pitch), key.has[pc] and nil or DIM)
		t:SetPosition(4, y + 2)
		for c = 0, n - 1 do
			local s = first + c
			local cc = (s - 1) % m.steps == 0 and magic.Color(bg.r + 0.08, bg.g + 0.08,
					bg.b + 0.08) or (s - 1) % m.beat == 0 and magic.Color(bg.r + 0.04,
					bg.g + 0.04, bg.b + 0.04) or bg
			cell(g, "music roll " .. s .. " " .. J.name(pitch), LW + c * CW, y, CW - 1,
					CH - 1, cc)
		end
	end
	for _, nt in ipairs(notes) do
		local r = top - nt.pitch
		local a, b = math.max(nt.step, first), math.min(nt.step + nt.len - 1, first + n - 1)
		if r >= 0 and r < rows and a <= b then
			local col = brighter(NOTE_C, nt.n.vel)
			if nt.dim then
				col = dim(col)
			end
			if MU.rsel and MU.rsel.step == nt.step and MU.rsel.pitch == nt.pitch then
				col = FOCUS
			end
			nt.el = cell(g, "music note " .. nt.step .. " " .. J.name(nt.pitch),
					LW + (a - first) * CW, HH + r * CH, (b - a + 1) * CW - 1, CH - 1, col,
					#nt.n.notes > 1 and nt.pitch == nt.n.notes[1] and (nt.n.def or "") or
					(nt.n.slide and "~" or nil))
			nt.el.enabled = false
			-- (over the cells: Urho3D's sort of equal priorities is no stable one)
			nt.el.priority = 1
		end
	end
	MU.grid = {el = g, x0 = LW, y0 = HH, first = first, n = n, rows = rows, top = top,
		press = function(r, s, x, y, dx) roll_press(p, lane, top - r + 1, s, x, y, dx) end}
	-- (the notes found again at the press, with their boxes)
	MU.roll_els = notes
	MU.ph = cell(g, "music playhead", 0, HH, CW - 1, rows * CH, magic.Color(1, 1, 1, 0.22))
	MU.ph.blendMode = magic.BLEND_ALPHA
	MU.ph.enabled = false
	MU.ph.priority = 2
	MU.ph.visible = false
	local sel = MU.rsel
	local hit = nil
	for _, nt in ipairs(notes) do
		if sel and nt.step == sel.step and nt.pitch == sel.pitch then
			hit = nt
		end
	end
	local d = row(body)
	if not hit then
		text(d, "Click to place or select a note, again to remove it. Drag to draw a " ..
				"note, move one, or resize one by its end.", DIM)
		return
	end
	text(d, lane.key .. " step " .. hit.step .. ": " .. J.name(hit.pitch) ..
			", length " .. hit.len)
	for _, mv in ipairs({{"<", -1, 0}, {">", 1, 0}, {"Up", 0, 1}, {"Down", 0, -1}}) do
		button(d, mv[1], function()
			local to = math.max(1, math.min(p.len, hit.step + mv[2]))
			roll_edit(p, lane, move_toks(p, st, hit, mv[2], mv[3]), "note " ..
					J.name(hit.pitch) .. " moved to step " .. to .. " as " ..
					J.name(hit.pitch + mv[3]), {step = to, pitch = hit.pitch + mv[3]})
		end):SetName("music move " .. mv[1])
	end
	button(d, "Remove", function()
		roll_edit(p, lane, remove_toks(p, st, hit), "note " .. J.name(hit.pitch) ..
				" at step " .. hit.step .. " removed", nil)
	end):SetName("music remove")
	note_row(body, lane, hit.step, hit.n, hit.len)
end

-- ---- Instrument: an instrument's parameters as sliders

local function inst_notes(m, name)
	local count, list = {}, {}
	for _, p in ipairs(m.patterns) do
		for _, lane in ipairs(p.lanes) do
			local t = m.track[lane.track]
			if t and t.inst == name and not lane.param then
				for _, tk in ipairs(lane.toks) do
					local n = not lane.drum and J.note(m, tk.s)
					if n then
						local k = J.name(n.notes[1])
						if not count[k] then
							list[#list + 1] = k
						end
						count[k] = (count[k] or 0) + 1
					end
				end
			end
		end
	end
	table.sort(list, function(a, b) return count[a] > count[b] end)
	return {list[1], list[2], list[3]}
end

local function inst_track(m, name)
	for _, t in ipairs(m.tracks) do
		if t.inst == name then
			return t.name
		end
	end
end

local function draw_inst(body)
	local m = MU.m
	local r = row(body)
	if not m.inst[MU.inst or ""] then
		MU.inst = m.insts[1] and m.insts[1].name
	end
	for _, i in ipairs(m.insts) do
		local ib, it = button(r, i.name, function()
			MU.inst = i.name
			say("instrument " .. i.name)
			MU.draw()
		end)
		ib:SetName("music inst " .. i.name)
		ui_utils.selectable(ib, it, i.name == MU.inst)
	end
	local i = m.inst[MU.inst or ""]
	if not i then
		text(body, "No instruments", DIM)
		return
	end
	local vals = J.inst_values(m, i.name)
	local own = J.own_values(m, i.ln, 4)
	local track = inst_track(m, i.name)
	local drum = J.DRUMS[i.src]
	local tok = drum and "X" or nil
	local ar = row(body)
	local srcs = {}
	for _, s in ipairs(J.CHOICES.src) do
		srcs[#srcs + 1] = {s, s}
	end
	choose(ar, "src", srcs, i.src, function(v)
		set_text(J.set_inst(m, i.name, "src", v), "inst " .. i.name .. " src " .. v)
	end, "inst " .. i.name .. (i.base and " (from " .. i.base .. ")" or ""))
	text(ar, track and "played on track " .. track or "not on any track", DIM)
	local notes = drum and {"X", "x", "g"} or inst_notes(m, i.name)
	if #notes == 0 then
		notes = {"C3", "C4"}
	end
	MU.aud_tok = MU.aud_for == i.name and MU.aud_tok or notes[1]
	MU.aud_for = i.name
	for _, nt in ipairs(notes) do
		lit(button(ar, nt, function()
			MU.aud_tok = nt
			audition(track, nt, i.name)
			MU.draw()
		end, nt == MU.aud_tok)):SetName("music audition " .. nt)
	end
	local function set(k, v, quiet)
		set_text(J.set_inst(MU.m, i.name, k, v ~= nil and (type(v) == "number" and
				J.fmt(v) or v) or nil), "inst " .. i.name .. " " .. k .. " " ..
				(v ~= nil and tostring(type(v) == "number" and J.fmt(v) or v) or "default"),
				quiet)
		-- heard again, a moment after the slider stops
		MU.aud_due = now_us() + (quiet and 250000 or 0)
	end
	local view = body:CreateChild("ScrollView")
	view:SetStyleAuto()
	view.scrollBarsAutoVisible = true
	view:SetFixedSize(MU.W - 20, MU.bh - 2 * ((MU.touch and 32 or 28) + 4) - 8)
	local page = view:CreateChild("UIElement")
	page:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	view.contentElement = page
	local cr = row(page)
	for _, k in ipairs(i.src == "osc" and {"wave", "wave2", "ftype", "poles"} or
			{"ftype", "poles"}) do
		local list = {}
		for _, v in ipairs(J.CHOICES[k]) do
			list[#list + 1] = {v, v}
		end
		choose(cr, "choice " .. k, list, vals[k] or J.CHOICE_DEFAULT[k], function(v)
			set(k, v)
		end, k)
	end
	local chord = edit(cr, vals.chord or "", function() end)
	chord:SetName("music chord")
	magic.SubscribeToEvent(chord, "TextFinished", function()
		local s = chord:GetText():gsub("%s", "")
		set("chord", s ~= "" and s or nil)
	end)
	text(cr, "chord (intervals)", DIM)
	for _, g in ipairs({i.src, "all", "filter"}) do
		if J.INST[g] then
			text(page, g == i.src and "Source: " .. g or g == "all" and "All sources" or
					"Filter" .. (vals.ftype and vals.ftype ~= "none" and "" or
					" (off while ftype is none)"), DIM)
			for _, d in ipairs(J.INST[g]) do
				param_row(page, d, vals[d[1]], own[d[1]] ~= nil, function(v, quiet)
					set(d[1], v, quiet)
				end, "music param")
			end
		end
	end
	MU.aud_track = track
end

-- ---- Mixer: a column a track, the buses', a row a mood

local function pan_text(v)
	v = tonumber(v) or 0
	if math.abs(v) < 0.005 then
		return "C"
	end
	return (v < 0 and "L" or "R") .. math.floor(math.abs(v) * 100 + 0.5)
end

local BUS_OF = {gain = {"master", "gain"}, comp = {"master", "comp"},
	rev = {"reverb", "decay"}, dly = {"delay", "feedback"}}

local function mix_text(m, t, g)
	local v = J.own_values(m, t.ln, 3)
	if g == "gain" then
		return v.gain or "0"
	elseif g == "pan" then
		return pan_text(v.pan)
	elseif g == "amp" then
		return v.amp or "-"
	elseif g == "eq" then
		local s = (v.hp and "hp" .. v.hp or "") .. (v.lp and "lp" .. v.lp or "")
		if s == "" then
			s = (v.lo or v.hi) and "shelf" or "-"
		end
		return s
	elseif g == "comp" then
		return v.comp or "-"
	elseif g == "trem" then
		return v.trem or "-"
	elseif g == "more" then
		return (v.mono == "1" and "mono" or v.choke == "1" and "choke" or v.transpose and
				"tr" .. v.transpose or "...")
	end
	return v[g] or "-"
end

local function draw_mixer(body)
	local m = MU.m
	local view = body:CreateChild("ScrollView")
	view:SetStyleAuto()
	view.scrollBarsAutoVisible = true
	local sel = MU.mix
	-- The table as tall as its rows (all of the body but a row below at
	-- most), its columns over the window's width, the labels' column as
	-- wide as the widest
	local rh = (MU.touch and 32 or 28) + 3
	local th = math.min(MU.bh - rh - 8, (2 + #J.TRACK + #m.moods) * rh + 8)
	view:SetFixedSize(MU.W - 20, th)
	local page = view:CreateChild("UIElement")
	page:SetLayout(magic.LM_VERTICAL, 3, magic.IntRect(0, 0, 0, 0))
	view.contentElement = page
	local labels = {}
	local function label_of(el)
		labels[#labels + 1] = el
		return el
	end
	local W = 0 -- (set below once the labels' width is known)
	local cells = {}
	local hr = row(page)
	label_of(text(hr, ""))
	for _, t in ipairs(m.tracks) do
		cells[#cells + 1] = text(hr, t.name)
	end
	cells[#cells + 1] = text(hr, "buses")
	local function cellb(r, name, s, on, fn)
		local b, t = button(r, s, fn)
		cells[#cells + 1] = b
		b:SetName(name)
		lit(b, t, on)
	end
	local function mood_rows()
		for _, md in ipairs(m.moods) do
			local r = row(page)
			local lb, lt = button(r, "mood " .. md.name, function()
				MU.mood = md.name
				if MU.player then
					MU.player:mood(md.name)
				end
				say("preview mood " .. md.name)
				MU.draw()
			end)
			label_of(lb)
			lb:SetName("music mood row " .. md.name)
			lit(lb, lt, MU.mood == md.name)
			for _, t in ipairs(m.tracks) do
				local v = md.gains[t.name]
				cellb(r, "music mix " .. t.name .. " mood " .. md.name, v or "0",
						sel and sel.track == t.name and sel.row == "mood " .. md.name, function()
					MU.mix = {track = t.name, row = "mood " .. md.name}
					-- (the mood heard while its gains are edited)
					MU.mood = md.name
					if MU.player then
						MU.player:mood(md.name)
					end
					say("mixer " .. t.name .. " mood " .. md.name)
					MU.draw()
				end)
			end
		end
	end
	for _, grp in ipairs(J.TRACK) do
		local g = grp[1]
		local r = row(page)
		label_of(text(r, g))
		for _, t in ipairs(m.tracks) do
			cellb(r, "music mix " .. t.name .. " " .. g, mix_text(m, t, g),
					sel and sel.track == t.name and sel.row == g, function()
				MU.mix = {track = t.name, row = g}
				say("mixer " .. t.name .. " " .. g)
				MU.draw()
			end)
		end
		local bus = BUS_OF[g]
		if bus then
			local ln = m.head[bus[1]]
			local v = ln and J.own_values(m, ln, 2)[bus[2]] or nil
			cellb(r, "music mix bus " .. g, bus[1]:sub(1, 3) .. " " .. (v or "-"),
					sel and sel.track == "bus" and sel.row == g, function()
				MU.mix = {track = "bus", row = g}
				say("mixer " .. bus[1])
				MU.draw()
			end)
		end
		-- (the moods' gains under the tracks' own)
		if g == "gain" then
			mood_rows()
		end
	end
	local LW = 0
	for _, el in ipairs(labels) do
		LW = math.max(LW, el.minWidth)
	end
	for _, el in ipairs(labels) do
		el:SetFixedWidth(LW + 4)
	end
	W = math.max(MU.touch and 64 or 56, math.min(120, math.floor((MU.W - 60 - LW) /
			(#m.tracks + 1)) - 4))
	for _, el in ipairs(cells) do
		el:SetFixedWidth(W)
	end
	if not sel or not (m.track[sel.track] or sel.track == "bus") then
		text(body, "Pick a cell to edit it here. A mood's cells also switch the preview " ..
				"to that mood.", DIM)
		return
	end
	local mood = sel.row:match("^mood (.+)$")
	if mood and m.mood[mood] then
		local d = row(body)
		local cur = m.mood[mood].gains[sel.track]
		text(d, "mood " .. mood .. ", " .. sel.track .. ": " .. (cur or "0") .. " dB")
		local function set(v)
			set_text(J.set_mood(m, mood, sel.track, v), "mood " .. mood .. " " ..
					sel.track .. " " .. tostring(v or "0"))
		end
		button(d, "off", function() set("off") end):SetName("music mood off")
		for _, v in ipairs({-12, -6, -3, 0}) do
			button(d, tostring(v), function() set(v ~= 0 and tostring(v) or nil) end):SetName(
					"music mood " .. v)
		end
		local n = tonumber(cur) or (cur == "off" and -24 or 0)
		button(d, "-", function()
			local x = math.max(-60, n - 1)
			set(x ~= 0 and J.fmt(x) or nil)
		end):SetName("music mood -")
		button(d, "+", function()
			local x = math.min(24, n + 1)
			set(x ~= 0 and J.fmt(x) or nil)
		end):SetName("music mood +")
		return
	end
	local dv = body:CreateChild("ScrollView")
	dv:SetStyleAuto()
	dv.scrollBarsAutoVisible = true
	dv:SetFixedSize(MU.W - 20, math.max(80, MU.bh - th - 8))
	local dp = dv:CreateChild("UIElement")
	dp:SetLayout(magic.LM_VERTICAL, 2, magic.IntRect(0, 0, 0, 0))
	dv.contentElement = dp
	if sel.track == "bus" then
		local bus = BUS_OF[sel.row][1]
		local own = m.head[bus] and J.own_values(m, m.head[bus], 2) or {}
		text(dp, bus, DIM)
		for _, d in ipairs(J.BUS[bus]) do
			param_row(dp, d, own[d[1]], own[d[1]] ~= nil, function(v, quiet)
				set_text(J.set_bus(MU.m, bus, d[1], v and J.fmt(v)), bus .. " " .. d[1] ..
						" " .. (v and J.fmt(v) or "default"), quiet)
			end, "music bus")
		end
		return
	end
	local t = m.track[sel.track]
	local own = J.own_values(m, t.ln, 3)
	text(dp, "track " .. t.name .. ", " .. sel.row, DIM)
	for _, grp in ipairs(J.TRACK) do
		if grp[1] == sel.row then
			for _, d in ipairs(grp[2]) do
				param_row(dp, d, own[d[1]], own[d[1]] ~= nil, function(v, quiet)
					set_text(J.set_track(MU.m, t.name, d[1], v and J.fmt(v)), "track " ..
							t.name .. " " .. d[1] .. " " .. (v and J.fmt(v) or "default"), quiet)
				end, "music track")
			end
		end
	end
end

-- ---- Text: the text itself

local function draw_text(body)
	local f = edit(body, MU.text, function(s)
		set_text(s, "typed", true)
		if MU.status_text then
			MU.status_text:SetText(MU.err and "Error: " .. MU.err or "No errors")
			MU.status_text:SetColor(MU.err and WARN or DIM)
		end
	end)
	f:SetName("music text")
	f.multiLine = true
	f.textSelectable = true
	f.textCopyable = true
	f.maxLength = 65536
	f:SetFixedSize(MU.W - 24, MU.bh - 4)
	f.cursorPosition = 0
end

-- ---- The window

local function analyze()
	if not MU.song then
		say("not analyzed: " .. tostring(MU.err))
		MU.draw()
		return
	end
	local t0 = now_us()
	local j = network.parse_json(MU.song:analyze(0, MU.mood)) or {}
	say(string.format("analyzed%s: %s LUFS, peak %s dBFS, %s s, hash %s (%d ms)",
			MU.mood and " in " .. MU.mood or "", tostring(j.lufs), tostring(j.peak_dbfs),
			tostring(j.seconds), tostring(j.hash), (now_us() - t0) / 1000))
	MU.draw()
end

-- force: past opts.may_close() (false: kept open, the opener asks first)
function MU.close(force)
	MU.close_due = nil
	if not force and MU.opts.may_close and not MU.opts.may_close() then
		return
	end
	stop()
	stop_audition()
	MU.win, MU.grid, MU.ph, MU.press = nil, nil, nil, nil
	uistack.main:pop(MU.root)
	MU.root = nil
	log:info(PRE .. "closed, " .. #MU.text .. " bytes")
	MU.opts.on_close()
end

local function header(win)
	local m = MU.m
	local r1 = row(win)
	text(r1, "Music: " .. (m.title ~= "" and m.title or MU.opts.title) .. "  ")
	for _, v in ipairs(VIEWS) do
		lit(button(r1, v[2], function()
			MU.view = v[1]
			say("view " .. v[1])
			MU.draw()
		end, MU.view == v[1])):SetName("music view " .. v[1])
	end
	text(r1, "  ")
	button(r1, "Undo", undo):SetName("music undo")
	if MU.opts.apply then
		button(r1, "Apply", function()
			MU.opts.apply(MU.text)
			say("applied, " .. #MU.text .. " bytes")
			MU.draw()
		end):SetName("music apply")
	end
	button(r1, "Close", MU.close):SetName("music close")
	local r2 = row(win)
	button(r2, MU.player and "Stop" or "Play", function()
		if MU.player then
			stop()
		else
			play()
		end
		MU.draw()
	end):SetName("music play")
	local loops = {{"the song", "song"}, {"this pattern", "pattern"}}
	for _, s in ipairs(m.sections) do
		loops[#loops + 1] = {"section " .. s.name, "s:" .. s.name}
	end
	choose(r2, "loop", loops, MU.loop or "song", function(v)
		MU.loop = v
		if MU.player then
			play()
		end
		say("loop " .. v:gsub("^s:", "section "))
		MU.draw()
	end, "Play")
	text(r2, " tempo")
	button(r2, "-", function()
		set_text(J.set_head(m, "tempo", J.fmt(math.max(20, m.tempo - 1))), "tempo " ..
				J.fmt(math.max(20, m.tempo - 1)))
	end):SetName("music tempo -")
	text(r2, J.fmt(m.tempo))
	button(r2, "+", function()
		set_text(J.set_head(m, "tempo", J.fmt(math.min(400, m.tempo + 1))), "tempo " ..
				J.fmt(math.min(400, m.tempo + 1)))
	end):SetName("music tempo +")
	text(r2, " swing")
	for _, dir in ipairs({-1, 1}) do
		if dir > 0 then
			text(r2, J.fmt(m.swing))
		end
		button(r2, dir < 0 and "-" or "+", function()
			local v = math.max(0, math.min(0.5, math.floor((m.swing + dir * 0.05) * 100 +
					0.5) / 100))
			set_text(J.set_head(m, "swing", J.fmt(v)), "swing " .. J.fmt(v))
		end):SetName("music swing " .. (dir < 0 and "-" or "+"))
	end
	MU.pos_text = text(r2, "", DIM)
	MU.pos_text:SetFixedWidth(130)
	MU.pos_said = nil
	button(r2, "Analyze", analyze):SetName("music analyze")
	local r3 = row(win)
	text(r3, "Mood:")
	local moods = {"all"}
	for _, md in ipairs(m.moods) do
		moods[#moods + 1] = md.name
	end
	for _, md in ipairs(moods) do
		lit(button(r3, md, function()
			MU.mood = md ~= "all" and md or nil
			if MU.player then
				MU.player:mood(md)
			end
			say("preview mood " .. md)
			MU.draw()
		end, (MU.mood or "all") == md)):SetName("music mood " .. md)
	end
	MU.status_text = text(r3, "  " .. (MU.err and "Error: " .. MU.err or MU.status or
			"No errors"), MU.err and WARN or DIM)
	if MU.opts.file_row then
		MU.opts.file_row(row(win))
	end
end

function MU.draw()
	local win = MU.win
	if not win then
		return
	end
	win:RemoveAllChildren()
	MU.grid, MU.ph, MU.playing_texts, MU.press = nil, nil, nil, nil
	header(win)
	MU.bh = MU.H - 16 - (MU.opts.file_row and 4 or 3) * ((MU.touch and 32 or 28) + 4) - 4
	local body = win:CreateChild("UIElement")
	body:SetFixedHeight(MU.bh)
	body:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(0, 0, 0, 0))
	local draw = ({song = draw_song, pattern = draw_grid, roll = draw_roll,
		inst = draw_inst, mixer = draw_mixer, text = draw_text})[MU.view]
	draw(body)
	if MU.touch then
		NT.sh.touch_size(win)
	end
	if MU.view ~= MU.said_view then
		MU.said_view = MU.view
	end
end

-- The editor on a song: opts {text, title, on_text(text), apply(text) (no
-- Apply without it), on_close(), file_row(row) (a fourth header row's
-- contents: the jam app's files), may_close() (false keeps it open), top
-- (UI pixels left free above it: the launcher's own buttons)}
function MU.open(opts)
	if MU.win then
		return
	end
	MU.opts = opts
	MU.undo, MU.status = {}, nil
	-- (the view kept; what was picked in it belonged to the last song)
	MU.mood, MU.loop, MU.pat, MU.page, MU.sel, MU.rsel, MU.ssel, MU.mix,
			MU.roll_lane, MU.roll_top, MU.inst = nil, nil, nil, nil, nil, nil, nil,
			nil, nil, nil, nil
	read(opts.text)
	sizes()
	local root = uistack.main:push({desc = "kit music"})
	root.defaultStyle = K.STYLE
	root:SetLayout(magic.LM_FREE, 0, magic.IntRect(0, 0, 0, 0))
	root:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
	root:SetPosition(0, 0)
	root:SetFixedSize(magic.ui.root.width, magic.ui.root.height)
	local win = root:CreateChild("Window")
	win:SetStyleAuto()
	win:SetLayout(magic.LM_VERTICAL, 4, magic.IntRect(8, 8, 8, 8))
	win:SetPosition(8, 8 + (opts.top or 0))
	win:SetFixedSize(MU.W, MU.H)
	win.clipChildren = true
	win:SetName("music window")
	ui_utils.wants_clicks(win)
	MU.root, MU.win = root, win
	local m = MU.m
	log:info(string.format(PRE .. "opened %s: %d bytes, %d tracks, " ..
			"%d patterns, %d sections, %s", opts.title, #opts.text, #m.tracks,
			#m.patterns, #m.sections, MU.err and "Error: " .. MU.err or "parses"))
	MU.draw()
end

-- A press on the grid or the roll, by where it is (UI pixels): the cells
-- are boxes, not buttons
magic.SubscribeToEvent("UIMouseClick", function(_, d)
	local g = MU.win and MU.grid
	if not g or ui_utils.dropdown_open() or d:GetInt("Button") ~= magic.MOUSEB_LEFT then
		return
	end
	-- Not through a screen over it (the jam app's file picker placed a step)
	if uistack.main:top() ~= MU.root then
		return
	end
	local p = g.el.screenPosition
	local mx, my = d:GetInt("X"), d:GetInt("Y")
	local x, y = mx - p.x - g.x0, my - p.y - g.y0
	if x < 0 or y < 0 then
		return
	end
	local c, r = math.floor(x / MU.CW), math.floor(y / MU.CH)
	if c >= g.n or r >= g.rows then
		return
	end
	-- (for a drive's drag: where, in the UI's units)
	log:info(string.format(PRE .. "press at %d %d of %d, cells %d %d",
			mx, my, magic.ui.root.width, MU.CW, MU.CH))
	g.press(r + 1, g.first + c, mx, my, x - c * MU.CW)
end)

-- A press held: the roll's drag followed, let go (or a tap) done
local function press_update()
	local pr = MU.press
	if not pr then
		return
	end
	local sc = magic.ui.scale
	local mp = magic.input:GetMousePosition()
	local mx, my = mp.x / sc, mp.y / sc
	local dc = math.floor((mx - pr.x) / MU.CW + 0.5)
	local dr = -math.floor((my - pr.y) / MU.CH + 0.5)
	if magic.input:GetMouseButtonDown(magic.MOUSEB_LEFT) then
		pr.moved = pr.moved or dc ~= 0 or dr ~= 0
		if pr.drag then
			pr.drag(dc, dr)
		end
		return
	end
	MU.press = nil
	if pr.done then
		if pr.moved then
			pr.done(dc, dr)
		else
			pr.done(0, 0)
		end
	end
end

-- The playing entry lit (the song view) or the step (grid, roll); the place
local function playhead()
	local p = MU.player
	local line, step = "", nil
	if p then
		local info = MU.pinfo
		local s = p:position()
		local from, to = info.loop[1], info.loop[2]
		if s >= to and to > from then
			s = from + (s - from) % (to - from)
		end
		step = math.floor(s / (info.bar / MU.m.steps))
		line = string.format("bar %d/%d %d:%04.1f", math.floor(s / info.bar) + 1,
				math.floor(to / info.bar + 0.5), math.floor(s / 60), s % 60)
	end
	if MU.pos_text and line ~= MU.pos_said then
		MU.pos_said = line
		MU.pos_text:SetText(line)
	end
	local item = nil
	for _, it in ipairs(step and MU.ptl or {}) do
		if step >= it.at and step < it.at + it.len then
			item = it
			break
		end
	end
	local key = item and item.k and item.k .. " " .. item.entry
	if MU.playing_texts and key ~= MU.lit_key then
		local old = MU.lit_key and MU.playing_texts[MU.lit_key]
		if old then
			old:SetColor(magic.Color(ui_utils.rgb("text")))
		end
		local new = key and MU.playing_texts[key]
		if new then
			new:SetColor(magic.Color(0.4, 1, 0.5))
		end
		MU.lit_key = key
	end
	local ph, g = MU.ph, MU.grid
	if ph and g then
		local pat = MU.m.pattern[MU.pat or ""]
		local on = false
		if item and pat then
			for _, pn in ipairs(item.layer) do
				if pn == pat.name then
					local ps = (step - item.at) % pat.len + 1
					if ps >= g.first and ps < g.first + g.n then
						ph:SetPosition(g.x0 + (ps - g.first) * MU.CW, ph.position.y)
						on = true
					end
				end
			end
		end
		ph.visible = on
	end
end

magic.SubscribeToEvent("Update", function()
	if not MU.win then
		return
	end
	if MU.close_due then
		MU.close_due = nil
		MU.close()
		return
	end
	local t = now_us()
	if MU.aud and t >= MU.aud_stop then
		stop_audition()
	end
	if MU.restart_us and t >= MU.restart_us then
		MU.restart_us = nil
		if MU.player then
			play(MU.player:position())
		end
	end
	if MU.aud_due and t >= MU.aud_due then
		MU.aud_due = nil
		if MU.view == "inst" and MU.aud_tok then
			audition(MU.aud_track, MU.aud_tok, MU.inst)
		end
	end
	press_update()
	playhead()
end)

-- The keys: Escape, Ctrl+Z, Space, Delete and the arrows on the selection
magic.SubscribeToEvent("KeyDown", function(_, d)
	if not MU.win then
		return
	end
	local key, q = d:GetInt("Key"), d:GetInt("Qualifiers")
	if key == magic.KEY_ESCAPE then
		-- (closed next frame: Kit's own handler, after this one, sees it
		-- open and leaves the Escape alone; an app's pause menu asks
		-- kit.escape() first, which closes it at once)
		-- Not a dialog's over it (its Escape is its own Cancel)
		MU.close_due = not ui_utils.dropdown_open() and
				uistack.main:top() == MU.root or nil
		return
	end
	local f = magic.ui.focusElement
	if (f and f:GetTypeName() == "LineEdit") or ui_utils.dropdown_open() then
		return
	end
	local m = MU.m
	local p = m.pattern[MU.pat or ""]
	if key == magic.KEY_Z and q == magic.QUAL_CTRL then
		undo()
	elseif key == magic.KEY_SPACE then
		if MU.player then
			stop()
		else
			play()
		end
		MU.draw()
	elseif MU.view == "pattern" and p and MU.sel and MU.sel.step then
		local lane = p.lane[MU.sel.lane]
		local step = MU.sel.step
		if not lane then
			return
		end
		local st = J.steps(p, lane)
		if key == magic.KEY_DELETE then
			MU.sel = {lane = lane.key}
			set_text(J.set_steps(m, p.name, lane.key, lane.param and {[step] = "."} or
					J.clear_toks(p, st, step)), "cleared " .. p.name .. " " .. lane.key ..
					" step " .. step)
		elseif key == magic.KEY_LEFT or key == magic.KEY_RIGHT then
			MU.sel.step = math.max(1, math.min(p.len, step + (key == magic.KEY_LEFT and -1
					or 1)))
			MU.draw()
		elseif (key == magic.KEY_UP or key == magic.KEY_DOWN) and not lane.drum and
				not lane.param then
			local dd = (key == magic.KEY_UP and 1 or -1) * (q == magic.QUAL_SHIFT and 12 or 1)
			local tok = retoken(lane, step, function(x) return shifted(x, dd) end, "pitch")
			if tok then
				audition(lane.track, tok)
			end
		end
	elseif MU.view == "roll" and p and MU.rsel then
		local lane = p.lane[MU.roll_lane or ""]
		local notes, st = roll_notes(p, lane)
		local hit = nil
		for _, nt in ipairs(notes) do
			if nt.step == MU.rsel.step and nt.pitch == MU.rsel.pitch then
				hit = nt
			end
		end
		if not hit then
			return
		end
		if key == magic.KEY_DELETE then
			roll_edit(p, lane, remove_toks(p, st, hit), "note " .. J.name(hit.pitch) ..
					" at step " .. hit.step .. " removed", nil)
		else
			local mv = ({[magic.KEY_LEFT] = {-1, 0}, [magic.KEY_RIGHT] = {1, 0},
				[magic.KEY_UP] = {0, 1}, [magic.KEY_DOWN] = {0, -1}})[key]
			if mv then
				local to = math.max(1, math.min(p.len, hit.step + mv[1]))
				roll_edit(p, lane, move_toks(p, st, hit, mv[1], mv[2]), "note " ..
						J.name(hit.pitch) .. " moved to step " .. to .. " as " ..
						J.name(hit.pitch + mv[2]), {step = to, pitch = hit.pitch + mv[2]})
			end
		end
	end
end)
end
-- vim: set noet ts=4 sw=4:
