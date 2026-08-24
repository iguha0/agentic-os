#!/bin/sh
# lnurl-pay.sh — Lightning Network RECEIVE via LNURL-pay (LUD-01/06/16)
#
#   lnurl-pay.sh setup <user@domain | https-lnurl>   configure your address
#   lnurl-pay.sh request <amount_sats> [memo]        get a BOLT11 invoice
#   lnurl-pay.sh tip-url <cid>                       tip line for a share
#   lnurl-pay.sh status                              show config
#
# Flow (receive): your wallet service hosts the LNURLp endpoint. Anyone
# (or any wallet) can then pay you; we only ever TALK to your own provider.
#
# Examples of supported providers:
#   getalby.com · walletofsatoshi.com · strike.me · lnbits (self-host)

LIGHTNING_DIR="${AGENTIC_DIR:-/usr/share/agentic}/lightning"
CONFIG="$LIGHTNING_DIR/config.json"
mkdir -p "$LIGHTNING_DIR"

log() { printf '[lightning] %s\n' "$*"; }
die() { log "ERROR: $*"; exit 1; }

# resolve a lightning address / lnurl to its JSON params URL
params_url() {
    addr="$1"
    case "$addr" in
        *@*)
            user=${addr%%@*}
            domain=${addr#*@}
            echo "https://$domain/.well-known/lnurlp/$user"
            ;;
        https://*|http://*)
            echo "$addr"
            ;;
        *)
            echo ""
            ;;
    esac
}

fetch_json_field() { # <json> <field>
    printf '%s' "$1" | grep -o "\"$2\"[: ]*\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

cmd_setup() {
    addr="$1"
    [ -z "$addr" ] && {
        echo "Usage: lnurl-pay.sh setup <you@provider.com>"
        echo "Providers: getalby.com, walletofsatoshi.com, strike.me, self-hosted lnbits…"
        exit 1
    }
    PURL=$(params_url "$addr")
    [ -z "$PURL" ] && die "cannot parse '$addr'"
    RESP=$(wget -q -T 10 -O - "$PURL" 2>/dev/null) || die "provider unreachable: $PURL"
    STATUS=$(printf '%s' "$RESP" | grep -o '"status":"[A-Z]*"' | cut -d'"' -f4)
    [ "$STATUS" = "OK" ] || die "provider did not return OK status ($PURL)"
    CALLBACK=$(fetch_json_field "$RESP" callback)
    MIN=$(printf '%s' "$RESP" | grep -o '"minSendable":[0-9]*' | cut -d: -f2)
    MAX=$(printf '%s' "$RESP" | grep -o '"maxSendable":[0-9]*' | cut -d: -f2)

    cat > "$CONFIG" <<EOF
{
  "address":   "$addr",
  "params_url":"$PURL",
  "callback":  "$CALLBACK",
  "min_sats":  $(( ${MIN:-1000} / 1000 )),
  "max_sats":  $(( ${MAX:-1000000000} / 1000 )),
  "node_id":   "$(cat /usr/share/agentic/identity/node.id 2>/dev/null || echo unknown)",
  "setup_ts":  $(date +%s)
}
EOF
    log "configured: $addr"
    log "callback:   $CALLBACK"
    log "range:      $(( ${MIN:-1000} / 1000 )) – $(( ${MAX:-1000000000} / 1000 )) sats"
}

cmd_request() {
    AMOUNT_SATS="$1"; MEMO="$2"
    [ -f "$CONFIG" ] || die "not configured — run: lnurl-pay.sh setup you@provider.com"
    [ -z "$AMOUNT_SATS" ] && die "amount in sats required"
    [ "$AMOUNT_SATS" -lt 1 ] 2>/dev/null && die "amount must be >= 1 sat"

    CALLBACK=$(printf '%s' "$(cat "$CONFIG")" | grep -o '"callback"[: ]*"[^"]*"' | head -1 | cut -d'"' -f4)
    [ -z "$CALLBACK" ] && die "config missing callback — rerun setup"

    MSAT=$((AMOUNT_SATS * 1000))
    SEP="?"; case "$CALLBACK" in *\?*) SEP="&";; esac

    RESP=$(wget -q -T 15 -O - "${CALLBACK}${SEP}amount=${MSAT}" 2>/dev/null) \
        || die "invoice request failed (network?)"

    STATUS=$(printf '%s' "$RESP" | grep -o '"status":"[A-Z]*"' | cut -d'"' -f4)
    PR=$(fetch_json_field "$RESP" pr)
    [ -z "$PR" ] && {
        REASON=$(fetch_json_field "$RESP" reason)
        die "invoice refused${REASON:+: $REASON}"
    }

    printf '%s' "$PR" > "$LIGHTNING_DIR/last-invoice.txt"
    {
        echo "$(date +%s) INVOICE ${AMOUNT_SATS}sats memo=${MEMO:-none}"
        echo "$PR"
    } >> "$LIGHTNING_DIR/payments.log"

    log "invoice for ${AMOUNT_SATS} sats ready:"
    cat "$LIGHTNING_DIR/last-invoice.txt"
    echo ""
    log "saved: $LIGHTNING_DIR/last-invoice.txt (paste into any Lightning wallet)"
}

cmd_tipurl() {
    CID="$1"
    ADDR=$(grep -o '"address":"[^"]*"' "$CONFIG" 2>/dev/null | cut -d'"' -f4)
    [ -z "$ADDR" ] && die "not configured — run: lnurl-pay.sh setup you@provider.com"
    [ -z "$CID" ] && die "cid required"
    echo "⚡ Tip this content: zap to $ADDR mentioning cid $CID"
    echo "   (bolt12/tip-page automation lands post-beta)"
}

cmd_status() {
    if [ -f "$CONFIG" ]; then
        echo "address: $(fetch_json_field "$(cat $CONFIG)" address)"
        echo "callback: $(fetch_json_field "$(cat $CONFIG)" callback)"
        [ -f "$LIGHTNING_DIR/last-invoice.txt" ] && {
            echo "last invoice: $(head -c 60 $LIGHTNING_DIR/last-invoice.txt)…"
        }
    else
        echo "not configured — run: lnurl-pay.sh setup you@provider.com"
    fi
}

CMD="${1:-help}"
shift 2>/dev/null
case "$CMD" in
    setup)   cmd_setup "$@" ;;
    request) cmd_request "$@" ;;
    tip-url) cmd_tipurl "$@" ;;
    status)  cmd_status ;;
    *) echo "Usage: lnurl-pay.sh <setup|request|tip-url|status>" ;;
esac
