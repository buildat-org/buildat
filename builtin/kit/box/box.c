/* http://www.apache.org/licenses/LICENSE-2.0
** Copyright 2026 Perttu Ahola <celeron55@gmail.com>
**
** [KIT] The Kit box: Lua 5.1 (lua/, a copy whose luaconf.h throws by a
** trap) in a server .wasm, which builtin/kit runs in src/wasm/engine.cpp's
** sandbox and meter. Component code runs here and nowhere else.
**
** One export, box_call(): the host's request is taken with call_input,
** the answer given with call_output, "O" and JSON, or "E" and an error.
**   "D<name>\0<source>"  a component type: its file run in an environment
**                        of its own; answers its declaration (the file's
**                        table, functions as the names in "handlers")
**   "R<lua literal>"     a handler run: {type, handler, id, pos, yaw, params,
**                        state, args, nargs, player, and the player's
**                        inventory: items (Kit's counts), inv = {type,
**                        id, params, state} (the replacing provider, or the
**                        player entity's own kit/inventory) or inv_self;
**                        [KIT] stage 4d: player_id (the player entity),
**                        names {by = name}, made {id...}, players (a type's
**                        `players`), next_id and sizes {"prefab:<name>" |
**                        "entity:<id>" = entities a copy makes};
**                        [KIT_VOXEL_STATES] box {sx, sy, sz} (its
**                        voxel_box) and voxels {names, ids} (reads_voxels:
**                        each cell's name's index, 0 not loaded)}; answers
**                        its effects, {set = {{key, value}...} (a table
**                        changed in place too), emit = {{output,
**                        value}...}, voxel = name, voxels = {{x, y, z,
**                        name}...} (c:set_voxels), after = {{name,
**                        seconds (-1: taken back), player | null}...},
**                        teleport = {x, y, z}, teleport_yaw = degrees
**                        (looking that way, level), items = {item = n}
**                        (the player's list after inventory calls),
**                        inv_set = {{key, value}...} (the provider's
**                        state), spawn = {{ref, pos|null, id}...}, remove
**                        = {id...}, send = {{id, input, value}...}, log =
**                        {line...}, app = {{what, value}...}}; a call into
**                        the provider (inv) is marked by "P" before it and
**                        "p" after it, ahead of the answer
**   "L<source>"          [KIT] stage 4h: the movement library
**                        (client_lua/move.lua), before the types
**   "S<lua literal>"     a body's steps: {type, params, state, inputs, dt,
**                        sub, world (move.lua's snapshot)}; answers the
**                        state after them
** A Lua error traps the call (no setjmp in this wasm). The host then calls
** box_recover(), which unwinds the Lua state as a longjmp to box_call's
** protected call would have, and answers "E" and the message; 0 from it
** (a trap that was not a Lua error: the meter, memory) means the state is
** not to be trusted, and the host starts a new box.
** simplified: one protected level. A pcall inside Lua could not catch (its
** C frames are gone with the trap), so components get no pcall, xpcall or
** coroutines; a loadstring's syntax error ends the whole call. */
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "lua/lua.h"
#include "lua/lauxlib.h"
#include "lua/lualib.h"
#include "lua/lstate.h"
#include "lua/ldo.h"
#include "lua/lfunc.h"
#include "interface/wasm_server_api.h"

static lua_State *L;
static int g_pending; /* a Lua error's status, thrown and not recovered */
static struct {
	ptrdiff_t top, ci, errfunc;
	unsigned short nCcalls;
	lu_byte allowhook;
} g_entry;
static void *g_stack_top;

static void *get_sp(void)
{
	void *p;
	__asm__ volatile(".globaltype __stack_pointer, i32\n\t"
			"global.get __stack_pointer\n\tlocal.set %0" : "=r"(p));
	return p;
}
static void set_sp(void *p)
{
	__asm__ volatile(".globaltype __stack_pointer, i32\n\t"
			"local.get %0\n\tglobal.set __stack_pointer" :: "r"(p));
}

/* The C stack is the linker's 64 KiB below the top: an error past 48 of
** them, while there is room left to raise it */
int box_stack_low(void)
{
	return g_stack_top && (char*)get_sp() < (char*)g_stack_top - (48 << 10);
}

void box_throw(struct lua_State *l, int status)
{
	(void)l;
	g_pending = status;
	__builtin_trap();
}

