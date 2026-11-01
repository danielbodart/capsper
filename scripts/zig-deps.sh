#!/usr/bin/env bash
# Moves each build.zig.zon dependency pinned to a GitHub release tag to its
# upstream's latest one (`zig fetch --save`, which rewrites its url and hash
# and keeps .lazy). The Nix package fetches none of them (they are lazy, for
# the tests), so there is no hash of them to work out again. Called by the
# weekly update; prints a line per dependency that moved, "name vA -> vB".
#
# Only plain vX.Y.Z tags count, never a pre-release, and only one whose
# build.zig.zon asks for no newer Zig than mise.toml's (its
# minimum_zig_version): minish 0.2.0 on needs Zig 0.16, and Zig's minor
# moves by hand, with zig_0_NN in nix/package.nix.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

zig=$(zig version)

# Whether Zig $zig builds tag $2 of GitHub repository $1 by its
# minimum_zig_version (none declared: yes; no build.zig.zon read: no).
fits() {
	local zon min
	zon=$(curl -fsSL "https://raw.githubusercontent.com/${1#https://github.com/}/$2/build.zig.zon") || return 1
	min=$(sed -n 's/.*\.minimum_zig_version = "\([^"]*\)".*/\1/p' <<<"$zon")
	[ -z "$min" ] || [ "$(printf '%s\n' "$min" "$zig" | sort -V | head -n1)" = "$min" ]
}

# "name url" for every dependency whose url is a tag's archive.
deps=$(awk '
	/^ *\.[a-z_0-9]+ = \.\{/ { name = $1; sub(/^\./, "", name) }
	/^ *\.url = "https:\/\/github\.com\/.*\/archive\/refs\/tags\/.*\.tar\.gz"/ {
		url = $3; gsub(/[",]/, "", url); print name, url
	}
' build.zig.zon)

while read -r name url; do
	[ -n "$name" ] || continue
	repo=${url%/archive/refs/tags/*}
	was=${url##*/refs/tags/}
	was=${was%.tar.gz}
	now=
	# Newest first, down to the pinned one.
	for tag in $(git ls-remote --tags --refs "$repo" | sed -n 's|.*refs/tags/\(v[0-9]*\.[0-9]*\.[0-9]*\)$|\1|p' | sort -rV); do
		if [ "$tag" = "$was" ]; then break; fi
		if fits "$repo" "$tag"; then now=$tag; break; fi
	done
	if [ -n "$now" ]; then
		zig fetch --save="$name" "$repo/archive/refs/tags/$now.tar.gz" >&2
		echo "$name $was -> $now"
	fi
done <<<"$deps"
