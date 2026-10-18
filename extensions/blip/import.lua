-- Buildat: extensions/blip/import.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- **sfxr's and jsfxr's sounds into blip1** ([BLIP]), lossily: their
-- parameters are blip1's by name, and blip1 makes them with the engine's
-- blocks, so the sound is close to theirs and not the same. What has no
-- counterpart is dropped and named.
--   sfs(data)   sfxr's .sfs, its file versions 100 to 102
--   text(s)     jsfxr's link string (the part after "#") or its JSON
--   pasted(s)   [BLIP_IMPORT_DIALOG] the first blip1 string in s (as in
--               blip.play("blip1:...")), else its first sound table
--               (read as data by lua_table, never run), else jsfxr's
--   lua_table(s, at)  the table constructor at s's index at: names,
--               strings, numbers, booleans and tables, nothing else
-- Each -> a blip1 parameter table and the list of what was dropped, or
-- nil and why. Run as a function of the generator:
--   local import = run_extension_file("import.lua")(gen)
return function(G)
local I = {}

local floor = math.floor

-- sfxr squares these, so a negative one (its RANDOMIZE makes them half
-- the time) sounds as its size; the others are clamped as sfxr's own
-- arithmetic clamps them
local SQUARED = {env_attack = true, env_sustain = true, env_decay = true,
	vib_speed = true, lpf_resonance = true, hpf_freq = true,
	base_freq = true}
local SFXR_WAVES = {[0] = "square", "saw", "sine", "noise"}
local KNOWN = {}
for _, d in ipairs(G.PARAMS) do
	KNOWN[d[1]] = true
end

-- values by name onto blip1's defaults; known names only
local function to_params(values, wave_type, dropped)
	local p = G.defaults()
	if wave_type ~= nil then
		p.wave = SFXR_WAVES[wave_type]
		if not p.wave then
			return nil, "wave type " .. tostring(wave_type) ..
					" is none of sfxr's (0 to 3)"
		end
	end
	local t = {}
	for _, d in ipairs(G.PARAMS) do
		local v = values[d[1]]
		if v ~= nil then
			if v ~= v or v == math.huge or v == -math.huge then
				return nil, d[1] .. " is not a finite number"
			end
			if SQUARED[d[1]] then
				v = math.abs(v)
			end
			t[d[1]] = v
		end
	end
	-- Clamped into blip1's ranges by G.params
	for k, v in pairs(G.params(t)) do
		if k ~= "wave" then
			p[k] = v
		end
	end
	return p, dropped
end

-- A little-endian float32 from four bytes
local function float32(b1, b2, b3, b4)
	local sign = b4 >= 128 and -1 or 1
	local e = (b4 % 128) * 2 + floor(b3 / 128)
	local m = (b3 % 128) * 65536 + b2 * 256 + b1
	if e == 255 then
		return m == 0 and sign * math.huge or 0 / 0
	end
	if e == 0 then
		return sign * math.ldexp(m, -149)
	end
	return sign * math.ldexp(m + 8388608, e - 150)
end