static void out(char kind, const char *s, size_t n)
{
	char *b = (char*)malloc(n + 1);
	if(!b){
		buildat_call_output("Eout of memory", 14);
		return;
	}
	b[0] = kind;
	memcpy(b + 1, s, n);
	buildat_call_output(b, (unsigned)(n + 1));
	free(b);
}

static int l_log(lua_State *l)
{
	size_t n;
	const char *s = luaL_checklstring(l, 1, &n);
	buildat_log(s, (unsigned)n);
	return 0;
}

/* A mark in the answer: "P" as a call into the replacing inventory
** provider starts, "p" as it ends. A call the meter stops leaves the last
** one, so the host knows whose run it was ([KIT] stage 4c) */
static int l_mark(lua_State *l)
{
	size_t n;
	const char *s = luaL_checklstring(l, 1, &n);
	buildat_call_output(s, (unsigned)n);
	return 0;
}

static int l_floor(lua_State *l)
{
	lua_pushnumber(l, floor(luaL_checknumber(l, 1)));
	return 1;
}
static int l_ceil(lua_State *l)
{
	lua_pushnumber(l, ceil(luaL_checknumber(l, 1)));
	return 1;
}
static int l_sqrt(lua_State *l)
{
	lua_pushnumber(l, sqrt(luaL_checknumber(l, 1)));
	return 1;
}
static int l_fmod(lua_State *l)
{
	lua_pushnumber(l, fmod(luaL_checknumber(l, 1), luaL_checknumber(l, 2)));
	return 1;
}
/* xorshift64*, one sequence for the box. simplified: not seeded per
** instance, and a box restart starts it over */
static unsigned long long g_rand = 0x9e3779b97f4a7c15ull;
static int l_random(lua_State *l)
{
	g_rand ^= g_rand >> 12;
	g_rand ^= g_rand << 25;
	g_rand ^= g_rand >> 27;
	const double r = (double)((g_rand * 2685821657736338717ull) >> 11) *
			(1.0 / 9007199254740992.0);
	switch(lua_gettop(l)){
	case 0:
		lua_pushnumber(l, r);
		return 1;
	case 1: {
		const int u = luaL_checkint(l, 1);
		luaL_argcheck(l, 1 <= u, 1, "interval is empty");
		lua_pushnumber(l, floor(r * u) + 1);
		return 1; }
	default: {
		const int lo = luaL_checkint(l, 1), up = luaL_checkint(l, 2);
		luaL_argcheck(l, lo <= up, 2, "interval is empty");
		lua_pushnumber(l, floor(r * (up - lo + 1)) + lo);
		return 1; }
	}
}

static const luaL_Reg MATH[] = {
	{"floor", l_floor}, {"ceil", l_ceil}, {"sqrt", l_sqrt}, {"fmod", l_fmod},
	{"random", l_random}, {NULL, NULL}
};

