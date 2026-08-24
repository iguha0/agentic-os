#!/bin/sh
# CGI: GET /cgi-bin/status.sh
# Returns system status JSON

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

AGENTIC_DIR="/usr/share/agentic"
LLAMA_PORT="${LLAMA_PORT:-8080}"

# Self-sufficient: check on-device first
LLM_ONLINE=false
LLM_MODE="none"
if wget -q -O /dev/null --timeout=2 "http://127.0.0.1:${LLAMA_PORT}/health" 2>/dev/null; then
    LLAMA_HOST="127.0.0.1"
    LLM_ONLINE=true
    LLM_MODE="on-device"
elif wget -q -O /dev/null --timeout=2 "http://10.0.2.2:${LLAMA_PORT}/health" 2>/dev/null; then
    LLAMA_HOST="10.0.2.2"
    LLM_ONLINE=true
    LLM_MODE="host-fallback"
fi

NODE_ID=$(cat "$AGENTIC_DIR/identity/node.id" 2>/dev/null || echo "unknown")
USERNAME=$(grep '"name"' "$AGENTIC_DIR/profile.json" 2>/dev/null | sed 's/.*"name": *"\([^"]*\)".*/\1/' | head -1)
[ -z "$USERNAME" ] && USERNAME="user"

MEM_BYTES=$(stat -c %s "$AGENTIC_DIR/memory.txt"     2>/dev/null || echo 0)
LOG_LINES=$(wc -l < "$AGENTIC_DIR/learning/interactions.jsonl" 2>/dev/null || echo 0)
NOTES_COUNT=$(wc -l < "$AGENTIC_DIR/notes.txt" 2>/dev/null || echo 0)

UPTIME=$(cat /proc/uptime 2>/dev/null | cut -d. -f1 || echo 0)
UPTIME_H=$(( UPTIME / 3600 ))
UPTIME_M=$(( (UPTIME % 3600) / 60 ))

cat <<EOF
{
  "llm_online":     $LLM_ONLINE,
  "llm_mode":       "$LLM_MODE",
  "llm_host":       "${LLAMA_HOST}:${LLAMA_PORT}",
  "model":          "Qwen2.5 1.5B Instruct",
  "node_id":        "$NODE_ID",
  "username":       "$USERNAME",
  "memory_bytes":   $MEM_BYTES,
  "interactions":   $LOG_LINES,
  "notes":          $NOTES_COUNT,
  "uptime":         "${UPTIME_H}h ${UPTIME_M}m",
  "version":        "0.2.0"
}
EOF
