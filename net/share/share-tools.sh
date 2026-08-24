#!/bin/sh
# share-tools.sh — natural language → agentic-shared commands
#
# This is the bridge between the AI agent and the sharing daemon.
# The AI calls these functions when it detects sharing intent.
#
# Called from shell/ai_client.c tool_dispatch() when the AI emits:
#   [TOOL:share file=/path/to/file mode=public]
#   [TOOL:share file=/path/to/file mode=selective recipients=rahul,priya]
#   [TOOL:share file=/path/to/file mode=private recipient_key=<pubkey>]
#   [TOOL:unshare cid=<cid> recipient=<name>]
#   [TOOL:shares_list]
#   [TOOL:share_log cid=<cid>]

SHARED_BIN="/usr/local/bin/agentic-shared"
[ -x "$SHARED_BIN" ] || SHARED_BIN="/usr/share/agentic/tools/agentic-shared.sh"

# Ensure daemon is running before any share operation
ensure_daemon() {
    "$SHARED_BIN" status | grep -q "RUNNING" || "$SHARED_BIN" start
}

# ── Tool: share ───────────────────────────────────────────────────────────────
# Parse [TOOL:share key=val ...] and execute

tool_share() {
    # Args come in as key=value pairs
    file=""; mode="public"; recipients=""; recipient_key=""
    for arg in "$@"; do
        case "$arg" in
            file=*)       file="${arg#file=}" ;;
            mode=*)       mode="${arg#mode=}" ;;
            recipients=*) recipients="${arg#recipients=}" ;;
            recipient_key=*) recipient_key="${arg#recipient_key=}" ;;
        esac
    done

    [ -n "$file" ]    || { echo "share: file required"; return 1; }
    [ -f "$file" ]    || { echo "share: file not found: $file"; return 1; }

    ensure_daemon

    case "$mode" in
        public)
            "$SHARED_BIN" share "$file" public
            ;;
        selective|select)
            [ -n "$recipients" ] || { echo "share: recipients required for selective mode"; return 1; }
            "$SHARED_BIN" share "$file" selective "$recipients"
            ;;
        private)
            echo "Private (E2E encrypted) sharing coming in Phase 2."
            echo "For now, use selective mode with a password-protected link."
            ;;
        *)
            echo "Unknown share mode: $mode"
            echo "Use: public | selective | private"
            return 1
            ;;
    esac
}

# ── Tool: unshare ─────────────────────────────────────────────────────────────

tool_unshare() {
    cid=""; recipient=""
    for arg in "$@"; do
        case "$arg" in
            cid=*)       cid="${arg#cid=}" ;;
            recipient=*) recipient="${arg#recipient=}" ;;
        esac
    done

    [ -n "$cid" ] || { echo "unshare: cid required"; return 1; }
    ensure_daemon
    "$SHARED_BIN" revoke "$cid" "$recipient"
}

# ── Tool: shares_list ─────────────────────────────────────────────────────────

tool_shares_list() {
    ensure_daemon
    "$SHARED_BIN" list
}

# ── Tool: share_log ───────────────────────────────────────────────────────────

tool_share_log() {
    cid=""
    for arg in "$@"; do
        case "$arg" in
            cid=*) cid="${arg#cid=}" ;;
        esac
    done
    ensure_daemon
    "$SHARED_BIN" log "$cid"
}

# ── Natural language intent classifier ───────────────────────────────────────
# Used by the AI agent to decide whether a query is a share request.
# Returns 0 (yes) or 1 (no).

is_share_intent() {
    input="$1"
    echo "$input" | grep -iqE \
        "share|send (this|the|my)|give access|make (this|it) public|let .* see|show .* to|distribute" \
        && return 0 || return 1
}

# ── Example AI system prompt additions ───────────────────────────────────────
# These strings are injected into the AI system prompt so the model knows
# when and how to call the share tools.

SHARE_SYSTEM_PROMPT='
You have access to a file sharing system. When the user wants to share a file, use:

[TOOL:share file=<absolute_path> mode=<public|selective|private> recipients=<name1,name2>]

Examples:
  User: "share my photo with everyone"
  → [TOOL:share file=/home/user/photo.jpg mode=public]

  User: "share this doc only with Rahul and Priya"
  → [TOOL:share file=/tmp/doc.pdf mode=selective recipients=rahul,priya]

  User: "stop sharing my Goa photos with Rahul"
  → First call [TOOL:shares_list] to find the CID, then
  → [TOOL:unshare cid=<cid> recipient=rahul]

  User: "who accessed my shared files?"
  → [TOOL:shares_list] followed by [TOOL:share_log cid=<cid>]

  User: "take down everything I shared publicly"
  → [TOOL:shares_list] then [TOOL:unshare cid=<cid>] for each public share

Always confirm with the user before making a file public. Selective and private
sharing is fine to proceed without confirmation since it is access-controlled.
'

# ── Entrypoint (for testing) ──────────────────────────────────────────────────

if [ "${1:-}" = "test" ]; then
    echo "Testing share tools..."
    echo "Creating test file..."
    echo "Hello from Agentic OS" > /tmp/test-share.txt
    tool_share "file=/tmp/test-share.txt" "mode=public"
    echo ""
    tool_share "file=/tmp/test-share.txt" "mode=selective" "recipients=alice,bob"
    echo ""
    tool_shares_list
fi

# Export tools for agent dispatch
export -f tool_share 2>/dev/null || true
export -f tool_unshare 2>/dev/null || true
export -f tool_shares_list 2>/dev/null || true
export -f tool_share_log 2>/dev/null || true
