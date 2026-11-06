#!/bin/bash
# A release in one go: bump VERSION, commit it on the development branch
# (whatever is checked out), tag that commit v<version>, and push the
# branch to bitbucket (its backup) and to github with the tag, which
# package.yml turns into a release with the archives. The branch is
# released as it is, history and all (user, 2026-10-05). The session
# working in the tree is not disturbed: only VERSION is committed, its
# other changes are left as they are.
#
#   util/release.sh            # patch: 0.3.1 -> 0.3.2
#   util/release.sh minor      # 0.3.1 -> 0.4.0
#   util/release.sh major      # 0.3.1 -> 1.0.0
#   util/release.sh alpha 0.8.0   # 0.7.99 -> 0.8.0-alpha.1
#   util/release.sh alpha         # 0.8.0-alpha.1 -> 0.8.0-alpha.2
#   PUSH=0 util/release.sh     # everything but the push
#
# **An alpha** ([ALPHA_BUILDS]): github gets only the tag, not the branch, and
# after a push that went through, all but the newest 5 v*-alpha.* releases
# are deleted there with their tags (gh; that failing is a warning). GITHUB_REPO
# names the repository for gh, else it is read off the github remote.
set -eu
here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$here"
part="${1:-patch}"
# The branch is never named here: a release is of whatever is checked
# out, so renaming the development branch carries through
branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = HEAD ]; then
	echo "detached HEAD; check out the development branch first" >&2; exit 2
fi
if ! git diff --quiet HEAD -- VERSION; then
	echo "VERSION has uncommitted changes; commit or revert them first" >&2; exit 2
fi
current=$(cat VERSION)
core=${current%%-*}
if [ "$part" != alpha ] && [ "$core" != "$current" ]; then
	echo "VERSION is $current, an alpha or other pre-release: $part does not" \
		"apply; util/release.sh alpha for the next one, or set VERSION to the" \
		"stable number by hand first" >&2
	exit 2
fi
IFS=. read -r ma mi pa <<< "$core"
case "$part" in
	major) ma=$((ma + 1)); mi=0; pa=0; v="$ma.$mi.$pa" ;;
	minor) mi=$((mi + 1)); pa=0; v="$ma.$mi.$pa" ;;
	patch) pa=$((pa + 1)); v="$ma.$mi.$pa" ;;
	alpha)
		base="${2:-}"
		n=0
		case "$current" in
			*-alpha.*)
				n=${current##*-alpha.}
				[ -z "$base" ] && base=$core ;;
			*)
				if [ -z "$base" ]; then
					echo "VERSION is $current: the first alpha names the version" \
						"it leads to: util/release.sh alpha <major>.<minor>.<patch>" >&2
					exit 2
				fi ;;
		esac
		if ! [[ $base =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
			echo "alpha: $base is not <major>.<minor>.<patch>" >&2; exit 2
		fi
		if [ "$base" != "$core" ] || [ "$core" = "$current" ]; then
			# A pre-release of a number at or below a stable one reads as older
			if [ "$(printf '%s\n%s\n' "$core" "$base" | sort -V | tail -n 1)" != "$base" ] ||
					{ [ "$base" = "$core" ] && [ "$core" = "$current" ]; }; then
				echo "alpha: $base is not above VERSION's $current" >&2; exit 2
			fi
			n=0
		fi
		v="$base-alpha.$((n + 1))" ;;
	*) echo "usage: util/release.sh [major|minor|patch|alpha [<major>.<minor>.<patch>]]" >&2; exit 2 ;;
esac
echo "$v" > VERSION
# Only this file, whatever else is in flight in the tree
git commit -q -m "version: $v" -- VERSION
# package.yml fires on the tag; a plain v<version> is a release (user,
# 2026-10-09), and one with a - in it, an alpha or one with a hash as the
# earlier ones are, a prerelease
t="v$v"
git tag "$t"
echo "committed version $v on $branch, tagged $t"
[ "${PUSH:-1}" = 1 ] || exit 0

# What the channel's tags number, and only that: any other tag is not touched
ALPHA_TAG='^v[0-9]+\.[0-9]+\.[0-9]+-alpha\.[0-9]+$'
prune_alphas() {
	local repo tags old o bad=0
	repo=${GITHUB_REPO:-$(git remote get-url github |
		sed -E 's#^.*github\.com[:/]##; s#\.git$##')} || return 1
	tags=$(git ls-remote --refs --tags github | sed 's#.*refs/tags/##') || return 1
	old=$(printf '%s\n' "$tags" | grep -E "$ALPHA_TAG" | sort -V | head -n -5 || true)
	for o in $old; do
		echo "deleting the old alpha $o"
		gh release delete "$o" --repo "$repo" --cleanup-tag --yes || bad=1
	done
	return $bad
}

# A push failing midway: the commit and the tag are made, so running this
# again would make another version
left() { # what is left to do, a command per argument
	local c
	echo "committed and tagged $t, but the push failed: do not run this again." >&2
	echo "Left to do by hand:" >&2
	for c in "$@"; do
		echo "  $c" >&2
	done
	exit 1
}
if [ "$part" = alpha ]; then
	# The tag alone: the branch stays off github
	to_github=("refs/tags/$t")
else
	to_github=("$branch" "$t")
fi
git push bitbucket "$branch" ||
	left "git push bitbucket $branch" "git push github ${to_github[*]}"
git push github "${to_github[@]}" ||
	left "git push github ${to_github[*]}"
if [ "$part" = alpha ]; then
	prune_alphas || echo "warning: old alphas not pruned on github; the release" \
		"stands. See 'gh release list', and delete by hand all but the last 5" \
		"with: gh release delete <tag> --cleanup-tag --yes" >&2
fi
