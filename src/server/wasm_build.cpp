// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#include "server/wasm_build.h"
#include "core/log.h"
#include "core/config.h"
#include "interface/fs.h"
#include "interface/process.h"
#include "interface/sha1.h"
#include <algorithm>
#include <chrono>
#include <fstream>
#include <sstream>
#include <cstdlib>
#include <cstring>
#ifndef _WIN32
#include <unistd.h>
#endif
#define MODULE "wasm"

namespace server {

// What the .wasm is built with; in its hash. Pinned features rather than
// clang's default CPU, which grows with each release: these are in every
// browser and in the client's validator. -ffp-contract=off as the
// server's native build of the same files (state.cpp): no a * b + c made
// one rounding on one side and two on the other ([CLIENT_WASM] step 5).
// Each a single literal: util/web_server.cmake reads them from here.
static const char *WASM_CFLAGS = "--target=wasm32 -O2 -nostdlib -ffreestanding -fvisibility=hidden -ffp-contract=off -mcpu=mvp -msign-ext -mmutable-globals -mnontrapping-fptoint -mbulk-memory";
// The maximum memory is the client's cap (64 MiB): a module declares one,
// and the client refuses one that does not
static const char *WASM_LDFLAGS = "--no-entry --export-dynamic --gc-sections --strip-all -O2 -z stack-size=65536 --max-memory=67108864";

// A module's Rust (wasm/Cargo.toml), built by cargo: the same features as
// the C flags (rustc's default CPU has reference types and multi-value,
// which the client refuses; the standard library is built with them, and
// its call_indirect's table index, a padded LEB that only reference types
// read, is made one byte by --compress-relocations), the client's maximum
// memory and the stack; panics abort (the client runs no unwinding).
// Offline, with a CARGO_HOME of its own: buildat_wasm is the engine's copy (interface/rust/), patched
// in for crates.io's name. simplified: no crates but path ones; fetching
// a module's crates before the box is the upgrade. In the hash.
static const char *RUST_FLAGS = "-C target-cpu=mvp -C target-feature=+sign-ext,+mutable-globals,+nontrapping-fptoint,+bulk-memory -C link-arg=--max-memory=67108864 -C link-arg=-zstack-size=65536 -C link-arg=--compress-relocations -C strip=symbols";
static const char *RUST_TARGET = "wasm32-unknown-unknown";

static ss_ env(const char *name)
{
	return interface::process::get_environment_variable(name);
}

static bool is_program(const ss_ &path)
{
	if(path.empty())
		return false;
#ifdef _WIN32
	return interface::fs::path_exists(path);
#else
	return access(path.c_str(), X_OK) == 0;
#endif
}

static ss_ find_in_path(const ss_ &name, sv_<ss_> &tried)
{
#ifdef _WIN32
	const char sep = ';';
	const ss_ file = name+".exe";
#else
	const char sep = ':';
	const ss_ file = name;
#endif
	const ss_ path = env("PATH");
	size_t at = 0;
	while(at <= path.size()){
		size_t end = path.find(sep, at);
		if(end == ss_::npos)
			end = path.size();
		const ss_ dir = path.substr(at, end - at);
		if(!dir.empty() && is_program(dir+"/"+file))
			return dir+"/"+file;
		at = end + 1;
	}
	tried.push_back(name+" in PATH");
	return "";
}

static ss_ first_program(const sv_<ss_> &candidates, sv_<ss_> &tried)
{
	for(const ss_ &c : candidates){
		if(is_program(c))
			return c;
		tried.push_back(c);
	}
	return "";
}

void find_wasm_toolchain(core::Config &config)
{
	sv_<ss_> tried;
	const ss_ home = env("HOME");
	sv_<ss_> emsdks;
	const ss_ emsdk_env = env("EMSDK");
	if(!emsdk_env.empty())
		emsdks.push_back(emsdk_env+"/upstream/bin/");
	if(!home.empty())
		emsdks.push_back(home+"/emsdk/upstream/bin/");

	ss_ cc = env("BUILDAT_WASM_CC");
	if(!cc.empty() && !is_program(cc)){
		tried.push_back("BUILDAT_WASM_CC="+cc);
		cc = "";
	}
	if(cc.empty())
		cc = find_in_path("clang", tried);
	if(cc.empty()){
		sv_<ss_> c;
		for(const ss_ &e : emsdks)
			c.push_back(e+"clang");
		cc = first_program(c, tried);
	}

	ss_ ld = env("BUILDAT_WASM_LD");
	if(!ld.empty() && !is_program(ld)){
		tried.push_back("BUILDAT_WASM_LD="+ld);
		ld = "";
	}
	if(ld.empty())
		ld = find_in_path("wasm-ld", tried);
	if(ld.empty()){
		sv_<ss_> c;
		for(const ss_ &e : emsdks)
			c.push_back(e+"wasm-ld");
		// rustup's lld, run as rust-lld -flavor wasm; the stable toolchain
		// first, then the others by name
		ss_ rustup = env("RUSTUP_HOME");
		if(rustup.empty() && !home.empty())
			rustup = home+"/.rustup";
		if(!rustup.empty()){
			sv_<ss_> chains;
			for(const auto &n : interface::fs::list_directory(rustup+"/toolchains"))
				if(n.is_directory)
					chains.push_back(n.name);
			std::sort(chains.begin(), chains.end(), [](const ss_ &a, const ss_ &b){
				const bool sa = a.compare(0, 6, "stable") == 0;
				const bool sb = b.compare(0, 6, "stable") == 0;
				return sa != sb ? sa : a < b;
			});
			for(const ss_ &t : chains){
				const ss_ lib = rustup+"/toolchains/"+t+"/lib/rustlib";
				for(const auto &n : interface::fs::list_directory(lib))
					if(n.is_directory)
						c.push_back(lib+"/"+n.name+"/bin/rust-lld");
			}
		}
		ld = first_program(c, tried);
	}
	ss_ tried_s;
	for(const ss_ &t : tried)
		tried_s += (tried_s.empty() ? "" : ", ")+t;
	log_v(MODULE, "wasm toolchain lookup tried: %s", cs(tried_s));
	if(cc.empty() || ld.empty()){
		// Not a warning: only a module with wasm/ needs it, and that one
		// is refused with this list
		log_i(MODULE, "No wasm toolchain (clang %s, linker %s; tried %s)",
				cc.empty() ? "missing" : cs(cc), ld.empty() ? "missing" : cs(ld),
				cs(tried_s));
		cc = "";
		ld = "";
	} else {
		log_i(MODULE, "wasm toolchain: %s, %s", cs(cc), cs(ld));
	}
	config.set("wasm_cc", cc);
	config.set("wasm_ld", ld);
	config.set("wasm_tried", tried_s);

	// A module's Rust (wasm/Cargo.toml): cargo, by name as above, and
	// rustup's home, which the box is given to read
	sv_<ss_> cargo_tried;
	ss_ cargo = env("BUILDAT_CARGO");
	if(!cargo.empty() && !is_program(cargo)){
		cargo_tried.push_back("BUILDAT_CARGO="+cargo);
		cargo = "";
	}
	if(cargo.empty())
		cargo = find_in_path("cargo", cargo_tried);
	if(cargo.empty()){
		sv_<ss_> c;
		if(!env("CARGO_HOME").empty())
			c.push_back(env("CARGO_HOME")+"/bin/cargo");
		if(!home.empty())
			c.push_back(home+"/.cargo/bin/cargo");
		cargo = first_program(c, cargo_tried);
	}
	ss_ cargo_tried_s;
	for(const ss_ &t : cargo_tried)
		cargo_tried_s += (cargo_tried_s.empty() ? "" : ", ")+t;
	ss_ rustup = env("RUSTUP_HOME");
	if(rustup.empty() && !home.empty() &&
			interface::fs::path_exists(home+"/.rustup"))
		rustup = home+"/.rustup";
	log_v(MODULE, "cargo: %s (tried %s)", cargo.empty() ? "missing" : cs(cargo),
			cs(cargo_tried_s));
	config.set("wasm_cargo", cargo);
	config.set("wasm_cargo_tried", cargo_tried_s);
	config.set("wasm_rustup", cargo.empty() ? "" : rustup);
}

static ss_ quote(const ss_ &s)
{
#ifdef _WIN32
	return "\""+s+"\"";
#else
	ss_ r = "'";
	for(char c : s){
		if(c == '\'')
			r += "'\\''";
		else
			r += c;
	}
	return r+"'";
#endif
}

static ss_ read_file(const ss_ &path)
{
	std::ifstream f(path, std::ios::binary);
	std::ostringstream os(std::ios::binary);
	os<<f.rdbuf();
	return os.str();
}

static void collect(const ss_ &dir, const ss_ &prefix, sv_<ss_> &out)
{
	for(const auto &n : interface::fs::list_directory(dir)){
		if(n.is_directory)
			collect(dir+"/"+n.name, prefix+n.name+"/", out);
		else
			out.push_back(prefix+n.name);
	}
}

static bool ends_with(const ss_ &s, const char *e)
{
	const size_t n = strlen(e);
	return s.size() >= n && s.compare(s.size() - n, n, e) == 0;
}

static bool run_logged(const ss_ &command, const ss_ &log_path,
		const sm_<ss_, ss_> &env = {})
{
	interface::process::ExecOptions opts;
	opts.output_path = log_path;
	opts.env = env;
	const int status = interface::process::shell_exec(command, opts);
	if(status == 0)
		return true;
	log_w(MODULE, "Failed (exit %i): %s", status, cs(command));
	std::ifstream f(log_path);
	ss_ line;
	int n = 0;
	while(std::getline(f, line) && n++ < 40)
		log_w(MODULE, "  %s", cs(line));
	return false;
}

// The module's other directories with a Cargo.toml than source (crates
// the source's may use by path, "../shared"), by name, and their files
// (target/ left out), each sorted
static sv_<std::pair<ss_, sv_<ss_>>> sibling_crates(const ss_ &module_path,
		const ss_ &source)
{
	sv_<std::pair<ss_, sv_<ss_>>> r;
	for(const auto &n : interface::fs::list_directory(module_path)){
		if(!n.is_directory || n.name == source || n.name[0] == '.' ||
				!interface::fs::path_exists(module_path+"/"+n.name+"/Cargo.toml"))
			continue;
		sv_<ss_> files;
		collect(module_path+"/"+n.name, "", files);
		files.erase(std::remove_if(files.begin(), files.end(),
				[](const ss_ &f){ return f.compare(0, 7, "target/") == 0; }),
				files.end());
		std::sort(files.begin(), files.end());
		r.emplace_back(n.name, files);
	}
	std::sort(r.begin(), r.end());
	return r;
}

// wasm/ as a Rust crate: copied out (cargo writes Cargo.lock beside
// Cargo.toml), with the module's other crates beside it as they are in the
// module, and built by cargo; the .wasm's path, or "" and why logged
static ss_ build_rust(const core::Config &config, const ss_ &module_name,
		const ss_ &module_path, const ss_ &source, const sv_<ss_> &files,
		const ss_ &out_dir, const ss_ &hash)
{
	const ss_ interface_path = config.get<ss_>("interface_path");
	const ss_ cargo = config.get<ss_>("wasm_cargo");
	if(cargo.empty()){
		log_e(MODULE, "%s has %s/ in Rust, and this server has no cargo to "
				"build it (tried %s). Install Rust (rustup) and its %s target, "
				"or set BUILDAT_CARGO.", cs(module_name), cs(source),
				cs(config.get<ss_>("wasm_cargo_tried")), RUST_TARGET);
		return "";
	}
	const auto t0 = std::chrono::steady_clock::now();
#ifdef _WIN32
	const ss_ tmp = out_dir+"/"+hash+".tmp";
	const ss_ rustc = interface::fs::strip_file_name(cargo)+"/rustc.exe";
#else
	const ss_ tmp = out_dir+"/"+hash+"."+itos(getpid())+".tmp";
	const ss_ rustc = interface::fs::strip_file_name(cargo)+"/rustc";
#endif
	interface::fs::create_directories(tmp+"/src");
	interface::fs::create_directories(tmp+"/cargo_home");
	// The flags in cargo's own form, which goes over RUSTFLAGS and any
	// config's: one byte 0x1f between them
	ss_ flags = RUST_FLAGS;
	std::replace(flags.begin(), flags.end(), ' ', '\x1f');
	const sm_<ss_, ss_> env = {
		{"CARGO_HOME", tmp+"/cargo_home"},
		{"CARGO_ENCODED_RUSTFLAGS", flags},
	};
	bool ok = true;
	ss_ why;
	// The target installed: rustc names its library directory either way
	if(ok){
		ok = run_logged(quote(rustc)+" --print target-libdir --target "+
				RUST_TARGET, tmp+"/rustc.log", env);
		ss_ dir = read_file(tmp+"/rustc.log");
		while(!dir.empty() && (dir.back() == '\n' || dir.back() == '\r'))
			dir.pop_back();
		if(!ok || dir.empty() || !interface::fs::path_exists(dir)){
			ok = false;
			why = ss_("cargo is there, and Rust's ")+RUST_TARGET+" target is "
					"not (rustup target add "+RUST_TARGET+")";
		}
	}
	sv_<std::pair<ss_, sv_<ss_>>> crates = sibling_crates(module_path, source);
	crates.emplace_back(source, files);
	for(size_t c = 0; ok && c < crates.size(); c++){
		const ss_ &dir = crates[c].first;
		for(size_t i = 0; ok && i < crates[c].second.size(); i++){
			const ss_ &f = crates[c].second[i];
			const ss_ to = tmp+"/src/"+dir+"/"+f;
			interface::fs::create_directories(interface::fs::strip_file_name(to));
			ok = interface::fs::copy_file(module_path+"/"+dir+"/"+f, to);
			if(!ok)
				why = "copying "+dir+"/"+f+" failed";
		}
	}
	if(ok){
		// The engine's crates patched in under their crates.io names: the
		// client's API and the server's ([SERVER_WASM]); a crate uses one
		const ss_ command = quote(cargo)+" build --offline --release --target "+
				RUST_TARGET+" --manifest-path "+quote(tmp+"/src/"+source+
					"/Cargo.toml")+
				" --target-dir "+quote(tmp+"/target")+
				" --config "+quote("patch.crates-io.buildat_wasm.path=\""+
					interface_path+"/rust/buildat_wasm\"")+
				" --config "+quote("patch.crates-io.buildat_wasm_server.path=\""+
					interface_path+"/rust/buildat_wasm_server\"")+
				" --config "+quote("profile.release.panic=\"abort\"");
		ok = run_logged(command, tmp+"/cargo.log", env);
		if(!ok)
			why = "cargo failed";
	}
	// The cdylib's .wasm: the one there
	ss_ built;
	if(ok){
		const ss_ dir = tmp+"/target/"+RUST_TARGET+"/release";
		for(const auto &n : interface::fs::list_directory(dir))
			if(!n.is_directory && ends_with(n.name, ".wasm"))
				built = built.empty() ? dir+"/"+n.name : "?";
		if(built.empty() || built == "?"){
			ok = false;
			why = built.empty() ? "cargo made no .wasm (crate-type = "
					"[\"cdylib\"] in [lib])" : "cargo made more than one .wasm";
		}
	}
	const ss_ out = out_dir+"/"+hash+".wasm";
	if(ok)
		ok = interface::fs::rename(built, out);
	interface::fs::remove_all(tmp);
	if(!ok){
		log_e(MODULE, "%s: building %s/ (Rust) failed: %s", cs(module_name),
				cs(source), cs(why));
		return "";
	}
	const int ms = (int)std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now() - t0).count();
	log_i(MODULE, "%s: built %s/ (Rust) in %i ms: %s (%zu bytes)",
			cs(module_name), cs(source), ms, cs(out), read_file(out).size());
	return out;
}

