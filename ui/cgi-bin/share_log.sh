#!/bin/sh
# CGI: GET /cgi-bin/share_log.sh?cid=<cid>
# Returns the access log for a share

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

AGENTIC_DIR="/usr/share/agentic"
CID=$(printf '%s' "$QUERY_STRING" | sed 's/.*cid=\([^&]*\).*/\1/' | sed 's/%2F/\//g; s/+/ /g')
[ -z "$CID" ] && echo '{"entries":[],"count":0,"error":"cid required"}' && exit 0

LOG="$AGENTIC_DIR/shares/logs/$CID.log"
COUNT=0
ENTRIES=""
if [ -f "$LOG" ]; then
    COUNT=$(wc -l < "$LOG")
    # last 20 entries: "ts result bytes"
    ENTRIES=$(tail -20 "$LOG" | tr '"' "'" | tr '\n' '|' | sed 's/|$//')
fi

echo "{\"cid\":\"$CID\",\"count\":$COUNT,\"entries\":\"$ENTRIES\"}"
