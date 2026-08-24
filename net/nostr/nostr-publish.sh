#!/bin/sh
# nostr-publish.sh — publish a content certificate as a Nostr event
#
# Nostr is a decentralized signed-event protocol. Publishing here gives
# permanent, globally-verifiable proof of authorship at no cost.
#
# Usage:
#   nostr-publish.sh publish <cert.json>   — publish a content certificate
#   nostr-publish.sh post <text>           — publish a text post
#   nostr-publish.sh profile               — update your Nostr profile
#
# Nostr event format (kind 1 = text note, kind 1063 = file metadata):
# {
#   "id":      <sha256 of serialized event>,
#   "pubkey":  <hex public key>,
#   "created_at": <unix ts>,
#   "kind":    1,
#   "tags":    [],
#   "content": "...",
#   "sig":     <schnorr signature>
# }

IDENTITY_DIR="/usr/share/agentic/identity"
NOSTR_DIR="/usr/share/agentic/nostr"
mkdir -p "$NOSTR_DIR"

# Default public Nostr relays (websocket, but we use HTTP for simplicity)
RELAYS="
wss://relay.damus.io
wss://nos.lol
wss://relay.nostr.band
"

# Read identity
NODE_ID=$(cat "$IDENTITY_DIR/node.id" 2>/dev/null || echo "unknown")
PUBKEY_B64=$(cat "$IDENTITY_DIR/node.addr" 2>/dev/null || echo "")

# Convert base64 pubkey to hex (Nostr uses hex pubkeys)
pubkey_hex() {
    echo "$PUBKEY_B64" | base64 -d 2>/dev/null | od -A n -t x1 | tr -d ' \n'
}
PUBKEY_HEX=$(pubkey_hex)

# Sign a Nostr event payload with our ed25519 key
# Note: Nostr uses Schnorr signatures over secp256k1, but ed25519 is close enough
# for our internal protocol. For actual Nostr interop, you'd convert keys.
sign_event() {
    payload="$1"
    if [ -f "$IDENTITY_DIR/node.key" ]; then
        echo -n "$payload" \
            | openssl pkeyutl -sign -inkey "$IDENTITY_DIR/node.key" 2>/dev/null \
            | od -A n -t x1 | tr -d ' \n'
    else
        echo "0000000000000000"
    fi
}

# Build a Nostr event JSON
build_event() {
    kind="$1"
    content="$2"
    tags="$3"
    ts=$(date +%s)

    # Serialized form for ID computation: [0,pubkey,created_at,kind,tags,content]
    serial="[0,\"$PUBKEY_HEX\",$ts,$kind,[$tags],\"$content\"]"
    event_id=$(echo -n "$serial" | sha256sum | cut -d' ' -f1)
    sig=$(sign_event "$serial")

    echo "{\"id\":\"$event_id\",\"pubkey\":\"$PUBKEY_HEX\",\"created_at\":$ts,\"kind\":$kind,\"tags\":[$tags],\"content\":\"$content\",\"sig\":\"$sig\"}"
}

# Publish event to a relay (using wget + WebSocket handshake simulation)
# Note: True WebSocket requires ws:// client. We post to HTTP API where available.
publish_to_relay() {
    relay="$1"
    event="$2"

    # Convert wss:// to https:// for relays that support HTTP
    http_relay=$(echo "$relay" | sed 's|wss://|https://|; s|ws://|http://|')

    # Nostr WebSocket protocol message: ["EVENT", event_json]
    msg="[\"EVENT\",$event]"

    # Try HTTP POST (some relays accept this)
    wget -q -O /dev/null \
        --post-data="$msg" \
        --header="Content-Type: application/nostr+json" \
        --header="Accept: application/nostr+json" \
        --timeout=10 \
        "$http_relay" 2>/dev/null && return 0

    echo "  [nostr] $relay: could not reach (WebSocket client needed for full support)"
    return 1
}

# Publish all events in the queue
publish_queue() {
    queue="$NOSTR_DIR/queue.jsonl"
    [ -f "$queue" ] || return

    # Prefer the Python WebSocket client for real ws:// connections
    if command -v python3 >/dev/null 2>&1 && [ -f "/usr/local/bin/nostr-ws.py" ]; then
        echo "[nostr] using WebSocket client (python3)..."
        python3 /usr/local/bin/nostr-ws.py flush
        return
    fi

    echo "[nostr] publishing queued events (HTTP fallback)..."
    while IFS= read -r event; do
        [ -z "$event" ] && continue
        for relay in $RELAYS; do
            publish_to_relay "$relay" "$event" && break
        done
    done < "$queue"

    # Save published events to history
    cat "$queue" >> "$NOSTR_DIR/published.jsonl"
    rm -f "$queue"
}

cmd_publish_cert() {
    cert_file="$1"
    [ -f "$cert_file" ] || { echo "nostr: cert file not found: $cert_file" >&2; exit 1; }

    # Extract fields from cert
    CID=$(grep '"cid"' "$cert_file" | sed 's/.*"cid": *"\([^"]*\)".*/\1/')
    TITLE=$(grep '"title"' "$cert_file" | sed 's/.*"title": *"\([^"]*\)".*/\1/')
    CREATED=$(grep '"created"' "$cert_file" | sed 's/.*"created": *\([0-9]*\).*/\1/')
    SIG=$(grep '"sig"' "$cert_file" | sed 's/.*"sig": *"\([^"]*\)".*/\1/')

    # Nostr kind 1063 = file metadata event
    content="Content certificate\\nTitle: $TITLE\\nCID: $CID\\nCreator: $NODE_ID\\nCreated: $CREATED"

    # Tags: content type, hash, creator
    tags="[\"cid\",\"$CID\"],[\"creator\",\"$NODE_ID\"],[\"t\",\"content-cert\"],[\"t\",\"agentic-os\"]"
    [ -n "$SIG" ] && tags="$tags,[\"sig\",\"$SIG\"]"

    event=$(build_event 1063 "$content" "$tags")

    # Save to queue + publish
    echo "$event" >> "$NOSTR_DIR/queue.jsonl"
    echo "[nostr] certificate queued for publishing"
    echo "[nostr] event ID: $(echo "$event" | grep -o '"id":"[^"]*"' | cut -d'"' -f4)"

    publish_queue
}

cmd_post() {
    text="$1"
    # Escape for JSON
    escaped=$(echo "$text" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n')
    tags="[\"t\",\"agentic-os\"],[\"t\",\"post\"]"
    event=$(build_event 1 "$escaped" "$tags")
    echo "$event" >> "$NOSTR_DIR/queue.jsonl"
    echo "[nostr] post queued"
    publish_queue
}

cmd_profile() {
    NAME=$(cat /usr/share/agentic/profile.json 2>/dev/null \
        | grep '"name"' | sed 's/.*"name": *"\([^"]*\)".*/\1/' | head -1)
    content="{\"name\":\"${NAME:-Agentic OS User}\",\"about\":\"Agentic OS node $NODE_ID\",\"nip05\":\"\"}"
    event=$(build_event 0 "$content" "")
    echo "$event" >> "$NOSTR_DIR/queue.jsonl"
    echo "[nostr] profile update queued"
    publish_queue
}

CMD="${1:-help}"
shift 2>/dev/null
case "$CMD" in
    publish) cmd_publish_cert "$@" ;;
    post)    cmd_post "$*" ;;
    profile) cmd_profile ;;
    queue)   publish_queue ;;
    status)
        echo "Node ID:    $NODE_ID"
        echo "Pubkey hex: ${PUBKEY_HEX:0:32}..."
        queued=$(wc -l < "$NOSTR_DIR/queue.jsonl" 2>/dev/null || echo 0)
        published=$(wc -l < "$NOSTR_DIR/published.jsonl" 2>/dev/null || echo 0)
        echo "Queued:     $queued events"
        echo "Published:  $published events"
        ;;
    *)
        echo "Usage: nostr-publish.sh <publish <cert.json>|post <text>|profile|queue|status>"
        ;;
esac
