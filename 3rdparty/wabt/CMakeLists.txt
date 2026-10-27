# WABT 1.0.42 (https://github.com/WebAssembly/wabt, release tarball
# wabt-1.0.42.tar.xz, sha256 a76cda3c174a43097863a07fc0b0c202f770f53e
# 21806ea2636f167d1ffb1e30), Apache 2.0 ([CLIENT_WASM]). Only what the
# client uses is kept: the binary reader, the validator, wasm2c's C
# writer (with its prebuilt templates), wasm2c's runtime, and the binary
# writer (the metered module the web client instantiates). No tools,
# tests, text format, interpreter or third_party beyond picosha2. Updated
# by copying the same files out of a newer release; the files are as
# released, this CMakeLists.txt is buildat's.
cmake_minimum_required(VERSION 3.10)

set(WABT_VERSION_STRING "1.0.42")
include(CheckIncludeFile)
include(CheckSymbolExists)
include(CheckTypeSize)
check_include_file("alloca.h" HAVE_ALLOCA_H)
check_include_file("unistd.h" HAVE_UNISTD_H)
check_symbol_exists(snprintf "stdio.h" HAVE_SNPRINTF)
check_symbol_exists(strcasecmp "strings.h" HAVE_STRCASECMP)
check_type_size(ssize_t SSIZE_T)
check_type_size(size_t SIZEOF_SIZE_T)
set(WABT_BIG_ENDIAN 0)
set(HAVE_OPENSSL_SHA_H 0) # picosha2, no libcrypto
set(WITH_EXCEPTIONS 0)
if(CMAKE_CXX_COMPILER_ID MATCHES "Clang" OR EMSCRIPTEN)
	set(COMPILER_IS_CLANG 1)
else()
	set(COMPILER_IS_GNU 1)
endif()
configure_file(src/config.h.in ${CMAKE_CURRENT_BINARY_DIR}/include/wabt/config.h @ONLY)

add_library(wabt STATIC
	src/apply-names.cc
	src/binary-reader-ir.cc
	src/binary-reader.cc
	src/binary-writer.cc
	src/binary-reader-logging.cc
	src/binary.cc
	src/binding-hash.cc
	src/common.cc
	src/config.cc
	src/expr-visitor.cc
	src/feature.cc
	src/generate-names.cc
	src/ir.cc
	src/leb128.cc
	src/opcode-code-table.c
	src/opcode.cc
	# feature.cc refers to it
	src/option-parser.cc
	src/sha256.cc
	src/shared-validator.cc
	src/stream.cc
	src/type-checker.cc
	src/utf8.cc
	src/validator.cc
	src/c-writer.cc
	src/prebuilt/wasm2c_header_top.cc
	src/prebuilt/wasm2c_header_bottom.cc
	src/prebuilt/wasm2c_source_includes.cc
	src/prebuilt/wasm2c_source_declarations.cc
	src/prebuilt/wasm2c_simd_source_declarations.cc
	src/prebuilt/wasm2c_atomicops_source_declarations.cc
)
target_include_directories(wabt PUBLIC
	${CMAKE_CURRENT_SOURCE_DIR}/include
	${CMAKE_CURRENT_BINARY_DIR}/include)
target_include_directories(wabt PRIVATE
	${CMAKE_CURRENT_SOURCE_DIR}/third_party/picosha2)
# The project's -std=c++0x comes earlier on the line; WABT 1.0.42 is C++20
target_compile_options(wabt PRIVATE $<$<COMPILE_LANGUAGE:CXX>:-std=c++20 -fno-exceptions>
	-O2 -w -D__STDC_LIMIT_MACROS=1 -D__STDC_FORMAT_MACROS=1)
set_target_properties(wabt PROPERTIES POSITION_INDEPENDENT_CODE ON)

# wasm2c's runtime, for the native client ([CLIENT_WASM]). The files the
# client writes beside the C it compiles, as strings (wasm_rt_files.cc):
# its headers, and on Windows the runtime's sources too, as each module's
# DLL has the runtime in it ([CLIENT_WASM_WINDOWS]: a DLL does not see the
# executable's symbols).
# On Linux the runtime's objects are linked into the client whole and
# exported to the modules it builds (wasm_rt.dynlist), the defines the same
# as those modules are built with (src/lua_bindings/wasm.cpp). The memory's
# allocation and freeing are renamed, so that the client's own wrap them
# and keeps the ranges its signal handler knows.
if(NOT EMSCRIPTEN)
	set(WASM_RT_FILES wasm-rt.h wasm-rt-impl.h wasm-rt-exceptions.h)
	if(WIN32)
		list(APPEND WASM_RT_FILES wasm-rt-exceptions-impl.c wasm-rt-impl.c
			wasm-rt-impl-tableops.inc wasm-rt-mem-impl.c
			wasm-rt-mem-impl-helper.inc)
	endif()
	set(WASM_RT_CC "extern \"C\" const char *const buildat_wasm_rt_files[] = {\n")
	foreach(f ${WASM_RT_FILES})
		file(READ ${CMAKE_CURRENT_SOURCE_DIR}/wasm2c/${f} T)
		string(REGEX REPLACE "(.[^\n]*\n)" "R\"w2c_template(\\1)w2c_template\"\n"
			T "${T}")
		string(APPEND WASM_RT_CC "\"${f}\",\n${T},\n")
		set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
			${CMAKE_CURRENT_SOURCE_DIR}/wasm2c/${f})
	endforeach()
	file(WRITE ${CMAKE_CURRENT_BINARY_DIR}/wasm_rt_files.cc "${WASM_RT_CC}0};\n")
	add_library(wasm_rt_files OBJECT ${CMAKE_CURRENT_BINARY_DIR}/wasm_rt_files.cc)
endif()
if(NOT EMSCRIPTEN AND NOT WIN32)
	add_library(wasm_rt OBJECT
		wasm2c/wasm-rt-impl.c
		wasm2c/wasm-rt-mem-impl.c
		wasm2c/wasm-rt-exceptions-impl.c)
	target_compile_definitions(wasm_rt PUBLIC
		WASM_RT_SKIP_SIGNAL_RECOVERY=1 WASM_RT_STACK_DEPTH_COUNT=1)
	set_source_files_properties(wasm2c/wasm-rt-mem-impl.c PROPERTIES
		COMPILE_DEFINITIONS
		"wasm_rt_allocate_memory=buildat_wasm_rt_allocate_memory_impl;wasm_rt_free_memory=buildat_wasm_rt_free_memory_impl")
	target_include_directories(wasm_rt PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/wasm2c)
	target_compile_options(wasm_rt PRIVATE -w)
endif()