/* The runtime's own Lua: the components' environments, the requests and
** the JSON of the answers */
static const char PRELUDE[] =
"local types = {}\n"
"local NULL = {}\n"
"local log = box_log\n"
"local mark = box_mark\n"
"local smeta = getmetatable('')\n"
"smeta.__metatable = false\n"
"local math_lib = box_math\n"
"math_lib.huge = 1/0\n"
"math_lib.pi = 3.14159265358979323846\n"
"function math_lib.abs(x) x = tonumber(x) or error('number expected', 2) if x < 0 then return -x end return x end\n"
"function math_lib.min(a, ...) for i = 1, select('#', ...) do local b = select(i, ...) if b < a then a = b end end return a end\n"
"function math_lib.max(a, ...) for i = 1, select('#', ...) do local b = select(i, ...) if b > a then a = b end end return a end\n"
"local function copy(t) local r = {} for k, v in pairs(t) do r[k] = v end return r end\n"
"local base = {assert = assert, error = error, ipairs = ipairs, next = next,\n"
"	pairs = pairs, select = select, tonumber = tonumber, tostring = tostring,\n"
"	type = type, unpack = unpack, rawequal = rawequal, rawget = rawget,\n"
"	rawset = rawset, setmetatable = setmetatable, getmetatable = getmetatable}\n"
"local function line(...)\n"
"	local t = {}\n"
"	for i = 1, select('#', ...) do t[i] = tostring((select(i, ...))) end\n"
"	return table.concat(t, ' ')\n"
"end\n"
"local function new_env(name)\n"
"	local e = copy(base)\n"
"	e.string = copy(string)\n"
"	e.table = copy(table)\n"
"	e.math = copy(math_lib)\n"
"	e.print = function(...) log(name .. ': ' .. line(...)) end\n"
"	return e\n"
"end\n"
"local function esc(c)\n"
"	if c == '\"' then return '\\\\\"' end\n"
"	if c == '\\\\' then return '\\\\\\\\' end\n"
"	return string.format('\\\\u%04x', c:byte())\n"
"end\n"
"local function enc(v, out, depth)\n"
"	if depth > 32 then error('a value nested past 32 levels', 0) end\n"
"	local t = type(v)\n"
"	if v == nil or v == NULL then out[#out + 1] = 'null'\n"
"	elseif t == 'boolean' then out[#out + 1] = tostring(v)\n"
"	elseif t == 'number' then\n"
"		if v ~= v or v == 1/0 or v == -1/0 then out[#out + 1] = 'null'\n"
"		else out[#out + 1] = string.format('%.17g', v) end\n"
"	elseif t == 'string' then out[#out + 1] = '\"' .. v:gsub('[%c\"\\\\]', esc) .. '\"'\n"
"	elseif t == 'table' then\n"
"		local n = #v\n"
"		local array = next(v) == nil or n > 0\n"
"		if array then for k in pairs(v) do\n"
"			if type(k) ~= 'number' or k < 1 or k > n or k % 1 ~= 0 then array = false break end end end\n"
"		if array then\n"
"			out[#out + 1] = '['\n"
"			for i = 1, n do if i > 1 then out[#out + 1] = ',' end enc(v[i], out, depth + 1) end\n"
"			out[#out + 1] = ']'\n"
"		else\n"
"			out[#out + 1] = '{'\n"
"			local first = true\n"
"			for k, x in pairs(v) do\n"
"				if type(x) ~= 'function' then\n"
"					if not first then out[#out + 1] = ',' end\n"
"					first = false\n"
"					enc(tostring(k), out, depth + 1)\n"
"					out[#out + 1] = ':'\n"
"					enc(x, out, depth + 1)\n"
"				end\n"
"			end\n"
"			out[#out + 1] = '}'\n"
"		end\n"
"	else out[#out + 1] = 'null' end\n"
"end\n"
"local function json(v) local out = {} enc(v, out, 0) return table.concat(out) end\n"
"local function define(name, src)\n"
"	if src:byte(1) == 27 then error(name .. ': a precompiled chunk is refused', 0) end\n"
"	local f = assert(loadstring(src, '=' .. name))\n"
"	setfenv(f, new_env(name))\n"
"	local def = f()\n"
"	if type(def) ~= 'table' then error(name .. ': the file returns no table', 0) end\n"
"	types[name] = def\n"
"	local decl, handlers = {}, {}\n"
"	for k, v in pairs(def) do\n"
"		if type(v) == 'function' then handlers[#handlers + 1] = k else decl[k] = v end\n"
"	end\n"
"	decl.handlers = handlers\n"
"	return json(decl)\n"
"end\n"
"local function proxy(state, sets)\n"
"	return setmetatable({}, {__index = state, __newindex = function(_, k, v)\n"
"		state[k] = v\n"
"		sets[#sets + 1] = {k, v == nil and NULL or v}\n"
"	end})\n"
"end\n"
"-- A table in the state changed in place (c.state.t[k] = v) is a set too:\n"
"-- each table's JSON before the run, compared after it\n"
"local function in_place(state, sets)\n"
"	local was = {}\n"
"	for k, v in pairs(state) do if type(v) == 'table' then was[k] = json(v) end end\n"
"	return function()\n"
"		for k, s in pairs(was) do\n"
"			local v = rawget(state, k)\n"
"			if type(v) == 'table' and json(v) ~= s then sets[#sets + 1] = {k, v} end\n"
"		end\n"
"	end\n"
"end\n"
"local MAX_ITEMS = 1000000\n"
"local KIT_INV = {\n"
"	inventory_count = function(p, player, item) return p.items[item] or 0 end,\n"
"	inventory_add = function(p, player, item, n)\n"
"		p.items[item] = math_lib.min(MAX_ITEMS, (p.items[item] or 0) + n) return true end,\n"
"	inventory_take = function(p, player, item, n)\n"
"		local had = p.items[item] or 0\n"
"		if had < n then return false end\n"
"		p.items[item] = had > n and had - n or nil\n"
"		return true\n"
"	end,\n"
"	inventory_list = function(p, player) return copy(p.items) end,\n"
"}\n"
"local function inventory(req, fx, c)\n"
"	local player, def, p, touched, inv_done = req.player, KIT_INV, nil, false, nil\n"
"	if req.inv_self then def, p = types[req.type], c\n"
"	elseif req.inv then\n"
"		def = types[req.inv.type]\n"
"		if not def then error('no inventory provider ' .. tostring(req.inv.type), 0) end\n"
"		fx.inv_set = {}\n"
"		local st = req.inv.state or {}\n"
"		p = {id = req.inv.id, params = req.inv.params or {},\n"
"			state = proxy(st, fx.inv_set)}\n"
"		inv_done = in_place(st, fx.inv_set)\n"
"		function p:log(...) log(req.inv.type .. ' ' .. tostring(req.inv.id) .. ': ' .. line(...)) end\n"
"	else p = {items = req.items or {}} end\n"
"	local function call(h, ...)\n"
"		if not req.inv then return def[h](p, ...) end\n"
"		mark('P')\n"
"		local r = def[h](p, ...)\n"
"		mark('p')\n"
"		return r\n"
"	end\n"
"	local function args(item, n, ext)\n"
"		if type(item) ~= 'string' or #item > 64 or not item:match('^[%w_]+$') then\n"
"			error('an item is letters, digits and _', 4) end\n"
"		if type(n) ~= 'number' or n < 1 or n > MAX_ITEMS or n % 1 ~= 0 then\n"
"			error('a count is a whole number from 1', 4) end\n"
"		if ext ~= nil and type(ext) ~= 'table' then error('ext is a table', 4) end\n"
"		return ext or {}\n"
"	end\n"
"	local inv = {}\n"
"	function inv.count(item, ext)\n"
"		ext = args(item, 1, ext)\n"
"		if not player then return 0 end\n"
"		return tonumber(call('inventory_count', player, item, ext)) or 0\n"
"	end\n"
"	function inv.change(h, item, n, ext)\n"
"		ext = args(item, n or 1, ext)\n"
"		if not player then return false end\n"
"		touched = true\n"
"		return call(h, player, item, n or 1, ext) == true\n"
"	end\n"
"	function inv.list(ext)\n"
"		if ext ~= nil and type(ext) ~= 'table' then error('ext is a table', 3) end\n"
"		if not player then return {} end\n"
"		local l = call('inventory_list', player, ext or {})\n"
"		return type(l) == 'table' and copy(l) or {}\n"
"	end\n"
"	function inv.finish()\n"
"		if touched then fx.items = inv.list() end\n"
"		if inv_done then inv_done() end\n"
"	end\n"
"	return inv\n"
"end\n"
"local function run(req)\n"
"	local def = types[req.type]\n"
"	if not def then error('no component type ' .. tostring(req.type), 0) end\n"
"	local h = def[req.handler]\n"
"	if type(h) ~= 'function' then return '{}' end\n"
"	local state, sets, emits, fx = req.state or {}, {}, {}, {}\n"
"	local c = {id = req.id, pos = req.pos, yaw = req.yaw or 0, params = req.params or {},\n"
"		player = req.player_id, made = req.made or {}, players = req.players}\n"
"	c.state = proxy(state, sets)\n"
"	local state_done = in_place(state, sets)\n"
"	local inv = inventory(req, fx, c)\n"
"	local names = req.names or {}\n"
"	function c:name(by) by = tostring(by) return names[by] or by end\n"
"	-- Entities: copies made, removed, signalled; the host checks each\n"
"	-- against what the component reaches\n"
"	local spawns, removes, sends, lines = {}, {}, {}, {}\n"
"	local next_id, sizes = req.next_id or 0, req.sizes or {}\n"
"	function c:spawn(t)\n"
"		if type(t) ~= 'table' then error('spawn: {prefab = name} or {entity = id}', 2) end\n"
"		local ref = t.prefab ~= nil and 'prefab:' .. tostring(t.prefab) or\n"
"			t.entity ~= nil and 'entity:' .. tostring(t.entity) or nil\n"
"		local n = ref and sizes[ref]\n"
"		if not n then error('spawn: ' .. tostring(ref) .. ' is none it reaches', 2) end\n"
"		if #spawns >= 16 then error('spawn: 16 a run at most', 2) end\n"
"		local pos = NULL\n"
"		if t.pos ~= nil then\n"
"			if type(t.pos) ~= 'table' then error('spawn: pos is {x, y, z}', 2) end\n"
"			pos = {tonumber(t.pos[1]) or 0, tonumber(t.pos[2]) or 0, tonumber(t.pos[3]) or 0}\n"
"		end\n"
"		local id = next_id\n"
"		next_id = next_id + n\n"
"		spawns[#spawns + 1] = {ref, pos, id}\n"
"		return id\n"
"	end\n"
"	function c:remove(id)\n"
"		if #removes >= 64 then error('remove: 64 a run at most', 2) end\n"
"		removes[#removes + 1] = tonumber(id) or req.id\n"
"	end\n"
"	function c:send(id, input, value)\n"
"		if #sends >= 64 then error('send: 64 a run at most', 2) end\n"
"		sends[#sends + 1] = {tonumber(id) or 0, tostring(input), value == nil and NULL or value}\n"
"	end\n"
"	function c:count(item, ext) return inv.count(item, ext) end\n"
"	function c:has(item, n, ext) return inv.count(item, ext) >= (tonumber(n) or 1) end\n"
"	function c:add(item, n, ext) return inv.change('inventory_add', item, n, ext) end\n"
"	c.give = c.add\n"
"	function c:take(item, n, ext) return inv.change('inventory_take', item, n, ext) end\n"
"	function c:list(ext) return inv.list(ext) end\n"
"	function c:emit(output, value) emits[#emits + 1] = {tostring(output), value == nil and NULL or value} end\n"
"	function c:set_voxel(name) fx.voxel = tostring(name) end\n"
"	-- [KIT_VOXEL_STATES] Its voxel box: its size, its voxels (reads_voxels)\n"
"	-- in box order, and cells written in it\n"
"	c.box = req.box\n"
"	local cells_read\n"
"	function c:voxels()\n"
"		local v = req.voxels\n"
"		if not v then error('voxels: its type reads no voxel box (reads_voxels)', 2) end\n"
"		if not cells_read then\n"
"			cells_read = {}\n"
"			for i, id in ipairs(v.ids) do cells_read[i] = v.names[id] or '' end\n"
"		end\n"
"		local out = {}\n"
"		for i = 1, #cells_read do out[i] = cells_read[i] end\n"
"		return out\n"
"	end\n"
"	function c:set_voxels(cells)\n"
"		if type(cells) ~= 'table' then error('set_voxels: {{x, y, z, name}...}', 2) end\n"
"		local out = fx.voxels or {}\n"
"		for _, q in ipairs(cells) do\n"
"			if type(q) ~= 'table' then error('set_voxels: {{x, y, z, name}...}', 2) end\n"
"			if #out >= 4096 then error('set_voxels: 4096 cells a run at most', 2) end\n"
"			out[#out + 1] = {tonumber(q[1]) or -1, tonumber(q[2]) or -1, tonumber(q[3]) or -1, tostring(q[4])}\n"
"		end\n"
"		fx.voxels = out\n"
"	end\n"
"	-- c:after(seconds, name, {player = id}): many an instance, by name and\n"
"	-- player; no seconds (or < 0) takes that one back\n"
"	function c:after(seconds, name, opts)\n"
"		if name ~= nil and type(name) ~= 'string' then error('after: a name is a string', 2) end\n"
"		if name and #name > 64 then error('after: a name is 64 characters at most', 2) end\n"
"		if opts ~= nil and type(opts) ~= 'table' then error('after: options are {player = id}', 2) end\n"
"		local a = fx.after or {}\n"
"		if #a >= 64 then error('after: 64 a run at most', 2) end\n"
"		local pl = opts and opts.player\n"
"		a[#a + 1] = {name or '', tonumber(seconds) or -1, pl == nil and NULL or pl}\n"
"		fx.after = a\n"
"	end\n"
"	function c:teleport(pos, opts)\n"
"		if type(pos) ~= 'table' then error('teleport: a position, {x, y, z}', 2) end\n"
"		if opts ~= nil and type(opts) ~= 'table' then error('teleport: options are {yaw = degrees}', 2) end\n"
"		local t = {tonumber(pos[1]) or 0, tonumber(pos[2]) or 0, tonumber(pos[3]) or 0}\n"
"		local yaw = opts and tonumber(opts.yaw)\n"
"		fx.teleport = t\n"
"		fx.teleport_yaw = yaw and yaw - yaw == 0 and yaw or nil\n"
"	end\n"
"	-- [KIT] stage 6a: a call into the app's native code (the host lets\n"
"	-- only the app's own types through)\n"
"	local apps = {}\n"
"	function c:app(what, value)\n"
"		if #apps >= 8 then error('app: 8 a run at most', 2) end\n"
"		apps[#apps + 1] = {tostring(what), value == nil and NULL or value}\n"
"	end\n"
"	-- A line in the server's log at once, and the entity's own in the answer\n"
"	function c:log(...)\n"
"		local s = line(...)\n"
"		log(req.type .. ' ' .. tostring(req.id) .. ': ' .. s)\n"
"		if #lines < 20 then lines[#lines + 1] = s:sub(1, 200) end\n"
"	end\n"
"	-- What it returned, a boolean and a reason ([KIT] stage 4j: allow)\n"
"	local r1, r2 = h(c, unpack(req.args or {}, 1, req.nargs or 0))\n"
"	inv.finish()\n"
"	if type(r1) == 'boolean' then fx.ret = {r1, type(r2) == 'string' and r2 or ''} end\n"
"	state_done()\n"
"	fx.set = sets\n"
"	fx.emit = emits\n"
"	if #spawns > 0 then fx.spawn = spawns end\n"
"	if #removes > 0 then fx.remove = removes end\n"
"	if #sends > 0 then fx.send = sends end\n"
"	if #lines > 0 then fx.log = lines end\n"
"	if #apps > 0 then fx.app = apps end\n"
"	return json(fx)\n"
"end\n"
"-- [KIT] stage 4h: the movement library (client_lua/move.lua), and a\n"
"-- body's steps with it\n"
"local move\n"
"local function step(req)\n"
"	local def = types[req.type]\n"
"	if not def or type(def.step) ~= 'function' then error('no movement ' .. tostring(req.type), 0) end\n"
"	if not move then error('no movement library', 0) end\n"
"	local w = move.snapshot(req.world or {})\n"
"	local s = req.state or {}\n"
"	move.steps(def, s, req.inputs or {}, req.dt or 1/60, req.sub or 1, w, req.params or {})\n"
"	return json(s)\n"
"end\n"
"function box_request(s)\n"
"	local op = s:sub(1, 1)\n"
"	if op == 'L' then\n"
"		local f = assert(loadstring(s:sub(2), '=move'))\n"
"		setfenv(f, {math = math_lib, ipairs = ipairs, pairs = pairs, type = type,\n"
"			tostring = tostring, tonumber = tonumber, setmetatable = setmetatable})\n"
"		move = f()\n"
"		return 'true'\n"
"	elseif op == 'S' then\n"
"		local f = assert(loadstring(s:sub(2), '=request'))\n"
"		setfenv(f, {})\n"
"		return step(f())\n"
"	elseif op == 'D' then\n"
"		local z = s:find('\\0', 2, true)\n"
"		if not z then error('a define with no name', 0) end\n"
"		return define(s:sub(2, z - 1), s:sub(z + 1))\n"
"	elseif op == 'R' then\n"
"		local f = assert(loadstring(s:sub(2), '=request'))\n"
"		setfenv(f, {})\n"
"		return run(f())\n"
"	elseif op == 'M' then\n"
"		-- [KIT] stage 5: an older version's parameters as the type's\n"
"		-- migrate(params, from) makes them\n"
"		local f = assert(loadstring(s:sub(2), '=request'))\n"
"		setfenv(f, {})\n"
"		local req = f()\n"
"		local def = types[req.type]\n"
"		if not def or type(def.migrate) ~= 'function' then error('no migrate in ' .. tostring(req.type), 0) end\n"
"		local p = def.migrate(req.params or {}, req.from)\n"
"		if type(p) ~= 'table' then error('migrate returns no table', 0) end\n"
"		return json(p)\n"
"	end\n"
"	error('an unknown request', 0)\n"
"end\n";

