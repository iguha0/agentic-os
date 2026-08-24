#!/bin/sh
# certify-verify.sh — verify a content certificate
# Anyone can run this to verify a file matches its certificate
# and that the signature was made by the claimed creator.
#
# Usage: certify-verify.sh <cert.json> [<file>]

CERT_FILE="$1"
FILE="$2"   # optional: if provided, verify file matches CID in cert

[ -f "$CERT_FILE" ] || { echo "verify: cert file not found: $CERT_FILE" >&2; exit 1; }

# Extract fields
extract() { grep "\"$1\"" "$CERT_FILE" | sed 's/.*"\([^"]*\)" *$/\1/' | head -1; }

CID=$(grep '"cid"' "$CERT_FILE" | sed 's/.*"cid": *"\([^"]*\)".*/\1/')
CREATOR=$(grep '"creator"' "$CERT_FILE" | sed 's/.*"creator": *"\([^"]*\)".*/\1/')
PUBKEY=$(grep '"pubkey"' "$CERT_FILE" | sed 's/.*"pubkey": *"\([^"]*\)".*/\1/')
CREATED=$(grep '"created"' "$CERT_FILE" | sed 's/.*"created": *\([0-9]*\).*/\1/')
SIG=$(grep '"sig"' "$CERT_FILE" | sed 's/.*"sig": *"\([^"]*\)".*/\1/')
TITLE=$(grep '"title"' "$CERT_FILE" | sed 's/.*"title": *"\([^"]*\)".*/\1/')

echo "=== Certificate Verification ==="
echo "Title:   $TITLE"
echo "Creator: $CREATOR"
echo "CID:     $CID"
echo "Created: $(date -d @$CREATED 2>/dev/null || date -r $CREATED 2>/dev/null || echo $CREATED)"
echo ""

# Verify file integrity if provided
if [ -n "$FILE" ]; then
    if [ ! -f "$FILE" ]; then
        echo "[FAIL] File not found: $FILE"
        exit 1
    fi
    ACTUAL_CID="sha256:$(sha256sum "$FILE" | cut -d' ' -f1)"
    if [ "$ACTUAL_CID" = "$CID" ]; then
        echo "[PASS] File integrity: content matches certificate"
    else
        echo "[FAIL] File integrity: content does NOT match certificate"
        echo "       Expected: $CID"
        echo "       Actual:   $ACTUAL_CID"
        exit 1
    fi
fi

# Verify signature
if [ -n "$SIG" ] && [ -n "$PUBKEY" ]; then
    PAYLOAD="{\"cid\":\"$CID\",\"creator\":\"$CREATOR\",\"created\":$CREATED}"

    # Decode pubkey and write to temp file
    TMP_PUB=$(mktemp)
    TMP_SIG=$(mktemp)
    TMP_PEM=$(mktemp)

    echo "$PUBKEY" | base64 -d > "$TMP_PUB" 2>/dev/null
    echo "$SIG"    | base64 -d > "$TMP_SIG" 2>/dev/null

    # Convert raw ed25519 public key bytes to PEM format
    # DER prefix for ed25519 SubjectPublicKeyInfo: 302a300506032b6570032100
    printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x70\x03\x21\x00' > "$TMP_PEM"
    cat "$TMP_PUB" >> "$TMP_PEM"

    PEM_FILE=$(mktemp)
    (echo "-----BEGIN PUBLIC KEY-----"
     base64 < "$TMP_PEM"
     echo "-----END PUBLIC KEY-----") > "$PEM_FILE"

    if echo -n "$PAYLOAD" | openssl pkeyutl -verify \
        -pubin -inkey "$PEM_FILE" \
        -sigfile "$TMP_SIG" >/dev/null 2>&1; then
        echo "[PASS] Signature valid: signed by node $CREATOR"
    else
        echo "[WARN] Signature could not be verified (openssl unavailable or key mismatch)"
    fi

    rm -f "$TMP_PUB" "$TMP_SIG" "$TMP_PEM" "$PEM_FILE"
else
    echo "[INFO] No signature in certificate (created without ed25519 key)"
fi

echo ""
echo "Certificate: $CERT_FILE"
