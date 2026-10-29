// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/json.h"

namespace interface
{
	// [AITTA_MVP]: an app as a signed package. A release is two files:
	// <author>-<name>-<version>.zip, the app's directory with its manifest
	// (meta.json at its root), and the same name with .sig, which carries
	// the zip's sha256, the author's public key and the key's signature
	// over the hash.
	//
	// The key is ECDSA P-256 through Mbed TLS (decided in
	// doc/plan/aitta_plan.md), and signing is deterministic (RFC 6979).
	namespace aitta
	{
		// The engine API an app is written against, its modules' and its
		// manifest's "engine_api". **Bumped when a change in src/interface
		// or the served Lua API breaks apps**; this engine runs
		// ENGINE_API_MIN...ENGINE_API, and an app outside that is refused
		// at load and not installed. 0.7 is 2 ([COMPAT_BREAK_07] 8c).
		static const int ENGINE_API_MIN = 2;
		static const int ENGINE_API = 2;
		// "" when this engine runs api, else why not, for a player
		static inline ss_ engine_api_refusal(int64_t api)
		{
			if(api < ENGINE_API_MIN)
				return "it is made for an older Buildat (engine API "+
						itos(api)+"; this one runs "+itos(ENGINE_API_MIN)+
						"-"+itos(ENGINE_API)+")";
			if(api > ENGINE_API)
				return "it needs a newer Buildat (engine API "+itos(api)+
						"; this one runs "+itos(ENGINE_API_MIN)+"-"+
						itos(ENGINE_API)+")";
			return "";
		}

		// A new key: the file's text, and its public half as hex
		void keygen(ss_ &key_file_text, ss_ &public_hex);
		// The public half of a key file's text; throws on a bad one
		ss_ public_of(const ss_ &key_file_text);
		// A .sig's "format", which the signature covers with the hash: a
		// release's never verifies as a page's ([AITTA_PACKAGE_PAGE])
		static const char *const RELEASE_FORMAT = "aitta-release-1";
		static const char *const PAGE_FORMAT = "aitta-page-1";

		// The key's signature over data's sha256, as hex
		ss_ sign(const ss_ &key_file_text, const ss_ &data,
				const char *format = RELEASE_FORMAT);
		bool verify(const ss_ &public_hex, const ss_ &data,
				const ss_ &signature_hex, const char *format = RELEASE_FORMAT);
		// The same, given the data's sha256 as hex: a registry checks who
		// signed a release before the archive has arrived
		bool verify_hash(const ss_ &public_hex, const ss_ &sha256_hex,
				const ss_ &signature_hex, const char *format = RELEASE_FORMAT);

		// A module's meta.json checked ([COMPAT_BREAK_07] 8c): "" or why
		// not. builtin: one Buildat comes with, which says no engine_api
		ss_ module_meta_refusal(const json::Value &v, bool builtin);

		// The manifest's fields checked; "" or why not. service: an
		// Aitta's, which keeps releases for every engine and of a kind or
		// audience a newer Buildat added, and leaves it to the client to
		// say which it runs; otherwise "engine_api" is in this engine's
		// range and the kind and audience are ones it knows
		ss_ check_manifest(const json::Value &m, bool service = false);

		// [PACKAGE_MEDIA] A package's image checked by its header: which
		// "icon", a square PNG of 256 px a side and 64 KB at most, or
		// "screenshot", a PNG or a JPEG (baseline or progressive, 8-bit:
		// what the client's decoder takes) of 1920 px a side and 2 MB at
		// most. "" or why not; *type "image/png" or "image/jpeg".
		// simplified: the header only; the client and the browser decode
		// the rest, as a server's icon
		ss_ media_check(const ss_ &which, const ss_ &data,
				ss_ *type = nullptr);
		// The manifest's "icon" and "screenshot" in dir checked: "" or why
		// not
		ss_ check_media(const json::Value &m, const ss_ &dir);
		// [AITTA_PACKAGE_PAGE] A package's page on Aitta, its page.json
		// ({package, time_ms, description, screenshots: [names]}) and the
		// files it names: "" or why not. The description 20000 characters
		// at most, up to 8 screenshots, each as the manifest's.
		ss_ check_page(const json::Value &page, const sm_<ss_, ss_> &files);
		// page_dir's description.txt and its PNG and JPEG screenshots (in
		// the order of their names) as <author>-<name>-page.zip in
		// out_dir, signed in PAGE_FORMAT with the key in key_path: the
		// zip's path; throws why not
		ss_ pack_page(const ss_ &page_dir, const ss_ &package,
				const ss_ &key_path, const ss_ &out_dir);
		// "app", "extension" ([AITTA] step 3's second kind): a client
		// extension, run in the client's sandbox under the name
		// "<author>__<name>", or "world" ([WORLD_PACKAGES], install_world())
		ss_ kind_of(const json::Value &m);

		// A SemVer 2.0 version, 40 characters at most
		bool semver_ok(const ss_ &v);

		// [LUANTI_APP_PACKAGES] The app a variant is made on ([GAME_BASE]):
		// its manifest's "base", a plain name -- an app beside app_dir, as
		// in the tree, else one shipped in <share_path>/apps -- or
		// "<author>.<name>", an installed package: the newest installed
		// version, or with "base_version" the newest of its major at that
		// version or above. The base's directory; "" with *why empty for
		// no base, "" with *why set for one not there.
		ss_ find_base(const json::Value &m, const ss_ &app_dir,
				const ss_ &share_path, const ss_ &user_path, ss_ *why);

		// What pack() puts in the archive: every file under dir, '/'
		// separated, the names starting with '.' and aitta_page/ (the
		// package's page, pack_page()'s) left out
		sv_<ss_> package_files(const ss_ &dir);

		// Packs app_dir (meta.json at its root) into out_dir and signs it
		// with the key in key_path. Returns the zip's path; throws why not.
		// built: {name in the archive, file} added to it, over a file of
		// the same name (a serverless package's .wasm, app::serverless_wasms)
		ss_ pack(const ss_ &app_dir, const ss_ &key_path, const ss_ &out_dir,
				const sv_<std::pair<ss_, ss_>> &built = {});

		// Checks a release -- the hash, the signature, the manifest, the
		// engine API -- and unpacks it into
		// <user>/installed/<author>/<name>/<version>/. The first install of
		// an author/name keeps its key, and a later version signed by
		// another key is refused. Returns the directory; throws why not.
		// review: a reviewer's playtest ([AITTA_REVIEW]), an app only, into
		// <user>/review/<author>__<name>/<version>/, no key kept, over one
		// there was.
		// share_path given: a variant whose base is not there (find_base())
		// is refused, naming it.
		ss_ install(const ss_ &zip_path, const ss_ &sig_path,
				const ss_ &user_path, bool review = false,
				const ss_ &share_path = "");

		// [WORLD_PACKAGES] A world: a save on top of a named app ("kind":
		// "world", "app", "app_version", "buildat_version"), its save
		// directory in world/ as the app keeps it. Checked as install()
		// checks a release, then put in as a new save of app,
		// <user>/apps/<app>/saves/<name>, named by the package or the
		// next free name; .world_package in it says which release, for
		// the app to take it as a stranger's on its first open. app: the
		// app that takes worlds (its launcher's ctx.world_packages), which
		// the manifest's must be; code: the paths in a save the app runs
		// as code, refused. The save's name; throws why not.
		static const size_t WORLD_FILES_MAX = 20000;
		static const uint64_t WORLD_UNPACKED_MAX =
				(uint64_t)1024 * 1024 * 1024;
		ss_ install_world(const ss_ &zip_path, const ss_ &sig_path,
				const ss_ &user_path, const ss_ &share_path, const ss_ &app,
				const sv_<ss_> &code);
	}
}
// vim: set noet ts=4 sw=4:
