Contributing to buildat
=======================

Where things go
---------------

- **Problems, ideas and questions**: a ticket on the tracker at
  https://forum.buildat.org. GitHub's issue tracker is off; GitHub holds
  the repository, its pull requests and its release builds, and nothing
  here needs a GitHub account.
- **A change**, any of:
  - a patch (`git format-patch`) attached to a ticket;
  - a ticket whose tracker link points at your branch, on any git host;
  - a pull request on GitHub.
- **A vulnerability**: [SECURITY.md](SECURITY.md), by mail, not in a
  public ticket.

A commit that answers a ticket ends with its number, `[#1234]`
(`doc/conventions.txt`).

Terms
-----

By offering a change you state that you wrote it, or have the right to
offer it, and that it may be distributed under the licence of the file
it touches:

- **`builtin/luanti/` and `extensions/luanti_client/`**, outside their
  `vendor/` directories: **`Apache-2.0 OR MIT`**. Both licences, at the
  recipient's choice. This is deliberate and it is the one thing here
  worth reading twice: Luanti is LGPL-2.1-or-later, Apache-2.0 is
  incompatible with LGPL-2.1, and MIT is not -- so a Luanti developer
  can take a function out of this Luanti client and carry it home. A
  contribution offered under Apache alone would close that door for
  everybody, which is why it cannot be accepted there.
- **Everything else**: `Apache-2.0`, as the rest of the tree is.
- **`vendor/` directories**: not ours. They carry the licence of the
  project they came from, and a change to one belongs upstream.

No CLA, no paperwork, no copyright assignment. A `Signed-off-by:` line
in the commit (`git commit -s`), the Developer Certificate of Origin's
form, is welcome and is not required.

Every file outside `vendor/` in the two subtrees above carries
`SPDX-License-Identifier: Apache-2.0 OR MIT` in its header; a new file
there wants the same line. `MIT.txt` and `LICENSE` beside it have the
texts.

Code taken from elsewhere
-------------------------

Where a file **transcribes** another project's source rather than
reimplementing a behaviour, the header says so and names that project's
licence -- `builtin/luanti/lua/misc.lua`'s day/night table is the
example. Reimplementing a documented behaviour is not transcription and
wants no such line.

Assets follow the same rule, written down where they sit:
`extensions/luanti_client/res/LICENSE` is how it is done.

Checks
------

A change is expected to leave the quick tier green:

    util/run_all.sh quick

CI on GitHub is not green yet; a local run is what counts.

and, if it touches the Luanti module or a renderer, the full tier,
which wants the game media (`util/media_fetch.sh`). The tiers are
described at the top of `util/run_all.sh`;
`util/checks_in_docker.sh` runs one the way CI does.

Non-trivial logic leaves one runnable check behind. A runner says
`PASS:` or `FAIL:` on its last line and exits by it -- that contract is
in `util/check_lib.sh`, and `util/check_contract.sh` reads every runner
for it.

Style
-----

Match the file you are in. The tree is tabs, 80 columns, and comments
that say why rather than what.
