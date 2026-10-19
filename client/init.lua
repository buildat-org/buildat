-- Buildat: client/init.lua
-- http://www.apache.org/licenses/LICENSE-2.0
-- Copyright 2014 Perttu Ahola <celeron55@gmail.com>
buildat = {safe = {}}

function buildat.bytes(data)
	local result = {}
	for i=1,#data do
		table.insert(result, string.byte(data, i))
	end
	return result
end
buildat.safe.bytes = buildat.bytes

function buildat.dump(thing)
	if type(thing) == 'string' then
		return '"'..thing..'"'
	end
	if type(thing) == 'number' then
		return ''..thing
	end
	if type(thing) == 'boolean' then
		if thing then return "true" else return "false" end
	end
	if thing == nil then
		return "nil"
	end
	if type(thing) == 'table' then
		local s = "{"
		local first = true
		for k, v in pairs(thing) do
			if not first then s = s..", " end
			s = s.."["..buildat.dump(k).."] = "..buildat.dump(v)
			first = false
		end
		s = s.."}"
		return s
	end
	return type(thing)
end
buildat.safe.dump = buildat.dump

function buildat.Logger(module)
	local logger = {}
	function fix_text(text)
		if type(text) == 'string' then
			return text
		end
		return buildat.dump(text)
	end
	function logger:error(text)
		text = fix_text(text)
		__buildat_print_log("error", module, text)
	end
	function logger:warning(text)
		text = fix_text(text)
		__buildat_print_log("warning", module, text)
	end
	function logger:info(text)
		text = fix_text(text)
		__buildat_print_log("info", module, text)
	end
	function logger:verbose(text)
		text = fix_text(text)
		__buildat_print_log("verbose", module, text)
	end
	function logger:debug(text)
		text = fix_text(text)
		__buildat_print_log("debug", module, text)
	end
	function logger:trace(text)
		text = fix_text(text)
		__buildat_print_log("trace", module, text)
	end
	return logger
end
buildat.safe.Logger = buildat.Logger

local log = buildat.Logger("__client/init")

log:info("init.lua loaded")

dofile(__buildat_get_path("share").."/client/test.lua")
dofile(__buildat_get_path("share").."/client/api.lua")
dofile(__buildat_get_path("share").."/client/packet.lua")
dofile(__buildat_get_path("share").."/client/extensions.lua")
dofile(__buildat_get_path("share").."/client/sandbox.lua")
dofile(__buildat_get_path("share").."/client/modules.lua")
dofile(__buildat_get_path("share").."/client/dummy.lua")

-- vim: set noet ts=4 sw=4:
