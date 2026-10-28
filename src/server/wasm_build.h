// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"

namespace core {
	struct Config;
}

namespace server
{
	// [CLIENT_WASM] The tools a module's wasm/ is built with: clang (for
	// --target=wasm32) and a wasm linker, set into the config as wasm_cc
	// and wasm_ld. Looked for by name, nothing run: BUILDAT_WASM_CC and
	// BUILDAT_WASM_LD, then PATH's clang and wasm-ld, then emsdk's
	// (~/emsdk, $EMSDK) and rustup's rust-lld. And cargo, for a module's
	// Rust (wasm_cargo: BUILDAT_CARGO, PATH's, $CARGO_HOME's, ~/.cargo's),
	// with rustup's home (wasm_rustup). Called before the box, which is
	// then given their directories to read. Logs what it tried.
	void find_wasm_toolchain(core::Config &config);

	// Builds <module_path>/wasm/ to <build_path>/wasm/<hash>.wasm, the hash
	// being of its files, the API header and the flags (and buildat_wasm's
	// files: a wasm/ with a Cargo.toml is Rust, built by cargo), unless that file
	// (or the prebuilt directory's) is there already. Returns the .wasm's
	// path, or "" and logs why. The module's name is for the log only.
	// [SERVER_WASM] source names another directory of the module (its
	// server .wasm's, meta.json's "server_wasm"), built against
	// wasm_server_api.h and the buildat_wasm_server crate when server is
	// set. A Rust crate's path dependencies may be the module's other
	// directories with a Cargo.toml (a crate both halves use): they are
	// copied and hashed with it.
	ss_ build_module_wasm(const core::Config &config, const ss_ &module_name,
			const ss_ &module_path, const ss_ &source = "wasm",
			bool server = false);
}
// vim: set noet ts=4 sw=4:
