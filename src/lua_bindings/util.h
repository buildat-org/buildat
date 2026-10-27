// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include <exception>
extern "C" {
#include <lua.h>
#include <lauxlib.h>
#if __has_include(<luajit.h>)
#include <luajit.h>
#endif
}

namespace lua_bindings
{
	sv_<ss_> dump_stack(lua_State *L);
	ss_ lua_tocppstring(lua_State *L, int index);
	ss_ lua_checkcppstring(lua_State *L, int index);
	int handle_error(lua_State *L);

	// Every binding is registered through this. A binding that lets a C++
	// exception out -- lua_tocppstring() on an argument that is not a
	// string is the everyday one -- throws it through Lua's own C frames,
	// which nothing there catches, and the process goes down on
	// std::terminate. That is reachable from sandboxed code by calling a
	// binding with the wrong kind of argument, which is to say by any
	// server a client connects to, and `extensions/sandbox_test` does it by
	// accident every time it runs.
	//
	// What comes out instead is an ordinary Lua error, which a pcall
	// catches and which says what went wrong.
	//
	// LuaJIT (x64) raises its own errors -- luaL_error() in F -- as a
	// foreign exception that catch(...) takes, and it must go on as it is
	// or its message is lost ([GUARDED_LUA_ERROR]). LuaJIT turns any other
	// non-std exception into a "C++ exception" Lua error itself. PUC Lua
	// (the web build) is compiled as C++ and raises by throwing its
	// lua_longjmp*, which the void* handler takes and passes on; as a
	// longjmp, Emscripten lost it in any C++ frame with a landing pad
	// ([WEB_LUA_ERROR_EH], Urho3D's Lua/CMakeLists.txt).
	template<lua_CFunction F>
	int guarded(lua_State *L)
	{
		// The C++ stack is unwound before lua_error() is reached, which is
		// what makes the long jump out of here safe
		try {
			return F(L);
		} catch(std::exception &e){
			lua_pushstring(L, e.what());
		} catch(void*){
			throw;
		} catch(...){
#ifdef LUAJIT_VERSION
			throw;
#else
			lua_pushstring(L, "unknown C++ exception in a binding");
#endif
		}
		return lua_error(L);
	}
}
// vim: set noet ts=4 sw=4:
