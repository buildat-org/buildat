#
# Copyright (c) 2008-2017 the Urho3D project.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#

# Check existence of various header files and their functions required by some of the third-party libraries and Urho3D library
# Set the CMake variables in this scope but only add the compiler defines in the respective library's scope
include (CheckIncludeFile)
foreach (HEADER stdint.h inttypes.h malloc.h)
    string (TOUPPER HAVE_${HEADER} HAVE_HEADER)
    string (REPLACE . _ HAVE_HEADER ${HAVE_HEADER})
    check_include_file (${HEADER} ${HAVE_HEADER})
endforeach ()
include (CheckFunctionExists)
foreach (FUNCT __sincosf malloc_usable_size)
    string (TOUPPER HAVE_${FUNCT} HAVE_FUNCT)
    check_function_exists (${FUNCT} ${HAVE_FUNCT})
endforeach ()
include (CheckLibraryExists)
check_library_exists (m sincosf "" HAVE_SINCOSF)
if (MINGW)
    include (CheckStructHasMember)
    check_struct_has_member (RTL_OSVERSIONINFOW dwOSVersionInfoSize minwindef.h\;winnt.h HAVE_RTL_OSVERSIONINFOW)
endif ()

# Setup RPATH settings
if (URHO3D_LIB_TYPE STREQUAL SHARED AND NOT WIN32 AND NOT ANDROID AND NOT IOS AND NOT TVOS AND NOT WEB)
    # Add RPATH entries when building
    set (CMAKE_SKIP_BUILD_RPATH FALSE)
    # But don't set them yet in the build tree
    set (CMAKE_BUILD_WITH_INSTALL_RPATH FALSE)
    if (APPLE)
        set (CMAKE_MACOSX_RPATH TRUE)
        set (ORIGIN @loader_path)
    else ()
        set (ORIGIN $ORIGIN)
    endif ()
    # When installing/packaging set the first RPATH entry to the library location relative to the executable
    set (CMAKE_INSTALL_RPATH ${ORIGIN}/../lib${LIB_SUFFIX}/${PATH_SUFFIX})    # The library location is based on SDK install destination
    # The second entry to the library location relative to the executable in the tool directory
    list (APPEND CMAKE_INSTALL_RPATH ${ORIGIN}/../../lib${LIB_SUFFIX}/${PATH_SUFFIX})    # The tools are installed one directory further down from normal executable
    # The last entry to the install destination of the library, if the destination location is not in the system default search path
    list (FIND CMAKE_PLATFORM_IMPLICIT_LINK_DIRECTORIES ${CMAKE_INSTALL_PREFIX}/lib${LIB_SUFFIX} isSystemDir)
    if (isSystemDir STREQUAL -1)
        list (APPEND CMAKE_INSTALL_RPATH ${CMAKE_INSTALL_PREFIX}/${DEST_LIBRARY_DIR})
    endif ()
endif ()

# Add targets
foreach (TARGET FreeType JO LZ4 PugiXml rapidjson StanHull STB)
    add_subdirectory (ThirdParty/${TARGET})
endforeach ()

# buildat: SDL 2.32 is built by its own upstream CMake, as a static library
# merged into Urho3D like the other third-party ones (doc/magic.txt). FORCE:
# a build tree configured for 2.0.5 keeps cache entries of the same names.
# What 2.0.5 did not have is left out: no Wayland, KMS/DRM, Vivante or
# Raspberry Pi video driver, so a client picks X11 as before.
foreach (OPT SDL_STATIC SDL2_DISABLE_SDL2MAIN SDL2_DISABLE_INSTALL SDL2_DISABLE_UNINSTALL)
    set (${OPT} ON CACHE BOOL "" FORCE)
endforeach ()
foreach (OPT SDL_SHARED SDL_TEST SDL_TESTS SDL_CCACHE SDL_RENDER SDL_WAYLAND SDL_KMSDRM SDL_VIVANTE SDL_RPI)
    set (${OPT} OFF CACHE BOOL "" FORCE)
endforeach ()
if (WEB)
    # As 2.0.5 was built here: SDL's threads would make it ask for -pthread
    set (SDL_THREADS OFF CACHE BOOL "" FORCE)
endif ()
set (SDL_CMAKE_DEBUG_POSTFIX "" CACHE STRING "" FORCE)
add_subdirectory (ThirdParty/SDL)
list (APPEND STATIC_LIBRARY_TARGETS SDL2-static)
# Its headers as <SDL/...>; the config and revision headers are generated
string (TOLOWER "${CMAKE_BUILD_TYPE}" SDL_CONFIG_DIR)
set (SDL_CONFIG_DIR ${CMAKE_CURRENT_BINARY_DIR}/ThirdParty/SDL/include-config-${SDL_CONFIG_DIR}/SDL2)
file (REMOVE_RECURSE ${CMAKE_BINARY_DIR}/${DEST_INCLUDE_DIR}/ThirdParty/SDL)  # 2.0.5's links
install_header_files (DIRECTORY ThirdParty/SDL/include/ DESTINATION ${DEST_INCLUDE_DIR}/ThirdParty/SDL FILES_MATCHING PATTERN *.h USE_FILE_SYMLINK)
install_header_files (FILES ${CMAKE_CURRENT_BINARY_DIR}/ThirdParty/SDL/include/SDL2/SDL_revision.h ${SDL_CONFIG_DIR}/SDL_config.h DESTINATION ${DEST_INCLUDE_DIR}/ThirdParty/SDL)

if (URHO3D_ANGELSCRIPT)
    add_subdirectory (ThirdParty/AngelScript)
    if (WEB OR (ARM AND URHO3D_64BIT))
        add_subdirectory (ThirdParty/boost)
    endif ()
endif ()

if (URHO3D_LUA)
    add_subdirectory (ThirdParty/Lua${JIT})
    add_subdirectory (ThirdParty/toluapp/src/lib)
endif ()

if (URHO3D_NETWORK)
    add_subdirectory (ThirdParty/Civetweb)
    add_subdirectory (ThirdParty/kNet)
endif ()

if (URHO3D_DATABASE_ODBC)
    add_subdirectory (ThirdParty/nanodbc)
endif ()
if (URHO3D_DATABASE_SQLITE)
    add_subdirectory (ThirdParty/SQLite)
endif ()

if (URHO3D_IK)
    add_subdirectory (ThirdParty/ik)
endif ()

if (URHO3D_NAVIGATION)
    add_subdirectory (ThirdParty/Detour)
    add_subdirectory (ThirdParty/DetourCrowd)
    add_subdirectory (ThirdParty/DetourTileCache)
    add_subdirectory (ThirdParty/Recast)
endif ()

if (URHO3D_URHO2D)
    add_subdirectory (ThirdParty/Box2D)
    if (EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/ThirdParty/spine)
        add_subdirectory (ThirdParty/spine)
        # Add definition for Spine
        add_definitions (-DURHO3D_SPINE)
    endif ()
endif ()

if (URHO3D_WEBP)
    add_subdirectory (ThirdParty/WebP)
endif ()

if (URHO3D_PHYSICS)
    add_subdirectory (ThirdParty/Bullet)
endif ()

if (NOT ANDROID AND NOT ARM AND NOT WEB)
    if (URHO3D_OPENGL)
        add_subdirectory (ThirdParty/GLEW)
    elseif (NOT URHO3D_D3D11)
        add_subdirectory (ThirdParty/MojoShader)
    endif ()
    if (NOT CMAKE_SYSTEM_NAME STREQUAL Linux)
        add_subdirectory (ThirdParty/LibCpuId)
    endif ()
endif ()

# Urho3D game engine library
add_subdirectory (Urho3D)

# Urho3D Clang tools
if (URHO3D_CLANG_TOOLS)
    add_subdirectory (Clang-Tools)
endif ()

# Urho3D tools
add_subdirectory (Tools)

# Urho3D samples
# Samples are built on iOS/tvOS platform too when enabled. Currently there is no available mechanism to package each sample apps into individual *.apk
# for Android platform, so we deploy all samples into one apk and use a simple list view activity launcher to select the sample to run
if (URHO3D_SAMPLES)
    add_subdirectory (Samples)
endif ()

# Urho3D extras
if (URHO3D_EXTRAS)
    add_subdirectory (Extras)
endif ()
