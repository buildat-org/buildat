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

(Commits, what changed where, checks run and their results, anything
open.)