-- sfxr's LoadSettings(), field by field
function I.sfs(data)
	if type(data) ~= "string" then
		return nil, "no data"
	end
	local pos = 1
	local function int32()
		local a, b, c, d = data:byte(pos, pos + 3)
		pos = pos + 4
		return ((d % 128) * 16777216 + c * 65536 + b * 256 + a) -
				(d >= 128 and 2147483648 or 0)
	end
	local function float()
		local a, b, c, d = data:byte(pos, pos + 3)
		pos = pos + 4
		return float32(a, b, c, d)
	end
	local version = #data >= 4 and int32()
	local size = ({[100] = 89, [101] = 101, [102] = 105})[version]
	if not size then
		return nil, "not an sfxr sound (file version " .. tostring(version) ..
				", not 100 to 102)"
	end
	if #data < size then
		return nil, "an sfxr sound of version " .. version .. " cut short"
	end
	local v, dropped = {}, {}
	local wave_type = int32()
	v.volume = version == 102 and float() or 0.5
	v.base_freq = float()
	v.freq_limit = float()
	v.freq_ramp = float()
	if version >= 101 then
		v.freq_dramp = float()
	end
	v.duty = float()
	v.duty_ramp = float()
	v.vib_strength = float()
	v.vib_speed = float()
	-- Read and saved by sfxr, used by none of its code
	if float() ~= 0 then
		dropped[#dropped + 1] = "vib_delay"
	end
	v.env_attack = float()
	v.env_sustain = float()
	v.env_decay = float()
	v.env_punch = float()
	pos = pos + 1 -- filter_on, a bool sfxr's synth does not read
	v.lpf_resonance = float()
	v.lpf_freq = float()
	v.lpf_ramp = float()
	v.hpf_freq = float()
	v.hpf_ramp = float()
	v.pha_offset = float()
	v.pha_ramp = float()
	v.repeat_speed = float()
	if version >= 101 then
		v.arp_speed = float()
		v.arp_mod = float()
	end
	return to_params(v, wave_type, dropped)
end

-- jsfxr's base58: the number's digits, most significant first
local B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local B58_INDEX = {}
for i = 1, #B58 do
	B58_INDEX[B58:sub(i, i)] = i - 1
end
local function b58decode(s)
	local d = {} -- base 256, least significant first
	local zeros = 0
	for i = 1, #s do
		local c = B58_INDEX[s:sub(i, i)]
		if not c then
			return nil
		end
		if c == 0 and #d == 0 and zeros == i - 1 then
			zeros = zeros + 1
		end
		local carry = c
		for j = 1, #d do
			carry = d[j] * 58 + carry
			d[j] = carry % 256
			carry = floor(carry / 256)
		end
		while carry > 0 do
			d[#d + 1] = carry % 256
			carry = floor(carry / 256)
		end
	end
	local out = {}
	for _ = 1, zeros do
		out[#out + 1] = 0
	end
	for j = #d, 1, -1 do
		out[#out + 1] = d[j]
	end
	return out
end

-- jsfxr's params_order: the wave's byte, then each parameter's float
-- (blip1's own order, which is jsfxr's)
local function from_b58(s)
	local bytes = b58decode(s)
	local n = G.SFXR_PARAMS - 1 -- sfxr's, all but the volume
	if not bytes or #bytes ~= 1 + 4 * n then
		return nil, "not a jsfxr link string"
	end
	local v = {}
	for i = 1, n do
		local o = 1 + (i - 1) * 4 + 1
		v[G.PARAMS[i][1]] = float32(bytes[o], bytes[o + 1], bytes[o + 2],
				bytes[o + 3])
	end
	return to_params(v, bytes[1], {})
end

-- jsfxr's JSON: one flat object
-- simplified: its shape only, {"name": number, boolean or string, ...};
-- a nested value is refused. A JSON parser is the upgrade if jsfxr's
-- format grows one.
local function from_json(s)
	local body = s:match("^%s*{(.*)}%s*$")
	if not body or body:find("[{%[]") then
		return nil, "not jsfxr's JSON"
	end
	local v, dropped, wave_type = {}, {}, nil
	for key, value in body:gmatch('"([^"]*)"%s*:%s*([^,]*)') do
		value = value:match("^%s*(.-)%s*$")
		local num = tonumber(value)
		local name = key:match("^p_(.+)$")
		if key == "wave_type" and num then
			wave_type = num
		elseif key == "sound_vol" and num then
			v.volume = num
		elseif key == "oldParams" then
			-- jsfxr's own marker of this shape
		elseif name and num and KNOWN[name] then
			v[name] = num
		else
			dropped[#dropped + 1] = key
		end
	end
	if wave_type == nil then
		return nil, "jsfxr's JSON with no wave_type"
	end
	return to_params(v, wave_type, dropped)
end

function I.text(s)
	if type(s) ~= "string" then
		return nil, "no text"
	end
	s = s:match("^%s*(.-)%s*$")
	if s:sub(1, 1) == "{" then
		return from_json(s)
	end
	return from_b58(s:match("#(.*)$") or s)
end

-- A table constructor read as data: -> the table and the index after
-- it, or nil and why. No calls, no operators but a number's minus
local ESCAPES = {n = "\n", t = "\t", r = "\r", a = "\a", b = "\b",
	f = "\f", v = "\v", ["\\"] = "\\", ['"'] = '"', ["'"] = "'",
	["\n"] = "\n"}
function I.lua_table(s, at)
	local i = at or 1
	local function skip()
		while true do
			local _, e = s:find("^%s+", i)
			if e then i = e + 1 end
			if s:sub(i, i + 1) ~= "--" then
				return
			end
			i = (s:find("\n", i, true) or #s) + 1
		end
	end
	local value
	local function str()
		local q, out = s:sub(i, i), {}
		i = i + 1
		while i <= #s do
			local c = s:sub(i, i)
			if c == q then
				i = i + 1
				return table.concat(out)
			elseif c == "\\" then
				local n = s:sub(i + 1, i + 1)
				local digits = s:match("^%d%d?%d?", i + 1)
				if digits then
					out[#out + 1] = string.char(tonumber(digits) % 256)
					i = i + 1 + #digits
				elseif ESCAPES[n] then
					out[#out + 1] = ESCAPES[n]
					i = i + 2
				else
					error("an escape \\" .. n .. " at " .. i, 0)
				end
			elseif c == "\n" then
				break
			else
				out[#out + 1] = c
				i = i + 1
			end
		end
		error("a string not closed", 0)
	end
	local function tbl()
		local t, n = {}, 0
		i = i + 1
		while true do
			skip()
			if s:sub(i, i) == "}" then
				i = i + 1
				return t
			end
			local key
			local name, e = s:match("^([%a_][%w_]*)%s*=()", i)
			if name and s:sub(e, e) ~= "=" then
				key, i = name, e
			elseif s:sub(i, i) == "[" then
				i = i + 1
				skip()
				key = value()
				skip()
				local e2 = s:match("^%]%s*=()", i)
				if not e2 or s:sub(e2, e2) == "=" then
					error("a key's ] = expected at " .. i, 0)
				end
				i = e2
			end
			skip()
			local v = value()
			if key == nil then
				n = n + 1
				key = n
			end
			t[key] = v
			skip()
			local c = s:sub(i, i)
			if c == "," or c == ";" then
				i = i + 1
			elseif c ~= "}" then
				error(", or } expected at " .. i, 0)
			end
		end
	end
	function value()
		local c = s:sub(i, i)
		if c == "{" then
			return tbl()
		elseif c == '"' or c == "'" then
			return str()
		end
		local num = s:match("^-?%s*0[xX]%x+", i) or
				s:match("^-?%s*%d*%.?%d+[eE][-+]?%d+", i) or
				s:match("^-?%s*%d+%.?%d*", i) or s:match("^-?%s*%.%d+", i)
		if num then
			i = i + #num
			return tonumber((num:gsub("%s", "")))
		end
		local word = s:match("^[%a_][%w_]*", i)
		if word == "true" or word == "false" then
			i = i + #word
			return word == "true"
		end
		error("a value expected at " .. i .. (word and (", not " .. word) or ""), 0)
	end
	skip()
	if s:sub(i, i) ~= "{" then
		return nil, "no { at " .. i
	end
	local ok, t = pcall(tbl)
	if not ok then
		return nil, t
	end
	return t, i
end

function I.pasted(s)
	if type(s) ~= "string" then
		return nil, "no text"
	end
	local b = s:match("blip1:[%w%-_+]+")
	if b then
		local ok, p = pcall(G.params, b)
		if not ok then
			return nil, "not a blip1 sound: " .. tostring(p)
		end
		return p, {}, "blip1"
	end
	local why = {}
	local start = s:find("{", 1, true)
	if start then
		local t, err = I.lua_table(s, start)
		if t then
			local ok, p = pcall(G.params, t)
			if ok then
				return p, {}, "a sound table"
			end
			err = tostring(p)
		end
		why[#why + 1] = "not a sound table: " .. err
	end
	local p, dropped = I.text(s)
	if p then
		return p, dropped, "jsfxr"
	end
	why[#why + 1] = "not jsfxr's: " .. tostring(dropped)
	return nil, table.concat(why, "; ")
end

return I
end
-- vim: set noet ts=4 sw=4:
