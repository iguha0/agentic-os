#!/bin/sh
# CGI: GET /cgi-bin/netsearch.sh?q=<query>
# Proxies a query to the AgentoNet DHT index

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

Q=$(printf '%s' "$QUERY_STRING" | sed 's/.*q=\([^&]*\).*/\1/' | sed 's/+/ /g; s/%20/ /g; s/%2B/+/g')
[ -z "$Q" ] && echo '{"results":[],"count":0,"error":"q required"}' && exit 0

QENC=$(printf '%s' "$Q" | sed 's/ /%20/g; s/"/%22/g; s/#/%23/g; s/&/%26/g; s/+/%2B/g; s/?/%3F/g')

DHT="${AGENTOS_DHT:-http://10.0.2.2:8889}"
OUT=$(wget -q -T 6 -O - "$DHT/search?q=$QENC&limit=12" 2>/dev/null)

if [ -n "$OUT" ]; then
    # normalize trailing commas from device-side records
    printf '%s\n' "$OUT" | sed 's/,}]/}]/; s/,]$/]/'
else
    echo '{"results":[],"count":0,"error":"dht unreachable"}'
fi
