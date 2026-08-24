#!/bin/sh
# CGI: POST /cgi-bin/app_create.sh
# Body: name=MyApp&url=https://site.com
# Saves a web-app shortcut backed by the device Chromium profile
# (its login session persists across reboots).

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

read -r body
qs="${QUERY_STRING}${body}"
NAME=$(printf '%s' "$qs" | tr '&' '\n' | grep '^name=' | head -1 | cut -d= -f2- | sed 's/+/ /g; s/%20/ /g')
URL=$(printf '%s' "$qs"  | tr '&' '\n' | grep '^url='  | head -1 | cut -d= -f2- | sed 's/%3A/:/g; s/%2F/\//g')

[ -z "$NAME" ] || [ -z "$URL" ] && echo '{"ok":false,"error":"name and url required"}' && exit 0

APPS_DIR="/usr/share/agentic/apps"
mkdir -p "$APPS_DIR"
SLUG=$(printf '%s' "$NAME" | tr -c 'a-zA-Z0-9' '_' | head -c 24)

cat > "$APPS_DIR/$SLUG.json" <<EOF
{"name":"$NAME","url":"$URL","type":"web","created":$(date +%s)}
EOF

echo "{\"ok\":true,\"slug\":\"$SLUG\"}"
