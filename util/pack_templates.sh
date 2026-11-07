#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# [KIT_TEMPLATES] Workbench's templates packed and signed, each an archive and
# its .sig for `buildat aitta publish` (doc/aitta.txt):
#
#   util/pack_templates.sh <key file> <out dir> [name...]
#
# The key is the caller's: `buildat aitta keygen` makes one, its public half
# bound to the author name on the Aitta, and it is refused inside this tree,
# whose files go into a commit.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
[ $# -ge 2 ] || { sed -n '2,9p' "$0" | sed 's/^# *//' >&2; exit 2; }
key=$(realpath "$1") out=$2
shift 2
case "$key" in
	"$here"/*) echo "the key $key is inside the repo: keep it out" >&2; exit 2 ;;
esac
cd "$here/apps/workbench/templates"
[ $# -gt 0 ] || set -- *
for t in "$@"; do
	"$here/Build/bin/buildat" aitta pack "$t" "$key" "$out"
done
