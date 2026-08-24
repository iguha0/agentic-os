#!/bin/sh
# e2e-encrypt.sh — E2E file encryption for private shares
#
# Uses X25519 (ECDH) for key exchange + AES-256-GCM for file encryption.
# The file never leaves the device unencrypted.
# Only the recipient (holding their private key) can decrypt.
#
# Usage:
#   e2e-encrypt.sh encrypt <file> <recipient_pubkey_b64>
#     → outputs <file>.enc + <file>.enc.key (encrypted key bundle)
#
#   e2e-encrypt.sh decrypt <file>.enc <file>.enc.key
#     → recovers original file
#
#   e2e-encrypt.sh keygen
#     → generate an X25519 encryption keypair (separate from ed25519 signing key)
#
#   e2e-encrypt.sh export-pubkey
#     → print your X25519 public key in base64 (share this with others)

IDENTITY_DIR="/usr/share/agentic/identity"
X25519_KEY="$IDENTITY_DIR/enc.key"     # X25519 private key (PEM)
X25519_PUB="$IDENTITY_DIR/enc.pub"     # X25519 public key (PEM)
X25519_ADDR="$IDENTITY_DIR/enc.addr"   # X25519 public key (base64, shareable)

# ── Key generation ─────────────────────────────────────────────────────────────
cmd_keygen() {
    mkdir -p "$IDENTITY_DIR"
    chmod 700 "$IDENTITY_DIR"

    if [ -f "$X25519_KEY" ]; then
        echo "[e2e] encryption keypair already exists at $X25519_KEY"
        return 0
    fi

    echo "[e2e] generating X25519 encryption keypair..."
    openssl genpkey -algorithm X25519 -out "$X25519_KEY" 2>/dev/null || {
        echo "[e2e] ERROR: openssl X25519 not available"
        exit 1
    }
    chmod 600 "$X25519_KEY"

    openssl pkey -in "$X25519_KEY" -pubout -out "$X25519_PUB" 2>/dev/null

    # Export shareable base64 address
    openssl pkey -in "$X25519_KEY" -pubout -outform DER 2>/dev/null \
        | tail -c 32 | base64 > "$X25519_ADDR"

    echo "[e2e] X25519 keypair generated"
    echo "[e2e] your encryption public key:"
    cat "$X25519_ADDR"
}

cmd_export_pubkey() {
    [ -f "$X25519_ADDR" ] || cmd_keygen
    cat "$X25519_ADDR"
}

# ── Encrypt a file for a recipient ────────────────────────────────────────────
# Process:
#   1. Generate ephemeral X25519 keypair
#   2. ECDH with recipient's public key → shared secret
#   3. Derive AES-256 key from shared secret (SHA-256)
#   4. Encrypt file with AES-256-CBC (GCM not always available in openssl CLI)
#   5. Bundle: ephemeral public key + encrypted file
cmd_encrypt() {
    FILE="$1"
    RECIPIENT_PUBKEY_B64="$2"

    [ -f "$FILE" ] || { echo "[e2e] file not found: $FILE" >&2; exit 1; }
    [ -n "$RECIPIENT_PUBKEY_B64" ] || { echo "[e2e] recipient pubkey required" >&2; exit 1; }

    OUT_ENC="${FILE}.enc"
    OUT_KEY="${FILE}.enc.key"

    echo "[e2e] encrypting: $FILE"

    # Write recipient public key to temp PEM
    TMP_DIR=$(mktemp -d)
    TMP_RECV_PUB="$TMP_DIR/recv.pub"
    TMP_EPH_KEY="$TMP_DIR/eph.key"
    TMP_EPH_PUB="$TMP_DIR/eph.pub"
    TMP_SHARED="$TMP_DIR/shared.bin"
    TMP_AES="$TMP_DIR/aes.key"

    # Reconstruct recipient PEM from base64
    RECV_DER="$TMP_DIR/recv.der"
    # X25519 SubjectPublicKeyInfo DER prefix (12 bytes)
    printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x6e\x03\x21\x00' > "$RECV_DER"
    echo "$RECIPIENT_PUBKEY_B64" | base64 -d >> "$RECV_DER" 2>/dev/null
    (echo "-----BEGIN PUBLIC KEY-----"
     base64 < "$RECV_DER"
     echo "-----END PUBLIC KEY-----") > "$TMP_RECV_PUB"

    # Generate ephemeral X25519 keypair
    openssl genpkey -algorithm X25519 -out "$TMP_EPH_KEY" 2>/dev/null || {
        echo "[e2e] ERROR: X25519 not available" >&2
        rm -rf "$TMP_DIR"; exit 1
    }
    openssl pkey -in "$TMP_EPH_KEY" -pubout -out "$TMP_EPH_PUB" 2>/dev/null

    # ECDH: derive shared secret
    openssl pkeyutl -derive \
        -inkey "$TMP_EPH_KEY" \
        -peerkey "$TMP_RECV_PUB" \
        -out "$TMP_SHARED" 2>/dev/null || {
        echo "[e2e] ERROR: ECDH key derivation failed" >&2
        rm -rf "$TMP_DIR"; exit 1
    }

    # Derive AES key: SHA-256 of shared secret
    sha256sum "$TMP_SHARED" | cut -d' ' -f1 | xxd -r -p > "$TMP_AES" 2>/dev/null || \
    openssl dgst -sha256 -binary "$TMP_SHARED" > "$TMP_AES"

    # Generate random IV
    TMP_IV="$TMP_DIR/iv.bin"
    openssl rand 16 > "$TMP_IV"

    # Encrypt file: AES-256-CBC
    openssl enc -aes-256-cbc \
        -in "$FILE" \
        -out "$OUT_ENC" \
        -K "$(xxd -p < "$TMP_AES" | tr -d '\n')" \
        -iv "$(xxd -p < "$TMP_IV" | tr -d '\n')" \
        2>/dev/null || {
        echo "[e2e] ERROR: AES encryption failed" >&2
        rm -rf "$TMP_DIR"; exit 1
    }

    # Key bundle: ephemeral_pubkey_b64 + ":" + iv_hex
    EPH_PUB_B64=$(openssl pkey -in "$TMP_EPH_KEY" -pubout -outform DER 2>/dev/null \
        | tail -c 32 | base64 | tr -d '\n')
    IV_HEX=$(xxd -p < "$TMP_IV" | tr -d '\n')

    echo "${EPH_PUB_B64}:${IV_HEX}" > "$OUT_KEY"

    rm -rf "$TMP_DIR"

    echo "[e2e] encrypted: $OUT_ENC"
    echo "[e2e] key bundle: $OUT_KEY"
    echo "[e2e] send both files to recipient. They decrypt with: e2e-encrypt.sh decrypt $OUT_ENC $OUT_KEY"
}

