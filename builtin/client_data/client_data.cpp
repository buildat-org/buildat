// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "interface/aitta.h"
#include <algorithm>
#include "client_file/api.h"
#include "network/api.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/string.hpp>
#include <fstream>
#include <streambuf>
#define MODULE "client_data"

using interface::Event;

namespace client_data {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		m_server(server),
		interface::Module(MODULE)
	{
		log_d(MODULE, "client_data construct");
	}

	~Module()
	{
		log_d(MODULE, "client_data destruct");
	}

	void init()
	{
		log_d(MODULE, "client_data init");
		m_server->sub_event(this, Event::t("core:start"));
		m_server->sub_event(this, Event::t("core:module_loaded"));
		m_server->sub_event(this, Event::t("core:module_unloaded"));
		m_server->sub_event(this, Event::t("network:client_connected"));
	}

	void event(const Event::Type &type, const Event::Private *p)
	{
		EVENT_VOIDN("core:start", on_start)
		EVENT_TYPEN("core:module_loaded", on_module_loaded,
				interface::ModuleLoadedEvent)
		EVENT_TYPEN("core:module_unloaded", on_module_unloaded,
				interface::ModuleUnloadedEvent)
		EVENT_TYPEN("network:client_connected", on_client_connected,
				network::NewClient)
	}

	// [APP_REMIX] The app's settings, each field's default with a remix's
	// value over it, as a file the client's buildat.app_settings() reads
	void on_start()
	{
		const ss_ json = interface::aitta::app_settings(m_server).stringify();
		log_i(MODULE, "client_data: the app's settings: %s", cs(json));
		client_file::access(m_server, [&](client_file::Interface *i){
			i->add_file_content("client_data/app_settings.json", json);
		});
	}

	// Files are published as <module>/<path under client_data>, which is the
	// name the client's resource cache knows them by. The subdirectories
	// matter: Urho looks up a shader include and a cube map face relative to
	// the resource that named them.
	void collect_files(const ss_ &dir_path, const ss_ &name_prefix,
			sv_<ss_> &result)
	{
		for(const interface::fs::Node &n : interface::fs::list_directory(dir_path)){
			if(n.is_directory)
				collect_files(dir_path+"/"+n.name, name_prefix+n.name+"/", result);
			else
				result.push_back(name_prefix+n.name);
		}
	}

	void on_module_loaded(const interface::ModuleLoadedEvent &event)
	{
		log_t(MODULE, "on_module_loaded(): %s", cs(event.name));
		ss_ module_name = event.name;
		ss_ module_path = m_server->get_module_path(module_name);
		ss_ client_data_path = module_path+"/client_data";
		sv_<ss_> names;
		collect_files(client_data_path, "", names);
		// A variant's or a remix's <module>/client_data/<path> over its
		// base's, one file at a time, as client_lua's ([APP_REMIX])
		const ss_ own = m_server->get_modules_path()+"/"+module_name+
				"/client_data";
		sv_<ss_> own_names;
		if(own != client_data_path)
			collect_files(own, "", own_names);
		// [CLIENT_WASM] The module's built wasm/, as <module>/<module>.wasm,
		// which buildat.wasm_load(<module>) reads on the client
		const ss_ wasm = m_server->get_module_wasm_path(module_name);
		if(!wasm.empty()){
			log_i(MODULE, "client_data: %s: %s.wasm", cs(module_name),
					cs(module_name));
			client_file::access(m_server, [&](client_file::Interface *i){
				i->add_file_path(module_name+"/"+module_name+".wasm", wasm);
			});
		}
		if(names.empty() && own_names.empty())
			return;

		log_i(MODULE, "client_data: %s: %s", cs(module_name), cs(dump(names)));
		if(!own_names.empty())
			log_i(MODULE, "client_data: %s: the variant's %s", cs(module_name),
					cs(dump(own_names)));
		for(const ss_ &name : own_names)
			if(std::find(names.begin(), names.end(), name) == names.end())
				names.push_back(name);

		for(const ss_ &name : names){
			const bool mine = std::find(own_names.begin(), own_names.end(),
					name) != own_names.end();
			const ss_ &file_path = (mine ? own : client_data_path)+"/"+name;
			const ss_ &public_file_name = module_name+"/"+name;
			client_file::access(m_server, [&](client_file::Interface *i){
				i->add_file_path(public_file_name, file_path);
			});
		}
	}

	void on_module_unloaded(const interface::ModuleUnloadedEvent &event)
	{
		log_v(MODULE, "on_module_unloaded(): %s", cs(event.name));
		// TODO: Tell client_file to remove files
	}

	void on_client_connected(const network::NewClient &client_connected)
	{
	}
};

extern "C" {
	BUILDAT_EXPORT void* createModule_client_data(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