// A crate's files into the key: a name and its bytes per file
static void key_files(std::ostringstream &key, const ss_ &dir,
		const sv_<ss_> &files)
{
	for(const ss_ &f : files){
		const ss_ data = read_file(dir+"/"+f);
		key<<f<<'\0'<<data.size()<<'\0'<<data;
	}
}

ss_ build_module_wasm(const core::Config &config, const ss_ &module_name,
		const ss_ &module_path, const ss_ &source, bool server)
{
	// A directory of the module's own, by its name
	bool plain = !source.empty() && source[0] != '.';
	for(char c : source)
		plain = plain && (isalnum((unsigned char)c) || c == '_' || c == '-');
	if(!plain){
		log_e(MODULE, "%s: its .wasm's source \"%s\" is not a directory name "
				"of the module's", cs(module_name), cs(source.substr(0, 64)));
		return "";
	}
	const ss_ src_dir = module_path+"/"+source;
	if(!interface::fs::path_exists(src_dir)){
		log_e(MODULE, "%s: no %s/ to build its .wasm from", cs(module_name),
				cs(source));
		return "";
	}
	sv_<ss_> files;
	collect(src_dir, "", files);
	std::sort(files.begin(), files.end());
	// Rust: a crate, which cargo builds; its target/ is a build's, not a
	// source
	const bool rust = interface::fs::path_exists(src_dir+"/Cargo.toml");
	if(rust)
		files.erase(std::remove_if(files.begin(), files.end(),
				[](const ss_ &f){ return f.compare(0, 7, "target/") == 0; }),
				files.end());
	sv_<ss_> sources;
	for(const ss_ &f : files)
		if(ends_with(f, ".c") || ends_with(f, ".cc") || ends_with(f, ".cpp"))
			sources.push_back(f);
	if(sources.empty() && !rust){
		log_e(MODULE, "%s: %s/ has no .c, .cc, .cpp or Cargo.toml",
				cs(module_name), cs(source));
		return "";
	}
	const ss_ interface_path = config.get<ss_>("interface_path");
	const ss_ include_dir = interface::fs::strip_file_name(interface_path);
	const ss_ crate_dir = interface_path+"/rust/buildat_wasm";
	const ss_ server_crate_dir = interface_path+"/rust/buildat_wasm_server";

	// Keyed by what goes in: a name and its bytes per file, the header, the
	// flags (and for Rust buildat_wasm's files). Not the tools' versions,
	// so that a prebuilt one serves a server without them.
	std::ostringstream key(std::ios::binary);
	key<<"buildat wasm 1\n"<<WASM_CFLAGS<<"\n"<<WASM_LDFLAGS<<"\n";
	key<<read_file(interface_path+"/wasm_api.h");
	bool bindings = false;
	for(const ss_ &f : files){
		const ss_ data = read_file(src_dir+"/"+f);
		key<<f<<'\0'<<data.size()<<'\0'<<data;
		bindings = bindings || data.find("buildat_client.h") != ss_::npos;
	}
	// [CLIENT_WASM_BINDINGS] The generated bindings, for the modules that
	// include them only (the others' keys, and their prebuilt .wasm, stay)
	if(bindings)
		key<<"bindings 1\n"<<read_file(interface_path+"/buildat_client.h");
	// The engine's crates, and the module's other crates (a module with
	// one crate keys as it always did)
	auto engine_crate = [&](const ss_ &dir){
		sv_<ss_> crate;
		collect(dir, "", crate);
		std::sort(crate.begin(), crate.end());
		crate.erase(std::remove_if(crate.begin(), crate.end(),
				[](const ss_ &f){ return f.compare(0, 7, "target/") == 0 ||
						f == "Cargo.lock"; }), crate.end());
		key_files(key, dir, crate);
	};
	if(rust){
		key<<"rust 1\n"<<RUST_FLAGS<<"\n"<<RUST_TARGET<<"\n";
		engine_crate(crate_dir);
		for(const auto &c : sibling_crates(module_path, source)){
			key<<"crate "<<c.first<<"\n";
			key_files(key, module_path+"/"+c.first, c.second);
		}
	}
	// [SERVER_WASM] A server module's: its API, and its crate
	if(server){
		key<<"server 1\n"<<read_file(interface_path+"/wasm_server_api.h");
		if(rust)
			engine_crate(server_crate_dir);
	}
	const ss_ hash = interface::sha1::hex(interface::sha1::calculate(key.str()));

	const ss_ out_dir = config.get<ss_>("rccpp_build_path")+"/wasm";
	const ss_ out = out_dir+"/"+hash+".wasm";
	if(interface::fs::path_exists(out)){
		log_i(MODULE, "%s: %s/ is built (cache hit): %s", cs(module_name),
				cs(source), cs(out));
		return out;
	}
	const ss_ prebuilt_dir = config.get<ss_>("rccpp_prebuilt_path");
	if(!prebuilt_dir.empty() &&
			interface::fs::path_exists(prebuilt_dir+"/wasm/"+hash+".wasm")){
		log_i(MODULE, "%s: %s/ is in the shared build", cs(module_name),
				cs(source));
		return prebuilt_dir+"/wasm/"+hash+".wasm";
	}
#ifdef BUILDAT_STATIC_MODULES
	if(server){
		log_e(MODULE, "%s: a server .wasm does not run in the browser's "
				"server yet", cs(module_name));
		return "";
	}
	// [WEB_LOCAL_SERVER]: no compiler in a browser. util/web_server.cmake
	// builds each module's from the same sources as the server it packs,
	// named by the module (rebuilt with them, so never stale)
	if(interface::fs::path_exists(out_dir+"/"+module_name+".wasm")){
		log_i(MODULE, "%s: wasm/ is built with this server", cs(module_name));
		return out_dir+"/"+module_name+".wasm";
	}
	log_e(MODULE, "%s: wasm/ is not built, and this server cannot build it",
			cs(module_name));
	return "";
#endif
	if(rust)
		return build_rust(config, module_name, module_path, source, files,
				out_dir, hash);
	const ss_ cc = config.get<ss_>("wasm_cc");
	const ss_ ld = config.get<ss_>("wasm_ld");
	if(cc.empty() || ld.empty()){
		log_e(MODULE, "%s has %s/, and this server has no clang and wasm "
				"linker to build it (tried %s). Install clang and lld, or set "
				"BUILDAT_WASM_CC and BUILDAT_WASM_LD.",
				cs(module_name), cs(source), cs(config.get<ss_>("wasm_tried")));
		return "";
	}

	const auto t0 = std::chrono::steady_clock::now();
#ifdef _WIN32
	const ss_ tmp = out_dir+"/"+hash+".tmp";
#else
	const ss_ tmp = out_dir+"/"+hash+"."+itos(getpid())+".tmp";
#endif
	interface::fs::create_directories(tmp);
	ss_ objects;
	bool ok = true;
	for(size_t i = 0; ok && i < sources.size(); i++){
		const ss_ &s = sources[i];
		const bool cpp = !ends_with(s, ".c");
		const ss_ obj = tmp+"/"+itos(i)+".o";
		const ss_ command = quote(cc)+" "+WASM_CFLAGS+
				(cpp ? " -std=c++17 -fno-exceptions -fno-rtti" : " -std=c11")+
				" -I"+quote(include_dir)+" -c "+quote(src_dir+"/"+s)+
				" -o "+quote(obj);
		ok = run_logged(command, tmp+"/compile.log");
		objects += " "+quote(obj);
	}
	if(ok){
		const bool rust_lld = ends_with(ld, "rust-lld") ||
				ends_with(ld, "rust-lld.exe");
		const ss_ command = quote(ld)+(rust_lld ? " -flavor wasm " : " ")+
				WASM_LDFLAGS+objects+" -o "+quote(tmp+"/out.wasm");
		ok = run_logged(command, tmp+"/link.log");
	}
	if(ok)
		ok = interface::fs::rename(tmp+"/out.wasm", out);
	interface::fs::remove_all(tmp);
	if(!ok){
		log_e(MODULE, "%s: building %s/ failed", cs(module_name), cs(source));
		return "";
	}
	const int ms = (int)std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now() - t0).count();
	log_i(MODULE, "%s: built %s/ in %i ms: %s (%zu bytes)", cs(module_name),
			cs(source), ms, cs(out), read_file(out).size());
	return out;
}

}
// vim: set noet ts=4 sw=4:
