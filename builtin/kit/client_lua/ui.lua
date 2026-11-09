-- Buildat: builtin/kit/client_lua/ui.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2026 Perttu Ahola <celeron55@gmail.com>
--
-- [KIT_UI_COMPONENTS] (stage 4m) UI as screen-space components: an
-- entity whose type has a `ui` (builtin/kit/api.h; kit/ui_text, ui_bar,
-- ui_button, ui_panel) is drawn on this player's screen from its node's
-- "kit_show" ui (its parameters) and its state: `shown` and `value`,
-- everyone's, under this player's own ("own", a per_player state the
-- server sends only to them, "kit:mine"). module.lua runs it after the
-- editor and the controls.
--   **Layout**: `anchor` (top_left, top, top_right, left, center, right,
--   bottom_left, bottom, bottom_right), also the element's own reference
--   point, and x, y in from it (from the centre: right and down), in the
--   UI root (the client's UI fit scales it) or in its parent panel's box; kept
--   inside the box it is in, so nothing goes off a narrow screen. On a
--   touchscreen a bottom anchor is above Kit's touch bars
--   (kit.touch_bar_top()).
--   [KIT_HUD_STYLE] **Units**: x, y, width, height, size and gap in percent
--   of the root's shorter side (CSS's vmin), in a panel too (a panel
--   resized does not distort its contents, copy style works across); a
--   text's size rounded to whole pixels as drawn. width or height 0: from
--   its contents, or a bar's or a pie's own default.
--   `order`: over or under overlapping elements (a ui_text over a ui_bar);
--   a panel still over the rest.
--   **Styles** (`style`): "plain", text alone, a flat track and fill or a
--   flat panel (Urho's style on a button), and "shapes" (the default): a
--   background and a border (`background`, `border`, each #rrggbb,
--   #rrggbbaa or "none") and for a bar its fill (`color`), running by
--   `direction`; `form` "pie" a disc, the fill and a ring instead, one
--   BorderImage each with its image rect in kit/hud_atlas.png
--   (util/kit_hud_atlas.py; the cell floor(f * 32)), tinted. A label wider
--   than its shape shrinks down to 8 pixels, then is clipped; no wrapping
--   inside a bar. `blink_below` (a fraction of a bar's range, 0 off) blinks
--   it. In a text: {value}, {value:time} (m:ss), {value:int} (none yet: 0).
--   **Stacking**: a panel's `layout` "column" or "row" stacks its shown
--   children by order (then id) with its `gap`, a hidden one leaving no
--   gap, their x and y unused; a width or height of 0 fits it to them and
--   with nothing shown and no title it is not drawn. Across a column they
--   go by the panel's anchor's side.
--   **Play**: shown while the server is Running and this player is out of
--   the tools (Stopped, the components do not run: none shown); a button's press is the action's (kit.press_action) or
--   "kit:ui" "<id> 1|0", the server checking it is on this player's
--   screen; while a panel with a button is up the pointer is free
--   (ui_utils.wants_clicks) for a player in mouse look. [KIT_TEXT_INPUT]
--   An input (kit/ui_input) is a label and a LineEdit named
--   "kit input <id>", its Enter "kit:ui_text" "<id> <text>"; in a panel
--   it frees the pointer as a button does.
--   **Edit mode**: every one drawn where it would be (one hidden dimmed),
--   framed (the selected one in kit.HOVER) with its id; a click selects
--   it, a drag moves it (its x and y set, one edit each) in whole percents
--   or onto another's (or the screen's) edge or centre within 1 percent;
--   the selected one's handles (right edge, bottom edge, corner) set its
--   width and height, its top left staying where it is.
--   **Kit's own HUD** (the rules' "hud" in "kit:slots": kit/game_rules'
--   health_*, hotbar_*, feed_*, hint_*, item_line_*): the health bar drawn
--   here as a ui_bar of `source` "health" (unless a placed one is up), the
--   others placed by kit.own_place() and framed and dragged here in edit
--   mode, written to kit/game_rules (placed on the root if there is none).
-- The text a builder wrote is drawn as plain text (a Text element: no
-- markup), its {value} the signal's value cut at 200 characters.
--   kit.ui_at(x, y) -> whether the pointer (pixels) is on a UI component
--     that takes clicks (a button or a panel with a background in play;
--     any in edit mode), which the controls and the editor leave alone
-- [KIT_HUD_STYLE] **The character sheet** (the textures style, a later
-- stage, draws numbers from it): one image of 4 x 5 equal cells, left to
-- right from the top: 0 1 2 3 / 4 5 6 7 / 8 9 : "/" / % - . , / and 4 cells
-- reserved for characters missed. No letters: labels stay in the font.
return function(K)
local M, E, P = K.M, K.E, K.P
local magic = require("buildat/extension/urho3d")
local ui_utils = require("buildat/extension/ui_utils")
local network = require("buildat/extension/network")
local log = K.log
local TOUCH = buildat.get_env("BUILDAT_TOUCH") == "1"
local WEB = buildat.get_env("BUILDAT_PAGE_HTTPS") ~= nil
local FONT = buildat.font_sans
local PIE_STEPS = 32

-- id -> {kind, raw (its ui's JSON), ui, el, t, parts, edge, parent, log};
-- Kit's own HUD under "own:<name>"
local U = {}
-- [id][key] = this player's own of a per_player state
local mine = {}
-- Up while a panel with a button is (the pointer freed): an element of
-- its own, so edit mode's overlay never counts
local want = magic.ui.root:CreateChild("UIElement")
want.visible = false
ui_utils.wants_clicks(want)
local drag = nil
local bars_at = nil
-- The selected element of Kit's own HUD (with kit/game_rules selected)
local own_sel = nil

buildat.sub_packet("kit:mine", function(data)
	local m = network.parse_json(data)
	if type(m) ~= "table" then
		return
	end
	if m.all then
		mine = {}
	end
	for _, o in ipairs(type(m.list) == "table" and m.list or {}) do
		local id = tonumber(o.id)
		if id and type(o.key) == "string" then
			mine[id] = mine[id] or {}
			mine[id][o.key] = o.value
		end
	end
end)

-- light: added to each channel and the alpha (a pointer over a button)
local function color(hex, fallback, light)
	local r, g, b, a = tostring(hex):match("^#(%x%x)(%x%x)(%x%x)(%x?%x?)$")
	if not r then
		return fallback
	end
	local k = light or 0
	return magic.Color(tonumber(r, 16) / 255 + k, tonumber(g, 16) / 255 + k,
			tonumber(b, 16) / 255 + k,
			math.min(1, (#a == 2 and tonumber(a, 16) / 255 or 1) + k))
end

local function num(v, d, lo, hi)
	v = tonumber(v) or d
	return math.max(lo, math.min(hi, v))
end

-- [KIT_SIGNALS_VIEW] The box the HUD is laid out in (screen UI units): the
-- Signals view's viewport with a HUD element selected, else the root
local function hud_box()
	local a = M.hud_area and M.hud_area()
	if a then
		return a.x, a.y, a.w, a.h
	end
	local r = magic.ui.root
	return 0, 0, r.width, r.height
end

-- One percent of the box's shorter side (the root's, CSS's vmin), in UI units
local function vmin()
	local _, _, w, h = hud_box()
	return math.min(w, h) / 100
end

local function pad_of(V)
	return math.max(3, math.floor(0.55 * V + 0.5))
end

-- The least a text is drawn at, in UI units: 8 pixels on the screen
local function min_text()
	return math.ceil(8 / magic.ui.scale)
end

-- The state as this player sees it: theirs over everyone's
local function state(n, id, key)
	local own = mine[id] and mine[id].own
	if type(own) == "table" and own[key] ~= nil then
		return own[key]
	end
	local v = n.node:GetVar("kit:" .. key)
	if v:IsEmpty() then
		return nil
	end
	return network.parse_json(v:GetString())
end

local function shown_text(s, value)
	local v = value
	if type(v) == "table" then
		v = network.write_json(v)
	end
	local n = tonumber(v)
	v = tostring(v == nil and "" or v):sub(1, 200)
	s = tostring(s or ""):gsub("{value:time}", function()
		if not n then
			return v
		end
		local t = math.max(0, math.floor(n + 0.5))
		return string.format("%d:%02d", math.floor(t / 60), t % 60)
	end):gsub("{value:int}", function()
		-- ([KIT_SHIP] none yet, a count before its first: 0)
		return n and string.format("%.0f", n) or (v == "" and "0" or v)
	end):gsub("{value}", function() return v end)
	return M.key_text((s:gsub("|", "\n")))
end

local function drop(r)
	if r.el then
		pcall(function() r.el:Remove() end)
	end
	r.el, r.t, r.parts, r.edge, r.px, r.wrap = nil, nil, nil, nil, nil, nil
	r.rows = nil
	if r.mark then
		r.mark:Remove()
		r.mark = nil
	end
	r.geom, r.step, r.over = nil, nil, nil
end

-- A layer of a shape: over those of a lower z, under the text (5)
local function part(r, z, col)
	local b = r.el:CreateChild("BorderImage")
	b.priority = z
	b.blendMode = magic.BLEND_ALPHA
	b.color = col
	return b
end

local ATLAS = nil
local function atlas()
	ATLAS = ATLAS or magic.cache:GetResource("Texture2D", "kit/hud_atlas.png")
	return ATLAS
end

-- The atlas's cell: index 0..31 the pie's steps 1..32, 32 the ring
local function cell(i)
	local x, y = (i % 8) * 128, math.floor(i / 8) * 128
	return magic.IntRect(x, y, x + 128, y + 128)
end
local function atlas_part(r, z, col, i)
	local b = part(r, z, col)
	b.texture = atlas()
	b.imageRect = cell(i)
	return b
end

local function make(r, id, parent, in_panel)
	local u, el = r.ui, nil
	r.host = parent
	local shapes = u.style ~= "plain"
	if u.kind == "button" then
		el = parent:CreateChild("Button")
		if shapes then
			el.color = magic.Color(0, 0, 0, 0)
		else
			el.defaultStyle = K.STYLE
			el:SetStyleAuto()
		end
		magic.SubscribeToEvent(el, "Pressed", function()
			r.press(true)
		end)
		magic.SubscribeToEvent(el, "Released", function()
			r.press(false)
		end)
	else
		el = parent:CreateChild("BorderImage")
		el.blendMode = magic.BLEND_ALPHA
		el.color = magic.Color(0, 0, 0, 0)
	end
	-- Under the editor's panels (-1); a panel over the rest; in a panel, over
	-- its background
	local order = num(u.order, 0, -40, 40)
	el.priority = math.floor(in_panel and 60 + order or
			u.kind == "panel" and -100 + order or -1000 + order)
	el.bringToFront = false
	r.el = el
	r.parts = {}
	local p = r.parts
	local fill_col = color(u.color, u.source == "health" and
			magic.Color(0.85, 0.15, 0.15) or magic.Color(0.13, 0.78, 0.88))
	r.pie = shapes and u.kind == "bar" and u.form == "pie"
	if r.pie then
		local bg, line = color(u.background, nil), color(u.border, nil)
		p.disc = bg and atlas_part(r, 1, bg, PIE_STEPS - 1)
		p.fill = atlas_part(r, 2, fill_col, PIE_STEPS - 1)
		p.ring = line and atlas_part(r, 3, line, PIE_STEPS)
	elseif shapes and u.kind ~= "own" then
		local bg, line = color(u.background, nil), color(u.border, nil)
		p.bg = bg and part(r, 1, bg)
		if u.kind == "bar" then
			p.fill = part(r, 2, fill_col)
		end
		if line then
			p.line = {part(r, 3, line), part(r, 3, line), part(r, 3, line),
				part(r, 3, line)}
		end
	elseif u.kind == "bar" then
		p.bg = part(r, 1, magic.Color(0.1, 0.1, 0.12))
		p.fill = part(r, 2, fill_col)
	elseif u.kind == "panel" then
		local bg = color(u.background, nil)
		p.bg = bg and part(r, 1, bg)
	end
	r.has_bg = (p.bg or p.disc) and true or false
	-- A fitted label cut at the shape's edge
	el.clipChildren = u.kind == "bar" or u.kind == "button" or u.kind == "input" or
			(u.kind == "text" and num(u.width, 0, 0, 400) > 0)
	-- [KIT_TEXT_INPUT] An input's field (a focused LineEdit gets the IME and,
	-- on the web, the page's text input): Enter sends its line
	-- ("kit:ui_text" "<id> <text>"), empties it and gives the keys back
	if u.kind == "input" then
		local f = el:CreateChild("LineEdit")
		f.defaultStyle = K.STYLE
		f:SetStyleAuto()
		f.priority = 6
		f:SetName("kit input " .. id)
		f.maxLength = math.floor(num(u.max_length, 100, 1, 200))
		r.edit = f
		magic.SubscribeToEvent(f, "TextFinished", function()
			local s = f.text
			f.text = ""
			magic.ui:SetFocusElement(nil)
			if E.editing or s == "" then
				return
			end
			buildat.send_packet("kit:ui_text", id .. " " .. s)
			log:info("kit: ui input " .. id .. " entered (" .. #s .. " bytes)")
		end)
	end
	r.t = el:CreateChild("Text")
	r.t.priority = 5
	r.t:SetTextEffect(magic.TE_SHADOW)
	local a = tostring(u.anchor or "")
	r.t:SetTextAlignment(u.kind == "text" and (a:find("left") and magic.HA_LEFT or
			a:find("right") and magic.HA_RIGHT) or magic.HA_CENTER)
	if u.kind ~= "bar" and u.kind ~= "own" then
		r.t:SetColor(color(u.color, magic.Color(1, 1, 1)))
	end
	-- Edit mode's frame: four bars
	r.edge = {}
	for i = 1, 4 do
		local b = el:CreateChild("BorderImage")
		b.priority = 10
		b.visible = false
		r.edge[i] = b
	end
	el.enabled = true
	r.press = function(down)
		if E.editing then
			return
		end
		local a = tostring(u.action or "")
		if a ~= "" then
			M.press_action(a, down)
		else
			buildat.send_packet("kit:ui", id .. (down and " 1" or " 0"))
		end
		if down then
			log:info("kit: ui button " .. id .. " pressed" ..
					(a ~= "" and " (action " .. a .. ")" or ""))
		end
	end
end

-- Where an element of w x h goes in a box of pw x ph by its anchor and
-- x, y: kept in the box. lift: the bottom's room taken (touch bars)
local function place(u, w, h, pw, ph, lift, V)
	local a = tostring(u.anchor or "top_left")
	local x, y = num(u.x, 0, -400, 400) * V, num(u.y, 0, -400, 400) * V
	local px, py
	if a:find("left") then
		px = x
	elseif a:find("right") then
		px = pw - w - x
	else
		px = (pw - w) / 2 + x
	end
	if a:find("top") then
		py = y
	elseif a:find("bottom") then
		py = ph - h - y
		if lift > 0 then
			py = math.min(py, ph - lift - h - 4)
		end
	else
		py = (ph - h) / 2 + y
	end
	px = math.max(0, math.min(pw - w, px))
	py = math.max(0, math.min(ph - h, py))
	return math.floor(px), math.floor(py)
end

-- What x, y (in percents, to 0.01) put it at px, py (a drag's end).
-- simplified: a bottom one as if no touch bars lifted it
local function from_place(u, w, h, pw, ph, px, py, V)
	local a = tostring(u.anchor or "top_left")
	local x, y
	if a:find("left") then
		x = px
	elseif a:find("right") then
		x = pw - w - px
	else
		x = px - (pw - w) / 2
	end
	if a:find("top") then
		y = py
	elseif a:find("bottom") then
		y = ph - h - py
	else
		y = py - (ph - h) / 2
	end
	return math.floor(x / V * 100 + 0.5) / 100,
			math.floor(y / V * 100 + 0.5) / 100
end

-- [KIT_PANEL_PARENT] The panel it is in: its parent, if a panel (the server
-- says, in the ui's look: a player's state has no parents)
local function panel_of(r)
	local p = tonumber(r.ui.panel) or 0
	return p >= 1 and math.floor(p) or nil
end

-- ---- Kit's own HUD: its placement from kit/game_rules ("kit:slots")
local OWN_KEYS = {health = {"style", "form", "direction", "label", "color",
	"background", "border", "size", "blink_below", "anchor", "x", "y", "width",
	"height", "order"}, hotbar = {"anchor", "x", "y"}, feed = {"anchor", "x",
	"y"}, hint = {"anchor", "x", "y"}, item_line = {"anchor", "x", "y"}}
local OWN_LABEL = {hotbar = "Hotbar", feed = "Kill feed", hint =
	"Spectate hint", item_line = "Item line"}
local OWN_ANCHOR = {health = "bottom", hotbar = "bottom", feed = "top_right",
	hint = "bottom", item_line = "bottom"}
-- A frame's size, percent (the hotbar's by its slots)
local OWN_SIZE = {feed = {24, 7}, hint = {44, 3}, item_line = {30, 2.4}}

local function hud_rules()
	local h = M.game_rule and M.game_rule("hud")
	return type(h) == "table" and h or nil
end

local function own_ui(name)
	local h, u = hud_rules() or {}, {}
	for _, k in ipairs(OWN_KEYS[name]) do
		u[k] = h[name .. "_" .. k]
	end
	u.anchor = u.anchor or OWN_ANCHOR[name]
	if name == "health" then
		u.kind, u.source, u.text = "bar", "health", u.label
	else
		u.kind, u.text = "own", OWN_LABEL[name]
		local s = OWN_SIZE[name]
		u.width = s and s[1]
		u.height = s and s[2]
	end
	return u
end

-- A hotbar slot's square with its gap: in percents like the rest, no less
-- than a pointer (a finger) can pick
function M.hud_unit()
	return math.max(TOUCH and 44 or 30, math.floor(4.1 * vmin()))
end

-- Where one of Kit's own of w x h goes on the screen (UI units)
-- The room a finger's bars take at the bottom, and for what stands on the
-- hotbar there the hotbar's too: its unit is a finger's, not its percents.
-- simplified: by the default order, hotbar, item line, health, hint, as far
-- as they were dragged or not
local function own_lift(name, V)
	local r = magic.ui.root
	local top = TOUCH and M.touch_bar_top and M.touch_bar_top()
	if not top or (M.hud_area and M.hud_area()) then
		return 0
	end
	local lift = math.max(0, r.height - top)
	local line = math.max(16, 2.4 * V)
	local over = name == "item_line" and 1 or name == "health" and 2 or
			name == "hint" and 3 or nil
	return over and lift + M.hud_unit() + 4 + (over - 1) * (line + 4) or lift
end

function M.own_place(name, w, h)
	local bx, by, bw, bh = hud_box()
	local V = vmin()
	local x, y = place(own_ui(name), w, h, bw, bh, own_lift(name, V), V)
	return x + bx, y + by
end

-- A Text of Kit's own placed by its rules, its font `pct` percent
local own_px = {}
function M.own_place_text(t, name, pct)
	local px = math.max(min_text(), math.floor(pct * vmin() + 0.5))
	if own_px[name] ~= px then
		own_px[name] = px
		t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), px)
	end
	local a = tostring(own_ui(name).anchor)
	t:SetAlignment(magic.HA_LEFT, magic.VA_TOP)
	t:SetTextAlignment(a:find("left") and magic.HA_LEFT or a:find("right") and
			magic.HA_RIGHT or magic.HA_CENTER)
	local x, y = M.own_place(name, t.minWidth, t.height)
	t:SetPosition(x, y)
end

-- The parameters of an element written: an entity's own, or kit/game_rules'
-- for Kit's own HUD (the scene's over the root's; a new one on the root the
-- first time, the edits following once the state has it)
local rules_wait = nil
local function set_params(r, list)
	local prefix = r.own and r.own .. "_" or tostring(r.ui.prefix or "")
	if not r.own then
		for _, kv in ipairs(list) do
			K.send({op = "set", id = r.id, comp = r.comp, param = prefix .. kv[1],
				value = kv[2]})
		end
		return
	end
	local id, comp = M.rules_entity()
	if not id then
		if not rules_wait then
			K.send({op = "place", type = "kit/game_rules", pos = {0, 0, 0}})
			log:info("kit: ui: kit/game_rules placed to keep Kit's own HUD")
		end
		rules_wait = rules_wait or {}
		for _, kv in ipairs(list) do
			rules_wait[#rules_wait + 1] = {prefix .. kv[1], kv[2]}
		end
		return
	end
	for _, kv in ipairs(list) do
		K.send({op = "set", id = id, comp = comp, param = prefix .. kv[1],
			value = kv[2]})
	end
end

-- ---- One element's drawing

local function fit_text(r, text, px, aw, ah, pw, pad)
	local key = text .. "|" .. px .. "|" .. tostring(aw) .. "|" .. tostring(ah) ..
			"|" .. pw
	if r.wrap ~= key then
		r.wrap = key
		local function put(p)
			if r.px ~= p then
				r.px = p
				r.t:SetFont(magic.cache:GetResource("Font", FONT), p)
			end
			r.t.text = ""
			r.t.text = text
			-- (its minWidth: its width read 0 a frame after)
			return r.t.minWidth
		end
		r.t:SetWordwrap(false)
		local tw, p = put(px), px
		if aw then
			local least = min_text()
			while (tw > aw or (ah and r.t.height > ah)) and p > least do
				p = math.max(least, math.min(p - 1,
						math.floor(p * aw / math.max(tw, 1))))
				tw = put(p)
			end
		elseif r.kind ~= "panel" and tw > pw - 2 * pad then
			r.t:SetWordwrap(true)
			tw = math.max(8, pw - 2 * pad)
		end
		r.tw = tw
	end
	r.t.width = r.tw
end

-- [KIT_PLAYER_LIST] A player list's rows ({name, team colour, score}): a
-- name in its colour and a score each; returns the widest name, the
-- widest score and a row's height
local function player_rows(r, rows, px)
	r.rows = r.rows or {}
	local font = magic.cache:GetResource("Font", FONT)
	local white = color(r.ui.color, magic.Color(1, 1, 1))
	local nw, sw, lh = 0, 0, 0
	for i = 1, math.max(#rows, #r.rows) do
		local row, e = rows[i], r.rows[i]
		if row and not e then
			e = {n = r.el:CreateChild("Text"), s = r.el:CreateChild("Text")}
			for _, t in ipairs({e.n, e.s}) do
				t.priority = 5
				t:SetTextEffect(magic.TE_SHADOW)
			end
			r.rows[i] = e
		end
		e.n.visible, e.s.visible = row ~= nil, row ~= nil
		if row then
			local key = px .. "|" .. tostring(row[1]) .. "|" ..
					tostring(row[2]) .. "|" .. tostring(row[3])
			if e.key ~= key then
				e.key = key
				e.n:SetFont(font, px)
				e.s:SetFont(font, px)
				e.n.text = tostring(row[1]):sub(1, 40)
				e.s.text = tostring(row[3])
				e.n:SetColor(color(row[2], white))
				e.s:SetColor(white)
			end
			nw, sw = math.max(nw, e.n.minWidth), math.max(sw, e.s.minWidth)
			lh = math.max(lh, e.n.height)
		end
	end
	return nw, sw, lh
end

local function rect(b, x, y, w, h)
	b:SetPosition(math.floor(x), math.floor(y))
	b:SetFixedSize(math.max(0, math.floor(w)), math.max(0, math.floor(h)))
end

-- The layers at w x h, a bar's fill at f
local function dress(r, w, h, V, f)
	local p = r.parts
	local geom = w .. "x" .. h .. ":" .. tostring(f)
	if r.geom == geom then
		return
	end
	r.geom = geom
	if r.pie then
		if p.disc then rect(p.disc, 0, 0, w, h) end
		if p.ring then rect(p.ring, 0, 0, w, h) end
		local ins = math.floor(w * 0.1)
		rect(p.fill, ins, ins, w - 2 * ins, h - 2 * ins)
		-- The cell floor(f * 32): step 0 none
		local step = math.floor(f * PIE_STEPS)
		r.step = step
		p.fill.visible = step > 0
		if step > 0 then
			p.fill.imageRect = cell(step - 1)
		end
		return
	end
	local b = p.line and math.max(1, math.floor(0.2 * V + 0.5)) or 0
	if p.fill and r.ui.style == "plain" then
		b = 2
	end
	if p.bg then rect(p.bg, 0, 0, w, h) end
	if p.line then
		rect(p.line[1], 0, 0, w, b)
		rect(p.line[2], 0, h - b, w, b)
		rect(p.line[3], 0, b, b, h - 2 * b)
		rect(p.line[4], w - b, b, b, h - 2 * b)
	end
	if p.fill then
		local iw, ih = w - 2 * b, h - 2 * b
		local d = tostring(r.ui.direction or "left_to_right")
		local x, y, fw, fh = b, b, iw, ih
		if d == "right_to_left" then
			fw = math.floor(iw * f)
			x = b + iw - fw
		elseif d == "bottom_to_top" then
			fh = math.floor(ih * f)
			y = b + ih - fh
		elseif d == "top_to_bottom" then
			fh = math.floor(ih * f)
		else
			fw = math.floor(iw * f)
		end
		rect(p.fill, x, y, fw, fh)
		p.fill.visible = f > 0
		r.fill_at = string.format("%d,%d %dx%d", x, y, fw, fh)
	end
end

-- A shown panel's stacked children placed (r.sx, r.sy, in it) and, where
-- its width or height is 0, its size fitted to them
local function stack(r, V)
	local u, kids = r.ui, {}
	for _, k in ipairs(r.kids or {}) do
		if k.on or E.editing then
			kids[#kids + 1] = k
		else
			k.sx, k.sy = 0, 0
		end
	end
	table.sort(kids, function(a, b)
		local oa, ob = num(a.ui.order, 0, -40, 40), num(b.ui.order, 0, -40, 40)
		if oa ~= ob then
			return oa < ob
		end
		return a.id < b.id
	end)
	local pad = pad_of(V)
	local gap = num(u.gap, 0, 0, 100) * V
	local row = u.layout == "row"
	local along, across = 0, 0
	for i, k in ipairs(kids) do
		along = along + (row and k.w or k.h) + (i > 1 and gap or 0)
		across = math.max(across, row and k.h or k.w)
	end
	local cw, ch = row and along or across, row and across or along
	local titled = r.text ~= ""
	if num(u.width, 0, 0, 400) <= 0 then
		r.w = math.min(math.max(cw, titled and r.tw or 0) + 2 * pad, r.pw)
	end
	if num(u.height, 0, 0, 400) <= 0 then
		r.h = math.min(ch + 2 * pad + r.title_h, r.ph)
	end
	r.empty = #kids == 0 and not titled and num(u.width, 0, 0, 400) <= 0
	local a = tostring(u.anchor or "")
	local at = 0
	for _, k in ipairs(kids) do
		if row then
			k.sx = pad + at
			k.sy = pad + r.title_h + (r.h - 2 * pad - r.title_h - k.h) / 2
			at = at + k.w + gap
		else
			local room = r.w - 2 * pad - k.w
			k.sx = pad + (a:find("left") and 0 or a:find("right") and room or
					room / 2)
			k.sy = pad + r.title_h + at
			at = at + k.h + gap
		end
	end
end

-- The HUD in edit mode is the Walk and HUD views', and in the Signals view's
-- viewport with its Show HUD: 2D and 3D draw the world alone
function M.hud_off()
	return E.editing and M.view ~= nil and M.view() ~= "walk" and
			M.view() ~= "hud" and not (M.hud_area and M.hud_area())
end

-- [KIT_AIRSHIPS_2] kit/pause_menu_action: an item in the app's pause menu
-- (E.menu), its label while its entity is here, shown and in play. A press
-- is a button's (kit:ui), pressed and let go at once.
-- simplified: the menu takes no item away, so one stays (labelled nil,
-- not shown) for each such entity this client has seen
local menu_items = {}
local function menu_item(id, n, u)
	local it = menu_items[id]
	if not it then
		if not E.menu then
			return
		end
		it = {}
		menu_items[id] = it
		E.menu.add(function()
			if not it.n or not E.running or E.editing or
					state(it.n, id, "shown") ~= true then
				return nil
			end
			return tostring(it.text or "")
		end, function()
			log:info("kit: menu item " .. id .. " pressed")
			buildat.send_packet("kit:ui", id .. " 1")
			buildat.send_packet("kit:ui", id .. " 0")
		end, {order = num(u.order, 50, 1, 99)})
	end
	it.n, it.text, it.seen = n, u.text, true
end

local function update()
	local root = magic.ui.root
	for _, it in pairs(menu_items) do
		it.seen = nil
	end
	local play = E.running and not E.editing
	local V = vmin()
	local pad = pad_of(V)
	local bx, by, bw, bh = hud_box()
	-- The ones there now; a panel before what is in it
	local list = {}
	for id, n in pairs(P.nodes) do
		local raw = n.show_raw
		local show = type(n.show) == "table" and n.show or nil
		if show and type(show.ui) == "table" and show.ui.kind == "menu" then
			menu_item(id, n, show.ui)
		elseif show and type(show.ui) == "table" then
			local r = U[id]
			if not r or r.raw ~= raw or r.node ~= n.node then
				if r then
					drop(r)
				end
				r = {id = id, raw = raw, ui = show.ui, kind = tostring(show.ui.kind),
					node = n.node, comp = tonumber(show.ui.comp) or 0}
				U[id] = r
			end
			r.n, r.seen = n, true
			list[#list + 1] = id
		end
	end
	local function depth(id)
		local d, r = 0, U[id]
		while r and panel_of(r) and d < 8 do
			d = d + 1
			r = U[panel_of(r)]
		end
		return d
	end
	table.sort(list, function(a, b)
		local da, db = depth(a), depth(b)
		if da ~= db then
			return da < db
		end
		return a < b
	end)
	-- Kit's own, once the rules are here
	if hud_rules() then
		for name in pairs(OWN_KEYS) do
			local id = "own:" .. name
			local u = own_ui(name)
			local raw = network.write_json(u)
			local r = U[id]
			if not r or r.raw ~= raw then
				if r then
					drop(r)
				end
				r = {id = id, raw = raw, ui = u, kind = u.kind, own = name}
				U[id] = r
			end
			r.seen = true
			list[#list + 1] = id
		end
	end
	for id, r in pairs(U) do
		if not r.seen then
			drop(r)
			U[id] = nil
		end
		r.seen = nil
	end
	for _, it in pairs(menu_items) do
		if not it.seen then
			it.n = nil
		end
	end
	local lift = 0
	if TOUCH and M.touch_bar_top then
		local top = M.touch_bar_top()
		lift = top and not (M.hud_area and M.hud_area()) and
				math.max(0, root.height - top) or 0
		-- simplified: the whole width's bottom, though the bars are at
		-- the lower right only; the bars' own rectangle is the upgrade
		if top ~= bars_at then
			bars_at = top
			log:info("kit: ui touch bars at y " .. tostring(top))
		end
	end
	local sel = M.selected and M.selected() or nil
	if own_sel and own_sel.entity ~= sel then
		own_sel = nil
	end
	local wants = false
	-- A placed health bar up instead of the rules' own
	local placed_health = false
	-- First each one's parent, shown state and size
	for _, id in ipairs(list) do
		local r = U[id]
		r.kids = nil
		r.sx, r.sy, r.empty = nil, nil, nil
	end
	local hp, hp_max = nil, nil
	if M.my_health then
		hp, hp_max = M.my_health()
	end
	for _, id in ipairs(list) do
		local r = U[id]
		local u = r.ui
		local pid = panel_of(r)
		local pr = pid and U[pid] or nil
		-- In a panel only while it is drawn
		local parent = root
		if pid then
			parent = pr and pr.kind == "panel" and pr.el or nil
		end
		-- (its panel's element, the same object while it is there; the
		-- root's wrapper is a new one each time it is read)
		local key = pid and parent or false
		if r.el and r.pkey ~= key then
			drop(r)
		end
		if parent and not r.el then
			make(r, id, parent, pid ~= nil)
			r.pkey = key
		end
		if r.el then
			r.pr = pr
			local value
			if r.own then
				local rules_on = M.game_rule("show_health") ~= false
				if r.own == "health" then
					r.on = rules_on and M.slots_own() and hp ~= nil and
							(P.hands and true or false) and not placed_health
					r.skip = not rules_on
				else
					r.on = false
					r.skip = (r.own == "hotbar" and (not M.slots_own() or
							(tonumber(M.game_rule("hotbar")) or 0) <= 0)) or
							(r.own == "item_line" and M.slots_own())
				end
				value = hp
			else
				r.on = state(r.n, id, "shown") == true and (not pr or pr.on)
				value = state(r.n, id, "value")
				-- [KIT_GOALS] a goal with no line
				if u.stack and tostring(u.text or "") == "" then
					r.on, r.empty = false, true
				end
				if u.source == "health" then
					value = hp
					placed_health = placed_health or (r.on and hp ~= nil)
				end
			end
			r.value = value
			local pw = pr and pr.w or bw
			local ph = pr and pr.h or bh
			local top = 0
			if pr then
				-- Under its panel's title, inside its edge
				top = pr.title_h or 0
				pw, ph = pw - 2 * pad, ph - 2 * pad - top
			end
			r.pw, r.ph, r.top = pw, ph, top
			local text = shown_text(u.text, value)
			if u.kind == "button" and text == "" and tostring(u.action or "")
					~= "" then
				for _, a in ipairs(M.world_actions()) do
					if a.name == u.action then
						text = a.label ~= "" and a.label or a.name
					end
				end
			end
			r.text = text
			local W, H = num(u.width, 0, 0, 400) * V, num(u.height, 0, 0, 400) * V
			if drag and drag.id == id and drag.size then
				W, H = drag.size[1], drag.size[2]
			end
			local px = math.max(min_text(),
					math.floor(num(u.size, 2, 0, 30) * V + 0.5))
			local w, h
			if u.kind == "panel" then
				fit_text(r, text, px, nil, nil, pw, pad)
				w = W > 0 and math.min(W, pw) or pw
				h = H > 0 and math.min(H, ph) or ph
				r.title_h = text ~= "" and r.t.height + pad or 0
				r.t:SetPosition(pad, math.floor(pad * 0.75))
				if tostring(u.layout or "none") == "none" and W <= 0 then
					w = math.min(30 * V, pw)
				end
				if tostring(u.layout or "none") == "none" and H <= 0 then
					h = math.min(15 * V, ph)
				end
			else
				if r.pie then
					local s = (W > 0 and H > 0) and math.min(W, H) or
							(W > 0 and W) or (H > 0 and H) or 5 * V
					w, h = math.min(s, pw, ph), math.min(s, pw, ph)
					fit_text(r, text, px, w * 0.76, h * 0.7, pw, pad)
				elseif u.kind == "bar" then
					w = math.min(W > 0 and W or 16 * V, pw)
					h = math.min(H > 0 and H or 2.6 * V, ph)
					fit_text(r, text, px, w - 2 * pad, h - 2, pw, pad)
				elseif u.kind == "own" then
					w = u.width and W or M.hud_unit() *
							(tonumber(M.game_rule("hotbar")) or 0)
					h = u.height and H or M.hud_unit()
					fit_text(r, text, px, w - 2, h - 2, pw, pad)
				elseif u.kind == "players" then
					-- The title, then the rows; a score at the right
					fit_text(r, text, px, nil, nil, pw, pad)
					local rows = type(value) == "table" and value or {}
					local nw, sw, lh = player_rows(r, rows, px)
					local th = text ~= "" and r.t.height or 0
					w = math.min(W > 0 and W or
							math.max(r.tw, nw + 2 * pad + sw) + 2 * pad, pw)
					h = math.min(H > 0 and H or th + #rows * lh + 2 * pad, ph)
					local y = pad + th
					for i, row in ipairs(rows) do
						local e = r.rows[i]
						e.n:SetPosition(pad, math.floor(y))
						e.s:SetPosition(math.floor(w - pad - e.s.minWidth),
								math.floor(y))
						y = y + lh
						text = text .. " | " .. tostring(row[1]) .. " " ..
								tostring(row[3]) .. " " .. tostring(row[2])
					end
					r.text = text
				elseif u.kind == "input" then
					-- The label at the left, the field the rest
					w = math.min(W > 0 and W or 30 * V, pw)
					fit_text(r, text, px, w / 2, nil, pw, pad)
					h = H > 0 and math.min(H, ph) or math.max(r.t.height +
							math.floor(pad * 0.7) * 2, TOUCH and 36 or math.floor(2.8 * V))
				elseif W > 0 then
					fit_text(r, text, px, W - 2 * pad, H > 0 and H - 2 or nil, pw, pad)
					w = math.min(W, pw)
					h = H > 0 and math.min(H, ph) or r.t.height +
							math.floor(pad * 0.7) * 2
				else
					fit_text(r, text, px, nil, nil, pw, pad)
					w = math.min(pw, r.tw + 2 * pad)
					h = H > 0 and math.min(H, ph) or r.t.height +
							math.floor(pad * 0.7) * 2
				end
				if u.kind == "button" and H <= 0 then
					h = math.max(h, TOUCH and 36 or math.floor(2.4 * V))
				end
			end
			r.w, r.h = w, h
			if pr then
				pr.kids = pr.kids or {}
				pr.kids[#pr.kids + 1] = r
			end
		end
	end
	-- Then the stacking panels, the innermost first
	for i = #list, 1, -1 do
		local r = U[list[i]]
		if r.el and r.kind == "panel" and (r.ui.layout == "column" or
				r.ui.layout == "row") then
			stack(r, V)
		end
	end
	-- [KIT_GOALS] The stacked lines of one place under each other
	local stacks = {}
	for _, id in ipairs(list) do
		local r = U[id]
		r.dy = nil
		if r.el and r.ui.stack and not r.empty and (r.on or E.editing) then
			local u = r.ui
			local k = tostring(u.anchor) .. " " .. tostring(u.x) .. " " ..
					tostring(u.y)
			stacks[k] = stacks[k] or {}
			table.insert(stacks[k], r)
		end
	end
	for _, l in pairs(stacks) do
		table.sort(l, function(a, b)
			local oa, ob = num(a.ui.order, 0, -40, 40), num(b.ui.order, 0, -40, 40)
			if oa ~= ob then
				return oa < ob
			end
			return a.id < b.id
		end)
		local at, up = 0, tostring(l[1].ui.anchor):find("bottom") ~= nil
		for _, r in ipairs(l) do
			r.dy = up and -at or at
			at = at + r.h + math.floor(0.4 * V)
		end
	end
	-- Then each one's place and looks
	local now = buildat.get_time_us() / 1e6
	for _, id in ipairs(list) do
		local r = U[id]
		if r.el then
			local u = r.ui
			local pr = r.pr
			local w, h = r.w, r.h
			local x, y
			if r.sx then
				x, y = r.sx, r.sy
			else
				x, y = place(u, w, h, r.pw, r.ph,
						pr and 0 or r.own and own_lift(r.own, V) or lift, V)
				if pr then
					x, y = x + pad, y + pad + r.top
				else
					x, y = x + bx, y + by
				end
				y = y + (r.dy or 0)
			end
			-- (no drag in the Signals view's box: bx, by not undone here)
			r.to_params = function(px, py, nw, nh)
				if pr then
					px, py = px - pad, py - pad - r.top
				end
				py = py - (r.dy or 0)
				return from_place(u, nw or w, nh or h, r.pw, r.ph, px, py, V)
			end
			if drag and drag.id == id and drag.at then
				x, y = drag.at[1], drag.at[2]
			end
			r.el:SetPosition(math.floor(x), math.floor(y))
			r.el:SetFixedSize(math.floor(w), math.floor(h))
			if u.kind == "players" then
				r.t:SetPosition(pad, pad)
			elseif u.kind ~= "panel" then
				r.t:SetPosition(math.max(1, math.floor((w - r.tw) / 2)),
						math.floor((h - r.t.height) / 2))
			end
			if r.edit then
				local lx = r.text ~= "" and r.tw + 2 * pad or pad
				r.t:SetPosition(pad, math.floor((h - r.t.height) / 2))
				local fh = math.max(8, math.floor(h - pad))
				r.edit:SetPosition(math.floor(lx), math.floor((h - fh) / 2))
				r.edit:SetFixedSize(math.max(8, math.floor(w - lx - pad)), fh)
				if r.edit_px ~= r.px then
					r.edit_px = r.px
					r.edit.textElement:SetFont(magic.cache:GetResource("Font", FONT),
							r.px)
				end
				r.edit.enabled = not E.editing
			end
			r.frac = nil
			if u.kind == "bar" then
				local lo, hi = tonumber(u.min) or 0, tonumber(u.max) or 100
				if u.source == "health" then
					lo, hi = 0, hp_max or 1
				end
				local f = hi ~= lo and ((tonumber(r.value) or lo) - lo) / (hi - lo)
						or 0
				f = math.max(0, math.min(1, f))
				-- (no player's health in edit mode: as if full)
				if E.editing and u.source == "health" and not hp then
					f = 1
				end
				r.frac = f
			end
			dress(r, math.floor(w), math.floor(h), V, r.frac or 0)
			-- Play: as its state says; edit mode: all, a hidden one dimmed,
			-- framed
			r.el.visible = not M.hud_off() and not r.skip and
					not (r.empty and not E.editing) and ((play and r.on) or E.editing or (r.own ~= nil and r.on))
			r.el.enabled = E.editing or r.kind ~= "text"
			local blink = tonumber(u.blink_below) or 0
			r.blinking = not E.editing and r.frac ~= nil and blink > 0 and
					r.frac < blink
			if E.editing then
				r.el.opacity = (r.on or r.own) and 0.95 or 0.45
			elseif r.blinking then
				r.el.opacity = (now * 2) % 1 < 0.5 and 1 or 0.25
			else
				r.el.opacity = 1
			end
			if r.kind == "button" and r.parts.bg then
				-- simplified: a pointer over it brightens it, no fade
				local mp = magic.input:GetMousePosition()
				local sc, sp = magic.ui.scale, r.el.screenPosition
				local over = mp.x / sc >= sp.x and mp.y / sc >= sp.y and
						mp.x / sc < sp.x + w and mp.y / sc < sp.y + h
				if over ~= r.over then
					r.over = over
					r.parts.bg.color = color(u.background, magic.Color(0, 0, 0, 0.6),
							over and 0.18 or 0)
				end
			end
			local selected = sel == id or (own_sel and own_sel.name == r.own)
			local col = selected and M.HOVER or (r.own and
					magic.Color(0.55, 0.8, 1) or magic.Color(0.8, 0.8, 0.8))
			-- [KIT_SIGNALS_VIEW] In the Signals viewport the selected one on an
			-- amber rectangle a little larger: beside it, not in it (a bar and
			-- a button clip their children)
			local marked = selected and M.hud_area ~= nil and M.hud_area() ~= nil
			if marked and not r.mark then
				r.mark = r.host:CreateChild("BorderImage")
				r.mark.blendMode = magic.BLEND_ALPHA
				r.mark.color = magic.Color(1, 0.65, 0.05, 0.9)
			end
			if r.mark then
				r.mark.visible = marked and true or false
				if marked then
					r.mark.priority = r.el.priority - 1
					local p = r.el.position
					rect(r.mark, p.x - 4, p.y - 4, math.floor(w) + 8,
							math.floor(h) + 8)
				end
			end
			local bars = {{0, 0, w, 1}, {0, h - 1, w, 1}, {0, 0, 1, h},
				{w - 1, 0, 1, h}}
			for i, b in ipairs(r.edge) do
				b.visible = E.editing
				if E.editing then
					b.color = col
					b:SetPosition(math.floor(bars[i][1]), math.floor(bars[i][2]))
					b:SetFixedSize(math.max(1, math.floor(bars[i][3])),
							math.max(1, math.floor(bars[i][4])))
				end
			end
			if play and r.on and r.kind == "panel" then
				for _, o in pairs(U) do
					if (o.kind == "button" or o.kind == "input") and
							panel_of(o) == id then
						wants = true
					end
				end
			end
			-- Said as it changes: where it is and what it shows
			local sw, sh = bw, bh
			local sp = r.el.screenPosition
			local line = string.format("kit: ui %s %s at %d,%d %dx%d in %dx%d" ..
					" font %d %s order %g %s%s%s%s%s%s: \"%s\"", tostring(id), r.kind,
					sp.x, sp.y, w, h, sw, sh, r.px or 0, tostring(u.style or "shapes"),
					num(u.order, 0, -40, 40), r.el.visible and "shown" or "hidden",
					E.editing and (r.on and ", edit mode" or
					", edit mode, hidden in play") or "",
					r.frac and string.format(", %.2f full", r.frac) or "",
					r.pie and ", pie step " .. tostring(r.step) .. " of 32" or "",
					(r.fill_at and not r.pie) and ", fill " .. r.fill_at or "",
					(r.blinking and ", blinks" or "") ..
							(r.mark and r.mark.visible and ", marked" or ""),
					(r.text:gsub("\n", " | ")))
			if line ~= r.log then
				r.log = line
				local off = sp.x < bx or sp.y < by or sp.x + w > bx + sw or
						sp.y + h > by + sh
				log:info(line .. ((off and r.el.visible) and " OFF SCREEN" or ""))
			end
		end
	end
	-- The edits waiting for a kit/game_rules placed
	if rules_wait and E.editing then
		local rid, comp = M.rules_entity()
		if rid then
			for _, kv in ipairs(rules_wait) do
				K.send({op = "set", id = rid, comp = comp, param = kv[1],
					value = kv[2]})
			end
			rules_wait = nil
		end
	end
	-- A panel with a button up: the pointer this player's to click with
	-- (as builtin/accounts' Server window frees it); ui_utils' mouse look
	-- takes it back after
	if wants and not want.visible then
		local input = magic.input
		if not input.mouseVisible or (WEB and input:IsMouseLocked()) then
			input:SetMouseVisible(true, "a Kit panel with a button")
			if WEB then
				input:SetMouseMode(magic.MM_ABSOLUTE)
			end
			log:info("kit: ui: the pointer freed for a panel's button")
		end
	end
	want.visible = wants
end

-- ---- The selected one's handles (edit mode)
local HANDLES = nil
local function handle_size()
	return TOUCH and 26 or 14
end

local function selected_rec()
	if own_sel then
		return U["own:" .. own_sel.name]
	end
	return M.selected and U[M.selected()] or nil
end

local function resizable(r)
	return r and r.el and r.kind ~= "own" and r.el.visible
end

-- [KIT_PARAM_CATEGORIES] Kit's own element selected with entity `id`: its name
function M.own_selected(id)
	return own_sel and own_sel.entity == id and own_sel.name or nil
end

-- The selected element's box (screen UI units) and, of Kit's own, its name;
-- nil with none on the screen
function M.hud_selected_rect()
	local r = selected_rec()
	if not r or not r.el or not r.el.visible or not r.w then
		return nil
	end
	local p = r.el.screenPosition
	return p.x, p.y, r.w, r.h, r.own
end

-- The handles' {mode, x, y}: on the right edge's and the bottom edge's
-- middle and the corner, in screen UI units
local function handle_list(r)
	local p = r.el.screenPosition
	local s, w, h = handle_size(), r.w, r.h
	return {{mode = "w", x = p.x + w - s / 2, y = p.y + h / 2 - s / 2},
		{mode = "h", x = p.x + w / 2 - s / 2, y = p.y + h - s / 2},
		{mode = "wh", x = p.x + w - s / 2, y = p.y + h - s / 2}}
end

local function draw_handles()
	local r = E.editing and selected_rec() or nil
	local on = resizable(r)
	if not HANDLES then
		if not on then
			return
		end
		HANDLES = {}
		for i = 1, 3 do
			local b = magic.ui.root:CreateChild("BorderImage")
			b.priority = -2
			b.bringToFront = false
			b.color = M.HOVER
			HANDLES[i] = b
		end
	end
	local list = on and handle_list(r) or nil
	for i, b in ipairs(HANDLES) do
		b.visible = on and true or false
		if on then
			rect(b, list[i].x, list[i].y, handle_size(), handle_size())
		end
	end
end

-- [KIT_CTF] World markers: an entity whose type has a `marker` ({color,
-- label, lift, state, style}, "param:<name>" as a look's) pointed out on
-- this screen while its shared state `state` (none: always) is true: a dot
-- of its colour and its label `lift` metres (1) over it, drawn over the
-- world (through walls), kept at the screen's edge while it is off the
-- screen or behind the view, following the entity as it moves.
-- [KIT_HUD_STYLE] style "shapes" (the default) a disc with a ring and the
-- label on a dark rectangle; "plain" a square and the text alone
local MK = {}
-- [KIT_GOALS] Where a marker points: its `kind` "use", at its `target`; "reach",
-- the middle of its box of cells `box`, turned with its node
function M.marker_at(n, mk)
	-- [KIT_GUIDE_BOTS_2] a target followed: "reach" and "place_item" too
	if mk.kind == "use" or ((mk.kind == "reach" or mk.kind == "place_item") and
			(tonumber(mk.target) or 0) >= 2 and P.nodes[tonumber(mk.target)]) then
		local t = P.nodes[tonumber(mk.target) or 0]
		return (t and t.node or n.node).worldPosition
	end
	local p = n.node.worldPosition
	if mk.kind == "reach" and type(mk.box) == "table" then
		local e = {}
		for i = 1, 3 do
			e[i] = (math.max(1, math.floor(tonumber(mk.box[i]) or 1)) - 1) / 2
		end
		return p + n.node.rotation * magic.Vector3(e[1], e[2], e[3])
	end
	return p
end

local function markers()
	-- [KIT_SIGNALS_VIEW] Through the viewport's camera, in its box
	local area = M.hud_area and M.hud_area()
	local cn = area and area.node or K.O.camera
	local cam = area and area.cam or (cn and cn:GetComponent("Camera"))
	local root = magic.ui.root
	local V = vmin()
	local bx, by, W, H = hud_box()
	for id, n in pairs(P.nodes) do
		local mk = type(n.show) == "table" and type(n.show.marker) == "table"
				and n.show.marker or nil
		local r = MK[id]
		if r and mk and r.style ~= mk.style then
			r.el:Remove()
			MK[id] = nil
			r = nil
		end
		if mk and (not r or r.node ~= n.node) then
			if r then
				r.el:Remove()
			end
			r = {node = n.node, style = mk.style}
			r.el = root:CreateChild("UIElement")
			r.el.priority = -1500
			r.el.bringToFront = false
			if mk.style ~= "plain" then
				r.bg = r.el:CreateChild("BorderImage")
				r.bg.blendMode = magic.BLEND_ALPHA
				r.bg.color = magic.Color(0, 0, 0, 0.63)
				r.ring = r.el:CreateChild("BorderImage")
				r.ring.blendMode = magic.BLEND_ALPHA
				r.ring.texture = atlas()
				r.ring.imageRect = cell(PIE_STEPS)
				r.ring.color = magic.Color(0.5, 0.5, 0.5, 0.8)
				r.ring.priority = 2
			end
			r.dot = r.el:CreateChild("BorderImage")
			r.dot.blendMode = magic.BLEND_ALPHA
			r.dot.priority = 1
			if mk.style ~= "plain" then
				r.dot.texture = atlas()
				r.dot.imageRect = cell(PIE_STEPS - 1)
			end
			r.t = r.el:CreateChild("Text")
			r.t.priority = 3
			r.t:SetTextEffect(magic.TE_SHADOW)
			MK[id] = r
		end
		if r then
			r.seen = true
			r.mk = mk
		end
	end
	for id, r in pairs(MK) do
		if not r.seen then
			pcall(function() r.el:Remove() end)
			MK[id] = nil
		end
		r.seen = nil
	end
	local MARGIN = 2 * V
	local D = math.max(8, math.floor(1.1 * V))
	for id, r in pairs(MK) do
		local mk, n = r.mk, P.nodes[id]
		local on = cam ~= nil and not M.hud_off() and mk.on ~= false and
				(type(mk.state) ~= "string" or
				state(n, id, mk.state) == true)
		local where = "hidden"
		if on then
			local p = M.marker_at(n, mk)
			p = magic.Vector3(p.x, p.y + num(mk.lift, 1, -100, 100), p.z)
			local o, d = cn.worldPosition, cn.worldDirection
			local behind = not cam.orthographic and (p.x - o.x) * d.x +
					(p.y - o.y) * d.y + (p.z - o.z) * d.z <= 0.01
			local sp = cam:WorldToScreenPoint(p)
			local x, y = sp.x * W, sp.y * H
			local cx, cy = W / 2, H / 2
			local dx, dy = x - cx, y - cy
			if behind then
				-- (its projection is through the eye: the way to it across
				-- the view instead, right = up x dir, up = dir x right, at
				-- least at the edge; straight behind: the bottom)
				local vx, vy, vz = p.x - o.x, p.y - o.y, p.z - o.z
				local rx, rz = d.z, -d.x
				local ux, uy, uz = -d.y * d.x, d.z * d.z + d.x * d.x, -d.y * d.z
				dx = vx * rx + vz * rz
				dy = -(vx * ux + vy * uy + vz * uz)
				if math.abs(dx) + math.abs(dy) < 1e-3 then
					dy = 1
				end
			end
			local hw, hh = cx - MARGIN, cy - MARGIN
			local k = math.min(dx ~= 0 and hw / math.abs(dx) or math.huge,
					dy ~= 0 and hh / math.abs(dy) or math.huge)
			where = "on screen"
			if behind or k < 1 then
				where = "at the edge"
				dx, dy = dx * k, dy * k
			end
			x, y = math.floor(cx + dx), math.floor(cy + dy)
			local label = tostring(mk.label == nil and "" or mk.label):sub(1, 64)
			-- [KIT_GOALS] the way to it, at the edge
			if mk.arrow and (behind or k < 1) then
				label = math.abs(dx) * hh >= math.abs(dy) * hw and
						(dx < 0 and "< " .. label or label .. " >") or
						(dy < 0 and "^ " or "v ") .. label
			end
			r.dot.color = color(mk.color, magic.Color(1, 0.85, 0.2))
			r.t:SetColor(r.dot.color)
			local px = math.max(min_text(), math.floor(1.6 * V + 0.5))
			if r.px ~= px then
				r.px = px
				r.t:SetFont(magic.cache:GetResource("Font", FONT), px)
			end
			if r.t.text ~= label then
				r.t.text = label
			end
			-- The dot on the point, the label over it, both on the screen
			local tw, th = r.t.minWidth, r.t.height
			r.el:SetPosition(bx, by)
			r.dot:SetFixedSize(D, D)
			r.dot:SetPosition(x - math.floor(D / 2), y - math.floor(D / 2))
			local tx = math.max(3, math.min(W - tw - 3, x - math.floor(tw / 2)))
			local ty = math.max(1, y - math.floor(D / 2) - 2 - th)
			r.t:SetPosition(tx, ty)
			if r.ring then
				local R = math.floor(D * 1.4)
				r.ring:SetFixedSize(R, R)
				r.ring:SetPosition(x - math.floor(R / 2), y - math.floor(R / 2))
				r.bg.visible = label ~= ""
				r.bg:SetFixedSize(tw + 6, th)
				r.bg:SetPosition(tx - 3, ty)
			end
			where = where .. " at " .. x .. "," .. y
			r.at = {x, y}
		end
		r.el.visible = on
		r.where = where
		local line = "kit: marker " .. id .. " \"" .. tostring(mk.label or "") ..
				"\" " .. where:gsub(" at %-?%d+,%-?%d+$", "")
		if line ~= r.log then
			r.log = line
			log:info(line .. (r.at and on and (" (" .. r.at[1] .. "," ..
					r.at[2] .. " in " .. W .. "x" .. H .. ")") or ""))
		end
	end
end

magic.SubscribeToEvent("Update", function()
	local ok, err = pcall(update)
	if not ok then
		log:warning("kit: ui: " .. tostring(err))
	end
	ok, err = pcall(draw_handles)
	if not ok then
		log:warning("kit: ui handles: " .. tostring(err))
	end
	ok, err = pcall(markers)
	if not ok then
		log:warning("kit: markers: " .. tostring(err))
	end
end)

-- For a drive: "event kit_markers" logs where each marker is drawn
magic.SubscribeToEvent("command_seq:kit_markers", function()
	for id, r in pairs(MK) do
		log:info("kit: marker " .. id .. " is " .. tostring(r.where))
	end
end)

-- For a drive: "event kit_ui_flood <id> <n>" sends n presses and releases
-- of a UI button at once, as a misbehaving client would
magic.SubscribeToEvent("command_seq:kit_ui_flood", function(_, data)
	local id, n = data:GetString("Param"):match("^(%d+) (%d+)$")
	log:info("kit: flooding " .. tostring(n) .. " presses of ui " ..
			tostring(id))
	for _ = 1, math.min(tonumber(n) or 0, 100000) do
		buildat.send_packet("kit:ui", id .. " 1")
		buildat.send_packet("kit:ui", id .. " 0")
	end
end)
-- "event kit_ui_text <id> <text>": that line sent as entered in it
magic.SubscribeToEvent("command_seq:kit_ui_text", function(_, data)
	buildat.send_packet("kit:ui_text", data:GetString("Param"))
end)

-- The one at x, y (pixels): the innermost, of those the smallest
local own_check = false
local function hit(x, y)
	if own_check then
		return nil
	end
	local sc = magic.ui.scale
	x, y = x / sc, y / sc
	local best, area = nil, nil
	for id, r in pairs(U) do
		if r.el and r.el.visible and (E.editing or r.kind == "button" or
				r.kind == "input" or (r.kind == "panel" and r.has_bg)) then
			local ok, a = pcall(function()
				local p, s = r.el.screenPosition, r.el.size
				return x >= p.x and y >= p.y and x < p.x + s.x and
						y < p.y + s.y and s.x * s.y
			end)
			if ok and a and (not area or a < area) then
				best, area = id, a
			end
		end
	end
	return best
end

-- The selected one's handle at x, y (pixels), which stick out of it
local function handle_at(x, y)
	local sel = selected_rec()
	if not resizable(sel) then
		return nil, sel
	end
	local sc, s = magic.ui.scale, handle_size()
	for _, h in ipairs(handle_list(sel)) do
		if x / sc >= h.x and y / sc >= h.y and x / sc < h.x + s and
				y / sc < h.y + s then
			return h, sel
		end
	end
	return nil, sel
end

function M.ui_at(x, y)
	return hit(x, y) ~= nil or (E.editing and not own_check and
			handle_at(x, y) ~= nil)
end

-- Edit mode: a press on a handle resizes the selected one, on one selects
-- it, a drag moves it (the mouse's or a finger's), unless the editor's own
-- panels are over it there
local function press(x, y)
	if not E.editing or (M.looking and M.looking()) then
		return
	end
	own_check = true
	local over = M.over_ui and M.over_ui(x, y)
	own_check = false
	if over then
		return
	end
	local h, sel = handle_at(x, y)
	if h then
		drag = {id = sel.id, x0 = x, y0 = y, mode = h.mode, w = sel.w,
			h = sel.h, px = sel.el.position.x, py = sel.el.position.y}
		-- ([KIT_PARAM_CATEGORIES] a small one's handles cover it: a press on
		-- one opens its panel too)
		if M.hud_picked then
			M.hud_picked()
		end
		return
	end
	local id = hit(x, y)
	local r = id and U[id]
	if not r then
		return
	end
	if r.own then
		local rid = M.rules_entity()
		if rid and M.select then
			M.select(rid)
		end
		own_sel = {name = r.own, entity = M.selected and M.selected() or nil}
		log:info("kit: ui: selected Kit's own " .. r.own)
	elseif M.select then
		M.select(id)
	end
	if M.hud_picked then
		M.hud_picked()
	end
	drag = {id = id, x0 = x, y0 = y, px = r.el.position.x,
		py = r.el.position.y, stacked = r.sx ~= nil}
end

-- The lines a dragged edge or centre may snap to (screen UI units): the
-- other shown elements' and the screen's
local function snap_lines(self)
	local xs, ys = {}, {}
	local root = magic.ui.root
	local function add(x, y, w, h)
		xs[#xs + 1] = x
		xs[#xs + 1] = x + w / 2
		xs[#xs + 1] = x + w
		ys[#ys + 1] = y
		ys[#ys + 1] = y + h / 2
		ys[#ys + 1] = y + h
	end
	add(0, 0, root.width, root.height)
	for _, o in pairs(U) do
		if o ~= self and o.el and o.el.visible and o.w and o.pr ~= self then
			local p = o.el.screenPosition
			add(p.x, p.y, o.w, o.h)
		end
	end
	return xs, ys
end

-- The smallest move putting one of `own` on one of `lines`, within t
local function nearest(own, lines, t)
	local best = nil
	for _, a in ipairs(own) do
		for _, l in ipairs(lines) do
			local d = l - a
			if math.abs(d) <= t and (not best or math.abs(d) < math.abs(best)) then
				best = d
			end
		end
	end
	return best
end

local function round(v)
	return math.floor(v + 0.5)
end

local function move(x, y)
	if not drag or not E.editing then
		return
	end
	local sc = magic.ui.scale
	local dx, dy = (x - drag.x0) / sc, (y - drag.y0) / sc
	local r = U[drag.id]
	if not r or not r.el then
		return
	end
	local V = vmin()
	local sp = r.el.screenPosition
	local ox, oy = sp.x - r.el.position.x, sp.y - r.el.position.y
	local xs, ys = snap_lines(r)
	if drag.mode then
		if not drag.size and math.abs(dx) + math.abs(dy) <= 2 then
			return
		end
		local nw, nh = drag.w, drag.h
		if drag.mode ~= "h" then
			nw = drag.w + dx
			local d = nearest({ox + drag.px + nw}, xs, V)
			nw = d and nw + d or round(nw / V) * V
		end
		if drag.mode ~= "w" then
			nh = drag.h + dy
			local d = nearest({oy + drag.py + nh}, ys, V)
			nh = d and nh + d or round(nh / V) * V
		end
		drag.size = {math.max(2 * V, nw), math.max(2 * V, nh)}
		drag.at = {drag.px, drag.py}
		return
	end
	if drag.stacked or (not drag.at and math.abs(dx) + math.abs(dy) <= 4) then
		return
	end
	local px, py = drag.px + dx, drag.py + dy
	local w, h = r.w, r.h
	local sx = nearest({ox + px, ox + px + w / 2, ox + px + w}, xs, V)
	local sy = nearest({oy + py, oy + py + h / 2, oy + py + h}, ys, V)
	-- An edge or a centre, else a whole percent
	local nx, ny = r.to_params(px + (sx or 0), py + (sy or 0))
	nx = sx and nx or round(nx)
	ny = sy and ny or round(ny)
	drag.params = {nx, ny}
	local gx, gy = place({anchor = r.ui.anchor, x = nx, y = ny}, w, h, r.pw, r.ph,
			0, V)
	if r.pr then
		gx, gy = gx + pad_of(V), gy + pad_of(V) + r.top
	end
	drag.at = {gx, gy}
	drag.snapped = (sx or sy) and true or false
end

local function release()
	local d = drag
	drag = nil
	local r = d and U[d.id]
	if not r or not d.at or not E.editing or not r.to_params then
		return
	end
	-- Back from the place to x and y from its anchor.
	-- simplified: an edit each, an undo each; an op setting several
	-- parameters at once is the upgrade
	local V = vmin()
	if d.size then
		local nw = math.floor(d.size[1] / V * 100 + 0.5) / 100
		local nh = math.floor(d.size[2] / V * 100 + 0.5) / 100
		local ox, oy = r.to_params(d.px, d.py, d.size[1], d.size[2])
		log:info("kit: ui " .. d.id .. " resized to " .. nw .. " x " .. nh)
		local list = {{"x", ox}, {"y", oy}}
		if d.mode ~= "h" then
			list[#list + 1] = {"width", nw}
		end
		if d.mode ~= "w" then
			list[#list + 1] = {"height", nh}
		end
		set_params(r, list)
		return
	end
	local ox, oy = d.params[1], d.params[2]
	log:info("kit: ui " .. d.id .. " dragged to " .. ox .. ", " .. oy ..
			(d.snapped and " (snapped)" or ""))
	set_params(r, {{"x", ox}, {"y", oy}})
end
magic.SubscribeToEvent("MouseButtonDown", function(_, data)
	if data:GetInt("Button") == magic.MOUSEB_LEFT and not TOUCH then
		local mp = magic.input:GetMousePosition()
		press(mp.x, mp.y)
	end
end)
magic.SubscribeToEvent("MouseMove", function(_, data)
	if not TOUCH then
		move(data:GetInt("X"), data:GetInt("Y"))
	end
end)
magic.SubscribeToEvent("MouseButtonUp", function(_, data)
	if data:GetInt("Button") == magic.MOUSEB_LEFT and not TOUCH then
		local mp = magic.input:GetMousePosition()
		move(mp.x, mp.y)
		release()
	end
end)
if TOUCH then
	local finger = nil
	magic.SubscribeToEvent("TouchBegin", function(_, data)
		if not finger then
			finger = data:GetInt("TouchID")
			press(data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("TouchMove", function(_, data)
		if data:GetInt("TouchID") == finger then
			move(data:GetInt("X"), data:GetInt("Y"))
		end
	end)
	magic.SubscribeToEvent("TouchEnd", function(_, data)
		if data:GetInt("TouchID") == finger then
			finger = nil
			release()
		end
	end)
end
end
-- vim: set noet ts=4 sw=4:
