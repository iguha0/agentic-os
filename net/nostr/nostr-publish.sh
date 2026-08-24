#!/bin/sh
# nostr-publish.sh — publish to the real Nostr network (NIP-01, BIP340 Schnorr)
#
#   nostr-publish.sh post <text>        sign & publish a kind-1 note
#   nostr-publish.sh profile            publish kind-0 profile metadata
#   nostr-publish.sh key                show your nostr pubkey
#   nostr-publish.sh status             identity + relay connectivity
#
# Requires python3 (present in graphical images). Signing is REAL secp256k1
# Schnorr per BIP340; events are accepted by public relays worldwide.

IDENTITY_DIR="/usr/share/agentic/identity"
export AGENTIC_IDENTITY_DIR="$IDENTITY_DIR"
export AGENTIC_NOSTR_DIR="/usr/share/agentic/nostr"

if ! command -v python3 >/dev/null 2>&1; then
    echo "[nostr] python3 not present in this image (graphical mode has it)."
    echo "[nostr] Events cannot be signed here — boot graphical mode to post."
    exit 1
fi

CMD="${1:-help}"
shift 2>/dev/null

case "$CMD" in
    post)
        [ -z "$1" ] && { echo "Usage: nostr-publish.sh post '<text>'"; exit 1; }
        exec /usr/local/bin/nostr-ws.py post "$*"
        ;;
    profile)
        NAME=$(grep '"name"' /usr/share/agentic/profile.json 2>/dev/null \
            | sed 's/.*"name": *"\([^"]*\)".*/\1/' | head -1)
        CONTENT="{\"name\":\"${NAME:-Agentic OS User}\",\"about\":\"Agentic OS node — the home screen is an agent.\"}"
        exec /usr/local/bin/nostr-ws.py profile "$CONTENT"
        ;;
    key|keygen)
        exec /usr/local/bin/nostr-ws.py key
        ;;
    status)
        exec /usr/local/bin/nostr-ws.py status
        ;;
    *)
        echo "Usage: nostr-publish.sh <post '<text>'|profile|key|status>"
        ;;
esac
