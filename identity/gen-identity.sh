#!/bin/sh
# gen-identity.sh — generate node identity on first boot
# Creates an ed25519 keypair using openssl.
# Called by agentic-init.sh once; skipped if identity already exists.

IDENTITY_DIR="/usr/share/agentic/identity"
KEY_FILE="$IDENTITY_DIR/node.key"       # PEM private key
PUB_FILE="$IDENTITY_DIR/node.pub"       # PEM public key
ID_FILE="$IDENTITY_DIR/node.id"         # short hex node ID
ADDR_FILE="$IDENTITY_DIR/node.addr"     # full base64 public key (shareable)

[ -f "$ID_FILE" ] && [ -f "$KEY_FILE" ] && {
    echo "[identity] already initialized: $(cat $ID_FILE)"
    exit 0
}

mkdir -p "$IDENTITY_DIR"
chmod 700 "$IDENTITY_DIR"

echo "[identity] generating ed25519 keypair..."

# Generate private key
if ! openssl genpkey -algorithm ed25519 -out "$KEY_FILE" 2>/dev/null; then
    # Fallback: generate random node ID without real crypto
    node_id=$(cat /dev/urandom | od -A n -t x1 | tr -d ' \n' | head -c 32)
    echo "$node_id" > "$ID_FILE"
    echo "[identity] WARNING: openssl ed25519 not available, using random ID"
    echo "[identity] node ID: $node_id"
    exit 0
fi
chmod 600 "$KEY_FILE"

# Extract public key
openssl pkey -in "$KEY_FILE" -pubout -out "$PUB_FILE" 2>/dev/null
chmod 644 "$PUB_FILE"

# Create shareable base64 address (raw public key bytes, base64-encoded)
openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null \
    | tail -c 32 \
    | base64 \
    > "$ADDR_FILE"

# Node ID = first 16 hex chars of SHA256 of public key
node_id=$(openssl pkey -in "$KEY_FILE" -pubout -outform DER 2>/dev/null \
    | sha256sum | cut -c1-16)
echo "$node_id" > "$ID_FILE"

echo "[identity] node ID:   $node_id"
echo "[identity] public key: $(cat $ADDR_FILE)"
echo "[identity] private key: $KEY_FILE (never share this)"
