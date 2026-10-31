# Work for the cloud session, on kit (2026-10-31)

One item on the kit branch (Kit, unreleased: no compatibility with older
Kit, Workbench or Aitta installs is kept). The rules are round 1's
(claude/cloud-tasks): commit on this branch only, as `git -c
user.name=Claude -c user.email=claude@buildat.org commit`, no
Co-Authored-By, the item's tag in the subject, no PROBE lines; the three
BUILDAT_*_DEFAULTs at https://127.0.0.1:9; no check delay over 2 s;
results below. Another session works on Workbench's launcher and saves
(apps/workbench/launcher, builtin/world_menu) meanwhile: stay out of
those.

## Aitta packages identified by key, not author name [AITTA_KEY_IDENTITY]

Two Aittas (aitta.buildat.org and, say, a school's own) can each bind an
author "alice". Keyed by author name, the second is refused for good on
any server or client that has the first. The user's decision: a package
is the signing key's fingerprint plus its name, everywhere -- Kit's
packages (builtin/kit: package:<a>/<n> rows today, the first-key pin
per author) and apps and anything else installed from Aitta
(`aitta install`: <user>/installed/<author>/<name>/ today, a key pinned
per package). No compatibility: old installs and Kit rows are not
migrated.

**Do**:
- Store and key by fingerprint and name: package:<fp>/<name>,
  <user>/installed/<fp>/<name>/, and wherever else an author name keys a
  package (grep the launcher, the publish screen, Kit's credits and
  palette, doc/aitta.txt).
- The author name is display only. Where two installed authors share a
  name, the credits, palette and launcher add the vouching Aitta's host;
  "unverified" when no Aitta confirmed the key (a local export, an Aitta
  not reached; checked again when one is). The vouching is the
  server's (or the installing client's) own `GET
  /api/v1/aitta/info?key=` to the Aitta the package came from, matching
  the manifest's author -- never what an uploading client claims.
- Manifest dependencies stay `{kit: "author/name", version}`, resolved on
  the Aitta the depending package came from; the key they resolved to is
  kept, so upgrades follow that key.
- The first-key pins go.
- doc/aitta.txt and builtin/kit/api.h say the new model.
- Checks: util/kit_publish_check.sh and util/aitta_check.sh moved to it,
  plus a case of two Aittas with the same author name, both installed
  and both credited with their hosts.

## Results

### [AITTA_KEY_IDENTITY]

Commits:
- ec36f878 Aitta: a package is its key's fingerprint and its name
- f52d1089 Aitta: the checks the key model moved, and a world's app by its author

**The id.** A key's fingerprint is the first 20 hex of sha256 of its
public key hex (`interface::aitta::fingerprint`, Lua
`__buildat_aitta_fingerprint`). Everything installed from Aitta is under
`<user>/installed/<fp>/<name>/<ver>/` with the key in
`installed/<fp>/.key` and the Aitta it came from in `.aitta_from`; an app
runs as `<fp>.<name>@<ver>`, an extension boots as `<fp>__<name>`
(`-m author__name` still finds the one installed of that name), a
playtest is `review/<fp>__<name>`. Kit rows are `package:<fp>/<name>`,
its types and prefabs `<fp>/<n>`. The per-author / per-package first-key
pins are gone: another key's same author/name installs beside it as
another package.

**Display.** The author is display only. The launcher, Apps from Aitta,
the Kit palette and credits label a package `author/name`, with
` @<host>` of its vouching Aitta when two installed packages share the
author name, and ` (unverified)` when no Aitta confirmed the key.

**Vouching.** `vouch_guarded()` (src/impl/aitta.cpp) asks
`GET <aitta>/api/v1/aitta/info?key=<hex>` and matches the answer's author
to the manifest's. The Kit server asks the Aitta the installing client
named (the user's answer: the client names the host, the server limits
it); the client asks for its own installs. The limits against SSRF:
- an origin only (`https://host[:port]`, no path, at most 200 chars,
  host characters checked); http only for loopback;
