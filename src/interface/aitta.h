// http://www.apache.org/licenses/LICENSE-2.0
// Copyright 2026 Perttu Ahola <celeron55@gmail.com>
#pragma once
#include "core/types.h"
#include "core/json.h"

namespace interface
{
	struct Server;
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
		// "<author>__<name>", "world" ([WORLD_PACKAGES], install_world()),
		// "remix" or "kit" ([KIT] stage 5: component types, prefabs and
		// voxel types, installed into a server's composition by Kit)
		ss_ kind_of(const json::Value &m);

		// a < b in SemVer's order (simplified as aitta.cpp says)
		bool version_less(const ss_ &a, const ss_ &b);

		// A SemVer 2.0 version, 40 characters at most
		bool semver_ok(const ss_ &v);

		// [LUANTI_APP_PACKAGES] The app a variant is made on ([GAME_BASE]):
		// its manifest's "base", a plain name -- an app beside app_dir, as
		// in the tree, else one shipped in <share_path>/apps -- or
		// "<author>.<name>", an installed package (resolve_installed(), on
		// the Aitta in app_dir's .aitta_from; the key it resolved to kept
		// in app_dir's .aitta_base and followed after): the newest installed
		// version, or with "base_version" the newest of its major at that
		// version or above. The base's directory; "" with *why empty for
		// no base, "" with *why set for one not there.
		ss_ find_base(const json::Value &m, const ss_ &app_dir,
				const ss_ &share_path, const ss_ &user_path, ss_ *why);

		// What pack() puts in the archive: every file under dir, '/'
		// separated, the names starting with '.', aitta_page/ (the
		// package's page, pack_page()'s) and any .wasm left out
		sv_<ss_> package_files(const ss_ &dir);

		// Whether a file's name ends in .wasm, in any case: never packed
		// or published, an Aitta builds them ([AITTA_WASM_PAST_REVIEW])
		bool is_wasm_name(const ss_ &name);

		// Packs app_dir (meta.json at its root) into out_dir and signs it
		// with the key in key_path. Returns the zip's path; throws why not.
		ss_ pack(const ss_ &app_dir, const ss_ &key_path, const ss_ &out_dir);

		// **A package is its key and its name** ([AITTA_KEY_IDENTITY]):
		// <fp>/<name>, fp the signing key's fingerprint, the first
		// FINGERPRINT_LEN hex digits of the sha256 of its 65 bytes. Two
		// Aittas may each bind an author "alice"; their packages are two.
		// The manifest's "author" is a name to show, and which Aitta
		// vouches for it (vouch()) says whose. "" for no key.
		static const size_t FINGERPRINT_LEN = 20;
		ss_ fingerprint(const ss_ &public_hex);
		bool fingerprint_ok(const ss_ &s);

		// Checks a release -- the hash, the signature, the manifest, the
		// engine API -- and unpacks it into
		// <user>/installed/<fp>/<name>/<version>/: a version of another
		// key is another package. Returns the directory; throws why not.
		// from: the Aitta it came from, in the version's .aitta_from,
		// which its references to other packages resolve on
		// (resolve_installed()). review: a reviewer's playtest
		// ([AITTA_REVIEW]), an app only, into
		// <user>/review/<fp>__<name>/<version>/, over one there was.
		// share_path given: a variant whose base is not there (find_base())
		// is refused, naming it.
		ss_ install(const ss_ &zip_path, const ss_ &sig_path,
				const ss_ &user_path, bool review = false,
				const ss_ &share_path = "", const ss_ &from = "");

		// [AITTA_NATIVE_WASM] What an installed release's .wasm built by its
		// Aitta are kept in, in the version's directory
		// (doc/aitta.txt, "A release's .wasm on a native server")
		static const char *const BUILT_WASM_DIR = ".aitta_wasm";
		static const size_t BUILT_WASM_MAX = 8 << 20; // wasm/engine.h's cap
		// The names under a dot at an archive's root, which are an
		// install's and its Aitta's own, never a package's (pack() leaves
		// them out): .aitta_wasm, .aitta_from, .aitta_sha256, .web, ...
		// install() drops them and a publish is refused with one.
		sv_<ss_> dotted_root_names(const ss_ &zip_path);
		// A name a release's "web_wasm" may have: <module>.wasm or
		// <module>.server.wasm, the module [A-Za-z0-9_], 64 at most
		bool built_wasm_name_ok(const ss_ &name);
		// A release's "web_wasm" ({name: sha256}) fetched from the Aitta
		// into version_dir/BUILT_WASM_DIR, each name checked, each file its
		// sha256 and at most BUILT_WASM_MAX; one there with that hash is
		// left alone. Blocking. What could not be had, a line each: a failed
		// fetch is no failed install, the server then says it has no .wasm.
		sv_<ss_> fetch_built_wasm(const ss_ &aitta,
				const json::Value &web_wasm, const ss_ &version_dir);

		// [AITTA_KEY_IDENTITY] A package named as its manifests name one
		// -- "<author>/<name>" (a Kit dependency), "<author>.<name>" (a
		// base, a world's app), "<author>__<name>" (an extension) --
		// resolved to an installed one: the fingerprint of the one whose
		// manifest's author that is, from the Aitta `from` (its
		// .aitta_from); with from "" (a local file), the only one by that
		// author and name. "" and *why for none or more than one.
		ss_ resolve_installed(const ss_ &user_path, const ss_ &author,
				const ss_ &name, const ss_ &from, ss_ *why);

		// **Who vouches for a key**: the Aitta's own word, its
		// GET <aitta>/api/v1/aitta/info?key=<key>, whose "author" is the
		// one it binds the key to -- never what a package or an uploading
		// client says. vouch_answer(): that answer's body read against the
		// manifest's author, "" or why not. vouch(): the GET (blocking) and
		// the same.
		ss_ vouch_answer(const ss_ &body, const ss_ &author);
		ss_ vouch(const ss_ &aitta, const ss_ &public_hex, const ss_ &author);
		// The vouch a server asks for a client that named the Aitta
		// (Kit's install of a package): the server's GET to a host it was
		// told, so its reach is narrowed. The Aitta is an origin,
		// https://host[:port] and nothing after it; its name's addresses
		// each a public one (none private, link-local, CGNAT, multicast,
		// unspecified, or loopback: loopback, and http with it, only with
		// loopback_ok, which a caller gives where the asking client is on
		// the server's machine itself and reaches its loopback already);
		// then one GET to the address checked (http_get_pinned): no
		// redirect, VOUCH_MAX_BYTES, VOUCH_TIMEOUT_S. "" when it vouches,
		// else why not.
		static const size_t VOUCH_MAX_BYTES = 4096;
		static const long VOUCH_TIMEOUT_S = 5;
		ss_ vouch_guarded(const ss_ &aitta, const ss_ &public_hex,
				const ss_ &author, bool loopback_ok);
		// An address a server's GET to a host a client named may go to
		// (vouch_guarded()): a numeric v4 or v6
		bool public_address(const ss_ &ip, bool loopback_ok);
		// The host an Aitta's address names ("aitta.buildat.org",
		// "127.0.0.1:8080"), for showing whose an author is
		ss_ aitta_host(const ss_ &aitta);
		// [ALPHA_BUILDS] Why an engine of this version does not publish to
		// this address, "" when it does: an alpha stays off the official
		// Aitta, by the actual name and not the BUILDAT_AITTA_DEFAULT a check
		// or a test Aitta sets. A build could be changed to go past it: it
		// keeps people's test packages out of the list, and it is no
		// protection of the list.
		ss_ publish_refusal(const ss_ &version, const ss_ &aitta);
		// An installed key's vouch, <user>/installed/<fp>/.vouch
		// ({"aitta", "author"}), written by the installing client after
		// its own vouch() (or a GET of its own to the same address) and
		// read for the tile's "alice (aitta.buildat.org)" or "alice
		// (unverified)". record_vouch() writes it; installed_vouch()
		// reads it: the Aitta's address, "" for unverified.
		void record_vouch(const ss_ &user_path, const ss_ &fp,
				const ss_ &aitta, const ss_ &author);
		ss_ installed_vouch(const ss_ &user_path, const ss_ &fp);

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
		// **An app's settings** ([APP_REMIX], doc/aitta.txt's "Settings
		// and remixes"): its manifest's "settings", a list of typed fields
		// {name, type, default, label, description, and the type's own:
		// number min, max, integer; text max_length; choice choices}, the
		// types number, bool, choice, color ("#rrggbb"), text, texture,
		// model and world (a file of the app by the name its client
		// reads it by, "<module>/<path under client_data>": .png .jpg
		// .jpeg, .mdl, .json). "" or why not.
		static const unsigned SETTINGS_MAX = 64;
		ss_ check_settings_schema(const json::Value &settings);
		// A value for a field of such a list: "" or why not. files: the
		// app's file names (app_client_files()) that a file type's value
		// must be one of; null takes any of the type's shape
		ss_ check_setting_value(const json::Value &field, const json::Value &v,
				const set_<ss_> *files);
		// What an app's modules serve from their client_data:
		// "<module>/<path>" -> the file
		sm_<ss_, ss_> app_client_files(const ss_ &app_dir);
		// A remix ("kind": "remix"): a package on a base app, its
		// "setting_values" and files of its own in place of the base's of
		// the same name (<module>/client_data/<path>: textures, models,
		// sounds, worlds) -- data, never code. dir checked: "" or why not.
		// base_dir "" checks what needs no base (an Aitta's publish);
		// given, each file replaces one of the base's and each value is
		// one of the base's settings and right for it.
		ss_ remix_refusal(const ss_ &dir, const json::Value &m,
				const ss_ &base_dir);
		// Whether a remix may carry a file of this name (by its extension)
		bool remix_replaceable(const ss_ &path);
		// **The one call an app's code reads its settings by**: name ->
		// value, each field's default with a remix's value over it. The
		// fields are the app's own "settings", or its base's for a remix
		// or a variant that declares none. A value that is not right for
		// its field is left at the default.
		json::Value app_settings(const ss_ &app_dir, const ss_ &share_path,
				const ss_ &user_path);
		// The same for the app a server runs: interface::aitta::
		// app_settings(m_server).get("board_size")
		json::Value app_settings(interface::Server *server);

		static const size_t WORLD_FILES_MAX = 20000;
		static const uint64_t WORLD_UNPACKED_MAX =
				(uint64_t)1024 * 1024 * 1024;
		ss_ install_world(const ss_ &zip_path, const ss_ &sig_path,
				const ss_ &user_path, const ss_ &share_path, const ss_ &app,
				const sv_<ss_> &code);
	}
}
// vim: set noet ts=4 sw=4:
