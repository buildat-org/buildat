# The server for the web ([WEB_LOCAL_SERVER] in doc/plan/web_client_plan.md),
# included by CMakeLists.txt with BUILDAT_WEB_SERVER_APP set under emcc.
# The app's modules and every module they depend on are compiled here and
# linked into the server; a generated table of their createModule_<name>
# stands in for rccpp's compile and dlopen (state.cpp, BUILDAT_STATIC_MODULES).
# The app's and the modules' directories are packed into the server's .data
# at /buildat, as the share path.

# An app of apps/ by its name, or one anywhere by its path (a check's fixture)
if(IS_ABSOLUTE "${BUILDAT_WEB_SERVER_APP}")
	set(WS_APP_DIR "${BUILDAT_WEB_SERVER_APP}")
else()
	set(WS_APP_DIR "${CMAKE_SOURCE_DIR}/apps/${BUILDAT_WEB_SERVER_APP}")
endif()
if(NOT EXISTS "${WS_APP_DIR}")
	message(FATAL_ERROR "BUILDAT_WEB_SERVER_APP: no ${WS_APP_DIR}")
endif()
# A variant's base ([GAME_BASE], interface::aitta::find_base): its modules
# after the variant's own, and its directory packed beside it, where the
# loader looks.
# simplified: a plain name beside the app or in apps/; an installed
# "<author>.<name>" base is not built here
set(WS_BASE "")
set(WS_BASE_DIR "")
if(EXISTS "${WS_APP_DIR}/meta.json")
	file(READ "${WS_APP_DIR}/meta.json" J)
	string(JSON WS_BASE ERROR_VARIABLE E GET "${J}" base)
endif()
if(WS_BASE)
	get_filename_component(WS_BASE_DIR "${WS_APP_DIR}/../${WS_BASE}" ABSOLUTE)
	if(NOT EXISTS "${WS_BASE_DIR}/main/meta.json")
		message(FATAL_ERROR "${WS_APP_DIR}: the base ${WS_BASE} is not beside it")
	endif()
endif()

# The modules: builtin/loader, the app's own, and their dependencies, as
# the loader resolves them. An app's module goes before a builtin of the
# same name, as in the loader.
# simplified: a meta.json's cxxflags are not read (none of these has any);
# reverse_dependencies are not followed (no builtin has one)
file(GLOB WS_APP_METAS CONFIGURE_DEPENDS "${WS_APP_DIR}/*/meta.json")
if(WS_BASE_DIR)
	file(GLOB WS_BASE_METAS CONFIGURE_DEPENDS "${WS_BASE_DIR}/*/meta.json")
	list(APPEND WS_APP_METAS ${WS_BASE_METAS})
endif()
set(WS_TODO "${CMAKE_SOURCE_DIR}/builtin/loader")
foreach(M ${WS_APP_METAS})
	get_filename_component(D "${M}" DIRECTORY)
	list(APPEND WS_TODO "${D}")
endforeach()
set(WS_NAMES "")
set(WS_DIRS "")
set(WS_CPP_NAMES "")
set(WS_UNMARKED "")
set(WS_EXTS "")
while(WS_TODO)
	list(POP_FRONT WS_TODO D)
	get_filename_component(N "${D}" NAME)
	list(FIND WS_NAMES "${N}" SEEN)
	if(SEEN GREATER -1)
		continue()
	endif()
	list(APPEND WS_NAMES "${N}")
	list(APPEND WS_DIRS "${D}")
	set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS "${D}/meta.json")
	file(READ "${D}/meta.json" J)
	# The gate: a module says it keeps to the web API ("web": true), unless
	# a stand-in (<name>_web.cpp beside it) takes its place
	string(JSON WEB ERROR_VARIABLE E GET "${J}" web)
	if(NOT WEB AND NOT EXISTS "${D}/${N}_web.cpp")
		list(APPEND WS_UNMARKED "${D}")
	endif()
	string(JSON CPP_OFF ERROR_VARIABLE E GET "${J}" disable_cpp)
	if(NOT CPP_OFF)
		list(APPEND WS_CPP_NAMES "${N}")
	endif()
	# The client extensions it serves (client_file::serve_extension), from
	# the share path
	string(JSON NEXT ERROR_VARIABLE E LENGTH "${J}" client_extensions)
	if(NOT E AND NEXT GREATER 0)
		math(EXPR LAST "${NEXT} - 1")
		foreach(I RANGE ${LAST})
			string(JSON X GET "${J}" client_extensions ${I})
			list(APPEND WS_EXTS "${X}")
		endforeach()
	endif()
	string(JSON NDEP ERROR_VARIABLE E LENGTH "${J}" dependencies)
	if(E)
		set(NDEP 0)
	endif()
	if(NDEP GREATER 0)
		math(EXPR LAST "${NDEP} - 1")
		foreach(I RANGE ${LAST})
			string(JSON DN GET "${J}" dependencies ${I} module)
			string(JSON OPT ERROR_VARIABLE E GET "${J}" dependencies ${I} optional)
			if(EXISTS "${WS_APP_DIR}/${DN}/meta.json")
				list(APPEND WS_TODO "${WS_APP_DIR}/${DN}")
			elseif(WS_BASE_DIR AND EXISTS "${WS_BASE_DIR}/${DN}/meta.json")
				list(APPEND WS_TODO "${WS_BASE_DIR}/${DN}")
			elseif(EXISTS "${CMAKE_SOURCE_DIR}/builtin/${DN}/meta.json")
				list(APPEND WS_TODO "${CMAKE_SOURCE_DIR}/builtin/${DN}")
			elseif(NOT OPT)
				message(FATAL_ERROR "${D}: no module ${DN}")
			endif()
		endforeach()
	endif()
endwhile()
if(WS_UNMARKED)
	string(REPLACE ";" "\n  " WS_UNMARKED "${WS_UNMARKED}")
	message(FATAL_ERROR "${BUILDAT_WEB_SERVER_APP} cannot be built for the web: "
		"these modules do not say \"web\": true in their meta.json "
		"(doc/server_api.txt, \"The web API\"):\n  ${WS_UNMARKED}")
endif()
message(STATUS "Web server of ${BUILDAT_WEB_SERVER_APP}: ${WS_NAMES}")

# The table, and each module's source: its stand-in where it has one
# (network, accounts, starport_announce), else its own. Each is compiled
# with BUILDAT_WEB_MODULE, under which the headers a module may not use
# here (sockets, HTTP, processes) are an #error.
set(WS_TABLE "${CMAKE_BINARY_DIR}/web_server_modules.cpp")
set(WS_DECLS "")
set(WS_ROWS "")
set(WS_SRCS "")
foreach(N ${WS_CPP_NAMES})
	list(FIND WS_NAMES "${N}" I)
	list(GET WS_DIRS ${I} D)
	if(EXISTS "${D}/${N}_web.cpp")
		list(APPEND WS_SRCS "${D}/${N}_web.cpp")
	else()
		list(APPEND WS_SRCS "${D}/${N}.cpp")
	endif()
	string(APPEND WS_DECLS "\tvoid* createModule_${N}(interface::Server*);\n")
	string(APPEND WS_ROWS "\t{\"${N}\", createModule_${N}},\n")
endforeach()
file(CONFIGURE OUTPUT "${WS_TABLE}" CONTENT
"// Generated by util/web_server.cmake for ${BUILDAT_WEB_SERVER_APP}
#include \"server/static_modules.h\"
extern \"C\" {
${WS_DECLS}}
namespace server {
const StaticModule g_static_modules[] = {
${WS_ROWS}\t{nullptr, nullptr},
};
}
")
# [CLIENT_WASM] A module's wasm/: its C and C++ compiled into the server as
# its module (state.cpp's native build of it), and built to <name>.wasm for
# its clients by util/prebuild_wasm.py (emsdk's clang and wasm-ld, or cargo
# for a Rust wasm/, with the flags of src/server/wasm_build.cpp), packed at
# /wasm, where this server looks (wasm_build.cpp, BUILDAT_STATIC_MODULES).
# A module with "disable_cpp" has only the .wasm.
# One directory per app: two apps' "main" are two files, and switching the
# build between them does not pack the other's
get_filename_component(WS_APP_NAME "${WS_APP_DIR}" NAME)
set(WS_WASM_DIR "${CMAKE_BINARY_DIR}/client_wasm/${WS_APP_NAME}")
set(WS_WASMS "")
foreach(N ${WS_NAMES})
	list(FIND WS_NAMES "${N}" I)
	list(GET WS_DIRS ${I} D)
	if(NOT IS_DIRECTORY "${D}/wasm")
		continue()
	endif()
	if(NOT WS_CLANG)
		find_program(WS_CLANG clang HINTS "$ENV{EMSDK}/upstream/bin" NO_DEFAULT_PATH)
		find_program(WS_WASM_LD wasm-ld HINTS "$ENV{EMSDK}/upstream/bin" NO_DEFAULT_PATH)
		if(NOT WS_CLANG OR NOT WS_WASM_LD)
			message(FATAL_ERROR "${D}/wasm: no clang and wasm-ld in $ENV{EMSDK}/upstream/bin")
		endif()
	endif()
	list(FIND WS_CPP_NAMES "${N}" CPP)
	if(CPP GREATER -1)
		file(GLOB_RECURSE W_SRCS CONFIGURE_DEPENDS "${D}/wasm/*.c" "${D}/wasm/*.cc" "${D}/wasm/*.cpp")
		list(APPEND WS_SRCS ${W_SRCS})
		set_property(SOURCE ${W_SRCS} "${D}/${N}.cpp" APPEND PROPERTY COMPILE_OPTIONS -ffp-contract=off)
	endif()
	file(GLOB_RECURSE W_ALL CONFIGURE_DEPENDS "${D}/wasm/*")
	list(FILTER W_ALL EXCLUDE REGEX "/wasm/target/")
	set(W_DEPS ${W_ALL})
	if(EXISTS "${D}/wasm/Cargo.toml")
		file(GLOB_RECURSE W_CRATE CONFIGURE_DEPENDS "${CMAKE_SOURCE_DIR}/src/interface/rust/*")
		list(FILTER W_CRATE EXCLUDE REGEX "/target/")
		list(APPEND W_DEPS ${W_CRATE})
	endif()
	add_custom_command(OUTPUT "${WS_WASM_DIR}/${N}.wasm"
		COMMAND python3 -I "${CMAKE_SOURCE_DIR}/util/prebuild_wasm.py" --by-name
			"${WS_CLANG}" "${WS_WASM_LD}" "${CMAKE_SOURCE_DIR}/src/interface"
			"${WS_WASM_DIR}" "${D}"
		DEPENDS ${W_DEPS} "${CMAKE_SOURCE_DIR}/src/interface/wasm_api.h"
			"${CMAKE_SOURCE_DIR}/src/server/wasm_build.cpp"
			"${CMAKE_SOURCE_DIR}/util/prebuild_wasm.py"
		COMMENT "${N}'s wasm/ for its clients")
	list(APPEND WS_WASMS "${WS_WASM_DIR}/${N}.wasm")
endforeach()
if(WS_WASMS)
	add_custom_target(web_server_client_wasm DEPENDS ${WS_WASMS})
	add_dependencies(${SERVER_EXE_NAME} web_server_client_wasm)
endif()
target_sources(${SERVER_EXE_NAME} PRIVATE ${WS_TABLE} ${WS_SRCS})
set_property(SOURCE ${WS_SRCS} APPEND PROPERTY COMPILE_DEFINITIONS
	BUILDAT_WEB_MODULE)
target_compile_definitions(${SERVER_EXE_NAME} PRIVATE BUILDAT_STATIC_MODULES RCCPP)
# What rccpp hands a module: builtin/ and the app's directory
target_include_directories(${SERVER_EXE_NAME} PRIVATE
	"${CMAKE_SOURCE_DIR}/builtin" "${WS_APP_DIR}")
# Bullet's own headers include each other by a path from its src/
target_include_directories(${SERVER_EXE_NAME} SYSTEM PRIVATE
	"${URHO3D_HOME}/Source/ThirdParty/Bullet/src")

# Where the app is in the packed tree, for pre.js's command line in a page
file(RELATIVE_PATH WS_APP_REL "${CMAKE_SOURCE_DIR}" "${WS_APP_DIR}")
set(WS_APP_JS "${CMAKE_BINARY_DIR}/web_server_app.js")
file(CONFIGURE OUTPUT "${WS_APP_JS}" CONTENT
"Module.buildatApp = '/buildat/${WS_APP_REL}';\n")
set(WS_LINK_FLAGS
	-fexceptions -pthread
	# main() in a thread of its own: the page's (or node's) own thread
	# stays free to start the module threads and to serve the file
	# system, which every thread's file call goes through
	-sPROXY_TO_PTHREAD=1
	-sALLOW_MEMORY_GROWTH=1 -sINITIAL_MEMORY=268435456
	-sSTACK_SIZE=8388608 -sDEFAULT_PTHREAD_STACK_SIZE=2097152
	-sFORCE_FILESYSTEM=1
	-sEXIT_RUNTIME=1
	# The page's way to stop it (main.cpp), and its stream
	# (builtin/network/network_web.cpp)
	-sEXPORTED_FUNCTIONS=_main,_buildat_server_stop,_buildat_stream_in,_buildat_stream_take,_buildat_stream_taken,_malloc,_free
	# The player's storage kept in the browser (pre.js)
	-lidbfs.js
	-sASSERTIONS=1 -sEXCEPTION_STACK_TRACES=1
	--profiling-funcs
	"SHELL:--pre-js ${WS_APP_JS}"
	"SHELL:--pre-js ${CMAKE_SOURCE_DIR}/src/server/web/pre.js"
	"SHELL:--exclude-file *.swp"
)
set(WS_PACKED "${WS_APP_DIR}" ${WS_BASE_DIR})
foreach(D ${WS_DIRS})
	if(NOT D MATCHES "^${WS_APP_DIR}/" AND NOT (WS_BASE_DIR AND D MATCHES "^${WS_BASE_DIR}/"))
		list(APPEND WS_PACKED "${D}")
	endif()
endforeach()
list(REMOVE_DUPLICATES WS_EXTS)
foreach(X ${WS_EXTS})
	if(EXISTS "${CMAKE_SOURCE_DIR}/extensions/${X}")
		list(APPEND WS_PACKED "${CMAKE_SOURCE_DIR}/extensions/${X}")
	endif()
endforeach()
foreach(D ${WS_PACKED})
	file(RELATIVE_PATH R "${CMAKE_SOURCE_DIR}" "${D}")
	list(APPEND WS_LINK_FLAGS "SHELL:--preload-file ${D}@/buildat/${R}")
	file(GLOB_RECURSE P_FILES CONFIGURE_DEPENDS "${D}/*")
	set_property(TARGET ${SERVER_EXE_NAME} APPEND PROPERTY LINK_DEPENDS ${P_FILES})
endforeach()
# hillclimb draws its ground with luanti_client's textures
# simplified: named here; a list of an app's share files when a second
# app needs one
if(EXISTS "${CMAKE_SOURCE_DIR}/extensions/luanti_client/res")
	list(APPEND WS_LINK_FLAGS "SHELL:--preload-file ${CMAKE_SOURCE_DIR}/extensions/luanti_client/res@/buildat/extensions/luanti_client/res")
endif()
if(WS_WASMS)
	list(APPEND WS_LINK_FLAGS "SHELL:--preload-file ${WS_WASM_DIR}@/wasm")
	set_property(TARGET ${SERVER_EXE_NAME} APPEND PROPERTY LINK_DEPENDS ${WS_WASMS})
endif()
target_link_options(${SERVER_EXE_NAME} PRIVATE ${WS_LINK_FLAGS})
set_property(TARGET ${SERVER_EXE_NAME} APPEND PROPERTY
	LINK_DEPENDS "${URHO3D_LIBRARY_FILE}" "${CMAKE_SOURCE_DIR}/src/server/web/pre.js"
	"${WS_APP_JS}")
