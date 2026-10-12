// SPDX-License-Identifier: Apache-2.0 OR MIT
// [SECURITY_RUN_5] phase 4: the records a peer's bytes become after the
// framing ([COMPAT_BREAK_07] 8a, 8b): core:hello, the file transfer's
// FileHash and FileContent lists (interface/protocol.h, interface::Record),
// and served Lua's cereal reader (lua_bindings/cereal.cpp) on a few types
// with records in them, an older and a newer minor among them. The first
// byte picks the reader.
#include "interface/protocol.h"
#include "lua_bindings/util.h"
#include <cereal/types/vector.hpp>
#include <stdexcept>
extern "C" {
#include <lualib.h>
}

namespace lua_bindings { void init_cereal(lua_State *L); }
// Build/buildat_version.cpp's, which the build generates
const char *BUILDAT_VERSION = "0.7.0-fuzz";

static lua_State *L = nullptr;

// The types the reader is given, as served Lua would write them
static const char *types_lua =
	"T = {\n"
	" {'record', 1, 0, {'object', {'a', 'int32_t'}, {'b', 'string'}}},\n"
	" {'record', 1, 3, {'object', {'a', 'byte'}, {'b', {'array', 'string'}},\n"
	"   {'c', {'record', 2, 1, {'object', {'x', 'double'},\n"
	"     {'m', {'unordered_map', 'string', 'int16_t'}}}}}}},\n"
	" {'array', {'record', 1, 1, {'object', {'n', 'string'},\n"
	"   {'h', {'object', {'p', 'int32_t'}, {'q', 'string'}}}}}},\n"
	" {'unordered_map', 'int32_t', {'record', 3, 0, 'string'}},\n"
	"}\n";

extern "C" int LLVMFuzzerInitialize(int *argc, char ***argv)
{
	L = luaL_newstate();
	luaL_openlibs(L);
	lua_bindings::init_cereal(L);
	if(luaL_dostring(L, types_lua) != 0)
		__builtin_trap();
	// An older minor reads with the fields it lacks at their zero value
	const char *self_check =
		"local old = __buildat_cereal_binary_output({a = 7},"
		" {'record', 1, 0, {'object', {'a', 'byte'}}})\n"
		"local v = __buildat_cereal_binary_input(old, T[2])\n"
		"assert(v.a == 7 and #v.b == 0 and v.c.x == 0 and v.c.m)\n";
	if(luaL_dostring(L, self_check) != 0)
		__builtin_trap();
	return 0;
}

template<typename T>
static void read_cpp(const ss_ &in)
{
	T v;
	std::istringstream is(in, std::ios::binary);
	cereal::PortableBinaryInputArchive ar(is);
	ar(v);
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size)
{
	if(size < 1)
		return 0;
	const ss_ in((const char*)data + 1, size - 1);
	const int which = data[0] % 8;
	try {
		switch(which){
		case 0: {
			// A hello read is written and read back the same
			interface::Hello h = interface::hello_of(in);
			interface::Hello h2 = interface::hello_of(interface::hello_data(h));
			if(h2.version != h.version || h2.features != h.features ||
					h2.protocol_min != h.protocol_min)
				__builtin_trap();
			(void)interface::hello_refusal(h, "the server");
			break;
		}
		case 1: read_cpp<sv_<interface::FileHash>>(in); break;
		case 2: read_cpp<sv_<interface::FileContent>>(in); break;
		default: {
			const int top = lua_gettop(L);
			lua_getglobal(L, "__buildat_cereal_binary_input");
			lua_pushlstring(L, in.c_str(), in.size());
			lua_getglobal(L, "T");
			lua_rawgeti(L, -1, 1 + (which - 3) % 4);
			lua_remove(L, -2);
			lua_pcall(L, 2, 1, 0);
			lua_settop(L, top);
			lua_gc(L, LUA_GCSTEP, 0);
		}
		}
	} catch(std::exception &e){
	}
	return 0;
}
