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
// browser and in the client's validator.
static const char *WASM_CFLAGS = "--target=wasm32 -O2 -nostdlib "
		"-ffreestanding -fvisibility=hidden -mcpu=mvp -msign-ext "
		"-mmutable-globals -mnontrapping-fptoint -mbulk-memory";
// The maximum memory is the client's cap (64 MiB): a module declares one,
// and the client refuses one that does not
static const char *WASM_LDFLAGS = "--no-entry --export-dynamic "
		"--gc-sections --strip-all -O2 -z stack-size=65536 "
		"--max-memory=67108864";

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

static bool run_logged(const ss_ &command, const ss_ &log_path)
{
	interface::process::ExecOptions opts;
	opts.output_path = log_path;
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

ss_ build_module_wasm(const core::Config &config, const ss_ &module_name,
		const ss_ &module_path)
{
	const ss_ src_dir = module_path+"/wasm";
	sv_<ss_> files;
	collect(src_dir, "", files);
	std::sort(files.begin(), files.end());
	sv_<ss_> sources;
	for(const ss_ &f : files)
		if(ends_with(f, ".c") || ends_with(f, ".cc") || ends_with(f, ".cpp"))
			sources.push_back(f);
	if(sources.empty()){
		log_e(MODULE, "%s: wasm/ has no .c, .cc or .cpp", cs(module_name));
		return "";
	}
	const ss_ interface_path = config.get<ss_>("interface_path");
	const ss_ include_dir = interface::fs::strip_file_name(interface_path);

	// Keyed by what goes in: a name and its bytes per file, the header, the
	// flags. Not the tools' versions, so that a prebuilt one serves a
	// server without them.
	std::ostringstream key(std::ios::binary);
	key<<"buildat wasm 1\n"<<WASM_CFLAGS<<"\n"<<WASM_LDFLAGS<<"\n";
	key<<read_file(interface_path+"/wasm_api.h");
	for(const ss_ &f : files){
		const ss_ data = read_file(src_dir+"/"+f);
		key<<f<<'\0'<<data.size()<<'\0'<<data;
	}
	const ss_ hash = interface::sha1::hex(interface::sha1::calculate(key.str()));

	const ss_ out_dir = config.get<ss_>("rccpp_build_path")+"/wasm";
	const ss_ out = out_dir+"/"+hash+".wasm";
	if(interface::fs::path_exists(out)){
		log_i(MODULE, "%s: wasm/ is built (cache hit): %s", cs(module_name),
				cs(out));
		return out;
	}
	const ss_ prebuilt_dir = config.get<ss_>("rccpp_prebuilt_path");
	if(!prebuilt_dir.empty() &&
			interface::fs::path_exists(prebuilt_dir+"/wasm/"+hash+".wasm")){
		log_i(MODULE, "%s: wasm/ is in the shared build", cs(module_name));
		return prebuilt_dir+"/wasm/"+hash+".wasm";
	}
#ifdef BUILDAT_STATIC_MODULES
	// [WEB_LOCAL_SERVER]: no compiler in a browser
	log_e(MODULE, "%s: wasm/ is not built, and this server cannot build it",
			cs(module_name));
	return "";
#endif
	const ss_ cc = config.get<ss_>("wasm_cc");
	const ss_ ld = config.get<ss_>("wasm_ld");
	if(cc.empty() || ld.empty()){
		log_e(MODULE, "%s has wasm/, and this server has no clang and wasm "
				"linker to build it (tried %s); the module is refused. Install "
				"clang and lld, or set BUILDAT_WASM_CC and BUILDAT_WASM_LD.",
				cs(module_name), cs(config.get<ss_>("wasm_tried")));
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
		log_e(MODULE, "%s: building wasm/ failed; the module is refused",
				cs(module_name));
		return "";
	}
	const int ms = (int)std::chrono::duration_cast<std::chrono::milliseconds>(
			std::chrono::steady_clock::now() - t0).count();
	log_i(MODULE, "%s: built wasm/ in %i ms: %s (%zu bytes)", cs(module_name),
			ms, cs(out), read_file(out).size());
	return out;
}

}
// vim: set noet ts=4 sw=4:
