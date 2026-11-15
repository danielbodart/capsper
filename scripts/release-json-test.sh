#!/usr/bin/env bash
# Tests scripts/release-json.sh against v0.420.300's real SHA256SUMS: the
# file it writes is the one flake.nix reads, with the hash in the SRI form
# `nix hash convert --hash-algo sha256 --to sri` gives (worked out with it
# once, and written here, since the check runs where there may be no nix),
# and a SHA256SUMS missing the Linux tarball, or a version that is not one,
# makes nothing. Run by mise run check (the lint task).
set -euo pipefail
unset CDPATH

script=$(cd "$(dirname "$0")" && pwd)/release-json.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

cat >"$work/SHA256SUMS" <<'SUMS'
64bfa9d9dea4b5c953c3a962a0211ac9cb58eb7f7dba8b8f200917fe3a661900  capsper-linux-x86_64.tar.gz
9915fc92e37ef8338a3faeac937a56f9e9d070166e3171842d9d39fb781c9d82  capsper-macos-arm64.tar.gz
SUMS

cat >"$work/want.json" <<'JSON'
{
  "version": "0.420.300",
  "assets": {
    "x86_64-linux": {
      "url": "https://github.com/danielbodart/capsper/releases/download/v0.420.300/capsper-linux-x86_64.tar.gz",
      "hash": "sha256-ZL+p2d6ktclTw6lioCEayctY6399uouPIAkX/jpmGQA="
    }
  }
}
JSON

if ! "$script" 0.420.300 "$work/SHA256SUMS" >"$work/got.json"; then
    fail "a release's SHA256SUMS: refused"
elif ! diff -u "$work/want.json" "$work/got.json"; then
    fail "a release's SHA256SUMS: not the release.json flake.nix wants"
fi

grep -v linux-x86_64 "$work/SHA256SUMS" >"$work/short"
if "$script" 0.420.300 "$work/short" >/dev/null 2>&1; then
    fail "a SHA256SUMS without the Linux tarball: accepted"
fi

if "$script" v0.420.300 "$work/SHA256SUMS" >/dev/null 2>&1; then
    fail "a version with a v: accepted"
fi

if [ $failures -gt 0 ]; then
    exit 1
fi
echo "release-json: ok"
