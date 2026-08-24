#!/bin/sh
# CGI: POST /cgi-bin/share_open.sh
# Body/Query: url=<private share link>
# Fetches + E2E-decrypts into this device's inbox

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

read -r body
qs="${QUERY_STRING}${body}"
URL=$(printf '%s' "$qs" | tr '&' '\n' | grep '^url=' | head -1 | cut -d= -f2- | sed 's/%3A/:/g; s/%2F/\//g; s/+/ /g; s/%20/ /g')

[ -z "$URL" ] && echo '{"ok":false,"error":"url required"}' && exit 0

OUT=$(/usr/local/bin/share-open "$URL" 2>&1)
case "$OUT" in
    OK:*)
        PATH_OUT=$(printf '%s' "$OUT" | head -1 | sed 's/^OK: //')
        ESC=$(printf '%s' "$PATH_OUT" | tr '"' "'")
        echo "{\"ok\":true,\"path\":\"$ESC\"}"
        ;;
    *)
        ESC=$(printf '%s' "$OUT" | tr '"' "'" | tr '\n' ' ')
        echo "{\"ok\":false,\"error\":\"$ESC\"}"
        ;;
esac
