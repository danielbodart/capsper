#!/usr/bin/env bash
# Tests scripts/last-release.sh in a throwaway repository: with no tag there
# is no last release; a tag made the old way, on the trunk commit, names
# that commit; a tag on a child commit off trunk (ci.yml's release job)
# names its parent; the newest of them by version wins; and a release made
# from a commit HEAD does not have (a later trunk, seen from an older
# checkout) is not this checkout's last. Run by mise run check.
set -euo pipefail
unset CDPATH

script=$(cd "$(dirname "$0")" && pwd)/last-release.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

cd "$work"
git init -q -b trunk
git config user.name test
git config user.email test@example.com
git config commit.gpgsign false
git config tag.gpgsign false
commit() { git commit -q --allow-empty -m "$1"; git rev-parse HEAD; }
expect() {
    local want=$1 got
    got=$("$script" 2>/dev/null) || got=none
    [ "$got" = "$want" ] || fail "$2: want '$want', got '$got'"
}

c1=$(commit one)
expect none "no tags"

git tag v0.1.1
expect "v0.1.1 $c1" "an old tag on trunk"

c2=$(commit two)
# A release's tag: a child of c2, holding nix/release.json, on no branch.
git checkout -q --detach "$c2"
mkdir -p nix && echo '{}' >nix/release.json && git add nix/release.json
git commit -q -m "Release v0.2.2"
git tag v0.2.2
git checkout -q trunk
expect "v0.2.2 $c2" "a child tag"

c3=$(commit three)
expect "v0.2.2 $c2" "a child tag, trunk moved on"

git checkout -q --detach "$c3"
mkdir -p nix && echo '{}' >nix/release.json && git add nix/release.json
git commit -q -m "Release v0.3.3"
git tag v0.3.3
git checkout -q "$c2"
expect "v0.2.2 $c2" "a later release ahead of HEAD"
git checkout -q trunk
expect "v0.3.3 $c3" "the newest of several"

if [ $failures -gt 0 ]; then
    exit 1
fi
echo "last-release: ok"