static void *l_alloc(void *ud, void *ptr, size_t osize, size_t nsize)
{
	(void)ud;
	(void)osize;
	if(nsize == 0){
		free(ptr);
		return NULL;
	}
	return realloc(ptr, nsize);
}

/* In the protected call: the state's first making, then the request */
static int f_request(lua_State *l)
{
	const char *in = (const char*)lua_touserdata(l, 1);
	const size_t n = *(const size_t*)lua_touserdata(l, 2);
	lua_getglobal(l, "box_request");
	lua_pushlstring(l, in, n);
	lua_call(l, 1, 1);
	return 1;
}

static int f_open(lua_State *l)
{
	lua_pushcfunction(l, luaopen_base);
	lua_call(l, 0, 0);
	lua_pushcfunction(l, luaopen_string);
	lua_call(l, 0, 0);
	lua_pushcfunction(l, luaopen_table);
	lua_call(l, 0, 0);
	lua_pushcfunction(l, l_log);
	lua_setglobal(l, "box_log");
	lua_pushcfunction(l, l_mark);
	lua_setglobal(l, "box_mark");
	lua_newtable(l);
	luaL_register(l, NULL, MATH);
	lua_setglobal(l, "box_math");
	if(luaL_loadbuffer(l, PRELUDE, sizeof(PRELUDE) - 1, "=kit") != 0)
		lua_error(l);
	lua_call(l, 0, 0);
	return 0;
}

/* The protected call's entry, what box_recover() puts back */
static void enter(void)
{
	g_entry.top = savestack(L, L->top);
	g_entry.ci = saveci(L, L->ci);
	g_entry.errfunc = L->errfunc;
	g_entry.nCcalls = L->nCcalls;
	g_entry.allowhook = L->allowhook;
	g_pending = 0;
}

__attribute__((noinline)) static int call_inner(void)
{
	if(!L){
		L = lua_newstate(l_alloc, NULL);
		if(!L){
			out('E', "out of memory", 13);
			return 1;
		}
		enter();
		if(lua_cpcall(L, f_open, NULL) != 0){
			out('E', "the prelude failed", 18);
			return 1;
		}
	}
	const int n = buildat_call_input(NULL, 0);
	if(n < 0){
		out('E', "no input", 8);
		return 1;
	}
	char *in = (char*)malloc((size_t)n + 1);
	if(!in){
		out('E', "out of memory", 13);
		return 1;
	}
	buildat_call_input(in, (unsigned)n);
	size_t len = (size_t)n;
	lua_settop(L, 0);
	lua_pushcfunction(L, f_request);
	lua_pushlightuserdata(L, in);
	lua_pushlightuserdata(L, &len);
	enter();
	g_entry.top = savestack(L, L->top - 3);
	/* simplified: the input buffer leaks when the call traps (its pointer
	** was in the lost frame); a request is small */
	const int status = lua_pcall(L, 2, 1, 0);
	free(in);
	size_t rn = 0;
	const char *r = lua_tolstring(L, -1, &rn);
	if(status != 0 || !r)
		out('E', r ? r : "?", r ? rn : 1);
	else
		out('O', r, rn);
	lua_settop(L, 0);
	return status != 0;
}

/* After a trap: 1 and "E" with the message when it was a Lua error, the
** state unwound to box_call's protected call; 0 when it was not */
__attribute__((noinline)) static int recover_inner(void)
{
	if(!L || !g_pending)
		return 0;
	const int status = g_pending;
	g_pending = 0;
	L->errorJmp = NULL;
	StkId oldtop = restorestack(L, g_entry.top);
	luaF_close(L, oldtop);
	luaD_seterrorobj(L, status, oldtop);
	L->nCcalls = g_entry.nCcalls;
	L->ci = restoreci(L, g_entry.ci);
	L->base = L->ci->base;
	L->savedpc = L->ci->savedpc;
	L->allowhook = g_entry.allowhook;
	if(L->size_ci > LUAI_MAXCALLS){
		const int inuse = (int)(L->ci - L->base_ci);
		if(inuse + 1 < LUAI_MAXCALLS)
			luaD_reallocCI(L, LUAI_MAXCALLS);
	}
	L->errfunc = g_entry.errfunc;
	size_t rn = 0;
	const char *r = lua_tolstring(L, -1, &rn);
	out('E', r ? r : "?", r ? rn : 1);
	lua_settop(L, 0);
	return 1;
}

/* The exports keep no frame of their own: the stack pointer a trap left
** deep is put back to the top here, before anything uses it */
BUILDAT_SERVER_EXPORT int box_call(void)
{
	if(!g_stack_top)
		g_stack_top = get_sp();
	else
		set_sp(g_stack_top);
	return call_inner();
}

BUILDAT_SERVER_EXPORT int box_recover(void)
{
	if(!g_stack_top)
		return 0;
	set_sp(g_stack_top);
	return recover_inner();
}
