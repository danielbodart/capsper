#!/usr/bin/env bash
# The last release before the commit checked out: prints its tag and the
# trunk commit it released, "v<V> COMMIT", or nothing (exit 1) if there is
# none. mise run release-due diffs against COMMIT, and CI's release notes
# list the commits since it.
#
# A release's tag is not on trunk. It names a commit of its own whose
# parent is the released trunk commit and which adds only nix/release.json
# (ci.yml's release job says why), so `git describe`, which looks for tags
# among HEAD's ancestors, finds none. The released commit is the tag's
# parent; the tags made before that change name the trunk commit itself,
# and count too. Of the tags whose released commit is an ancestor of HEAD
# (or HEAD), the newest by version is the last: the minor is the commit
# count, so it orders them along trunk.
set -euo pipefail
unset CDPATH

cd "$(git rev-parse --show-toplevel)"

while read -r tag; do
    for c in "$tag^{commit}" "$tag^{commit}^"; do
        commit=$(git rev-parse -q --verify "$c" 2>/dev/null) || continue
        if git merge-base --is-ancestor "$commit" HEAD; then
            echo "$tag $commit"
            exit 0
        fi
    done
done < <(git tag --list 'v[0-9]*' --sort=-v:refname)
exit 1
