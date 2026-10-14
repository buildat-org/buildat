// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
//
// zlib and zstd for Lua. What needs this first is the Luanti client extension,
// where a mapblock arrives as one zstd frame, but nothing here knows about
// that: data in, data out.
#include "lua_bindings/util.h"
#include "core/log.h"
#include "interface/compress.h"
#include <sstream>
#include <cstring>
#define MODULE "lua_bindings"

namespace lua_bindings {

// "zlib" or "zstd"; anything else is an error rather than a guess
enum CompressFormat {
	FORMAT_ZLIB,
	FORMAT_ZSTD,
};

static bool parse_format(const char *name, CompressFormat &result)
{
	if(strcmp(name, "zlib") == 0){
		result = FORMAT_ZLIB;
		return true;
	}
	if(strcmp(name, "zstd") == 0){
		result = FORMAT_ZSTD;
		return true;
	}
	return false;
}

// compress(data, format [, level]) -> string
static int l_compress(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	CompressFormat format;
	if(!parse_format(luaL_checkstring(L, 2), format))
		return luaL_error(L, "compress(): unknown format \"%s\"",
				luaL_checkstring(L, 2));
	bool have_level = !lua_isnoneornil(L, 3);
	int level = have_level ? luaL_checkint(L, 3) : 0;

	std::ostringstream os(std::ios::binary);
	try {
		if(format == FORMAT_ZLIB)
			interface::compress_zlib(data, os, have_level ? level : 6);
		else
			interface::compress_zstd(data, os, have_level ? level : 3);
	} catch(std::exception &e){
		return luaL_error(L, "compress(): %s", e.what());
	}
	ss_ result = os.str();
	lua_pushlstring(L, result.c_str(), result.size());
	return 1;
}

// decompress(data, format) -> data, bytes_consumed
//
// bytes_consumed is how much of the front of data the stream took, which is
// what tells a caller reading concatenated streams where the next one begins.
// The format is required, as compress()'s is ([API_DEFAULTS_07]).
static int l_decompress(lua_State *L)
{
	ss_ data = lua_checkcppstring(L, 1);
	CompressFormat format;
	if(lua_isnoneornil(L, 2))
		return luaL_error(L, "decompress(): the format is required"
				" (\"zlib\" or \"zstd\")");
	if(!parse_format(luaL_checkstring(L, 2), format))
		return luaL_error(L, "decompress(): unknown format \"%s\"",
				luaL_checkstring(L, 2));

	std::ostringstream os(std::ios::binary);
	size_t consumed = 0;
	try {
		if(format == FORMAT_ZLIB){
			std::istringstream is(data, std::ios::binary);
			interface::decompress_zlib(is, os);
			// decompress_zlib() ungets what inflate did not take, so where the
			// stream reads up to is where the next one starts
			std::streampos pos = is.tellg();
			consumed = pos < 0 ? data.size() : (size_t)pos;
		} else {
			consumed = interface::decompress_zstd(data, os);
		}
	} catch(std::exception &e){
		return luaL_error(L, "decompress(): %s", e.what());
	}
	ss_ result = os.str();
	lua_pushlstring(L, result.c_str(), result.size());
	lua_pushnumber(L, consumed);
	return 2;
}

void init_compress(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(compress)
	DEF_BUILDAT_FUNC(decompress)
}

} // namespace lua_bindings

// vim: set noet ts=4 sw=4:
