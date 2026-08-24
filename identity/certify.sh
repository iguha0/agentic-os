#!/bin/sh
# certify.sh — create a signed content certificate for a file
#
# Usage: certify.sh <file> [title]
# Output: prints certificate JSON, saves to /usr/share/agentic/certs/
#
# Certificate format:
# {
#   "cid":      "sha256:<hex>",
#   "creator":  "<node_id>",
#   "pubkey":   "<base64_pubkey>",
#   "file":     "<original path>",
#   "title":    "<title>",
#   "created":  <unix_timestamp>,
#   "size":     <bytes>,
#   "sig":      "<ed25519_signature_base64>"
# }

IDENTITY_DIR="/usr/share/agentic/identity"
CERTS_DIR="/usr/share/agentic/certs"
mkdir -p "$CERTS_DIR"

FILE="$1"
TITLE="${2:-$(basename "$FILE" | sed 's/\.[^.]*$//')}"

[ -f "$FILE" ] || { echo "certify: file not found: $FILE" >&2; exit 1; }
[ -f "$IDENTITY_DIR/node.id" ] || { echo "certify: no identity, run gen-identity.sh first" >&2; exit 1; }

NODE_ID=$(cat "$IDENTITY_DIR/node.id")
PUBKEY=$(cat "$IDENTITY_DIR/node.addr" 2>/dev/null || echo "none")
TIMESTAMP=$(date +%s)
SIZE=$(stat -c %s "$FILE" 2>/dev/null || wc -c < "$FILE")

# Content hash (CID)
CID="sha256:$(sha256sum "$FILE" | cut -d' ' -f1)"

# Perceptual hash for images (using imagemagick if available)
PHASH=""
if command -v convert >/dev/null 2>&1; then
    PHASH=$(convert "$FILE" -resize 32x32! -colorspace gray \
        -format "%[fx:u]" info: 2>/dev/null | sha256sum | cut -c1-16) || true
fi

# Build the unsigned payload (what we sign)
PAYLOAD="{\"cid\":\"$CID\",\"creator\":\"$NODE_ID\",\"created\":$TIMESTAMP}"

# Sign with ed25519 private key
SIG=""
if [ -f "$IDENTITY_DIR/node.key" ]; then
    SIG=$(echo -n "$PAYLOAD" \
        | openssl pkeyutl -sign -inkey "$IDENTITY_DIR/node.key" 2>/dev/null \
        | base64 | tr -d '\n') || SIG=""
fi

# Escape file path for JSON
FILE_ESC=$(echo "$FILE" | sed 's/\\/\\\\/g; s/"/\\"/g')
TITLE_ESC=$(echo "$TITLE" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Build full certificate
CERT=$(cat <<EOF
{
  "cid":       "$CID",
  "creator":   "$NODE_ID",
  "pubkey":    "$PUBKEY",
  "file":      "$FILE_ESC",
  "title":     "$TITLE_ESC",
  "created":   $TIMESTAMP,
  "size":      $SIZE
  ${PHASH:+, "phash":    "$PHASH"}
  ${SIG:+,   "sig":     "$SIG"}
}
EOF
)

# Save certificate
CERT_FILE="$CERTS_DIR/${NODE_ID}_$(echo "$CID" | cut -c8-23).json"
echo "$CERT" > "$CERT_FILE"

echo "$CERT"
echo ""
echo "Certificate saved: $CERT_FILE"
echo "CID: $CID"
echo "To verify: certify-verify.sh $CERT_FILE"
