#!/bin/sh
# CGI: POST /cgi-bin/ai.sh
# Body: {"message":"...", "history":[...]}
# Returns: {"reply":"..."}

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

# Read POST body
read -r body

# Extract message (simple JSON parser)
message=$(echo "$body" | sed 's/.*"message":"\([^"]*\)".*/\1/' | head -c 2000)
[ -z "$message" ] && echo '{"error":"no message"}' && exit 0

# Basic internet search support for the chat UI
SEARCH_RESULTS=""
if echo "$message" | grep -qiE 'search|flight|weather|kolkata|delhi|price|book|ticket'; then
    Q=$(echo "$message" | sed -E 's/.*(search|flight|weather|from|to) *([^.?!]*).*/\2/i' | tr ' ' '+' | head -c 100)
    [ -z "$Q" ] && Q=$(echo "$message" | tr ' ' '+' | head -c 80)
    if [ -n "$Q" ]; then
        SEARCH_RESULTS=$(curl -s --max-time 5 "https://html.duckduckgo.com/html/?q=$Q" 2>/dev/null | grep -o '<a[^>]*>[^<]*</a>' | head -5 | sed 's/<[^>]*>//g' | tr '\n' ' ' || echo "search failed")
        if [ -n "$SEARCH_RESULTS" ]; then
            SEARCH_RESULTS=" [Web search results for your query: $SEARCH_RESULTS]"
            message="$message$SEARCH_RESULTS"
        fi
    fi
fi

# Build conversation history for llama-server
# Extract history array (last few turns)
history_msgs=""
echo "$body" | grep -q '"history"' && {
    # Parse history turns from JSON array
    history_json=$(echo "$body" | sed 's/.*"history":\(\[.*\]\)}.*/\1/')
    # We'll just pass the raw history to build_prompt below
}

# Read system context (memory, profile, notes)
AGENTIC_DIR="/usr/share/agentic"
MEMORY=""
PROFILE=""
NOTES=""
[ -f "$AGENTIC_DIR/memory.txt" ]           && MEMORY=$(head -20 "$AGENTIC_DIR/memory.txt" | head -c 800)
[ -f "$AGENTIC_DIR/profile.json" ]         && PROFILE=$(cat "$AGENTIC_DIR/profile.json" 2>/dev/null | head -c 300)
[ -f "$AGENTIC_DIR/notes.txt" ]            && NOTES=$(tail -5 "$AGENTIC_DIR/notes.txt" | head -c 400)

NODE_ID=$(cat "$AGENTIC_DIR/identity/node.id" 2>/dev/null || echo "unknown")

# Build system prompt
SYSTEM="You are an AI assistant running locally on Agentic OS (a custom Linux OS).
Node ID: $NODE_ID
You are a local AI on Agentic OS. You have no direct internet access. For real-time info like flights or search, tell the user to use the terminal shell with 'search <query>' or similar. You can help with local memory, notes, weather (via tool if in shell), and general questions. Be concise.
Be concise and helpful. This is a mobile-like interface so keep responses readable.
$([ -n "$MEMORY" ] && echo "\nMemory:\n$MEMORY")
$([ -n "$PROFILE" ] && echo "\nUser profile:\n$PROFILE")
$([ -n "$NOTES" ] && echo "\nRecent notes:\n$NOTES")"

# Escape for JSON
esc_system=$(echo "$SYSTEM"   | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n')
esc_message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')

# Build messages array
MESSAGES="[{\"role\":\"system\",\"content\":\"${esc_system}\"},{\"role\":\"user\",\"content\":\"${esc_message}\"}]"

# POST to llama-server
# Self-sufficient: try on-device llama-server first, fall back to host
LLAMA_PORT="${LLAMA_PORT:-8080}"
if wget -q -O /dev/null --timeout=2 "http://127.0.0.1:${LLAMA_PORT}/health" 2>/dev/null; then
    LLAMA_HOST="127.0.0.1"
else
    LLAMA_HOST="${LLAMA_HOST:-10.0.2.2}"  # QEMU dev fallback only
fi

PAYLOAD="{\"model\":\"qwen2.5\",\"messages\":${MESSAGES},\"max_tokens\":128,\"temperature\":0.7,\"stream\":false}"

RESPONSE=$(wget -q -O - \
    --post-data="$PAYLOAD" \
    --header="Content-Type: application/json" \
    --timeout=300 \
    "http://${LLAMA_HOST}:${LLAMA_PORT}/v1/chat/completions" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
    echo '{"error":"AI offline — llama-server not reachable on port 8080","reply":"AI engine is offline. Verify that the Qwen model disk is attached and then restart Agentic OS."}'
    exit 0
fi

# Extract reply content from JSON
reply=$(echo "$RESPONSE" | grep -o '"content":"[^"]*"' | head -1 | sed 's/"content":"//; s/"$//')

# Unescape
reply=$(printf '%s' "$reply" | sed 's/\\n/\n/g; s/\\t/\t/g; s/\\"/"/g; s/\\\\/\\/g')

# Escape for output JSON
out=$(printf '%s' "$reply" | sed 's/\\/\\\\/g; s/"/\\"/g; s/$/\\n/' | tr -d '\n')

echo "{\"reply\":\"${out}\"}"

# Log interaction
TS=$(date +%s)
printf '{"ts":%s,"q":"%s","a":"%s"}\n' \
    "$TS" \
    "$(echo "$message" | head -c 100 | sed 's/"/\\"/g')" \
    "$(echo "$reply" | head -c 100 | sed 's/"/\\"/g')" \
    >> "$AGENTIC_DIR/learning/interactions.jsonl" 2>/dev/null
