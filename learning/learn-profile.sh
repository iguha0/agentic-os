#!/bin/sh
# learn-profile.sh — nightly profile extractor + learning processor
#
# Runs in background (called from init or scheduled).
# Reads interactions.jsonl and:
#   1. Extracts user facts → stores in memory.txt
#   2. Builds/updates profile.json
#   3. Identifies preferred patterns (short answers, language, tone)
#   4. Prunes old interactions to keep log manageable
#
# This is the foundation of Layer 1 personalization.

AGENTIC_DIR="/usr/share/agentic"
LEARN_DIR="$AGENTIC_DIR/learning"
MEMORY_FILE="$AGENTIC_DIR/memory.txt"
PROFILE_FILE="$AGENTIC_DIR/profile.json"
INTERACTIONS="$LEARN_DIR/interactions.jsonl"
PREFS_FILE="$LEARN_DIR/preferences.json"
FACTS_FILE="$LEARN_DIR/extracted_facts.txt"
LOG="$LEARN_DIR/learn.log"

mkdir -p "$LEARN_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M')] $*" >> "$LOG"; }

[ -f "$INTERACTIONS" ] || { log "no interactions yet"; exit 0; }

TOTAL=$(wc -l < "$INTERACTIONS")
log "processing $TOTAL interactions..."

# ── Extract facts from conversation ──────────────────────────────────────────
# Look for patterns in queries that reveal user facts

extract_facts() {
    tmp=$(mktemp)

    grep '"q":' "$INTERACTIONS" | while IFS= read -r line; do
        # Extract query text
        q=$(echo "$line" | sed 's/.*"q":"\([^"]*\)".*/\1/')

        # "my name is X"
        echo "$q" | grep -iq "my name is " && \
            name=$(echo "$q" | sed -i 's/.*my name is \([a-zA-Z]*\).*/\1/') && \
            echo "user_name=$name" >> "$tmp"

        # "I am from X" / "I live in X"
        echo "$q" | grep -iq "i.*live in\|i.*from\|i am from" && \
            city=$(echo "$q" | sed 's/.*\(live in\|from\) \([A-Za-z ]*\).*/\2/' | head -c 32) && \
            [ -n "$city" ] && echo "user_city=$city" >> "$tmp"

        # "my team" / "my colleague" mentions
        echo "$q" | grep -iq "my colleague\|my team\|my coworker" && \
            echo "has_team=true" >> "$tmp"

        # Language detection: Hindi/regional words
        echo "$q" | grep -iqE "bhai|yaar|kya|karo|theek|haan|nahi|matlab" && \
            echo "preferred_language=hindi-english-mix" >> "$tmp"

        # Preference: short vs long answers (based on query length)
        qlen=$(echo "$q" | wc -c)
        [ "$qlen" -lt 30 ] && echo "prefers_short_queries=true" >> "$tmp"
    done

    # Deduplicate and save facts
    sort -u "$tmp" >> "$FACTS_FILE"
    rm -f "$tmp"
}

# ── Count tool usage patterns ─────────────────────────────────────────────────
count_tool_usage() {
    weather_count=$(grep -c '"q":".*weather' "$INTERACTIONS" 2>/dev/null || echo 0)
    note_count=$(grep -c '"q":".*note' "$INTERACTIONS" 2>/dev/null || echo 0)
    search_count=$(grep -c '"q":".*search' "$INTERACTIONS" 2>/dev/null || echo 0)
    share_count=$(grep -c '"q":".*share' "$INTERACTIONS" 2>/dev/null || echo 0)

    cat > "$PREFS_FILE" <<EOF
{
  "tool_usage": {
    "weather": $weather_count,
    "notes":   $note_count,
    "search":  $search_count,
    "share":   $share_count
  },
  "total_interactions": $TOTAL,
  "updated": $(date +%s)
}
EOF
    log "tool usage: weather=$weather_count notes=$note_count search=$search_count share=$share_count"
}

# ── Promote extracted facts to memory ─────────────────────────────────────────
promote_facts() {
    [ -f "$FACTS_FILE" ] || return

    sort -u "$FACTS_FILE" | while IFS= read -r fact; do
        key=$(echo "$fact" | cut -d= -f1)
        value=$(echo "$fact" | cut -d= -f2-)
        [ -n "$key" ] && [ -n "$value" ] || continue

        # Only write if not already in memory
        grep -q "^$key=" "$MEMORY_FILE" 2>/dev/null || \
            echo "$key=$value" >> "$MEMORY_FILE"
    done
    log "facts promoted to memory"
}

# ── Identify peak usage hours ─────────────────────────────────────────────────
usage_pattern() {
    # Extract hours from timestamps
    grep '"ts":' "$INTERACTIONS" | \
        sed 's/.*"ts":\([0-9]*\).*/\1/' | \
        while read ts; do
            hour=$(date -d "@$ts" "+%H" 2>/dev/null || \
                   awk "BEGIN{print int($ts % 86400 / 3600)}")
            echo "$hour"
        done | sort | uniq -c | sort -rn | head -3 | \
        while read count hour; do
            echo "peak_hour_$hour=$count"
        done >> "$FACTS_FILE"
}

# ── Prune old interactions (keep last 1000) ────────────────────────────────────
prune_interactions() {
    lines=$(wc -l < "$INTERACTIONS")
    if [ "$lines" -gt 1000 ]; then
        tmp=$(mktemp)
        tail -n 1000 "$INTERACTIONS" > "$tmp"
        mv "$tmp" "$INTERACTIONS"
        log "pruned to 1000 interactions (was $lines)"
    fi
}

# ── Update profile.json ───────────────────────────────────────────────────────
update_profile() {
    # Read existing name
    existing_name=$(grep '"name"' "$PROFILE_FILE" 2>/dev/null \
        | sed 's/.*"name": *"\([^"]*\)".*/\1/' | head -1)

    # Read extracted facts
    city=$(grep "^user_city=" "$FACTS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
    lang=$(grep "^preferred_language=" "$FACTS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)
    has_team=$(grep "^has_team=" "$FACTS_FILE" 2>/dev/null | tail -1 | cut -d= -f2)

    cat > "$PROFILE_FILE" <<EOF
{
  "name":        "${existing_name:-user}",
  "city":        "${city:-}",
  "language":    "${lang:-en}",
  "has_team":    ${has_team:-false},
  "interactions": $TOTAL,
  "updated":     $(date +%s)
}
EOF
    log "profile updated"
}

# ── Run all steps ─────────────────────────────────────────────────────────────
log "=== nightly learning pass ==="
extract_facts
count_tool_usage
usage_pattern
promote_facts
update_profile
prune_interactions
log "=== done ==="

echo "[learn] profile updated. Facts extracted: $(wc -l < "$FACTS_FILE" 2>/dev/null || echo 0)"
