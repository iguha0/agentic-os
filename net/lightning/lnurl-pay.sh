#!/bin/sh
# lnurl-pay.sh — Lightning Network micropayment helpers for Agentic OS
#
# This enables creators to receive Bitcoin tips/payments for shared content.
# Works with LNURL-pay protocol (supported by most Lightning wallets).
#
# Usage:
#   lnurl-pay.sh setup <wallet_endpoint>   — configure your Lightning address
#   lnurl-pay.sh invoice <amount_sats> [memo]   — request an invoice
#   lnurl-pay.sh qr <invoice>             — display QR code in terminal
#   lnurl-pay.sh address                  — show your Lightning address
#   lnurl-pay.sh tip-url <cid>            — get a tip URL for content
#   lnurl-pay.sh status                   — show payment config status
#
# LNURL-pay flow:
#   1. Sender fetches lnurl-pay metadata from your endpoint
#   2. Sender specifies amount in millisats
#   3. Your wallet returns a BOLT11 invoice
#   4. Sender pays invoice → you receive sats
#
# Examples of supported wallet endpoints (self-hosted):
#   LNbits:   https://your-lnbits.com/lnurlp/api/v1/lnurl/<id>
#   Alby:     https://getalby.com/lnurlp/<username>
#   Phoenix:  https://api.phoenix.acinq.co/lnurlp/<nodekey>
#   BTCPay:   https://your-btcpay.com/BTC/LNURL/<id>

LIGHTNING_DIR="/usr/share/agentic/lightning"
LIGHTNING_CONFIG="$LIGHTNING_DIR/config.json"
LIGHTNING_LOG="$LIGHTNING_DIR/payments.log"
mkdir -p "$LIGHTNING_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M')] $*" >> "$LIGHTNING_LOG"; }

# ── Setup: save wallet endpoint ────────────────────────────────────────────────
cmd_setup() {
    endpoint="$1"
    [ -z "$endpoint" ] && {
        echo "Usage: lnurl-pay.sh setup <wallet_endpoint>"
        echo ""
        echo "Examples:"
        echo "  lnurl-pay.sh setup https://getalby.com/lnurlp/yourname"
        echo "  lnurl-pay.sh setup https://your-lnbits.com/lnurlp/api/v1/lnurl/abc123"
        echo ""
        echo "For a free Lightning address, sign up at:"
        echo "  https://getalby.com   (free Lightning address)"
        echo "  https://strike.me     (US users)"
        return 1
    }

    cat > "$LIGHTNING_CONFIG" <<EOF
{
  "endpoint":    "$endpoint",
  "node_id":     "$(cat /usr/share/agentic/identity/node.id 2>/dev/null || echo unknown)",
  "setup_ts":    $(date +%s),
  "currency":    "BTC",
  "min_sats":    1,
  "max_sats":    1000000
}
EOF
    echo "[lightning] configured endpoint: $endpoint"
    echo "[lightning] tip URL for your content:"
    cmd_address
}

# ── Show configured address ────────────────────────────────────────────────────
cmd_address() {
    [ -f "$LIGHTNING_CONFIG" ] || {
        echo "[lightning] not configured. Run: lnurl-pay.sh setup <endpoint>"
        return 1
    }
    endpoint=$(grep '"endpoint"' "$LIGHTNING_CONFIG" | sed 's/.*"endpoint": *"\([^"]*\)".*/\1/')
    node_id=$(grep '"node_id"'   "$LIGHTNING_CONFIG" | sed 's/.*"node_id": *"\([^"]*\)".*/\1/')

    # Encode as LNURL (bech32) — show both raw and encoded forms
    echo "Lightning endpoint: $endpoint"
    echo "Node ID:            $node_id"
    echo ""
    echo "Share this link for tips: $endpoint"
    echo ""

    # Generate a simple LNURL (base64url of the endpoint, prefixed)
    # Full bech32 encoding needs a separate tool; we show a QR-friendly URL
    encoded=$(echo -n "$endpoint" | base64 | tr '+/' '-_' | tr -d '=')
    echo "LNURL (base64url): $encoded"
}

