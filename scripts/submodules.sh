#!/usr/bin/env bash
# Moves each git submodule to its upstream's latest release tag, a plain
# vX.Y[.Z] (never a -beta or -rc), and prints a line per submodule that
# moved, "path was -> vX.Y.Z". Called by the weekly update.
#
# vendor/libopus is compiled by build.zig from a list of its sources, so a
# move writes that list again from the new tag's own *_sources.mk (the
# encoder's: CELT, SILK with its float path, and Opus with its float
# analysis; the DNN extensions and the per-CPU variants stay out), and the
# version string beside it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

git submodule update --init --quiet

while read -r path; do
	git -C "$path" fetch -q --tags origin
	latest=$(git -C "$path" tag -l 'v*' | grep -E '^v[0-9]+(\.[0-9]+)+$' | sort -V | tail -n1)
	[ -n "$latest" ] || continue
	if [ "$(git -C "$path" rev-parse HEAD)" != "$(git -C "$path" rev-parse "$latest^{commit}")" ]; then
		was=$(git -C "$path" describe --tags 2>/dev/null || git -C "$path" rev-parse --short HEAD)
		git -C "$path" checkout -q "$latest"
		# Staged, or the next `git submodule update` (./run's) puts it back.
		git add "$path"
		echo "$path $was -> $latest"
	fi
done < <(git config -f .gitmodules --get-regexp '\.path$' | awk '{print $2}')

opus=vendor/libopus
if [ -z "$(git diff --name-only HEAD -- "$opus")" ]; then exit 0; fi

sources=$(awk '
	FNR == 1 { var = "" }
	/^[A-Z0-9_]+ = *\\$/ { var = $1; next }
	/^[[:space:]]*$/ { var = ""; next }
	var ~ /^(CELT_SOURCES|SILK_SOURCES|SILK_SOURCES_FLOAT|OPUS_SOURCES|OPUS_SOURCES_FLOAT)$/ && $1 ~ /\.c$/ {
		print "    \"" $1 "\","
	}
' "$opus"/celt_sources.mk "$opus"/silk_sources.mk "$opus"/opus_sources.mk | sort)
if [ -z "$sources" ]; then
	echo "submodules: no sources found in $opus/*_sources.mk" >&2
	exit 1
fi
version=$(git -C "$opus" describe --tags --exact-match)
awk -v sources="$sources" '
	/^const opus_sources = / { print; print sources; skip = 1; next }
	skip && /^};/ { skip = 0 }
	!skip { print }
' build.zig >build.zig.new
mv build.zig.new build.zig
sed -i -E 's/(-DPACKAGE_VERSION=\\")[^\\]*(\\")/\1'"${version#v}"'\2/' build.zig
