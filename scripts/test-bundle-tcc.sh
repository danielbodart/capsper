#!/usr/bin/env bash
set -euo pipefail

# test-bundle-tcc.sh — Test whether TCC grants survive binary replacement
# inside a Fulcio-signed app bundle.
#
# This script:
#   1. Builds capsper
#   2. Creates a minimal .app bundle
#   3. Signs it with Fulcio
#   4. Launches it so you can grant Accessibility + Microphone
#   5. Waits for you to confirm permissions are granted
#   6. Rebuilds, re-signs (simulating an update — new cdhash, same DR)
#   7. Launches again and checks if TCC grants survived
#
# Usage:
#   ./scripts/test-bundle-tcc.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUNDLE_DIR="$PROJECT_DIR/dist/Capsper.app"
BUNDLE_ID="io.github.danielbodart.capsper"

cd "$PROJECT_DIR"

# ─── Step 1: Build ──────────────────────────────────────────────────────────

echo "=== Step 1: Build capsper ==="
./run.ts build
echo ""

# ─── Step 2: Create .app bundle ────────────────────────────────────────────

echo "=== Step 2: Create app bundle ==="

rm -rf "$BUNDLE_DIR"
mkdir -p "$BUNDLE_DIR/Contents/MacOS"
mkdir -p "$BUNDLE_DIR/Contents/Resources"

cp dist/macos/bin/capsper "$BUNDLE_DIR/Contents/MacOS/capsper"

cat > "$BUNDLE_DIR/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>
    <string>capsper</string>
    <key>CFBundleName</key>
    <string>Capsper</string>
    <key>CFBundleDisplayName</key>
    <string>Capsper</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSBackgroundOnly</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Capsper needs microphone access for push-to-talk voice dictation.</string>
</dict>
</plist>
EOF

echo "Bundle created at: $BUNDLE_DIR"
echo ""

# ─── Step 3: Sign the bundle ───────────────────────────────────────────────

echo "=== Step 3: Sign bundle with Fulcio ==="
# fulcio-codesign signs a Mach-O binary. We need to sign the binary
# inside the bundle, then sign the bundle itself.
# For now, sign just the inner binary with our existing script, then
# codesign the bundle with an ad-hoc signature that preserves the inner sig.

# Sign the binary inside the bundle with Fulcio (same DR as production)
fulcio-codesign --identifier io.github.danielbodart.capsper --subject io.github.danielbodart.capsper --entitlements dist/macos/entitlements.plist "$BUNDLE_DIR/Contents/MacOS/capsper"

# Record the cdhash for comparison later
CDHASH_V1=$(codesign -dvvv "$BUNDLE_DIR/Contents/MacOS/capsper" 2>&1 | grep CDHash | head -1)
echo "v1 binary: $CDHASH_V1"
echo ""

# ─── Step 4: Test TCC — first launch ───────────────────────────────────────

echo "=== Step 4: First launch — grant permissions ==="
echo ""

# Find installed models (needed to get past model loading to the permission checks)
MODEL_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/capsper/models"
if [ ! -d "$MODEL_DIR/nemotron-coreml/encoder.mlmodelc" ]; then
    echo "ERROR: CoreML models not found at $MODEL_DIR/nemotron-coreml/"
    echo "Install capsper first (./run.ts setup) so models are available."
    exit 1
fi

echo "Launching Capsper.app via 'open' (so macOS attributes TCC to the bundle, not Terminal)."
echo "This will trigger Accessibility and Microphone permission prompts for 'Capsper'."
echo "Grant BOTH permissions when prompted."
echo ""
echo "The app will run in the background. Check logs at: /tmp/capsper-tcc-test.log"
echo ""

# Launch via 'open' so macOS sees the bundle identity, not Terminal.
# Pass args via --args. stdout/stderr go to a log file since 'open' detaches.
open "$BUNDLE_DIR" --args \
    --trigger capslock \
    --model "$MODEL_DIR/nemotron" \
    > /tmp/capsper-tcc-test.log 2>&1

# Give it time to start and trigger permission prompts
sleep 3
echo "Capsper.app launched. Check System Settings for permission prompts."
echo "Logs so far:"
cat /tmp/capsper-tcc-test.log 2>/dev/null || true
echo ""

echo ""

# Show what TCC sees
echo "TCC entries after granting:"
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT service, client, auth_value FROM access WHERE client LIKE '%capsper%' OR client LIKE '%Capsper%';" 2>/dev/null || echo "(could not read TCC.db — check manually)"
echo ""

read -rp "Verify both permissions are granted above (auth_value=2), then press Enter..."
echo ""

# Kill the running instance before rebuilding
echo "Stopping Capsper.app..."
pkill -f "$BUNDLE_DIR/Contents/MacOS/capsper" 2>/dev/null || true
sleep 1

# ─── Step 5: Simulate update — rebuild and re-sign ─────────────────────────

echo "=== Step 5: Simulate update — rebuild + re-sign ==="
echo ""

# Touch a source file to force a different binary (different cdhash)
# We add a harmless comment change to ensure the binary differs
MARKER_FILE="$PROJECT_DIR/src/shared/utils.zig"
echo "" >> "$MARKER_FILE"  # append newline to force recompile

./run.ts build

# Restore the file
git checkout -- "$MARKER_FILE"

# Replace binary in bundle
cp dist/macos/bin/capsper "$BUNDLE_DIR/Contents/MacOS/capsper"

# Re-sign with Fulcio (new ephemeral cert, new cdhash, same DR)
fulcio-codesign --identifier io.github.danielbodart.capsper --subject io.github.danielbodart.capsper --entitlements dist/macos/entitlements.plist "$BUNDLE_DIR/Contents/MacOS/capsper"

CDHASH_V2=$(codesign -dvvv "$BUNDLE_DIR/Contents/MacOS/capsper" 2>&1 | grep CDHash | head -1)
echo ""
echo "v1 binary: $CDHASH_V1"
echo "v2 binary: $CDHASH_V2"

if [ "$CDHASH_V1" = "$CDHASH_V2" ]; then
    echo ""
    echo "WARNING: CDHash did not change! The test is invalid."
    echo "The binary must differ between v1 and v2 to test TCC persistence."
    exit 1
fi

echo ""
echo "CDHash changed (good — this simulates a real update)."
echo ""

# ─── Step 6: Test TCC — second launch ──────────────────────────────────────

echo "=== Step 6: Second launch — check if TCC survived ==="
echo ""

echo "TCC entries after binary replacement (before launching):"
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT service, client, auth_value FROM access WHERE client LIKE '%capsper%' OR client LIKE '%Capsper%';" 2>/dev/null || echo "(could not read TCC.db)"
echo ""

echo "Launching updated Capsper.app via 'open'..."
open "$BUNDLE_DIR" --args \
    --trigger capslock \
    --model "$MODEL_DIR/nemotron" \
    > /tmp/capsper-tcc-test-v2.log 2>&1

sleep 5
echo "Logs:"
cat /tmp/capsper-tcc-test-v2.log 2>/dev/null || true
echo ""

echo "TCC entries after launching updated binary:"
sqlite3 "$HOME/Library/Application Support/com.apple.TCC/TCC.db" \
    "SELECT service, client, auth_value FROM access WHERE client LIKE '%capsper%' OR client LIKE '%Capsper%';" 2>/dev/null || echo "(could not read TCC.db)"
echo ""

# Kill v2 instance
pkill -f "$BUNDLE_DIR/Contents/MacOS/capsper" 2>/dev/null || true

echo "=== Results ==="
echo ""
echo "If auth_value=2 (granted) persists for both services after the update:"
echo "  → TCC grants survive across Fulcio-signed bundle updates!"
echo "  → App bundle migration is worth doing."
echo ""
echo "If auth_value changed to 0 (denied/reset):"
echo "  → TCC still breaks with Fulcio signing even inside a bundle."
echo "  → Would need Apple Developer ID) for TCC persistenc'"
echo ""
echo "If 'Capsper' shows as the app name (not a raw path) in TCC entries:"
echo "  → Bundle gives better UX in System Settings regardless."
