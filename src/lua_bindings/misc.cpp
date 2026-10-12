// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "lua_bindings/util.h"
#include <ctime>
#include "core/log.h"
#include "core/version.h"
#include "interface/fs.h"
#include "interface/protocol.h"
#include <c55/os.h>
#define MODULE "lua_bindings"

namespace lua_bindings {

// print_log(level, module, text)
static int l_print_log(lua_State *L)
{
	ss_ level = lua_tocppstring(L, 1);
	const char *module_c = lua_tostring(L, 2);
	const char *text_c = lua_tostring(L, 3);
	// Either can be nil from Lua, and a null module crashed the client in
	// log_() -- the sandbox scan's walk reached it from a script
	if(module_c == nullptr)
		module_c = "?";
	if(text_c == nullptr)
		text_c = "nil";
	int loglevel = CORE_INFO;
	if(level == "trace")
		loglevel = CORE_TRACE;
	else if(level == "debug")
		loglevel = CORE_DEBUG;
	else if(level == "verbose")
		loglevel = CORE_VERBOSE;
	else if(level == "info")
		loglevel = CORE_INFO;
	else if(level == "warning")
		loglevel = CORE_WARNING;
	else if(level == "error")
		loglevel = CORE_ERROR;
	log_(loglevel, module_c, "%s", text_c);
	return 0;
}

// mkdir(path: string)
static int l_mkdir(lua_State *L)
{
	ss_ path = lua_tocppstring(L, 1);
	bool ok = interface::fs::create_directories(path);
	if(!ok)
		log_w(MODULE, "Failed to create directory: \"%s\"", cs(path));
	else
		log_v(MODULE, "Created directory: \"%s\"", cs(path));
	lua_pushboolean(L, ok);
	return 1;
}

// Like lua_pcall, but returns a full traceback on error
// pcall(function) -> status, error
static int l_pcall(lua_State *L)
{
	log_t(MODULE, "l_pcall() begin");
	lua_pushcfunction(L, handle_error);
	int handle_error_stack_i = lua_gettop(L);

	lua_pushvalue(L, 1);
	int r = lua_pcall(L, 0, 0, handle_error_stack_i);
	int error_stack_i = lua_gettop(L);
	if(r == 0){
		log_t(MODULE, "l_pcall() returned 0 (no error)");
		lua_pushboolean(L, true);
		return 1;
	}
	if(r == LUA_ERRRUN)
		log_w(MODULE, "pcall(): Runtime error");
	if(r == LUA_ERRMEM)
		log_w(MODULE, "pcall(): Out of memory");
	if(r == LUA_ERRERR)
		log_w(MODULE, "pcall(): Error handler  failed");
	lua_pushboolean(L, false);
	lua_pushvalue(L, error_stack_i);
	return 2;
}

// fatal_error(error: string)
static int l_fatal_error(lua_State *L)
{
	ss_ error = lua_tocppstring(L, 1);
	log_e(MODULE, "Fatal error: %s", cs(error));
	throw Exception("Fatal error from Lua");
	return 0;
}

// get_time_us()
static int l_get_time_us(lua_State *L)
{
	lua_pushnumber(L, (double)get_timeofday_us());
	return 1;
}

// get_local_time() -> day of the year (1..366), hour, minute, second: the
// user's wall clock, which os.date would give but the sandbox leaves out
// (Lua 5.1's os.date can crash on a bad format)
static int l_get_local_time(lua_State *L)
{
	const time_t t = time(nullptr);
	struct tm tmv;
#ifdef _WIN32
	localtime_s(&tmv, &t);
#else
	localtime_r(&t, &tmv);
#endif
	lua_pushinteger(L, tmv.tm_yday + 1);
	lua_pushinteger(L, tmv.tm_hour);
	lua_pushinteger(L, tmv.tm_min);
	lua_pushinteger(L, tmv.tm_sec);
	return 4;
}

// version() -> version, git hash ([VERSION]); sandbox-safe, so a launcher
// file or a game can show what it runs on
static int l_version(lua_State *L)
{
	lua_pushstring(L, BUILDAT_VERSION);
	lua_pushstring(L, BUILDAT_GIT_HASH);
	return 2;
}

// protocol() -> the engine API, and the protocol's feature names as a set
// ([COMPAT_BREAK_07] 8a): served Lua's buildat.api and buildat.has()
static int l_protocol(lua_State *L)
{
	lua_pushinteger(L, interface::aitta::ENGINE_API);
	lua_newtable(L);
	for(const ss_ &name : interface::protocol_features()){
		lua_pushboolean(L, 1);
		lua_setfield(L, -2, name.c_str());
	}
	return 2;
}

void init_misc(lua_State *L)
{
#define DEF_BUILDAT_FUNC(name){ \
		lua_pushcfunction(L, guarded<l_##name>); \
		lua_setglobal(L, "__buildat_" #name); \
}
	DEF_BUILDAT_FUNC(print_log);
	DEF_BUILDAT_FUNC(mkdir)
	DEF_BUILDAT_FUNC(pcall)
	DEF_BUILDAT_FUNC(fatal_error)
	DEF_BUILDAT_FUNC(get_time_us)
	DEF_BUILDAT_FUNC(get_local_time)
	DEF_BUILDAT_FUNC(version)
	DEF_BUILDAT_FUNC(protocol)
}

} // namespace lua_bindingss
// vim: set noet ts=4 sw=4:
