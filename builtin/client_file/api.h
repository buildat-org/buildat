// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "interface/event.h"
#include "interface/server.h"
#include "interface/server_config.h"
#include "interface/fs.h"
#include "core/log.h"
#include "network/api.h"

namespace client_file
{
	struct FilesTransmitted: public interface::Event::Private
	{
		network::PeerInfo::Id recipient;

		FilesTransmitted(const network::PeerInfo::Id &recipient): recipient(
					recipient){}
	};

	struct Interface
	{
		// A file the server holds the bytes of. Calling it again with the
		// same name replaces the file, and every connected client is told.
		virtual void add_file_content(const ss_ &name, const ss_ &content) = 0;

		// A file on disk. Only its hash is kept; it is read again when a
		// client asks for it, so a game's whole asset tree costs the server
		// its hashes and not its bytes.
		//
		// With watch_client_files set, the file is watched and an edit
		// reaches a running client. That is off by default: it is an inotify
		// watch per directory, which is for developing a game and not for
		// serving one.
		virtual void add_file_path(const ss_ &name, const ss_ &path) = 0;
		// Many at once, announced to the connected clients in one packet:
		// a game's thousands of media files added one by one reached a
		// client already connected as thousands of announce, request and
		// transfer round trips ([FIRST_RUN])
		virtual void add_file_paths(const sv_<std::pair<ss_, ss_>> &name_paths) = 0;
		// The server's icon as clients get it at a connect, "" for none;
		// Starport's listing carries it too ([SERVER_ICONS])
		virtual ss_ get_server_icon() = 0;
	};

	inline bool access(interface::Server *server,
			std::function<void(client_file::Interface*)> cb)
	{
		return server->access_module("client_file", [&](interface::Module *module){
			cb((client_file::Interface*)module->check_interface());
		});
	}

	// [LC_SKY_SHARED] A client extension served under its own names:
	// <share>/extensions/<name>/<file> as <name>/<file>. A game's client
	// then runs its server's copy (buildat.run_script_file("<name>/
	// init.lua")), and the resources it names resolve to the served files
	// before the client's bundled ones -- the version the server knows,
	// whatever the client was built with.
	// simplified: the extension's own directory, not its subdirectories
	inline void serve_extension(interface::Server *server, const ss_ &name)
	{
		const ss_ dir = server->get_config().get<ss_>("share_path")+
				"/extensions/"+name;
		sv_<std::pair<ss_, ss_>> files;
		ss_ names;
		for(const interface::fs::Node &n : interface::fs::list_directory(dir)){
			if(!n.is_directory){
				files.push_back({name+"/"+n.name, dir+"/"+n.name});
				names += " "+name+"/"+n.name;
			}
		}
		log_i("client_file", "Serving the extension %s:%s", cs(name),
				cs(names));
		access(server, [&](client_file::Interface *i){
			i->add_file_paths(files);
		});
	}
}
// vim: set noet ts=4 sw=4:
