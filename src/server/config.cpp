// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2014 Perttu Ahola <celeron55@gmail.com>
#include "server/config.h"
#include "core/log.h"
#include "boot/autodetect.h"
#include <fstream>
#define MODULE "config"

namespace server {

Config::Config()
{
	// Paths are filled in by autodetection
	set_default("rccpp_build_path", "");
	// The shared build a boxed server only reads ([PROCESS_SANDBOX]); set
	// by server::confine()
	set_default("rccpp_prebuilt_path", "");
	// The ports a boxed server may connect to beyond buildat's own, the
	// admin's (--connect-ports, BUILDAT_CONNECT_PORTS): "8080,2525" or "any"
	set_default("connect_ports", "");
	// Started by a boxed parent, in the box (Windows; --boxed)
	set_default("boxed", false);
	// What the box is made of, for an admin's Health page
	// ([SERVER_ADMIN_PAGE]); set by main() and server::confine()
	set_default("box", "");
	set_default("interface_path", "");
	set_default("share_path", "");
	set_default("cache_path", "");
	set_default("root_path", "");
	set_default("log_file", "");
	set_default("log_level_given", false);
	set_default("log_path", "");
	set_default("user_path", "");
	set_default("urho3d_path", "");
	set_default("compiler_command", "");
	set_default("network_address", "any");
	set_default("network_port", "29500");
	// The launcher's token for its own client, from BUILDAT_OWNER_TOKEN;
	// see builtin/accounts. Empty for a server nobody launched.
	set_default("owner_token", "");
	// <user>/first_admin's line, read by main() ([FIRST_ADMIN])
	set_default("first_admin", "");
	// [LOGIN_UNLOADED]: seconds a right password waits for its TOTP code
	set_default("totp_wait_s", "300");
	// [ADMIN_NOTIFY] One ntfy push a person in this many seconds
	set_default("ntfy_batch_s", "300");
	// [SERVER_CAPS]: the operator's --max-players, --max-view-range
	// (voxels) and --max-disk-mb ([SAVE_LIMIT]; --max-world-mb its old
	// name); "0" is none
	set_default("max_players", "0");
	set_default("max_view_range", "0");
	// [SAVE_CHECKPOINT]: seconds between writes of a running world, 0 none
	set_default("save_interval_s", "5.3");
	set_default("max_disk_mb", "0");
	// The web client's build ([WEB_CLIENT]); empty is <share_path>/web
	set_default("web_client_path", "");
	// Whose X-Forwarded-For is believed for a WebSocket client's address
	// ([FP_ACCESS] 6): comma separated, loopback being nginx on the box
	set_default("web_trusted_proxies", "127.0.0.1,::1");
	// What an untrusted launcher asked for, key=value a line, through -u;
	// a module reads it as it would a packet ([LAUNCH_GRID])
	set_default("untrusted_launch", "");
	// The name a dedicated server announces itself to the LAN under
	// ([LAN_DISCOVERY]; --lan-announce, BUILDAT_LAN_ANNOUNCE); "" is not
	// announced
	set_default("lan_announce", "");

	set_default("skip_compiling_modules", json::object());

	// Whether client_file watches the files it serves and pushes an updated
	// one to connected clients. That is what makes a game's client Lua
	// editable while a client is running, and it is what the feature is for
	// -- but it is an inotify watch per directory, which does not scale to a
	// game whose media is a few hundred megabytes, and it is not something a
	// production server wants at all. On for development, off otherwise.
	set_default("watch_client_files", false);

	// Whether a module is restarted when its own source changes. It is the
	// same kind of thing as the line above and off for the same kind of
	// reason, with one of its own: a reload throws away whatever the module
	// was holding -- for builtin/luanti the running game, the joined player,
	// every core.after a probe registered -- and nothing says the run is now
	// invalid, so a scripted run whose screenshots come a minute in
	// photographs a world that restarted under it. On for development, off
	// otherwise; see -R.
	set_default("reload_modules", false);
	set_default("compile_only", false);
	// [SIM_CLOCK]: --sim-clock, never a setting
	set_default("sim_clock", false);
}

bool Config::check_paths()
{
	bool ok = boot::autodetect::check_server_paths(*this, false);
	if(!ok)
		boot::autodetect::check_server_paths(*this, true);
	return ok;
}

}
// vim: set noet ts=4 sw=4:
