# http://www.apache.org/licenses/LICENSE-2.0
# Copyright 2014 Perttu Ahola <celeron55@gmail.com>

cmake_minimum_required(VERSION 3.2.3)
project(buildat)

#
# Global options
#

set(BUILD_SERVER TRUE CACHE BOOL "Build server")
set(BUILD_CLIENT TRUE CACHE BOOL "Build client")
set(DEBUG_LOG_TIMING FALSE CACHE BOOL "Output log messages of interesting but floody time measurements")
# Where the cache and the user's own things live. TRUE keeps both beside the
# program, in <buildat>/cache and <buildat>/user: what development wants, and
# the default. FALSE puts them where the platform says, which is what an
# installed copy wants. See doc/plan/world_persistence_plan.md.
set(PORTABLE TRUE CACHE BOOL "Keep cache/ and user/ beside the program")
# The client for a web browser, which the server serves ([WEB_CLIENT] in
# doc/plan/web_client_plan.md): configure a build directory of its own with
# emsdk's emcmake (util/build_web.sh). No server, and no runtime-compiled
# modules to share the engine and the core library with, so both are static.
# The server for the web instead ([WEB_LOCAL_SERVER]): one app's modules
# compiled ahead of time and linked into it, with pthreads, in a build
# directory of its own (util/build_web_server.sh)
set(BUILDAT_WEB_SERVER_APP "" CACHE STRING "Under emcc, build the server for this app instead of the client")
# [WEB_MESH_OFF_THREAD] The web client with pthreads, its mesh tasks on
# workers: buildat_mt.{js,wasm,data} beside the one without, which the page
# runs where it is cross-origin isolated (util/build_web.sh builds both)
set(BUILDAT_WEB_THREADS FALSE CACHE BOOL "Under emcc, the client with threads (buildat_mt)")
if(EMSCRIPTEN)
	set(BUILDAT_WEB TRUE)
	if(BUILDAT_WEB_SERVER_APP)
		set(BUILD_SERVER TRUE CACHE BOOL "Build server" FORCE)
		set(BUILD_CLIENT FALSE CACHE BOOL "Build client" FORCE)
		set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")
		set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -pthread")
	else()
		set(BUILD_SERVER FALSE CACHE BOOL "Build server" FORCE)
		if(BUILDAT_WEB_THREADS)
			set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -pthread")
			set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -pthread")
		endif()
	endif()
	# buildat throws, and Emscripten does not catch unless asked. Emscripten's
	# clang also refuses one of luabind's templates GCC takes, and its libc
	# has M_PI and the like only with _GNU_SOURCE, which g++ always defines.
	set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fexceptions -D_GNU_SOURCE -Wno-unusable-partial-specialization")
	set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fexceptions")
endif()

#
# Urho3D dependency (bundled in 3rdparty/Urho3D)
#
# 1.7.1 UrhoCommon.cmake treats CMAKE_SOURCE_DIR as the Urho tree. Do not
# include it from this file. Configure the engine as a sub-build of the Urho
# root instead of Source/.
#

set(URHO3D_BUNDLED_HOME "${CMAKE_SOURCE_DIR}/3rdparty/Urho3D")
if(NOT URHO3D_HOME)
	if(DEFINED ENV{URHO3D_HOME} AND NOT "$ENV{URHO3D_HOME}" STREQUAL "")
		set(URHO3D_HOME "$ENV{URHO3D_HOME}")
	else()
		set(URHO3D_HOME "${URHO3D_BUNDLED_HOME}")
	endif()
endif()
message(STATUS "URHO3D_HOME=\"${URHO3D_HOME}\"")
if(NOT EXISTS "${URHO3D_HOME}/CMakeLists.txt")
	message(FATAL_ERROR "Urho3D not found at URHO3D_HOME=${URHO3D_HOME}")
endif()

# SHARED is required for the module interface.
set(URHO3D_LIB_TYPE SHARED CACHE STRING "Urho3D library type (SHARED required by Buildat modules)")
set(URHO3D_LUA TRUE CACHE BOOL "Enable Urho3D Lua")
set(URHO3D_SAFE_LUA TRUE CACHE BOOL "Enable Urho3D Lua safety checks")
set(URHO3D_ANGELSCRIPT FALSE CACHE BOOL "Enable Urho3D AngelScript")
# LuaJIT is the runtime ([LUAJIT] in doc/plan/performance_plan.md); the
# server's Luanti state and the client's sandbox are one Lua build
set(URHO3D_LUAJIT TRUE CACHE BOOL "Enable Urho3D LuaJIT")
if(BUILDAT_WEB)
	# Static, wasm32, and PUC Lua: LuaJIT does not run in a browser, and the
	# engine's web build turns it off anyway. WebGL 2 ([WEB_GLES3]).
	set(URHO3D_LIB_TYPE STATIC)
	set(URHO3D_LUAJIT FALSE)
	set(URHO3D_64BIT FALSE)
endif()
if(NOT DEFINED URHO3D_64BIT)
	if(CMAKE_SIZEOF_VOID_P EQUAL 8)
		set(URHO3D_64BIT TRUE)
	else()
		set(URHO3D_64BIT FALSE)
	endif()
endif()

# A sanitizer, for chasing an intermittent crash rather than for every day:
# -DSANITIZE=address builds with AddressSanitizer, and the option is passed
# to the bundled Urho3D's own build below, because the engine is where a
# use-after-free of a scene node would be. Build it in a directory of its
# own -- Build/asan -- so that the ordinary build is untouched, and build
# and run it with ASAN_OPTIONS=detect_leaks=0:abort_on_error=1 (LuaJIT's
# build-time host tool leaks, and LeakSanitizer fails the build), a long-lived engine's
# exit leaks being what would otherwise bury the report. It costs about
# twice the CPU and three times the memory, which is why it is not the
# default. See doc/plan/master_plan.md, "Catching a use-after-free before it
# is a mystery".
set(SANITIZE "" CACHE STRING "Sanitizer to build with: address, thread or empty")
if(SANITIZE)
	set(SANITIZE_FLAGS "-fsanitize=${SANITIZE} -fno-omit-frame-pointer")
	set(COMMON_CXX_FLAGS "${COMMON_CXX_FLAGS} ${SANITIZE_FLAGS}")
	set(CMAKE_EXE_LINKER_FLAGS
			"${CMAKE_EXE_LINKER_FLAGS} ${SANITIZE_FLAGS}")
	set(CMAKE_SHARED_LINKER_FLAGS
			"${CMAKE_SHARED_LINKER_FLAGS} ${SANITIZE_FLAGS}")
	message(STATUS "Building with -fsanitize=${SANITIZE}")
	# For rccpp to build the runtime-compiled modules the same way
	add_definitions(-DBUILDAT_SANITIZE="${SANITIZE}")
endif()

# The bundled Urho3D is built in one directory, shared by every buildat
# build directory there is -- so a sanitizer build needs its own, or
# configuring one re-flags the engine for the ordinary build as well and the
# next ordinary link fails. Found the hard way.
if(SANITIZE)
	set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build-${SANITIZE}")
elseif(BUILDAT_WEB_SERVER_APP)
	# Threads: every object of a pthreads link is built with them
	set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build-webserver")
elseif(BUILDAT_WEB AND BUILDAT_WEB_THREADS)
	set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build-web-mt")
elseif(BUILDAT_WEB)
	set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build-web")
else()
	set(URHO3D_BUILD_DIR "${URHO3D_HOME}/Build")
endif()
if(BUILDAT_WEB)
	set(URHO3D_LIBRARY_FILE "${URHO3D_BUILD_DIR}/lib/libUrho3D.a")
elseif(WIN32)
	set(URHO3D_LIBRARY_FILE "${URHO3D_BUILD_DIR}/bin/Urho3D.dll")
	set(URHO3D_IMPLIB_FILE "${URHO3D_BUILD_DIR}/lib/libUrho3D.dll.a")
else()
	set(URHO3D_LIBRARY_FILE "${URHO3D_BUILD_DIR}/lib/libUrho3D${CMAKE_SHARED_LIBRARY_SUFFIX}")
endif()

# Flat includes so existing #include <Scene.h> and RCC++ modules keep working.
set(URHO3D_INCLUDE_DIRS
	"${URHO3D_HOME}/Source/Urho3D"
	"${URHO3D_BUILD_DIR}/include"
	"${URHO3D_BUILD_DIR}/include/Urho3D"
	"${URHO3D_BUILD_DIR}/include/Urho3D/ThirdParty"
	"${URHO3D_BUILD_DIR}/include/Urho3D/ThirdParty/Bullet"
	"${URHO3D_HOME}/Source/ThirdParty/toluapp/include"
)
file(GLOB URHO3D_ENGINE_SUBDIRS "${URHO3D_HOME}/Source/Urho3D/*")
foreach(URHO3D_ENGINE_SUBDIR ${URHO3D_ENGINE_SUBDIRS})
	if(IS_DIRECTORY "${URHO3D_ENGINE_SUBDIR}")
		list(APPEND URHO3D_INCLUDE_DIRS "${URHO3D_ENGINE_SUBDIR}")
	endif()
endforeach()

