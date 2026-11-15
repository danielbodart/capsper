#!/usr/bin/env bash
# Prints nix/release.json for a release: its version, and for each Nix
# system the URL of its release tarball and the tarball's hash in the SRI
# form fetchurl takes. nix/package.nix is that tarball fetched and patched
# for NixOS, not a build from source (Dan, 2026-11-15: the tarballs are
# built once, by mise's Zig, in CI), so a flake pinned at
# github:danielbodart/capsper/v<V> runs the very binary the release carries.
#
# usage: scripts/release-json.sh VERSION SHA256SUMS
#
# SHA256SUMS is the one `mise run sums` writes over the tarballs: each
# platform below must be in it exactly once, under its tarball's name. CI's
# release job commits the output as the tag's own commit, a child of the
# released trunk commit (ci.yml's release job says why); CI's nix job
# writes one for the tarball its own run built, for the checks.
set -euo pipefail
unset CDPATH

if [ $# -ne 2 ]; then
    echo "usage: scripts/release-json.sh VERSION SHA256SUMS" >&2
    exit 2
fi
version=$1
sums=$2

if ! [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "release-json: '$version' is not MAJOR.MINOR.PATCH" >&2
    exit 2
fi

# The tarball's platform and the Nix system it serves. Linux only: the flake
# packages capsper for x86_64-linux alone (flake.nix says why macOS is not
# there), though the macOS tarball is released too.
pairs=(linux-x86_64:x86_64-linux)

# A hex SHA-256 as SRI, sha256-<base64 of the 32 bytes>, without nix (the
# release job has none): bash's printf writes each \xHH as its byte.
sri() {
    local hex=$1 esc='' i
    for ((i = 0; i < ${#hex}; i += 2)); do esc+="\\x${hex:i:2}"; done
    printf 'sha256-%s' "$(printf '%b' "$esc" | base64 | tr -d '\n')"
}

printf '{\n  "version": "%s",\n  "assets": {\n' "$version"
n=0
for pair in "${pairs[@]}"; do
    platform=${pair%%:*}
    system=${pair#*:}
    name="capsper-$platform.tar.gz"
    # No mapfile: the check runs this on macOS too, whose bash is 3.2.
    hex=$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1 }' "$sums")
    found=$(printf '%s' "$hex" | grep -c . || true)
    if [ "$found" -ne 1 ] || ! [[ $hex =~ ^[0-9a-f]{64}$ ]]; then
        echo "release-json: want one sha256 for $name in $sums, found $found" >&2
        exit 1
    fi
    n=$((n + 1))
    sep=,
    [ $n -lt ${#pairs[@]} ] || sep=
    printf '    "%s": {\n      "url": "https://github.com/danielbodart/capsper/releases/download/v%s/%s",\n      "hash": "%s"\n    }%s\n' \
        "$system" "$version" "$name" "$(sri "$hex")" "$sep"
done
printf '  }\n}\n'
