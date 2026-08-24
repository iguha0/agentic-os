#!/bin/sh
# agtunnel.sh — AgentoNet device-side tunnel client
#
# Keeps a long-poll connection to the relay and serves share requests
# out of the local share index. Pure busybox: wget + coreutils only.
#
#   agtunnel.sh start [relay_url]   daemonize
#   agtunnel.sh stop
#   agtunnel.sh status
#   agtunnel.sh run   [relay_url]   foreground (debug)
#
# The relay is a blind pipe; ALL policy lives here:
#   public     → serve
#   selective  → token segment must match, honour expiry/max-downloads
#   private    → serve ciphertext (recipient decrypts locally)

AGENTIC_DIR="${AGENTIC_DIR:-/usr/share/agentic}"
SHARE_DIR="$AGENTIC_DIR/shares"
IDENTITY_DIR="$AGENTIC_DIR/identity"
INDEX_FILE="$SHARE_DIR/index.json"
LOG_DIR="$SHARE_DIR/logs"
PID_FILE="$SHARE_DIR/tunnel.pid"
RELAY_URL="${AGENTOS_RELAY_URL:-http://10.0.2.2:7075}"
POLL_WAIT=3

log() { echo "[agtunnel] $*" >&2; }

node_id() {
    cat "$IDENTITY_DIR/node.id" 2>/dev/null || echo "unknown-node"
}

urldecode() {
    printf '%b' "${1//%/\\x}"
}

mime_of() {
    case "$1" in
        *.png)  echo "image/png" ;;
        *.jpg|*.jpeg) echo "image/jpeg" ;;
        *.gif)  echo "image/gif" ;;
        *.webp) echo "image/webp" ;;
        *.svg)  echo "image/svg+xml" ;;
        *.mp4)  echo "video/mp4" ;;
        *.webm) echo "video/webm" ;;
        *.mp3)  echo "audio/mpeg" ;;
        *.ogg)  echo "audio/ogg" ;;
        *.pdf)  echo "application/pdf" ;;
        *.zip)  echo "application/zip" ;;
        *.json) echo "application/json" ;;
        *.txt|*.md|*.log|*.conf|*.sh) echo "text/plain" ;;
        *)      echo "application/octet-stream" ;;
    esac
}

# record_lookup <cid> -> echoes "mode<TAB>file" or empty
record_lookup() {
    cid="$1"
    [ -f "$INDEX_FILE" ] || return 1
    # Pull out ONLY the object holding this cid (index.json is a single line).
    line=$(grep -o "\"cid\":\"$cid\"[^}]*}" "$INDEX_FILE" 2>/dev/null | head -n 1)
    [ -z "$line" ] && return 1
    mode=$(printf '%s' "$line" | grep -o '"mode":"[^"]*"' | cut -d'"' -f4)
    file=$(printf '%s' "$line" | grep -o '"file":"[^"]*"' | cut -d'"' -f4)
    printf '%s\t%s\n' "$mode" "$file"
}

# access_log <cid> <result> <bytes>
access_log() {
    mkdir -p "$LOG_DIR"
    printf '%s %s %s %s\n' "$(date +%s)" "$2" "$3" "${1:-"-"}" >> "$LOG_DIR/$1.log" 2>/dev/null || true
}

# respond <rid> <status> <ctype> <file-or-"-"> <errtext-if-dash>
# Payload is base64'd: busybox wget mangles binary post bodies (NUL truncation).
respond() {
    rid="$1"; status="$2"; ctype="$3"; body_file="$4"; errtext="$5"
    tmp="/tmp/agtunnel-resp.$$"
    if [ "$body_file" = "-" ]; then
        printf 'RESP %s %s %s\n%s' "$rid" "$status" "$ctype" "$errtext" > "$tmp"
    else
        { printf 'RESP %s %s %s B64\n' "$rid" "$status" "$ctype"; base64 < "$body_file"; } > "$tmp" 2>/dev/null
    fi
    wget -q -T 20 -O /dev/null --post-file "$tmp" "$RELAY_URL/respond/$NODE" 2>/dev/null
    rm -f "$tmp"
}

# handle_request <rid> <method> <path>
handle_request() {
    rid="$1"; m="$2"; path="$3"
    path=$(printf '%s' "$path" | sed 's/%20/ /g; s/%2B/+/g')

    # path grammar: /<pub|sel|prv>/<cid>[/<token>]/<filename>
    set -- $(printf '%s' "$path" | tr '/' ' ')
    [ $# -lt 3 ] && { respond "$rid" 404 text/plain - "not found"; return; }
    pmode="$1"; shift
    cid="$1"; shift

    lookup=$(record_lookup "$cid")
    [ -z "$lookup" ] && { respond "$rid" 404 text/plain - "unknown content"; return; }
    rmode=${lookup%%	*}
    file=${lookup#*	}
    fname=$(basename "$file")

    # mode must match prefix used in link
    case "$pmode" in
        pub) want="public" ;;
        sel) want="selective" ;;
        prv) want="private" ;;
        *)   respond "$rid" 404 text/plain - "bad route"; return ;;
    esac
    if [ "$rmode" != "$want" ] && [ "$rmode" != "private" ]; then
        # allow prv links to serve private-mode records
        [ "$pmode" = "prv" ] || { respond "$rid" 403 text/plain - "forbidden"; return; }
    fi

    # selective: token check
    served_name="$fname"
    if [ "$want" = "selective" ]; then
        token="$1"; shift
        [ -n "$token" ] || { respond "$rid" 401 text/plain - "token required"; return; }
        tok_ok=0
        for tf in "$SHARE_DIR/tokens/$cid/"*.token; do
            [ -f "$tf" ] || continue
            stored_token=$(cat "$tf")
            meta="$SHARE_DIR/tokens/$cid/$(basename "$tf" .token).meta"
            expiry=$(awk '$1=="expiry"{print $2}' "$meta" 2>/dev/null)
            maxdl=$(awk '$1=="max_dl"{print $2}' "$meta" 2>/dev/null)
            count=$(awk '$1=="count"{print $2}' "$meta" 2>/dev/null)
            count=${count:-0}
            now=$(date +%s)
            if [ "$stored_token" = "$token" ]; then
                if [ -n "$expiry" ] && [ "$expiry" != "0" ] && [ "$now" -gt "$expiry" ]; then
                    respond "$rid" 410 text/plain - "link expired"; return
                fi
                if [ -n "$maxdl" ] && [ "$maxdl" != "0" ] && [ "$count" -ge "$maxdl" ]; then
                    respond "$rid" 429 text/plain - "download limit reached"; return
                fi
                tok_ok=1
                mkdir -p "$(dirname "$meta")"
                awk -v c=$((count+1)) '$1=="count"{$2=c} {print}' "$meta" > "$meta.new" 2>/dev/null \
                    && mv "$meta.new" "$meta" 2>/dev/null || \
                    printf 'count %s\n' "$((count+1))" > "$meta"
                break
            fi
        done
        [ "$tok_ok" = "0" ] && { respond "$rid" 403 text/plain - "invalid token"; return; }
    fi

    # private shares store <name>.enc; serve ciphertext as-is
    if [ "$rmode" = "private" ] && [ ! -f "$file" ] && [ -f "$file.enc" ]; then
        file="$file.enc"; served_name="$(basename "$file")"
    fi

    if [ ! -f "$file" ]; then
        access_log "$cid" missing 0
        respond "$rid" 404 text/plain - "content vanished"
        return
    fi

    size=$(wc -c < "$file")
    access_log "$cid" served "$size"
    respond "$rid" 200 "$(mime_of "$served_name")" "$file" ""
    log "served $cid ($size bytes)"
}

report_note() { # post diagnostic payload to relay (best effort)
    printf '%s' "$1" > /tmp/.agt-note
    wget -q -T 5 -O /dev/null --post-file=/tmp/.agt-note "$RELAY_URL/note/tunnel-$(node_id)" 2>/dev/null || true
    rm -f /tmp/.agt-note
}

run_loop() {
    NODE=$(node_id)
    ensure_identity_once
    log "tunnel up: node=$NODE relay=$RELAY_URL"
    trap 'log "caught signal — exiting"; report_note "$(tail -30 /tmp/agtunnel.log 2>/dev/null)"; exit 0' INT TERM HUP
    cycle=0

    while true; do
        cycle=$((cycle + 1))
        reqs=$(wget -q -T $((POLL_WAIT + 9)) -O - "$RELAY_URL/poll/$NODE?wait=$POLL_WAIT" 2>/dev/null)
        rc=$?
        if [ $((cycle % 8)) -eq 1 ]; then
            log "heartbeat cycle=$cycle rc=$rc"
            report_note "$(date +%s) cycle=$cycle rc=$rc
$(tail -12 /tmp/agtunnel.log 2>/dev/null)"
        fi
        if [ -n "$reqs" ]; then
            printf '%s\n' "$reqs" | while IFS=' ' read -r kw rid method path; do
                [ "$kw" = "REQ" ] || continue
                handle_request "$rid" "$method" "$path"
            done
        fi
        sleep 0.3
    done
}

ensure_identity_once() {
    [ -f "$IDENTITY_DIR/node.id" ] || /usr/local/bin/gen-identity >/dev/null 2>&1 || true
    # register presence (best effort; poll itself also proves liveness)
    printf '%s' "$(node_id)" > /tmp/.agtunnel-reg
    wget -q -T 5 -O /dev/null --post-file=/tmp/.agtunnel-reg "$RELAY_URL/register" 2>/dev/null || true
    rm -f /tmp/.agtunnel-reg
}

case "$1" in
    start)
        [ -n "$2" ] && RELAY_URL="$2"
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            log "already running (pid $(cat "$PID_FILE"))"
            exit 0
        fi
        (
            exec >/tmp/agtunnel.log 2>&1
            run_loop
        ) &
        echo $! > "$PID_FILE"
        log "started (pid $(cat "$PID_FILE"), relay=$RELAY_URL)"
        ;;
    stop)
        [ -f "$PID_FILE" ] && kill "$(cat "$PID_FILE")" 2>/dev/null && rm -f "$PID_FILE"
        log "stopped"
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
            echo "agtunnel: RUNNING (pid $(cat "$PID_FILE"), relay=$RELAY_URL, node=$(node_id))"
            wget -q -T 3 -O - "$RELAY_URL/who/$(node_id)" 2>/dev/null && echo
        else
            echo "agtunnel: STOPPED"
        fi
        ;;
    run)
        [ -n "$2" ] && RELAY_URL="$2"
        run_loop ;;
    *)
        echo "Usage: agtunnel.sh <start|stop|status|run> [relay_url]"
        ;;
esac
