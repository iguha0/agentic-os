#!/bin/sh
# CGI: POST /cgi-bin/lightning.sh
# Body: cmd=status | cmd=setup&addr=u@d | cmd=request&amount=<sats>&memo=<m>
# Returns JSON; includes svg QR when python3 qrcode is available (graphical).

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

read -r body
qs="${QUERY_STRING}${body}"
get() { printf '%s' "$qs" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2- | sed 's/+/ /g; s/%20/ /g; s/%40/@/g'; }

CMD=$(get cmd)
[ -z "$CMD" ] && CMD="status"

case "$CMD" in
    setup)
        ADDR=$(get addr)
        OUT=$(/usr/local/bin/lnurl-pay setup "$ADDR" 2>&1)
        ;;
    request)
        AMT=$(get amount); MEMO=$(get memo)
        OUT=$(/usr/local/bin/lnurl-pay request "$AMT" "$MEMO" 2>&1)
        INVOICE=""
        if [ -f "/usr/share/agentic/lightning/last-invoice.txt" ]; then
            INVOICE=$(head -c 500 /usr/share/agentic/lightning/last-invoice.txt)
        fi
        SVG=""
        if command -v python3 >/dev/null 2>&1 && python3 -c "import qrcode" 2>/dev/null; then
            SVG=$(python3 - <<PY
import qrcode
q = qrcode.QRCode(border=2)
q.add_data("$INVOICE")
q.make()
import io; b = io.StringIO()
q.print_svg(b)
print(b.getvalue().replace('"', "'").replace(chr(10), ""))
PY
)
        fi
        ESC=$(printf '%s' "$OUT" | tr '"' "'" | tr '\n' ' ')
        ISVG=$(printf '%s' "$SVG" | tr '"' "'")
        echo "{\"ok\":true,\"invoice\":\"$INVOICE\",\"svg\":\"$ISVG\",\"output\":\"$ESC\"}"
        exit 0
        ;;
    *)
        OUT=$(/usr/local/bin/lnurl-pay status 2>&1)
        ;;
esac

ESC=$(printf '%s' "$OUT" | tr '"' "'" | tr '\n' ' ')
echo "{\"ok\":true,\"output\":\"$ESC\"}"
