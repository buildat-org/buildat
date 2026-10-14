-- extensions/launch_world: [LAUNCH_WORLD], the room you start in.
--
-- **An extension, not a game** (user, 2026-09-23): the room *is* the
-- launcher, and starting a game is `ctx.launch` on the launcher's own
-- trusted side, which a game cannot call. So it needs no server process:
-- the voxels are described in room.lua, built here and meshed straight
-- into a node of this extension's own scene.
--
-- What that costs, as the plan said it would: no voxelworld means no
-- skylight flood and no baked ambient occlusion, so the wall's relief
-- rests entirely on the real lights; and the dissolve is a rewrite of the
-- block and a re-mesh rather than voxel removal on a server.
--
-- Run it with `Build/bin/buildat -m launch_world`.
-- **The safe API under one name, whichever side this runs on**
-- ([LAUNCH_SANDBOX]): inside the sandbox `buildat` *is* the safe table,
-- and outside it the safe half is `buildat.safe`. The room calls
-- nothing else, which is what makes the switch a switch.
local api = buildat.safe or buildat
local log = buildat.Logger("launch_world")

-- **The room's debug knobs** (`BUILDAT_LAUNCH_*`), through one reader;
-- an unset one is "" and falls back to its default, which is what a
-- player sees in any case. The knobs are for the checks and for the
-- next person measuring this room.
local function env(name)
	return buildat.get_env(name) or ""
