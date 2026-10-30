#!/bin/bash
# The game media the checks want ([CI_RUNS] (4)), fetched from ContentDB
# (and devtest from Luanti's source) into <user>/shared/vanilla/games:
#
#   util/media_fetch.sh            install what is missing
#   util/media_fetch.sh devtest    devtest alone, what the ci tier plays
#   util/media_fetch.sh --key      print author/name and release id per
#                                  line, which is what a CI cache is
#                                  keyed on: a run that changes nothing
#                                  downloads nothing
#
# Only the games a runner names are here. A game already on disk is left
# alone whatever release it is -- this is a fetch, not an updater.
# pipefail: a fetch's 403 is curl's error, not tar's "unexpected end of file"
set -eu -o pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
dest="${BUILDAT_USER_DIR:-$here/user}/shared/vanilla/games"
url="${BUILDAT_CONTENTDB_URL:-https://content.luanti.org}"
# Who is calling, as src/impl/http.cpp says it: ContentDB's bandwidth is
# donated, and a mirror's filter turns libcurl's own name away
ua="buildat/$(cat "$here/VERSION")"
# author/name/installed-as. mineclone2 is VoxeLibre, and the runners
# name it by the directory Luanti installs it under
packages="Wuzzy/mineclone2/mineclone2"
key_only=""
[ "${1:-}" = "--key" ] && key_only=1
[ "${1:-}" = devtest ] && packages=""
mkdir -p "$dest"
for p in $packages; do
	author=${p%%/*}; rest=${p#*/}; name=${rest%%/*}; as=${rest##*/}
	# The newest release: ContentDB's releases list, or, where a mirror
	# serves only what Luanti's own client asks (contentdb.milcho.org),
	# the package's for-client page, which names it too
	rel=$( { curl -fsL -A "$ua" "$url/api/packages/$author/$name/releases/" ||
		curl -fsSL -A "$ua" "$url/api/packages/$author/$name/for-client/"; } |
		python3 -c 'import json,sys; r=json.load(sys.stdin)
print(r.get("release", "") if isinstance(r, dict) else r[0]["id"] if r else "")')
	if [ -z "$rel" ]; then
		echo "no release for $author/$name at $url" >&2; exit 2
	fi
	if [ -n "$key_only" ]; then
		echo "$author/$name $rel"
		continue
	fi
	if [ -e "$dest/$as/game.conf" ]; then
		echo "$as: already here"
		continue
	fi
	zip=$(mktemp /tmp/buildat_media.XXXXXX.zip)
	curl -fsSL -A "$ua" -o "$zip" \
		"$url/packages/$author/$name/releases/$rel/download/"
	# ContentDB's zip has one top directory, whose name is not the
	# package's; the game goes in as the name the runners use
	tmp=$(mktemp -d /tmp/buildat_media.XXXXXX)
	unzip -q "$zip" -d "$tmp"
	mv "$tmp/$(ls "$tmp" | head -1)" "$dest/$as"
	rm -rf "$zip" "$tmp"
	echo "$as: release $rel, $(du -sh "$dest/$as" | cut -f1)"
done

# devtest, the game most luanti runners play: not on ContentDB but in
# Luanti's source, from a pinned tag
# simplified: the tag by hand; the desk's devtest was a snapshot near it
devtest_tag=5.17.0
if [ -n "$key_only" ]; then
	echo "luanti/devtest $devtest_tag"
elif [ -e "$dest/devtest/game.conf" ]; then
	echo "devtest: already here"
else
	tmp=$(mktemp -d /tmp/buildat_media.XXXXXX)
	curl -fsSL -A "$ua" "https://codeload.github.com/luanti-org/luanti/tar.gz/refs/tags/$devtest_tag" |
		tar -xz -C "$tmp" --strip-components=2 "luanti-$devtest_tag/games/devtest"
	mv "$tmp/devtest" "$dest/devtest"
	rm -rf "$tmp"
	echo "devtest: $devtest_tag, $(du -sh "$dest/devtest" | cut -f1)"
fi
