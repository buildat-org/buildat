// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "core/log.h"
#include "interface/module.h"
#include "interface/server.h"
#include "interface/event.h"
#include "interface/fs.h"
#include "client_file/api.h"
#include "network/api.h"
#include <cereal/archives/binary.hpp>
#include <cereal/types/string.hpp>
#include <fstream>
#include <streambuf>
#define MODULE "client_lua"

using interface::Event;

namespace client_lua {

struct Module: public interface::Module
{
	interface::Server *m_server;

	Module(interface::Server *server):
		m_server(server),
		interface::Module(MODULE)
	{
		log_d(MODULE, "client_lua construct");
	}

	~Module()
	{
		log_d(MODULE, "client_lua destruct");
	}

	void init()
	{
		log_d(MODULE, "client_lua init");
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

	void on_start()
	{
	}

	void on_module_loaded(const interface::ModuleLoadedEvent &event)
	{
		log_t(MODULE, "on_module_loaded(): %s", cs(event.name));
		ss_ module_name = event.name;
		ss_ module_path = m_server->get_module_path(module_name);
		// A variant's <module>/client_lua/<file> over its base's or
		// builtin's module's, one file at a time, and the module's own
		// directory with no meta.json in the variant ([LUANTI_APP_PACKAGES])
		const ss_ own = m_server->get_modules_path()+"/"+module_name+
				"/client_lua";
		sm_<ss_, ss_> files;
		for(const ss_ &dir : {module_path+"/client_lua", own})
			for(const interface::fs::Node &n : interface::fs::list_directory(dir))
				if(!n.is_directory)
					files[n.name] = dir+"/"+n.name;
		if(files.empty())
			return;
		const bool other = own != module_path+"/client_lua";
		sv_<ss_> log_list;
		for(const auto &f : files)
			log_list.push_back(other && f.second.compare(0, own.size(), own)
					== 0 ? f.first+" (the variant's)" : f.first);
		log_i(MODULE, "client_lua: %s: %s", cs(module_name), cs(dump(log_list)));
		for(const auto &f : files){
			client_file::access(m_server, [&](client_file::Interface *i){
				i->add_file_path(module_name+"/"+f.first, f.second);
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
	BUILDAT_EXPORT void* createModule_client_lua(interface::Server *server){
		return (void*)(new Module(server));
	}
}
}
// vim: set noet ts=4 sw=4:
