-- extensions/blip/test/gen_test.lua: blip1's formats and the imports, in
-- plain Lua (no client, no synth):
--   luajit extensions/blip/test/gen_test.lua   (from the tree's root)
-- The sfxr and jsfxr files here were written by their own code
-- (README.txt); each must decode to the values it was saved with and map
-- to the blip1 string committed beside it.
local dir = "extensions/blip/"
local G = dofile(dir .. "blip_gen.lua")
local I = dofile(dir .. "import.lua")(G)

local function read(name)
	local f = assert(io.open(dir .. "test/" .. name, "rb"))
	local d = f:read("*a")
	f:close()
	return d
end
local function near(a, b)
	return math.abs(a - b) < 1e-6
end
local function check_values(what, p, want)
	for k, v in pairs(want) do
		if k == "wave" then
			assert(p.wave == v, what .. ": wave " .. tostring(p.wave))
		else
			assert(near(p[k], v), what .. ": " .. k .. " " .. tostring(p[k]) ..
					", saved " .. v)
		end
	end
end

-- What the fixtures were saved with (README.txt)
local SFXR = {wave = "saw", volume = 0.35, base_freq = 0.42,
	freq_limit = 0.12, freq_ramp = -0.21, freq_dramp = 0.03, duty = 0.3,
	duty_ramp = -0.1, vib_strength = 0.25, vib_speed = 0.4,
	env_attack = 0.05, env_sustain = 0.2, env_decay = 0.35, env_punch = 0.4,
	lpf_resonance = 0.3, lpf_freq = 0.8, lpf_ramp = -0.05, hpf_freq = 0.1,
	hpf_ramp = 0.02, pha_offset = 0.15, pha_ramp = -0.05, repeat_speed = 0,
	arp_speed = 0.6, arp_mod = 0.35}
local JSFXR = {wave = "sine", env_attack = 0.1, env_sustain = 0.25,
	env_punch = 0.2, env_decay = 0.3, base_freq = 0.55, freq_limit = 0,
	freq_ramp = 0.1, freq_dramp = -0.02, vib_strength = 0.1,
	vib_speed = 0.3, arp_mod = -0.4, arp_speed = 0.7, duty = 0.2,
	duty_ramp = 0.05, repeat_speed = 0.2, pha_offset = -0.1, pha_ramp = 0.1,
	lpf_freq = 0.9, lpf_ramp = 0.01, lpf_resonance = 0.2, hpf_freq = 0.05,
	hpf_ramp = -0.01}
-- And the blip1 each maps to
local WANT = {
	sfxr_v100 = "blip1:BDNMzZmWZa4HrZRf_QAZmf_AATNcyAAkyeZzMeZTNGagogAAAAA",
	sfxr_v101 = "blip1:BDNMzZmWZa4HrZRg8QAZmrLmZTNcyAAkyeZzMeZTNGagogAAAAA",
	sfxr_v102 = "blip1:BDNMzZmWZa4HrZRg8QAZmrLmZTNcyAAkyeZzMeZTNGagoWZAAAA",
	jsfxr_link = "blip1:CGZQAMzTMjMAAjMfWGZTMTMsyMzhlMzcyjM5lgTMzDNfrgAAAAA",
	jsfxr_json = "blip1:CGaQAMzTNjMAAjMfWGaTNTMszMzhlMzcyjM5mgTMzDNfrTNAAAA",
}
local bad = 0
local function compare(name, p)
	local s = G.pack(p)
	if s ~= WANT[name] then
		print(name .. " maps to " .. s .. ", not " .. WANT[name])
		bad = bad + 1
	end
end

for v = 100, 102 do
	local name = "sfxr_v" .. v
	local p, dropped = I.sfs(read(name .. ".sfs"))
	assert(p, name .. ": " .. tostring(dropped))
	local want = {}
	for k, x in pairs(SFXR) do
		want[k] = x
	end
	-- What a version before 102 lacks is sfxr's default
	if v < 102 then want.volume = 0.5 end
	if v < 101 then want.freq_dramp, want.arp_speed, want.arp_mod = 0, 0, 0 end
	check_values(name, p, want)
	assert(#dropped == 0, name .. " dropped " .. table.concat(dropped, ", "))
	compare(name, p)
end
local link, json = read("jsfxr.txt"):match("^(%S+)\n(%b{})")
local p = assert(I.text("https://sfxr.me/#" .. link))
check_values("jsfxr link", p, JSFXR)
compare("jsfxr_link", p)
local dropped
p, dropped = I.text(json)
assert(p, dropped)
local want = {volume = 0.3}
for k, x in pairs(JSFXR) do
	want[k] = x
end
check_values("jsfxr JSON", p, want)
table.sort(dropped)
assert(table.concat(dropped, ",") == "sample_rate,sample_size",
		"jsfxr JSON dropped " .. table.concat(dropped, ","))
compare("jsfxr_json", p)

-- Refusals, each with its reason
assert(not I.sfs("abcd"), "a short file")
assert(not I.text("0OIl"), "not base58")
assert(not I.text('{"wave_type": 9}'), "wave 9")
assert(not pcall(G.params, "blip2:x"), "blip2")
assert(not pcall(G.params, {nope = 1}), "an unknown field")
assert(not pcall(G.params, {wave = "organ"}), "an unknown wave")

-- The forms: the compact one round-trips; both = compact plus a table
for i, name in ipairs(G.PRESETS) do
	local q = G.preset(name, i)
	local s = G.pack(q)
	assert(G.pack(G.params(s)) == s, name .. " does not round-trip")
	local both = G.params({s, volume = 0.25})
	assert(both.volume == 0.25 and both.base_freq == G.params(s).base_freq)
	local n, calls = G.chain(q, 44100)
	assert(n >= 1 and #calls >= 2, name .. "'s chain")
end
assert(G.pack(G.defaults()):sub(1, 6) == "blip1:")

-- The layers and the parameters beyond sfxr's: the table form reads back
-- as the same sound, and a sound with neither packs as blip1 did
for _, name in ipairs({"crunch", "snort", "pluck", "rattle", "chime"}) do
	local q = G.preset(name, 3)
	local t = assert(loadstring("return " .. G.table_source(G.to_table(q))))()
	assert(G.pack(G.params(t)) == G.pack(q), name .. "'s table form")
end
local old = WANT.sfxr_v102
assert(#old == 57 and G.pack(G.params(old)) == old, "a blip1 string of 57")
local two = old .. "+Ay" .. old:sub(7)
local q = G.params(two)
assert(#q.layers == 1 and q.layers[1].at == 0.05 and G.pack(q) == two,
		"two layers")
q = G.params({old, pluck = 0.5})
assert(#G.pack(q) == 57 + 8 and G.params(G.pack(q)).pluck > 0.49, "pluck")
assert(not pcall(G.params, old .. "+A"), "a layer cut short")
assert(not pcall(G.params, {layers = {two}}), "a layer with layers")
-- A variant: every layer nudged, its own noise, the layers' times kept
local r = G.preset("rattle", 3)
local v = G.vary(r, 2, 0.3)
assert(v.seed ~= r.seed and #v.layers == #r.layers and
		v.layers[1].at == r.layers[1].at and
		v.layers[1].seed ~= r.layers[1].seed, "a variant's layers")
assert(G.pack(G.vary(r, 2, 0.3)) == G.pack(v), "a variant is the same twice")
local same = G.vary(r, 5, 0)
assert(same.base_freq == r.base_freq and same.seed ~= r.seed, "no nudge")

-- [BLIP_IMPORT_DIALOG] What the Import dialog reads
local user = "blip1:DKQJcEhPmjsAAWJdHAAg0gzGkFVgRAAgZoMLf7dwZLFd8gAfstafl1sAAAA"
local got, _, from = I.pasted('blip.play("' .. user .. '")\n')
assert(got and from == "blip1" and G.pack(got) == user, "the user's paste")
-- Copy's table form of a sound of layers, comments and all
local src = "-- a sound\nlocal s = " .. G.table_source(G.to_table(r)) ..
		"\nblip.play(s)"
got, _, from = I.pasted(src)
assert(got and from == "a sound table" and G.pack(got) == G.pack(r),
		"the table form of layers: " .. tostring(got and G.pack(got) or _))
local t = assert(I.lua_table([[{1, -2.5, 0x10, 1e-3, "a\"b\65", [ "k" ] = true;
	n = {x = false}, }]]))
assert(t[1] == 1 and t[2] == -2.5 and t[3] == 16 and t[4] == 0.001 and
		t[5] == 'a"bA' and t.k == true and t.n.x == false, "the table reader")
-- Never run: a call is refused, and nothing ran
local ran = false
_G.blip_import_ran = function() ran = true end
for _, evil in ipairs({'{wave = "sine", os.exit()}',
		"{wave = blip_import_ran()}", "{x = 1 + 1}", '{wave = ("sine")}'}) do
	local q, why = I.pasted(evil)
	assert(not q and why:find("not a sound table"), evil .. ": " .. tostring(why))
end
assert(not ran, "a pasted call ran")
-- jsfxr's JSON as import.text reads it
assert(G.pack(assert(I.pasted(json))) == G.pack(assert(I.text(json))), "jsfxr's JSON")
assert(not I.pasted("nothing here"), "nothing")

if bad > 0 then
	print("FAIL: " .. bad .. " mapped to another blip1")
	os.exit(1)
end
print("PASS: sfxr 100-102 and jsfxr's link and JSON decode and map; " ..
		"the forms round-trip, layers and all; a paste reads, a call is refused")
-- vim: set noet ts=4 sw=4:
