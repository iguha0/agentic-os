#!/bin/sh
# CGI: GET /cgi-bin/apps_list.sh
# User-created web apps (each backed by the persistent browser session)

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

APPS_DIR="/usr/share/agentic/apps"
mkdir -p "$APPS_DIR"

FIRST=1
printf '{"apps":['
for f in "$APPS_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ $FIRST -eq 1 ] || printf ','
    cat "$f"
    FIRST=0
done
printf ']}'