end
-- **The light, as an options round** ([LAUNCH_WORLD] stage 3, the light;
-- local/options_for_LOBBY_light/): one knob, BUILDAT_LAUNCH_LIGHT=<name>,
-- each a whole look rather than a slider, so the user's pick is a
-- one-word default. "ambient" is the user's pick (2026-10-03) and the
-- default; "tomb" is the room as stage 2 left it.
--   cave     a floor of light on every voxel, the shader's cCaveAmbient
--            (nought in the tomb: the room's vertex colours carry none)
--   zone     the zone's ambient, which lights the spheres and the desk
--   orb, sky the orbs' and the opening's light, times the preset's
--   fill     the cool fill's, times the preset's
--   fov      the overhead spot's cone; spot_shadow whether it casts
--   shadows  whether anything casts (the renderer's switch)
--   opening  the opening's emitter, times its own white
--   far      a bright disc high over the formation, for the eye to rest
--            on, and its light; nil for none
LIGHT_LOOKS = {
	tomb = {cave = {0, 0, 0}, zone = {0.01, 0.01, 0.015}, orb = 1.0,
		sky = 1.0, fill = 1.0, fov = 140, spot_shadow = true,
		shadows = true, opening = 1.0},
	-- Nothing pure black, the contrast down: a cool floor every face
	-- gets, the spheres the same, the key lights a little lower so the
	-- room does not just get brighter
	ambient = {cave = {0.080, 0.085, 0.105}, zone = {0.16, 0.17, 0.21},
		orb = 0.8, sky = 0.75, fill = 0.6, fov = 140, spot_shadow = true,
		shadows = true, opening = 1.0},
	-- The opening as a soft skylight: a wide cone that casts nothing,
	-- brighter, its square bright overhead, and a little floor of light
	skylight = {cave = {0.012, 0.014, 0.020}, zone = {0.06, 0.07, 0.09},
		orb = 0.8, sky = 1.6, fill = 0.4, fov = 170, spot_shadow = false,
		shadows = true, opening = 1.6},
	-- Low room light and one bright thing far up, over the formation
	far = {cave = {0.006, 0.006, 0.008}, zone = {0.03, 0.03, 0.04},
		orb = 0.7, sky = 0.35, fill = 0.5, fov = 140, spot_shadow = true,
		shadows = true, opening = 0.5,
		far = {color = {1.0, 0.86, 0.66}, emissive = 18, light = 6.0}},
	-- The tomb without its shadow maps: what the shadows cost and what
	-- the room is without them
	noshadow = {cave = {0, 0, 0}, zone = {0.01, 0.01, 0.015}, orb = 1.0,
		sky = 1.0, fill = 1.0, fov = 140, spot_shadow = false,
		shadows = false, opening = 1.0},
}
light_look_name = LIGHT_LOOKS[env("BUILDAT_LAUNCH_LIGHT")] and
		env("BUILDAT_LAUNCH_LIGHT") or "ambient"
light_look = LIGHT_LOOKS[light_look_name]
-- require answers the safe interface inside the sandbox and the whole
-- extension outside it; the safe table raises on a name it does not
-- know, so it is asked with something it has
local urho3d = require("buildat/extension/urho3d")
local magic = urho3d.Vector3 and urho3d or urho3d.safe
-- **Its own files through the safe verb** ([LAUNCH_SANDBOX]): a
-- sandboxed extension cannot dofile a path, and a launch UI of any size
-- is more than one chunk.
local room = api.run_extension_file("room.lua")

-- **What the room holds is what the tree offers.** Every launcher/init.lua
-- in games/, builtin/ and extensions/, run in the sandbox and checked, is
-- what the launch grid draws its tiles from ([LAUNCH_GRID]); this room
-- draws the same list as orbs. A game goes in a pocket, anything else
-- that launches stands on the floor.
--
-- Read before the room is built, because how many pockets the wall has is
-- how many things there are to put in them.
-- **Through the safe verb, not the trusted file** ([LAUNCH_SANDBOX]:
-- the room is written against the sandboxed API while it still runs
-- trusted, so the switch is a switch). `launch_actions()` answers plain
-- data and a key; `api.launch(key)` is what runs one, on the
-- trusted side, where it is looked up rather than called across.
local GAMES, FLOOR_ACTIONS = {}, {}
-- **An icon two things share is not a mark** (2026-09-24): the Luanti
-- launcher gives every entry it offers `icon = "grass_block.png"`, so
-- VoxeLibre, devtest, realtest, "Import a Luanti game" and twenty more all
-- drew the same picture -- and a mark's whole job is to tell one orb
-- from another. Counted here and read where the mark is made: an icon
-- worn by more than one falls through to the name-seeded sigil, which
-- is what an orb with no icon already gets.
shared_icons = {}
do
	local seen = {}
	for _, a in ipairs(api.launch_actions()) do
		-- A Luanti server wears its game's icon, as every other server
		-- on that game does ([SERVER_ICONS]): that is not sharing a mark
		if a.icon and a.category ~= "server" then
			seen[a.icon] = (seen[a.icon] or 0) + 1
			if seen[a.icon] > 1 then shared_icons[a.icon] = true end
		end
	end
end
for _, a in ipairs(api.launch_actions()) do
	-- **The action says what it is and how much it matters**
	-- ([LAUNCH_SIGNIFY]), rather than the room guessing from where the
	-- entry came from. The category is an open set, so one this room has
	-- no orb for draws the default.
	local o = {name = a.label, icon = a.icon, key = a.key, kind = a.kind,
		description = a.description, from = a.from,
		category = a.category or "action", significance = a.significance}
	-- An app, or a Luanti game (builtin/luanti's tiles), on the wall
	if o.category == "app" or o.category == "game" then
		GAMES[#GAMES + 1] = o
	else
		-- **Everything in this table is on the floor by definition**
		-- ([FLOOR_FLAG]): the flag was set only on the games that spill
		-- off the wall, so an action on the floor was not the glossy
		-- white sphere it should be and the check's own aim line was
		-- never logged for it.
		o.floor = true
		FLOOR_ACTIONS[#FLOOR_ACTIONS + 1] = o
	end
end
-- **The saves are on the floor, smaller** (user): "save", not "world",
-- which is a Luanti-ism -- saves being universal in buildat. They come
-- from api.list_saves(), which enumerates them off the disk rather
-- than asking a server, there being none to ask.
--
-- simplified: the newest twelve. This tree has sixty-odd, most of them a
-- test run's, and a floor with sixty spheres on it is a worse list than
-- the one this room is replacing. Newest first is the order that makes a
-- cap sensible; the rest wait on the room learning to hold more than it
-- can show, which is the same open question the wall has.
local SAVES = {}
-- **The cap is about what is drawn, not about what can be reached**
-- (2026-09-24): a floor with 239 spheres on it is a worse list than the
-- one this room replaces, but a save this client has and cannot open by
-- name is a launcher that lost it. So the ones past the cap are
-- remembered here and the prompt finds them -- typed, they launch like
-- any other, and nothing is drawn for them until the player moves one.
-- A global: the search is a long way below this and the chunk is at
-- Lua's limit of locals.
unshown_saves = {}
for _, sv in ipairs(api.list_saves()) do
	-- BUILDAT_LAUNCH_SAVES=<n> is the cap, for looking at a floor with
	-- fewer on it and for driving the prompt's own path to the rest
	if #SAVES >= (tonumber(env("BUILDAT_LAUNCH_SAVES")) or 12) then
		unshown_saves[#unshown_saves + 1] = {name = sv.name, app = sv.app}
	else
		SAVES[#SAVES + 1] = sv
	end
end

log:info("saves: " .. #SAVES .. " on the floor, " .. #unshown_saves ..
		" more reachable by name")

-- **Chekhov's empty pocket**, last: a pocket with nothing in it is what
-- says there is room for another game, and it is the way to ContentDB
GAMES[#GAMES + 1] = {name = "install a game", warm = true, empty = true}

-- **The servers** (user, 2026-09-23: three kinds of sphere -- glowing,
-- white polished, mirror -- and the mirrors are the servers). A server
-- is a reflective chrome sphere standing on the floor, which is the
-- plan's own mapping.
--
-- **The client's own addresses first**: `network.known_addresses()` is
-- every address this client has used, last used first, and a
-- serverlist URL is not a server so the https ones are left out. The
-- mock-up below fills the floor out behind them.
--
-- simplified: the rest of the list is made up, because a fetched
-- serverlist is [CONTENTDB]-shaped work of its own and a room with two
-- spheres on the floor shows nothing about a room full of them. A real
-- fetch replaces the padding and nothing else.
local SERVERS = {}
do
	local net = require("buildat/extension/network")
	net = net.known_addresses and net or net.safe
	for _, a in ipairs(net.known_addresses()) do
		-- simplified: ten, the most recently used first, which is what
		-- the floor has room for without becoming a heap
		if a.uri:sub(1, 4) ~= "http" and #SERVERS < 10 then
			-- [LAUNCH_WORLD] (4): the icon the server sent at its last
			-- connect, kept by the client under the cache's server_icons/
			-- by its hash; a resource of that name, or nil and a sigil
			local icon = (a.icon or "") ~= "" and (a.icon .. ".png") or nil
			if icon and not magic.cache:Exists(icon) then icon = nil end
			if icon then
				log:info("marks: server " .. a.uri .. " wears its stored icon")
			end
			SERVERS[#SERVERS + 1] = {
				name = a.name ~= "" and a.name or a.uri, address = a.uri,
				icon = icon}
		end
	end
	log:info("servers: " .. #SERVERS .. " of the client's own")
	-- **The games on this network** ([LAN_DISCOVERY]): what announced
	-- itself before the room was built (the client listens from its
	-- start once the player has opened This network, [WIN_FIREWALL]),
	-- as heard -- anyone on the LAN can announce.
	-- simplified: heard once, at the build; a game opened to the LAN
	-- after it stands on the floor the next time the room is entered.
	-- Spheres added to a built floor when that is not soon enough.
	local lan = 0
	for _, e in ipairs(api.lan_servers()) do
		local address = e.host .. ":" .. e.port
		local known = false
		for _, sv in ipairs(SERVERS) do
			-- A used one is "<scheme>://host:port"
			if sv.address:sub(-#address - 3) == "://" .. address then
				known = true
			end
		end
		if #SERVERS < 10 and not known then
			SERVERS[#SERVERS + 1] = {address = address,
				name = (e.name ~= "" and e.name or address) ..
						" (on this network)",
				players = e.players}
			lan = lan + 1
		end
	end
	log:info("servers: " .. lan .. " heard on this network")
	-- **Starport's listings** ([SERVER_ICONS]): the lists kept from the
	-- last fetch, as the filters let them through, each with the icon
	-- its listing carries; a fetch now (of the Starports the user said
	-- yes to) refreshes them, and its icons, for the next build.
	-- simplified: last time's list, as the room is built in one frame
	local ok, sp = pcall(require, "buildat/extension/starport")
	sp = ok and type(sp) == "table" and (sp.kept_rows and sp or sp.safe)
	local listed = 0
	for _, r in ipairs(sp and sp.kept_rows() or {}) do
		local address = tostring(r.address)
		local known = false
		for _, sv in ipairs(SERVERS) do
			if sv.address == address or
					sv.address:sub(-#address - 3) == "://" .. address then
				known = true
			end
		end
		if #SERVERS < 10 and not known then
			local icon = r.icon and r.icon:match("^%x+$") and #r.icon == 64 and
					(r.icon .. ".png") or nil
			if icon and not magic.cache:Exists(icon) then icon = nil end
			if icon then
				log:info("marks: server " .. address .. " wears its listing's icon")
			end
			SERVERS[#SERVERS + 1] = {address = address,
				name = tostring(r.name or address), players = r.players,
				icon = icon}
			listed = listed + 1
		end
	end
	if sp then
		sp.fetch(function() end)
	end
	log:info("servers: " .. listed .. " listed on Starport")
end
-- **The proof's padding is gone** ([LAUNCH_WORLD] stage 1(b), 2026-09-28).
-- Nine invented hostnames -- buildat.example.org, "the long night",
-- "scrapyard" and the rest -- stood on the floor to show what a room
-- full of servers looks like. They were a mock-up of a fetched
-- serverlist, and a first-time player, who is who this room is for
-- ([TWO_AUDIENCES]), met a lobby whose servers were props. A room shows
-- what there is.
--
-- **What an empty lobby shows instead is one sensible pick, said as
-- one**: localhost, which is a real thing to try -- a server this
-- client can start for itself -- and which says where its name is read
-- out that it is the room's suggestion rather than somewhere anybody is
-- playing. The check also needs one server it can name and fail to
-- reach, and this is it.
local real_servers = 0
for _, a in ipairs(FLOOR_ACTIONS) do
	if a.category == "server" then real_servers = real_servers + 1 end
end
do
	local sv = {name = "localhost", address = "127.0.0.1:29797"}
	local had = false
	for _, e in ipairs(SERVERS) do
		if e.address == sv.address then had = true break end
	end
	if not had then
		sv.example = true
		SERVERS[#SERVERS + 1] = sv
	end
end
-- **The room as the reference frame has it** (user, 2026-09-24): the
-- reference has the glowing orbs in their pockets only, with the wall
-- lit by the light from above -- while this room's floor carries the
-- launch actions, the saves and the servers, and a game the player
-- moved out of its pocket stands among them throwing its own light at
-- the wall. That is the room working; it is not the picture a look
-- reading or an options sheet should be taken from, because the wall
-- is then lit by something the reference does not have.
--
-- BUILDAT_LAUNCH_BARE=1 leaves the floor empty: the wall, its pockets,
-- the terminal and nothing else.
if env("BUILDAT_LAUNCH_BARE") ~= "" then
	local dropped = #FLOOR_ACTIONS + #SERVERS + #SAVES
	FLOOR_ACTIONS, SERVERS, SAVES = {}, {}, {}
	log:info("bare: the floor is empty, " .. dropped ..
			" things left out of it")
end

do
	local ex = 0
	for _, sv in ipairs(SERVERS) do if sv.example then ex = ex + 1 end end
	log:info("servers: " .. #SERVERS .. " on the floor, " .. ex ..
			" of them the room's own suggestion, " .. real_servers ..
			" off a fetched list")
end
-- **More games than the wall can hold stand on the floor** (the open
-- question this plan named: nine pockets fit across the wall and
-- ContentDB can install a game at any time). The wall answers what it
-- can hold and the rest go where everything that is not in the wall
-- goes -- still glowing, since a game is a game wherever it is, which
-- is what a game carried out of its pocket and put down already looks
-- like. The empty pocket stays last, being the way to ContentDB.
do
	-- BUILDAT_LAUNCH_POCKETS=<n> holds the wall to fewer than it could,
	-- which is how the spill is driven on a tree with nine games rather
	-- than waited for until somebody installs twenty.
	-- **BUILDAT_LAUNCH_PITCH=<voxels> and BUILDAT_LAUNCH_COLS=<n>** are
	-- the formation's column pitch and its spheres to a row, for reading
	-- other picks at the wall station ([LAUNCH_WORLD] stage 2)
	room.COL_PITCH = tonumber(env("BUILDAT_LAUNCH_PITCH")) or
			room.COL_PITCH
	room.COLS = tonumber(env("BUILDAT_LAUNCH_COLS")) or room.COLS
	-- **The architecture, as an options round** ([LAUNCH_WORLD] stage 3;
	-- local/options_for_LOBBY_arch/): BUILDAT_LAUNCH_ARCH=<name> picks a
	-- whole wall out of room.lua's M.ARCHES -- tomb (the default until
	-- the user's pick), calm, plain, bare. Before set_pockets(), which
	-- builds the slabs off it.
	log:info("arch: " .. room.set_arch(env("BUILDAT_LAUNCH_ARCH")))
	local want = tonumber(env("BUILDAT_LAUNCH_POCKETS")) or #GAMES
	local made = room.set_pockets(math.min(#GAMES, want))
	if made < #GAMES then
		local spill = {}
		-- The empty pocket is the last of GAMES and keeps its place
		local empty = table.remove(GAMES)
		while #GAMES > made - 1 do
			table.insert(spill, 1, table.remove(GAMES))
		end
		GAMES[#GAMES + 1] = empty
		for _, g in ipairs(spill) do
			g.floor = true
			g.game_orb = true
			table.insert(FLOOR_ACTIONS, 1, g)
		end
		log:info("the wall holds " .. made .. " of " ..
				(#GAMES + #spill - 1) .. " games; " .. #spill ..
				" stand on the floor")
	else
		-- **Said when nothing spills, too** ([LAUNCH_WORLD] stage 1(b)
		-- asks for every game on the wall, twenty-nine and not seven).
		-- The spill line was the only word on this, so "they all fit"
		-- read as silence and the clause could not be checked without
		-- counting orbs in a picture. Four walls at a pitch of six hold
		-- forty-six between them, which is more than this desk's
		-- twenty-eight.
		log:info("the wall holds all " .. (#GAMES - 1) .. " games in " ..
				made .. " pockets, none on the floor")
	end
end
-- **The tools are the terminal's, not the floor's** ([LAUNCH_WORLD]
-- stage 1(b): the tools family as lines on the terminal's screen). The
-- API's four families are games, saves, servers and tools, and a room
-- that shows the first three apart and then pours the fourth onto the
-- floor beside the saves is showing three families and a heap. An
-- action that says `category = "tool"` goes to the terminal instead.
TOOLS = {}
do
	local rest = {}
	for _, a in ipairs(FLOOR_ACTIONS) do
		if a.category == "tool" then
			TOOLS[#TOOLS + 1] = a
		else
			rest[#rest + 1] = a
		end
	end
	FLOOR_ACTIONS = rest
end
log:info("contents: " .. (#GAMES - 1) .. " games, " .. #FLOOR_ACTIONS ..
		" other launch actions, " .. #SAVES .. " saves, " .. #SERVERS ..
		" servers, " .. #TOOLS .. " tools on the terminal")
-- The one that installs a game, for the terminal's ContentDB row: the
-- tree has no extensions/contentdb, so what there is is an import action
install_action = nil
for _, a in ipairs(TOOLS) do
	if a.name:lower():find("import a game") or
			a.name:lower():find("install") then
		install_action = a
		break
	end
end

-- The ornament generator and the maps it feeds; see ornament.lua
local ornament = api.run_extension_file("ornament.lua")
-- **The voxel tiles are generated here and registered by name**, which
-- is the only way a generated picture reaches a voxel atlas: a tile is
-- loaded out of the resource cache by the name the voxel definition
-- gives, and this puts one there under it. The plan's rule is that the
-- generator and its seed are the source and the picture is a build
-- artefact, never committed -- so this is where the wall's material
-- comes from.
--
-- **Before the room is meshed**, or a face is drawn before its texture
-- exists and is drawn without it.
tiles = {}
local function register_tile(name, h, inlay, opts)
	local diff = ornament.maps(magic, h, inlay, opts)
	assert(magic.cache:AddManualResource(diff, name),
			"the generated tile went into the cache")
	-- Held: a resource the cache has is the cache's, but the wrapper is
	-- this script's and the Image would go with it. Its own table,
	-- because the tiles are registered before the world may stream and
	-- that is earlier than anything else here is built.
	tiles[#tiles + 1] = diff
	log:info("tile: generated/" .. name)
end

do
	local wh, wi = ornament.wall(128, ornament.seed_of("launch_world wall"))
	-- **Medium grey stone, and the orange is the light's** (user,
	-- 2026-09-23). The mineral patches were rust for a while, which put
	-- the reference frame's warmth in the albedo -- and that is not
	-- where it comes from: the reference's stone is grey and what makes
	-- it orange is what is shining on it. So the base is a medium grey
	-- and the patches are a shade off it in value rather than in hue.
	register_tile("wall.png", wh, wi,
			{base = magic.Color(0.50, 0.50, 0.50, 1),
			inlay = magic.Color(0.41, 0.41, 0.42, 1), relief = 0.35,
			strength = 2})
end
do
	-- **The frieze along a slab's edge.** A slab is one voxel tall, so
	-- the strip a player sees is one voxel high: the motif has to fill
	-- the tile and the tile has to be one voxel across, or the edge
	-- shows whichever quarter of a pattern its own height lands on. So
	-- one unit, no rules above or below it -- they fall outside a tile
	-- the band fills -- and uv_scale 1, which is one motif every 45 cm.
	-- **The band, not the meander** ([SIGIL_ROUND], 2026-09-24): one
	-- seed answers a whole frieze, in three kinds, where the meander
	-- drew one figure for every wall in every room. **At period one**,
	-- which is what a tile one voxel across can show -- the run that
	-- repeats every eight voxels waits on per-axis `uv_scale`, and
	-- pinning the cycle costs a sigil its beat and nothing else.
	-- **The whole run in one texture** ([SIGIL_ROUND], 2026-09-24): the
	-- band's period is `cycle * hold` voxels, and with `uv_scale` across
	-- and `uv_scale_v` up the wall can show a strip that long and one
	-- voxel tall. Every tile of the run is drawn side by side into one
	-- field, which is what the per-axis wrap then walks along.
	local fstyle = ornament.band_style(ornament.seed_of("launch_world frieze"))
	fstyle.band_height = 1.0
	frieze_run = fstyle.cycle * fstyle.hold
	local fh = ornament.field(96 * frieze_run, 0, 96)
	for t = 0, frieze_run - 1 do
		local tile = ornament.band(96, fstyle, t)
		for y = 0, 95 do
			for x = 0, 95 do
				ornament.put(fh, t * 96 + x, y, ornament.at(tile, x, y))
			end
		end
	end
	-- The inlay is the band's own field: what is carved is what takes
	-- the second material, where the meander set a rectangle around a
	-- figure that filled it
	local fi = fh
	log:info(("frieze: %s, %d voxels of run, one voxel tall"):format(
			fstyle.kind, frieze_run))
	register_tile("frieze.png", fh, fi,
			{base = magic.Color(0.50, 0.50, 0.50, 1),
			inlay = magic.Color(0.36, 0.36, 0.38, 1), relief = 0.85,
			strength = 5})
end
do
	-- The pockets' side columns, which are the one place the ornament
	-- goes now that the wall is one material ([LAUNCH_WORLD]: "the
	-- ornament is on its side columns and nowhere else")
	local cstyle = ornament.band_style(ornament.seed_of("launch_world column"))
	cstyle.cycle = 1
	local ch = ornament.band(128, cstyle, 0)
	local ci = ch
	register_tile("column.png", ch, ci,
			{base = magic.Color(0.46, 0.47, 0.52, 1),
			inlay = magic.Color(0.22, 0.20, 0.26, 1), relief = 0.8,
			strength = 4})
end

-- The room's sound, synthesised; see synth.lua
local synth = api.run_extension_file("synth.lua")

-- Held at module scope: a Lua-owned Image, Texture2D or Material is freed
-- when the last Lua reference goes, whatever is drawing with it
local kept = {}
-- **Every texture the room writes rather than loads.** Urho3D brings a
-- texture back after a change of screen mode by reloading its file, and
-- these have none -- they are drawn here, pixel by pixel. So the image
-- each was written from is kept beside it and put back when the context
-- goes ([BOX_PLAYTEST_3] (1); the voxel atlas has its own registry for
-- the same reason). Both ends also have to be held: a Lua table is not
-- a reference to the engine's object.
kept.written = {}
function written_texture(texture, image)
	kept.written[#kept.written + 1] = {texture, image}
	kept[#kept + 1] = image
	kept[#kept + 1] = texture
	return texture
end

-- **The room is authored in metres and lives on a 45 cm grid** (user's
-- reading of the reference frame: the eye sits at the centre of the
-- fourth stacked slab, which is 3.5 voxels to a 1.6 m eye). So one unit
-- of the scene is one voxel, and everything written below in metres is
-- multiplied by this on its way in -- which is what lets the numbers stay
-- readable while the voxelworld gets the grid it wants.
local VOXEL_M = 0.45
local U = 1 / VOXEL_M

-- Metres to units, for the places that do not go through part()
local function V(x, y, z)
	return magic.Vector3(x * U, y * U, z * U)
end


-- The classic raytrace floor, built rather than loaded: a 2x2 checker is
-- the one texture the look actually needs
-- The classic raytrace floor, built rather than loaded. squares is how
-- many across the image, since Plane.mdl's UVs run 0..1 over the whole
-- plane: at one square per half of it the floor is two grey rectangles,
-- not a checkerboard.
local function checker_texture(size, squares, a, b, filter)
	local image = magic.Image:new()
	assert(image:SetSize(size, size, 3), "Image:SetSize")
	local cell = size / squares
	for y = 0, size - 1 do
		for x = 0, size - 1 do
			local dark = (math.floor(x / cell) + math.floor(y / cell)) % 2 == 1
			image:SetPixel(x, y, dark and a or b)
		end
	end
	local texture = magic.Texture2D:new()
	assert(texture:SetData(image), "Texture2D:SetData")
	texture.filterMode = filter or magic.FILTER_NEAREST
	return written_texture(texture, image)
end

-- Urho3D's PBR techniques, on the client's own render path -- no render
-- path control needed, and none of the preferred-viewport machinery is in
-- the way. What they do want is PBR_INTENSITY below.
-- simplified: a diffuse colour, a roughness and a metalness, and no
-- material maps at all. The library of generated maps is the ornament
-- generator's work, further down the list.
local function material(colour, roughness, metallic, texture)
	local m = magic.Material:new()
	-- BUILDAT_LAUNCH_NOPBR=1 puts the stock non-PBR techniques on
	-- instead, which is the last thing between a scene that lights in
	-- HDR here and one that does not
	local pbr = env("BUILDAT_LAUNCH_NOPBR") == ""
	local t = magic.cache:GetResource("Technique",
			pbr and (texture and "Techniques/PBR/PBRDiff.xml" or
			"Techniques/PBR/PBRNoTexture.xml") or
			(texture and "Techniques/Diff.xml" or
			"Techniques/NoTexture.xml"))
	assert(t ~= nil, "the technique loaded")
	m:SetTechnique(0, t)
	if texture then m:SetTexture(magic.TU_DIFFUSE, texture) end
	m:SetShaderParameter("MatDiffColor", colour)
	m:SetShaderParameter("Roughness", roughness)
	m:SetShaderParameter("Metallic", metallic)
	kept[#kept + 1] = m
	return m
end

-- **The room's own scene.** There is no server and so no replicated
-- scene; the voxels are meshed into a node of this one like any other
-- model.
scene = magic.Scene()
scene:CreateComponent("Octree")

-- **The floor's two tiles and the dark under it**, generated like the
-- wall is: the plan's rule is that everything is generated and nothing
-- generated is committed, and as an extension there is no client_data
-- directory to put a picture in anyway.
do
	-- A field of nought: these three are colours, and what makes them a
	-- surface is the finish in the voxel definition, not a picture
	local flat = {size = 16}
	for i = 1, 16 * 16 do flat[i] = 0 end
	-- **The floor is the one surface the look reading still argues
	-- with** (2026-09-24): its light squares are the brightest thing in
	-- the room and they clip near the camera, which is where the 90th
	-- percentile and the white share sit over the reference frame's.
	-- What to do about it is the user's eye, so both halves of it are a
	-- knob rather than a decision: BUILDAT_LAUNCH_FLOOR_VALUE scales the
	-- light square's value and BUILDAT_LAUNCH_FLOOR_GLOSS its roughness
	-- (lower is glossier). floor_sheet.sh draws the options.
	-- **0.60 is the pick** (user, 2026-09-24, off the three-sheet
	-- round): at 1.00 the light squares were 47 per cent saturated and
	-- washed the reflection off; at 0.60 nothing clips and the floor
	-- reads as stone rather than as paper. The default is the number
	-- somebody looked at, not a flag over a number nobody chose.
	local fv = tonumber(env("BUILDAT_LAUNCH_FLOOR_VALUE")) or 0.60
	register_tile("floor_light.png", flat, flat,
			{base = magic.Color(0.72 * fv, 0.73 * fv, 0.76 * fv, 1),
				relief = 0})
	-- Near-black, which is what makes the checkerboard read as the
	-- reference's does: its median is 38 against a 90th of 171, and a
	-- dark tile at 0.10 lit from above is not dark
	register_tile("floor_dark.png", flat, flat,
			{base = magic.Color(0.045, 0.045, 0.055, 1), relief = 0})
	register_tile("dark.png", flat, flat,
			{base = magic.Color(0.05, 0.05, 0.06, 1), relief = 0})
end

-- **The voxel registry, in the order room.lua's ids are read back from.**
-- The atlas takes the normal and roughness maps off each tile's own
-- luminance, so what is set here is the finish and not a picture.
local voxel_reg = api.createVoxelRegistry()
-- A few types and nothing per voxel: the room's ids are bytes
voxel_reg:set_format("blocks")
local atlas_reg = api.createAtlasRegistry()
local function add_voxel(name, texture, solid, roughness, spec_strength,
		bumpiness, uv_scale, uv_scale_v)
	local vdef = api.VoxelDefinition()
	vdef.name.block_name = name
	vdef.name.segment_x = 0
	vdef.name.segment_y = 0
	vdef.name.segment_z = 0
	vdef.name.rotation_primary = 0
	vdef.name.rotation_secondary = 0
	vdef.handler_module = ""
	local textures = {}
	for i = 1, 6 do
		local seg = api.AtlasSegmentDefinition()
		seg.resource_name = texture or ""
		seg.total_segments = magic.IntVector2(texture and 1 or 0,
				texture and 1 or 0)
		seg.select_segment = magic.IntVector2(0, 0)
		seg.roughness = roughness or 0.9
		seg.spec_strength = spec_strength or 0.3
		seg.bumpiness = bumpiness or 0.5
		seg.translucency = 0.0
		seg.spots = 0.0
		seg.static_spots = 0.0
		textures[i] = seg
	end
	vdef.textures = textures
	vdef.edge_material_id = solid and
			api.VoxelDefinition.EDGEMATERIALID_GROUND or
			api.VoxelDefinition.EDGEMATERIALID_EMPTY
	vdef.physically_solid = solid
	vdef.fully_empty = not solid
	-- How many voxels this voxel's texture spans before it repeats
	-- ([WORLD_UV]); 1 is one stamp a voxel, as it always was
	vdef.uv_scale = uv_scale or 1
	-- And how many it spans upwards ([SIGIL_ROUND]): a frieze is a long
	-- strip one voxel tall, so it is eight across and one up. Nought is
	-- "the same as across", which is every voxel that does not say
	vdef.uv_scale_v = uv_scale_v or 0
	return voxel_reg:add_voxel(vdef)
end

room.id.air = add_voxel("air", nil, false)
-- **The wall's own material**, spanning eight voxels before it repeats so
-- that it reads as one cut surface rather than as a grid of stamps
room.id.stone = add_voxel("stone", "generated/wall.png", true,
		0.85, 0.10, 0.7, 8)
room.id.dark = add_voxel("dark", "generated/dark.png", true, 0.95, 0.1, 0.4)
-- The pockets' side columns, which are the one place the ornament goes
room.id.column = add_voxel("column", "generated/column.png", true,
		0.70, 0.20, 0.9, 4)
-- **The one voxel the player may place** ([LAUNCH_WORLD] step 8): the
-- ornamented stone, so a placed voxel is told from the room's own at a
-- glance -- which matters, the room's own being the one thing that
-- cannot be dug
room.id.placed = add_voxel("placed", "generated/column.png", true,
		0.70, 0.20, 0.9, 4)
-- A slab's own edge, one motif a voxel
-- Eight voxels of frieze across and one up ([SIGIL_ROUND]); the run's
-- own length is whatever the style's cycle came out at
room.id.frieze = add_voxel("frieze", "generated/frieze.png", true,
		0.78, 0.16, 0.85, frieze_run, 1)
-- Kept, because the ornament toggle puts plain stone in its place
column_id = room.id.column
-- The checkerboard: the light squares are polished, which is what puts
-- the room's reflection in the floor
-- Polished: a reflective floor is half the reference frame, and what it
-- reflects is the probe's cube map -- the room itself
-- The floor's gloss, the other half of the knob above: the two squares
-- keep their two hundredths of difference, so what moves is the finish
-- and not the pattern
-- **The finish, and what this knob really does** (measured 2026-09-24):
-- roughness picks a **mip level** of the reflection probe through
-- `GetMipFromRoughness`, so it moves in steps and has as many distinct
-- values as the probe has levels -- **one**, while the room's probe is
-- the float16 cube [PBR_HDR] settled on, which this driver will not
-- filter a chain for. Shot against a mip chain it has a handful:
-- 0.02 and 0.04 came out byte-identical and the rest of the range
-- differed by under two levels of 255. So this is the surface's
-- roughness for the lights, and **not** a blur knob for the
-- reflection; a knob that did less than it said cost two afternoons
-- here already.
local fg = tonumber(env("BUILDAT_LAUNCH_FLOOR_GLOSS")) or 0.04
room.id.floor_light = add_voxel("floor_light", "generated/floor_light.png",
		true, fg, 1.0, 0.15)
room.id.floor_dark = add_voxel("floor_dark", "generated/floor_dark.png",
		true, fg + 0.02, 1.0, 0.15)

-- **The room in chunks across x**, so that a dissolve re-meshes the one
-- or two the bay touches rather than the whole room. Each chunk is told
-- where its own zero sits, which is what a voxel of uv_scale > 1 takes
-- its slice of the repeat from ([WORLD_UV]).
-- **The room's geometry is drawn with voxel_shading's own technique**, the
-- one builtin/voxel_shading hands voxelworld's chunks. There is no server
-- to send that module's client_data, so the client's resource router
-- falls back to builtin/<module>/client_data for a name nobody announced;
-- the mesher itself sets no technique, and a node without one is
-- invisible rather than unlit (2026-09-23).
-- **The room's own variant of the voxel technique** ([LAUNCH_WORLD],
-- 2026-09-24): the same shading with VOXELROOMPROBE compiled in, which
-- is the answer to "is this cube map the sky, or this room?" -- the
-- parallax correction on and the sky-visibility gating off. A game with
-- a sky keeps the plain one, whose shader has none of it, which is what
-- keeps [LOOK_CHECK]'s rule satisfiable rather than argued about.
local VOXEL_TECHNIQUE = magic.cache:GetResource("Technique",
		"voxel_shading/PBRVoxelRoom.xml")
assert(VOXEL_TECHNIQUE, "voxel_shading/PBRVoxelRoom.xml is in the cache")
-- **What makes the voxels reflect.** `PBRVoxel` has image-based lighting
-- (VOXELIBL), and it is gated three ways -- by a table of how much sky is
-- visible along a direction, by how much light is on that sky, and by a
-- specular emphasis -- all of which `builtin/voxel_shading`'s module.lua
-- keeps up to date for a world with a sky. This room has no server and no
-- module, so all three read zero and the floor reflected nothing while the
-- chrome spheres, on stock PBR, reflected the room (user, 2026-09-23:
-- can the floor be reflective too).
--
-- **The sky is visible in every direction here**, because what the cube
-- map holds is not a sky but the room itself: the reflection probe. So
-- the table is filled with ones -- six faces of six by six cells, packed
-- four to a vec4 -- and the other two are 1.
local SKYVIS_CELLS = 6
local sky_vis_buffer = magic.VectorBuffer:new()
do
	local ones = {}
	for i = 1, 6 * SKYVIS_CELLS * SKYVIS_CELLS do
		ones[i] = 1.0
	end
	api.write_floats(sky_vis_buffer, ones)
end
local SKY_VIS = magic.Variant(sky_vis_buffer)

-- **The probe's own point and the box the room fills**, in scene units
-- (one unit is one voxel). The floor is wide and flat and the probe is a
-- point two metres up in the middle of the room, so without this the
-- floor reflects the room as seen from there -- which is what "the
-- reflection has the wrong field of view" looks like. The box is the
-- room's own extent, a voxel outside each face, which is where a
-- reflected ray leaves the room.
-- One table, not three names: this chunk is at Lua's limit of 200 locals
local probe_box = {
	-- How much the floor reflects: a multiplier on the specular colour
	-- the room hands its voxels, 1 being the dielectric eight per cent
	-- the shader assumes ([LAUNCH_WORLD]'s floor round, second axis)
	-- 1.0 is the dielectric eight per cent the shader assumes and is
	-- what the round was judged at. **Above 1 is not a physical
	-- dielectric** -- it is a floor lying about its own material, which
	-- may still be the right look and is a pick rather than a fix.
	spec = tonumber(env("BUILDAT_LAUNCH_FLOOR_SPEC")) or 1.0,
	at = magic.Vector3(0, 2.0 * U, 0),
	min = magic.Vector3(room.X_MIN - 1, room.FLOOR_TOP, room.Z_MIN - 1),
	max = magic.Vector3(room.X_MAX + 1, room.Y_TOP + 1, room.Z_MAX + 1),
}

local function apply_technique(node)
	local cg = node:GetComponent("CustomGeometry")
	local i = 0
	while true do
		local m = cg:GetMaterial(i)
		if m == nil then break end
		m:SetTechnique(0, VOXEL_TECHNIQUE)
		-- The mesher does not pack the sky into the vertex alpha here, and
		-- the shadow-kind diagnostic is off
		m:SetShaderParameter("PackedSky", 0.0)
		m:SetShaderParameter("ShadowKinds", 0.0)
		-- **Where the probe stands and the box it holds** (user,
		-- 2026-09-24: "the reflection might have the wrong FOV"). A
		-- cube map is the room seen from one point, and a floor
		-- reflecting it without correction shows the room as seen from
		-- that point rather than from the floor -- objects at the
		-- wrong size and in the wrong place, which reads as a wrong
		-- field of view. The shader follows the reflected ray to the
		-- box and looks up the hit point instead; these three are what
		-- it needs, in the scene's own units.
		-- **Something to reflect with** (2026-09-24): `PBRVoxel` builds
		-- its specular colour as `0.08 * specStrength * cMatSpecColor`,
		-- and Urho3D's default for `MatSpecColor` is **black** -- so
		-- every voxel material the mesher hands over reflects with a
		-- specular colour of zero and all that is left of the
		-- image-based term is the sliver `METALNESS_FLOOR` leaves
		-- (measured: 0.02 to 0.04 where the other factors are 1).
		-- White is what the shader's own 0.08 expects, and it is the
		-- **atlas** that says which voxel is polished: the floor's
		-- tiles carry a spec_strength of 1 and the stone 0.10, so this
		-- makes the floor a dielectric mirror and leaves the wall matte.
		-- **And how much of a mirror it is** (user, 2026-09-24: none of
		-- the glosses shot are enough). A dielectric reflects about
		-- four per cent straight on whatever its roughness -- what
		-- mirrors a wet road is Fresnel at a grazing angle -- so the
		-- missing quantity underfoot is **reflectance, not
		-- smoothness**. The shader's `0.08 * specStrength *
		-- cMatSpecColor` says where to put it, and because
		-- `specStrength` is per texel from the atlas, scaling this
		-- moves the **floor** (1.0) and barely touches the stone
		-- (0.10). Above one it is no longer a physical dielectric,
		-- which is the pick rather than the fix: a mirror floor with no
		-- diffuse reads as glass rather than stone.
		m:SetShaderParameter("MatSpecColor",
				magic.Color(probe_box.spec, probe_box.spec,
					probe_box.spec, 1))
		m:SetShaderParameter("ProbeBox", 1.0)
		m:SetShaderParameter("ProbePos", probe_box.at)
		m:SetShaderParameter("ProbeBoxMin", probe_box.min)
		m:SetShaderParameter("ProbeBoxMax", probe_box.max)
		-- The three that let the reflection through
		m:SetShaderParameter("SkyVis", SKY_VIS)
		m:SetShaderParameter("SkyLight", 1.0)
		m:SetShaderParameter("SpecEmphasis", 1.0)
		-- And the terms this room has none of: no sky to tint, no
		-- bounce or ground or lamp light, nothing translucent
		m:SetShaderParameter("SkyTintAmount", 0.0)
		m:SetShaderParameter("BounceLight", 0.0)
		m:SetShaderParameter("GroundLight", 0.0)
		m:SetShaderParameter("LampLight", 0.0)
		m:SetShaderParameter("CaveAmbient", magic.Vector3(light_look.cave[1],
				light_look.cave[2], light_look.cave[3]))
		m:SetShaderParameter("TranslucencyGain", 0.0)
		i = i + 1
	end
end

-- **Where a voxel is, in the scene: on its own index.** A voxel spans
-- [v - 0.5, v + 0.5], and everything else in the room -- the orbs, the
-- lights, a pocket's mouth -- is already placed at a plain index, so
-- this is the convention and the mesher's block is what was moved to
-- meet it (see mesh_chunk). One place for it, and one for the inverse.
local function at_voxel(x, y, z)
	return magic.Vector3(x, y, z)
end

-- And back: which voxel a point in the scene is in: the nearest index.
local function voxel_of(p)
	return math.floor(p + 0.5)
end

-- **Everything the room puts on ui.root, in one list.** A game's own
-- screens come up over the room and the room's must go away while they
-- are there -- and come back after ([MENU_CONTEXT]). The client sweeps
-- the game's elements off on the way back; these are the room's, and it
-- hides and shows them itself.
room_ui = {}
local function room_ui_child(kind)
	local e = magic.ui.root:CreateChild(kind)
	room_ui[#room_ui + 1] = e
	return e
end

-- **Blocks, not columns** (2026-09-26). The wall used to be meshed in
-- six slices 16 wide and the room's full 32 by 77 -- and a drawable is
-- culled by its bounding box, so every one of the ten orbs' cube shadow
-- maps redrew whole slices of room for a light that reaches 11 voxels.
-- That was 3.85 of the frame's 5.17 million triangles. A block the
-- light's own size lets the frustum do its work.
-- **Blocks, not columns** (2026-09-26). The wall used to be meshed in
-- six slices 16 wide and the room's full 32 by 77 -- and a drawable is
-- culled by its bounding box, so every one of the ten orbs' cube shadow
-- maps redrew whole slices of room for a light that reaches 11 voxels.
-- That was 3.85 of the frame's 5.17 million triangles.
-- **One table and not seven locals**: this file is at Lua 5.1's limit of
-- 200 in a main chunk, and a block of stone is not worth a name each.
local blk = {
	-- Measured: 8 and 12 mesh no faster and cost half again as many
	-- batches, 32 draws a fifth more triangles
	size = 16,
	nodes = {},
	checked = false,
}
rows = room.build()
blk.nx = math.ceil(room.W / blk.size)
blk.ny = math.ceil(room.H / blk.size)
blk.nz = math.ceil(room.D / blk.size)
blk.air = string.char(room.id.air)
-- The block an index is in, and the one key the three make
function blk.of(i, o) return math.floor((i - o) / blk.size) end
function blk.key(cx, cy, cz) return (cz * blk.ny + cy) * blk.nx + cx end
local function mesh_chunk(cx, cy, cz)
	local n = blk.size
	local x0, y0, z0 = cx * n, cy * n, cz * n
	local w = math.min(n, room.W - x0)
	local h = math.min(n, room.H - y0)
	local d = math.min(n, room.D - z0)
	local data = {}
	local at = 0
	for z = z0, z0 + d - 1 do
		for y = y0, y0 + h - 1 do
			at = at + 1
			data[at] = rows[z * room.H + y + 1]:sub(x0 + 1, x0 + w)
		end
	end
	local blob = table.concat(data)
	local key = blk.key(cx, cy, cz)
	local node = blk.nodes[key]
	-- Most of a room is the air in it: a block of nothing gets no node
	if node == nil and blob == string.rep(blk.air, #blob) then
		return
	end
	if not node then
		node = scene:CreateChild("room" .. key)
		-- **The mesher centres a block on its node** (mesh.cpp: every
		-- vertex is its voxel less half the block), so the node goes to
		-- the block's middle rather than to its corner. The half is the
		-- voxel's own: a voxel v fills [v, v + 1), which is what makes
		-- the floor's top face the room's metre zero.
		-- **A whole voxel short of where the arithmetic says.** Measured
		-- rather than derived, after three wrong guesses at the box's
		-- end: with the node at OX + x0 + w/2 + 0.5, a 16-wide chunk of
		-- indices -47..-32 reported a world bounding box of -46.5..-30.5,
		-- so the mesher centres voxel i on i + 1. PolyVox's cubic
		-- extractor puts voxel i's far corner at pv = i + 1 and the
		-- mesher's pv - w/2 - 0.5 takes off only half of it. Moving the
		-- block instead of the box keeps the stone on the same indices
		-- as everything else in the room.
		node.position = magic.Vector3(room.OX + x0 + w / 2 - 0.5,
				room.OY + y0 + h / 2 - 0.5, room.OZ + z0 + d / 2 - 0.5)
		blk.nodes[key] = node
	end
	api.set_8bit_voxel_geometry(node, w, h, d, blob, voxel_reg, atlas_reg,
			room.OX + x0, room.OY + y0, room.OZ + z0)
	apply_technique(node)
	-- **The check that settles it**: the block's own bounding box against
	-- the indices it was built from. A voxel spans half a unit each side
	-- of its index, so the block stands inside the indices it was built
	-- from. This is what three guesses at the selection box's position
	-- could not tell apart. The first block with stone in it, since the
	-- corner one is air.
	if not blk.checked then
		blk.checked = true
		local bb = node:GetComponent("CustomGeometry").worldBoundingBox
		local want = {room.OX + x0 - 0.5, room.OY + y0 - 0.5,
				room.OZ + z0 - 0.5}
		local got = {bb.min.x, bb.min.y, bb.min.z}
		for i = 1, 3 do
			assert(got[i] >= want[i] - 0.01,
					("the meshed block starts at %.2f, outside %.2f, on " ..
					"axis %d"):format(got[i], want[i], i))
		end
		log:info(("block %d sits on its indices: %.2f %.2f %.2f .. " ..
				"%.2f %.2f %.2f"):format(key, bb.min.x, bb.min.y, bb.min.z,
				bb.max.x, bb.max.y, bb.max.z))
	end
end
function blk.all()
	for cz = 0, blk.nz - 1 do
		for cy = 0, blk.ny - 1 do
			for cx = 0, blk.nx - 1 do
				mesh_chunk(cx, cy, cz)
			end
		end
	end
end
blk.all()

-- The whole room again from room.lua's description: what wants it is the
-- ornament toggle, which changes what a voxel is rather than what is
-- drawn over it
function rebuild_room()
	rows = room.build()
	blk.all()
end
blk.built = 0
for _ in pairs(blk.nodes) do blk.built = blk.built + 1 end
log:info("room: " .. room.W .. "x" .. room.H .. "x" .. room.D ..
		" voxels of 45 cm in " .. blk.built .. " blocks of " .. blk.size ..
		" that have anything in them")

-- The dissolve rewrites the pocket's own box and re-meshes what it
-- touched; the room is generated and never saved, so the description in
-- room.lua is the only state there is.
local function rewrite_box(x0, x1, y0, y1, z0, z1, open)
	local touched = {}
	for z = z0, z1 do
		for y = y0, y1 do
			local ri = room.row_index(y, z)
			local rw = rows[ri]
			if rw then
				local out = {}
				for x = x0, x1 do
					local i = x - room.OX + 1
					if i >= 1 and i <= room.W then
						out[#out + 1] = {i, string.char(open and room.id.air or
								room.voxel_at(x, y, z))}
					end
				end
				local cy = blk.of(y, room.OY)
				local cz = blk.of(z, room.OZ)
				for _, e in ipairs(out) do
					rw = rw:sub(1, e[1] - 1) .. e[2] .. rw:sub(e[1] + 1)
					local cx = math.floor((e[1] - 1) / blk.size)
					touched[blk.key(cx, cy, cz)] = {cx, cy, cz}
				end
				rows[ri] = rw
			end
		end
	end
	for _, c in pairs(touched) do
		mesh_chunk(c[1], c[2], c[3])
	end
end

-- Ambient near zero: nothing in this room is lit by "the environment",
-- everything is lit by a source you can point at
local zone_node = scene:CreateChild("Zone")
local zone = zone_node:CreateComponent("Zone")
zone.boundingBox = magic.BoundingBox(-200, 200)
-- **Nought, and it has to be**: the voxel shader multiplies the zone's
-- ambient by the skylight share, which in a sealed room is nought
-- everywhere, so raising this moves nothing at all. What stands for the
-- bounce is the pair of directional lights below.
zone.ambientColor = magic.Color(light_look.zone[1], light_look.zone[2],
		light_look.zone[3], 1)
zone.fogColor = magic.Color(0, 0, 0, 1)
zone.fogStart = 26 * U
zone.fogEnd = 64 * U

local function part(model, pos, scale, mat)
	local node = scene:CreateChild("part")
	node.position = magic.Vector3(pos.x * U, pos.y * U, pos.z * U)
	node.scale = magic.Vector3(scale.x * U, scale.y * U, scale.z * U)
	local object = node:CreateComponent("StaticModel")
	object.model = magic.cache:GetResource("Model", "Models/" .. model .. ".mdl")
	object.material = mat
	object.castShadows = true
	return node
end

local chrome = material(magic.Color(0.92, 0.94, 0.97, 1), 0.06, 1.0)
local machined = material(magic.Color(0.55, 0.57, 0.62, 1), 0.34, 1.0)
local stone = material(magic.Color(0.26, 0.26, 0.29, 1), 0.85, 0.0)
-- A launch action that is not a game: glossy and white, a dielectric
-- rather than a metal, so it reads as neither an orb nor a server
-- **The white spheres are grey** (user, 2026-09-24: the blow-out is bad
-- for the mark's visibility). At 0.86 they sit 20 to 47 per cent
-- saturated in the room's own light, and a picture on a surface that is
-- at 255 over a third of itself is a picture half erased. The albedo is
-- what buys the headroom, and **a grey ball among dark stone still
-- reads as white** -- white is relative and there is nothing brighter
-- beside it to argue with. 0.6 is the starting pick, moved by eye;
-- BUILDAT_LAUNCH_WHITE_V is the knob for moving it.
local WHITE_V = tonumber(env("BUILDAT_LAUNCH_WHITE_V")) or 0.60
local white = material(magic.Color(WHITE_V, WHITE_V * 1.01, WHITE_V * 1.03, 1),
		0.12, 0.0)

-- A material wearing a generated height field: the ornament is the
-- texture and not the geometry, which is what lets the room sit on a
-- 45 cm grid and still carry a meander ([LAUNCH_WORLD]'s own reading of
-- the reference frame).
local ORN_SIZE = 128
local function ornamented(h, inlay, opts)
	local diff, norm = ornament.maps(magic, h, inlay, opts)
	local dt, nt = magic.Texture2D:new(), magic.Texture2D:new()
	assert(dt:SetData(diff), "the ornament's albedo")
	assert(nt:SetData(norm), "the ornament's normal")
	written_texture(dt, diff)
	written_texture(nt, norm)
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/PBR/PBRDiffNormal.xml"))
	m:SetTexture(magic.TU_DIFFUSE, dt)
	m:SetTexture(magic.TU_NORMAL, nt)
	m:SetShaderParameter("MatDiffColor", magic.Color(1, 1, 1, 1))
	m:SetShaderParameter("Roughness", (opts or {}).roughness or 0.75)
	m:SetShaderParameter("Metallic", (opts or {}).metallic or 0.0)
	-- **The frieze has to tile.** A Box's UVs run 0..1 over a face, so
	-- one 128-texel meander stretched across nine metres of frieze is
	-- four metres a unit and reads as a plain band. Urho3D's UOffset and
	-- VOffset are the scale, as a Vector4 whose x and y are the tiling.
	local uv = (opts or {}).uv
	if uv then
		-- A Color, not a Vector4: the sandbox's SetShaderParameter takes
		-- no Vector4, and a Color carries the same four floats into the
		-- same uniform
		m:SetShaderParameter("UOffset", magic.Color(uv[1], 0, 0, 0))
		m:SetShaderParameter("VOffset", magic.Color(0, uv[2], 0, 0))
	end
	kept[#kept + 1] = m
	return m
end

-- An unlit material draws at its own colour whatever the light does,
-- which is what an orb that *is* the light needs; it also lands in the
-- probe, so the chrome has something bright to reflect.
--
-- **The mark is a hole in the glow, not a picture on it** (user): the
-- texture multiplies the orb's own colour, so where the mark is the
-- light is not -- a silhouette inside the light, the way a lantern's
-- cut-out works, rather than a sticker fighting the emission.
-- **One texture, three materials** (the plan): the mark masks the
-- emission on a glowing orb, and the same picture darkens into an etch
-- on a white or a chrome one. Generated from the name where the thing
-- ships no icon of its own.
marks_own = 0
-- **The whole mark, not the middle of it** (user, 2026-09-23: only the
-- centre of a logo shows, because the sphere's UV region crops the tile
-- it is drawn on). The picture is drawn into the middle half of its
-- tile and the rest is left as "no mark", so what the orb carries is
-- the logo entire.
local MARK_SIZE = 128
-- How many pixels of the last mark were the mark, which is what says a
-- thing has one at all and that two things do not share it
last_mark_ink = 0
-- **And one bit, not a shade, where the mark cuts a glow** (user, and
-- the arithmetic agrees): a glowing orb's emissive is multiplied by 26
-- so that its smallest channel clears saturation, and a masked pixel
-- only comes back out of white if its mask falls below about 1/26 --
-- four per cent. Anything greyer than that still saturates, so on a
-- glowing orb the mark is nought where it cuts and one where it does
-- not. The threshold is luminance, and **alpha decides first**: most
-- icons are cut-outs, and a transparent pixel is background whatever
-- colour it is.
-- The luminance an icon's own picture is cut at, and -- for a mark
-- generated from a name -- **how much of it is the mark**: the darkest
-- fifth of the picture, which is a legible glyph at the size a sphere
-- gives it and not so much that the orb stops reading as a light. One
-- table, since this chunk is at Lua's limit of 200 locals.
-- The luminance a mark's picture is cut at, and the quarter turn
-- between "-Z at the viewer" and "the middle of the UV map at the
-- viewer", measured on Sphere.mdl (see the turn below). One table,
-- since this chunk is at Lua's limit of 200 locals.
local ONE_BIT = {AT = 0.5, INK = 0.16, T_LO = 0.02,
		FACE_YAW = tonumber(env("BUILDAT_LAUNCH_FACE_YAW")) or 270,
		T_HI = 0.60, T_STEP = 0.01,
		-- **What survives under the mark on a glowing orb**
		-- ([GLOW_MARK], picked off the sheet 2026-09-24), stated as the
		-- emissive fraction and not as a brightness: the emissive is
		-- multiplied by 26, so a masked pixel only comes out of
		-- saturation below about 1/26. 0.04 is the top of that band --
		-- the faintest mark that still reads, and a darker orange
		-- rather than a hole in the light. It moves with the
		-- multiplier: one over it.
		CUT = tonumber(env("BUILDAT_LAUNCH_GLOW_CUT")) or 0.04,
		-- The figure: the mask itself, or its boundary alone
		-- (BUILDAT_LAUNCH_MARK_FIGURE=outline)
		FIG = env("BUILDAT_LAUNCH_MARK_FIGURE")}

-- **The boundary of a mask** ([GLOW_MARK]): on a glowing orb a solid
-- mark is a hole punched in the light and an outline is a drawing left
-- on it. A pixel stays on when any of its four neighbours is off, and
-- what is outside the square counts as off. On ONE_BIT rather than a
-- local of its own -- this chunk is at Lua's limit of 200.
function ONE_BIT.outline(bits, n)
	local out = {}
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local i = y * n + x
			out[i] = bits[i] and (x == 0 or y == 0 or x == n - 1 or
					y == n - 1 or not bits[i - 1] or not bits[i + 1] or
					not bits[i - n] or not bits[i + n]) or false
		end
	end
	return out
end

-- **A pixel as an integer, not as a Colour** ([ROOM_BOOT], 2026-09-24):
-- Urho3D's SetPixelInt takes 0xAABBGGRR, which is what Color::ToUInt()
-- packs, and a generated tile is four thousand pixels with seventy of
-- them at boot -- a quarter of a million objects nobody ever looks at.
function ONE_BIT.rgb(r, g, b)
	local function q(v)
		v = math.floor(v * 255)
		if v < 0 then v = 0 elseif v > 255 then v = 255 end
		return v
	end
	return 255 * 16777216 + q(b) * 65536 + q(g) * 256 + q(r)
end

-- **The one-bit transform, settled** ([MARK_ONEBIT], user 2026-09-24):
-- the logo comes down to the tile's own size first, and what is marked
-- is **where the picture changes** rather than which side of it is ink
-- -- so a logo of white lines on transparency cannot vanish the way it
-- did under a luminance cut, and a coloured logo does not come out as
-- the blob an alpha cut makes of it.
--
-- A feature is the **largest per-channel colour difference** to a drawn
-- neighbour: two patches can differ in hue at one brightness and be the
-- strongest thing in a picture, which luminance scores at zero rather
-- than low. Taken among drawn pixels only -- an undrawn neighbour would
-- make a cut-out's own edge the strongest feature and every line-art
-- icon fat.
--
-- The threshold is **searched, not chosen**: what a person reads across
-- the room is how much of the sphere the mark covers, so `t` is
-- whatever lands nearest ONE_BIT.INK, ties to the higher one (the
-- sparser mark is the safer). No fixed number serves both a flat icon
-- and a photograph. The search is over a histogram rather than over the
-- picture once per threshold, this being boot time and seventy orbs.
--
-- The mask is that union with the **alpha silhouette**, and when
-- nothing reaches the target the cut-out is the only other mark there
-- is -- but only when there is one: on an opaque thumbnail alpha is the
-- whole tile, which is a black sphere and worse than the specks it
-- replaces. Then the picture has no mark in it, and a game whose logo
-- has none gets the room's generated sigil.
function ONE_BIT.mask(src, n)
	local sw, sh = src.width, src.height
	local r, g, b, a = {}, {}, {}, {}
	-- **Down first, then decide**: the picture is judged at the size the
	-- sphere gives it. A box average rather than a point sample, since
	-- a 128-pixel icon read at every other pixel aliases its own lines
	-- away and the feature field is then noise; the reference sheet
	-- resizes with Lanczos and the two land within two points of ink on
	-- every logo this tree ships.
	local k = math.floor(sw / n)
	if k < 1 then k = 1 elseif k > 4 then k = 4 end
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local sx, sy = math.floor(x * sw / n), math.floor(y * sh / n)
			local cr, cg, cb, ca, m = 0, 0, 0, 0, 0
			for oy = 0, k - 1 do
				for ox = 0, k - 1 do
					if sx + ox < sw and sy + oy < sh then
						local c = src:GetPixel(sx + ox, sy + oy)
						cr, cg, cb, ca = cr + c.r, cg + c.g, cb + c.b, ca + c.a
						m = m + 1
					end
				end
			end
			local i = y * n + x
			r[i], g[i], b[i], a[i] = cr / m, cg / m, cb / m, ca / m
		end
	end
	local feature, edge, buckets = {}, {}, {}
	local nb = math.floor((ONE_BIT.T_HI - ONE_BIT.T_LO) / ONE_BIT.T_STEP) + 1
	for i = 1, nb do buckets[i] = 0 end
	local edges, drawn_n = 0, 0
	for y = 0, n - 1 do
		for x = 0, n - 1 do
			local i = y * n + x
			local drawn = a[i] >= 0.5
			if drawn then drawn_n = drawn_n + 1 end
			local best, ahi, alo = 0.0, a[i], a[i]
			for k = 1, 4 do
				local nx = x + (k == 3 and -1 or (k == 4 and 1 or 0))
				local ny = y + (k == 1 and -1 or (k == 2 and 1 or 0))
				if nx >= 0 and nx < n and ny >= 0 and ny < n then
					local j = ny * n + nx
					if a[j] > ahi then ahi = a[j] end
					if a[j] < alo then alo = a[j] end
					if drawn and a[j] >= 0.5 then
						local d = math.abs(r[i] - r[j])
						local dg = math.abs(g[i] - g[j])
						local db = math.abs(b[i] - b[j])
						if dg > d then d = dg end
						if db > d then d = db end
						if d > best then best = d end
					end
				end
			end
			feature[i] = best
			edge[i] = (ahi - alo) > 0.5
			if edge[i] then
				edges = edges + 1
			else
				-- Which thresholds this pixel is still ink at: the
				-- bucket it falls in and every one below it
				local k = math.floor((best - ONE_BIT.T_LO) / ONE_BIT.T_STEP)
				if k >= nb then k = nb - 1 end
				if k >= 0 then buckets[k + 1] = buckets[k + 1] + 1 end
			end
		end
	end
	local total = n * n
	local above, best_t, best_d = 0, ONE_BIT.T_LO, nil
	for k = nb, 1, -1 do
		above = above + buckets[k]
		local t = ONE_BIT.T_LO + (k - 1) * ONE_BIT.T_STEP
		local d = math.abs((edges + above) / total - ONE_BIT.INK)
		-- Walking down from the highest threshold, `<` keeps the higher
		-- one on a tie
		if best_d == nil or d < best_d then
			best_d, best_t = d, t
		end
	end
	local share = 0
	local mask = {}
	for i = 0, total - 1 do
		mask[i] = edge[i] or feature[i] > best_t
		if mask[i] then share = share + 1 end
	end
	-- How this tile was arrived at, for the log: the fallbacks below
	-- overwrite it
	ONE_BIT.last = ("%dpx t %.2f"):format(sw, best_t)
	if share / total < ONE_BIT.INK * 0.4 then
		if drawn_n / total < 0.45 then
			for i = 0, total - 1 do
				mask[i] = a[i] >= 0.5
			end
			share = drawn_n
			ONE_BIT.last = ("%dpx cut-out"):format(sw)
		else
			-- Neither the edges nor a cut-out: **this picture has no
			-- mark in it**, and the room's generated sigil is what such
			-- a game gets. Saying so is the caller's cue -- an alpha
			-- cut on an opaque thumbnail is the whole tile, a black
			-- sphere, and worse than the specks it would replace.
			ONE_BIT.last = ("%dpx none"):format(sw)
			return nil, 0
		end
	end
	return mask, share
end
-- **Which pixels are the mark**: a cut-out says so with its alpha, and
-- the plan's rule is alpha first. But an icon that is white lines on
-- transparency -- the buildat logo, and most of this tree's -- has
-- *luminance* 1 everywhere it is drawn, so a luminance threshold makes
-- it vanish. So: if the picture has transparency at all, the shape is
-- its alpha; if it does not, the shape is its dark ink.
local function bit_of(c, cutout)
	if cutout then
		return c.a >= 0.5
	end
	return (c.r * 0.299 + c.g * 0.587 + c.b * 0.114) < ONE_BIT.AT
end

local function is_cutout(src)
	local w, h = src.width, src.height
	local clear = 0
	for y = 0, 7 do
		for x = 0, 7 do
			local c = src:GetPixel(math.floor(x * w / 8),
					math.floor(y * h / 8))
			if c.a < 0.5 then clear = clear + 1 end
		end
	end
	return clear >= 4
end

-- `invert` swaps what the bit means, because the two slots want
-- opposite polarity: a glow **mask** keeps the light where it is one
-- and cuts it where it is nought, and a **roughness** map leaves the
-- surface where it is nought and roughens it where it is one. The same
-- picture, read from either end.
-- `generated` says the picture is the room's own sigil rather than a
-- game's logo: a height field already cut to black and white, whose
-- ink *is* the mark. The settled transform marks where a picture
-- changes, which on a sigil means its outline alone -- and a sigil
-- that fails the transform's ink target would come back as "no mark"
-- and leave the orb bare, which is what it was the answer to.
-- **`src` is an `Image` or one of ornament.lua's own fields**
-- ([ROOM_BOOT], 2026-09-24): the generated path had its figure in Lua
-- already, wrote it into an `Image` a pixel at a time and had this read
-- the same square straight back out -- four thousand `SetPixel`, four
-- thousand `GetPixel` and eight thousand wrapped calls an orb, seventy
-- times over, for a picture that never left the process. A field is
-- read directly.
local function mark_image(src, one_bit, invert, slot, generated)
	local img = magic.Image:new()
	-- **The tile is built as bytes and handed over once** ([ROOM_BOOT],
	-- 2026-09-24): seventy marks at four thousand SetPixel calls each
	-- was a quarter of a million crossings of the sandbox and six
	-- seconds of black window. `rows` is the tile, row by row, three
	-- bytes a pixel; image_set_data takes the whole of it.
	local bg = invert and 0.0 or 1.0
	local bgb = string.char(math.floor(bg * 255)):rep(3)
	-- The drawn square and where it sits, declared before the two
	-- helpers below read them
	local inner = math.floor(MARK_SIZE / 2)
	local off = math.floor((MARK_SIZE - inner) / 2)
	-- **Row by row, not pixel by pixel**: the tile is mostly background
	-- and only its middle square is drawn, so the rows outside that are
	-- one string each and the rows inside are the left pad, the square
	-- and the right pad. Sixteen thousand little strings a tile was
	-- most of what was left of the boot ([ROOM_BOOT]).
	local px = {}
	local function q(v)
		v = math.floor(v * 255)
		if v < 0 then v = 0 elseif v > 255 then v = 255 end
		return v
	end
	local function set(x, y, r, g, b)
		px[y * MARK_SIZE + x + 1] = string.char(q(r), q(g), q(b))
	end
	-- The one-bit path has two possible pixels: the mark and the ground
	local function triple(v)
		if slot == "rough" then return string.char(q(v), 0, 0) end
		if slot == "metal" then return string.char(0, q(v), 0) end
		return string.char(q(v), q(v), q(v))
	end
	-- The glow slot is the only one whose mark goes through the
	-- emissive cut, so [GLOW_MARK]'s lightness is read here alone
	local byte_on = triple(slot == "glow" and ONE_BIT.CUT or
			(invert and 1.0 or 0.0))
	local byte_off = triple(bg)
	-- The drawn band is known rather than searched for: only the middle
	-- square is ever written, so the rows outside it are one string and
	-- the rows inside are two pads around their own cells
	local function tile_bytes()
		local out, blank = {}, bgb:rep(MARK_SIZE)
		local lpad, rpad = bgb:rep(off), bgb:rep(MARK_SIZE - off - inner)
		for y = 0, MARK_SIZE - 1 do
			if y < off or y >= off + inner then
				out[#out + 1] = blank
			else
				local row = {}
				for x = 0, inner - 1 do
					row[x + 1] = px[y * MARK_SIZE + off + x + 1] or bgb
				end
				out[#out + 1] = lpad .. table.concat(row) .. rpad
			end
		end
		return table.concat(out)
	end
	-- **The caller says which it is**, and it cannot be asked: the
	-- sandbox raises on a property an Image does not have rather than
	-- answering nil, so `src.size` on a picture is an error and not a
	-- test. `generated` is the generated path, and the generated path
	-- is the one that hands over a field.
	local from_field = generated == true
	local sw = from_field and src.size or src.width
	local sh = from_field and (src.rows or src.size) or src.height
	if sw < 1 or sh < 1 then
		magic.image_set_data(img, MARK_SIZE, MARK_SIZE, 3, tile_bytes())
		return img
	end
	-- A generated field is grey and opaque; only a picture has alpha
	local cutout = (not from_field) and is_cutout(src) or false
	local ink = 0
	-- One pass of the settled transform for the whole tile
	-- ([MARK_ONEBIT]); the diffuse path below reads the picture itself
	local bits = nil
	ONE_BIT.last = nil
	if one_bit and not generated then
		bits = ONE_BIT.mask(src, inner)
	end
	if one_bit and not generated and bits == nil then
		-- **No mark in this picture**, so no picture: nil is what sends
		-- the caller to the room's generated sigil. A blank tile would
		-- be taken for a mark and worn as one -- twenty-nine orbs came
		-- up wearing nothing at all before this said so (2026-09-24)
		last_mark_ink = 0
		return nil
	end
	-- **The figure, on the glowing orbs alone** ([GLOW_MARK]): the
	-- outline is a question about a mark that cuts a light, and the
	-- other two surfaces wear the mask itself. The generated path has
	-- its bits in the loop below, so they are gathered first here.
	if one_bit and slot == "glow" and ONE_BIT.FIG == "outline" then
		if not bits then
			bits = {}
			for y = 0, inner - 1 do
				for x = 0, inner - 1 do
					local sx = math.floor(x * sw / inner)
					local sy = math.floor(y * sh / inner)
					if from_field then
						bits[y * inner + x] =
								ornament.at(src, sx, sy) <= ONE_BIT.AT
					else
						bits[y * inner + x] =
								bit_of(src:GetPixel(sx, sy), cutout)
					end
				end
			end
		end
		bits = ONE_BIT.outline(bits, inner)
	end
	for y = 0, inner - 1 do
		for x = 0, inner - 1 do
			local sx = math.floor(x * sw / inner)
			local sy = math.floor(y * sh / inner)
			-- A field's value is its own height; a picture's is a Colour
			local fv = from_field and ornament.at(src, sx, sy) or nil
			local c = (not from_field) and src:GetPixel(sx, sy) or nil
			if one_bit then
				-- Nought where the mark is, one where it is not: on a
				-- glowing orb that is the difference between a hole in
				-- the light and a pixel that still saturates
				local on
				if bits then
					on = bits[y * inner + x]
				elseif from_field then
					-- The carved part of a height field is the mark
					on = fv <= ONE_BIT.AT
				else
					on = bit_of(c, cutout)
				end
				if on then ink = ink + 1 end
				local v = on and (invert and 1.0 or 0.0) or bg
				-- One of two bytes, not a string built per pixel
				px[(off + y) * MARK_SIZE + off + x + 1] =
						on and byte_on or byte_off
				-- **Red is roughness, green is metalness** in Urho3D's
				-- metallic-roughness map (`PBRLitSolid`: `sSpecMap.r`
				-- adds to roughness and `.g` to metalness). A grey mark
				-- therefore pushes *both*, and option B's etch turned
				-- its patch into rough **metal** -- which on a white
				-- sphere is a black disc, since a metal has no diffuse
				-- (2026-09-24). Written into red alone it is what it
				-- says: the same surface, rougher where the mark is.
				-- **One texture, three channels** (user, 2026-09-24),
				-- each surface marked in the slot it can show:
				-- `rough` puts the mark in **red**, which Urho3D's
				-- metallic-roughness map adds to roughness; `metal`
				-- puts it in **green**, which adds to metalness -- and
				-- there it is the *ground* that is one and the mark
				-- that is nought, so a patch of a mirror stops being
				-- metal and reads as dull grey against it. A grey
				-- pixel would drive both at once, which is what made
				-- B's etch a black disc on a white ball.
				-- (the pixel is written above, from the two bytes)
			elseif from_field then
				if fv <= ONE_BIT.AT then ink = ink + 1 end
				set(off + x, off + y, fv, fv, fv)
			else
				if bit_of(c, cutout) then ink = ink + 1 end
				if c.a < 0.5 then
					set(off + x, off + y, 1, 1, 1)
				else
					set(off + x, off + y, c.r, c.g, c.b)
				end
			end
		end
	end
	last_mark_ink = ink
	magic.image_set_data(img, MARK_SIZE, MARK_SIZE, 3, tile_bytes())
	return img
end

-- A flat white texel, for a material whose picture is in another slot
local function white_texture()
	if kept.white_tex then return kept.white_tex end
	local img = magic.Image:new()
	img:SetSize(2, 2, 3)
	img:Clear(magic.Color(1, 1, 1, 1))
	local t = magic.Texture2D:new()
	t:SetData(img)
	kept.white_img, kept.white_tex = img, t
	return written_texture(t, img)
end

local function mark_texture(mark, icon, one_bit, invert, slot)
	if not mark then return nil end
	-- **The grid's fallback is not a mark, and neither is an icon two
	-- things share.** `launch_grid` hands out `buildat_logo.png` for
	-- anything whose launcher names no icon, and the Luanti launcher
	-- hands out `grass_block.png` for every game it offers -- one picture
	-- worn by twenty-three orbs. A picture generated from the name
	-- tells them apart, which is the whole job of a mark.
	if icon == "buildat_logo.png" or shared_icons[icon] then
		icon = nil
	end
	local image
	if icon and magic.cache:Exists(icon) then
		marks_own = (marks_own or 0) + 1
		-- **A game's own icon is its mark** (the launcher plan's step 5):
		-- the launch grid resolves an icon to a resource name on the
		-- trusted side, and a game that ships one has said what it looks
		-- like better than a hash of its name can
		-- **The pixels in one crossing** ([ROOM_BOOT], 2026-10-03): a
		-- picture read through Image:GetPixel is a wrapped call a pixel,
		-- times the one-bit mask's supersampling -- a second for nineteen
		-- icons, half the room's boot. read_image hands the RGBA over as
		-- one string and the same GetPixel is answered from it here.
		local ok, w, h, rgba = pcall(buildat.read_image, icon)
		local src
		if ok and w and rgba then
			src = {width = w, height = h}
			function src:GetPixel(x, y)
				local i = (y * w + x) * 4
				local r, g, b, a = rgba:byte(i + 1, i + 4)
				return {r = (r or 0) / 255, g = (g or 0) / 255,
						b = (b or 0) / 255, a = (a or 255) / 255}
			end
		else
			src = magic.cache:GetResource("Image", icon)
		end
		if src then
			image = mark_image(src, one_bit, invert, slot)
		end
	end
	if not image then
		-- **An empty mark is not a mark** (2026-09-24): some seeds draw
		-- a figure that survives neither the one-bit cut nor the
		-- shrink, and a fetched serverlist is where it showed -- one
		-- server in twelve came up blank. So the seed is walked until
		-- something is on it, which keeps the mark a function of the
		-- name without letting the name draw nothing.
		local seed = ornament.seed_of(mark)
		for try = 0, 3 do
			-- Straight from the generator to the tile ([ROOM_BOOT]): the
			-- Image in between cost eight thousand wrapped calls an orb
			-- and carried nothing this does not already have
			local f = ornament.mark(64, seed + try * 7919)
			image = mark_image(f, one_bit, invert, slot, true)
			if (last_mark_ink or 0) > 0 then break end
		end
	end
	local t = magic.Texture2D:new()
	assert(t:SetData(image), "the mark's texture")
	t.filterMode = magic.FILTER_BILINEAR
	written_texture(t, image)
	-- The ink count is what the round is judged on, and how the tile
	-- was arrived at is what says why a count is odd ([MARK_ONEBIT])
	log:info("mark: " .. tostring(mark) .. " ink " .. last_mark_ink ..
			" (" .. tostring(ONE_BIT.last or "generated") .. ")")
	return t
end

-- **The etch** (user, 2026-09-23: the orbs should have the mark; a dummy
-- one will do): the same picture on a white or a chrome orb, where it
-- darkens the surface instead of cutting a hole in the light.
-- simplified: **option A** is the diffuse map, not the roughness, which
-- reads as an etch at a glance and costs one texture. Option B, the
-- roughness change the plan asks about, is built and is what
-- BUILDAT_LAUNCH_MARK=B draws; which of the two the room wears by
-- default is the user's pick, off mark_sheet.sh's own sheet.
-- **The options round** ([LAUNCH_WORLD]'s mark, 2026-09-23), and it is
-- about the white and the chrome orbs only -- a glowing one needs the
-- one-bit mark whatever is picked, since nothing greyer survives an
-- emissive of 26.
--
--   A (BUILDAT_LAUNCH_MARK=A, the default): the icon in full colour in
--     the diffuse, padded so the whole of it shows -- a coloured
--     picture suspended in a glass marble.
--   B (BUILDAT_LAUNCH_MARK=B): the same logo as one bit in the
--     **roughness**, which is what an etch is: the surface takes the
--     light differently where the mark is, rather than wearing a
--     picture of it. `sSpecMap.r` adds to roughness in Urho3D's
--     metallic-roughness shader, so the mark's 0 leaves the mirror and
--     its 1 makes that patch matte.
local function mark_option()
	return (env("BUILDAT_LAUNCH_MARK") == "B") and "B" or "A"
end

local function etched(r, g, b, roughness, metallic, mark, icon)
	-- **A chrome sphere is marked in its metalness** (user, 2026-09-24,
	-- closing the round): neither a picture in the diffuse nor a mark in
	-- the roughness touches a `metallic 1.0` surface visibly -- a metal
	-- has no diffuse term, and a rougher mirror is still a mirror. A
	-- patch that **stops being metal** does: it reads as dull grey
	-- against the reflection. The map's green channel carries it, one
	-- outside the mark and nought inside, with the material's own
	-- metalness at nought so the texture is the whole of it.
	if metallic > 0.5 then
		white_texture()
		local t = mark_texture(mark, icon, true, false, "metal")
		if not t then return nil end
		local m = magic.Material:new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/PBR/PBRMetallicRoughDiffSpec.xml"))
		m:SetTexture(magic.TU_DIFFUSE, kept.white_tex)
		m:SetTexture(magic.TU_SPECULAR, t)
		m:SetShaderParameter("MatDiffColor", magic.Color(r, g, b, 1))
		m:SetShaderParameter("Roughness", roughness)
		m:SetShaderParameter("Metallic", 0.0)
		kept[#kept + 1] = m
		return m
	end
	if mark_option() == "B" then
		white_texture()
		local t = mark_texture(mark, icon, true, true, "rough")
		if not t then return nil end
		local m = magic.Material:new()
		m:SetTechnique(0, magic.cache:GetResource("Technique",
				"Techniques/PBR/PBRMetallicRoughDiffSpec.xml"))
		-- The mark is the rough patch: its one is added to roughness,
		-- its nought leaves the surface as the material says
		m:SetTexture(magic.TU_DIFFUSE, kept.white_tex)
		m:SetTexture(magic.TU_SPECULAR, t)
		m:SetShaderParameter("MatDiffColor", magic.Color(r, g, b, 1))
		m:SetShaderParameter("Roughness", roughness)
		m:SetShaderParameter("Metallic", metallic)
		kept[#kept + 1] = m
		return m
	end
	local t = mark_texture(mark, icon)
	if not t then return nil end
	return material(magic.Color(r, g, b, 1), roughness, metallic, t)
end

local function glow(colour, mark, icon)
	local m = magic.Material:new()
	-- One bit: nothing else survives an emissive multiplied by 26
	local t = mark_texture(mark, icon, true, false, "glow")
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			t and "Techniques/DiffUnlit.xml" or
			"Techniques/NoTextureUnlit.xml"))
	if t then m:SetTexture(magic.TU_DIFFUSE, t) end
	m:SetShaderParameter("MatDiffColor", colour)
	kept[#kept + 1] = m
	return m
end

-- The ornament generator's own check, which runs whatever wears its
-- output: the patterns are asserted as patterns here and the wall and
-- the columns wear them as voxel tiles, registered at the top of this
-- file.
log:info(ornament.self_check(ORN_SIZE))

-- The floor: a checkerboard in perspective is half the classic raytrace
-- picture, and in the reference frame it carries the reflections of
-- everything standing on it
local floor_mat = material(magic.Color(1, 1, 1, 1), 0.18, 0.0,
		checker_texture(256, 20, magic.Color(0.04, 0.04, 0.05, 1),
		magic.Color(0.62, 0.63, 0.66, 1), magic.FILTER_TRILINEAR))
-- (the floor is the voxelworld's checkerboard now)

-- **The architecture is the room's, and described once.** room.lua holds
-- the wall, its slabs, its insets and the pockets; nothing here keeps a
-- second copy of those numbers to drift from them, which is what the
-- extension move bought -- the game had them in main.cpp and again here,
-- and the check compared the two lists.
--
-- **The composition rule** (user), read off the reference frame and
-- against the evenly-lit set that was rejected: every view has a light
-- source occluded by something -- so the orb sits in its pocket and the
-- stone silhouettes against it.
local BAYS = room.BAYS
local BAY_Z = room.BAY_Z
local function bay_u(i) return room.bay_u(i - 1) end
local function bay_y(i) return room.bay_y(i - 1) end

-- **An orb is as big as its game** (the plan: 1.2 to 1.8 voxels across,
-- from the game's own size). `list_apps()` answers a directory tree's
-- bytes, and on a linear scale every game here sits at the bottom -- one
-- is a hundred times another -- so it is the log that is spread across
-- the range. A tree with one game gets the middle.
-- **Every orb about 2.0 voxels across** (user, [LAUNCH_SIGNIFY]), moved
-- mildly from there by whatever the thing says about itself -- so the
-- kinds are told apart by **material**, as this plan has always said,
-- and size is a small signal rather than the loud one it was: a server
-- was 3.4 voxels where a save was 0.9 and no size for a server had ever
-- been planned.
--
-- **Normalised within a category and nowhere else**: bytes against a
-- player count against a date are not comparable, so each category's own
-- significances are spread across the band and a category with one
-- member, or with none that say anything, sits in the middle. The log
-- stays because one game is a hundred times another.
-- One table rather than five names: this chunk is at Lua's limit of 200
-- locals and the room has more to say than that ([LAUNCH_WORLD]).
local sig = {MIN = 1.7, MAX = 2.3, range = {}}
sig.MID = (sig.MIN + sig.MAX) / 2

-- Told what a category's significances are; may be told nothing, which
-- is what "no opinion" comes to
function sig.note(category, n)
	if type(n) ~= "number" or n < 0 then return end
	local v = math.log(n + 1)
	local r = sig.range[category]
	if not r then
		sig.range[category] = {lo = v, hi = v}
	else
		r.lo = math.min(r.lo, v)
		r.hi = math.max(r.hi, v)
	end
end

-- The orb's own size: the band's middle for anything with no opinion,
-- which includes every category this room has never heard of
local function orb_across(spec)
	local n = spec and tonumber(spec.significance)
	local r = spec and sig.range[spec.category or "action"]
	if not n or n < 0 or not r or r.hi <= r.lo then
		return sig.MID
	end
	local t = (math.log(n + 1) - r.lo) / (r.hi - r.lo)
	return sig.MIN + t * (sig.MAX - sig.MIN)
end

-- What each category has to say, before anything asks for a size: the
-- band is spread over the significances that are there, and a category
-- where nothing has an opinion keeps the middle.
for _, o in ipairs(GAMES) do sig.note("game", o.significance) end
for _, o in ipairs(FLOOR_ACTIONS) do
	sig.note(o.category or "action", o.significance)
end
for _, sv in ipairs(SERVERS) do sig.note("server", sv.players) end
-- A save's significance is its recency ([LAUNCH_SIGNIFY]), measured
-- against the oldest of the ones listed: the list is newest first, so
-- the last is the floor to measure from. Nothing to compare against
-- means no opinion.
sig.save_epoch = #SAVES > 1 and tonumber(SAVES[#SAVES].modified) or nil
if sig.save_epoch then
	for _, sv in ipairs(SAVES) do
		sig.note("save",
				math.max(0, (tonumber(sv.modified) or 0) - sig.save_epoch))
	end
end

-- **The orbs are the games** (user): warm is what you own, cold is a
-- server you can reach. The name is what Text3D says over the one being
-- pointed at, and a game's own icon is its mark -- generated from the
-- name only where a game ships none.
local ORBS = GAMES

local orb_places = {}
local bay_desc = {}
for b = 1, BAYS do
	-- **Wholly behind the wall's plane**, which is what makes the
	-- pocket's contrast line free: every point of the wall's outward
	-- face has the orb behind it, so N dot L is negative there and the
	-- face takes nothing from it, while every face inside the pocket
	-- looks at the orb and lights all round.
	-- **An orb finds its own place** (user, 2026-09-23): per axis it
	-- centres itself where the walls are close and otherwise keeps a
	-- margin off the one it would touch. At 2 to 4 voxels across, every
	-- pocket here is the close case, so the middle is both answers --
	-- and the margin has a lighting reason as well as a visual one, a
	-- point light at no distance from a face burning it white.
	local p = room.pockets[b]
	-- The middle of the indices the pocket covers, in its own wall's
	-- frame ([POCKETS_ROUND]): u0 .. u0 + su - 1 is centred on
	-- u0 + (su - 1) / 2, a voxel being centred on its index, and the
	-- depth runs from the mouth into the stone
	local mu = p.u0 + (p.su - 1) / 2
	local mn = p.mouth + room.WALL_IN[p.wall] * (p.sd - 1) / 2
	local ox, _, oz = room.wall_xyz(p.wall, mu, 0, mn)
	orb_places[b] = {
		x = ox * VOXEL_M,
		y = (p.y0 + (p.sy - 1) / 2) * VOXEL_M,
		z = oz * VOXEL_M,
	}
	bay_desc[#bay_desc + 1] = string.format("%s %d %d %d %d%d%d",
			p.wall:sub(1, 1), p.u0, p.y0, p.mouth, p.su, p.sy, p.sd)
end
log:info("bays " .. BAYS .. " " .. BAY_Z .. " " ..
		table.concat(bay_desc, " "))

-- Where the sweep is looking now, eased toward the wall it is showing
attract_aim = nil
attract_shown = nil

-- **The floor's own things** (user): a launch action that is not a game
-- is a glossy white sphere, and it stands on the floor rather than in a
-- pocket. The wall holds the games; the floor holds everything else that
-- launches, which in this tree is mostly Luanti's installed games.
--
-- **They are laid out and not scattered**, in two blocks flanking the
-- way to the wall: the room's answer to sorting a list is that the
-- player moves them around, and a heap is a worse starting point than a
-- grid. The middle is left open, because anything standing there stands
-- in front of the pockets the room is lit by.
--
local FLOOR_COLS = {-13.0, -9.0, -5.0, 5.0, 9.0, 13.0}
local FLOOR_ROWS = {-4.0, -0.5, 3.0, 6.5, 10.0}
for i, a in ipairs(FLOOR_ACTIONS) do
	local col = FLOOR_COLS[(i - 1) % #FLOOR_COLS + 1]
	local row = FLOOR_ROWS[math.floor((i - 1) / #FLOOR_COLS) % #FLOOR_ROWS + 1]
	-- **A server the grid offers is a mirror too** ([LAUNCH_SIGNIFY]:
	-- the category says what kind of thing it is). The fetched list
	-- arrives this way -- an action with an address behind it -- and it
	-- should look like the servers the client already knew rather than
	-- like a launch action that happens to be one.
	local o = {name = a.name, icon = a.icon, key = a.key,
		kind = a.kind, description = a.description, floor = true,
		server = (a.category == "server") or nil,
		category = a.category, significance = a.significance}
	ORBS[#ORBS + 1] = o
	orb_places[#orb_places + 1] = {x = col,
		y = orb_across(o) * VOXEL_M / 2, z = row}
end

-- **No size of its own any more** ([LAUNCH_SIGNIFY]): a server was 3.4
-- voxels across because the reference frame's chrome was the largest
-- thing on its floor, which said "a server matters most" and was never
-- planned. It is a mirror at the band's middle now, and what would move
-- it is the player count remembered from the last visit -- a field
-- beside the address, which nothing writes yet.
-- **A server is a mirror, and it stands where the room's chrome used to
-- be.** Those spheres were the reference frame's own furniture standing
-- in for something; this is the something.
local SERVER_COLS = {-14.0, -9.5, -5.0, 5.0, 9.5, 14.0}
for i, sv in ipairs(SERVERS) do
	local col = SERVER_COLS[(i - 1) % #SERVER_COLS + 1]
	local row = 0.5 + math.floor((i - 1) / #SERVER_COLS) * 4.5
	local o = {name = sv.name, address = sv.address, server = true,
		icon = sv.icon,
		description = sv.address ..
				(sv.example and "   (the room's suggestion)" or ""),
		floor = true, category = "server",
		significance = sv.players,
		search = sv.name .. " " .. sv.address}
	ORBS[#ORBS + 1] = o
	orb_places[#orb_places + 1] = {x = col,
		y = orb_across(o) * VOXEL_M / 2, z = row}
end

-- **A save is a white sphere too, smaller** (user), and it stands in
-- front of the launch actions: a save is a thing the player made and the
-- actions are the tree's, so the player's own are nearer to hand.
local SAVE_COLS = {-11.0, -7.5, -4.0, 4.0, 7.5, 11.0}
for i, sv in ipairs(SAVES) do
	local col = SAVE_COLS[(i - 1) % #SAVE_COLS + 1]
	local row = 13.0 - math.floor((i - 1) / #SAVE_COLS) * 3.2
	local o = {name = sv.name, app = sv.app, save = true,
		description = "save of " .. sv.app, floor = true,
		category = "save",
		-- Its recency, against the oldest of the ones listed: the list
		-- is newest first, so the last one is the floor to measure from
		significance = sig.save_epoch and
				math.max(0, (tonumber(sv.modified) or 0) - sig.save_epoch) or nil,
		search = sv.name .. " " .. sv.app}
	ORBS[#ORBS + 1] = o
	orb_places[#orb_places + 1] = {x = col,
		y = orb_across(o) * VOXEL_M / 2, z = row}
end

do
	local lo, hi, n = nil, nil, 0
	for _, o in ipairs(ORBS) do
		if not o.empty then
			local v = orb_across(o)
			n = n + 1
			lo = (lo == nil or v < lo) and v or lo
			hi = (hi == nil or v > hi) and v or hi
		end
	end
	local cats = {}
	for c in pairs(sig.range) do cats[#cats + 1] = c end
	table.sort(cats)
	log:info(string.format("orb sizes: %d orbs, %.2f to %.2f voxels, "..
			"ranked within %s", n, lo or 0, hi or 0,
			#cats > 0 and table.concat(cats, ", ") or "nothing"))
end

-- **The ornament, on primitives in front of the voxels.** The bays are
-- voxel mass and the ornament is a generated texture, and the two cannot
-- meet: a voxel's tile is loaded by resource name out of Urho3D's
-- ResourceCache and there is no way to put a generated Image in there.
-- So the friezes are what the plan's own "three representations, each
-- where it is better" asks for -- boxes carrying the meander and the
-- socket field, standing a little proud of the wall the way a course of
-- dressed stone stands proud of rubble.
-- **No friezes.** They were the ornament's home while the wall was a
-- flat plane with a balcony per orb; the wall the reference actually has
-- is one material with the ornament on the pockets' side columns and
-- nowhere else, and those are voxels wearing a generated tile. What used
-- to stand proud of the wall here is the wall's own relief now.
frieze_nodes = {}

-- **A size in voxels, through part()'s metres.** part() takes metres and
-- multiplies by U on the way in, so a sphere asked for at "1.5" came out
-- 1.5 / 0.45 = 3.3 voxels across -- twice what the plan asks for, and
-- the floor's spheres were half-buried because their centres were set
-- for the size they were meant to be (user, 2026-09-23).
local function across(voxels)
	local m = voxels * VOXEL_M
	return magic.Vector3(m, m, m)
end

-- **A probe box of known albedos** (BUILDAT_LAUNCH_PROBEBOX=1), for
-- judging the exposure rather than arguing about it: five matte patches
-- standing in the room at 90, 50, 18 and 4 per cent grey and the orb's
-- own orange, lit by whatever the room is lit by. What a picture of it
-- says is where the tonemap has put each of them -- whether the white
-- has saturated and whether the dark has gone to nothing.
if env("BUILDAT_LAUNCH_PROBEBOX") ~= "" then
	local PATCHES = {
		{0.90, 0.90, 0.90}, {0.50, 0.50, 0.50}, {0.18, 0.18, 0.18},
		{0.04, 0.04, 0.04}, {1.00, 0.55, 0.20},
	}
	-- **Behind the overhead light, not in front of it.** At z = 6 m the
	-- patches faced the camera and the light was behind them, so every
	-- one of them read black whatever the exposure was: a probe that
	-- cannot be lit measures nothing.
	for i, c in ipairs(PATCHES) do
		local m = material(magic.Color(c[1], c[2], c[3], 1), 0.65, 0.0)
		part("Box", {x = -3.6 + (i - 1) * 1.5, y = 0.7, z = -1.5},
				{x = 1.2, y = 1.2, z = 0.4}, m)
	end
	log:info("probe box: five patches, 90/50/18/4 per cent grey and the orange")
end

-- The orbs. Warm is what you own; the palette's own entry says which
-- colour each carries, and the light at it is what lights the room.
local orb_mats = {}
local orb_nodes = {}
-- An orb out of its pocket is not a source: which ones those are, and
-- what each one's lit colour was, so it can be handed back
orb_bright = {}
for i, o in ipairs(orb_places) do
	local spec = ORBS[i]
	if spec and spec.empty then
		-- Nothing in the niche but the ring that would hold something,
		-- dim: an empty socket reads as empty, not as broken
		part("Torus", magic.Vector3(o.x, o.y, o.z), across(1.4), machined)
	elseif spec and spec.server then
		-- **A mirror**: a server is a thing you can see the room in,
		-- which is the whole of why the reflection probe is here
		local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
				across(orb_across(spec)),
				etched(0.92, 0.94, 0.97, 0.06, 1.0, spec.name, spec.icon) or
				chrome)
		node:GetComponent("StaticModel").castShadows = true
		orb_nodes[i] = node
	elseif spec and spec.save then
		-- Smaller, because it is one save of one game rather than a
		-- thing to launch on its own
		local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
				across(orb_across(spec)),
				etched(WHITE_V, WHITE_V * 1.01, WHITE_V * 1.03, 0.12, 0.0,
					spec.name) or white)
		node:GetComponent("StaticModel").castShadows = true
		orb_nodes[i] = node
	elseif spec and spec.floor and not spec.game_orb then
		-- **A glossy white sphere** (user): not a source, so it takes
		-- the room's light rather than making any, and it is told apart
		-- from a server's chrome by being white rather than a mirror
		local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
				across(orb_across(spec)),
				etched(WHITE_V, WHITE_V * 1.01, WHITE_V * 1.03, 0.12, 0.0,
					spec.name, spec.icon) or
				white)
		node:GetComponent("StaticModel").castShadows = true
		orb_nodes[i] = node
	else
		orb_mats[i] = glow(magic.Color(1, 1, 1, 1), spec and spec.name,
				spec and spec.icon)
		local node = part("Sphere", magic.Vector3(o.x, o.y, o.z),
				across(orb_across(spec)), orb_mats[i])
		node:GetComponent("StaticModel").castShadows = false
		orb_nodes[i] = node
	end
end

log:info("marks: " .. marks_own .. " of the room's own icons, the rest " ..
		"generated from the name")

-- The foreground: ten shipped primitives on the checkerboard, the chrome
-- ones doing what a perfect sphere under a sharp light does
-- **What is left of the reference frame's furniture.** Its five chrome
-- spheres are the room's servers now, which is what they were standing
-- in for; these are the shapes that are not spheres.
--
-- **The floor's own things, out of the way of the wall.** A server and a
-- launch action stand on the floor, and the pockets are at Y 0 to 3 --
-- knee to chest -- so anything in the middle of the floor stands in
-- front of the lights the room is lit by. They frame the view instead:
-- wide in x, near the eye in z, and the corridor to the wall left open.
-- The check's own 99th percentile catches this, having read 110 against
-- 253 the moment the eye came down to standing height (2026-09-23).
local PROPS = {
	{"Cone", -9.0, 1.35, 9.2, 2.7, "machined"},
	{"Cylinder", 11.4, 1.25, 5.0, 2.5, "machined"},
	{"Pyramid", 13.8, 1.15, 8.4, 2.3, "stone"},
	{"Pyramid", -13.0, 1.10, 10.6, 2.2, "machined"},
}

local MATS = {chrome = chrome, machined = machined, stone = stone}
prop_nodes = {}
for _, o in ipairs(PROPS) do
	prop_nodes[#prop_nodes + 1] = part(o[1],
			magic.Vector3(o[2], o[3], o[4]),
			magic.Vector3(o[5], o[5], o[5]), MATS[o[6]])
end

-- The ten lights are the experiment. Their places are the room's and do
-- not move; a preset says what colour, how bright and how far each is.
-- Roles, from the plan: 1-2 the interior key pair, 3-6 the readouts
-- (every readout is a real light source), 7-8 the structure's own glow,
-- 9 the one amber thing that wants you, 10 the horizon through the
-- opening.
-- **The bounce has to be point lights.** A directional one does almost
-- nothing in here: the voxel shader gates the sun by the skylight
-- nibble, which is what keeps a cave out of the sun, and this room's
-- nibble is nought everywhere. Eight times the brightness moved the
-- wall by three levels. So the fill below is point lights with long
-- ranges and low strength, spread through the room, which is the only
-- lever a sealed voxel room has.
-- The first six lights are the orbs -- each sits inside its own sphere,
-- so what lights the room is the thing you can see lighting it. The last
-- four are fill: two low at the sides and two picking out the
-- foreground, which is what keeps the chrome from being a black ball
-- with one highlight.
-- **The room's light, as the wall's own reading has it**: cold, from a
-- big square opening overhead, and the orbs. Nothing else -- the fill
-- and the per-bay washes that lit the old flat wall are gone, because
-- they re-light the very surface the pocket's contrast line depends on.
--
-- **The whole shadow budget goes to the overhead light**, which is the
-- one doing the dramatic work on the wall's relief: without it the deep
-- insets cannot read black while lit. The orbs are plain point lights
-- with a tight range -- no cube shadow maps and no cones. The pocket's
-- own contrast line is free: the wall's outward face has the orb behind
-- its plane, so N dot L is negative there and it takes nothing, while
-- every face inside the pocket looks at the orb.
-- **The opening's own emitter**, filling the square cut through the
-- ceiling: unlit and far above 1, so it clips to white and a mirror
-- shows a sharp bright square where the light comes from. A light casts
-- nothing a reflection can see; only a surface does.
do
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureUnlit.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(5.2 * light_look.opening,
			5.6 * light_look.opening, 6.4 * light_look.opening, 1))
	kept[#kept + 1] = m
	local node = scene:CreateChild("opening")
	node.position = magic.Vector3(
			(room.OPEN_X0 + room.OPEN_X1) / 2,
			room.Y_TOP + 0.5,
			(room.OPEN_Z0 + room.OPEN_Z1) / 2)
	node.scale = magic.Vector3(room.OPEN_X1 - room.OPEN_X0 + 1, 0.3,
			room.OPEN_Z1 - room.OPEN_Z0 + 1)
	local o = node:CreateComponent("StaticModel")
	o.model = magic.cache:GetResource("Model", "Models/Box.mdl")
	o.material = m
	o.castShadows = false
	log:info("the opening: " .. (room.OPEN_X1 - room.OPEN_X0 + 1) .. "x" ..
			(room.OPEN_Z1 - room.OPEN_Z0 + 1) .. " voxels at the ceiling")
end

-- The light sits just under the opening, which is where it would be
-- Voxels above the floor: under the ceiling, which is as high as the
-- formation makes it
local OVERHEAD_Y = room.Y_TOP - 1
-- **The pockets' orbs and nothing else**: a thing on the floor is a
-- glossy white sphere and takes the room's light rather than making any,
-- so the sources are the games and the opening overhead
local LIGHT_PLACES = {}
for i = 1, BAYS do
	local o = orb_places[i]
	LIGHT_PLACES[i] = {o.x, o.y, o.z}
end
-- Under the opening's own middle, which is the room's (user,
-- 2026-09-25): the square moved and the light that stands in for it
-- goes with it, or the pool on the floor is not under the hole
LIGHT_PLACES[#LIGHT_PLACES + 1] = {0.0, OVERHEAD_Y * VOXEL_M,
		(room.OPEN_Z0 + room.OPEN_Z1) / 2 * VOXEL_M}
-- **A cool fill, low and forward** -- the one thing standing in for the
-- bounce a path trace gets free. Without it the shadows go to nothing
-- once the light from above casts: the room's median came to 23 against
-- the reference frame's 38, and its blue to 58 against 68. It lights the
-- floor and the chrome and falls off before the wall, so the stone keeps
-- silhouetting against the orbs, which is the composition.
LIGHT_PLACES[#LIGHT_PLACES + 1] = {0.0, 1.6, 7.0}

-- The palette's roles, from the plan: cyan is live and connected, purple
-- is structure and never state, amber is the one thing that wants you,
-- and the warm horizon is the world outside and not yours.
local CYAN = {0.15, 0.85, 1.0}
local PURPLE = {0.55, 0.20, 0.95}
local AMBER = {1.0, 0.62, 0.12}
-- **The orb's own orange** (user, 2026-09-23): the glow reads white in
-- the middle only because it saturates on brightness -- the emissive is
-- well above 1 -- and what it throws on the stone is this. A paler warm
-- (1.0, 0.72, 0.45) lit the room beige; (1.0, 0.55, 0.20) read yellow
-- against the reference frame. It wants to be **further toward red than
-- it looks like it should**, because the middle of every glow is
-- clipped white and only the falloff carries the hue.
local WARM = {1.0, 0.24, 0.06}
-- **Mildly cold, not blue** (user, 2026-09-23). At (0.72, 0.85, 1.0)
-- the light from above painted half the room blue -- 48 per cent cool
-- pixels against the reference frame's 30.
local COLD_WHITE = {0.86, 0.91, 1.0}

-- {colour, intensity, range}. The six orbs, then the overhead opening.
local function preset_lights(orb, sky, orb_i, sky_i)
	local l = {}
	for i = 1, BAYS do
		-- Tight, so an orb's light dies before it reaches the sideways
		-- faces of the neighbouring slabs, which can see into a
		-- neighbour's pocket -- the one leak the normal does not cover,
		-- and a range is cheaper than a shadow map
		-- **Eight voxels, which is a change to this plan's fourth
		-- condition** -- that an orb's light should die before it
		-- reaches a neighbour's pocket. At four it died inside its own,
		-- and the room came out 68 per cent cool pixels against the
		-- reference frame's 30 with a twentieth of its warmth. **The
		-- reference's warm floods**: its glows spill across whole
		-- faces of stone, and that is where its colour comes from. The
		-- contrast line the condition is really about is still free,
		-- being geometry -- an orb behind the wall's plane gives its
		-- outward face nothing whatever the range is. **A pick, and
		-- the user's to overrule.**
		l[i] = {orb, orb_i, 11 * U}
	end
	l[BAYS + 1] = {sky, sky_i, 17 * U}
	-- **Bluer than the light it stands in for.** What a fill replaces
	-- here is the bounce a path trace gets free, and in a room lit from
	-- a cold opening the bounce is colder than the source; the room read
	-- 21 per cent cool pixels against the reference frame's 30 with the
	-- fill the same colour as the opening.
	l[BAYS + 2] = {{sky[1] * 0.50, sky[2] * 0.76, sky[3]},
		sky_i * 0.72, 16 * U}
	return l
end

local PRESETS = {
	{
		-- The reference frame's own scheme: warm orbs in the wall, cold
		-- light from outside it
		name = "cold_in_warm_out",
		-- The two the probe sheet sweeps; see probe_sheet.sh
	lights = preset_lights(WARM, COLD_WHITE,
			tonumber(env("BUILDAT_LAUNCH_ORB")) or 16.0,
			tonumber(env("BUILDAT_LAUNCH_SKY")) or 2.2),
	},
	{
		name = "warm_in_cold_out",
		lights = preset_lights(CYAN, AMBER, 7.0, 1.6),
	},
	{
		name = "all_cold",
		lights = preset_lights(COLD_WHITE, CYAN, 7.0, 1.6),
	},
	{
		-- Deliberately wrong, and the useful one
		name = "wrong",
		lights = preset_lights(PURPLE, AMBER, 8.0, 3.0),
	},
}

-- Urho3D's PBR shaders want a light an order of magnitude brighter than
-- the non-PBR ones for the same picture: their falloff is physical and
-- brightness is radiant intensity, not a 0..1 dimmer. A preset's numbers
-- above are relative to each other, and this is the one place the scale
-- lives. Getting this wrong is what made PBR look like it did not work
-- at all -- the room came out black and the render path got the blame.
local PBR_INTENSITY = 25

-- Shadows on, and a map big enough for a wall of relief: they are
-- required rather than optional here ([LAUNCH_WORLD]'s wall)
-- BUILDAT_LAUNCH_NOSHADOW=1 turns them off, which is how [PBR_HDR]
-- asked whether the shadow maps were what a float probe breaks
magic.renderer.drawShadows = (env("BUILDAT_LAUNCH_NOSHADOW") == "") and
		light_look.shadows
-- **1024, not 2048.** Eleven shadow-casting lights -- ten cube maps for
-- the orbs and the spot overhead -- at 2048 dropped the frame rate by
-- half (2026-09-23).
magic.renderer.shadowMapSize = 1024

local lights = {}
-- Kept so a carried orb's light can follow it: an orb is its own light
-- made visible, and a handful of them should light the hand
light_nodes = {}
for i, place in ipairs(LIGHT_PLACES) do
	local node = scene:CreateChild("light")
	node.position = V(place[1], place[2], place[3])
	local light = node:CreateComponent("Light")
	-- **The whole shadow budget goes to the light from above** (this
	-- plan's own rule), and it had none: every light in the room was
	-- `castShadows = false`, so the wall's relief threw nothing and the
	-- deep insets could not read black while lit. That is where the
	-- room's dark mass went -- its median came to 72 against the
	-- reference frame's 38 (2026-09-23).
	--
	-- A spot rather than a point, because a point wants a cube shadow
	-- map for six faces of which one is ever looked at, and because an
	-- opening overhead throws light down and not sideways.
	local overhead = (i == #LIGHT_PLACES - 1)
	light.lightType = overhead and magic.LIGHT_SPOT or magic.LIGHT_POINT
	if overhead then
		node.direction = magic.Vector3(0, -1, 0.12)
		light.fov = light_look.fov
		light.castShadows = light_look.spot_shadow
		light.shadowBias = magic.BiasParameters(0.00006, 0.6)
	else
		-- **The pocket's walls have to contain its orb** (user,
		-- 2026-09-23: the leak onto the surrounding wall ruins the
		-- look). Geometry alone does not do it -- the wall's outward
		-- face is safe, being behind the orb, but every slab standing
		-- proud of it has sideways faces that see straight into the
		-- pocket, which is the leak this plan's fourth condition names
		-- and a range cannot close. So the orbs cast after all: a cube
		-- shadow map each, which is what "the whole shadow budget goes
		-- to the overhead light" was avoiding, and the room is static
		-- enough to afford it.
		light.castShadows = true
		light.shadowBias = magic.BiasParameters(0.00012, 0.55)
	end
	lights[i] = light
	light_nodes[i] = node
end

local current = 0
local function set_preset(n)
	local preset = PRESETS[n]
	if preset == nil then return end
	current = n
	for i, light in ipairs(lights) do
		local e = preset.lights[i]
		light.color = magic.Color(e[1][1], e[1][2], e[1][3], 1)
		local spec = ORBS[i]
		if spec and spec.empty then
			-- An empty niche is a dark one, and the one amber thing in
			-- the room is allowed to be the invitation to fill it
			light.color = magic.Color(1.0, 0.62, 0.12, 1)
		end
		-- An orb is its own light made visible, so it wears the colour it
		-- casts, well above 1 so it reads as a source and not as a pale
		-- ball -- and so the probe carries it to the chrome
		if orb_mats[i] then
			-- **The orb reads white because it saturates, not because it
			-- is white** (user, 2026-09-23): its emissive is far above
			-- 1, so the middle clips and only the falloff at its edge
			-- shows the colour it casts. That is separate from how much
			-- orange it throws on the stone, which is the light below.
			--
			-- **And the multiplier has to clear the *smallest* channel.**
			-- At seven the orange's blue was 0.42 and never came near
			-- saturation, so the middle stayed orange and the orb read
			-- as a flame rather than as a lamp (user, 2026-09-23). At
			-- twenty-six the blue clears 1.5 and the core goes white.
			local bright = magic.Color(e[1][1] * 26.0, e[1][2] * 26.0,
					e[1][3] * 26.0, 1)
			orb_bright[i] = bright
			orb_mats[i]:SetShaderParameter("MatDiffColor", bright)
		end
		-- The light look's share ([LAUNCH_WORLD] stage 3): the orbs, the
		-- opening overhead, then the fill
		local look_k = (i <= BAYS and light_look.orb) or
				(i == BAYS + 1 and light_look.sky) or light_look.fill
		light.brightness = e[2] * PBR_INTENSITY * look_k *
				((spec and spec.empty) and 0.22 or 1.0)
		light.range = e[3]
	end
	if label then
		label:SetText(preset.name .. "  (1-" .. #PRESETS .. ")")
	end
	log:info("palette preset " .. n .. ": " .. preset.name)
end

-- The one viewpoint every picture is taken from: standing in the room,
-- the open side behind the camera, the chrome and the plinth in frame
local camera_node = scene:CreateChild("Camera")
camera_node:CreateComponent("Camera")
-- **Where the room is heard from** ([NO_SOUND], 2026-09-24): every
-- sound in here is a `SoundSource3D` and positional audio with no
-- listener is silent without being an error -- the room played nothing
-- at all and said nothing about it. The ear goes where the eyes are,
-- as vanilla and featuretest both put it; how loud it all is stays the
-- player's own preference.
if magic.audio then
	magic.audio.listener = camera_node:CreateComponent("SoundListener")
end
-- placed from the camera state below, once it exists
-- [LAUNCH_WORLD] step 2: the reflection probe, which is a prerequisite
-- and not an upgrade -- a PBR metal reflects its surroundings and nothing
-- else, so with no environment it is black but for its highlight, and
-- half the reference frame is reflections.
--
-- The room is static: no mapgen, no day, nothing that moves the light. So
-- the environment is rendered once into a cubemap and hung on the zone,
-- and that is the whole feature. Float16, because what a probe carries is
-- radiance and the emissive orbs are well above 1.
--
-- simplified: one probe for the whole room, at a point named by hand, so
-- a reflection is right where the probe is and progressively wrong away
-- from it. The upgrade is a probe per bay with the nearest chosen per
-- object, which Urho3D will not do for us.
local PROBE_SIZE = 256
-- Urho3D's cube faces in its own order (+X, -X, +Y, -Y, +Z, -Z), as the
-- pitch and yaw a camera needs to look down each
local PROBE_FACES = {
	{0, 90}, {0, -90}, {-90, 0}, {90, 0}, {0, 0}, {0, 180},
}
local probe_surfaces = {}
probe_on = true
local function reflection_probe(at)
	local cube = magic.TextureCube:new()
	-- **A float16 cube, which is what a reflection is** ([PBR_HDR],
	-- fixed 2026-09-23): eight bits could not carry an orb that is
	-- twenty times white, so every source clipped to a flat white disc
	-- in every reflection. What kept this in eight bits for a day was
	-- **the mip chain above**: a render-target cube is given the whole
	-- chain and only level 0 is ever rendered into, so a rough surface
	-- sampled a level nobody wrote -- a wrong colour in eight bits, and
	-- in float16 a NaN, which this shader *adds* to the frame, and
	-- every additive light pass after it adds to a NaN. One level fixes
	-- it at the source and the voxel shader refuses a sample that is
	-- not a number as well.
	--
	-- simplified: one level means a rough surface reflects as sharply
	-- as a mirror. **Measured 2026-09-24, and it is the format rather
	-- than the chain**: Urho3D does regenerate a render target's levels
	-- by itself (`Graphics::SetRenderTarget` marks them dirty, the bind
	-- calls glGenerateMipmap), and with the chain left on an eight-bit
	-- probe draws the room with its rough surfaces blurred and its
	-- mirrors intact -- mean 90.4 against the one level's 91.0. The
	-- same chain on the float16 probe takes every reflection black:
	-- the levels come back as the shader's NaN guard sees them, so
	-- **this driver does not generate them for a float16 cube**. The
	-- upgrade is therefore a format the driver will filter, or six
	-- faces blurred by hand into the levels -- not a call that is
	-- missing. BUILDAT_LAUNCH_PROBEMIPS=1 is how that gets measured
	-- again rather than argued about.
	--
	-- BUILDAT_LAUNCH_PROBE8=1 goes back to eight bits, which is what
	-- the two were compared with.
	local fmt = env("BUILDAT_LAUNCH_PROBE8") ~= "" and
			magic.Graphics.GetRGBAFormat() or
			(env("BUILDAT_LAUNCH_PROBE32") ~= "" and
				magic.Graphics.GetRGBAFloat32Format() or
				magic.Graphics.GetRGBAFloat16Format())
	-- **One level, not a chain nobody writes** ([PBR_HDR], and this is
	-- the whole fault): a render target cube is given the full mip
	-- chain by default and only level 0 is ever rendered into, so every
	-- sample above it reads memory nobody wrote -- a wrong colour in
	-- eight bits, and in float16 a NaN, which the shader then adds to
	-- the frame and takes the room black. A method, not a property:
	-- Urho3D's `levels` is read-only and a write to it goes nowhere.
	-- BUILDAT_LAUNCH_PROBEMIPS=1 leaves the chain on, which is how the
	-- upgrade above gets measured rather than argued about
	if env("BUILDAT_LAUNCH_PROBEMIPS") == "" then
		cube:SetNumLevels(1)
	end
	assert(cube:SetSize(PROBE_SIZE, fmt,
			magic.TEXTURE_RENDERTARGET), "the probe's cubemap")
	cube.filterMode = magic.FILTER_BILINEAR
	kept.probe = cube
	for i, a in ipairs(PROBE_FACES) do
		local node = scene:CreateChild("probe_face")
		node.position = at
		node.rotation = magic.Quaternion(a[1], a[2], 0)
		local cam = node:CreateComponent("Camera")
		cam.fov = 90
		cam.aspectRatio = 1
		cam.nearClip = 0.05 * U
		cam.farClip = 120 * U
		local vp = magic.Viewport:new(scene, cam)
		local surface = cube:GetRenderSurface(i - 1)
		surface:SetViewport(0, vp)
		-- Drawn when asked rather than every frame: six more views a frame
		-- for a room that does not change is exactly the kind of cost this
		-- whole thing is a showcase of leaving out
		surface.updateMode = magic.SURFACE_MANUALUPDATE
		probe_surfaces[i] = surface
		kept[#kept + 1] = vp
	end
	-- **Not on the zone yet**: what the bake is allowed to see is the
	-- room's own lamps, not the cube it is about to write. The frame
	-- after the bake puts it on (handle_probe_update below).
	-- **Kept by name as well** (2026-09-26): F5 puts the probe back by
	-- reading kept.probe, which nothing set, so the second press
	-- assigned nil to a property that will not take one. The dark one
	-- beside it was named all along.
	kept.probe = cube
	-- What the zone wears when the probe is taken away: an environment of
	-- nothing, rather than no environment at all. The property will not
	-- take nil, and an unbound cubemap reads bright rather than black.
	local dark = magic.TextureCube:new()
	dark:SetNumLevels(1)
	assert(dark:SetSize(4, magic.Graphics.GetRGBAFloat16Format(), 0),
			"the empty environment")
	local black = magic.Image:new()
	assert(black:SetSize(4, 4, 3), "the empty environment's face")
	black:Clear(magic.Color(0, 0, 0, 1))
	for face = 0, 5 do
		dark:SetData(face, black)
	end
	kept.dark_probe = dark
	kept[#kept + 1] = black
	zone.zoneTexture = dark
	-- **And something in the engine has to hold each of them.** A Lua
	-- table is not a reference: the safe wrapper does not own the C++
	-- object, the engine's own count does, and the only thing holding
	-- either cube map was the zone it was on. So F5 swapping them freed
	-- the one being taken off, and the press after that handed the zone
	-- a pointer to freed memory -- SIGSEGV in RefCounted, reached from
	-- Zone::SetZoneTexture. A zone of its own, on a node that is never
	-- enabled, is the reference that outlives the swap. (The same shape
	-- as the materials in extensions/luanti_client/world.lua.)
	for _, held in ipairs({cube, dark}) do
		local keeper = scene:CreateChild("probe_keeper")
		keeper.enabled = false
		keeper:CreateComponent("Zone").zoneTexture = held
		kept[#kept + 1] = keeper
	end
	return cube
end
reflection_probe(V(0, 2.0, 0.0))

-- **One bake, on the first frame, and nothing is timed** (user,
-- 2026-09-26: the long frames it makes seconds in give a bad
-- impression, and there has to be a robust way of knowing when the
-- probe can be taken).
--
-- The thing that made the old code bake again and again was never the
-- textures arriving: a bake at frame 2, 4, 8, 16 and 32 all give the
-- same picture to a fiftieth of a level. It was **the probe reading its
-- own output**. The cube is the zone's environment map, so the first
-- bake drew a room lit by whatever was in the cube -- an uninitialised
-- one, which reads bright -- and every bake after it was converging
-- that feedback. Ninety-one frames of it, then four spread over three
-- seconds, both of them a loop dressed as a wait.
--
-- So the rule is not when, it is **what the bake is allowed to see**:
-- the zone wears the black cube while the room is drawn into the probe,
-- which makes the first bake a room lit by its own lamps and nothing
-- else. That does not depend on a clock, a frame count or a machine's
-- speed -- but one of them is not enough to look at: **a floor lit by
-- nothing but the orbs is orange**, and every sphere in the room then
-- reflects a red floor (user, 2026-09-26). So the cube goes on the zone
-- and the room is drawn into it **once more, the very next frame**: the
-- second bake is the room lit by the first, which is the bounce the red
-- floor was missing. Two frames, both inside the boot's own burst,
-- rather than four spread over three seconds of a player's time.
--
-- **And the camera does not move until it is done** (user, 2026-09-26):
-- a slow frame is worst when it is the player's own movement that
-- stutters. `probe_pending()` below holds the camera for those two
-- frames. The deadline is the safety: if the bake never happens -- a
-- launch UI over the room at boot, the probe turned off -- the player is
-- not held hostage to it.
probe_bake = {queued = false, left = 2, done = false, started = nil,
		hold = 2.0}
-- Whether the room is still waiting for its one bake.
function probe_pending()
	if probe_bake.done then return false end
	local since = probe_bake.started and
			buildat.get_time_us() / 1e6 - probe_bake.started or 0
	return since < probe_bake.hold
end
function handle_probe_update()
	if probe_bake.done then return end
	-- The room stands down while a game, or a console, is over it
	-- ([MENU_CONTEXT], [LAUNCH_CONSOLE])
	if held_was or held_by_others() then return end
	if env("BUILDAT_LAUNCH_NORENDERPROBE") ~= "" then
		probe_bake.done = true
		return
	end
	probe_bake.started = probe_bake.started or buildat.get_time_us() / 1e6
	if probe_bake.queued then
		-- The frame after the queue is the one that drew the six faces:
		-- the cube has the room in it now, so the zone wears it -- and
		-- the next bake, if there is one, sees the room lit by this one
		if probe_on then
			zone.zoneTexture = kept.probe
		end
		if probe_bake.left <= 0 then
			probe_bake.done = true
			log:info("probe: baked twice, the second off the first")
			return
		end
	end
	probe_bake.queued = true
	probe_bake.left = probe_bake.left - 1
	for _, s in ipairs(probe_surfaces) do
		s:QueueUpdate()
	end
end
magic.SubscribeToEvent("Update", function(t, d) handle_probe_update(t, d) end)

-- **What a change of screen mode takes with it** ([BOX_PLAYTEST_3] (1),
-- the same fault the Luanti client had). F11, and anything else that
-- recreates the window -- multisampling on the desk is one -- destroys
-- the GL context, and Urho3D can only bring back what it loaded from a
-- file. The room's textures are not loaded, they are written: the
-- voxel atlas is filled in by hand and the probe is drawn into. So the
-- world came back black and unlit.
--
-- The atlas registry keeps the Image every segment was written into and
-- puts it back when the texture says its data is lost; that is
-- `atlas_reg:update()`, and it is per frame rather than on the event
-- because the texture is what knows, not the window. (voxelworld's
-- client half does the same for a game.)
function handle_device_update()
	atlas_reg:update()
end
magic.SubscribeToEvent("Update", function(t, d) handle_device_update(t, d) end)

-- The probe has no image to put back -- it is a render target, and what
-- was in it is gone -- so it is drawn again, by the same two bakes the
-- boot does and with the same hold on the player.
magic.SubscribeToEvent("ScreenMode", function()
	if probe_bake.done then
		probe_bake.queued = false
		probe_bake.left = 2
		probe_bake.done = false
		probe_bake.started = nil
		zone.zoneTexture = kept.dark_probe
		for _, w in ipairs(kept.written) do
			w[1]:SetData(w[2])
		end
		log:info("screen mode changed: the atlas restores itself, " ..
				#kept.written .. " written textures go back on and the " ..
				"probe is drawn again")
	end
end)

-- **The field of view** (user, 2026-09-23: it is quite small; try 72,
-- which is Luanti's and fits tight spaces and mouse look) -- **and a
-- setting of the room's**, since it is a taste. A global: the terminal's
-- row and the save both reach it, and this chunk is at Lua's local
-- limit.
fov = 72
camera_node:GetComponent("Camera").fov = fov
local viewport = magic.Viewport:new(scene,
		camera_node:GetComponent("Camera"))
-- **The viewport is registered before the render path is touched**,
-- which is the order apps/voxel_lighting uses and the last difference
-- between the two that was left to try.
magic.set_preferred_viewports({viewport})

-- **The tonemap**, which is the last thing between this room and the
-- reference frame: a path trace rolls its highlights off and a frame
-- with none can only clip them (3.58 per cent of this one is pure
-- white against the reference's 0.31).
--
-- **It does not work yet, and the hook is left here because the next
-- attempt should not start from nothing.** BUILDAT_LAUNCH_TONEMAP names
-- which of Urho3D's own post-process effects to append, comma
-- separated. What is known:
--   * all three together draw a black frame, and so does Tonemap alone
--     (mean 1 of 255), so it is not AutoExposure or BloomHDR
--   * Tonemap.xml is not missing its parameters -- it declares
--     TonemapExposureBias itself, so the "unset reads as zero" rule is
--     not the cause
--   * every command in it reads the texture named "viewport" and writes
--     it back, and this game's scene goes through
--     set_preferred_viewports(), which renders it to an offscreen
--     texture of its own. That is the first thing to suspect: the
--     effect is reading a viewport the scene was never drawn into.
-- The room is lit to fit in the range meanwhile, so the orbs clip to
-- white -- which is what a source should do -- and the wall stops short
-- of it.
-- **Built again on the way back from a game, not kept.** The cloned
-- path belongs to whatever viewport holds it: keeping the wrapper in a
-- global and putting it on a fresh Viewport handed Urho3D a freed
-- RenderPath, and the first frame after the game segfaulted in
-- View::Define with a null renderPath_ (2026-09-23). Rebuilding it
-- costs one clone.
function apply_room_path(vp)
	-- **On by default, and without HDR.** Urho3D's Tonemap works
	-- appended to the client's own render path; what draws a black frame
	-- is `HDRRendering`. So the room is tonemapped in LDR: the
	-- highlights roll off instead of clipping, which took the pure-white
	-- share from 3.58 per cent to nothing.
	--
	-- **What HDR does here, exactly** (BUILDAT_LAUNCH_HDR=1 to see it):
	-- the frame is not black, it is *only the unlit materials* -- the
	-- orbs and the readout draw and everything lit by a point light does
	-- not. Brighten the shot six times and that is what is in it. So the
	-- light passes are not reaching the HDR buffer, and the base pass
	-- is. apps/voxel_lighting renders in HDR with the same three
	-- effects appended in the same order, and the difference that is
	-- left is that its scene is lit by a **directional** light and this
	-- one by points. That is where the next look starts, and it is a
	-- client-wide question rather than this room's: nothing else in the
	-- tree lights an HDR scene with point lights.
	local want = env("BUILDAT_LAUNCH_TONEMAP")
	if want == "" then want = "Tonemap" end
	-- **HDR is on** (user, 2026-09-23: a float target is non-negotiable
	-- here). A renderer that clips every radiance at 1.0 before the
	-- tonemap measures a clamp rather than light, and a source then
	-- cannot be brighter than a fully-lit wall. BUILDAT_LAUNCH_NOHDR=1
	-- goes back to LDR, which is what the two can be compared with.
	local hdr = env("BUILDAT_LAUNCH_NOHDR") == ""
	-- BUILDAT_LAUNCH_SUN adds one directional light, to settle whether
	-- it is point lights in particular that the HDR path drops
	if env("BUILDAT_LAUNCH_SUN") ~= "" then
		local node = scene:CreateChild("sun")
		node.direction = magic.Vector3(-0.4, -0.8, 0.45)
		local sun = node:CreateComponent("Light")
		sun.lightType = magic.LIGHT_DIRECTIONAL
		sun.color = magic.Color(1, 0.95, 0.85, 1)
		sun.brightness = 1.4
		sun.castShadows = false
		kept[#kept + 1] = sun
		log:info("tonemap: a directional light added")
	end
	if want ~= "" or hdr then
		-- HDR on its own, so it can be told apart from the effects
		magic.renderer.HDRRendering = hdr
		log:info("tonemap: HDR " .. tostring(hdr))
		local rp = vp.renderPath:Clone()
		for fx in want:gmatch("[^,]+") do
			local xml = magic.cache:GetResource("XMLFile",
					"PostProcess/" .. fx .. ".xml")
			if xml then
				local before = rp:GetNumCommands()
				rp:Append(xml)
				log:info("tonemap: " .. fx .. " added " ..
						(rp:GetNumCommands() - before) .. " commands")
			else
				log:warning("tonemap: no PostProcess/" .. fx .. ".xml")
			end
		end
		-- **Uncharted2, not Reinhard.** Tonemap.xml ships three curves
		-- with the Reinhard one enabled; Reinhard lifts the blacks and
		-- caps the highlights, which is the opposite of the reference
		-- frame's deep blacks and bright sources (its median is 38 and
		-- its 99th 252; Reinhard at a bias that reached 80 put the 99th
		-- at 184). The filmic curve keeps the toe low and rolls the
		-- shoulder off.
		rp:SetEnabled("TonemapReinhardEq3", false)
		rp:SetEnabled("TonemapUncharted2", true)
		rp:SetShaderParameter("TonemapExposureBias",
				tonumber(env("BUILDAT_LAUNCH_BIAS")) or 1.15)
		rp:SetShaderParameter("TonemapMaxWhite",
				tonumber(env("BUILDAT_LAUNCH_WHITE")) or 1.15)
		rp:SetShaderParameter("AutoExposureAdaptRate", 2.0)
		rp:SetShaderParameter("AutoExposureLumRange",
				magic.Vector2(0.06, 2.0))
		rp:SetShaderParameter("AutoExposureMiddleGrey", 0.12)
		vp.renderPath = rp
		log:info("tonemap: " .. want .. ", " .. rp:GetNumCommands() ..
				" commands, HDR on")
	end
end
apply_room_path(viewport)


-- The name of the preset in the corner, so a picture says which it is
label = room_ui_child("Text")
label:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 14)
label.horizontalAlignment = magic.HA_LEFT
label.verticalAlignment = magic.VA_BOTTOM
label:SetPosition(8, -8)

-- **There was a patch bay here, and it was removed 2026-09-25** (user):
-- a rack of server ports standing at x 8.2, forward and to the left of
-- where the player stands, 0.7 by 3.6 by 2.2 voxels a port -- a wall
-- once a few addresses were known. It was a second copy of the server
-- list in wall form: the servers are already orbs on the floor, which
-- is where they belong, moving pieces being what a save and a server
-- are. Not to be rebuilt.

-- **The version, as a readout rather than as text on a HUD**
-- ([BOX_PLAYTEST_4]'s complaint answered with geometry): a seven-segment
-- display standing on the floor at spawn, its lit segments unlit-bright
-- and its dark ones just visible, the way a VFD's unlit segments are. It
-- is a real light source, as every readout in this room is.
local SEG_ON = {
	["0"] = "abcdef", ["1"] = "bc", ["2"] = "abdeg", ["3"] = "abcdg",
	["4"] = "bcfg", ["5"] = "acdfg", ["6"] = "acdefg", ["7"] = "abc",
	["8"] = "abcdefg", ["9"] = "abcdfg", ["-"] = "g", ["."] = "p",
	-- The letters a version string can carry, in the shapes a
	-- seven-segment display has for them
	["b"] = "cdefg", ["d"] = "bcdeg", ["a"] = "abcefg", ["e"] = "adefg",
	["f"] = "aefg", ["c"] = "adef", ["r"] = "eg", ["t"] = "defg",
	["v"] = "cde", ["o"] = "cdeg", ["n"] = "ceg", ["i"] = "e",
	["g"] = "acdfg", ["l"] = "def", ["p"] = "abefg", ["u"] = "cde",
}
-- Each segment as {x, y, w, h} in a digit's own box, 1 wide and 2 high
local SEG_BOX = {
	a = {0.5, 1.90, 0.76, 0.16}, g = {0.5, 1.00, 0.76, 0.16},
	d = {0.5, 0.10, 0.76, 0.16}, f = {0.10, 1.47, 0.16, 0.70},
	b = {0.90, 1.47, 0.16, 0.70}, e = {0.10, 0.53, 0.16, 0.70},
	c = {0.90, 0.53, 0.16, 0.70}, p = {1.02, 0.10, 0.16, 0.16},
}

local function readout(text, at, scale, colour)
	local lit = glow(magic.Color(colour.r * 2.5, colour.g * 2.5,
			colour.b * 2.5, 1))
	-- What an unlit segment is: the same shape, barely there, so the
	-- display reads as a device with digits in it rather than as floating
	-- strokes
	local dim = glow(magic.Color(colour.r * 0.10, colour.g * 0.10,
			colour.b * 0.10, 1))
	local x = at.x
	for i = 1, #text do
		local ch = text:sub(i, i)
		local on = SEG_ON[ch] or ""
		if ch ~= "." then
			-- The face the digit is cut out of, which is what makes the
			-- dark segments read
			part("Box", magic.Vector3(x + 0.5 * scale, at.y + scale,
					at.z - 0.06 * scale),
					magic.Vector3(1.24 * scale, 2.24 * scale, 0.10 * scale),
					machined)
		end
		for seg, b in pairs(SEG_BOX) do
			if (seg == "p") == (ch == ".") then
				part("Box", magic.Vector3(x + b[1] * scale,
						at.y + b[2] * scale, at.z),
						magic.Vector3(b[3] * scale, b[4] * scale,
						0.10 * scale),
						on:find(seg, 1, true) and lit or dim)
			end
		end
		-- Leftwards in x, which is rightwards on screen: the camera looks
		-- down -Z and Urho3D is left-handed, so a string advancing +x
		-- reads back to front
		x = x - (ch == "." and 0.40 or 1.15) * scale
	end
	-- A readout that lights what is around it, which is the whole reason
	-- they are objects here and not a HUD
	local node = scene:CreateChild("readout_light")
	node.position = V(at.x - #text * 0.6 * scale, at.y + scale, at.z + 0.6)
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_POINT
	light.color = colour
	light.brightness = 0.9 * PBR_INTENSITY
	light.range = 5 * U
	light.castShadows = false
end

-- Standing at spawn, low and to the left, turned a little out of the wall
readout("b" .. api.version(), {x = 9.0, y = 0.25, z = -1.0}, 0.34,
		magic.Color(0.15, 0.85, 1.0, 1))

-- **The orb turns to face whoever approaches** (user), and the name is
-- over the one being pointed at only -- not always on, which is what
-- keeps the room from being a label wall.
--
-- "Pointed at" is what the arrows browse, or what a click is on: the
-- stations and the keys choose it, not the middle of the screen.
-- **The camera is a state, not a constant**, because the fast path flies
-- it: where it is and what it looks at are numbers that get lerped, and
-- the pointing below reads them rather than the two it was set up with.
-- Copies, not the node's own vectors -- a position property hands back a
-- reference that follows the node.
-- **The wall station frames the formation** ([LAUNCH_WORLD] stage 2,
-- section 3): near horizontal, square on to the middle of the rows, and
-- back far enough that every sphere and the name beside it is in the
-- frame with a margin round it -- the neighbours as context. The fov is
-- the 72 degrees set below, and the frame is taken as 16:9.
-- BUILDAT_LAUNCH_STAND=<metres> overrides how far back it stands.
local HOME_FROM, HOME_AT
do
	local x0, x1, y0, y1 = 1e9, -1e9, 1e9, -1e9
	for b = 1, BAYS do
		local o = orb_places[b]
		if o then
			x0, x1 = math.min(x0, o.x), math.max(x1, o.x)
			y0, y1 = math.min(y0, o.y), math.max(y1, o.y)
		end
	end
	-- The last column's names reach most of a pitch past its spheres,
	-- toward -x, which is the screen's right
	local names = (room.COL_PITCH - room.POCKET) * VOXEL_M
	local cx = (x0 - names + x1) / 2
	local cy = (y0 + y1) / 2
	local half_w = (x1 - x0 + names) / 2 + 2.0
	local half_h = (y1 - y0) / 2 + 1.5
	local t = math.tan(math.rad(72 / 2))
	local back = math.max(half_h / t, half_w / (t * 16 / 9), 6.0)
	local wall_z = BAY_Z * VOXEL_M
	HOME_FROM = {x = cx, y = cy,
		z = tonumber(env("BUILDAT_LAUNCH_STAND")) or wall_z + back}
	HOME_AT = {x = cx, y = cy, z = wall_z}
	log:info(string.format("wall station: %.1f m back from the wall, " ..
			"the formation %d by %d", HOME_FROM.z - wall_z,
			room.cols or 0, room.rows or 0))
end
-- **The far thing** (light look "far", stage 3): a bright disc just over
-- the formation's top row, a little proud of the wall, and the light it
-- throws -- one place for the eye to rest above the names
if light_look.far then
	local f = light_look.far
	local top = -1e9
	for b = 1, BAYS do
		if orb_places[b] then top = math.max(top, orb_places[b].y) end
	end
	local node = scene:CreateChild("far_thing")
	node.position = magic.Vector3(HOME_AT.x * U, (top + 1.8) * U,
			(HOME_AT.z + 0.3) * U)
	node.rotation = magic.Quaternion(90, magic.Vector3(1, 0, 0))
	node.scale = magic.Vector3(1.6 * U, 0.06 * U, 1.6 * U)
	local o = node:CreateComponent("StaticModel")
	o.model = magic.cache:GetResource("Model", "Models/Cylinder.mdl")
	local m = magic.Material:new()
	m:SetTechnique(0, magic.cache:GetResource("Technique",
			"Techniques/NoTextureUnlit.xml"))
	m:SetShaderParameter("MatDiffColor", magic.Color(f.color[1] * f.emissive,
			f.color[2] * f.emissive, f.color[3] * f.emissive, 1))
	kept[#kept + 1] = m
	o.material = m
	o.castShadows = false
	local light = node:CreateComponent("Light")
	light.lightType = magic.LIGHT_POINT
	light.color = magic.Color(f.color[1], f.color[2], f.color[3], 1)
	light.brightness = f.light * PBR_INTENSITY
	light.range = 22 * U
	light.castShadows = false
end
log:info("light: " .. light_look_name)
local cam = {
	from = {x = HOME_FROM.x, y = HOME_FROM.y, z = HOME_FROM.z},
	at = {x = HOME_AT.x, y = HOME_AT.y, z = HOME_AT.z},
	to_from = nil, to_at = nil, t = 0,
}
local view_from = V(cam.from.x, cam.from.y, cam.from.z)
local view_dir = magic.Vector3(0, 0, -1)

local function apply_camera()
	camera_node.position = V(cam.from.x, cam.from.y, cam.from.z)
	camera_node:LookAt(V(cam.at.x, cam.at.y, cam.at.z))
	view_from = V(cam.from.x, cam.from.y, cam.from.z)
	local dx, dy, dz = cam.at.x - cam.from.x, cam.at.y - cam.from.y,
			cam.at.z - cam.from.z
	local l = math.sqrt(dx * dx + dy * dy + dz * dz)
	view_dir = magic.Vector3(dx / l, dy / l, dz / l)
end

-- **The camera flies to what was picked**, which is how the fast path
-- teaches the room: someone who typed a name sees where that name lives
-- on the way in.
local FLY_SECONDS = 1.3
-- **A search hop is swift** (user, 2026-09-23): a launch's flight is a
-- stately arrival, and walking a list of matches with the arrows wants
-- to keep up with the keys rather than queue behind them
local HOP_SECONDS = 0.45
local function fly_to(from, at, seconds)
	cam.to_from, cam.to_at, cam.t = from, at, 0
	cam.fly_seconds = seconds or FLY_SECONDS
	cam.was_from = {x = cam.from.x, y = cam.from.y, z = cam.from.z}
	cam.was_at = {x = cam.at.x, y = cam.at.y, z = cam.at.z}
end

function handle_camera_update(event_type, event_data)
	-- **An animation stands down for a screen on top of the room and
	-- not for a launch** ([LAUNCH_FROZEN]): the launch is seconds of
	-- this room's own movement
	if screen_taken() then return end
	if not cam.to_from then
		return
	end
	cam.t = math.min(1, cam.t + event_data:GetFloat("TimeStep") /
			(cam.fly_seconds or FLY_SECONDS))
	local e = cam.t * cam.t * (3 - 2 * cam.t)
	for _, k in ipairs({"x", "y", "z"}) do
		cam.from[k] = cam.was_from[k] + (cam.to_from[k] - cam.was_from[k]) * e
		cam.at[k] = cam.was_at[k] + (cam.to_at[k] - cam.was_at[k]) * e
	end
	apply_camera()
	if cam.t >= 1 then
		cam.to_from, cam.to_at = nil, nil
		-- **Said once a flight ends** ([CHECK_COST]): a drive that has
		-- asked the camera to go somewhere waits for this rather than
		-- guessing at FLY_SECONDS, which is the guess that shot frames
		-- mid-flight when the room got faster
		log:info("camera: landed")
		-- **What is pointed at is said again when the flight lands**
		-- (2026-09-25): the name over an orb is written when the
		-- pointed orb changes, and during a fly that is whatever was
		-- briefly nearest the middle on the way past -- so a portrait
		-- of one orb came back wearing a neighbour's name. -1 is
		-- "whatever is pointed at now, say it again", the same thing a
		-- mode change asks for.
		pointed_orb = -1
	end
end
magic.SubscribeToEvent("Update", function(t, d) handle_camera_update(t, d) end)

-- **What the room's own frames cost** (2026-09-26): the first half
-- minute after a start reads badly and nothing in the room said so.
-- The worst frame of each second while the room is young, and after
-- that only a frame over the ceiling, so a settled room is quiet.
frame_watch = {worst = 0, worst_at = 0, due = 0, started = nil,
		said = 0,
		-- A settled room's frame is well under the engine's own clamp, so
		-- a reading of the settled frame asks for a lower bar
		ceiling = tonumber(env("BUILDAT_LAUNCH_FRAME_CEILING")) or 0.1,
		young = 45, over = 0, summed = false,
		-- A young room's frames are the bake's, not the room's: a reading
		-- of the settled frame waits this many seconds for its table
		dump_after = tonumber(env("BUILDAT_LAUNCH_FRAME_DUMP_AFTER")) or 0,
		-- Every second, for an A/B of what a frame is spent on
		every = env("BUILDAT_LAUNCH_FRAME_TRACE") ~= ""}
-- Declared here and filled at the end of the file: the sandbox refuses
-- an assignment to a global that the main chunk has not made
frame_trace = {us = {}, due = 0}
handle_frame_trace = nil
function handle_frame_watch(event_type, event_data)
	local dt = event_data:GetFloat("TimeStep")
	local now = buildat.get_time_us() / 1e6
	frame_watch.started = frame_watch.started or now
	local age = now - frame_watch.started
	if dt > frame_watch.worst then
		frame_watch.worst, frame_watch.worst_at = dt, age
	end
	frame_watch.due = frame_watch.due - dt
	if frame_watch.due > 0 then
		return
	end
	frame_watch.due = 1.0
	-- And the engine's own table for a frame that cost this much, at
	-- most a few times: what a Lua line cannot say is where in the
	-- engine the time went (the same reading [PACKET_STALL] takes)
	if frame_watch.worst >= frame_watch.ceiling and frame_watch.said < 3 and
			age >= frame_watch.dump_after and buildat.profiler_data then
		frame_watch.said = frame_watch.said + 1
		log:info("the frame that cost " ..
				math.floor(frame_watch.worst * 1000) .. " ms:\n" ..
				(buildat.profiler_data(4) or ""))
	end
	-- Said when a second's worst frame is over the ceiling, and once at
	-- the end of the young window whatever it was: a settled room is
	-- quiet and a slow one says so without anybody asking.
	if frame_watch.worst >= frame_watch.ceiling or frame_watch.every then
		log:info(string.format(
				"frames: at %.0f s the worst of the last second was " ..
				"%.0f ms (%.0f fps at that rate)", age,
				frame_watch.worst * 1000,
				frame_watch.worst > 0 and 1.0 / frame_watch.worst or 0))
	end
	if not frame_watch.summed and age >= frame_watch.young then
		frame_watch.summed = true
		log:info(string.format(
				"frames: the first %.0f s had %d seconds whose worst " ..
				"frame was over %.0f ms", frame_watch.young,
				frame_watch.over or 0, frame_watch.ceiling * 1000))
	end
	if frame_watch.worst >= frame_watch.ceiling then
		frame_watch.over = (frame_watch.over or 0) + 1
	end
	frame_watch.worst = 0
end
magic.SubscribeToEvent("Update", function(t, d) handle_frame_watch(t, d) end)

-- **One mode** ([LAUNCH_WORLD] stage 2, section 11): point-and-click
-- with the keyboard, the mouse always free. The proof's FPS body -- the
-- walk, the look, the collision, the captured mouse, the crosshair, the
-- hold, digging, carrying and placing -- is cut, and the camera is the
-- only eye: it stands at stations and flies to what is picked.

-- One floor orb said out loud, with where it stands, so a run needs no
-- constant of this room's to aim at it
for i = 1, #orb_places do
	if ORBS[i] and ORBS[i].floor and orb_places[i] then
		local o = orb_places[i]
		log:info(string.format("orb sample: %s at %.2f %.2f %.2f from " ..
				"%.2f %.2f %.2f", ORBS[i].name, o.x * U, o.y * U, o.z * U,
				HOME_FROM.x * U, HOME_FROM.y * U, HOME_FROM.z * U))
		break
	end
end

terminal_open = false

-- **A scripted run never touches the mouse.** The whitelist stands down
-- on cursor changes in one ([SCRIPTED_CURSOR]), but a check shares a
-- desk with the person whose mouse it is and the room should not be
-- asking at all (user, 2026-09-23: "I can't use my mouse during your
-- tests"). The mouse is free and visible, always: what this does is
-- take it back from whatever left it otherwise.
local function mouse_for(reason)
	if api.is_scripted() then return end
	magic.input:SetMouseVisible(true, reason)
	magic.input:SetMouseMode(magic.MM_ABSOLUTE)
end

-- Whether somebody else held the screen last frame ([LAUNCH_WORLD]'s
-- one gate): a global because this file is at Lua's 200-local limit,
-- and **declared here rather than beside the other room state at the
-- end of the file** -- the Update handler is subscribed a thousand
-- lines above that and fires while the chunk is still building the
-- room, where the sandbox refuses an undeclared global. **True until
-- the first frame**: a room booted from another launch UI's Enter (its
-- chooser) heard that same key and launched the first orb (2026-10-06).
held_was = true

-- **One gate, asked once a frame** ([LAUNCH_WORLD], 2026-09-24:
-- "whatever holds the screen owns the input"). Three faults of this
-- shape in three days -- the pause dialog looking with the mouse, the
-- console opened over the room keeping the room's Tab, and "switch to
-- the menu" leaving the camera on the mouse with no cursor -- because
-- every feature remembered its own condition and none of them knew
-- about a launch UI booted over this one. `set_launch_ui` leaves the
-- room running underneath, so the room asks whose screen it is rather
-- than being told.
--
-- What is *not* in here: the room's own screens. The pause dialog, the
-- desk and a flight are the room's, and it keeps the keyboard for them.
-- This is only about
-- somebody else's screen.
-- **The stack knows what is on the screen and the room does not push to
-- it** ([MENU_STUCK], user 2026-09-24: a game's ContentDB menu was still
-- on the screen while the room had taken the input back -- Escape opened
-- the room's pause dialog over it and typing went to both). The room
-- draws straight on `ui.root`, so anything on the main stack is somebody
-- else's screen, including one that outlived the game that pushed it.
-- Asking the stack is what the five flags below cannot do: they describe
-- every way a screen can arrive and no way one can linger.
room_stack = require("buildat/extension/uistack")
room_stack = room_stack.safe or room_stack

-- **Whether another screen is actually on top of the room**
-- ([LAUNCH_FROZEN], user 2026-09-24: a launch froze the dissolve at its
-- first frame). The room's animations stand down for a game, a console,
-- a backdrop or another launch UI -- and explicitly not for
-- `launching`, which is the room's own seconds of animation between the
-- hold and the game. Input stands down on `held_by_others()` below,
-- which is the other question: whether the player is steering the room.
function screen_taken()
	if in_app or console_open or backdrop then
		return true
	end
	local st = room_stack and room_stack.main and room_stack.main.stack
	if st and st[1] then -- not #st: see leave_app below
		return true
	end
	local who = api.launch_ui_name and api.launch_ui_name() or nil
	return who ~= nil and who ~= "launch_world"
end

function held_by_others()
	-- `launching` is the input half of `in_app`: the launch has
	-- committed and the player is not steering the room any more, but
	-- the room is still what is on the screen ([LAUNCH_WORLD],
	-- 2026-09-24: it stood down at the first moment of a sequence that
	-- runs for seconds and the player watched the rest of it with
	-- nothing to look at)
	return launching or screen_taken()
end

-- The last answer, so the handing over happens once rather than every
-- frame: the mouse goes back to the cursor when somebody else takes the
-- screen, and comes back to the room's own mode when the room has it
-- again. `held_was` is a global beside the other room state, this file
-- being at Lua's 200-local limit.
function hand_over_if_needed()
	local held = held_by_others()
	if held == held_was then
		return held
	end
	held_was = held
	if held then
		log:info("input: handed to whatever holds the screen")
		mouse_for("launch_world: somebody else's screen")
	else
		log:info("input: the room has the screen again")
		mouse_for("launch_world: the room has the screen")
	end
	return held
end


function handle_room_update(event_type, event_data)
	-- A backdrop takes no input ([TWO_AUDIENCES]' composition)
	if backdrop then return end
	-- A launch in flight: the room draws on until the game takes the
	-- view, and this is what notices that it has
	launch_watch()
	-- **The one gate, asked once a frame** ([LAUNCH_WORLD]: whatever
	-- holds the screen owns the input). This is the asking; every other
	-- handler below reads the answer it left.
	hand_over_if_needed()
end
magic.SubscribeToEvent("Update", function(t, d) handle_room_update(t, d) end)

-- **The launcher's own storage** ([LAUNCH_SANDBOX]): one name, and the
-- client puts it under this launch extension's directory. The room used
-- to build the path itself and open it.
local SAVE_NAME = "room.txt"


-- **What the player pinned** ([LAUNCH_WORLD] section 14: the room's save
-- holds the bookmarks row, and pinning is the player's only organising).
-- A set for "is this pinned" and a list for the order they were pinned
-- in, because the row reads left to right and a set has no order.
-- Globals rather than locals: this chunk is near Lua 5.1's two hundred
-- and the file says so in several places already.
--
-- **A row a bookmark**, `!bookmark <key>`, rather than one line with all
-- of them on it: a launch key is `<from>/<id>` and an id is whatever a
-- launcher file called it, so a separator would need escaping and a row
-- that reads to the end of the line does not.
bookmarks = {}
bookmark_order = {}
-- Where an orb stood before it was pinned, so unpinning puts it back
-- rather than leaving a hole in the wall
bookmark_home = {}

-- The three things a move is: the sphere, its light, and where the room
-- thinks the sphere is. `part()` takes metres and multiplies by U on the
-- way in; a node's own position is in those units and `orb_places` is in
-- metres, and the two are kept in step here.
function move_orb_to(i, mx, my, mz)
	if orb_nodes[i] then
		orb_nodes[i].position = magic.Vector3(mx * U, my * U, mz * U)
	end
	if light_nodes[i] then
		light_nodes[i].position = magic.Vector3(mx * U, my * U, mz * U)
	end
	orb_places[i] = {x = mx, y = my, z = mz}
end

-- **The bookmarks row, at the standing place** ([LAUNCH_WORLD] stage
-- 1(b)). What the player pinned stands in front of where they stand, in
-- the order they pinned it, low enough to leave the wall its frame. An
-- orb is moved rather than copied: two spheres for one game would be two
-- things to point at and one of them a lie about where it lives.
function place_bookmarks()
	local row = {}
	for _, key in ipairs(bookmark_order) do
		if bookmarks[key] then
			for i, o in ipairs(ORBS) do
				if o.key == key and orb_nodes[i] then
					row[#row + 1] = i
					break
				end
			end
		end
	end
	local in_row = {}
	for _, i in ipairs(row) do in_row[i] = true end
	for i, home in pairs(bookmark_home) do
		if not in_row[i] then
			move_orb_to(i, home.x, home.y, home.z)
			bookmark_home[i] = nil
		end
	end
	for k, i in ipairs(row) do
		if not bookmark_home[i] then
			local p = orb_places[i]
			bookmark_home[i] = {x = p.x, y = p.y, z = p.z}
		end
		-- On the floor, resting on it as the floor's own spheres do, and
		-- far enough ahead that the row is a shelf at the player's feet
		-- rather than a sphere across the whole frame: at 2.4 m one
		-- pinned orb filled the middle of the view and the wall behind
		-- it was gone (2026-09-28, the first try).
		move_orb_to(i, HOME_FROM.x + (k - (#row + 1) / 2) * 1.3,
				orb_across(ORBS[i]) * VOXEL_M / 2, HOME_FROM.z - 5.0)
	end
	log:info("bookmarks: " .. #row .. " in the row at the standing place")
end

-- The room's save, read at boot: the bookmarks and the sound levels,
-- one row a line, which is a file a person can read and delete. Rows of
-- placed voxels, moved spheres and the field of view, which the proof
-- wrote, are read past ([LAUNCH_WORLD] section 14 cuts them).
do
	-- BUILDAT_LAUNCH_BARE=1 reads no save either: what a look reading
	-- compares against the reference is the room as it is generated,
	-- not the room as somebody left it
	local text = env("BUILDAT_LAUNCH_BARE") == "" and
			api.storage_read(SAVE_NAME) or nil
	if text then
		local n = 0
		for line in text:gmatch("[^\n]+") do
			if line:match("^!sound_db ") then
				-- The room's own levels, kept where its voxels are
				local a, b = line:match("^!sound_db (-?%d+) (-?%d+)$")
				if a then
					saved_sound = {tonumber(a), tonumber(b)}
					n = n + 1
				end
			elseif line:match("^!sound ") then
				-- **A row from before the decibels** ([VOLUME_LAW]): two
				-- fader positions, read once through the old meaning and
				-- rounded to the nearest step, so nobody's room gets
				-- louder or quieter on an upgrade. Written back as
				-- !sound_db on the next save.
				local a, b = line:match("^!sound ([%d%.]+) ([%d%.]+)$")
				if a then
					local function db_of(v)
						v = tonumber(v) or 0
						if v <= 0 then return -33 end
						local db = math.floor(20 * math.log10(v) / 3 + 0.5) * 3
						return math.max(-33, math.min(0, db))
					end
					saved_sound = {db_of(a), db_of(b)}
					log:info("save: the !sound row is fader positions; " ..
							a .. " and " .. b .. " are " ..
							saved_sound[1] .. " and " .. saved_sound[2] ..
							" dB")
					n = n + 1
				end
			elseif line:match("^!bookmark ") then
				local key = line:match("^!bookmark (.+)$")
				if key and not bookmarks[key] then
					bookmarks[key] = true
					bookmark_order[#bookmark_order + 1] = key
					n = n + 1
				end
			end
		end
		log:info("save: " .. n .. " rows read, " ..
				#bookmark_order .. " of them bookmarks")
	end
	place_bookmarks()
end

-- **The room's own sound levels**, a global table rather than a field of
-- the drone below: the save is written by a function defined long before
-- the drone exists, and reaching forward for it wrote nothing and said
-- nothing (2026-09-24). [ROOM_SOUND] wants these moved by ear, so they
-- are two rows on the terminal and two numbers in the room's save.
-- **Decibels below full, on the settings' own 3 dB steps**
-- ([VOLUME_LAW]): the client's volume moved to decibels and these are
-- the tree's other two, so they move with it. The defaults are the
-- nearest step to what they were by ear -- the orbs were 1.0 and the
-- bed 0.6, which is -4.4 dB and rounds to -3. -33 is off.
levels = {orbs = 0, bed = -3}

-- The one place a level becomes a gain, as the client has one
function level_gain(db)
	if db <= -33 then
		return 0
	end
	return 10 ^ (db / 20)
end

local save_dirty = false
local function write_save()
	local keys = {}
	for _, key in ipairs(bookmark_order) do
		if bookmarks[key] then
			keys[#keys + 1] = "!bookmark " .. key
		end
	end
	keys[#keys + 1] = string.format("!sound_db %d %d", levels.orbs,
			levels.bed)
	local ok, why = api.storage_write(SAVE_NAME,
			table.concat(keys, "\n"))
	if not ok then
		log:warning("save: " .. tostring(why))
		return
	end
	log:info("save: " .. #keys .. " rows written")
end

-- **The save is written a frame after it is dirtied**, not at once: the
-- terminal's rows set it while a level is being stepped, and one write
-- for a run of steps is enough
function handle_save_update()
	if save_dirty then
		save_dirty = false
		write_save()
	end
end
magic.SubscribeToEvent("Update", function(t, d) handle_save_update(t, d) end)


-- **The name is an overlay, not geometry** ([ORB_LABEL], user
-- 2026-09-24). A `Text3D` over an orb in a pocket is occluded by the
-- stone in front of it, and the material route to make it draw through
-- was tried and is worse than the occlusion (it draws the name dark red
-- and half-eaten: Urho3D builds that material in C++ per batch). The
-- room already projects every orb to the screen for picking, so the
-- name and its caption are **the room's own UI text placed at that
-- point** -- which cannot be occluded at any pocket depth, and takes
-- the label's half of the floor flag with it: an overlay has no plane
-- to stand at.
--
-- **Typography as graphic design**, which is what that era did with a
-- name: huge letterforms and wide tracking, not a centred column of
-- small labels. There is no tracking setting, so the spacing is spaces
-- -- which is how it was done then too.
-- The ceiling is the font ([TRANSLATION_FONT]): Latin-1 and Cyrillic,
-- so a CJK name does not draw and whoever widens the font settles this.
local name_text = room_ui_child("Text")
name_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 44)
name_text:SetColor(magic.Color(1, 1, 1, 1))
name_text.horizontalAlignment = magic.HA_CENTER
name_text.verticalAlignment = magic.VA_CENTER
name_text:SetTextAlignment(magic.HA_CENTER)
name_text.priority = 40
name_text.text = ""

-- **What the launcher said about it, under its name** (user, 2026-09-23:
-- the description does not really show up, and it should be fairly
-- close, above the orb). Small and unspaced, so it reads as a caption to
-- the name rather than as a second title.
local desc_text = room_ui_child("Text")
desc_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 20)
desc_text:SetColor(magic.Color(0.80, 0.84, 0.90, 1))
desc_text.horizontalAlignment = magic.HA_CENTER
desc_text.verticalAlignment = magic.VA_CENTER
desc_text:SetTextAlignment(magic.HA_CENTER)
desc_text.priority = 40
desc_text.text = ""

-- Which orb the label belongs to and how high above it it sits, in
-- voxels: the two places that say what the label reads say this too,
-- and the placing below is one function run every frame -- an overlay
-- has to follow the camera, where geometry stood still by itself.
label_orb = 0
label_lift = 1.5
function label_place()
	local n = orb_nodes[label_orb or 0]
	-- **Not at the desk, and not for a sphere on the wall**: the wall's
	-- spheres carry their names beside them (wall_labels below), and the
	-- browsed one's lights up there with its caption under it -- a big
	-- name over the formation lay across its neighbours
	if not n or name_text.text == "" or terminal_open or
			(label_orb >= 1 and label_orb <= BAYS) then
		name_text.visible = false
		desc_text.visible = label_orb >= 1 and label_orb <= BAYS and
				not terminal_open and desc_text.text ~= "" and
				station == "wall"
		return
	end
	local p = n.position
	local ax, ay, az = p.x, p.y + (label_lift or 1.5) * U, p.z
	local sp = camera_node:GetComponent("Camera"):WorldToScreenPoint(
			magic.Vector3(ax, ay, az))
	-- **Only behind the camera hides it** (user, 2026-09-25: walk up to
	-- an orb, look at its middle, and the name went out). Up close the
	-- point the name hangs from -- a voxel and a half above the orb --
	-- is off the top of the screen while the orb fills it, and a gate
	-- on the projection being inside the window took the name away
	-- exactly when the player was nearest the thing. A point behind the
	-- camera still has to go: it projects to nonsense, mirrored.
	local dx, dy, dz = ax - view_from.x, ay - view_from.y, az - view_from.z
	local ahead = dx * view_dir.x + dy * view_dir.y + dz * view_dir.z > 0
	name_text.visible = ahead
	desc_text.visible = ahead and desc_text.text ~= ""
	if not ahead then
		return
	end
	-- **Bounded to the window** (user, 2026-09-25): a name is wider
	-- than the orb it is over -- much wider, spaced out as it is -- so
	-- an orb near an edge had its last letters off the screen. Centred
	-- alignment makes the offsets from the middle, so the limit is half
	-- the window less half the text and a margin. This is also what
	-- keeps a name on screen when its anchor is not: an orb at arm's
	-- length hangs its name above the top, and the clamp brings it
	-- down to the edge rather than taking it away.
	-- **The UI's own coordinates, not the window's** (user, 2026-09-25:
	-- pointing at the sphere's right edge moved the name further left
	-- than the sphere). A projection is a fraction of the screen and a
	-- UI element is placed in the root's units, which are the window
	-- divided by the UI scale -- 1620 wide in a 900-pixel window here.
	-- Multiplying the fraction by the window's pixels is right only
	-- where that scale happens to be 1.
	local lw = math.max(1, magic.ui.root.width)
	local lh = math.max(1, magic.ui.root.height)
	local function bounded(e, x, y)
		local mx = math.max(0, lw / 2 - e.width / 2 - 8)
		local my = math.max(0, lh / 2 - e.height / 2 - 8)
		x = math.max(-mx, math.min(mx, x))
		y = math.max(-my, math.min(my, y))
		e:SetPosition(math.floor(x), math.floor(y))
		return y
	end
	local x = (sp.x - 0.5) * lw
	local y = (sp.y - 0.5) * lh
	-- **The caption keeps its place under the name**: both clamped on
	-- their own, an anchor above the screen pushed each to the same
	-- edge and the caption came out on top of the title (user,
	-- 2026-09-25). So the name is clamped and the caption is hung off
	-- where the name actually landed.
	local at = bounded(name_text, x, y - 30)
	bounded(desc_text, x, at + name_text.height / 2 + 4)
end

-- **Every game's name beside its sphere, always** ([LAUNCH_WORLD]
-- stage 2: "every sphere's name rendered permanently beside it,
-- left-aligned"). The same overlay the big label is, for the same
-- reason -- a Text3D in a pocket is occluded by its stone -- one per
-- pocket, hung off the sphere's right edge so the names line up into
-- columns with the formation. Placed every frame: an overlay follows
-- the camera. A global table, this chunk being at Lua's local limit.
wall_labels = {}
-- Declared here: the handler below runs while the chunk is still
-- building, and the stations are set up a long way down
station = "wall"
for b = 1, BAYS do
	local o = ORBS[b]
	if o and orb_places[b] then
		local t = room_ui_child("Text")
		t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 18)
		t:SetColor(o.empty and magic.Color(0.75, 0.62, 0.45, 1) or
				magic.Color(0.92, 0.90, 0.86, 1))
		t.horizontalAlignment = magic.HA_LEFT
		t.verticalAlignment = magic.VA_TOP
		t.priority = 30
		-- simplified: a name past eighteen letters is cut, so the
		-- columns stay columns; the browsed one's full name is the big
		-- label over it
		t.text = #o.name > 18 and (o.name:sub(1, 16) .. "..") or o.name
		wall_labels[#wall_labels + 1] = {b = b, text = t}
	end
end
function handle_wall_labels()
	-- At the wall's station only: from the floor's the names stood in a
	-- row along the top of the frame
	local hide = terminal_open or held_was or station ~= "wall"
	local lw = math.max(1, magic.ui.root.width)
	local lh = math.max(1, magic.ui.root.height)
	local cc = camera_node:GetComponent("Camera")
	for _, l in ipairs(wall_labels) do
		-- Where the sphere is, or would be: the empty pocket has none
		local op = orb_places[l.b]
		local n = orb_nodes[l.b]
		local show = not hide and op ~= nil
		if show then
			local p = n and n.position or V(op.x, op.y, op.z)
			local dx, dy, dz = p.x - view_from.x, p.y - view_from.y,
					p.z - view_from.z
			show = dx * view_dir.x + dy * view_dir.y + dz * view_dir.z > 0
			if show then
				local c = cc:WorldToScreenPoint(p)
				-- The sphere's right edge: a voxel and a half to the
				-- right of its middle, which clears every size there is
				local e = cc:WorldToScreenPoint(magic.Vector3(p.x - 1.5,
						p.y, p.z))
				-- The text's height and colour asked and set only when
				-- they change: each is a sandboxed call ([FRAME_WORK])
				l.h = l.h or l.text.height
				local x = math.floor(e.x * lw + 4)
				local y = math.floor(c.y * lh - l.h / 2)
				l.text:SetPosition(x, y)
				-- The one browsed or pointed at is lit, and its caption
				-- hangs under it, left-aligned with it
				local lit = l.b == label_orb
				local tone = lit and "lit" or (ORBS[l.b] and ORBS[l.b].empty and
						"empty" or "full")
				if l.tone ~= tone then
					l.tone = tone
					l.text:SetColor(lit and magic.Color(1.0, 0.82, 0.45, 1) or
							(tone == "empty" and
							magic.Color(0.75, 0.62, 0.45, 1) or
							magic.Color(0.92, 0.90, 0.86, 1)))
				end
				if lit and desc_text.visible then
					-- The caption is centred by its alignment: from the
					-- middle of the root, and its own middle
					desc_text:SetPosition(
							math.floor(x - lw / 2 + desc_text.width / 2),
							math.floor(y + l.h + 2 - lh / 2 +
							desc_text.height / 2))
				end
			end
		end
		if l.shown ~= show then
			l.shown = show
			l.text.visible = show
		end
	end
end
magic.SubscribeToEvent("Update", function(t, d) handle_wall_labels(t, d) end)

pointed_orb = 0
-- How near the pointer counts as on an orb, as a fraction of the screen
local POINT_RADIUS = 0.055

-- **Which orb is at a point on the screen** (the third playtest's rule,
-- carried from the dialog's rows to the room itself): by where each orb
-- lands on the screen rather than by a ray, which is a projection the
-- camera does anyway and no new reach for a sandbox.
function orb_at(fx, fy)
	local cam_c = camera_node:GetComponent("Camera")
	local near, near_d = 0, POINT_RADIUS
	for i = 1, #orb_places do
		local node = orb_nodes[i]
		if node then
			local sp = cam_c:WorldToScreenPoint(node.position)
			-- Behind the camera projects to nonsense; the room is in
			-- front of it and everything else is not worth a ray
			if sp.x > -0.2 and sp.x < 1.2 and sp.y > -0.2 and
					sp.y < 1.2 then
				local dx, dy = sp.x - fx, sp.y - fy
				local d = math.sqrt(dx * dx + dy * dy)
				if d < near_d then
					near, near_d = i, d
				end
			end
		end
	end
	return near
end
-- **The step change is the indicator** (user): a sphere is lit and is a
-- sphere, so it says "selected" in its own vocabulary rather than in a
-- wireframe's -- and it is a discrete jump, not a fade, so it reads the
-- instant it is selected.
local ORB_STEP = 1.18
local orb_base_scale = {}
-- A node nobody draws, borrowed for the arithmetic of "which way is
-- that": LookAt writes a rotation and nothing else builds one
local turner = scene:CreateChild("turner")
-- The way back to the menu, shown while the room is what the player is
-- using (ui_utils.menu_button); the pause menu's "2D menu" is the same.
-- **Both close the room** (user, 2026-10-06): it is not left drawing and
-- sounding behind the menu. Its screen elements and view go here, its
-- sound with its scene, and set_launch_ui's close drops its handlers,
-- so picking it again boots a new one. launch_overlay is assigned
-- further down, before anything can call this.
function close_room()
	for _, e in ipairs(room_ui) do e:Remove() end
	room_ui = {}
	launch_overlay:Remove()
	room_menu_button:Remove()
	-- The Scene itself refuses SetEnabled (an error, and nothing changes):
	-- its children are what go off
	for i = scene:GetNumChildren() - 1, 0, -1 do
		scene:GetChild(i):SetDeepEnabled(false)
	end
	magic.set_preferred_viewports({})
	log:info("room: closed")
end
room_menu_button = require("buildat/extension/ui_utils")
room_menu_button = (room_menu_button.safe or room_menu_button)
		.menu_button(magic.ui.root, close_room, {close = true})
-- Each orb's facing: {node, x, y, z (the view's), left (s), q}
orb_face = {}
function handle_orb_update(event_type, event_data)
	room_menu_button.visible = not (launching or screen_taken())
	-- **An animation stands down for a screen on top of the room and
	-- not for a launch** ([LAUNCH_FROZEN]): the launch is seconds of
	-- this room's own movement
	if screen_taken() then return end
	-- **Nothing is pointed at while the room shows itself off**: the
	-- sweep is not a player looking at an orb, and the name of whatever
	-- was in the middle of the screen when the drift began hung over the
	-- showcase until they came back (2026-09-25). The same rule the
	-- hint follows -- nobody is being told anything while this runs.
	if attracting then
		if name_text.text ~= "" or desc_text.text ~= "" then
			name_text.text, desc_text.text = "", ""
			label_place()
		end
		-- "whatever is pointed at now, say it again" for the frame the
		-- sweep ends on
		pointed_orb = -1
		return
	end
	local dt = math.min(0.1, event_data:GetFloat("TimeStep"))
	local best, best_score, best_dot, best_up = 0, math.huge, -1, false
	-- The view's and each orb's components read once: a field of a
	-- vector is a sandboxed call, and the samples below read them 30
	-- times an orb ([FRAME_WORK])
	local fx, fy, fz = view_from.x, view_from.y, view_from.z
	local vx, vy, vz = view_dir.x, view_dir.y, view_dir.z
	-- Not ipairs: an empty niche leaves a hole in the list and ipairs
	-- stops at it, which would hide every orb past the empty one
	for i = 1, #orb_places do
		local node = orb_nodes[i]
		if node then
			local p = node.position
			local px, py, pz = p.x, p.y, p.z
			-- **The selection volume is not the drawn volume** (user,
			-- 2026-09-23): close to a floor orb a player points *over*
			-- it, since that is where the horizon sits comfortably, and
			-- the middle of the screen left it. So the thing is pointed at
			-- anywhere up its own column -- its footprint extruded from
			-- where it stands to eye height -- and the best point on
			-- that column answers rather than its centre.
			--
			-- Five samples up the column rather than a closest-point
			-- solve: the column is at most three voxels tall and this
			-- runs once an orb a frame.
			--
			-- **From the orb's bottom, not from its middle**
			-- ([POINT_LOW], user 2026-09-25: a sphere's selection box
			-- was above the sphere). The samples ran from `p.y` up, so
			-- the lower half of every orb was outside the volume that
			-- selects it -- worst up close, where a two-voxel orb at
			-- five voxels subtends twenty degrees against a tolerance
			-- of about ten, which is the distance a player reaches
			-- from. The radius is what the orb was drawn at.
			local r = 0.5 * orb_across(ORBS[i])
			local bottom = py - r
			local top = py + r
			-- **Measured against the orb's own size, not by the angle
			-- alone** ([POINT_LOW]'s other half, 2026-09-25): a dot
			-- says nothing about how big a thing looks, so a distant
			-- orb a little off the axis beat a near one the screen's
			-- middle was on -- which is how a portrait of one orb came back
			-- with its neighbour's name over it. The score is the angle
			-- in units of the orb's own angular radius: under one is
			-- the screen's middle on the disc, and a near orb is forgiven the
			-- degrees it fills.
			local score, dot, up = math.huge, -1, false
			for k = 0, 4 do
				local y = bottom + (top - bottom) * (k / 4)
				local dx, dy, dz = px - fx, y - fy, pz - fz
				local l = math.sqrt(dx * dx + dy * dy + dz * dz)
				local d = (dx * vx + dy * vy + dz * vz) / l
				local s = math.huge
				if d > 0 and r > 0 then
					s = math.sqrt(math.max(0, 1 - d * d)) * l / r
				end
				if s < score then
					score, dot, up = s, d, y > py
				end
			end
			if score < best_score then
				best, best_score, best_dot, best_up = i, score, dot, up
			end
			-- Present the face: the mark sits in the middle of the
			-- sphere's UVs, which Sphere.mdl puts on -Z, so the orb looks
			-- away from the viewer to show it to them.
			--
			-- **And it turns rather than snapping** (the note that stood
			-- here said a snap is invisible while the camera is fixed
			-- and wants a slerp the moment it moves -- the camera walks
			-- now). The scratch node is where the target rotation comes
			-- from: LookAt is the only way to build one, and reading it
			-- off a node nobody draws costs nothing.
			-- Frame-rate independent: the same fraction of the way there
			-- every second, whatever the frame took
			-- **Where the middle of the UV map actually is** (user,
			-- 2026-09-24: the mark sits off to the left as if the
			-- sphere were turned a quarter). Aiming -Z at the viewer
			-- assumed the mark's middle lives there; it does not.
			-- Measured by turning every orb through 0, 90, 180 and 270
			-- degrees and looking: at **270** the icon is centred on
			-- the face, at the other three it is at the limb or behind.
			-- So the middle of `Sphere.mdl`'s UVs is a quarter turn
			-- round from -Z, and this is that quarter -- named, so the
			-- next model is a new measurement rather than a mystery.
			-- BUILDAT_LAUNCH_FACE_YAW is how it gets measured again (read
			-- at load).
			-- **Turned to where the view was when it moved** ([FRAME_WORK]:
			-- the look and the slerp were ~90 us an orb a frame): the target
			-- made again when the view moves, and turned to for 3 s
			-- (e^-21 of the way left); the bob under it is ignored.
			local f = orb_face[i]
			if not f or f.node ~= node or f.x ~= fx or f.y ~= fy or
					f.z ~= fz then
				turner.position = p
				turner:LookAt(magic.Vector3(fx * 2 - px, fy * 2 - py,
						fz * 2 - pz))
				f = {node = node, x = fx, y = fy, z = fz, left = 3,
						q = turner.rotation *
						magic.Quaternion(0, ONE_BIT.FACE_YAW, 0)}
				orb_face[i] = f
			end
			if f.left > 0 then
				f.left = f.left - dt
				node.rotation = f.left > 0 and
						node.rotation:Slerp(f.q, 1 - math.exp(-7.0 * dt)) or
						f.q
			end
		end
	end
	-- **What is browsed is what is pointed at** ([LAUNCH_WORLD] stage 2):
	-- the screen's middle is the fallback for when nothing is browsed;
	-- the keys choose, and a click launches whatever is under the cursor
	-- without pointing first
	if (browsed or 0) > 0 then
		best = browsed
	end
	if best ~= pointed_orb then
		-- The step, in both directions
		local was = orb_nodes[pointed_orb]
		if was and orb_base_scale[pointed_orb] then
			was.scale = orb_base_scale[pointed_orb]
		end
		local now = orb_nodes[best]
		if now then
			if not orb_base_scale[best] then
				local sc = now.scale
				orb_base_scale[best] = magic.Vector3(sc.x, sc.y, sc.z)
			end
			local b = orb_base_scale[best]
			now.scale = magic.Vector3(b.x * ORB_STEP, b.y * ORB_STEP,
					b.z * ORB_STEP)
		end
		pointed_orb = best
		local o = ORBS[best]
		name_text.text = o and o.name:upper():gsub("(.)", "%1 "):gsub(" $", "")
				or ""
		desc_text.text = (o and o.description) or ""
		log:info("pointing at orb " .. best .. ": " ..
				(o and o.name or "?") ..
				(best_up and " (up its column)" or "") ..
				string.format(" [%.2f of its disc]", best_score))
	end
	if best > 0 then
		label_orb, label_lift = best, 1.5
	end
	label_place()
end
magic.SubscribeToEvent("Update", function(t, d) handle_orb_update(t, d) end)


-- simplified: the pointer is read where it is clicked, not followed.
-- `MouseMove` never fires for a pointer put somewhere by a command
-- sequence -- the UI polls the cursor instead, which is why hovering a
-- dialog's row works and this did not -- so an orb lights up when it is
-- clicked rather than when the mouse crosses it. Following the pointer
-- would poll Input:GetMousePosition each frame, which the whitelist has
-- now.

-- **A click on an orb launches it**, which is what Enter does to the
-- one being pointed at: the room's own menu, answering the mouse the
-- way its dialogs do.
function handle_orb_click(event_type, event_data)
	if held_was or held_by_others() then return end
	if terminal_open or pause_open or prompt_open then
		return
	end
	if event_data:GetInt("Button") ~= magic.MOUSEB_LEFT then return end
	-- The Menu button's click is its own, not an orb's under it
	local x, y = event_data:GetInt("X"), event_data:GetInt("Y")
	local mb = room_menu_button
	if mb.visible then
		local p = mb.screenPosition
		if x >= p.x and x < p.x + mb.width and
				y >= p.y and y < p.y + mb.height then
			return
		end
	end
	local w = math.max(1, magic.ui.root.width)
	local h = math.max(1, magic.ui.root.height)
	local b = orb_at(event_data:GetInt("X") / w, event_data:GetInt("Y") / h)
	if b > 0 then
		log:info("click: " .. (ORBS[b] and ORBS[b].name or "?"))
		launch(b)
	end
end
magic.SubscribeToEvent("UIMouseClick", "handle_orb_click")
apply_camera()



-- The room's bed. One source on one stream, topped up every frame; the
-- number of orbs alight is the number of drone voices, so what the room
-- hums is the list of games ([LAUNCH_WORLD]'s own reason for generating
-- the audio rather than looping a file).
log:info(synth.self_check(magic))
-- **The sound as an options round** (stage 3; see synth.lua's STYLES and
-- local/options_for_LOBBY_music/): BUILDAT_LAUNCH_SOUND=<name>, and
-- "m116_broken", the user's pick of 2026-10-04, without it. Only "today"
-- keeps the orbs' voices, which section 13 cuts.
sound_style = synth.STYLES[env("BUILDAT_LAUNCH_SOUND")] and
		env("BUILDAT_LAUNCH_SOUND") or "m116_broken"
log:info("sound: " .. sound_style)
local bed = synth.new(magic, log, sound_style)
bed:set_voices(#orb_nodes)
bed:play(scene:CreateChild("sound"))
kept.bed = bed
-- **Every orb is a voice** ([ROOM_SOUND], the user's design: the
-- planet's core routed into this space and the orbs leaking energy).
-- The bed above is the core -- it does not pan, so the room never goes
-- quiet when the player faces away -- and these are the leaks.
--
-- **Six sources, not twenty**: the nearest orbs get a voice and the
-- rest fold into the bed, which is the cull the design asks for. Each
-- voice plays the *same* loop at its own playback rate, so a room of
-- pitches costs one loop of Lua.
-- One table, not eight locals: a Lua chunk may have two hundred and
-- this room's main function is near it
local drone = {VOICES = sound_style == "today" and 6 or 0, LOW = 40.0,
	HIGH = 160.0, t = 0, voices = {},
	}
-- What the save said, if it said anything
if saved_sound then
	levels.orbs = saved_sound[1] or levels.orbs
	levels.bed = saved_sound[2] or levels.bed
end
if kept.bed and kept.bed.source then
	kept.bed.source.gain = level_gain(levels.bed)
end
log:info(string.format("sound: the orbs at %d dB, the bed at %d dB",
		levels.orbs, levels.bed))
-- A pentatonic-ish stack: root, fifth, octave first, the rest sparser.
-- Vast rather than busy, which is what the design asks for.
drone.SCALE = {0, 7, 12, 19, 24, 3, 10, 15}
-- **Two loops, dark and bright, and pointing crossfades between them**
-- ([ROOM_SOUND]: raise the filter by crossfading rather than filtering
-- live). Both are the same two saws through the same one pole -- the
-- bright one's filter is simply slacker -- so they are the same note
-- and the fade is a change of colour rather than of pitch. Two sources
-- a voice, one node: they are the same place in the room.
drone.loop = synth.drone_loop(magic, 0.6, false)
drone.bright = synth.drone_loop(magic, 0.6, true)
for i = 1, drone.VOICES do
	local node = scene:CreateChild("orb_voice")
	local v = {node = node, orb = 0, phase = i * 1.7, gain = 0, lit = 0}
	local function source_for(loop)
		local voice = synth.drone_voice(magic, loop)
		local src = node:CreateComponent("SoundSource3D")
		src.nearDistance = 3 * U
		src.farDistance = 46 * U
		src.rolloffFactor = 1.1
		src.gain = 0
		src:Play(voice.stream)
		voice.source = src
		return voice
	end
	v.dark = source_for(drone.loop)
	v.lit_voice = source_for(drone.bright)
	drone.voices[i] = v
end
-- **And whether any of it reaches the mixer** ([NO_SOUND]): a stream
-- that is not playing, an audio subsystem that never opened and a
-- missing listener are all silent and none of them is an error, so the
-- three facts go in the log where a check and a person can both read
-- them.
log:info(("the room hums: %d voices of %d orbs, %.1f to %.1f Hz, " ..
		"dark and bright loops, a bed under them; audio %s, listener %s, "
		.. "first voice playing %s"):format(drone.VOICES,
		#orb_places, drone.LOW, drone.HIGH,
		magic.audio and (magic.audio.playing and "playing" or "silent")
				or "missing",
		(magic.audio and magic.audio.listener) and "placed" or "none",
		tostring(drone.voices[1] and drone.voices[1].dark.source.playing)))

-- **A pitch is a hash of the orb's name**, not its index, so an orb
-- sounds the same every boot and moving things about does not retune
-- the room -- the rule the marks already follow.
function drone.hz(i)
	local o = ORBS[i]
	local name = (o and o.name) or tostring(i)
	local h = 0
	for c = 1, #name do
		h = (h * 31 + name:byte(c)) % 65536
	end
	local step = drone.SCALE[h % #drone.SCALE + 1]
	local octave = math.floor(h / 97) % 3
	local hz = drone.LOW * math.pow(2, (step + octave * 12) / 12)
	while hz > drone.HIGH do hz = hz / 2 end
	return hz
end

function handle_synth_update(event_type, event_data)
	-- **The room hums on through a launch** ([LAUNCH_WORLD],
	-- 2026-09-24): the input goes when the launch commits, but the
	-- room is still what the player is looking at until the game draws,
	-- and a wait that goes silent at its first moment feels switched
	-- off rather than continuous. So the sound follows *in_app*, not
	-- the input gate -- and when the room does go, the drone **fades**.
	local dt = event_data:GetFloat("TimeStep")
	local want_sound = (in_app or launching or console_open or backdrop)
			and 0 or 1
	sound_fade = sound_fade + (want_sound - sound_fade) *
			(1 - math.exp(-dt / 0.35))
	if want_sound == 0 and sound_fade < 0.01 then
		for _, v in ipairs(drone.voices) do
			v.dark.source.gain = 0
			v.lit_voice.source.gain = 0
		end
		kept.bed.source.gain = 0
		return
	end
	bed:update()
	kept.bed.source.gain = level_gain(levels.bed) * sound_fade
	drone.t = drone.t + dt
	-- **What the player is doing, as one number** ([ROOM_SOUND]): at
	-- rest it is barely there, an orb under the crosshair brings it up,
	-- the desk further, and connecting to a server furthest -- the one
	-- state with a duration and no certainty, where a beat underneath
	-- makes waiting feel like something happening.
	-- Nought at rest: an empty room is quiet ([ROOM_SOUND], 2026-09-24)
	local want = 0
	if pointed_orb and pointed_orb > 0 then want = 0.25 end
	if terminal_open then want = 0.5 end
	if connecting then want = 0.8 end
	bed:set_engagement(want)
	-- The nearest orbs take the voices. Picked every quarter second
	-- rather than every frame: a list of sixty distances is cheap but
	-- not free, and a voice that changes orb mid-note is a click.
	if drone.t > 0.25 then
		drone.t = 0
		local near = {}
		for i = 1, #orb_places do
			local node = orb_nodes[i]
			if node then
				local p = node.position
				local dx = p.x - view_from.x
				local dy = p.y - view_from.y
				local dz = p.z - view_from.z
				near[#near + 1] = {i = i, d = dx * dx + dy * dy + dz * dz}
			end
		end
		table.sort(near, function(a, b) return a.d < b.d end)
		for k = 1, drone.VOICES do
			local v = drone.voices[k]
			local pick = near[k] and near[k].i or 0
			if pick ~= v.orb then
				v.orb = pick
				if pick > 0 then
					v.node.position = orb_nodes[pick].position
					-- The playback rate *is* the pitch: both loops were
					-- made at synth.DRONE_HZ
					local f = 22050 * (drone.hz(pick) / synth.DRONE_HZ)
					v.dark.source.frequency = f
					v.lit_voice.source.frequency = f
				end
			end
		end
	end
	for k = 1, drone.VOICES do
		local v = drone.voices[k]
		if v.orb > 0 then
			v.dark:feed()
			v.lit_voice:feed()
			-- A slow breath each, at its own rate, so the room is never
			-- quite still while the player is
			local lfo = 0.82 + 0.18 * math.sin(drone.t * 0.7 + v.phase +
					k * 1.3)
			-- **Pointing raises that orb and ducks the others**, and the
			-- desk ducks them all. The lift is a crossfade to the
			-- brighter loop as well as a gain, which is what the design
			-- asks for: a change of colour rather than of loudness.
			local g = 0.30
			local want_lit = 0
			if pointed_orb == v.orb then
				g, want_lit = 0.52, 1
			elseif pointed_orb and pointed_orb > 0 then
				g = 0.20
			end
			if terminal_open then g = g * 0.35 end
			-- **The duck is ramped, not switched** ([ROOM_SOUND]: about
			-- 150 ms, or it clicks). One pole per frame, which is the
			-- same ramp whatever the frame rate is doing, and the
			-- crossfade rides the same ramp.
			local k = 1 - math.exp(-dt / 0.15)
			v.gain = v.gain + (g - v.gain) * k
			v.lit = v.lit + (want_lit - v.lit) * k
			v.dark.source.gain = v.gain * lfo * (1 - v.lit) *
					level_gain(levels.orbs) * sound_fade
			v.lit_voice.source.gain = v.gain * lfo * v.lit *
					level_gain(levels.orbs) * sound_fade
		else
			v.dark.source.gain = 0
			v.lit_voice.source.gain = 0
		end
	end
end
magic.SubscribeToEvent("Update", function(t, d) handle_synth_update(t, d) end)

-- **The dissolve**: a bay un-builds into flying slabs, and it is the
-- only transition there is. The voxels stop being there -- the server is
-- told, and puts them back from the room's own description when the bay
-- shuts -- and what flies is a cube per voxel that was on the bay's
-- face, made here and thrown away when it lands.
--
-- States are configurations of one scene, not screens with a camera
-- parked in each, so a bay is a number in 0..1 and every cube's place is
-- read off it: reversible, interruptible, no keyframes. Where a cube
-- goes is decided once from its own index, since a wall that scatters
-- differently each time reads as noise rather than as a mechanism.
--
-- simplified: only the bay's front plane flies, which is 378 cubes at
-- the widest instead of fifteen hundred, and is the face anyone is
-- looking at. The upgrade is the whole depth, and a budget.
local DISSOLVE_SECONDS = 0.9
local bay_state = {}
for b = 1, BAYS do
	bay_state[b] = {t = 0, target = 0, slabs = {}}
end

-- The pocket's own box, which is what comes apart: the mouth stands
-- wherever the slabs around it put it, so the sweep goes from the deepest
-- a face can be to the furthest it can stand.
-- The pocket's box in room coordinates: the mouth and the wall around
-- it, from two voxels out in front of the face to two behind its back,
-- asked in the pocket's own wall's frame
local function bay_box(b)
	local p = room.pockets[b]
	local into = room.WALL_IN[p.wall]
	local x0, _, z0 = room.wall_xyz(p.wall, p.u0 - 2, 0,
			p.mouth - into * 2)
	local x1, _, z1 = room.wall_xyz(p.wall, p.u0 + p.su + 1, 0,
			p.mouth + into * (p.sd + 2))
	return math.min(x0, x1), math.max(x0, x1),
			p.y0 - 2, p.y0 + p.sy + 1,
			math.min(z0, z1), math.max(z0, z1)
end

local function dissolve_voxels(b, open)
	local x0, x1, y0, y1, z0, z1 = bay_box(b)
	rewrite_box(x0, x1, y0, y1, z0, z1, open)
end

local function build_flying(b)
	local st = bay_state[b]
	if #st.slabs > 0 then
		return
	end
	local p = room.pockets[b]
	local i = 0
	local into = room.WALL_IN[p.wall]
	-- The pocket's own mouth and the wall around it, which is what comes
	-- apart; the face stands wherever the slabs put it, so a column of
	-- voxels is walked into the wall until one is found -- "into" being
	-- the pocket's own wall's direction ([POCKETS_ROUND])
	for u = p.u0 - 2, p.u0 + p.su + 1 do
		for y = p.y0 - 2, p.y0 + p.sy + 1 do
			local v, vx, vz = nil, nil, nil
			for k = -2, p.sd + 2 do
				local x, _, z = room.wall_xyz(p.wall, u, y,
						p.mouth + into * k)
				local id = room.voxel_at(x, y, z)
				if id ~= room.id.air then
					v, vx, vz = id, x, z
					break
				end
			end
			if v then
				i = i + 1
				local node = part("Box",
						magic.Vector3(vx * VOXEL_M, y * VOXEL_M,
						vz * VOXEL_M),
						magic.Vector3(VOXEL_M, VOXEL_M, VOXEL_M), stone)
				local pos = node.position
				local dir = ((i % 2 == 0) and 1 or -1)
				-- Away is along the wall and out of it, which is the
				-- same pair of directions whichever wall it is
				local du = dir * (2.0 + (i % 7) * 0.5) * U
				local dn = -into * (1.8 + (i % 3) * 0.7) * U
				local ax, az = pos.x + du, pos.z + dn
				if room.WALL_U[p.wall] ~= "x" then
					ax, az = pos.x + dn, pos.z + du
				end
				st.slabs[i] = {
					node = node,
					-- The numbers, not the Vector3: a position property
					-- hands back the node's own vector, so a home kept as
					-- that object follows the cube as it flies
					home = {x = pos.x, y = pos.y, z = pos.z},
					away = {x = ax,
							y = pos.y + (1.0 + (i % 5) * 0.4) * U,
							z = az},
					spin = {i * 11 % 40 - 20, i * 27 % 60 - 30,
							i * 17 % 50 - 25},
				}
			end
		end
	end
	log:info("dissolve: bay " .. b .. " has " .. i .. " cubes to fly")
end

local function drop_flying(b)
	local st = bay_state[b]
	for _, sl in ipairs(st.slabs) do
		sl.node:Remove()
	end
	st.slabs = {}
end

local function ease(t)
	-- Slow at both ends, which is what makes a heavy slab read as heavy
	return t * t * (3 - 2 * t)
end

function dissolve_bay(b, open)
	-- Only a pocket comes apart; a thing on the floor has no wall to
	-- take away from in front of it
	local st = bay_state[b]
	if not st or (st.target == (open and 1 or 0)) then
		return
	end
	if open then
		-- The cubes are made from the voxels that are there, and only
		-- then are the voxels taken away
		build_flying(b)
		dissolve_voxels(b, true)
	end
	st.target = open and 1 or 0
end

function handle_dissolve_update(event_type, event_data)
	-- **An animation stands down for a screen on top of the room and
	-- not for a launch** ([LAUNCH_FROZEN]): the launch is seconds of
	-- this room's own movement
	if screen_taken() then return end
	local dt = event_data:GetFloat("TimeStep")
	for b = 1, BAYS do
		local st = bay_state[b]
		if st.t ~= st.target then
			local step = dt / DISSOLVE_SECONDS
			if st.target > st.t then
				st.t = math.min(st.target, st.t + step)
			else
				st.t = math.max(st.target, st.t - step)
			end
			local e = ease(st.t)
			for _, sl in ipairs(st.slabs) do
				sl.node.position = magic.Vector3(
						sl.home.x + (sl.away.x - sl.home.x) * e,
						sl.home.y + (sl.away.y - sl.home.y) * e,
						sl.home.z + (sl.away.z - sl.home.z) * e)
				sl.node.rotation = magic.Quaternion(sl.spin[1] * e,
						sl.spin[2] * e, sl.spin[3] * e)
			end
			if st.t == 0 and st.target == 0 then
				-- Landed: the voxels come back and the cubes go
				dissolve_voxels(b, false)
				drop_flying(b)
				log:info("dissolve: bay " .. b .. " rebuilt")
			end
		end
	end
end
magic.SubscribeToEvent("Update", function(t, d) handle_dissolve_update(t, d) end)

-- **Nothing is ever static.** The era this room refers to treated a
-- still frame as a bug: idle rotation, breathing, drift. So the orbs
-- breathe on their own clocks and the loose chrome turns, slowly enough
-- that it reads as the room being alive rather than as animation.
--
-- **F7 freezes it**, which is what the checks use: every comparison
-- here is between two frames and a room that drifts has no two frames
-- alike. The freeze is the exception that proves the rule, and the
-- runner asserts the drift is there before turning it off.
still = false
idle_t = 0
local idle_bob = {}
for i, o in ipairs(orb_places) do
	idle_bob[i] = {node = orb_nodes[i], y = o.y, phase = i * 1.7}
end

-- **The attract mode**: left alone, the room shows itself off. The
-- camera leaves its standing place and drifts along the bays, and the
-- first key press brings it back -- which is the era's own habit and
-- costs a sine.
--
-- simplified: one path, a slow sweep across the room and back, rather
-- than a tour of the objects. A tour wants the objects to say where
-- they are, which they will when there is a launcher behind them.
-- Long enough that it never fires while the room is being used; a run
-- gets at it at once with `event room attract` rather than a short
-- timer, which would fire between the check's own keys and eat the next
-- one -- which is exactly what it did.
-- How long the sweep spends on one wall before turning to the next
local ATTRACT_WALL_S = tonumber(env("BUILDAT_LAUNCH_ATTRACT_WALL_S")) or 14
local ATTRACT_AFTER = tonumber(
		env("BUILDAT_LAUNCH_ATTRACT")) or 14
idle_quiet = 0
attracting = false

-- **Connecting is a wait, and the room says so** (the launcher plan's
-- step 6: it wants the connecting screen's own polling). The connect
-- runs on a worker -- a blocking one freezes the frame for as long as
-- it takes -- so this asks once a frame and the notice line says where
-- it got to. There is no screen to push: the room is the screen.
connecting = nil
function connect_to(name, address)
	if connecting then return end
	api.connect_start(address)
	connecting = {name = name, address = address, t = 0}
	notice("connecting to " .. name .. " ...")
	log:info("connect: " .. name .. " at " .. address)
end

local function connect_poll(dt)
	if not connecting then return end
	connecting.t = connecting.t + dt
	local status, err = api.connect_poll()
	if status == "ok" then
		log:info("connect: " .. connecting.name .. " ok after " ..
				string.format("%.1f s", connecting.t))
		notice("")
		connecting = nil
		entered_app()
	elseif status == "failed" then
		-- The room stays up and says what happened, rather than a
		-- dialog: a server that is not there is an ordinary thing
		log:warning("connect: " .. connecting.name .. " failed: " ..
				tostring(err))
		notice(connecting.name .. ": " .. (err or "could not connect"))
		connecting = nil
	end
end

function handle_idle_update(event_type, event_data)
	local dt_any = event_data:GetFloat("TimeStep")
	connect_poll(dt_any)
	if hint_left > 0 then
		hint_left = hint_left - dt_any
		if hint_left <= 0 then
			drop_hint()
		end
	end
	if notice_left > 0 then
		notice_left = notice_left - dt_any
		if notice_left <= 0 then
			notice_text.text = ""
			notice_left = 0
		end
	end
	-- The room stands down while a game, or a console, is over it
	-- ([MENU_CONTEXT], [LAUNCH_CONSOLE])
	if held_was or held_by_others() then return end
	if still then
		return
	end
	local dt = event_data:GetFloat("TimeStep")
	idle_quiet = idle_quiet + dt
	-- The room shows itself off when it is left alone
	if not attracting and not terminal_open and not pause_open and
			not cam.to_from and idle_quiet > ATTRACT_AFTER then
		attracting = true
		drop_hint()
		log:info("attract: the room is showing itself off")
	end
	if attracting then
		local a = idle_quiet - ATTRACT_AFTER
		-- **A sweep down the open corridor, not through the
		-- furniture** (2026-09-23: the old sweep went nine units either
		-- way and spent half its time inside the floor's spheres, which
		-- are lit from behind and read as black blobs filling the
		-- frame). The middle of the floor is left open by design --
		-- it is the corridor to the wall -- so the sweep stays in it
		-- and moves toward the wall and back instead, which is the
		-- view the room was composed for.
		-- **Over the wall's formation and down to the floor and back**
		-- ([LAUNCH_WORLD] section 12, one wall): four places, eased
		-- from each to the next, ATTRACT_WALL_S on each leg, slow
		local wall_z = HOME_AT.z
		local back = HOME_FROM.z - wall_z
		local span = math.max(1.0, math.abs(HOME_FROM.x - (orb_places[1]
				and orb_places[1].x or HOME_FROM.x)))
		local top = orb_places[1] and orb_places[1].y or HOME_AT.y
		local bottom = orb_places[BAYS] and orb_places[BAYS].y or HOME_AT.y
		local mid = launch_floor_middle()
		local keys = {
			{"over the wall", {x = HOME_AT.x + span * 0.5, y = top,
				z = wall_z + back * 0.55}, {x = HOME_AT.x + span * 0.5,
				y = top, z = wall_z}},
			{"along the rows", {x = HOME_AT.x - span * 0.5, y = bottom,
				z = wall_z + back * 0.55}, {x = HOME_AT.x - span * 0.5,
				y = bottom, z = wall_z}},
			{"down to the floor", {x = mid.x, y = 4.5, z = mid.z + 6.0},
				{x = mid.x, y = 0.0, z = mid.z + 1.0}},
			{"back up", {x = HOME_FROM.x, y = HOME_FROM.y, z = HOME_FROM.z},
				{x = HOME_AT.x, y = HOME_AT.y, z = HOME_AT.z}},
		}
		local leg = a / ATTRACT_WALL_S
		local n = math.floor(leg) % #keys + 1
		local k0 = keys[(n - 2) % #keys + 1]
		local k1 = keys[n]
		local f = leg - math.floor(leg)
		f = f * f * (3 - 2 * f)
		if attract_shown ~= k1[1] then
			attract_shown = k1[1]
			log:info("attract: " .. k1[1])
		end
		for _, c in ipairs({"x", "y", "z"}) do
			cam.from[c] = k0[2][c] + (k1[2][c] - k0[2][c]) * f
			cam.at[c] = k0[3][c] + (k1[3][c] - k0[3][c]) * f
		end
		apply_camera()
	end
	idle_t = idle_t + dt
	for _, b in ipairs(idle_bob) do
		if b.node then
			local p = b.node.position
			b.node.position = magic.Vector3(p.x,
					(b.y + math.sin(idle_t * 0.7 + b.phase) * 0.09) * U, p.z)
		end
	end
	-- The loose chrome turns, each at its own rate: a sphere turning is
	-- only visible in what it reflects, which is exactly the point of
	-- putting a checkerboard under it
	for i, n in ipairs(prop_nodes) do
		n.rotation = magic.Quaternion(0, idle_t * (4 + i * 1.3) % 360, 0)
	end
end
magic.SubscribeToEvent("Update", function(t, d) handle_idle_update(t, d) end)



-- The palette preset: the first, or BUILDAT_LAUNCH_PRESET's (scaffold,
-- [LAUNCH_WORLD] section 11; stage 3 sets the light)
set_preset(math.max(1, math.min(#PRESETS,
		tonumber(env("BUILDAT_LAUNCH_PRESET")) or 1)))

-- **The keyboard path, untouched**: typing anywhere opens a one-line
-- prompt that fuzzy-matches a game or a server, Enter launches it, and
-- the camera flies to the matching object on the way out so the fast
-- path teaches the room. Digits pick slots. A returning user never
-- walks anywhere.
--
-- simplified: the prompt is a Text element and the keys are read
-- straight off KeyDown rather than through a LineEdit -- no style to
-- load, no focus to take and give back, and a room whose whole point is
-- how much it leaves out can spell twenty-six letters itself. The
-- upgrade is a LineEdit the moment anything needs a caret or paste.

local prompt_text = room_ui_child("Text")
prompt_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 26)
prompt_text.horizontalAlignment = magic.HA_CENTER
prompt_text.verticalAlignment = magic.VA_BOTTOM
prompt_text:SetPosition(0, -40)
prompt_text:SetColor(magic.Color(0.55, 0.95, 1.0, 1))
prompt_text.text = ""
prompt_open = false
prompt_str = ""
ornament_on = true
-- How long the opening hint has left, in seconds; zero once it is gone
hint_left = 0
-- And the same for a notice, which is not the hint: one is taken away
-- by the player moving, the other by having been read
notice_left = 0

-- **One line the room says things on**, above the prompt: connecting,
-- and why a connection did not happen. A dialog would take the mouse
-- and stop the room; this does not. simplified: the line stays until
-- something else is said -- there is no timeout, since the only things
-- said so far are a wait and its outcome.
-- A global, as `notice_left` beside it is: the frame handler that
-- clears the notice is defined further up this file and a local here
-- would be nil from there -- which it was, and the clearing raised
-- (2026-09-24)
notice_text = room_ui_child("Text")
notice_text:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 20)
notice_text.horizontalAlignment = magic.HA_CENTER
notice_text.verticalAlignment = magic.VA_BOTTOM
notice_text:SetPosition(0, -80)
notice_text:SetColor(magic.Color(1.0, 0.82, 0.45, 1))
notice_text.text = ""
-- **A notice says something and then stops saying it** (2026-09-23: a
-- "Connect failed" from minutes earlier was still on the screen while
-- the room showed itself off). Twelve seconds is long enough to read a
-- line and short enough that it is gone before the room is looked at
-- again; a wait says the same thing every frame it is still waiting.
local NOTICE_SECONDS = 12
function notice(text)
	-- **Something to say takes the hint's place**, and the hint is over
	-- when it does: the line is one line, so a notice over it ends the
	-- hint as surely as the first step does, and it is said once here
	-- rather than being lost between the two
	drop_hint()
	notice_text.text = text or ""
	notice_left = (text ~= nil and text ~= "") and NOTICE_SECONDS or 0
	hint_left = 0
end

-- **One line, gone at the first key** ([LAUNCH_WORLD] section 11). Not
-- a HUD: it is the notice line the room already has, it names Tab and
-- typing, and the first key takes it away -- so it is gone before it
-- can become furniture, and a player who already knows never reads it.
local HINT = "Tab  moves between the wall, the floor and the desk   -   " ..
		"type to search"
local HINT_SECONDS = 20
function show_hint()
	notice_text.text = HINT
	hint_left = HINT_SECONDS
	log:info("hint: Tab and typing, until the first key")
end
function drop_hint()
	if hint_left > 0 then
		-- The text only if it is still the hint's: a notice calls this
		-- on its way to writing its own line
		if notice_text.text == HINT then
			notice_text.text = ""
		end
		log:info("hint: taken away")
	end
	hint_left = 0
end

-- A subsequence match, which is what "fuzzy" has to mean when the list
-- is six names: every letter typed appears in order. The best match is
-- the one whose letters sit closest to the front.
local function fuzzy(query, name)
	local q, n = query:lower(), name:lower()
	local at, score = 1, 0
	for i = 1, #q do
		local found = n:find(q:sub(i, i), at, true)
		if not found then
			return nil
		end
		score = score + found
		at = found + 1
	end
	return score
end

-- **Browsing the room with the arrows** (user, 2026-09-23): with the
-- prompt empty they walk the world in the pockets' own grid directions
-- rather than a flattened list, because the spatial layout is the thing
-- being browsed and a player who learnt where something is by looking
-- should reach it by pressing toward it.
--
-- The grid is read off the things themselves: a row is everything at
-- much the same depth, rows ordered from the wall forward, and within a
-- row they go left to right. So it is the room's own layout and not a
-- second description of it.
local browse_rows = {}
do
	-- **The wall's rows are the formation's** ([LAUNCH_WORLD] stage 2,
	-- section 11: the arrows browse the room's own grid): top to bottom,
	-- each left to right, then the floor's ranks below the last of them,
	-- nearest the wall first.
	local by_row = {}
	for i = 1, BAYS do
		local p = room.pockets[i]
		if orb_places[i] and p then
			by_row[p.row] = by_row[p.row] or {}
			table.insert(by_row[p.row], {i = i, u = p.u0})
		end
	end
	for r = 1, room.rows or 0 do
		local e = by_row[r]
		if e then
			-- Left to right on the screen, which is down x
			table.sort(e, function(a, b) return a.u > b.u end)
			local row = {}
			for _, x in ipairs(e) do row[#row + 1] = x.i end
			browse_rows[#browse_rows + 1] = row
		end
	end

	local by_z = {}
	for i = BAYS + 1, #orb_places do
		local o = orb_places[i]
		if o and orb_nodes[i] then
			local key = math.floor(o.z + 0.5)
			by_z[key] = by_z[key] or {}
			table.insert(by_z[key], {i = i, x = o.x})
		end
	end
	local keys = {}
	for k in pairs(by_z) do keys[#keys + 1] = k end
	table.sort(keys)
	for _, k in ipairs(keys) do
		local r = by_z[k]
		table.sort(r, function(a, b) return a.x < b.x end)
		local out = {}
		for _, e in ipairs(r) do out[#out + 1] = e.i end
		browse_rows[#browse_rows + 1] = out
	end
end
browsed = 0
local browse_row, browse_col = 1, 1

function browse_show()
	local row = browse_rows[browse_row]
	if not row then return end
	browse_col = math.max(1, math.min(#row, browse_col))
	browsed = row[browse_col]
	local o = ORBS[browsed]
	name_text.text = o and o.name:upper():gsub("(.)", "%1 "):gsub(" $", "")
			or ""
	label_orb, label_lift = browsed, 2.6
	label_place()
	-- **The camera goes where the browsing is**: down off the wall's
	-- last row is the floor's station, and back up is the wall's
	local on_wall = browsed >= 1 and browsed <= BAYS
	if on_wall and station == "floor" then
		go_station("wall")
	elseif not on_wall and station == "wall" then
		go_station("floor")
	end
	log:info("browse: row " .. browse_row .. " of " .. #browse_rows ..
			", " .. (o and o.name or "?"))
end

-- Returns true when the key was the browser's
function browse_key(key)
	if prompt_open or terminal_open or pause_open then
		return false
	end
	local row = browse_rows[browse_row]
	if key == magic.KEY_LEFT then
		browse_col = browse_col - 1
		if browse_col < 1 then browse_col = #row end
	elseif key == magic.KEY_RIGHT then
		browse_col = browse_col + 1
		if browse_col > #row then browse_col = 1 end
	elseif key == magic.KEY_UP then
		browse_row = browse_row > 1 and browse_row - 1 or #browse_rows
	elseif key == magic.KEY_DOWN then
		browse_row = browse_row < #browse_rows and browse_row + 1 or 1
	else
		return false
	end
	browse_show()
	return true
end

-- What the prompt can find: the orbs, and the terminal, which is the
-- one thing in the room that is not one
local function best_match(query)
	local best, best_score = nil, nil
	local term = fuzzy(query, "settings terminal contentdb")
	if term then
		best, best_score = "terminal", term
	end
	for i, o in ipairs(ORBS) do
		local sc = fuzzy(query, o.search or o.name)
		if sc and (best_score == nil or sc < best_score) then
			best, best_score = i, sc
		end
	end
	return best
end

local function match_name(b)
	if b == "terminal" then return "settings / ContentDB" end
	if type(b) == "string" then
		local game, name = b:match("^save:(.-)/(.+)$")
		if name then
			return name .. "  (" .. game .. ", not on the floor)"
		end
	end
	local o = b and ORBS[b]
	if not o then return nil end
	-- A save says whose it is: two games may both have a "world"
	return o.save and (o.name .. "  (" .. o.app .. ")") or o.name
end

-- **The terminal**: settings and the ContentDB listing are a thing you
-- walk to and sit at, and what is drawn on it is an ordinary
-- information-dense widget at full readable density. The rule that
-- keeps the whole room from being a circus (the brief): **physical to
-- find, flat to read, never a 3D prop pretending to be a scrollbar.**
--
-- So the console is geometry -- a plinth, an angled screen, a keyboard
-- ledge -- and the moment the camera is square-on to it the panel that
-- appears is flat UI with rows of text in it.
-- **In the middle of the torus** (user, 2026-09-23: the torus was
-- unplanned, but the terminal could sit in it). The ring was one of the
-- reference frame's leftover primitives standing on the floor with
-- nothing to do; a chrome ring around the desk gives it a job and gives
-- the desk the thing that makes it findable from across the room. The
-- desk keeps its own corner rather than taking the ring's place in the
-- middle: a seven-metre ring in the corridor to the wall stands in
-- front of the lights the room is lit by, which the check read as the
-- room going still and dark (drift 5.6 to 0.9 of a level).
-- **At the junction of the wall and the floor** ([LAUNCH_WORLD] stage 2,
-- section 10): at the foot of the wall, to the right of the formation
-- where nothing stands in front of a pocket, and the ring brought in to
-- what fits between the desk and the stone.
local TERMINAL = {
	-- The screen's right is -x
	x = math.max((room.form.x0 - 1) * VOXEL_M - 3.0,
			room.X_MIN * VOXEL_M + 2.6),
	y = 0.0, z = BAY_Z * VOXEL_M + 2.6}
do
	local t = TERMINAL
	-- The desk stands inside the ring, and the ring clear of the wall
	part("Torus", magic.Vector3(t.x, t.y + 0.40, t.z),
			magic.Vector3(4.6, 4.6, 4.6), chrome)
	part("Box", magic.Vector3(t.x, t.y + 0.45, t.z),
			magic.Vector3(3.0, 0.9, 1.7), stone)
	part("Box", magic.Vector3(t.x, t.y + 0.95, t.z + 0.55),
			magic.Vector3(2.6, 0.12, 0.7), machined)
	-- The screen: dark glass in a housing, which is what it is when
	-- nobody is sitting at it
	part("Box", magic.Vector3(t.x, t.y + 1.75, t.z - 0.42),
			magic.Vector3(2.8, 1.7, 0.22), machined)
	part("Box", magic.Vector3(t.x, t.y + 1.75, t.z - 0.30),
			magic.Vector3(2.5, 1.45, 0.06),
			glow(magic.Color(0.03, 0.10, 0.13, 1)))
end

-- The flat half. Hidden until the camera is at the desk; nothing here
-- pretends to be an object.
local panel = room_ui_child("BorderImage")
panel.visible = false
panel.priority = 50
panel.horizontalAlignment = magic.HA_CENTER
panel.verticalAlignment = magic.VA_CENTER
panel.color = magic.Color(0.02, 0.05, 0.07, 0.94)
-- A flat white texel to tint: an image element with no texture draws
-- nothing at all
panel.texture = checker_texture(2, 1, magic.Color(1, 1, 1, 1),
		magic.Color(1, 1, 1, 1))
panel.imageRect = magic.IntRect(0, 0, 2, 2)
-- **After the texture**: an image element takes its texture's size when
-- one is set, so a size asked for first is thrown away and the panel
-- comes out two pixels across
panel.size = magic.IntVector2(760, 420)

-- Forward: the rows redraw themselves when the mouse picks one, and a
-- click changes the setting the row stands for
local draw_panel, setting_change, settings, sel
-- **The desk's rows answer the mouse too** (the rule: every menu this
-- room draws). A row that stands for a setting is a `Button` under its
-- text -- hovering selects it and a click changes it, which is what
-- left and right do from the keyboard -- and a row that is only a
-- heading stays a `Text`, since there is nothing to point at.
local function panel_row(y, left, right, colour, which)
	local holder = panel
	local b
	if which then
		b = panel:CreateChild("Button")
		b:SetPosition(18, y - 4)
		b:SetFixedSize(724, 24)
		-- **One white texel, made once**: a texture per row per redraw
		-- is an upload per frame the panel changes, and the first one
		-- after a device reset -- which changing multisampling is --
		-- fails outright (2026-09-23)
		b.texture = white_texture()
		b.imageRect = magic.IntRect(0, 0, 2, 2)
		b.color = magic.Color(0.05, 0.11, 0.14, 1)
		b.enabled = true
		holder = b
		magic.SubscribeToEvent(b, "HoverBegin", function()
			if terminal_open then
				sel = which
				draw_panel()
			end
		end)
		magic.SubscribeToEvent(b, "Released", function()
			if terminal_open then
				sel = which
				setting_change(settings[which], 1)
				draw_panel()
			end
		end)
	end
	local t = holder:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 17)
	t:SetPosition(which and 8 or 26, which and 3 or y)
	t:SetColor(colour or magic.Color(0.62, 0.86, 0.95, 1))
	t.text = string.format("%-26s %s", left, right)
	return b or t
end

local panel_rows = {}
-- **The terminal is where a setting is changed, not where it is shown**
-- ([LAUNCH_WORLD] step 9). The rows are the client's own preferences --
-- `api.list_preferences()`, whose values live in app::Options and
-- whose C++ side parses, range checks and persists them, so this is a
-- page of rows over two calls and knows nothing about the file -- plus
-- the room's own two toggles, which are the room's and not the client's.
--
-- simplified: one page. There are eight rows and the panel holds
-- seventeen; a room with more settings than that wants scrolling, and
-- this one does not have them.
local STEPS = {
	render_scale = {0.5, 2.0, 0.1, "%.2f"},
	max_fps = {0, 480, 10, "%d"},
	multisampling = {1, 16, 1, "%d"},
	-- Decibels below full on the settings' own 3 dB steps ([VOLUME_LAW]);
	-- -33 is off, which is the step under the quietest level
	sound_volume_db = {-33, 0, 3, "%d"},
}
settings = {}
for _, name in ipairs(api.list_preferences()) do
	settings[#settings + 1] = {pref = name}
end
-- The room's own, which no preference file knows about
settings[#settings + 1] = {room = "palette"}
settings[#settings + 1] = {room = "probe"}
settings[#settings + 1] = {room = "drone"}
settings[#settings + 1] = {room = "bed"}
settings[#settings + 1] = {room = "contentdb"}
-- **And the tools family, a row each** ([LAUNCH_WORLD] stage 1(b)). The
-- install action is not repeated here: it is the ContentDB row above,
-- which is what step 9 asked for by name.
for _, a in ipairs(TOOLS) do
	if a ~= install_action then
		settings[#settings + 1] = {tool = a}
	end
end
sel = 1

local db_text = require("buildat/extension/ui_utils")
db_text = (db_text.safe or db_text).db_text
local function setting_value(sg)
	if sg.tool then return "run it" end
	if sg.pref then
		local v = api.get_preference(sg.pref)
		if type(v) == "boolean" then return v and "on" or "off" end
		if sg.pref == "sound_volume_db" then
			return db_text(v)
		end
		local st = STEPS[sg.pref]
		-- A number is stepped; render_scale may be "auto", which is not
		return (st and type(v) == "number") and string.format(st[4], v) or
				tostring(v)
	end
	if sg.room == "palette" then return PRESETS[current].name end
	if sg.room == "probe" then return probe_on and "on" or "off" end
	if sg.room == "drone" then
		return db_text(levels.orbs)
	end
	if sg.room == "bed" then
		return db_text(levels.bed)
	end
	return "install a game"
end

local function setting_label(sg)
	if sg.tool then return sg.tool.name end
	if sg.pref then return sg.pref:gsub("_", " ") end
	if sg.room == "palette" then return "palette" end
	if sg.room == "probe" then return "reflection probe" end
	if sg.room == "drone" then return "the orbs' level" end
	if sg.room == "bed" then return "the bed's level" end
	return "contentdb"
end

-- Left and right change the selected row; a boolean flips and a number
-- steps within the range the C++ side would clamp it to anyway
setting_change = function(sg, dir)
	if sg.pref then
		local v = api.get_preference(sg.pref)
		if type(v) == "boolean" then
			local ok, err = api.set_preference(sg.pref, not v)
			if not ok then log:warning("setting: " .. tostring(err)) end
		else
			local st = STEPS[sg.pref]
			if not st then return end
			-- "auto" steps from the scale it stands for
			local nv = math.max(st[1], math.min(st[2],
					(tonumber(v) or 1.0) + dir * st[3]))
			local ok, err = api.set_preference(sg.pref, tostring(nv))
			if not ok then log:warning("setting: " .. tostring(err)) end
		end
		log:info("setting: " .. sg.pref .. " = " ..
				tostring(api.get_preference(sg.pref)))
		return
	end
	if sg.room == "palette" then
		set_preset((current - 1 + dir) % #PRESETS + 1)
	elseif sg.room == "drone" or sg.room == "bed" then
		-- 3 dB at a time on the settings' own steps, never above 0:
		-- there is no master limiter under these ([ROOM_SOUND]), and a
		-- step is a step wherever the tree shows a volume ([VOLUME_LAW])
		local key = sg.room == "drone" and "orbs" or "bed"
		levels[key] = math.max(-33, math.min(0, levels[key] + dir * 3))
		if sg.room == "bed" and kept.bed and kept.bed.source then
			kept.bed.source.gain = level_gain(levels.bed)
		end
		save_dirty = true
		log:info(string.format("setting: %s level = %d dB", sg.room,
				levels[key]))
	elseif sg.room == "probe" then
		probe_on = not probe_on
		zone.zoneTexture = probe_on and kept.probe or kept.dark_probe
		log:info("reflection probe " .. (probe_on and "on" or "off"))
	end
end

panel.enabled = true
-- Forward-declared above, where the rows learned to be hovered
draw_panel = function()
	for _, t in ipairs(panel_rows) do
		t:Remove()
	end
	panel_rows = {}
	local y = 18
	local function row(l, r, c, which)
		panel_rows[#panel_rows + 1] = panel_row(y, l, r, c, which)
		y = y + 24
	end
	row("SETTINGS", "up/down, left/right to change", magic.Color(1, 1, 1, 1))
	for i, sg in ipairs(settings) do
		local mark = (i == sel) and "> " or "  "
		row(mark .. setting_label(sg), setting_value(sg),
				(i == sel) and magic.Color(1.0, 0.72, 0.45, 1) or nil, i)
	end
	y = y + 14
	row("", "the room holds " .. #ORBS .. " things; Escape leaves the desk",
			magic.Color(0.45, 0.6, 0.66, 1))
end

-- Returns true when the key was the terminal's
function terminal_key(key)
	if not terminal_open then return false end
	if key == magic.KEY_UP then
		sel = sel > 1 and sel - 1 or #settings
	elseif key == magic.KEY_DOWN then
		sel = sel < #settings and sel + 1 or 1
	elseif key == magic.KEY_LEFT then
		setting_change(settings[sel], -1)
	elseif key == magic.KEY_RIGHT then
		setting_change(settings[sel], 1)
	elseif key == magic.KEY_RETURN then
		if settings[sel].tool then
			local a = settings[sel].tool
			log:info("tools: running " .. tostring(a.name))
			api.launch(a.key)
		end
		if settings[sel].room == "contentdb" then
			-- **A game found, installed and launched without touching
			-- another screen** is what step 9 asks for; what the tree
			-- has today is builtin/luanti's own import action, and
			-- there is no extensions/contentdb to enter. So this runs
			-- the install action the launch grid offered, and says so
			-- when the tree offers none.
			local a = install_action
			if a then
				log:info("contentdb: running " .. a.name)
				api.launch(a.key)
			else
				log:warning("contentdb: the tree offers no install action")
			end
		end
		return true
	else
		return true    -- the desk eats everything while you are sitting at it
	end
	draw_panel()
	return true
end

-- **The pause dialog, in both modes** (user, 2026-09-23): the room's
-- only way out of the program, and it needs one more than a game does --
-- a game has the launcher to go back to, and this *is* the launcher.
-- Two lines, chosen with up and down and taken with Enter.
--
-- simplified: it is the terminal's own panel machinery rather than a
-- styled dialog, because a style is a resource to load and a focus to
-- take and give back, and this has two rows.
local PAUSE_ITEMS = {
	{"Continue", nil},
	-- The settings are the desk's ([LAUNCH_WORLD] section 11): the dialog
	-- sends the camera there, which is a station like the others
	{"Settings", function() go_station("terminal") end},
	{"2D menu", function()
		-- **The slot, through its verb** ([LAUNCH_SANDBOX]): the choice
		-- is remembered as a preference and the other UI is booted now,
		-- so switching is one action from either side ([TWO_AUDIENCES])
		-- rather than a flag and a restart.
		close_room()
		local ok, why = api.set_launch_ui("launch_menu", {close = true})
		if not ok then
			log:warning("pause: " .. tostring(why))
			notice(tostring(why))
		end
	end},
	{"Developer console", function()
		-- **The console offers its screen and the room takes it**
		-- ([LAUNCH_CONSOLE]): the room's handlers stand down while it
		-- is up, the same standing down a game gets. The dialog has
		-- already closed itself by the time this runs.
		local c = require("buildat/extension/launch_console")
		c = c.show and c or c.safe
		if not c or not c.show then
			notice("the console extension is not here")
			return
		end
		console_open = true
		log:info("console: over the room")
		c.show(function()
			console_open = false
			mouse_for("launch_world: the console closed")
		end)
	end},
	{"Exit Buildat", function() api.disconnect() end},
}
local pause_panel = room_ui_child("BorderImage")
pause_panel.visible = false
pause_panel.priority = 60
pause_panel.horizontalAlignment = magic.HA_CENTER
pause_panel.verticalAlignment = magic.VA_CENTER
pause_panel.color = magic.Color(0.02, 0.05, 0.07, 0.96)
pause_panel.texture = checker_texture(2, 1, magic.Color(1, 1, 1, 1),
		magic.Color(1, 1, 1, 1))
pause_panel.imageRect = magic.IntRect(0, 0, 2, 2)
-- As tall as its rows, a row 48 apart from 14 down
pause_panel.size = magic.IntVector2(420, 14 + #PAUSE_ITEMS * 48 + 8)
-- **An element Urho3D has not been told is enabled is not hit by the
-- mouse, and neither is anything inside it** -- which is why the rows
-- below answered the keyboard only
pause_panel.enabled = true
-- **Every menu this room draws answers the mouse as well as the
-- keyboard** (user, 2026-09-23: a row could not be hovered or
-- clicked). A row is a `Button` rather than a `Text` -- a Text is not
-- hit-testable -- **without `SetStyleAuto()`**, which would paint
-- Urho3D's light default over a dark panel, so the row carries the
-- panel's own colours. **Hovering sets the selection**, so the two
-- ways drive one cursor rather than two, and the keyboard still works
-- with no mouse near it.
local pause_rows, pause_buttons = {}, {}
pause_sel = 1
-- Forward: both are defined with the dialog's keys, below the rows
local draw_pause, close_pause
local function pause_pick(i)
	pause_sel = i
	draw_pause()
end
for i = 1, #PAUSE_ITEMS do
	local b = pause_panel:CreateChild("Button")
	b:SetPosition(24, 14 + (i - 1) * 48)
	b:SetFixedSize(372, 40)
	b.texture = white_texture()
	b.imageRect = magic.IntRect(0, 0, 2, 2)
	b.color = magic.Color(0.05, 0.09, 0.12, 1)
	b.enabled = true
	local t = b:CreateChild("Text")
	t:SetFont(magic.cache:GetResource("Font", buildat.font_mono), 20)
	t:SetPosition(10, 8)
	pause_rows[i] = t
	pause_buttons[i] = b
	magic.SubscribeToEvent(b, "HoverBegin", function()
		if not pause_open then return end
		pause_pick(i)
		log:info("pause: hover on " .. PAUSE_ITEMS[i][1])
	end)
	magic.SubscribeToEvent(b, "Released", function()
		if not pause_open then return end
		pause_pick(i)
		local run = PAUSE_ITEMS[i][2]
		close_pause()
		if run then run() end
		log:info("pause: clicked " .. PAUSE_ITEMS[i][1])
	end)
end
pause_open = false
-- (declared above, where the rows learned to be clicked)
draw_pause = function()
	for i, item in ipairs(PAUSE_ITEMS) do
		pause_rows[i].text = (i == pause_sel and "> " or "  ") .. item[1]
		pause_rows[i]:SetColor(i == pause_sel and
				magic.Color(1.0, 0.72, 0.45, 1) or
				magic.Color(0.55, 0.62, 0.68, 1))
		if pause_buttons[i] then
			pause_buttons[i].color = i == pause_sel and
					magic.Color(0.12, 0.18, 0.22, 1) or
					magic.Color(0.05, 0.09, 0.12, 1)
		end
	end
end
local function open_pause()
	pause_open = true
	pause_sel = 1
	draw_pause()
	pause_panel.visible = true
	mouse_for("launch_world: paused")
	log:info("pause: open")
end
close_pause = function()
	if not pause_open then return false end
	pause_open = false
	pause_panel.visible = false
	log:info("pause: closed")
	return true
end
-- Returns true when the key was the dialog's
function pause_key(key)
	if not pause_open then return false end
	if key == magic.KEY_UP then
		pause_sel = pause_sel > 1 and pause_sel - 1 or #PAUSE_ITEMS
	elseif key == magic.KEY_DOWN then
		pause_sel = pause_sel < #PAUSE_ITEMS and pause_sel + 1 or 1
	elseif key == magic.KEY_ESCAPE then
		close_pause()
	elseif key == magic.KEY_RETURN then
		local run = PAUSE_ITEMS[pause_sel][2]
		close_pause()
		if run then run() end
		return true
	else
		return true    -- the dialog eats everything while it is up
	end
	draw_pause()
	return true
end

local function sit_at_terminal()
	terminal_open = true
	-- The desk's own answer, and the orbs duck under it ([ROOM_SOUND])
	if kept.bed and kept.bed.beep then kept.bed:beep() end
	draw_panel()
	panel.visible = true
	-- Square-on and close, which is what "the camera snaps flat onto it"
	-- has to mean for a screen to be readable
	fly_to({x = TERMINAL.x, y = TERMINAL.y + 1.75, z = TERMINAL.z + 2.6},
			{x = TERMINAL.x, y = TERMINAL.y + 1.75, z = TERMINAL.z - 0.3})
	-- **Sitting down ends the search.** The prompt kept its term while
	-- the desk was open, and up and down then walked the *matches*
	-- instead of the rows -- flying the camera away from the desk it
	-- had just sat at. It passed the check for as long as the term had
	-- one match and broke the moment the room held more things
	-- (2026-09-24: a fetched serverlist). A term is a way of getting
	-- somewhere; once you are there it is spent.
	prompt_str = ""
	prompt_open = false
	show_prompt()
	log:info("terminal: sat down")
end

local function leave_terminal()
	if not terminal_open then
		return false
	end
	terminal_open = false
	panel.visible = false
	log:info("terminal: stood up")
	return true
end

-- **The stations** ([LAUNCH_WORLD] sections 3 and 11): the camera stands
-- at one of three places and Tab cycles them -- the wall, near
-- horizontal; the floor, about -45 degrees over its ranks; and the desk,
-- square on. The numbers are stage 2's first picks, to be adjusted once
-- playtested.
-- simplified: the floor station is placed once, over the middle of the
-- floor's spheres as they stand at the first Tab; a room whose floor
-- changes under it keeps the old place until the next boot.
station = "wall"
floor_station = nil
STATIONS = {"wall", "floor", "terminal"}
function go_station(name)
	if name ~= "terminal" then
		leave_terminal()
	end
	if name == "wall" then
		fly_to(HOME_FROM, HOME_AT)
	elseif name == "floor" then
		if not floor_station then
			-- The middle of the floor's spheres, in metres as orb_places is
			local sx, sz, n = 0, 0, 0
			for i = BAYS + 1, #orb_places do
				local o = orb_places[i]
				if o and orb_nodes[i] then
					sx, sz, n = sx + o.x, sz + o.z, n + 1
				end
			end
			local cx = n > 0 and sx / n or HOME_FROM.x
			local cz = n > 0 and sz / n or HOME_FROM.z - 3.0
			-- Far enough to hold the ranks: the widest reach from the
			-- middle, in metres, decides it
			local spread = 0
			for i = BAYS + 1, #orb_places do
				local o = orb_places[i]
				if o and orb_nodes[i] then
					spread = math.max(spread, math.abs(o.x - cx),
							math.abs(o.z - cz))
				end
			end
			-- Back toward the standing place and up by as much: 45 degrees
			local h = math.max(4.0, spread * 0.8)
			floor_station = {from = {x = cx, y = h, z = cz + h},
				at = {x = cx, y = 0.0, z = cz}}
		end
		fly_to(floor_station.from, floor_station.at)
	elseif name == "terminal" then
		if not terminal_open then
			sit_at_terminal()
		end
	elseif name == "overview" then
		-- **For a scripted shot only** (`event room station overview`; not
		-- in Tab's cycle): the room's back corner under the ceiling,
		-- looking at the wall, so the room's size and the wall's relief
		-- are in one frame ([LAUNCH_WORLD] stage 3's architecture axes)
		fly_to({x = room.X_MAX * 0.85 * VOXEL_M, y = (room.Y_TOP - 2) * VOXEL_M,
				z = room.Z_MAX * 0.85 * VOXEL_M},
			{x = 0, y = room.Y_TOP * 0.35 * VOXEL_M, z = room.BAY_Z * VOXEL_M})
	else
		return
	end
	station = name
	log:info("station: " .. name)
end

-- **Every match, not the best one** (user, 2026-09-23: a term like
-- "test" matches many saves on this desk, and a search that names one
-- of them hides most of its answer). Sorted the way the prompt sorted
-- its single answer: the lower the fuzzy score, the earlier the
-- letters sit in the name.
local function matches_for(query)
	local out = {}
	local term = fuzzy(query, "settings terminal contentdb")
	if term then
		out[#out + 1] = {i = "terminal", score = term}
	end
	for i, o in ipairs(ORBS) do
		local sc = fuzzy(query, o.search or o.name)
		if sc then
			out[#out + 1] = {i = i, score = sc}
		end
	end
	-- The saves the floor has no room for: named like the terminal is,
	-- by a string rather than by an orb index, since there is no orb.
	--
	-- **Only from the start of the name**, and this is why: a
	-- subsequence match against two hundred saves fills the results
	-- with things that have no place in the room, and walking them with
	-- the arrows leaves the camera sitting still -- which is the one
	-- thing the search was fixed for ("until the camera follows, what
	-- is browsed is a word rather than a place"). Typing a save's name
	-- still finds it; typing three letters browses the room.
	local low = query:lower()
	for _, sv in ipairs(unshown_saves or {}) do
		if sv.name:lower():sub(1, #low) == low then
			out[#out + 1] = {i = "save:" .. sv.app .. "/" .. sv.name,
				score = #sv.name - #low}
		end
	end
	table.sort(out, function(a, b)
		if a.score ~= b.score then return a.score < b.score end
		return tostring(a.i) < tostring(b.i)
	end)
	return out
end

-- Which of them the prompt is on: the term's own results, walked with
-- up and down, and what Enter launches
match_list, match_at = {}, 1

-- **Which way is out of the wall an orb sits in** ([POCKETS_ROUND]): a
-- pocket on a side wall is looked at from the side, and one behind the
-- player from behind. A thing on the floor has no wall and is looked at
-- from +z, which is the way the room is entered.
-- Also **how far out the orb's own mouth is**: an orb in a pocket sits
-- inside the wall, so a camera told to stand two metres from it stands
-- inside the stone. A thing on the floor has no mouth to count from.
function orb_out(b)
	local p = type(b) == "number" and room.pockets[b] or nil
	if not p then return 0, 1, 0 end
	local depth = (p.sd - 1) / 2 * VOXEL_M
	if room.WALL_U[p.wall] == "x" then
		return 0, -room.WALL_IN[p.wall], depth
	end
	return -room.WALL_IN[p.wall], 0, depth
end

-- **The camera goes to what is browsed** (user): until it does, "what
-- is browsed" is a word rather than a place, and Enter launching it is
-- a leap of faith. A swift hop rather than a launch's flight.
local function show_match(i)
	local b = match_list[i] and match_list[i].i
	-- Nothing to fly to for the terminal or for a save with no orb
	if not b or type(b) == "string" then
		return
	end
	local o = orb_places[b]
	if not o then return end
	-- **From above and in front**, which is the one direction the room
	-- is not crowded in: at eye height the floor is full of spheres a
	-- metre and a half tall, and a launch's own framing -- seven metres
	-- straight back -- put the camera inside a server for a match on
	-- the floor (2026-09-23). Three metres up clears everything and
	-- still shows what the orb is standing among.
	-- **How far back the hop stops**, which is a portrait distance for
	-- the orb: three up and four and a half back reads as "this one,
	-- and here is where it lives". BUILDAT_LAUNCH_HOP moves it, which
	-- is how the mark's options sheet gets close enough to judge a
	-- picture on a sphere.
	local back = tonumber(env("BUILDAT_LAUNCH_HOP")) or 4.5
	local ox, oz, depth = orb_out(b)
	-- **The rise is what makes a hop read as a move** (the plan: three
	-- up and four and a half back is "this one, and here is where it
	-- lives"), and it is wrong for a portrait: close in, a camera that
	-- rises leaves the pocket's own corridor and ends up inside the
	-- slab beside it -- the mark sheet's fourth tile came back as a
	-- grey slab filling half the frame (2026-09-25, the pockets being
	-- packed in the middle of the wall by [POCKETS_ROUND]).
	-- BUILDAT_LAUNCH_HOP_FLAT is how a sheet asks for the straight-on
	-- one; the room keeps the view from above, which is also what
	-- clears the spheres standing around a floor orb.
	local flat = env("BUILDAT_LAUNCH_HOP_FLAT") ~= ""
	-- The mouth's own depth is counted in only for the portrait: the
	-- room's hop is measured from the orb, as it always was
	local out = flat and (back + depth) or back
	fly_to({x = o.x + ox * out, y = o.y + (flat and 0 or back * 0.67),
			z = o.z + oz * out},
			{x = o.x, y = o.y, z = o.z}, HOP_SECONDS)
end

function show_prompt()
	if prompt_str == "" then
		prompt_text.text = prompt_open and "type a name" or ""
		return
	end
	local b = match_list[match_at] and match_list[match_at].i
	local where = #match_list > 1 and
			("   [" .. match_at .. " of " .. #match_list .. "]") or ""
	prompt_text.text = "> " .. prompt_str ..
			(b and ("   -- " .. match_name(b) .. where) or "   -- no match")
end

-- The term changed: its results are new, and the camera goes to the
-- first of them
function prompt_changed()
	match_list = prompt_str ~= "" and matches_for(prompt_str) or {}
	match_at = 1
	show_prompt()
	if #match_list > 0 then
		show_match(1)
		-- How many of them are saves the floor has no room for: a
		-- launcher that cannot reach what the client has is worse than
		-- one that draws less of it, so this is the number that says
		-- the cap costs nothing
		local hidden = 0
		for _, m in ipairs(match_list) do
			if type(m.i) == "string" and m.i:sub(1, 5) == "save:" then
				hidden = hidden + 1
			end
		end
		log:info("prompt: \"" .. prompt_str .. "\" matches " ..
				#match_list .. " (" .. hidden .. " not on the floor)" ..
				", showing " .. tostring(match_name(match_list[1].i)))
	end
end

-- Up and down walk the results, each a hop of the camera; left and
-- right stay the cursor's, which is the decision already made
function prompt_walk(by)
	if #match_list < 2 then return false end
	match_at = match_at + by
	if match_at < 1 then match_at = #match_list end
	if match_at > #match_list then match_at = 1 end
	show_prompt()
	show_match(match_at)
	log:info("prompt: match " .. match_at .. " of " .. #match_list ..
			", " .. tostring(match_name(match_list[match_at].i)))
	return true
end

-- The floor's middle, in front of the formation, in metres
function launch_floor_middle()
	local wall_z = BAY_Z * VOXEL_M
	return {x = HOME_AT.x, y = 0, z = wall_z + (HOME_FROM.z - wall_z) * 0.45}
end

-- **The launch animation** ([LAUNCH_WORLD] section 0, user 2026-09-28):
-- played while the game is already loading, the camera following the orb
-- through all of it. The orb pulls out of its pocket, falls to three
-- voxels over the floor, moves to the floor's middle -- or into the save's
-- sphere, for a save -- and there its glow rises without bound until the
-- frame saturates, which is what the game's first frame replaces. It
-- holds while the game has a menu of its own up and goes on when that
-- goes or the game says it is loading (`app_loading`). Each phase is a
-- log line a drive waits on. Globals: the chunk is at its 200 locals.
LAUNCH_PHASES = {pull = 0.7, fall = 0.55, move = 1.1}
-- How far the glow gets before the game has said it is loading: lit
-- well up, the white not begun
LAUNCH_HOLD_T = 0.9
launch_anim = nil
launch_overlay = magic.ui.root:CreateChild("BorderImage")
launch_overlay.visible = false
launch_overlay.priority = 900
launch_overlay.texture = checker_texture(2, 1, magic.Color(1, 1, 1, 1),
		magic.Color(1, 1, 1, 1))
launch_overlay.imageRect = magic.IntRect(0, 0, 2, 2)
launch_overlay.color = magic.Color(1, 1, 1, 1)

local function anim_phase(a, name)
	a.phase, a.t = name, 0
	a.from = {x = a.p.x, y = a.p.y, z = a.p.z}
	log:info("launch: " .. name .. " (" .. a.name .. ")")
end

-- b: the wall orb that moves (nil for a save whose game is not on the
-- wall: then the save's own sphere glows where it stands); to: where it
-- comes to rest, in metres; name: what the log says
function launch_anim_start(b, to, name)
	local o = b and orb_places[b] or to
	local ox, oz, depth = 0, 1, 0
	if b then ox, oz, depth = orb_out(b) end
	local a = {b = b, name = name, to = to, ox = ox, oz = oz,
		home = {x = o.x, y = o.y, z = o.z},
		p = {x = o.x, y = o.y, z = o.z}, glow = 1, held = false,
		loading = false,
		radius = b and orb_across(ORBS[b]) * VOXEL_M / 2 or 0,
		-- Out of the mouth: the pocket's depth and a voxel and a half
		out = depth * 2 + 1.5 * VOXEL_M}
	a.base_bright = b and lights[b] and lights[b].brightness or 1
	a.vp = launch_viewports
	launch_anim = a
	-- **Muted at the click** (section 0): the feedback for the click,
	-- and a cleared palette for the game to take over
	sound_fade = 0
	cam.to_from, cam.to_at = nil, nil
	anim_phase(a, b and "pull" or "glow")
end

local function anim_camera(a)
	-- Behind the orb as seen from the room, a little above: the wall is
	-- behind it while it pulls out and falls, the floor under it after
	cam.from.x = a.p.x + a.ox * 4.5
	cam.from.y = a.p.y + 1.6
	cam.from.z = a.p.z + a.oz * 4.5
	cam.at.x, cam.at.y, cam.at.z = a.p.x, a.p.y, a.p.z
	apply_camera()
end

function handle_launch_anim(event_type, event_data)
	local a = launch_anim
	if not a then return end
	-- **Until the game's view replaces the room's**, and not until the
	-- room stands down: a game with a menu of its own has the room stand
	-- down after LAUNCH_WAIT_S with the room still on the screen behind
	-- the menu, and the animation goes on there. The white is the
	-- room's: the game's first frame is not drawn under it.
	local vp = magic.viewport_generation and magic.viewport_generation() or 0
	if vp ~= a.vp then
		launch_overlay.visible = false
		return
	end
	-- In the wall's time and not the engine's step: a world loading makes
	-- long frames, and a step clamped per frame left the glow short of
	-- the white when the game's view arrived (2026-10-03)
	local now = buildat.get_time_us()
	local dt = a.last_us and (now - a.last_us) / 1000000 or 0
	a.last_us = now
	a.t = a.t + math.min(dt, 0.5)
	-- **Held at a glow short of the white until the game says it is
	-- loading** (section 12: a game in a menu of its own pauses it).
	-- simplified: the room cannot see the game's menu -- the game's UI
	-- stack is its own sandbox's and the root's children come back as new
	-- wrappers every time -- so the hold is on the launch API's word
	-- (`launch_loading`, which vanilla says when a world is picked). A
	-- game that never says it holds there until its view replaces the
	-- room's, which is the end of the animation anyway.
	if a.phase == "glow" and not a.loading and a.t > LAUNCH_HOLD_T then
		a.t = LAUNCH_HOLD_T
		if not a.held then
			a.held = true
			log:info("launch: held until the game says it is loading")
		end
	elseif a.held and a.loading then
		a.held = false
		log:info("launch: going on")
	end
	local d = LAUNCH_PHASES[a.phase]
	local k = d and math.min(1, a.t / d) or 0
	local e = k * k * (3 - 2 * k)
	if a.phase == "pull" then
		a.p.x = a.from.x + a.ox * a.out * e
		a.p.z = a.from.z + a.oz * a.out * e
		if k >= 1 then anim_phase(a, "fall") end
	elseif a.phase == "fall" then
		-- Three voxels over the floor, by gravity's curve
		local y1 = 3 * VOXEL_M + a.radius
		a.p.y = a.from.y + (y1 - a.from.y) * k * k
		if k >= 1 then anim_phase(a, "move") end
	elseif a.phase == "move" then
		a.p.x = a.from.x + (a.to.x - a.from.x) * e
		a.p.z = a.from.z + (a.to.z - a.from.z) * e
		if k >= 1 then anim_phase(a, "glow") end
	elseif a.phase == "glow" then
		-- Without bound: the light and the orb's own emissive multiply
		-- up, and a white over the frame finishes what the exposure
		-- would -- the game's first frame is what replaces it
		a.glow = math.exp(a.t * 1.6)
		local w = math.max(0, math.min(1, (a.t - 1.2) / 1.6))
		launch_overlay.size = magic.IntVector2(magic.ui.root.width,
				magic.ui.root.height)
		launch_overlay.visible = w > 0
		launch_overlay.opacity = w
		if w >= 1 and not a.saturated then
			a.saturated = true
			log:info("launch: the frame is saturated (" .. a.name .. ")")
		end
	end
	if a.b then
		move_orb_to(a.b, a.p.x, a.p.y, a.p.z)
		if lights[a.b] then
			lights[a.b].brightness = (a.base_bright or 1) * a.glow
		end
		if orb_mats[a.b] and orb_bright[a.b] then
			local c = orb_bright[a.b]
			orb_mats[a.b]:SetShaderParameter("MatDiffColor",
					magic.Color(c.r * a.glow, c.g * a.glow, c.b * a.glow, 1))
		end
	end
	anim_camera(a)
end
magic.SubscribeToEvent("Update", function(t, d) handle_launch_anim(t, d) end)

-- Back in the room: the orb in its pocket, its light and colour as the
-- preset has them, the white gone
function launch_anim_reset()
	local a = launch_anim
	launch_anim = nil
	launch_overlay.visible = false
	if a and a.b then
		move_orb_to(a.b, a.home.x, a.home.y, a.home.z)
		set_preset(current)
	end
end

-- Launching, in this room, is the bay coming apart and the camera going
-- in: there is nothing behind it to run yet, and the transition is the
-- content.
-- Global: the FPS hold below is in a handler defined above this
function launch(b)
	if kept.bed then
		kept.bed:thunk()
	end
	if b == "terminal" then
		sit_at_terminal()
		return
	end
	if type(b) == "string" then
		-- A save the floor has no room for, found by the prompt: it
		-- opens by name like the ones standing on the floor do
		local game, name = b:match("^save:(.-)/(.+)$")
		if name then
			log:info("launch: save " .. name .. " of " .. game ..
					" (not on the floor)")
			local ok, why = api.launch_save(game, name)
			if ok then
				entered_app()
			else
				log:warning("launch: " .. tostring(why))
			end
		end
		return
	end
	if not b or not orb_places[b] then
		return
	end
	log:info("launch: " .. (ORBS[b] and ORBS[b].name or "?") ..
			" (bay " .. b .. ")")
	-- **And it launches.** The action came out of the launch grid, which
	-- is the one door a launcher file has; running it here is running it
	-- there. simplified: the camera flies in and the bay opens first,
	-- and nothing waits for either -- a launch that takes the client
	-- somewhere else takes it there mid-flight.
	if ORBS[b] and ORBS[b].key then
		local ok, why = api.launch(ORBS[b].key)
		if not ok then
			log:warning("launch: " .. tostring(why))
			notice(tostring(why))
		end
		-- **A run that started a game takes the room down with it.** Not
		-- every launch action is a game -- a launcher file can put
		-- anything on the grid -- so the room asks whether a server came
		-- up rather than assuming one did.
		if api.local_server_running() then
			entered_app()
			-- A wall orb plays the animation; the floor's actions do not
			-- (section 0 is the games')
			if b <= BAYS then
				launch_anim_start(b, launch_floor_middle(), ORBS[b].name)
			end
		end
	elseif ORBS[b] and ORBS[b].server then
		connect_to(ORBS[b].name, ORBS[b].address)
	elseif ORBS[b] and ORBS[b].save then
		-- **A save opens by name.** The launcher starts the save's own
		-- game with "save=<name>" through the server's -u, which is the
		-- same door "menu" and "luanti_game" come through; the game
		-- reads it and opens that save instead of drawing its menu.
		-- simplified: a game that reads no `save` key starts as it
		-- normally would, which is what vanilla did before it read one.
		local o = ORBS[b]
		log:info("launch: save " .. o.name .. " of " .. o.app)
		local ok, why = api.launch_save(o.app, o.name)
		if ok then
			entered_app()
			-- **The save's own game, brought to it** (section 0): the
			-- orb of the app the save belongs to pulls out and moves
			-- into the save's sphere; a save whose app has no orb on the
			-- wall glows where it stands
			local g = nil
			for i = 1, BAYS do
				local k = ORBS[i] and ORBS[i].key
				if k and k:sub(1, #("app/" .. o.app .. "/")) ==
						"app/" .. o.app .. "/" then
					g = i
					break
				end
			end
			local at = orb_places[b]
			launch_anim_start(g, {x = at.x, y = at.y, z = at.z}, o.name)
		else
			log:warning("launch: " .. tostring(why))
		end
	end
end

function prompt_key(key)
	-- **A digit inside an open query is a character**, not a shortcut:
	-- a server is named by its address where the client has no name for
	-- it, and "127.0.0.1" cannot be typed otherwise. The match is a
	-- subsequence, so the dots need no key of their own -- Urho3D's Lua
	-- has no KEY_PERIOD anyway. With the prompt closed they stay the
	-- shortcuts.
	if prompt_open then
		for n = 0, 9 do
			if key == magic["KEY_" .. n] then
				prompt_str = prompt_str .. tostring(n)
				prompt_changed()
				return true
			end
		end
	end
	-- Digits pick the nearest slots, which is the path a returning user
	-- actually takes. There are nine of them and the room may hold more
	-- than nine things; past that, typing the name is the way.
	for n = 1, math.min(BAYS, 9) do
		if key == magic["KEY_" .. n] then
			prompt_open = false
			prompt_str = ""
			show_prompt()
			launch(n)
			return true
		end
	end
	if key == magic.KEY_ESCAPE then
		-- Escape is handled once, for both modes, in handle_keydown
		return false
	end
	if key == magic.KEY_RETURN then
		if prompt_open then
			-- **What is browsed**, which is the match the arrows walked
			-- to and not the best one, now that the camera is on it
			local b = match_list[match_at] and match_list[match_at].i or
					best_match(prompt_str)
			prompt_open = false
			prompt_str = ""
			match_list, match_at = {}, 1
			show_prompt()
			launch(b)
			return true
		end
		return false
	end
	-- **Up and down walk the results** with text in the prompt, each one
	-- a hop of the camera; left and right stay the cursor's
	if prompt_open and prompt_str ~= "" then
		if key == magic.KEY_UP then
			return prompt_walk(-1)
		end
		if key == magic.KEY_DOWN then
			return prompt_walk(1)
		end
	end
	if key == magic.KEY_BACKSPACE and prompt_open then
		prompt_str = prompt_str:sub(1, #prompt_str - 1)
		prompt_changed()
		return true
	end
	-- Any letter opens the prompt and is its first character
	for i = 0, 25 do
		local ch = string.char(97 + i)
		if key == magic["KEY_" .. ch:upper()] then
			prompt_open = true
			prompt_str = prompt_str .. ch
			prompt_changed()
			return true
		end
	end
	if key == magic.KEY_SPACE and prompt_open then
		prompt_str = prompt_str .. " "
		prompt_changed()
		return true
	end
	return false
end

function handle_keydown(event_type, event_data)
	-- A backdrop takes no input ([TWO_AUDIENCES]' composition)
	if backdrop then return end
	local key = event_data:GetInt("Key")
	-- **The way out of a game is the game's own** ([NO_WAY_BACK], user
	-- 2026-09-24): every game leaves through `buildat.leave()`, which
	-- comes back here when there is a launcher under it. The room used
	-- to bind F10 to rescue players from games that dropped the client
	-- instead; the launcher should not have to rig anything up to make
	-- games behave, and `leave_app()` is still the door -- the client
	-- calls it through the launch interface.
	-- The room stands down while a game, or a console, is over it
	-- ([MENU_CONTEXT], [LAUNCH_CONSOLE])
	if held_was or held_by_others() then return end
	-- The first key takes the hint away, whatever it was
	drop_hint()
	-- **B pins what is pointed at** ([LAUNCH_WORLD] section 14: the
	-- player's only organising). A toggle, so the same key takes it
	-- back; written through at once rather than on a timer, a pin being
	-- a rare thing the player will expect to survive a crash.
	-- What is browsed: there is no crosshair to point with any more
	if key == magic.KEY_B and not prompt_open and browsed > 0 and
			ORBS[browsed] then
		local o = ORBS[browsed]
		if o.key then
			if bookmarks[o.key] then
				bookmarks[o.key] = nil
				for i, k in ipairs(bookmark_order) do
					if k == o.key then
						table.remove(bookmark_order, i)
						break
					end
				end
				notice(o.name .. " unpinned")
			else
				bookmarks[o.key] = true
				bookmark_order[#bookmark_order + 1] = o.key
				notice(o.name .. " pinned")
			end
			log:info("bookmarks: " .. #bookmark_order .. " pinned (" ..
					tostring(o.name) .. " " ..
					(bookmarks[o.key] and "in" or "out") .. ")")
			place_bookmarks()
			write_save()
		end
		return
	end
	idle_quiet = 0
	if attracting then
		attracting = false
		attract_aim, attract_shown = nil, nil
		fly_to(HOME_FROM, HOME_AT)
		log:info("attract: back to the standing place")
		return
	end
	-- The pause dialog is over everything while it is up
	if pause_key(key) then
		return
	end
	-- Then the desk, which eats the arrows and Enter while it is open;
	-- Escape below stands you up, and Tab goes on to the next station
	if key ~= magic.KEY_ESCAPE and key ~= magic.KEY_TAB and
			terminal_key(key) then
		return
	end
	-- **Escape closes what is open, and the pause dialog when nothing
	-- is** ([LAUNCH_WORLD] section 11): out of the desk, out of a bay,
	-- the prompt cleared -- and at the room's top level the dialog,
	-- which is the room's own way out of the program.
	if key == magic.KEY_ESCAPE then
		if terminal_open then
			go_station("wall")
			return
		end
		local backed = false
		for b = 1, BAYS do
			if bay_state[b] and bay_state[b].target ~= 0 then
				dissolve_bay(b, false)
				backed = true
			end
		end
		if backed then
			fly_to(HOME_FROM, HOME_AT)
		end
		-- **The prompt closes where it is**: the camera stays on what the
		-- search found, the thing browsed now, which a click or Enter can
		-- take (the formation has nothing at the standing place's middle
		-- for a camera flown home to point at)
		if prompt_open or prompt_str ~= "" then
			prompt_open = false
			prompt_str = ""
			show_prompt()
			return
		end
		if backed then
			return
		end
		open_pause()
		return
	end
	-- **Tab cycles the stations** ([LAUNCH_WORLD] section 11): the wall,
	-- the floor, the desk, and round again
	if key == magic.KEY_TAB then
		local next_i = 1
		for k, name in ipairs(STATIONS) do
			if name == (terminal_open and "terminal" or station) then
				next_i = k % #STATIONS + 1
			end
		end
		go_station(STATIONS[next_i])
		return
	end
	if browse_key(key) then
		-- The arrows browse while the prompt is empty; with text in it
		-- they are the prompt's own, which is what prompt_key does
		return
	elseif prompt_key(key) then
		return
	end
	-- **Enter launches, always** (user): the browsed thing when the
	-- prompt is empty, the match when it is not -- one key for "do the
	-- thing" and no rule to remember. prompt_key takes the second case.
	if key == magic.KEY_RETURN and browsed > 0 then
		launch(browsed)
		return
	end
	if key == magic.KEY_RETURN or key == magic.KEY_ESCAPE then
		if kept.bed then
			kept.bed:thunk()
		end
	end
end
magic.SubscribeToEvent("KeyDown", "handle_keydown")

-- **The proof's switches, off the F keys** ([LAUNCH_WORLD] section 11):
-- the F keys are the client's and behave as vanilla's, so the room's
-- own -- the probe, the ornament, the freeze, the attract mode and the
-- palette preset -- are knobs read at boot and `event room <what>` for a
-- scripted run, which is how a check shoots a frame with one on and off.
function room_switch(what, arg)
	if what == "probe" then
		-- The probe off the zone and back: a metal with nothing to
		-- reflect is black but for its highlight, and that difference is
		-- the whole of what the probe is for
		probe_on = not probe_on
		zone.zoneTexture = probe_on and kept.probe or kept.dark_probe
		log:info("reflection probe " .. (probe_on and "on" or "off"))
	elseif what == "ornament" then
		-- **The ornament is on the pockets' columns and nowhere else**,
		-- so stripping it is making those voxels plain stone and meshing
		-- the room again
		ornament_on = not ornament_on
		room.id.column = ornament_on and column_id or room.id.stone
		rebuild_room()
		log:info("ornament " .. (ornament_on and "on" or "off"))
	elseif what == "still" then
		still = not still
		log:info("idle drift " .. (still and "frozen" or "running"))
	elseif what == "attract" then
		attracting = true
		idle_quiet = ATTRACT_AFTER
		drop_hint()
		log:info("attract: the room is showing itself off")
	elseif what == "preset" then
		set_preset(tonumber(arg) or 1)
	elseif what == "station" then
		go_station(arg)
	elseif what == "dissolve" then
		-- **The dissolve, kept for stage 3** ([LAUNCH_WORLD] section 12:
		-- a possible effect on a pocket at a launch, undecided, and no
		-- transition of its own any more): a check opens and shuts a bay
		-- by this, the empty pocket's unless a number says which
		local b = tonumber(arg)
		if not b then
			for i = 1, BAYS do
				if ORBS[i] and ORBS[i].empty then b = i end
			end
		end
		local st = b and bay_state[b]
		if st then
			dissolve_bay(b, st.target == 0)
		end
	else
		log:warning("event room: \"" .. tostring(what) .. "\" is not a switch")
	end
end
function handle_seq_room(event_type, event_data)
	local what, arg = event_data:GetString("Param"):match("^(%S+)%s*(.*)$")
	room_switch(what, arg)
end
magic.SubscribeToEvent("command_seq:room", "handle_seq_room")

-- **What a scripted run says instead of guessing at Tab** ([CMD_EVENT]:
-- `event mode menu`). Tab is a toggle and Escape pops a level, so a
-- sequence of forty keys has to carry the room's mode in its head, and
-- a step that guesses wrong types into the other mode and its assertion
-- passes on whatever that did -- which is how the dissolve's check came
-- to be satisfied by the terminal opening (2026-09-23). This says it
-- outright. It is not a debug hook: the launcher's own state is what a
-- driven run drives.
function handle_seq_mode(event_type, event_data)
	local want = event_data:GetString("Param")
	if want ~= "menu" then
		log:warning("event mode: \"" .. tostring(want) .. "\" is not a mode")
		return
	end
	-- Everything over the room goes first, so the mode is the mode
	leave_terminal()
	close_pause()
	if prompt_open or prompt_str ~= "" then
		prompt_open = false
		prompt_str = ""
		show_prompt()
	end
	for b = 1, BAYS do
		if bay_state[b] and bay_state[b].target ~= 0 then
			dissolve_bay(b, false)
		end
	end
	station = "wall"
	fly_to(HOME_FROM, HOME_AT)
	log:info("event mode: " .. want .. ", at the standing place")
end
magic.SubscribeToEvent("command_seq:mode", "handle_seq_mode")

-- **Into a game and back out of it** ([MENU_CONTEXT], the launcher
-- plan's step 6). The room is never torn down: it keeps standing behind
-- the game, its handlers stand down, its own UI goes away, and the way
-- back is the client's `api.leave_to_menu()` plus a viewport.
--
-- **A fresh Viewport, not the one the room booted with**: handing the
-- old wrapper back to `set_preferred_viewports()` after the sandbox
-- reset segfaults, and the room's cloned render path has to go on the
-- new one or it draws black with HDR on.
in_app = false
-- **The launch has committed and the game is not on screen yet**: the
-- room gives up the input at once and keeps drawing and humming until
-- something else takes the view -- which is `set_preferred_viewports`,
-- so the count that call keeps is what says so -- or until the wait
-- runs out and a launch that never drew stops holding the room open.
launching = false
-- How much of the room's own sound is playing: one at rest, ramped to
-- nought when the room leaves the screen so the drone fades rather
-- than cuts ([LAUNCH_WORLD], 2026-09-24)
sound_fade = 1
launch_started_us = 0
launch_viewports = 0
-- **How long the room draws on without the game taking the view.**
-- A game that comes up into a world takes a viewport within a second
-- or two of its client Lua running, and the room goes then. A game
-- that draws **its own menu first** takes no viewport at all -- it is
-- UI over whatever is behind it -- so this ceiling is what stops the
-- room from humming behind that menu; twelve seconds is long enough
-- for a local server to start and short enough not to be a second
-- wait of its own.
LAUNCH_WAIT_S = 12
-- The developer console, drawn over the room by launch_console and
-- taken away again by its own Escape ([LAUNCH_CONSOLE] offers it)
console_open = false
-- **The room as somebody else's backdrop** ([TWO_AUDIENCES]' third
-- option: the menu stacked over the room in attract mode). It draws
-- and drifts and shows itself off; it takes no key, no mouse and no
-- mouse capture, because every one of those belongs to the screen in
-- front of it.
backdrop = false

function be_backdrop()
	backdrop = true
	-- Its own UI goes: a prompt, a crosshair and a preset label belong
	-- to a room somebody is using, not to a view behind a menu
	for _, e in ipairs(room_ui) do
		e.visible = false
	end
	attracting = true
	idle_quiet = ATTRACT_AFTER
	log:info("room: a backdrop for somebody else's screen")
end

-- **The launch committed**: the input goes, the room's own furniture
-- goes -- a prompt and a crosshair belong to a room somebody is using
-- -- and the room keeps drawing and sounding. What it is waiting for
-- is the game's own view.
function entered_app()
	if in_app or launching then return end
	launching = true
	launch_started_us = buildat.get_time_us()
	launch_viewports = magic.viewport_generation and
			magic.viewport_generation() or 0
	for _, e in ipairs(room_ui) do
		e.visible = false
	end
	attracting = false
	log:info("game: the launch has the input; the room keeps drawing")
end

-- The room is not on the screen any more: stop drawing it, and let the
-- drone fade rather than cut, the point being that the wait feels
-- continuous rather than switched off.
function stand_down(why)
	if in_app then return end
	in_app = true
	launching = false
	log:info("game: the room stands down (" .. why .. ")")
end

-- Asked once a frame while a launch is in flight; see LAUNCH_WAIT_S
function launch_watch()
	if not launching then return end
	local now = magic.viewport_generation and magic.viewport_generation() or 0
	if now ~= launch_viewports then
		stand_down("the game has the view")
		return
	end
	if buildat.get_time_us() - launch_started_us >
			LAUNCH_WAIT_S * 1000000 then
		stand_down("nothing drew in " .. LAUNCH_WAIT_S .. " s")
	end
end

function leave_app()
	-- **A launch that has not finished is still something to leave**
	-- ([LEAVE_POP], 2026-09-25): a menu launched from an orb -- ContentDB
	-- -- never takes the viewport, so the room stands down on
	-- LAUNCH_WAIT_S's timeout, and "back to the launcher" pressed before
	-- that found `in_app` false and did nothing. Which is also why it
	-- worked by luck: wait long enough and the same button works.
	local was = in_app or launching
	launching = false
	if not was then return false end
	-- **The screens under the game go with it** ([MENU_STUCK], user
	-- 2026-09-24): the launcher composed under the room pushes a
	-- placeholder when it starts a game and pops it in its own
	-- leave_app, which is not the one that runs when the room is the
	-- launcher -- so a game's menu, and the placeholder under it, stayed
	-- on the screen while the room took the input back. The room pushes
	-- nothing itself, so the stack is empty when the room owns the
	-- screen alone, and `screen_taken()` above is what reads that.
	-- **Before the client's leave**, which removes the elements under
	-- the stack's entries: popping after it reaches a UIElement that is
	-- already gone, and the sandbox raises on it.
	-- stack[1], not #stack: a sandboxed caller gets a read-only view,
	-- whose # is 0 on Lua 5.1 ([LUANTI_NO_WORLD])
	local st = room_stack and room_stack.main
	if st and st.stack[1] then
		st:pop_to(st.stack[1], true)
	end
	api.leave_to_menu()
	in_app = false
	local vp = magic.Viewport:new(scene,
			camera_node:GetComponent("Camera"))
	apply_room_path(vp)
	magic.set_preferred_viewports({vp})
	viewport = vp
	for _, e in ipairs(room_ui) do
		e.visible = true
	end
	panel.visible = false
	pause_panel.visible = false
	terminal_open = false
	pause_open = false
	-- The orb back in its pocket and the camera at the wall
	launch_anim_reset()
	cam.to_from, cam.to_at = nil, nil
	cam.from = {x = HOME_FROM.x, y = HOME_FROM.y, z = HOME_FROM.z}
	cam.at = {x = HOME_AT.x, y = HOME_AT.y, z = HOME_AT.z}
	apply_camera()
	station = "wall"
	-- The mouse the way the room takes it rather than the way the game
	-- left it
	mouse_for("launch_world: back in the room")
	log:info("game: back in the room")
	return true
end

magic.ui:SetFocusElement(nil)

-- **It starts at the wall, with the mouse free** ([LAUNCH_WORLD]
-- section 11): one mode, point-and-click with the keyboard.
mouse_for("launch_world: the room")
show_prompt()
-- The browser starts on the first thing in the first row, so there is
-- a selection from the first frame
browse_show()
show_hint()
-- The room's switches from the environment ([LAUNCH_WORLD] section 11):
-- each one the same toggle `event room <what>` makes
if env("BUILDAT_LAUNCH_NO_PROBE") ~= "" then room_switch("probe") end
if env("BUILDAT_LAUNCH_NO_ORNAMENT") ~= "" then room_switch("ornament") end
if env("BUILDAT_LAUNCH_STILL") ~= "" then room_switch("still") end

-- **What the client asks a launcher for** ([MENU_CONTEXT]): init.lua
-- hands these on as the extension's own.
-- **Where a frame goes, while the room is young** (2026-09-26): each
-- handler wrapped by name, since the sandbox has no _G to walk. Off
-- unless BUILDAT_LAUNCH_FRAME_TRACE is set: this is a measurement. The
-- handlers are subscribed through a closure for it: SubscribeToEvent
-- looks a name up when subscribing, and the wrapped ones went uncalled
-- ([FRAME_WORK], 2026-10-08).
;(function()
	if env("BUILDAT_LAUNCH_FRAME_TRACE") == "" then
		return
	end
	local function timed(name, f)
		return function(a, b)
			local t0 = buildat.get_time_us()
			f(a, b)
			frame_trace.us[name] = (frame_trace.us[name] or 0) +
					(buildat.get_time_us() - t0)
		end
	end
	handle_probe_update = timed("probe", handle_probe_update)
	handle_camera_update = timed("camera", handle_camera_update)
	handle_room_update = timed("room", handle_room_update)
	handle_orb_update = timed("orb", handle_orb_update)
	handle_synth_update = timed("synth", handle_synth_update)
	handle_dissolve_update = timed("dissolve", handle_dissolve_update)
	handle_idle_update = timed("idle", handle_idle_update)
	handle_wall_labels = timed("wall_labels", handle_wall_labels)
	handle_device_update = timed("device", handle_device_update)
	handle_frame_watch = timed("frame_watch", handle_frame_watch)
	handle_save_update = timed("save", handle_save_update)
	handle_launch_anim = timed("launch_anim", handle_launch_anim)
	handle_frame_trace = function(event_type, event_data)
		frame_trace.due = frame_trace.due - event_data:GetFloat("TimeStep")
		if frame_trace.due > 0 then
			return
		end
		frame_trace.due = 1.0
		for n, us in pairs(frame_trace.us) do
			if us > 500 then
				parts[#parts + 1] = string.format("%s %.0f", n, us / 1000)
			end
			frame_trace.us[n] = 0
		end
		table.sort(parts)
		log:info("the room's own second, in ms: " ..
				(#parts > 0 and table.concat(parts, ", ") or "nothing over 1"))
	end
	magic.SubscribeToEvent("Update", "handle_frame_trace")
end)()

-- **The game says it is loading** (the launch API's `launch_loading`):
-- the animation goes on even with the game's menu still up
function app_loading(what)
	if launch_anim and not launch_anim.loading then
		launch_anim.loading = true
		log:info("launch: the game is loading a " .. tostring(what))
	end
end

return {
	entered_app = entered_app,
	leave_app = leave_app,
	app_loading = app_loading,
	in_app = function() return in_app end,
	be_backdrop = be_backdrop,
}

-- vim: set noet ts=4 sw=4:
