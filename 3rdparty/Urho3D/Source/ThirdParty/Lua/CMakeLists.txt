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

# Define target name for Lua library
set (TARGET_NAME Lua)

# Define source files
define_source_files (GLOB_CPP_PATTERNS src/*.c GLOB_H_PATTERNS src/*.h EXCLUDE_PATTERNS src/lua.c src/luac.c)

# Define dependency libs
if (READLINE_FOUND)
    add_definitions (-DLUA_USE_READLINE)
    list (APPEND INCLUDE_DIRS ${READLINE_INCLUDE_DIRS})
    list (APPEND LIBS ${READLINE_LIBRARIES})
endif ()

# buildat: on the web, compiled as C++ so that a Lua error is a C++ throw
# (luaconf.h's LUAI_THROW) and not a longjmp. Emscripten's JS exception
# handling loses a longjmp that passes through a C++ frame with a landing
# pad: the call there returns as if nothing happened ([WEB_LUA_ERROR_EH])
if (WEB)
    set_source_files_properties (${CPP_FILES} PROPERTIES LANGUAGE CXX)
endif ()

# Setup target
setup_library ()
if (WEB)
    target_compile_options (${TARGET_NAME} PRIVATE -fexceptions)
endif ()

# Install headers for building and using the Urho3D library (no direct dependencies but library user may need them)
install_header_files (DIRECTORY src/ DESTINATION ${DEST_INCLUDE_DIR}/ThirdParty/Lua FILES_MATCHING PATTERN *.h)  # Note: the trailing slash is significant

# Setup additional Lua standalone targets (these targets can be transfered and executed on an embedded device, such as Raspberry Pi and Android)
if (NOT CMAKE_PROJECT_NAME MATCHES ^Urho3D-ExternalProject-tolua\\+\\+ AND NOT IOS AND NOT TVOS AND NOT WEB)
    # Define target name for Lua interpreter
    set (TARGET_NAME lua_interpreter)   # Note: intended target name is 'lua' which clashes with 'Lua' library target above for case-insensitive platform

    # Define source files
    set (SOURCE_FILES src/lua.c)

    # Define dependency libs
    set (LIBS Lua)
    if (NOT MSVC)
        list (APPEND LIBS m)
    endif ()

    # Setup target
    setup_executable (NODEPS)
    adjust_target_name ()   # Adjust to intended target output name

    # Define target name for Lua compiler
    set (TARGET_NAME luac)

    # Define source files
    set (SOURCE_FILES src/luac.c)

    # Define dependency libs
    # Same as above

    # Setup target
    setup_executable (NODEPS)
endif ()