# ccache when it is there ([BUILD_TIME]), for this project and the engine;
# -DBUILDAT_CCACHE=OFF goes without
# simplified: not under emcc, which ccache does not know as a compiler;
# the web build goes without until it is measured to work
option(BUILDAT_CCACHE "Compile through ccache when it is found" ON)
set(BUILDAT_LAUNCHER_ARGS "")
if(BUILDAT_CCACHE AND NOT BUILDAT_WEB)
	find_program(CCACHE_PROGRAM ccache)
	if(CCACHE_PROGRAM)
		set(CMAKE_C_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
		set(CMAKE_CXX_COMPILER_LAUNCHER "${CCACHE_PROGRAM}")
		set(BUILDAT_LAUNCHER_ARGS
			"-DCMAKE_C_COMPILER_LAUNCHER=${CCACHE_PROGRAM}"
			"-DCMAKE_CXX_COMPILER_LAUNCHER=${CCACHE_PROGRAM}")
	endif()
endif()

# Build the in-tree engine as part of this project.
get_filename_component(URHO3D_HOME_ABS "${URHO3D_HOME}" ABSOLUTE)
get_filename_component(URHO3D_BUNDLED_HOME_ABS "${URHO3D_BUNDLED_HOME}" ABSOLUTE)
if(URHO3D_HOME_ABS STREQUAL URHO3D_BUNDLED_HOME_ABS)
	if(NOT CMAKE_BUILD_TYPE)
		set(CMAKE_BUILD_TYPE Debug)
	endif()
	file(MAKE_DIRECTORY "${URHO3D_BUILD_DIR}")
	set(URHO3D_CROSS_ARGS "")
	if(CMAKE_TOOLCHAIN_FILE)
		list(APPEND URHO3D_CROSS_ARGS "-DCMAKE_TOOLCHAIN_FILE=${CMAKE_TOOLCHAIN_FILE}")
	else()
		list(APPEND URHO3D_CROSS_ARGS
			"-DCMAKE_C_COMPILER=${CMAKE_C_COMPILER}"
			"-DCMAKE_CXX_COMPILER=${CMAKE_CXX_COMPILER}")
	endif()
	if(MINGW_PREFIX)
		list(APPEND URHO3D_CROSS_ARGS "-DMINGW_PREFIX=${MINGW_PREFIX}")
	endif()
	set(URHO3D_BUNDLE_CMAKE_ARGS
		-DCMAKE_BUILD_TYPE=${CMAKE_BUILD_TYPE}
		# The sanitizer as well, when there is one: the engine is where a
		# use-after-free of a scene node would be, and ASan has to be in the
		# library that owns the memory as much as in what calls it
		"-DCMAKE_CXX_FLAGS=${SANITIZE_FLAGS}"
		"-DCMAKE_C_FLAGS=${SANITIZE_FLAGS}"
		# A cross build hands the engine the same toolchain file and, for
		# Urho3D's MinGW.cmake, the tool prefix ([PACKAGING] step 3) --
		# and not the compilers, which the toolchain sets and Urho3D's
		# native-tool checks must not inherit
		${URHO3D_CROSS_ARGS}
		${BUILDAT_LAUNCHER_ARGS}
		-DURHO3D_LIB_TYPE=${URHO3D_LIB_TYPE}
		-DURHO3D_LUA=${URHO3D_LUA}
		-DURHO3D_SAFE_LUA=${URHO3D_SAFE_LUA}
		-DURHO3D_LUAJIT=${URHO3D_LUAJIT}
		-DURHO3D_ANGELSCRIPT=${URHO3D_ANGELSCRIPT}
		# generic, not Urho3D's default native: a Urho3D.dll compiled for
		# the CI runner's CPU (AVX-512) died in DllMain on any box without
		# it ([WIN_MARCH]); package.sh's guard checks the result
		-DURHO3D_DEPLOYMENT_TARGET=generic
		-DURHO3D_SAMPLES=FALSE
		-DURHO3D_TOOLS=FALSE
		-DURHO3D_EXTRAS=FALSE
		-DURHO3D_DOCS=FALSE
		-DURHO3D_DATABASE_SQLITE=FALSE
		-DURHO3D_PCH=FALSE
		-DURHO3D_64BIT=${URHO3D_64BIT}
	)
	if(BUILDAT_WEB_SERVER_APP)
		list(APPEND URHO3D_BUNDLE_CMAKE_ARGS -DURHO3D_THREADING=TRUE)
	elseif(BUILDAT_WEB)
		list(APPEND URHO3D_BUNDLE_CMAKE_ARGS -DURHO3D_GLES3=TRUE)
		if(BUILDAT_WEB_THREADS)
			list(APPEND URHO3D_BUNDLE_CMAKE_ARGS -DURHO3D_THREADING=TRUE)
		endif()
	endif()
	# Under Urho3D's MinGW toolchain the outer configure has exported the
	# cross compilers into this process's environment (the toolchain's
	# try_compile workaround), and Urho3D's own configure probes for a
	# *native* compiler with the same environment -- and finds the cross
	# one, which cannot link -rdynamic. Unset them for the child.
	set(URHO3D_CONFIGURE_ENV "")
	if(CMAKE_CROSSCOMPILING AND NOT CMAKE_HOST_WIN32 AND NOT BUILDAT_WEB)
		set(URHO3D_CONFIGURE_ENV /usr/bin/env -i "PATH=$ENV{PATH}"
			"HOME=$ENV{HOME}")
	endif()
	# Configured again only when its arguments changed ([BUILD_TIME]): a
	# stamp of them, written after a configure that worked
	set(URHO3D_CONFIGURE_STAMP_TEXT
		"${URHO3D_CONFIGURE_ENV};${CMAKE_COMMAND};${URHO3D_BUNDLE_CMAKE_ARGS};${URHO3D_HOME}")
	set(URHO3D_CONFIGURE_STAMP "${URHO3D_BUILD_DIR}/buildat_configure_stamp.txt")
	set(URHO3D_CONFIGURE_STAMP_OLD "")
	if(EXISTS "${URHO3D_CONFIGURE_STAMP}" AND
			EXISTS "${URHO3D_BUILD_DIR}/CMakeCache.txt")
		file(READ "${URHO3D_CONFIGURE_STAMP}" URHO3D_CONFIGURE_STAMP_OLD)
	endif()
	if(NOT URHO3D_CONFIGURE_STAMP_OLD STREQUAL URHO3D_CONFIGURE_STAMP_TEXT)
		file(REMOVE "${URHO3D_CONFIGURE_STAMP}")
		execute_process(
			COMMAND ${URHO3D_CONFIGURE_ENV}
				${CMAKE_COMMAND} ${URHO3D_BUNDLE_CMAKE_ARGS} "${URHO3D_HOME}"
			WORKING_DIRECTORY "${URHO3D_BUILD_DIR}"
			RESULT_VARIABLE URHO3D_CONFIGURE_RESULT
		)
		if(NOT URHO3D_CONFIGURE_RESULT EQUAL 0)
			message(FATAL_ERROR "Failed to configure bundled Urho3D")
		endif()
		file(WRITE "${URHO3D_CONFIGURE_STAMP}" "${URHO3D_CONFIGURE_STAMP_TEXT}")
	endif()
	# $(MAKE) hands the sub-build the parent make's jobserver, so the engine
	# builds with the -j the user gave and not with one of its own. Other
	# generators have no jobserver to inherit; --parallel without a number is
	# the best they can do.
	if(CMAKE_GENERATOR MATCHES "Makefiles")
		set(URHO3D_BUILD_COMMAND $(MAKE))
	else()
		set(URHO3D_BUILD_COMMAND ${CMAKE_COMMAND} --build "${URHO3D_BUILD_DIR}" --parallel)
	endif()
	# The web build's engine archive is merged again when a third-party
	# archive changed in the build just done, and the build runs once more
	# to do that; a no-op when nothing did
	set(URHO3D_POST_BUILD_COMMAND "")
	if(BUILDAT_WEB)
		set(URHO3D_POST_BUILD_COMMAND
			COMMAND ${CMAKE_COMMAND} -DDIR=${URHO3D_BUILD_DIR}
				-P ${CMAKE_SOURCE_DIR}/util/web_urho3d_stale.cmake
			COMMAND ${URHO3D_BUILD_COMMAND})
	endif()
	# Entered only when the engine's source changed or it has not been
	# built here ([BUILD_TIME]): the stamp is rewritten when the tree's
	# git id or diff changes, and the build depends on it
	set(URHO3D_SOURCE_STAMP "${URHO3D_BUILD_DIR}/buildat_source_stamp.txt")
	set(URHO3D_BUILT_STAMP "${URHO3D_BUILD_DIR}/buildat_built_stamp.txt")
	add_custom_target(urho3d_source
		COMMAND ${CMAKE_COMMAND} -DSRC=${CMAKE_SOURCE_DIR}
			-DOUT=${URHO3D_SOURCE_STAMP}
			-P ${CMAKE_SOURCE_DIR}/util/urho3d_stamp.cmake
		BYPRODUCTS "${URHO3D_SOURCE_STAMP}"
	)
	add_custom_command(OUTPUT "${URHO3D_BUILT_STAMP}"
		COMMAND ${URHO3D_BUILD_COMMAND}
		${URHO3D_POST_BUILD_COMMAND}
		COMMAND ${CMAKE_COMMAND} -E touch "${URHO3D_BUILT_STAMP}"
		DEPENDS "${URHO3D_SOURCE_STAMP}"
		WORKING_DIRECTORY "${URHO3D_BUILD_DIR}"
		COMMENT "Building bundled Urho3D"
	)
	add_custom_target(urho3d_build DEPENDS "${URHO3D_BUILT_STAMP}")
	add_dependencies(urho3d_build urho3d_source)
endif()

if(NOT TARGET Urho3D AND BUILDAT_WEB)
	add_library(Urho3D STATIC IMPORTED GLOBAL)
	set_target_properties(Urho3D PROPERTIES
		IMPORTED_LOCATION "${URHO3D_LIBRARY_FILE}")
endif()
if(NOT TARGET Urho3D)
	add_library(Urho3D SHARED IMPORTED GLOBAL)
	set_target_properties(Urho3D PROPERTIES
		IMPORTED_LOCATION "${URHO3D_LIBRARY_FILE}")
	if(WIN32)
		set_target_properties(Urho3D PROPERTIES
			IMPORTED_IMPLIB "${URHO3D_IMPLIB_FILE}")
	endif()
endif()

# SYSTEM gets rid of annoying warnings that we're not going to fix
include_directories(SYSTEM ${URHO3D_INCLUDE_DIRS})
if(NOT WIN32)
	set(CMAKE_BUILD_WITH_INSTALL_RPATH TRUE)
	set(CMAKE_INSTALL_RPATH "\$ORIGIN/../lib;${URHO3D_BUILD_DIR}/lib")
endif()

# Urho3D's Lua (luabind needs the headers and a Lua archive)
set(LUA_FOUND true)
if(URHO3D_LUAJIT)
	set(LUA_INCLUDE_DIRS "${URHO3D_HOME}/Source/ThirdParty/LuaJIT/src")
	set(LUA_LIBRARY "${URHO3D_BUILD_DIR}/Source/ThirdParty/LuaJIT/libLuaJIT.a")
	set(BUILDAT_LUA_DIR "LuaJIT")
else()
	set(LUA_INCLUDE_DIRS "${URHO3D_HOME}/Source/ThirdParty/Lua/src")
	set(LUA_LIBRARY "${URHO3D_BUILD_DIR}/Source/ThirdParty/Lua/libLua.a")
	set(BUILDAT_LUA_DIR "Lua")
endif()
# Where the engine's Lua headers are installed under Build/include, for the
# server to hand to the modules it compiles at run time
add_definitions(-DBUILDAT_LUA_DIR="${BUILDAT_LUA_DIR}")
if(WIN32)
	set(LUA_LIBRARIES ${LUA_LIBRARY})
	message(STATUS "LUA_LIBRARIES=${LUA_LIBRARIES}")
endif()
include_directories(${LUA_INCLUDE_DIRS})
set(URHO3D_TOLUA_LIBRARY "${URHO3D_BUILD_DIR}/Source/ThirdParty/toluapp/src/lib/libtoluapp.a")
if(BUILDAT_WEB)
	# The static engine archive carries Lua and tolua++ already
	set(LUA_LIBRARY "")
	set(URHO3D_TOLUA_LIBRARY "")
endif()

#
# Bundled libraries
#

add_subdirectory("3rdparty/cereal")
add_subdirectory("3rdparty/c55lib")
add_subdirectory("3rdparty/smallsha1")
add_subdirectory("3rdparty/polyvox")
add_subdirectory("3rdparty/zlib")
add_subdirectory("3rdparty/zstd")
add_subdirectory("3rdparty/mbedtls")
add_subdirectory("3rdparty/qrcodegen")
add_subdirectory("3rdparty/sqlite")
add_subdirectory("3rdparty/md4c")
add_subdirectory("3rdparty/luabind-deboostified")
# [CLIENT_WASM] the validator and wasm2c, for the client and the server
# ([SERVER_WASM]: src/wasm/engine.cpp; in the browser's server the
# validator only, [WEB_LOCAL_AITTA])
if(BUILD_CLIENT OR BUILD_SERVER)
	add_subdirectory("3rdparty/wabt")
	# and the interpreter, natively on Linux and Windows
	if((CMAKE_SYSTEM_NAME STREQUAL "Linux" OR WIN32) AND NOT EMSCRIPTEN)
		add_subdirectory("3rdparty/wamr")
	endif()
endif()

include_directories("src")
include_directories("3rdparty/cereal/include")
include_directories("3rdparty/c55lib")
include_directories("3rdparty/smallsha1")
include_directories("3rdparty/polyvox/library/PolyVoxCore/include")
include_directories("3rdparty/zlib")
include_directories("${CMAKE_BINARY_DIR}/3rdparty/zlib")
include_directories("3rdparty/zstd/lib")
include_directories("3rdparty/sqlite/src")
include_directories("3rdparty/md4c")
# SYSTEM gets rid of annoying warnings that we're not going to fix
include_directories(SYSTEM "3rdparty/luabind-deboostified")

#
# Buildat
#

if(DEBUG_LOG_TIMING)
	set(COMMON_CXX_FLAGS "${COMMON_CXX_FLAGS} -DDEBUG_LOG_TIMING")
endif()
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -std=c++0x -Wall")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -Wextra -Wno-unused-parameter")
set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} ${COMMON_CXX_FLAGS}")
#set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O0 -Wall")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} -std=c++0x -g -O1 -Wall")
set(CMAKE_CXX_FLAGS_DEBUG "${CMAKE_CXX_FLAGS_DEBUG} ${COMMON_CXX_FLAGS}")
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin") # Executables
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib") # Shared libs
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib") # Static libs

# Always output in color (useful when using head for build output)
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fdiagnostics-color=always")
# Security / crash protection
#set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fstack-protector-all")

set(BUILDAT_CORE_NAME buildat_core)
# The client *is* buildat: it shows the launch menu, starts a local server for
# a game and connects to a remote one. There used to be a separate `buildat`
# launcher that did nothing but exec `buildat_client -m launch_menu`, and two
# launch menus with it.
set(CLIENT_EXE_NAME buildat)
set(SERVER_EXE_NAME buildat_server)

#
# Core library - shared code between executables and modules
#

set(BUILDAT_CORE_SRCS
	src/core/log.cpp
	src/core/json.cpp
	src/boot/autodetect.cpp
	src/impl/fs.cpp
	src/impl/event.cpp
	src/impl/tcpsocket.cpp
	src/impl/module.cpp
	src/impl/sha1.cpp
	src/impl/markup.cpp
	src/impl/sha256.cpp
	src/impl/bignum.cpp
	src/impl/packet_stream.cpp
	src/impl/mesh.cpp
	src/impl/atlas.cpp
	src/impl/voxel.cpp
	src/impl/voxel_volume.cpp
	src/impl/voxel_path.cpp
	src/impl/compress.cpp
	src/impl/zip.cpp
	src/impl/aitta.cpp
	src/impl/http.cpp
	src/impl/thread_pool.cpp
	src/impl/thread.cpp
	src/impl/magic_event_handler.cpp
)
if(WIN32)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/file_watch.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/process.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/debug.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/os.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/windows/fs.cpp)
else()
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/file_watch.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/process.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/debug.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/os.cpp)
	set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} src/impl/linux/fs.cpp)
endif()
# Read in autodetect.cpp only: on that file alone, so the package's
# portable tree and its xdg tree share every other object in ccache
# ([REWORK_1019_PERF] build 5)
if(PORTABLE)
	set_source_files_properties(src/boot/autodetect.cpp PROPERTIES
		COMPILE_DEFINITIONS BUILDAT_PORTABLE)
endif()
# The version and the git hash, generated into a source of the core library
# at configure and again on every build ([VERSION]); see util/version.cmake
set(BUILDAT_VERSION_CPP ${CMAKE_BINARY_DIR}/buildat_version.cpp)
execute_process(COMMAND ${CMAKE_COMMAND}
	-DSRC=${CMAKE_SOURCE_DIR} -DOUT=${BUILDAT_VERSION_CPP}
	-P ${CMAKE_SOURCE_DIR}/util/version.cmake)
add_custom_target(buildat_version ALL
	COMMAND ${CMAKE_COMMAND}
		-DSRC=${CMAKE_SOURCE_DIR} -DOUT=${BUILDAT_VERSION_CPP}
		-P ${CMAKE_SOURCE_DIR}/util/version.cmake
	BYPRODUCTS ${BUILDAT_VERSION_CPP}
	COMMENT "Reading the version and the git hash")
# VERSION is not a configure dependency: the target reads it every build
# ([BUILD_TIME]; a bump re-ran this configure and Urho3D's)
set(BUILDAT_CORE_SRCS ${BUILDAT_CORE_SRCS} ${BUILDAT_VERSION_CPP})
# sqlite's objects rather than a library: builtin/storage is a runtime-compiled
# module and cannot link one, so buildat_core is what exports sqlite3_* to it.
if(BUILDAT_WEB)
	# No libcurl in a browser: interface/http.h is a stub that throws there,
	# and a browser has no inotify, execinfo or signals
	list(REMOVE_ITEM BUILDAT_CORE_SRCS src/impl/http.cpp
		src/impl/linux/file_watch.cpp src/impl/linux/debug.cpp)
	list(APPEND BUILDAT_CORE_SRCS src/impl/web/http.cpp
		src/impl/web/file_watch.cpp src/impl/web/debug.cpp)
	set(BUILDAT_CORE_TYPE STATIC)
else()
	set(BUILDAT_CORE_TYPE SHARED)
endif()
add_library(${BUILDAT_CORE_NAME} ${BUILDAT_CORE_TYPE} ${BUILDAT_CORE_SRCS}
	$<TARGET_OBJECTS:sqlite> $<TARGET_OBJECTS:md4c>)
add_dependencies(${BUILDAT_CORE_NAME} buildat_version)
# libcurl, required ([CONTENTDB]): ContentDB is HTTPS only and the tree has
# no TLS of its own. The system's on Linux; on the mingw cross build a
# static libcurl.a built in the image with the same toolchain
# (util/docker/windows, schannel), CURL_INCLUDE_DIR and CURL_LIBRARY
# passed by util/package.sh -- no DLL, no second C runtime in the
# process ([WIN_DLL_INIT]).
if(NOT BUILDAT_WEB)
	find_package(CURL REQUIRED)
endif()
target_include_directories(${BUILDAT_CORE_NAME} PRIVATE ${CURL_INCLUDE_DIRS})
target_link_libraries(${BUILDAT_CORE_NAME}
	c55lib
	smallsha1
	PolyVoxCore
	zlib
	zstd
	mbedtls
	${CURL_LIBRARIES}
)
# Mbed TLS for the Aitta signatures ([AITTA_MVP]) stays inside the core
# library: exported from it, the client's own static copy is a second
# definition of every symbol to mingw's linker
if(NOT BUILDAT_WEB)
	set_property(TARGET ${BUILDAT_CORE_NAME} APPEND_STRING PROPERTY
		LINK_FLAGS " -Wl,--exclude-libs,libmbedtls.a")
endif()
if(WIN32)
	target_compile_definitions(${BUILDAT_CORE_NAME} PRIVATE CURL_STATICLIB)
	# libcurl.pc's Libs.private for the schannel build
	target_link_libraries(${BUILDAT_CORE_NAME}
		secur32 bcrypt advapi32 crypt32 ws2_32 iphlpapi)
endif()
if(NOT WIN32)
	find_package(Threads REQUIRED)
	target_link_libraries(${BUILDAT_CORE_NAME}
		${CMAKE_THREAD_LIBS_INIT}
		${CMAKE_DL_LIBS}
	)
endif()
if(WIN32)
	target_link_libraries(${BUILDAT_CORE_NAME}
		wsock32
		ws2_32
		psapi # Process stuff
		shell32 # ShellExecute
		Urho3D
	)
endif()

#
# Client
#

