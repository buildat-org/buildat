-- Buildat: extensions/luanti_client/res/formspec.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
-- SPDX-License-Identifier: Apache-2.0 OR MIT
--
-- The one copy for both Luanti clients ([LUANTI_SHARED]): the extension
-- runs it from res/, and the luanti module serves it as luanti/formspec.lua.
--
-- Luanti's formspecs, which are the windows a server puts on the screen: the
-- player's inventory, a chest, a furnace, whatever a mod asks for.
--
-- A formspec is a string of elements one after another, each
-- "name[field;field;...]":
--
--   size[8,7.5]list[current_player;main;0,3.5;8,4;]
--
-- A field may hold a position or a size as "x,y". A backslash escapes what
-- would otherwise end a field or an element. container[x,y] shifts everything
-- until the matching container_end[] , which is resolved here so that what
-- comes out is one flat list with absolute positions.
--
-- What is not here is the drawing; parse() only says what the elements are.
-- Nothing in this file knows about Urho3D.

local M = {}

-- Luanti's own coordinate arithmetic, from its gui/guiFormSpecMenu.cpp.
--
-- Everything is in units of one inventory slot, and how many pixels that is
-- comes out of the screen size: the form is made to fit with a twentieth of
-- the screen spare on each side, but never bigger than a fifteenth of the
-- smaller screen dimension per slot.
--
-- Before formspec version 2 the units were not slots but slots plus their
-- spacing, and an element's position had a fixed padding added to it. A form
-- says which it is by its formspec_version, or by real_coordinates[].
M.PADDING = 0.05

-- units_per_px: the screen's units per pixel; density: the display's
-- ([HUD_DENSITY]). Luanti's fixed slot, getFixedImgsize(), is 0.5555 x 96
-- pixels times the density: a fixed_size form's (size[]'s third field)
-- slot, and the least any other form's is. Either is capped to fit the
-- screen, which Luanti's fixed_size is not: an upright phone's form is not
-- wider than it. The slot is whole pixels, as Luanti's imgsize is: in real
-- coordinates everything is placed by it, in the old ones the spacing is
-- of the fraction.
-- simplified: Luanti's gui_scaling taken as 1, and its touch_gui exception
-- (no lock) left out.
function M.layout(size, real_coordinates, screen_w, screen_h, units_per_px,
		density)
	local upp = units_per_px or 1
	local pw = screen_w * (1 - M.PADDING * 2)
	local ph = screen_h * (1 - M.PADDING * 2)
	local fixed = 0.5555 * 96 * (density or 1) * upp
	local prefer = size.fixed and fixed or
			math.max(math.min(screen_w, screen_h) / 15, fixed)
	local function whole(x) return math.floor(x / upp) * upp end
	local imgsize
	if real_coordinates then
		imgsize = whole(math.min(prefer, pw / size[1], ph / size[2]))
		return {
			imgsize = imgsize,
			-- Where an element's x,y lands, and how big its w,h is
			scale = {imgsize, imgsize},
			origin = {0, 0},
			-- One slot of a list, and the step from one to the next
			slot = imgsize,
			slot_step = imgsize * 1.25,
			width = size[1] * imgsize,
			height = size[2] * imgsize,
		}
	end
	local use = math.min(prefer,
			pw / (5 / 4 * (0.5 + size[1])),
			ph / (15 / 13 * (0.85 + size[2])))
	imgsize = whole(use)
	local sx, sy = use * 5 / 4, use * 15 / 13
	local pad = whole(use * 3 / 8)
	return {
		imgsize = imgsize,
		scale = {sx, sy},
		origin = {pad, pad},
		slot = imgsize,
		slot_step = sx,
		width = size[1] * sx + pad * 2,
		height = size[2] * sy + pad * 2,
	}
end

-- What a game's locale/*.tr files said, as translations[domain][key]. The
-- server reads them and sends them; see lua/translations.lua and
-- M.set_translations() below. Empty until they arrive, and empty forever for
-- a game that ships none, in which case all of this is one string find that
-- comes to nothing.
local translations = {}

function M.set_translations(t)
	translations = t or {}
end

-- Luanti's translation markup: the escape character and then either
-- (T@domain) or a bare T, up to a matching (E) or bare E. What lies between
-- is the string as the game wrote it, with (F) ... (E) around each argument
-- -- so the template to look up is that text with the arguments replaced by
-- @1, @2, and the translation is filled back in.
--
-- This is translate_string() in Luanti's src/util/string.cpp.
--
-- simplified: no plural forms. Luanti's marker can carry a number for a
-- language with several, and a .tr file an entry per form; this takes the
-- one entry a file has.
local translate_all

-- One marked string, starting just after its T: the translated text, and
-- where it ended.
local function translate_one(s, at, domain)
	local template = {}
	local args = {}
	while at <= #s do
		local e = string.find(s, "\27", at, true)
		if e == nil then
			template[#template + 1] = string.sub(s, at)
			at = #s + 1
			break
		end
		if e > at then
			-- A literal @ in the text is written twice, so that it is not
			-- taken for an argument when the template is filled back in
			template[#template + 1] =
					string.gsub(string.sub(s, at, e - 1), "@", "@@")
		end
		local rest = string.sub(s, e + 1)
		local body = string.match(rest, "^(%b())")
		local word, after
		if body then
			word = string.match(body, "^%(([^@)]*)") or ""
			after = e + 1 + #body
		else
			word = string.sub(rest, 1, 1)
			after = e + 2
		end
		if word == "E" then
			at = after
			break
		elseif word == "F" then
			local text
			text, at = translate_all(s, after, true)
			args[#args + 1] = text
			template[#template + 1] = "@" .. #args
		else
			-- Somebody else's markup -- a colour -- which belongs to the
			-- text and travels with it
			template[#template + 1] = string.sub(s, e, after - 1)
			at = after
		end
	end
	local key = table.concat(template)
	local out = (translations[domain] and translations[domain][key]) or key
	-- And the arguments back in: "@@" is a literal @ and "@1" is an
	-- argument, which is Luanti's own rule for a translated template
	out = string.gsub(out, "@(.)", function(c)
		if c == "@" then
			return "@"
		end
		local n = tonumber(c)
		if n and args[n] then
			return args[n]
		end
		return "@" .. c
	end)
	return out, at
end

-- Everything from `at` on, stopping at an (E) while reading an argument
translate_all = function(s, at, stop_at_end)
	local out = {}
	while at <= #s do
		local e = string.find(s, "\27", at, true)
		if e == nil then
			out[#out + 1] = string.sub(s, at)
			at = #s + 1
			break
		end
		if e > at then
			out[#out + 1] = string.sub(s, at, e - 1)
		end
		local rest = string.sub(s, e + 1)
		local body = string.match(rest, "^(%b())")
		local word, arg, after
		if body then
			word, arg = string.match(body, "^%(([^@)]*)@?(.-)%)$")
			word = word or ""
			after = e + 1 + #body
		else
			word = string.sub(rest, 1, 1)
			arg = ""
			after = e + 2
		end
		if word == "T" then
			local text
			text, at = translate_one(s, after,
					(arg ~= "" and arg) or nil)
			out[#out + 1] = text
		elseif word == "E" and stop_at_end then
			at = after
			break
		else
			-- Not ours: kept, because the colour markup is read after this
			out[#out + 1] = string.sub(s, e, after - 1)
			at = after
		end
	end
	return table.concat(out), at
end

-- A string with its translation markers resolved and everything else left
-- alone. Cheap for the common case: no escape character, nothing to do.
function M.translate(s)
	s = s or ""
	if string.find(s, "\27", 1, true) == nil then
		return s
	end
	local out = translate_all(s, 1, false)
	return out
end

-- Luanti's translation and colour markup: an escape character, then either
-- (something) or a single letter. The translation markers are resolved
-- first and whatever markup is left is taken out, which for a game with no
-- .tr files is exactly what this always did.
local function strip_escapes(s)
	s = M.translate(s)
	s = s:gsub("\27%b()", "")
	s = s:gsub("\27.", "")
	return s
end

M.strip_escapes = strip_escapes

do
	-- Plain text is untouched; a marked string comes out translated with
	-- its argument where the translation puts it, and untranslated as the
	-- template the game wrote. The example is Luanti's own, out of the
	-- comment on translate_string().
	assert(M.translate("just text") == "just text",
			"translate: plain text is untouched")
	local marked = "\27(T@mymod)\27(F)White\27(E) Wool\27(E)"
	M.set_translations({mymod = {["@1 Wool"] = "villaa @1"}})
	assert(M.translate(marked) == "villaa White",
			"translate: the argument goes where the translation puts it")
	M.set_translations({})
	assert(M.translate(marked) == "White Wool",
			"translate: with no translation the template is the answer")
	assert(strip_escapes("\27(c@red)hi") == "hi",
			"translate: other markup still comes out")
end

-- The colours Luanti's own markup names by word rather than by number.
--
-- simplified: the ones a mod actually writes. Luanti takes the whole CSS
-- list; a name that is not here is drawn in whatever colour the line
-- already had, which is what a client that did not understand it would do.
local COLOR_NAMES = {
	white = "#ffffff", black = "#000000", red = "#ff0000",
	green = "#008000", lime = "#00ff00", blue = "#0000ff",
	yellow = "#ffff00", cyan = "#00ffff", aqua = "#00ffff",
	magenta = "#ff00ff", fuchsia = "#ff00ff", orange = "#ffa500",
	pink = "#ffc0cb", purple = "#800080", brown = "#a52a2a",
	gray = "#808080", grey = "#808080", silver = "#c0c0c0",
	gold = "#ffd700", darkgray = "#a9a9a9", darkgrey = "#a9a9a9",
	lightgray = "#d3d3d3", lightgrey = "#d3d3d3",
}

-- "#rgb", "#rrggbb", "#rrggbbaa" or a name, as three numbers between zero
-- and one; nil for anything else
local function color_of(spec)
	spec = COLOR_NAMES[string.lower(spec or "")] or spec or ""
	local hex = string.match(spec, "^#(%x+)$")
	if hex == nil then
		return nil
	end
	if #hex == 3 or #hex == 4 then
		hex = string.gsub(hex, "(%x)", "%1%1")
	end
	if #hex ~= 6 and #hex ~= 8 then
		return nil
	end
	-- a: the alpha the string gives, nil where it gives none (each element
	-- has its own default, as Luanti's parseColorString)
	return {
		r = tonumber(string.sub(hex, 1, 2), 16) / 255,
		g = tonumber(string.sub(hex, 3, 4), 16) / 255,
		b = tonumber(string.sub(hex, 5, 6), 16) / 255,
		a = #hex == 8 and tonumber(string.sub(hex, 7, 8), 16) / 255 or nil,
	}
end

M.color_of = color_of

-- A line as the pieces it is drawn in: Luanti's own colour markup says where
-- a colour starts and every piece runs until the next one. A string with no
-- markup in it is one piece with no colour of its own, which is the common
-- case and costs one table.
--
-- The escape is \27 and then either (word@argument) or a single letter; a
-- "c" is a colour and a "b" is a background colour, which nothing here
-- draws. What is not markup at all is text.
function M.split_colors(s)
	s = s or ""
	if string.find(s, "\27", 1, true) == nil then
		return {{text = s}}
	end
	-- The translation markers first, so that what is looked up is the
	-- string the game wrote and what is coloured is the answer
	s = M.translate(s)
	if string.find(s, "\27", 1, true) == nil then
		return {{text = s}}
	end
	local out = {}
	local color = nil
	local at = 1
	while at <= #s do
		local e = string.find(s, "\27", at, true)
		if e == nil then
			break
		end
		if e > at then
			out[#out + 1] = {text = string.sub(s, at, e - 1), color = color}
		end
		local rest = string.sub(s, e + 1)
		local body = string.match(rest, "^(%b())")
		if body then
			at = e + 1 + #body
			local word, arg = string.match(body, "^%((%a+)@(.*)%)$")
			if word == "c" then
				color = color_of(arg) or color
			end
		else
			-- A single letter, which is a translation marker and not ours
			at = e + 2
		end
	end
	if at <= #s then
		out[#out + 1] = {text = string.sub(s, at), color = color}
	end
	if #out == 0 then
		out[#out + 1] = {text = ""}
	end
	return out
end

local function unescape(s)
	return (s:gsub("\\(.)", "%1"))
end

M.unescape = unescape

-- Splits on an unescaped separator
local function split(s, sep)
	local parts = {}
	local start = 1
	local i = 1
	while i <= #s do
		local c = s:sub(i, i)
		if c == "\\" then
			i = i + 1
		elseif c == sep then
			parts[#parts + 1] = s:sub(start, i - 1)
			start = i + 1
		end
		i = i + 1
	end
	parts[#parts + 1] = s:sub(start)
	return parts
end

M.split = split

-- "1.5,-2" -> {1.5, -2}, or nil
function M.parse_v2(s)
	local a, b = s:match("^%s*(-?[%d.]+)%s*,%s*(-?[%d.]+)%s*$")
	if not a then
		return nil
	end
	return {tonumber(a), tonumber(b)}
end

-- parse(spec) -> elements, size, real_coordinates
--
-- elements is an array of {name =, fields = {...}, raw = {...}, at = {x, y}},
-- where at is the container offset in force, already added to the element's
-- own position if it has one, and raw is the fields with their escapes still
-- in. size is what size[] said, defaulting to a small window.
function M.parse(spec)
	local elements = {}
	local size = {10, 10}
	local version = 1
	local real = nil
	local offset = {0, 0}
	local stack = {}
	-- Which scroll_container an element is inside, and how many there have
	-- been; nil for the form itself
	local scroll_now = nil
	local scroll_stack = {}
	local scrolls = 0
	local i = 1
	while i <= #spec do
		-- An element is a name, then its fields in brackets
		local name_start = i
		while i <= #spec and spec:sub(i, i) ~= "[" do
			i = i + 1
		end
		if i > #spec then
			break
		end
		-- A formspec a mod built out of lines has whitespace between its
		-- elements, and it belongs to neither of them; Luanti trims the same
		-- way. Without this every element after the first newline is a
		-- name nothing knows and the form comes out empty.
		local name = spec:sub(name_start, i - 1):match("^%s*(.-)%s*$")
		i = i + 1
		local body_start = i
		while i <= #spec do
			local c = spec:sub(i, i)
			if c == "\\" then
				i = i + 1
			elseif c == "]" then
				break
			end
			i = i + 1
		end
		local body = spec:sub(body_start, math.min(i, #spec) - 1)
		i = i + 1

		local fields = split(body, ";")
		-- The fields as they were written as well: a field that is itself a
		-- list -- a table's cells, a dropdown's items -- has to be split on
		-- its commas before the escapes in it are taken out, or a cell with
		-- a comma of its own turns into two
		local raw = {}
		for k, v in ipairs(fields) do
			raw[k] = v
			fields[k] = unescape(v)
		end

		if name == "size" then
			-- size[w,h,fixed_size]: Luanti's own death screen has the third
			-- ([VL_DEATH_FORM]), and true draws the form at a slot size of
			-- its own whatever the screen (M.layout)
			local f = fields[1] or ""
			local v = M.parse_v2((f:gsub(",%s*%a+%s*$", "")))
			if v then
				v.fixed = f:match(",%s*true%s*$") ~= nil
				size = v
			end
		elseif name == "formspec_version" then
			version = tonumber(fields[1]) or 1
		elseif name == "real_coordinates" then
			real = fields[1] == "true"
		elseif name == "__prepend_end" then
			-- What a client put in front of the form from the player's
			-- formspec prepend, which Luanti reads in legacy coordinates
			for _, e in ipairs(elements) do
				e.prepend = true
			end
		elseif name == "container" then
			local v = M.parse_v2(fields[1] or "")
			stack[#stack + 1] = offset
			offset = {offset[1] + (v and v[1] or 0),
					offset[2] + (v and v[2] or 0)}
		elseif name == "container_end" then
			offset = table.remove(stack) or {0, 0}
		elseif name == "scroll_container" then
			-- Like a container, and the element itself is kept: the client
			-- draws a clipped box for it and what is inside rides its
			-- scrollbar ([FORMSPEC_SCROLL]). Everything between this and
			-- its end is marked with the box's number.
			local v = M.parse_v2(fields[1] or "")
			scrolls = scrolls + 1
			elements[#elements + 1] = {
				name = name, fields = fields, raw = raw, at = offset,
				scroll_id = scrolls, scroll = scroll_now,
			}
			stack[#stack + 1] = offset
			scroll_stack[#scroll_stack + 1] = scroll_now
			scroll_now = scrolls
			offset = {offset[1] + (v and v[1] or 0),
					offset[2] + (v and v[2] or 0)}
		elseif name == "scroll_container_end" then
			offset = table.remove(stack) or {0, 0}
			scroll_now = table.remove(scroll_stack)
		else
			elements[#elements + 1] = {
				name = name, fields = fields, raw = raw, at = offset,
				scroll = scroll_now,
			}
		end
	end
	if real == nil then
		real = version >= 2
	end
	return elements, size, real
end

return M
-- vim: set noet ts=4 sw=4:
