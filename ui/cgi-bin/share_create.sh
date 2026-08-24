#!/bin/sh
# CGI: POST /cgi-bin/share_create.sh
# Body/Query: file=/path&mode=public|selective|private&recipients=a,b&expires=<epoch|0>&maxdl=<n>
# Creates a share via agentic-shared; returns text result

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

read -r body
qs="${QUERY_STRING}${body}"

get() { printf '%s' "$qs" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2- | sed 's/%2F/\//g; s/%20/ /g; s/+/ /g; s/%3A/:/g; s/%2C/,/g; s/%3D/=/g'; }

FILE=$(get file)
MODE=$(get mode)
RECIP=$(get recipients)
EXPIRES=$(get expires)
MAXDL=$(get maxdl)

[ -z "$FILE" ] && echo '{"ok":false,"error":"file required"}' && exit 0
[ -z "$MODE" ] && MODE="public"

[ -f "$FILE" ] || echo '{"ok":false,"error":"file not found on device"}' && [ -f "$FILE" ] || exit 0

OUT=$(/usr/local/bin/agentic-shared share "$FILE" "$MODE" "$RECIP" "$EXPIRES" "$MAXDL" 2>&1 | tail -12)
LINK=$(printf '%s' "$OUT" | grep -o 'http://[^ ]*/f/[^ ]*' | head -1)
CID=$(printf '%s' "$OUT" | grep -o 'CID: [0-9a-f]*' | cut -d' ' -f2)

# JSON-escape output (strip quotes/backslashes crudely)
ESC=$(printf '%s' "$OUT" | tr '"' "'" | tr '\\' '/')
echo "{\"ok\":true,\"link\":\"$LINK\",\"cid\":\"$CID\",\"output\":\"$ESC\"}"