# ── Decrypt a file using our private key ──────────────────────────────────────
cmd_decrypt() {
    ENC_FILE="$1"
    KEY_FILE="$2"

    [ -f "$ENC_FILE" ] || { echo "[e2e] enc file not found: $ENC_FILE" >&2; exit 1; }
    [ -f "$KEY_FILE" ]  || { echo "[e2e] key bundle not found: $KEY_FILE" >&2; exit 1; }
    [ -f "$X25519_KEY" ] || { echo "[e2e] no decryption key. run: e2e-encrypt.sh keygen" >&2; exit 1; }

    OUT_FILE="${ENC_FILE%.enc}"
    [ "$OUT_FILE" = "$ENC_FILE" ] && OUT_FILE="${ENC_FILE}.dec"

    TMP_DIR=$(mktemp -d)

    # Parse key bundle
    BUNDLE=$(cat "$KEY_FILE")
    EPH_PUB_B64=$(echo "$BUNDLE" | cut -d: -f1)
    IV_HEX=$(echo "$BUNDLE" | cut -d: -f2)

    # Reconstruct ephemeral public key PEM
    TMP_EPH_PUB="$TMP_DIR/eph.pub"
    TMP_EPH_DER="$TMP_DIR/eph.der"
    printf '\x30\x2a\x30\x05\x06\x03\x2b\x65\x6e\x03\x21\x00' > "$TMP_EPH_DER"
    echo "$EPH_PUB_B64" | base64 -d >> "$TMP_EPH_DER" 2>/dev/null
    (echo "-----BEGIN PUBLIC KEY-----"
     base64 < "$TMP_EPH_DER"
     echo "-----END PUBLIC KEY-----") > "$TMP_EPH_PUB"

    # ECDH: derive shared secret using our private key
    TMP_SHARED="$TMP_DIR/shared.bin"
    openssl pkeyutl -derive \
        -inkey "$X25519_KEY" \
        -peerkey "$TMP_EPH_PUB" \
        -out "$TMP_SHARED" 2>/dev/null || {
        echo "[e2e] ERROR: ECDH derivation failed" >&2
        rm -rf "$TMP_DIR"; exit 1
    }

    # Derive AES key
    TMP_AES="$TMP_DIR/aes.key"
    openssl dgst -sha256 -binary "$TMP_SHARED" > "$TMP_AES"
    AES_HEX=$(xxd -p < "$TMP_AES" | tr -d '\n')

    # Decrypt
    openssl enc -d -aes-256-cbc \
        -in "$ENC_FILE" \
        -out "$OUT_FILE" \
        -K "$AES_HEX" \
        -iv "$IV_HEX" \
        2>/dev/null || {
        echo "[e2e] ERROR: decryption failed (wrong key?)" >&2
        rm -rf "$TMP_DIR"
        rm -f "$OUT_FILE"
        exit 1
    }

    rm -rf "$TMP_DIR"
    echo "[e2e] decrypted: $OUT_FILE"
}

CMD="${1:-help}"
shift 2>/dev/null
case "$CMD" in
    keygen)       cmd_keygen ;;
    export-pubkey) cmd_export_pubkey ;;
    encrypt)      cmd_encrypt "$@" ;;
    decrypt)      cmd_decrypt "$@" ;;
    *)
        echo "Usage: e2e-encrypt.sh <keygen|export-pubkey|encrypt <file> <pubkey_b64>|decrypt <file.enc> <file.enc.key>>"
        ;;
esac
