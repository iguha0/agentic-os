#!/bin/sh
# agentic-shared — on-device content serving daemon
# Runs inside Agentic OS. Serves files via busybox httpd.
# Called by the AI agent when user says "share X".
#
# Usage:
#   agentic-shared start                  — start share daemon + relay tunnel
#   agentic-shared stop                   — stop everything
#   agentic-shared share <file> public    — create public share
#   agentic-shared share <file> selective <recipient1,recipient2> [expires_epoch] [max_downloads]
#   agentic-shared share <file> private <recipient_enc_pubkey_b64>
#   agentic-shared revoke <cid> [recipient]
#   agentic-shared list                   — list active shares
#   agentic-shared log <cid>              — access log for a share
#   agentic-shared status                 — daemon + tunnel status

AGENTIC_DIR="/usr/share/agentic"
SHARE_DIR="$AGENTIC_DIR/shares"
IDENTITY_DIR="$AGENTIC_DIR/identity"
SERVE_ROOT="/tmp/agentic-serve"
DAEMON_PORT="7070"
DAEMON_PID="$SHARE_DIR/daemon.pid"
RELAY_URL="${AGENTOS_RELAY_URL:-http://10.0.2.2:7075}"
INDEX_FILE="$SHARE_DIR/index.json"

# ── Helpers ───────────────────────────────────────────────────────────────────

log() { echo "[agentic-shared] $*"; }

die() { log "ERROR: $*" >&2; exit 1; }

# Generate a sha256 CID for a file
cid_of() {
    sha256sum "$1" 2>/dev/null | cut -d' ' -f1
}

# Generate a random token (32 hex chars)
gen_token() {
    dd if=/dev/urandom bs=16 count=1 2>/dev/null | od -A n -t x1 | tr -d ' \n'
}

# Get or create node identity
ensure_identity() {
    mkdir -p "$IDENTITY_DIR"
    if [ ! -f "$IDENTITY_DIR/node.id" ]; then
        log "generating node identity..."
        # Generate a random node ID (in production: ed25519 keypair)
        node_id=$(gen_token | cut -c1-16)
        echo "$node_id" > "$IDENTITY_DIR/node.id"
        log "node ID: $node_id"
    fi
    NODE_ID=$(cat "$IDENTITY_DIR/node.id")
}

# Initialize share index if missing
ensure_index() {
    mkdir -p "$SHARE_DIR" "$SHARE_DIR/tokens" "$SHARE_DIR/logs"
    [ -f "$INDEX_FILE" ] || echo '{"shares":[]}' > "$INDEX_FILE"
}

# Add a share record to the index
index_add() {
    cid="$1"; mode="$2"; file="$3"; title="$4"
    tmp=$(mktemp)
    ts=$(date +%s)
    record="{\"cid\":\"$cid\",\"mode\":\"$mode\",\"file\":\"$file\",\"title\":\"$title\",\"created\":$ts,\"node\":\"$NODE_ID\"}"
    # Append to shares array ('|' delimiter: paths contain '/')
    sed "s|\"shares\":\[|\"shares\":[$record,|" "$INDEX_FILE" > "$tmp" && mv "$tmp" "$INDEX_FILE"
}

# ── HTTP handler via busybox httpd ────────────────────────────────────────────