- every resolved address must be public (no private, link-local, CGNAT,
  multicast, documentation, ULA, v4-mapped ...); loopback only when the
  installing client is itself on this machine (decided by the peer's
  address);
- the connect is pinned to the checked address with CURLOPT_RESOLVE, so a
  second DNS answer cannot move it;
- the server's port allowlist (BUILDAT_CONNECT_PORTS / --connect-ports)
  still applies;
- 4096 bytes and 5 s at most, on a detached thread whose result is taken
  on the server tick; once a minute at most per package; a failure
  leaves it unverified and it is asked again when a client installs it
  again;
- the server setting `kit_vouch` (BUILDAT_KIT_VOUCH): "" asks any Aitta,
  a comma list asks only those, "none" asks none.

**Dependencies** keep the manifest form `{kit: "author/name", version}`;
they are resolved on the depending package's Aitta, and the key they
resolved to is kept, so an upgrade follows that key. A world package's
`app` stays `author.name` too: an exported world names its app by the
installed fingerprint's author, and the world's install resolves it to
the installed app of that author from the world's own Aitta
(`.aitta_from`).

**Docs**: doc/aitta.txt (identity, vouching and its limits, the paths)
and builtin/kit/api.h (`package:<fp>/<name>`, `<fp>/<n>` types, labels).

**Simplifications** (marked `simplified:` in the code):
- an extension's `require` of another extension by `author/name`
  resolves only when exactly one of that name is installed;
- Lua type sources are not rewritten: a type's own code naming another
  type by `author/name` works when that name is unique on the server;
- loopback is allowed by the peer's address, not by any further proof;
- recent_releases (the launcher's "now" strip) still keys by
  author/name, as the Hearth feed does;
- a world's app is found by `.aitta_from`, so a world zip installed by
  hand (no Aitta) needs its app installed from an Aitta first.

**Checks.** Migrated to fingerprint paths and ids: aitta_check,
aitta_pin, aitta_publish, aitta_serve, aitta_web, app_remix,
base_install, release_thread, serve_delisted, serverless,
world_package, lively_menu (its stand-in Aitta's release now has a key;
a release with none is no package), kit_publish. aitta_check adds
another key's same author/name installed beside the first.
kit_publish_check section 5 adds two Aittas each binding "alice" with
its own key and its own alice/lamps: dave installs both on one server,
each vouched by its own Aitta, the palette shows `alice/lamp @host:port`
for each and the credits name both hosts; no "signed with another key"
refusal.

`xvfb-run util/run_all.sh --changed b0318a26..HEAD`: 23 passed,
6 failed, 3 skipped (aitta_web and aitta_on_web: no web/; dual_stack:
no ::1). Every check of the key model passes: aitta, aitta_check,
aitta_pin, aitta_publish, aitta_serve, app_remix, base_install,
kit_publish, kit_controls, lively_menu, release_thread, serve_builds,
serve_delisted, world_package and the rest. (An earlier run also failed
kit_editor and web_join, which this run's set did not pick; both looked
at alone below.)

The failures left are all this machine's, each looked at alone:
- serverless_check: the native part passes; its web part needs Chrome
  (`setsid: failed to execute google-chrome`).
- web_left_dialog_check, web_join_check: no browser
  (`failed to execute firefox`).
- save_icon_check, kit_editor_check, kit_runtime_check: no `sqlite3` CLI
  here (the first makes its saves with it, the others read the save's
  rows with it: "kit's rows are \"\"").
- view_settings_local_check: its client compiles vanilla's 17 modules
  into a fresh cache, and that takes more than the check's 60 s
  "load: the world is in" wait on this machine (13 of 17 compiled at
  60 s, alone and in run_all).
- connect_async: the sandbox refuses 192.0.2.1 at once ("Connection
  refused") instead of blackholing it, so there is no wait to see.

**Open**: none needing a decision. To run on a machine with Chrome,
Firefox and sqlite3: serverless (web part), web_left_dialog, web_join,
save_icon, kit_editor, kit_runtime, connect_async, and
view_settings_local on a faster machine.
