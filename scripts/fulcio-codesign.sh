#!/usr/bin/env bash
set -euo pipefail

# fulcio-codesign.sh — Sign a macOS binary using a Fulcio certificate
#
# Uses Sigstore's Fulcio CA to obtain a short-lived code signing certificate
# tied to an OIDC identity (GitHub Actions or interactive), then signs the
# binary with Apple's codesign using that certificate.
#
# The designated requirement pins on the binary identifier + Fulcio's
# "Source Repository URI" OID, so TCC permissions survive across builds
# as long as the signing identity traces back to the same GitHub repo.
#
# Usage:
#   In GitHub Actions (keyless, automatic):
#     ./scripts/fulcio-codesign.sh dist/bin/capsper
#
#   Locally (opens browser for OIDC login):
#     ./scripts/fulcio-codesign.sh dist/bin/capsper
#
# Requirements: openssl, curl, jq, rcodesign, csreq (macOS)

IDENTIFIER="io.github.danielbodart.capsper"
FULCIO_URL="https://fulcio.sigstore.dev"
REPO_URI="https://github.com/danielbodart/capsper"
# Fulcio OID 1.3.6.1.4.1.57264.1.12 = Source Repository URI
REPO_OID="1.3.6.1.4.1.57264.1.12"

BINARY="${1:?Usage: fulcio-codesign.sh <binary>}"
[ -f "$BINARY" ] || { echo "error: binary not found: $BINARY" >&2; exit 1; }

TMPDIR_WORK=""
cleanup() {
    if [ -n "$TMPDIR_WORK" ]; then
        # Shred private key material
        [ -f "$TMPDIR_WORK/key.pem" ] && rm -P "$TMPDIR_WORK/key.pem" 2>/dev/null || true
        [ -f "$TMPDIR_WORK/signing.pem" ] && rm -P "$TMPDIR_WORK/signing.pem" 2>/dev/null || true
        rm -rf "$TMPDIR_WORK"
    fi
}
trap cleanup EXIT

TMPDIR_WORK=$(mktemp -d)

# ─── Step 1: Generate ephemeral EC key pair ──────────────────────────────────

echo "Generating ephemeral key pair..."
# Generate in PKCS#8 format (required by rcodesign)
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$TMPDIR_WORK/key.pem" 2>/dev/null
openssl pkey -in "$TMPDIR_WORK/key.pem" -pubout -out "$TMPDIR_WORK/pub.pem" 2>/dev/null

# ─── Step 2: Get OIDC token ──────────────────────────────────────────────────

if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
    echo "Requesting OIDC token from GitHub Actions..."
    OIDC_TOKEN=$(curl -sS \
        -H "Authorization: Bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
        "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=sigstore" \
        | jq -r '.value')
else
    echo "Not in GitHub Actions — using Sigstore OAuth (opens browser)..."
    # Sigstore runs a Dex OIDC provider. We do a localhost OAuth redirect flow
    # to get an OIDC token with audience "sigstore".
    OIDC_ISSUER="https://oauth2.sigstore.dev/auth"
    OIDC_CLIENT_ID="sigstore"
    REDIRECT_PORT=0  # Let OS assign

    # Start a temporary HTTP server to catch the OAuth redirect
    # Python is available on macOS by default
    FIFO="$TMPDIR_WORK/oauth-fifo"
    mkfifo "$FIFO"

    # Find a free port
    REDIRECT_PORT=$(python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()")
    REDIRECT_URI="http://localhost:$REDIRECT_PORT/callback"

    # Discover endpoints
    OIDC_CONFIG=$(curl -sS "$OIDC_ISSUER/.well-known/openid-configuration")
    AUTH_ENDPOINT=$(echo "$OIDC_CONFIG" | jq -r '.authorization_endpoint')
    TOKEN_ENDPOINT=$(echo "$OIDC_CONFIG" | jq -r '.token_endpoint')

    # PKCE challenge (S256)
    CODE_VERIFIER=$(openssl rand -base64 32 | tr -d '=/+' | head -c 43)
    CODE_CHALLENGE=$(echo -n "$CODE_VERIFIER" | openssl dgst -sha256 -binary | base64 | tr '+/' '-_' | tr -d '=')

    STATE=$(openssl rand -hex 16)
    NONCE=$(openssl rand -hex 16)

    AUTH_URL="${AUTH_ENDPOINT}?client_id=${OIDC_CLIENT_ID}&redirect_uri=${REDIRECT_URI}&response_type=code&scope=openid+email&state=${STATE}&nonce=${NONCE}&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256"

    echo "Opening browser for authentication..."
    open "$AUTH_URL"

    # Catch the redirect with a one-shot HTTP server
    AUTH_CODE=$(python3 -c "
import http.server, urllib.parse, sys

class Handler(http.server.BaseHTTPRequestHandler):
    code = None
    def do_GET(self):
        params = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
        if 'code' in params:
            Handler.code = params['code'][0]
        self.send_response(200)
        self.send_header('Content-Type', 'text/html')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.wfile.write(b'<html><body><h2>Authentication successful!</h2><p>You can close this tab.</p></body></html>')
    def log_message(self, *args): pass

server = http.server.HTTPServer(('127.0.0.1', $REDIRECT_PORT), Handler)
server.handle_request()  # handle the callback
if Handler.code:
    print(Handler.code, end='')
else:
    sys.exit(1)
")

    [ -n "$AUTH_CODE" ] || { echo "error: OAuth flow failed — no auth code received" >&2; exit 1; }

    # Exchange code for OIDC token
    TOKEN_RESPONSE=$(curl -sS -X POST "$TOKEN_ENDPOINT" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=authorization_code&code=${AUTH_CODE}&redirect_uri=${REDIRECT_URI}&client_id=${OIDC_CLIENT_ID}&code_verifier=${CODE_VERIFIER}")

    OIDC_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.id_token // empty')
    if [ -z "$OIDC_TOKEN" ]; then
        echo "error: failed to get id_token from token exchange" >&2
        echo "$TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$TOKEN_RESPONSE" >&2
        exit 1
    fi
fi

[ -n "$OIDC_TOKEN" ] || { echo "error: failed to get OIDC token" >&2; exit 1; }

# Helper: decode base64url JWT payload (add padding, fix alphabet)
jwt_payload() {
    local payload
    payload=$(echo "$1" | cut -d. -f2 | tr '_-' '/+')
    # Add padding
    local pad=$(( 4 - ${#payload} % 4 ))
    [ "$pad" -lt 4 ] && payload="${payload}$(printf '=%.0s' $(seq 1 $pad))"
    echo "$payload" | base64 -d 2>/dev/null
}

# Decode and display token claims (for debugging)
echo "OIDC token issuer: $(jwt_payload "$OIDC_TOKEN" | jq -r '.iss' 2>/dev/null || echo 'unknown')"

# ─── Step 3: Create proof of possession ──────────────────────────────────────
# Sign the OIDC identity (email if present, otherwise sub) with our ephemeral key.
# This must match Fulcio's SubjectFromUnverifiedToken logic:
#   if email is present and email_verified: use email
#   otherwise: use sub

PAYLOAD_JSON=$(jwt_payload "$OIDC_TOKEN")
EMAIL=$(echo "$PAYLOAD_JSON" | jq -r '.email // empty')
EMAIL_VERIFIED=$(echo "$PAYLOAD_JSON" | jq -r '.email_verified // false')
SUB_CLAIM=$(echo "$PAYLOAD_JSON" | jq -r '.sub')

if [ -n "$EMAIL" ] && [ "$EMAIL_VERIFIED" = "true" ]; then
    CHALLENGE="$EMAIL"
    echo "OIDC identity (email): $EMAIL"
else
    CHALLENGE="$SUB_CLAIM"
    echo "OIDC identity (sub): $SUB_CLAIM"
fi

# Sign the challenge as proof of possession
echo -n "$CHALLENGE" | openssl dgst -sha256 -sign "$TMPDIR_WORK/key.pem" -out "$TMPDIR_WORK/proof.sig"
PROOF_B64=$(base64 < "$TMPDIR_WORK/proof.sig")

# Read public key content
PUB_KEY_CONTENT=$(cat "$TMPDIR_WORK/pub.pem")

# ─── Step 4: Request certificate from Fulcio ─────────────────────────────────

echo "Requesting certificate from Fulcio..."

REQUEST_BODY=$(jq -n \
    --arg token "$OIDC_TOKEN" \
    --arg pubkey "$PUB_KEY_CONTENT" \
    --arg proof "$PROOF_B64" \
    '{
        credentials: {
            oidcIdentityToken: $token
        },
        publicKeyRequest: {
            publicKey: {
                algorithm: "ECDSA",
                content: $pubkey
            },
            proofOfPossession: $proof
        }
    }')

RESPONSE=$(curl -sS -w "\n%{http_code}" \
    -X POST "$FULCIO_URL/api/v2/signingCert" \
    -H "Content-Type: application/json" \
    -d "$REQUEST_BODY")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" != "200" ]; then
    echo "error: Fulcio returned HTTP $HTTP_CODE" >&2
    echo "$BODY" >&2
    exit 1
fi

echo "Certificate received from Fulcio."

# Extract the certificate chain
# The v2 API returns signedCertificateEmbeddedSct or signedCertificateDetachedSct
CERT_CHAIN=$(echo "$BODY" | jq -r '
    (.signedCertificateEmbeddedSct // .signedCertificateDetachedSct)
    | .chain.certificates[]' 2>/dev/null)

if [ -z "$CERT_CHAIN" ]; then
    echo "error: failed to extract certificate chain from response" >&2
    echo "Response body:" >&2
    echo "$BODY" | jq . 2>/dev/null || echo "$BODY" >&2
    exit 1
fi

# Write leaf cert and chain
LEAF_CERT=$(echo "$BODY" | jq -r '(.signedCertificateEmbeddedSct // .signedCertificateDetachedSct).chain.certificates[0]')
echo "$LEAF_CERT" > "$TMPDIR_WORK/leaf.pem"

# Write full chain
echo "$BODY" | jq -r '(.signedCertificateEmbeddedSct // .signedCertificateDetachedSct).chain.certificates[]' \
    > "$TMPDIR_WORK/chain.pem"

# Show cert details
echo "Cert: $(openssl x509 -in "$TMPDIR_WORK/leaf.pem" -noout -issuer 2>/dev/null | sed 's/issuer=//')"
echo "Valid: $(openssl x509 -in "$TMPDIR_WORK/leaf.pem" -noout -startdate -enddate 2>/dev/null | tr '\n' ' ')"
echo ""

# Extract the Source Repository URI OID value from the cert
# Use -F for fixed-string match (OID contains dots that are regex wildcards)
# DER-encoded strings (OIDs 1.8+) have a tag+length prefix that shows as
# non-printable or punctuation chars in openssl text output. Strip everything
# before the first "http" to get the clean URI.
CERT_REPO_URI=$(openssl x509 -in "$TMPDIR_WORK/leaf.pem" -noout -text 2>/dev/null \
    | grep -F -A1 "$REPO_OID:" | tail -1 | sed 's/^[[:space:]]*//;s/^.*\(https\{0,1\}:\/\/\)/\1/' || echo "")
echo "Source Repository URI in cert: ${CERT_REPO_URI:-not found}"

# ─── Step 5: Sign with rcodesign ─────────────────────────────────────────────
# rcodesign signs Mach-O binaries directly from PEM key+cert files,
# bypassing the macOS keychain entirely. This avoids issues with Fulcio's
# empty-subject certs not forming valid keychain identities.

echo ""
echo "Signing $BINARY with rcodesign..."

# Combine key and cert chain into a single PEM for rcodesign
cat "$TMPDIR_WORK/key.pem" "$TMPDIR_WORK/leaf.pem" "$TMPDIR_WORK/chain.pem" \
    > "$TMPDIR_WORK/signing.pem"

# Build the designated requirement
# Always pins on identifier + the Fulcio Source Repository URI OID.
# In CI this is the actual repo URL; locally it's the Dex OAuth redirect.
# This lets us test the full DR pipeline locally with the same structure.
if [ -n "$CERT_REPO_URI" ]; then
    DR="designated => identifier \"$IDENTIFIER\" and certificate leaf[field.$REPO_OID] = \"$CERT_REPO_URI\""
    echo "DR: identifier + repo OID = $CERT_REPO_URI"
else
    DR="designated => identifier \"$IDENTIFIER\""
    echo "DR: identifier only (no repo OID in cert)"
fi

RCODESIGN="${RCODESIGN:-rcodesign}"

# Compile the designated requirement to binary format (required by rcodesign)
# csreq outputs a RequirementSet blob (fade0c01), but rcodesign expects
# just the inner Requirement blob (fade0c00), so we strip the 20-byte header.
csreq -r="$DR" -b "$TMPDIR_WORK/requirements-set.bin"
dd if="$TMPDIR_WORK/requirements-set.bin" of="$TMPDIR_WORK/requirements.bin" bs=1 skip=20 2>/dev/null

"$RCODESIGN" sign \
    --pem-source "$TMPDIR_WORK/signing.pem" \
    --binary-identifier "$IDENTIFIER" \
    --code-signature-flags runtime \
    --code-requirements-file "$TMPDIR_WORK/requirements.bin" \
    "$BINARY"

echo "Binary signed successfully."

# ─── Step 7: Verify ──────────────────────────────────────────────────────────

echo ""
echo "=== Verification ==="
codesign -dvvv "$BINARY" 2>&1 | head -20
echo ""
echo "Designated requirement:"
codesign -dr- "$BINARY" 2>&1
echo ""
echo "Done. Binary is signed with Fulcio cert tied to: $REPO_URI"