# Build the serve root directory — each share gets a symlink
build_serve_root() {
    rm -rf "$SERVE_ROOT"
    mkdir -p "$SERVE_ROOT/pub" "$SERVE_ROOT/sel" "$SERVE_ROOT/prv"

    # For each share in index, create a route
    # /pub/<node_id>/<cid>/<filename>  → actual file
    # /sel/<node_id>/<cid>/<token>/    → token-gated file
    # Public shares
    if [ -f "$INDEX_FILE" ]; then
        # Parse shares (simple grep — no jq needed)
        grep '"mode":"public"' "$INDEX_FILE" | while IFS= read -r line; do
            cid=$(echo "$line" | grep -o '"cid":"[^"]*"' | cut -d'"' -f4)
            file=$(echo "$line" | grep -o '"file":"[^"]*"' | cut -d'"' -f4)
            [ -n "$cid" ] && [ -f "$file" ] || continue
            fname=$(basename "$file")
            mkdir -p "$SERVE_ROOT/pub/$NODE_ID/$cid"
            ln -sf "$file" "$SERVE_ROOT/pub/$NODE_ID/$cid/$fname"
        done

        # Selective shares — token dirs
        grep '"mode":"selective"' "$INDEX_FILE" | while IFS= read -r line; do
            cid=$(echo "$line" | grep -o '"cid":"[^"]*"' | cut -d'"' -f4)
            file=$(echo "$line" | grep -o '"file":"[^"]*"' | cut -d'"' -f4)
            [ -n "$cid" ] && [ -f "$file" ] || continue
            fname=$(basename "$file")
            # Each token gets its own dir
            if [ -d "$SHARE_DIR/tokens/$cid" ]; then
                for tok_file in "$SHARE_DIR/tokens/$cid/"*.token; do
                    [ -f "$tok_file" ] || continue
                    token=$(cat "$tok_file")
                    mkdir -p "$SERVE_ROOT/sel/$NODE_ID/$cid/$token"
                    ln -sf "$file" "$SERVE_ROOT/sel/$NODE_ID/$cid/$token/$fname"
                done
            fi
        done
    fi

    # Write a minimal CGI-free httpd config
    cat > "$SERVE_ROOT/.httpd.conf" <<EOF
# agentic-shared httpd config
# Log to stderr for agent to monitor
logfile:/tmp/agentic-shared-access.log
EOF
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_start() {
    ensure_identity
    ensure_index
    build_serve_root

    if [ -f "$DAEMON_PID" ] && kill -0 "$(cat $DAEMON_PID)" 2>/dev/null; then
        log "already running (pid $(cat $DAEMON_PID))"
        return
    fi

    # Start busybox httpd
    busybox httpd -p "$DAEMON_PORT" -h "$SERVE_ROOT" -f &
    echo $! > "$DAEMON_PID"
    log "started on port $DAEMON_PORT (pid $!)"

    # Register with relay (best-effort)
    register_with_relay &
}

cmd_stop() {
    if [ -f "$DAEMON_PID" ]; then
        kill "$(cat $DAEMON_PID)" 2>/dev/null
        rm -f "$DAEMON_PID"
        log "stopped"
    else
        log "not running"
    fi
}

register_with_relay() {
    # Start the long-poll tunnel client (real relay transport).
    /usr/local/bin/agtunnel start "$RELAY_URL"
}

cmd_share() {
    file="$1"; mode="$2"; recipients="$3"; expires="$4"; maxdl="$5"
    ensure_identity
    ensure_index

    [ -f "$file" ] || die "file not found: $file"

    log "sharing: $file"
    log "mode:    $mode"

    case "$mode" in
        public)
            cid=$(cid_of "$file")
            fname=$(basename "$file")
            title="${fname%.*}"
            index_add "$cid" "public" "$file" "$title"
            build_serve_root
            publish_to_dht "$cid" "$file" "$title"
            register_with_relay
            echo ""
            echo "Share link:"
            echo "  $RELAY_URL/f/$NODE_ID/pub/$cid/$fname"
            /usr/local/bin/lnurl-pay tip-url "$cid" 2>/dev/null || true
            echo ""
            echo "CID: $cid"
            ;;

        selective)
            [ -n "$recipients" ] || die "provide at least one recipient (comma separated)"
            cid=$(cid_of "$file")
            fname=$(basename "$file")
            title="${fname%.*}"
            index_add "$cid" "selective" "$file" "$title"
            mkdir -p "$SHARE_DIR/tokens/$cid"

            echo ""
            echo "Selective share created: $title"
            if [ -n "$expires" ] && [ "$expires" != "0" ]; then
                echo "Expires:  $(date -d @$expires 2>/dev/null || echo epoch $expires)"
            fi
            if [ -n "$maxdl" ] && [ "$maxdl" != "0" ]; then
                echo "Max dl:   $maxdl per recipient"
            fi
            echo ""

            IFS=','
            for recipient in $recipients; do
                recipient=$(echo "$recipient" | tr -d ' ')
                token=$(gen_token)
                echo "$token" > "$SHARE_DIR/tokens/$cid/$recipient.token"
                {
                    echo "expiry ${expires:-0}"
                    echo "max_dl ${maxdl:-0}"
                    echo "count 0"
                } > "$SHARE_DIR/tokens/$cid/$recipient.meta"
                echo "  $recipient:"
                echo "    $RELAY_URL/f/$NODE_ID/sel/$cid/$token/$fname"
            done
            unset IFS
            echo ""
            echo "Each link works only for its token."
            echo "Revoke with: agentic-shared revoke $cid <recipient>"
            build_serve_root
            register_with_relay
            ;;

        private)
            [ -n "$recipients" ] || die "private mode needs the recipient's encryption pubkey (base64)"
            cid=$(cid_of "$file")
            fname=$(basename "$file")
            title="${fname%.*}"

            # Preferred: libsodium sealed box (crypto_box_seal). Recipient opens
            # with their private key alone — no key bundle to distribute.
            if [ -x /usr/local/bin/agseal ]; then
                /usr/local/bin/agseal seal "$file" "$recipients" "$file.enc" || die "agseal seal failed"
                index_add "$cid" "private" "$file.enc" "$title"
                build_serve_root
                register_with_relay
                echo ""
                echo "Private share created (libsodium sealed box): $title"
                echo "Ciphertext link:"
                echo "  $RELAY_URL/f/$NODE_ID/prv/$cid/$fname.enc"
                echo ""
                echo "Recipient opens with: agseal open $fname.enc $fname"
                echo "CID: $cid"
            else
                # Fallback: openssl X25519 + AES-256-CBC with key bundle file.
                /usr/local/bin/e2e-encrypt encrypt "$file" "$recipients" || die "encryption failed"
                index_add "$cid" "private" "$file.enc" "$title"
                build_serve_root
                register_with_relay
                echo ""
                echo "Private share created (E2E encrypted, X25519+AES-256): $title"
                echo "Ciphertext link:"
                echo "  $RELAY_URL/f/$NODE_ID/prv/$cid/$fname.enc"
                echo "Key bundle (send via another channel):"
                echo "  $file.enc.key"
                echo ""
                echo "CID: $cid"
            fi
            ;;

        *)
            die "unknown mode: $mode (use: public | selective | private)"
            ;;
    esac
}

