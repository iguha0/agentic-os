#!/bin/sh
# CGI: POST /cgi-bin/share_revoke.sh
# Body/Query: cid=<cid>&recipient=<optional>

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

read -r body
qs="${QUERY_STRING}${body}"

get() { printf '%s' "$qs" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2- | sed 's/%2F/\//g; s/%20/ /g; s/+/ /g'; }

CID=$(get cid)
RECIP=$(get recipient)

[ -z "$CID" ] && echo '{"ok":false,"error":"cid required"}' && exit 0

if [ -n "$RECIP" ]; then
    OUT=$(/usr/local/bin/agentic-shared revoke "$CID" "$RECIP" 2>&1)
else
    OUT=$(/usr/local/bin/agentic-shared revoke "$CID" 2>&1)
fi

ESC=$(printf '%s' "$OUT" | tr '"' "'" | tr '\\' '/')
echo "{\"ok\":true,\"output\":\"$ESC\"}"