# ── Request an invoice from your wallet ───────────────────────────────────────
cmd_invoice() {
    amount_sats="${1:-1000}"
    memo="${2:-Agentic OS tip}"

    [ -f "$LIGHTNING_CONFIG" ] || {
        echo "[lightning] not configured. Run: lnurl-pay.sh setup <endpoint>"
        return 1
    }

    endpoint=$(grep '"endpoint"' "$LIGHTNING_CONFIG" | sed 's/.*"endpoint": *"\([^"]*\)".*/\1/')
    amount_msats=$((amount_sats * 1000))

    echo "[lightning] requesting invoice for ${amount_sats} sats..."

    # Step 1: fetch LNURL-pay metadata
    meta=$(wget -q -O - --timeout=10 "$endpoint" 2>/dev/null)
    if [ -z "$meta" ]; then
        echo "[lightning] could not reach wallet endpoint"
        echo "[lightning] endpoint: $endpoint"
        log "invoice request failed: endpoint unreachable"
        return 1
    fi

    # Extract callback URL from metadata
    callback=$(echo "$meta" | grep -o '"callback":"[^"]*"' | sed 's/.*"callback":"\([^"]*\)".*/\1/')
    if [ -z "$callback" ]; then
        echo "[lightning] endpoint did not return LNURL-pay metadata"
        log "invoice request failed: no callback in metadata"
        return 1
    fi

    # Step 2: request invoice with amount and memo
    memo_enc=$(printf '%s' "$memo" | od -A n -t x1 | tr -d ' \n' | sed 's/../%&/g')
    invoice_resp=$(wget -q -O - --timeout=10 \
        "${callback}?amount=${amount_msats}&comment=${memo_enc}" 2>/dev/null)

    if [ -z "$invoice_resp" ]; then
        echo "[lightning] no response from callback"
        log "invoice request failed: no callback response"
        return 1
    fi

    # Extract BOLT11 invoice
    bolt11=$(echo "$invoice_resp" | grep -o '"pr":"[^"]*"' | sed 's/.*"pr":"\([^"]*\)".*/\1/')
    if [ -z "$bolt11" ]; then
        echo "[lightning] no invoice in response: $invoice_resp"
        return 1
    fi

    echo ""
    echo "BOLT11 Invoice (${amount_sats} sats):"
    echo "$bolt11"
    echo ""
    echo "QR code:"
    cmd_qr "$bolt11"

    # Save to log
    log "invoice created: ${amount_sats} sats, memo='$memo'"
    echo "$bolt11" > "$LIGHTNING_DIR/last_invoice.txt"
    echo "[lightning] invoice saved to $LIGHTNING_DIR/last_invoice.txt"
}

# ── Terminal QR code (text art) ────────────────────────────────────────────────
cmd_qr() {
    data="$1"
    [ -z "$data" ] && data=$(cat "$LIGHTNING_DIR/last_invoice.txt" 2>/dev/null)
    [ -z "$data" ] && { echo "no invoice to display"; return 1; }

    # Use qrencode if available
    if command -v qrencode >/dev/null 2>&1; then
        echo "$data" | qrencode -t UTF8 -o - 2>/dev/null
        return
    fi

    # Use Python if available
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$data" <<'PYEOF'
import sys, urllib.request, urllib.parse

data = sys.argv[1] if len(sys.argv) > 1 else ""
if not data:
    print("no data")
    sys.exit(1)

# Try to use the goqr.me API for QR generation (text-based)
try:
    url = f"https://api.qrserver.com/v1/create-qr-code/?data={urllib.parse.quote(data)}&size=200x200&format=svg"
    print(f"QR URL: {url}")
    print(f"(open this URL to scan the QR code)")
except Exception as e:
    print(f"QR generation failed: {e}")
PYEOF
        return
    fi

    # Fallback: just show the raw data for manual QR generation
    echo "Install qrencode for terminal QR display."
    echo "Or scan this using a QR generator:"
    echo ""
    echo "$data" | head -c 200
    echo ""
}

# ── Generate a tip URL for a piece of content ─────────────────────────────────
cmd_tip_url() {
    cid="$1"
    [ -z "$cid" ] && { echo "Usage: lnurl-pay.sh tip-url <cid>"; return 1; }

    [ -f "$LIGHTNING_CONFIG" ] || {
        echo "[lightning] not configured"
        return 1
    }

    endpoint=$(grep '"endpoint"' "$LIGHTNING_CONFIG" | sed 's/.*"endpoint": *"\([^"]*\)".*/\1/')
    node_id=$(grep '"node_id"'   "$LIGHTNING_CONFIG" | sed 's/.*"node_id": *"\([^"]*\)".*/\1/')

    echo "Tip URL for content $cid:"
    echo "${endpoint}?comment=tip_for_${cid}_by_${node_id}"
    echo ""
    echo "Include this URL alongside your content so others can tip you."
}

cmd_status() {
    echo "=== Lightning Status ==="
    if [ -f "$LIGHTNING_CONFIG" ]; then
        endpoint=$(grep '"endpoint"' "$LIGHTNING_CONFIG" | sed 's/.*"endpoint": *"\([^"]*\)".*/\1/')
        echo "Configured:  yes"
        echo "Endpoint:    $endpoint"
        paid=$(grep "invoice created" "$LIGHTNING_LOG" 2>/dev/null | wc -l || echo 0)
        echo "Invoices:    $paid created"
    else
        echo "Configured:  NO"
        echo "Run: lnurl-pay.sh setup <your_lnurl_endpoint>"
    fi
}

CMD="${1:-status}"
shift 2>/dev/null
case "$CMD" in
    setup)    cmd_setup "$@" ;;
    invoice)  cmd_invoice "$@" ;;
    qr)       cmd_qr "$@" ;;
    address)  cmd_address ;;
    tip-url)  cmd_tip_url "$@" ;;
    status)   cmd_status ;;
    *)
        echo "Usage: lnurl-pay.sh <setup|invoice|qr|address|tip-url|status>"
        ;;
esac