publish_to_dht() {
    cid="$1"; file="$2"; title="$3"
    size_kb=$(du -k "$file" 2>/dev/null | cut -f1)
    mime=$(file -b --mime-type "$file" 2>/dev/null || echo "application/octet-stream")
    ts=$(date +%s)

    # tags: filename tokens (minus extension) so search finds "sunset photo.jpg"
    base=$(basename "$file"); base="${base%.*}"
    TAGS=$(printf '%s' "$base" | tr '-_.' ',' | tr -cd 'a-zA-Z0-9,')
    record="{\"cid\":\"$cid\",\"node_id\":\"$NODE_ID\",\"relay_url\":\"$RELAY_URL\",\"title\":\"$title\",\"type\":\"$mime\",\"size_kb\":$size_kb,\"tags\":\"$TAGS\",\"published\":$ts}"

    # Post to configured DHT nodes (comma separated). Default: local bootstrap.
    DHT_NODES="${AGENTOS_DHT_NODES:-http://10.0.2.2:8889}"
    for dht_node in $(printf '%s' "$DHT_NODES" | tr ',' ' '); do
        wget -q -T 5 -O /dev/null \
            --post-data="$record" \
            --header="Content-Type: application/json" \
            "$dht_node/publish" 2>/dev/null &
    done

    log "published to DHT: $cid"
}

cmd_revoke() {
    cid="$1"; recipient="$2"
    ensure_identity
    ensure_index

    if [ -n "$recipient" ]; then
        tok_file="$SHARE_DIR/tokens/$cid/$recipient.token"
        if [ -f "$tok_file" ]; then
            rm -f "$tok_file"
            log "revoked access for $recipient on $cid"
            build_serve_root
        else
            die "no token found for $recipient on $cid"
        fi
    else
        # Revoke entire share (index may be a single line; grep -v can exit 1)
        rm -rf "$SHARE_DIR/tokens/$cid"
        tmp=$(mktemp)
        grep -v "\"cid\":\"$cid\"" "$INDEX_FILE" > "$tmp" 2>/dev/null || true
        mv "$tmp" "$INDEX_FILE"
        build_serve_root
        log "share $cid fully revoked"
    fi
}

cmd_list() {
    ensure_index
    echo ""
    echo "Active shares:"
    echo "─────────────────────────────────────────"
    if [ -f "$INDEX_FILE" ]; then
        grep '"cid"' "$INDEX_FILE" | while IFS= read -r line; do
            cid=$(echo "$line" | grep -o '"cid":"[^"]*"' | cut -d'"' -f4)
            mode=$(echo "$line" | grep -o '"mode":"[^"]*"' | cut -d'"' -f4)
            title=$(echo "$line" | grep -o '"title":"[^"]*"' | cut -d'"' -f4)
            echo "  [$mode] $title"
            echo "          cid: $cid"
        done
    else
        echo "  (none)"
    fi
    echo ""
}

cmd_log() {
    cid="$1"
    log_file="/tmp/agentic-shared-access.log"
    [ -f "$log_file" ] || { echo "no access log yet"; return; }
    echo "Access log for $cid:"
    grep "$cid" "$log_file" 2>/dev/null || echo "  (no accesses recorded)"
}

cmd_status() {
    if [ -f "$DAEMON_PID" ] && kill -0 "$(cat $DAEMON_PID)" 2>/dev/null; then
        echo "agentic-shared: RUNNING (pid $(cat $DAEMON_PID), port $DAEMON_PORT)"
    else
        echo "agentic-shared: STOPPED"
    fi
    /usr/local/bin/agtunnel status 2>/dev/null || true
    ensure_index
    count=$(grep -c '"cid"' "$INDEX_FILE" 2>/dev/null || echo 0)
    echo "Active shares: $count"
    echo "Relay: $RELAY_URL"
    echo "DHT:   ${AGENTOS_DHT_NODES:-http://10.0.2.2:8889}"
    echo "Node ID: $(cat $IDENTITY_DIR/node.id 2>/dev/null || echo 'not initialized')"
}

# ── Entrypoint ────────────────────────────────────────────────────────────────

CMD="$1"; shift
case "$CMD" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    share)   cmd_share "$@" ;;
    revoke)  cmd_revoke "$@" ;;
    list)    cmd_list ;;
    log)     cmd_log "$@" ;;
    status)  cmd_status ;;
    restart) cmd_stop; cmd_start ;;
    *)
        echo "Usage: agentic-shared <start|stop|restart|status|list>"
        echo "       agentic-shared share <file> public"
        echo "       agentic-shared share <file> selective <recipients> [expires_epoch] [max_downloads]"
        echo "       agentic-shared share <file> private <recipient_enc_pubkey_b64>"
        echo "       agentic-shared revoke <cid> [recipient]"
        echo "       agentic-shared log <cid>"
        exit 1
        ;;
esac
