#!/bin/sh
# CGI: GET /cgi-bin/share_list.sh
# Returns active shares + node identity

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

AGENTIC_DIR="/usr/share/agentic"
INDEX="$AGENTIC_DIR/shares/index.json"
NODE=$(cat "$AGENTIC_DIR/identity/node.id" 2>/dev/null || echo "unknown")

if [ -f "$INDEX" ]; then
    # normalize trailing comma so JSON is valid for browsers
    SHARES=$(sed 's/,}]/}]/; s/,]$/]/' "$INDEX")
else
    SHARES='{"shares":[]}'
fi

TUNNEL="stopped"
[ -f "$AGENTIC_DIR/shares/tunnel.pid" ] && kill -0 "$(cat $AGENTIC_DIR/shares/tunnel.pid)" 2>/dev/null && TUNNEL="running"

echo "{\"node\":\"$NODE\",\"tunnel\":\"$TUNNEL\",\"index\":$SHARES}"