# The Windows executables' icon, manifest and version info ([WIN_RESOURCES])
if(WIN32)
	enable_language(RC)
	file(STRINGS ${CMAKE_SOURCE_DIR}/VERSION BUILDAT_VERSION_TEXT LIMIT_COUNT 1)
	string(REPLACE "." "," BUILDAT_RC_VERSION ${BUILDAT_VERSION_TEXT})
	set(BUILDAT_RC_DIR ${CMAKE_SOURCE_DIR})
	set(BUILDAT_RC ${CMAKE_BINARY_DIR}/buildat.rc)
	configure_file(util/windows/buildat.rc.in ${BUILDAT_RC} @ONLY)
endif()

if(BUILD_CLIENT)
	set(CLIENT_SRCS
		src/client/main.cpp
		src/client/state.cpp
		src/client/wss.cpp
		src/client/pipe_stream.cpp
		src/client/app.cpp
		src/client/config.cpp
		src/client/command_seq.cpp
		src/lua_bindings/util.cpp
		src/lua_bindings/init.cpp
		src/lua_bindings/misc.cpp
		src/lua_bindings/cereal.cpp
		src/lua_bindings/voxel.cpp
		src/lua_bindings/atlas.cpp
		src/lua_bindings/mesh.cpp
		src/lua_bindings/voxel_volume.cpp
		src/lua_bindings/voxel_data.cpp
	src/lua_bindings/image.cpp
		src/lua_bindings/spatial_update_queue.cpp
		src/lua_bindings/misc_urho3d.cpp
		src/lua_bindings/network.cpp
		src/lua_bindings/crypto.cpp
		src/lua_bindings/compress.cpp
		src/lua_bindings/replicate.cpp
		src/lua_bindings/synth.cpp
		src/lua_bindings/wasm.cpp
		src/wasm/engine.cpp
		# [WASM_MAIN_WEB_PATHS] a serverless app's .wasm (app::serverless_wasms)
		src/server/wasm_build.cpp
	)
	# [CLIENT_WASM] wasm2c's runtime, linked in whole on Linux, and the
	# files the client writes beside the C it compiles
	if(TARGET wasm_rt)
		list(APPEND CLIENT_SRCS $<TARGET_OBJECTS:wasm_rt>)
	endif()
	if(TARGET wasm_rt_files)
		list(APPEND CLIENT_SRCS $<TARGET_OBJECTS:wasm_rt_files>)
	endif()

	if(WIN32)
		list(APPEND CLIENT_SRCS ${BUILDAT_RC})
	endif()
	# [SYNTH_BLOCKS]: the same samples on every platform, so no fused
	# multiply-add where the source has a multiply and an add
	set_source_files_properties(src/lua_bindings/synth.cpp PROPERTIES
			COMPILE_OPTIONS "-ffp-contract=off")
	# [CLIENT_WASM] WABT's headers are C++20
	set_source_files_properties(src/lua_bindings/wasm.cpp src/wasm/engine.cpp
			PROPERTIES COMPILE_OPTIONS "-std=c++20")
	add_executable(${CLIENT_EXE_NAME} ${CLIENT_SRCS})
	# A GUI executable on Windows ([WIN8_START] 19): no console window,
	# whose synchronous writes made the client pay a console write per
	# log line. A shell start attaches to the shell's console at boot
	# (boot/basic_init.h) so -c runs and --help still print there.
	if(WIN32)
		set_target_properties(${CLIENT_EXE_NAME} PROPERTIES WIN32_EXECUTABLE TRUE)
		# The boxed local server's pipe ([PROCESS_SANDBOX]): its container's SID
		target_link_libraries(${CLIENT_EXE_NAME} userenv)
	endif()

	target_link_libraries(${CLIENT_EXE_NAME}
		${BUILDAT_CORE_NAME}
		c55lib
		smallsha1
		PolyVoxCore
		zlib
		zstd
		mbedtls
		qrcodegen
		wabt
		luabind
		Urho3D
		${URHO3D_TOLUA_LIBRARY}
		${LUA_LIBRARY}
	)
	# [CLIENT_WASM] The interpreter (step 4)
	if(TARGET wamr)
		target_link_libraries(${CLIENT_EXE_NAME} wamr)
	endif()
	# [CLIENT_WASM] The modules the client builds call the runtime in it
	if(TARGET wasm_rt)
		target_include_directories(${CLIENT_EXE_NAME} PRIVATE
			${CMAKE_SOURCE_DIR}/3rdparty/wabt/wasm2c)
		target_compile_definitions(${CLIENT_EXE_NAME} PRIVATE
			WASM_RT_SKIP_SIGNAL_RECOVERY=1 WASM_RT_STACK_DEPTH_COUNT=1)
		target_link_options(${CLIENT_EXE_NAME} PRIVATE
			-Wl,--dynamic-list=${CMAKE_SOURCE_DIR}/3rdparty/wabt/wasm_rt.dynlist)
	endif()
	# [CLIENT_WASM_WINDOWS] On Windows each module's DLL has the runtime in
	# it, and the client reads its types only (the memory's); the main
	# thread's stack is Linux's 8 MiB, which the modules' call depth of 2000
	# is counted against (src/lua_bindings/wasm.cpp)
	if(WIN32 AND TARGET wasm_rt_files)
		target_include_directories(${CLIENT_EXE_NAME} PRIVATE
			${CMAKE_SOURCE_DIR}/3rdparty/wabt/wasm2c)
		target_compile_definitions(${CLIENT_EXE_NAME} PRIVATE
			WASM_RT_MEMCHECK_BOUNDS_CHECK=1 WASM_RT_STACK_DEPTH_COUNT=1)
		target_link_options(${CLIENT_EXE_NAME} PRIVATE -Wl,--stack,8388608)
	endif()
	#if(NOT WIN32)
	#	target_link_libraries(${CLIENT_EXE_NAME}
	#		${LUA_LIBRARY}
	#	)
	#endif()

	# The web client ([WEB_CLIENT]): buildat.js, .wasm and .data, and the
	# page that starts them, in the directory the server serves them from
	# (web_client_path; <share_path>/web by default)
	if(BUILDAT_WEB)
		set(BUILDAT_WEB_OUTPUT "${CMAKE_SOURCE_DIR}/web" CACHE PATH
			"Where the web client is written, for the server to serve")
		set_target_properties(${CLIENT_EXE_NAME} PROPERTIES
			RUNTIME_OUTPUT_DIRECTORY "${BUILDAT_WEB_OUTPUT}")
		# What the client reads from its share and Urho3D paths, in the
		# browser's file system where the page's -P and -U point
		set(WEB_PRELOAD
			"${CMAKE_SOURCE_DIR}/client@/buildat/client"
			"${CMAKE_SOURCE_DIR}/extensions@/buildat/extensions"
			"${CMAKE_SOURCE_DIR}/builtin/luanti/client_data@/buildat/builtin/luanti/client_data"
			"${CMAKE_SOURCE_DIR}/builtin/voxel_shading/client_data@/buildat/builtin/voxel_shading/client_data"
			# A serverless app's default client_main ([WASM_MAIN_WEB_PATHS])
			"${CMAKE_SOURCE_DIR}/builtin/client_lua/client_lua/wasm_main.lua@/buildat/builtin/client_lua/client_lua/wasm_main.lua"
			"${URHO3D_HOME}/bin/CoreData@/urho/bin/CoreData"
			"${URHO3D_HOME}/bin/Data@/urho/bin/Data"
		)
		set(WEB_LINK_FLAGS
			-fexceptions
			-sMIN_WEBGL_VERSION=2 -sMAX_WEBGL_VERSION=2 -sFULL_ES3=1
			-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=268435456
			# luabind and the Lua VM recurse deeper than the 64 KiB default
			-sSTACK_SIZE=8388608
			-sFORCE_FILESYSTEM=1
			# IndexedDB for the cache and the user directory ([WEB_PERSIST])
			-lidbfs.js
			-sEXIT_RUNTIME=0
			# What an uncaught exception or an abort was, in the console
			-sASSERTIONS=1 -sEXCEPTION_STACK_TRACES=1
			# Function names in the stack of a crash
			--profiling-funcs
			-sDISABLE_DEPRECATED_FIND_EVENT_TARGET_BEHAVIOR=0
			"-sEXPORTED_RUNTIME_METHODS=['FS','ENV','callMain','UTF8ToString','stringToNewUTF8','addRunDependency','removeRunDependency']"
			"SHELL:--exclude-file *.swp"
		)
		# SHELL: keeps each pair whole; CMake would merge the repeated flags
		foreach(P ${WEB_PRELOAD})
			list(APPEND WEB_LINK_FLAGS "SHELL:--preload-file ${P}")
		endforeach()
		if(BUILDAT_WEB_THREADS)
			set_target_properties(${CLIENT_EXE_NAME} PROPERTIES
				OUTPUT_NAME ${CLIENT_EXE_NAME}_mt)
			list(APPEND WEB_LINK_FLAGS
				-pthread
				# The workers the pool's threads run on, made before main():
				# as many as the page found cores for (index.html)
				-sPTHREAD_POOL_SIZE=Module.buildatThreads
				# A mesh task's stack is a native thread's in miniature
				-sDEFAULT_PTHREAD_STACK_SIZE=2097152
				# The page makes the shared memory itself, the largest
				# maximum the browser grants under this (index.html)
				-sMAXIMUM_MEMORY=2147483648
			)
		endif()
		target_link_options(${CLIENT_EXE_NAME} PRIVATE ${WEB_LINK_FLAGS})
		# An imported archive is no dependency of the link by itself
		set_property(TARGET ${CLIENT_EXE_NAME} APPEND PROPERTY
			LINK_DEPENDS "${URHO3D_LIBRARY_FILE}")
		# The preloaded files are packed at the link: a change to one links
		# again, and a file added or removed is seen by CONFIGURE_DEPENDS
		foreach(P ${WEB_PRELOAD})
			string(REGEX REPLACE "@.*" "" P_DIR "${P}")
			file(GLOB_RECURSE P_FILES CONFIGURE_DEPENDS "${P_DIR}/*")
			list(FILTER P_FILES EXCLUDE REGEX "\\.swp$")
			set_property(TARGET ${CLIENT_EXE_NAME} APPEND PROPERTY
				LINK_DEPENDS ${P_FILES})
		endforeach()
		configure_file("${CMAKE_SOURCE_DIR}/src/client/web/index.html"
			"${BUILDAT_WEB_OUTPUT}/index.html" COPYONLY)
	endif()

endif(BUILD_CLIENT)

#
# Server
#

if(BUILD_SERVER)
	set(SERVER_SRCS
		src/server/main.cpp
		src/server/state.cpp
		src/server/rccpp.cpp
		src/server/config.cpp
		src/server/rccpp_util.cpp
		src/server/confine.cpp
		src/server/confine_windows.cpp
		src/server/wasm_build.cpp
	)
	# [SERVER_WASM] a module that is a .wasm, on the client's runtime; in
	# the browser's server on the browser's own wasm ([WEB_LOCAL_AITTA])
	list(APPEND SERVER_SRCS src/wasm/engine.cpp src/server/wasm_module.cpp)
	if(TARGET wasm_rt_files)
		list(APPEND SERVER_SRCS $<TARGET_OBJECTS:wasm_rt_files>)
	endif()
	if(TARGET wasm_rt)
		list(APPEND SERVER_SRCS $<TARGET_OBJECTS:wasm_rt>)
	endif()
	set_source_files_properties(src/wasm/engine.cpp PROPERTIES
			COMPILE_OPTIONS "-std=c++20")
	# The builtins' interfaces (network/api.h) it reaches modules through
	set_source_files_properties(src/server/wasm_module.cpp PROPERTIES
			INCLUDE_DIRECTORIES "${CMAKE_SOURCE_DIR}/builtin")
	if(WIN32)
		list(APPEND SERVER_SRCS ${BUILDAT_RC})
	endif()
	add_executable(${SERVER_EXE_NAME} ${SERVER_SRCS})
	target_link_libraries(${SERVER_EXE_NAME} wabt)
	if(NOT EMSCRIPTEN)
		if(TARGET wamr)
			target_link_libraries(${SERVER_EXE_NAME} wamr)
		endif()
		target_include_directories(${SERVER_EXE_NAME} PRIVATE
			${CMAKE_SOURCE_DIR}/3rdparty/wabt/wasm2c)
		if(TARGET wasm_rt)
			# The modules it builds call the runtime in it (as the client's)
			target_compile_definitions(${SERVER_EXE_NAME} PRIVATE
				WASM_RT_SKIP_SIGNAL_RECOVERY=1 WASM_RT_STACK_DEPTH_COUNT=1)
			target_link_options(${SERVER_EXE_NAME} PRIVATE
				-Wl,--dynamic-list=${CMAKE_SOURCE_DIR}/3rdparty/wabt/wasm_rt.dynlist)
		elseif(WIN32)
			target_compile_definitions(${SERVER_EXE_NAME} PRIVATE
				WASM_RT_MEMCHECK_BOUNDS_CHECK=1 WASM_RT_STACK_DEPTH_COUNT=1)
		endif()
	endif()
	if(WIN32)
		target_compile_definitions(${SERVER_EXE_NAME} PRIVATE
			$<$<COMPILE_LANGUAGE:RC>:BUILDAT_SERVER_EXE>)
	endif()

	target_link_libraries(${SERVER_EXE_NAME}
		${BUILDAT_CORE_NAME}
		c55lib
		smallsha1
		Urho3D
	)
	if(WIN32)
		# The box ([PROCESS_SANDBOX]): AppContainer profiles
		target_link_libraries(${SERVER_EXE_NAME} userenv)
	else()
		target_link_libraries(${SERVER_EXE_NAME} dl)
	endif()
	if(BUILDAT_WEB_SERVER_APP)
		include(util/web_server.cmake)
	endif()
endif(BUILD_SERVER)

if(TARGET urho3d_build)
	# The core links against the engine too, and under -j it reached the
	# import library before the engine's build had made it
	add_dependencies(${BUILDAT_CORE_NAME} urho3d_build)
	if(BUILD_CLIENT)
		add_dependencies(${CLIENT_EXE_NAME} urho3d_build)
	endif()
	if(BUILD_SERVER)
		add_dependencies(${SERVER_EXE_NAME} urho3d_build)
	endif()
endif()

#
# Installation
#
# The archive's layout, one for every platform ([PACKAGING]): bin/ with the
# programs (and lib/ with the shared libraries on Linux, found through
# RPATH), buildat's own trees at the root as the share path, src/ and the
# headers that run-time compilation reads, Urho3D's sources and data, and
# on Windows the MinGW-w64 tree under compiler/ -- Linux uses the system
# compiler. util/package.sh runs this into a staging directory and makes
# the archive.

if(WIN32)
	set(DST_BIN "bin")
	set(DST_LIB "bin")
else()
	set(DST_BIN "bin")
	set(DST_LIB "lib")
endif()
set(DST_SHARE ".")
set(DST_COMPILER "${DST_SHARE}/compiler")

install(DIRECTORY "${CMAKE_SOURCE_DIR}/doc" DESTINATION "."
	PATTERN "plan" EXCLUDE)
install(FILES "${CMAKE_SOURCE_DIR}/NOTICE" DESTINATION ".")
install(FILES "${CMAKE_SOURCE_DIR}/README.md" DESTINATION ".")

install(TARGETS ${BUILDAT_CORE_NAME} DESTINATION "${DST_LIB}")
if(WIN32)
	install(FILES "${URHO3D_LIBRARY_FILE}" DESTINATION "${DST_LIB}")
	# [SEC_WIN_NET]: an administrator's step that gives the sandboxes Linux's ports
	install(FILES "${CMAKE_SOURCE_DIR}/util/windows/sandbox_firewall.ps1"
		DESTINATION "${DST_BIN}")
else()
	# libUrho3D.so is a symlink chain to libUrho3D.so.0.1.x: the real
	# file and the links with it, or the archive links to nothing
	get_filename_component(URHO3D_LIBRARY_DIR "${URHO3D_LIBRARY_FILE}" DIRECTORY)
	install(DIRECTORY "${URHO3D_LIBRARY_DIR}/" DESTINATION "${DST_LIB}"
		FILES_MATCHING PATTERN "libUrho3D.so*")
endif()
if(WIN32)
	# The compiler the Windows archive ships under compiler/ is a native
	# MinGW-w64 distribution, not the cross toolchain that built the
	# binaries (a Linux program): BUILDAT_SHIP_COMPILER names its mingw64
	# root, which util/docker/windows unpacks from a pinned winlibs release
	# ([PACKAGING] step 3). The runtime DLLs beside the executables come
	# from the same tree, so the modules it compiles and the binaries it
	# is shipped with run on one libstdc++.
	set(BUILDAT_SHIP_COMPILER "" CACHE PATH
		"A native MinGW-w64 tree (mingw64/) to ship under compiler/ on Windows")
	if(NOT BUILDAT_SHIP_COMPILER)
		message(WARNING "BUILDAT_SHIP_COMPILER is not set: the archive will "
			"carry no compiler and its server cannot build a module")
	endif()
	# Where the three runtime DLLs beside the executables come from
	# ([WIN_DLL_INIT]): "winlibs", the shipped compiler's (one libstdc++
	# for the binaries and the modules it compiles); "toolchain", the
	# cross toolchain's own that built the binaries. Not a static one:
	# a static libgcc in two DLLs that export everything defines
	# _Unwind_Resume twice, the toolchain's libgcc_s itself imports
	# winpthread, and g++'s own -lpthread comes after any -Bstatic.
	set(BUILDAT_RUNTIME_DLLS "winlibs" CACHE STRING
		"Source of the runtime DLLs: winlibs or toolchain")
	if(BUILDAT_RUNTIME_DLLS STREQUAL "winlibs" AND BUILDAT_SHIP_COMPILER)
		foreach(DLL libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll)
			install(FILES "${BUILDAT_SHIP_COMPILER}/bin/${DLL}" DESTINATION "${DST_BIN}")
		endforeach()
	elseif(BUILDAT_RUNTIME_DLLS STREQUAL "toolchain")
		foreach(DLL libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll)
			# The compiler's own copy: what -print-file-name resolves
			execute_process(COMMAND "${CMAKE_CXX_COMPILER}" -print-file-name=${DLL}
				OUTPUT_VARIABLE DLL_PATH OUTPUT_STRIP_TRAILING_WHITESPACE)
			if(NOT IS_ABSOLUTE "${DLL_PATH}")
				message(FATAL_ERROR "runtime DLL ${DLL} not found by ${CMAKE_CXX_COMPILER}")
			endif()
			install(FILES "${DLL_PATH}" DESTINATION "${DST_BIN}")
		endforeach()
	endif()
endif()
if(WIN32)
	# The DLL load probe, shipped beside the DLLs ([WIN_DLL_INIT]): plain
	# C, its runtime static, so it imports nothing the archive ships
	add_executable(loadprobe util/loadprobe.c)
	target_link_options(loadprobe PRIVATE -static)
	install(TARGETS loadprobe DESTINATION "${DST_BIN}")
endif()
if(NOT CMAKE_CROSSCOMPILING)
	# [WEB_ID_NO_EXT]: client-side Lua runs on LuaJIT natively and on PUC
	# Lua 5.1 in the web build, which cannot parse `goto` and the like.
	# A host luac from Urho3D's own Lua 5.1 parses each client-side file,
	# and a file it cannot parse fails the build with its file and line.
	# simplified: syntax only; a LuaJIT-only library (`bit`) still fails
	# at run time on the web
	set(LUA51_SRC "${URHO3D_BUNDLED_HOME}/Source/ThirdParty/Lua/src")
	file(GLOB LUAC51_SRCS "${LUA51_SRC}/*.c")
	foreach(f lua linit lbaselib ldblib liolib lmathlib loadlib loslib
			lstrlib ltablib)
		list(REMOVE_ITEM LUAC51_SRCS "${LUA51_SRC}/${f}.c")
	endforeach()
	add_executable(luac51 ${LUAC51_SRCS})
	if(NOT WIN32)
		target_link_libraries(luac51 m)
	endif()
	file(GLOB_RECURSE CLIENT_SIDE_LUA CONFIGURE_DEPENDS
		"${CMAKE_SOURCE_DIR}/client/*.lua"
		"${CMAKE_SOURCE_DIR}/extensions/*.lua"
		"${CMAKE_SOURCE_DIR}/builtin/*.lua" "${CMAKE_SOURCE_DIR}/apps/*.lua")
	list(FILTER CLIENT_SIDE_LUA INCLUDE REGEX
		"/(client|extensions)/|/client_lua/")
	# The files to a script as one argument
	string(JOIN "|" CLIENT_SIDE_LUA_ARG ${CLIENT_SIDE_LUA})
	set(LUA51_STAMP "${CMAKE_BINARY_DIR}/lua51_parse.stamp")
	add_custom_command(OUTPUT "${LUA51_STAMP}"
		COMMAND luac51 -p ${CLIENT_SIDE_LUA}
		# [LUA51_ESCAPES]: what Lua 5.1 parses but reads otherwise
		COMMAND ${CMAKE_COMMAND} "-DFILES=${CLIENT_SIDE_LUA_ARG}"
			-P "${CMAKE_SOURCE_DIR}/util/lua51_escapes.cmake"
		COMMAND ${CMAKE_COMMAND} -E touch "${LUA51_STAMP}"
		DEPENDS luac51 ${CLIENT_SIDE_LUA}
			"${CMAKE_SOURCE_DIR}/util/lua51_escapes.cmake"
		COMMENT "Parsing the client-side Lua as Lua 5.1 (the web build's)"
		VERBATIM)
	add_custom_target(lua51_parse ALL DEPENDS "${LUA51_STAMP}")
endif()
if(BUILD_CLIENT)
	install(TARGETS ${CLIENT_EXE_NAME} buildat DESTINATION "${DST_BIN}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/client" DESTINATION "${DST_SHARE}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/extensions" DESTINATION "${DST_SHARE}")
