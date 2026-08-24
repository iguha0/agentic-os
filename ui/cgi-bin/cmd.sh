#!/bin/sh
# CGI: POST /cgi-bin/cmd.sh
# Body: {"cmd":"..."}
# Runs safe whitelisted commands, returns output

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

read -r body
cmd=$(echo "$body" | sed 's/.*"cmd":"\([^"]*\)".*/\1/')

# Whitelist of safe commands
case "$cmd" in
    "status"|"nostr status"|"lightning"|"lightning status")
        OUTPUT=$(eval "$cmd" 2>&1 | head -20) ;;
    reboot)
        sync; reboot; OUTPUT="Rebooting..." ;;
    shutdown|poweroff)
        sync; poweroff; OUTPUT="Shutting down..." ;;
    "nostr flush")
        OUTPUT=$(python3 /usr/local/bin/nostr-ws.py flush 2>&1 | head -10) ;;
    *)
        OUTPUT="Command not allowed: $cmd" ;;
esac

OUT=$(echo "$OUTPUT" | head -c 500 | sed 's/"/\\"/g; s/$/\\n/' | tr -d '\n')
echo "{\"output\":\"${OUT}\"}"
