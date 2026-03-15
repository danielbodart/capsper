#!/usr/bin/env bash
set -euo pipefail

# Grant macOS TCC permissions to a binary.
#
# macOS TCC blocks protected resources (microphone, accessibility, camera,
# etc.) from SSH sessions. This script pre-authorises a binary by inserting
# its cdhash-based code signing requirement into the user TCC database.
# The binary must be launched via LaunchAgent (launchctl load) to run in
# the GUI session where TCC honours the grant.
#
# Usage:
#   grant-tcc.sh <binary> <service> [service...]
#   grant-tcc.sh --list
#   grant-tcc.sh --help
#
# Examples:
#   grant-tcc.sh dist/bin/capsper Microphone
#   grant-tcc.sh dist/bin/capsper Microphone Accessibility
#   grant-tcc.sh dist/bin/capsper ScreenCapture Camera
#
# Service names (case-insensitive, kTCCService prefix optional):
#   Accessibility       — CGEventTap keyboard interception + CGEventPost injection
#   Microphone          — CoreAudio AUHAL capture
#   Camera              — AVCaptureDevice video
#   ScreenCapture       — Screen recording
#   SystemPolicyAllFiles — Full Disk Access
#   AddressBook         — Contacts
#   Calendar            — Calendar events
#   Reminders           — Reminders
#   Photos / PhotosAdd  — Photo library
#   InputMonitoring     — Input device monitoring (Xcode 15+)
#
# Requirements:
#   - macOS with SIP disabled (csrutil disable)
#   - codesign, csreq, xxd, sqlite3 (all ship with macOS)
#
# The grant must be refreshed after every rebuild (cdhash changes).

TCC_DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"

usage() {
    sed -n '3,36p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

list_services() {
    cat << 'EOF'
Known TCC service names (use short name without kTCCService prefix):

  Accessibility          CGEventTap, CGEventPost, AXIsProcessTrusted
  Microphone             CoreAudio capture, AVCaptureDevice audio
  Camera                 AVCaptureDevice video
  ScreenCapture          Screen recording
  SystemPolicyAllFiles   Full Disk Access
  InputMonitoring        Input device monitoring
  AddressBook            Contacts
  Calendar               Calendar events
  Reminders              Reminders
  Photos                 Photo library (read)
  PhotosAdd              Photo library (write)
  SpeechRecognition      Speech recognition
  Liverpool              Location services
  Ubiquity               iCloud
  SystemPolicyDesktopFolder   Desktop folder access
  SystemPolicyDocumentsFolder Documents folder access
  SystemPolicyDownloadsFolder Downloads folder access

Currently granted in your TCC database:
EOF
    sqlite3 "$TCC_DB" "SELECT service, client, CASE auth_value WHEN 2 THEN 'granted' WHEN 0 THEN 'denied' ELSE auth_value END FROM access ORDER BY service, client;" 2>/dev/null | column -t -s'|' || echo "  (unable to read TCC database)"
}

# Normalize service name: add kTCCService prefix if not present
normalize_service() {
    local svc="$1"
    if [[ "$svc" != kTCCService* ]]; then
        echo "kTCCService${svc}"
    else
        echo "$svc"
    fi
}

grant_one() {
    local binary="$1"
    local service="$2"

    # Remove old entry
    sqlite3 "$TCC_DB" "DELETE FROM access WHERE service='$service' AND client='$binary';" 2>/dev/null || true

    # Restart tccd to drop cached state
    killall tccd 2>/dev/null || true
    sleep 0.5

    # Insert new grant
    sqlite3 "$TCC_DB" "INSERT OR REPLACE INTO access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, indirect_object_identifier, flags) VALUES ('$service', '$binary', 1, 2, 3, 1, X'${HEX}', 'UNUSED', 0);"

    # Verify
    local result
    result=$(sqlite3 "$TCC_DB" "SELECT auth_value FROM access WHERE service='$service' AND client='$binary';" 2>/dev/null)
    if [[ "$result" == "2" ]]; then
        echo "  ✓ $service"
    else
        echo "  ✗ $service (verify failed: $result)"
    fi
}

# ─── Main ────────────────────────────────────────────────────────────────────

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "Not macOS — skipping TCC grant"
    exit 0
fi

[[ "${1:-}" == "--help" || "${1:-}" == "-h" ]] && usage 0
[[ "${1:-}" == "--list" ]] && list_services && exit 0

BINARY="${1:-}"
shift || true
SERVICES=("$@")

if [[ -z "$BINARY" || ${#SERVICES[@]} -eq 0 ]]; then
    echo "ERROR: Binary path and at least one service required." >&2
    echo "" >&2
    usage 1
fi

# Resolve to absolute path
BINARY="$(realpath "$BINARY")"

if [[ ! -f "$BINARY" ]]; then
    echo "ERROR: Binary not found: $BINARY" >&2
    exit 1
fi

# Get the designated code signing requirement
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

# Dismiss any pending TCC dialogs
killall UserNotificationCenter 2>/dev/null || true

echo "Granting TCC permissions for: $BINARY"

for svc in "${SERVICES[@]}"; do
    grant_one "$BINARY" "$(normalize_service "$svc")"
done

# Final tccd restart to pick up all changes
killall tccd 2>/dev/null || true
killall UserNotificationCenter 2>/dev/null || true
sleep 1

echo "Done."