endif()
if(BUILD_SERVER)
	install(TARGETS ${SERVER_EXE_NAME} DESTINATION "${DST_BIN}")
	# Aitta parses a release's client Lua with it ([AITTA_LUA51])
	if(TARGET luac51)
		install(TARGETS luac51 DESTINATION "${DST_BIN}")
	endif()
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/builtin" DESTINATION "${DST_SHARE}")
	# The font and the logo an app's HTML is served with ([HTML_BRAND],
	# src/interface/web_brand.h), in a server build without the client too
	install(FILES "${CMAKE_SOURCE_DIR}/client/data/buildat_logo.png"
		DESTINATION "${DST_SHARE}/client/data")
	install(FILES "${CMAKE_SOURCE_DIR}/client/data/Fonts/Overpass-Regular.ttf"
		"${CMAKE_SOURCE_DIR}/client/data/Fonts/OverpassMono-Regular.ttf"
		DESTINATION "${DST_SHARE}/client/data/Fonts")
	# BUILDAT_LUANTI_ONLY ([LUANTI_BUILD]): the "Luanti only" archive --
	# apps/vanilla and no other app, and no compiler; its modules come
	# prebuilt in its cache (util/package.sh copies them from the full
	# archive's stage). A reconfigure of the same build tree, not a
	# rebuild: the option only changes what is installed.
	option(BUILDAT_LUANTI_ONLY "Install apps/vanilla alone and no compiler" FALSE)
	if(BUILDAT_LUANTI_ONLY)
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/apps/vanilla" DESTINATION "${DST_SHARE}/apps")
	else()
		install(DIRECTORY "${CMAKE_SOURCE_DIR}/apps" DESTINATION "${DST_SHARE}")
	endif()
	# The web client the server serves ([WEB_CLIENT]), when util/build_web.sh
	# has made one: its default web_client_path is <share_path>/web
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/web" DESTINATION "${DST_SHARE}"
		OPTIONAL)
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/src" DESTINATION "${DST_SHARE}")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/3rdparty/cereal/include" DESTINATION "${DST_SHARE}/3rdparty/cereal")
	install(DIRECTORY "${CMAKE_SOURCE_DIR}/3rdparty/polyvox/library/PolyVoxCore/include" DESTINATION "${DST_SHARE}/3rdparty/polyvox/library/PolyVoxCore")
	install(FILES "${CMAKE_SOURCE_DIR}/3rdparty/sqlite/src/sqlite3.h"
		DESTINATION "${DST_SHARE}/3rdparty/sqlite/src")
	install(DIRECTORY "${URHO3D_HOME}/Source" DESTINATION "${DST_SHARE}/Urho3D")
	# The whole generated include tree, not Urho3D.h alone: a module's
	# <lua.h> comes from Build/include/Urho3D/ThirdParty/<Lua>, which the
	# server adds to the module compiler's paths
	# Dereferenced: Urho3D's build makes that tree of symlinks into its
	# source and build directories, absolute, which in an archive point
	# at the machine that built it ([PACKAGING], the xdg tarball on a
	# second machine: every module failed on <Urho3D/Urho3D.h>)
	install(CODE "
		file(REMOVE_RECURSE \"\${CMAKE_INSTALL_PREFIX}/${DST_SHARE}/Urho3D/Build/include\")
		file(MAKE_DIRECTORY \"\${CMAKE_INSTALL_PREFIX}/${DST_SHARE}/Urho3D/Build\")
		execute_process(COMMAND cp -rL \"${URHO3D_BUILD_DIR}/include\"
			\"\${CMAKE_INSTALL_PREFIX}/${DST_SHARE}/Urho3D/Build/include\"
			RESULT_VARIABLE r)
		if(NOT r EQUAL 0)
			message(FATAL_ERROR \"copying Urho3D's include tree dereferenced failed\")
		endif()
	")
	if(WIN32 AND BUILDAT_SHIP_COMPILER AND NOT BUILDAT_LUANTI_ONLY)
		# What a C++ compile and link of a module needs and nothing else:
		# the whole distribution is 760 MB with clang, gdb and doxygen in
		# it. The driver finds cc1plus and the crt objects relative to
		# itself, so the layout under compiler/ is the distribution's.
		set(SC "${BUILDAT_SHIP_COMPILER}")
		install(DIRECTORY "${SC}/bin/" DESTINATION "${DST_COMPILER}/bin"
			FILES_MATCHING
			PATTERN "c++.exe" PATTERN "g++.exe" PATTERN "gcc.exe"
			PATTERN "as.exe" PATTERN "ld.exe" PATTERN "ld.bfd.exe" PATTERN "ar.exe"
			PATTERN "libgcc_s_seh-1.dll" PATTERN "libstdc++-6.dll"
			PATTERN "libwinpthread-1.dll" PATTERN "libgmp-10.dll"
			PATTERN "libmpfr-6.dll" PATTERN "libmpc-3.dll" PATTERN "libisl-23.dll"
			PATTERN "libzstd.dll" PATTERN "zlib1.dll" PATTERN "libiconv-2.dll"
			PATTERN "libintl-8.dll")
		file(GLOB SC_LIBEXEC "${SC}/libexec/gcc/x86_64-w64-mingw32/*")
		list(GET SC_LIBEXEC 0 SC_LIBEXEC_VER)
		get_filename_component(SC_GCC_VER "${SC_LIBEXEC_VER}" NAME)
		# cc1.exe: the C a client builds from a wasm module's wasm2c
		# translation ([CLIENT_WASM_WINDOWS]), 30 MB
		install(DIRECTORY "${SC_LIBEXEC_VER}/"
			DESTINATION "${DST_COMPILER}/libexec/gcc/x86_64-w64-mingw32/${SC_GCC_VER}"
			FILES_MATCHING PATTERN "cc1plus.exe" PATTERN "cc1.exe" PATTERN "collect2.exe"
			PATTERN "*.dll" PATTERN "install-tools" EXCLUDE PATTERN "plugin" EXCLUDE)
		install(DIRECTORY "${SC}/lib/gcc" DESTINATION "${DST_COMPILER}/lib")
		# The C++ and libgcc import libraries beside lib/gcc: what -lstdc++
		# and -lgcc_s resolve to when a module links
		install(DIRECTORY "${SC}/lib/" DESTINATION "${DST_COMPILER}/lib"
			FILES_MATCHING PATTERN "libstdc++*.a" PATTERN "libgcc_s.a"
			PATTERN "libwinpthread*.a" PATTERN "libssp*.a"
			PATTERN "gcc" EXCLUDE PATTERN "clang" EXCLUDE PATTERN "python3.9" EXCLUDE
			PATTERN "bfd-plugins" EXCLUDE PATTERN "pkgconfig" EXCLUDE)
		install(DIRECTORY "${SC}/include/c++" DESTINATION "${DST_COMPILER}/include")
		install(DIRECTORY "${SC}/x86_64-w64-mingw32" DESTINATION "${DST_COMPILER}"
			PATTERN "bin" EXCLUDE)
		install(FILES "${SC}/version_info.txt" DESTINATION "${DST_COMPILER}" OPTIONAL)
	endif()
endif()
install(DIRECTORY "${URHO3D_HOME}/bin/CoreData" DESTINATION "${DST_SHARE}/Urho3D/bin")
install(DIRECTORY "${URHO3D_HOME}/bin/Data" DESTINATION "${DST_SHARE}/Urho3D/bin")

set(PACKAGE_NAME "${PROJECT_NAME}")
if(BUILD_CLIENT AND BUILD_SERVER)
	set(PACKAGE_NAME "${PACKAGE_NAME}-full")
elseif(BUILD_CLIENT)
	set(PACKAGE_NAME "${PACKAGE_NAME}-client")
elseif(BUILD_SERVER)
	set(PACKAGE_NAME "${PACKAGE_NAME}-server")
endif()
if(WIN32)
	if(CMAKE_SIZEOF_VOID_P EQUAL 8)
		set(PACKAGE_NAME "${PACKAGE_NAME}-w64")
	else()
		set(PACKAGE_NAME "${PACKAGE_NAME}-w32")
	endif()
	set(CPACK_GENERATOR ZIP)
else()
	set(PACKAGE_NAME "${PACKAGE_NAME}-linux-${CMAKE_SYSTEM_PROCESSOR}")
	set(CPACK_GENERATOR TGZ)
endif()
message(STATUS "PACKAGE_NAME: ${PACKAGE_NAME}")
set(CPACK_PACKAGE_FILE_NAME "${PACKAGE_NAME}")
include(CPack)

message(STATUS "CMAKE_INSTALL_PREFIX: ${CMAKE_INSTALL_PREFIX}")
message(STATUS "Run 'make install' to install, or util/package.sh to make the archives.")

# vim: set noet ts=4 sw=4:
