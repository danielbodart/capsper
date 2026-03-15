#!/usr/bin/env bash
set -euo pipefail

# Grant macOS TCC microphone permission to a binary.
#
# macOS TCC blocks microphone access from SSH sessions — AudioUnitRender
# silently returns zero samples. This script pre-authorises a binary by
# inserting its cdhash-based code signing requirement into the user TCC
# database. The binary must be launched via LaunchAgent (launchctl load)
# to run in the GUI session where TCC honours the grant.
#
# Usage: ./grant-tcc-mic.sh <binary-path> [service]
#   binary-path  — absolute path to the binary to grant permission to
#   service      — TCC service name (default: kTCCServiceMicrophone)
#
# Requirements:
#   - macOS with SIP disabled (csrutil disable)
#   - codesign, csreq, xxd, sqlite3, tccutil (all ship with macOS)
#
# The script:
#   1. Kills UserNotificationCenter to dismiss pending TCC dialogs
#   2. Resets the service to clear stale entries
#   3. Restarts tccd (TCC daemon)
#   4. Inserts a grant with the binary's current cdhash-based csreq
#   5. Restarts tccd again to reload
#
# The grant must be refreshed after every rebuild (cdhash changes).

BINARY="${1:?Usage: $0 <binary-path> [service]}"
SERVICE="${2:-kTCCServiceMicrophone}"
TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Not macOS — skipping TCC grant"
    exit 0
fi

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found: $BINARY" >&2
    exit 1
fi

# Get the designated code signing requirement (cdhash for ad-hoc signed)
REQ=$(codesign -dr- "$BINARY" 2>&1 | grep -E 'designated|cdhash' | sed 's/.*designated => //' | sed 's/^# //')
if [[ -z "$REQ" ]]; then
    echo "ERROR: Could not get code signing requirement for $BINARY" >&2
    exit 1
fi

# Generate csreq binary blob and convert to hex
CSREQ_BIN=$(mktemp)
trap 'rm -f "$CSREQ_BIN"' EXIT
echo "$REQ" | csreq -r- -b "$CSREQ_BIN"
HEX=$(xxd -p "$CSREQ_BIN" | tr -d '\n')

if [[ ${#HEX} -lt 10 ]]; then
    echo "ERROR: Failed to generate csreq blob" >&2
    exit 1
fi

# 1. Dismiss any pending TCC dialogs
killall UserNotificationCenter 2>/dev/null || true

# 2. Remove only THIS binary's stale entry (not all apps' permissions)
sqlite3 "$TCC_DB" "DELETE FROM access WHERE service='$SERVICE' AND client='$BINARY';" 2>/dev/null || true

# 3. Restart tccd so it drops any cached state for the old entry
killall tccd 2>/dev/null || true
sleep 1

# 4. Insert grant with current cdhash
sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier, flags) VALUES ('$SERVICE', '$BINARY', 1, 2, 3, 1, X'${HEX}', 'UNUSED', 0);"

# 5. Restart tccd + dismiss dialogs again
killall tccd 2>/dev/null || true
killall UserNotificationCenter 2>/dev/null || true
sleep 2

# Verify
RESULT=$(sqlite3 "$TCC_DB" "SELECT auth_value, length(csreq) FROM access WHERE service='$SERVICE' AND client='$BINARY';")
echo "TCC: Granted $SERVICE to $BINARY (verify: $RESULT)"
