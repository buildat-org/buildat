// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace interface {
	struct Server;
}

namespace rccpp
{
	// The flags every module is compiled with. Part of the build cache hash,
	// so changing them rebuilds what is already cached.
	ss_ cxxflags_fixed();

	struct Compiler {
		virtual ~Compiler(){}

		virtual bool build(const std::string &module_name,
				const std::string &in_path, const std::string &out_path,
				const ss_ &extra_cxxflags = "", const ss_ &extra_ldflags = "",
				bool skip_compile = false) = 0;

		// The compile alone, without loading the result; safe to call from
		// several threads at once while include_directories is not changed
		virtual bool compile(const std::string &in_path,
				const std::string &out_path,
				const ss_ &extra_cxxflags, const ss_ &extra_ldflags) = 0;

		// What says which compiler this is, for the build cache: --version's
		// first line, less the program's name a path or a symlink changes.
		// Empty without a compiler or when it does not answer. Asked once;
		// scratch_path is a file to overwrite, removed after.
		virtual ss_ version(const ss_ &scratch_path) = 0;

		virtual void* construct(const char *name, interface::Server *server) = 0;

		virtual void unload(const std::string &module_name) = 0;

		std::vector<std::string> include_directories;
		std::vector<std::string> library_directories;
		std::vector<std::string> libraries;
	};

	Compiler* createCompiler(const ss_ &compiler_command);
}
// vim: set noet ts=4 sw=4:
