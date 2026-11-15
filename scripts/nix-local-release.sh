#!/usr/bin/env bash
# Makes this checkout's flake a release of a tarball built here, without
# publishing anything: writes nix/release.json for it, stages it (a flake
# in a git checkout sees only what git tracks), and adds the tarball to the
# Nix store under the very path fetchurl would fetch it to, so the package
# is made from this file and nothing is downloaded.
#
# CI's nix job does this with the tarball its own linux job made, so the
# checks run the binary this run will release, through the same
# release.json, fetchurl and patching as a pinned tag; the weekly update
# does it with the tarball it built. The path is sound because it is
# content-addressed: fetchurl's output is fixed by its name (the tarball's)
# and its hash (release.json's), and nix-store --add-fixed computes the
# hash from the file, so only the file whose hash release.json names can
# stand in for the download.
#
# usage: scripts/nix-local-release.sh VERSION DIR
#
# DIR holds capsper-linux-x86_64.tar.gz and a SHA256SUMS naming it, as
# `mise run dist` leaves dist/. The release.json it leaves staged must never
# be committed to trunk (ci.yml's release job says why).
set -euo pipefail
unset CDPATH

if [ $# -ne 2 ]; then
    echo "usage: scripts/nix-local-release.sh VERSION DIR" >&2
    exit 2
fi
version=$1
dir=$(cd "$2" && pwd)
scripts=$(cd "$(dirname "$0")" && pwd)

cd "$(git rev-parse --show-toplevel)"
mkdir -p nix
"$scripts/release-json.sh" "$version" "$dir/SHA256SUMS" >nix/release.json
git add nix/release.json
nix-store --add-fixed sha256 "$dir/capsper-linux-x86_64.tar.gz" >/dev/null
cat nix/release.json
