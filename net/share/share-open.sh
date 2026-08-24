#!/bin/sh
# share-open.sh — receive & decrypt a private share (full recipient flow)
#
#   share-open.sh <link>              fetch .enc via relay, E2E-decrypt into inbox
#
# Link format: http://<relay>/f/<node>/prv/<cid>/<filename>.enc
# Uses this device's libsodium identity (agseal) — only the intended
# recipient can open the sealed box. Plaintext lands in
# /usr/share/agentic/inbox/<filename> (with .enc stripped).

AGENTIC_DIR="${AGENTIC_DIR:-/usr/share/agentic}"
INBOX="$AGENTIC_DIR/inbox"
NODE_ID=$(cat "$AGENTIC_DIR/identity/node.id" 2>/dev/null || echo unknown)

link="$1"
[ -z "$link" ] && { echo "ERROR: link required"; exit 1; }

mkdir -p "$INBOX"

# fetch ciphertext
TMP_ENC="/tmp/agshare-$$.enc"
if ! wget -q -T 60 -O "$TMP_ENC" "$link"; then
    rm -f "$TMP_ENC"
    echo "ERROR: could not fetch $link"
    exit 1
fi

SIZE=$(wc -c < "$TMP_ENC")
if [ "$SIZE" -lt 48 ]; then
    echo "ERROR: fetched payload too small ($SIZE bytes) — wrong link?"
    cat "$TMP_ENC"; echo
    rm -f "$TMP_ENC"
    exit 1
fi

# derive plaintext name
BASE=$(basename "$link")
NAME="${BASE%.enc}"
NAME=$(printf '%s' "$NAME" | sed 's/%20/ /g')
OUT="$INBOX/$NAME"

# decrypt with our sealed-box identity
if [ -x /usr/local/bin/agseal ]; then
    if ! /usr/local/bin/agseal open "$TMP_ENC" "$OUT" >/dev/null 2>&1; then
        # maybe sealed for someone else, or legacy openssl bundle
        if [ -f "$OUT" ]; then rm -f "$OUT"; fi
        echo "ERROR: decryption failed — this share was not sealed for this device ($NODE_ID)"
        rm -f "$TMP_ENC"
        exit 1
    fi
else
    echo "ERROR: agseal not installed on this device"
    rm -f "$TMP_ENC"
    exit 1
fi

rm -f "$TMP_ENC"
PSIZE=$(wc -c < "$OUT" 2>/dev/null || echo 0)
echo "OK: $OUT ($PSIZE bytes)"
