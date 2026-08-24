#!/bin/sh
# shortcuts.sh — web app shortcuts for Agentic OS
#
# Think of these as "app icons" for the terminal: named bookmarks that
# open a URL in a terminal browser. No app store required.
#
# Usage:
#   shortcuts.sh add <name> <url> [description]   — save a web app
#   shortcuts.sh open <name>                       — launch it
#   shortcuts.sh list                              — show all shortcuts
#   shortcuts.sh remove <name>                     — delete a shortcut
#   shortcuts.sh search <query>                    — find a shortcut
#   shortcuts.sh suggest <query>                   — ask AI to find the right app URL
#
# Built-in popular apps (no setup needed):
#   open youtube, open netflix, open gmail, open maps, open spotify, ...

SHORTCUTS_FILE="/usr/share/agentic/apps/shortcuts.json"
SHORTCUTS_DIR="/usr/share/agentic/apps"
mkdir -p "$SHORTCUTS_DIR"

# Initialize shortcuts file if it doesn't exist
init_shortcuts() {
    [ -f "$SHORTCUTS_FILE" ] && return
    cat > "$SHORTCUTS_FILE" <<'EOF'
{
  "apps": {
    "youtube":    {"url": "https://m.youtube.com",        "desc": "YouTube videos",          "icon": "▶"},
    "netflix":    {"url": "https://www.netflix.com",      "desc": "Netflix streaming",       "icon": "N"},
    "gmail":      {"url": "https://mail.google.com",      "desc": "Gmail email",             "icon": "✉"},
    "maps":       {"url": "https://maps.google.com",      "desc": "Google Maps",             "icon": "📍"},
    "spotify":    {"url": "https://open.spotify.com",     "desc": "Spotify music",           "icon": "♪"},
    "reddit":     {"url": "https://old.reddit.com",       "desc": "Reddit (classic)",        "icon": "🔴"},
    "twitter":    {"url": "https://mobile.twitter.com",   "desc": "Twitter / X",            "icon": "🐦"},
    "github":     {"url": "https://github.com",           "desc": "GitHub code",             "icon": "⚙"},
    "wikipedia":  {"url": "https://en.m.wikipedia.org",   "desc": "Wikipedia",              "icon": "W"},
    "news":       {"url": "https://news.google.com",      "desc": "Google News",             "icon": "📰"},
    "weather":    {"url": "https://wttr.in",              "desc": "Terminal weather",        "icon": "☁"},
    "translate":  {"url": "https://translate.google.com", "desc": "Google Translate",        "icon": "🌐"},
    "calendar":   {"url": "https://calendar.google.com",  "desc": "Google Calendar",         "icon": "📅"},
    "drive":      {"url": "https://drive.google.com",     "desc": "Google Drive",            "icon": "💾"},
    "meet":       {"url": "https://meet.google.com",      "desc": "Google Meet video",       "icon": "📹"},
    "whatsapp":   {"url": "https://web.whatsapp.com",     "desc": "WhatsApp Web",            "icon": "💬"},
    "telegram":   {"url": "https://web.telegram.org",     "desc": "Telegram Web",            "icon": "✈"},
    "amazon":     {"url": "https://www.amazon.com",       "desc": "Amazon shopping",         "icon": "🛒"},
    "flipkart":   {"url": "https://www.flipkart.com",     "desc": "Flipkart shopping",       "icon": "🛒"},
    "paytm":      {"url": "https://paytm.com",            "desc": "Paytm payments",          "icon": "💳"},
    "upi":        {"url": "https://www.bhimupi.org.in",   "desc": "BHIM UPI",               "icon": "💳"},
    "irctc":      {"url": "https://m.irctc.co.in",        "desc": "IRCTC train tickets",     "icon": "🚂"},
    "zomato":     {"url": "https://www.zomato.com",       "desc": "Zomato food delivery",    "icon": "🍔"},
    "swiggy":     {"url": "https://www.swiggy.com",       "desc": "Swiggy food delivery",    "icon": "🍔"}
  }
}
EOF
}

# ── Detect best available terminal browser ────────────────────────────────────
detect_browser() {
    # agbrowser is our built-in browser — always prefer it
    for b in agbrowser w3m lynx links elinks; do
        command -v "$b" >/dev/null 2>&1 && echo "$b" && return
    done
    echo "wget"
}

open_url() {
    url="$1"
    name="$2"

    # In graphical mode with Chromium available, prefer real Chromium (controlled by agent via CDP)
    if [ -n "$DISPLAY" ] && [ -x /usr/local/bin/browser-ctl ]; then
        echo "[apps] opening $name in graphical Chromium (via agent ctl)..."
        /usr/local/bin/browser-ctl navigate "$url" || chromium --new-window "$url" &
        return
    fi

    browser=$(detect_browser)

    case "$browser" in
        agbrowser)
            echo "[apps] opening $name..."
            agbrowser "$url"
            ;;
        w3m)
            echo "[apps] opening $name with w3m..."
            w3m "$url"
            ;;
        lynx)
            echo "[apps] opening $name with lynx..."
            lynx -display_charset=utf-8 "$url"
            ;;
        links)
            links "$url" ;;
        elinks)
            elinks "$url" ;;
        wget)
            # Last-resort text dump
            echo "[apps] fetching $name (text only)..."
            wget -q -O - --timeout=15 \
                --user-agent="Agentic/1.0" \
                "$url" 2>/dev/null \
                | sed 's/<[^>]*>//g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g' \
                | grep -v '^[[:space:]]*$' \
                | head -80
            ;;
    esac
}

# ── Get a field from the JSON shortcuts file (lightweight jq-free parser) ────
json_get_app_field() {
    name="$1"
    field="$2"
    # Extract the block for the app name, then get the field
    awk -v app="\"$name\"" -v fld="\"$field\"" '
        $0 ~ app":" { found=1 }
        found && $0 ~ fld":" {
            gsub(/.*"'"$field"'": *"/, "")
            gsub(/".*/, "")
            print
            exit
        }
    ' "$SHORTCUTS_FILE"
}

list_apps() {
    init_shortcuts
    echo ""
    echo "  ─── Web App Shortcuts ───────────────────────────────────────────"
    echo ""
    # Parse all app names from the JSON
    grep '"[a-z]"' "$SHORTCUTS_FILE" 2>/dev/null | head -1 >/dev/null  # warmup

    # Extract name, icon, url, desc lines
    awk '
        /"[a-z]/ && /": {/ {
            name = $0
            gsub(/.*"/, "", name)
            gsub(/".*/, "", name)
            getline; icon=$0; gsub(/.*"icon": *"/, "", icon); gsub(/".*/, "", icon)
            getline; desc=$0; gsub(/.*"desc": *"/, "", desc); gsub(/".*/, "", desc)
            getline; url=$0; gsub(/.*"url": *"/, "", url); gsub(/".*/, "", url)
            printf "  %-14s %s  %-30s  %s\n", name, icon, desc, url
        }
    ' "$SHORTCUTS_FILE" 2>/dev/null || \
    grep -o '"[^"]*":.*{' "$SHORTCUTS_FILE" | sed 's/"//g; s/: {//'

    echo ""
    echo "  Use: open <app-name>  or  shortcuts.sh add <name> <url>"
    echo ""
}

cmd_open() {
    name=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    init_shortcuts

    # Look up in shortcuts file
    url=$(awk -v app="\"$name\"" '
        $0 ~ app":" { found=1 }
        found && /"url"/ {
            gsub(/.*"url": *"/, "")
            gsub(/".*/, "")
            print
            exit
        }
    ' "$SHORTCUTS_FILE" 2>/dev/null)

    if [ -z "$url" ]; then
        # Fuzzy match: try prefix
        url=$(awk -v app="$name" '
            $0 ~ "\"" app {
                sub(/.*"/, "")
                sub(/".*/, "")
                nm=$0
            }
            nm && /"url"/ {
                gsub(/.*"url": *"/, "")
                gsub(/".*/, "")
                print
                exit
            }
        ' "$SHORTCUTS_FILE" 2>/dev/null)
    fi

    if [ -z "$url" ]; then
        echo "[apps] '$name' not found."
        echo "[apps] run: shortcuts.sh list  to see all apps"
        echo "[apps] or:  shortcuts.sh add $name <url>  to add it"
        return 1
    fi

    open_url "$url" "$name"
}

cmd_add() {
    name=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    url="$2"
    desc="${3:-custom app}"

    [ -z "$name" ] && { echo "usage: shortcuts.sh add <name> <url> [desc]" >&2; exit 1; }
    [ -z "$url" ]  && { echo "usage: shortcuts.sh add <name> <url> [desc]" >&2; exit 1; }

    init_shortcuts
    tmp=$(mktemp)

    # Insert new app into the JSON (before closing brace of "apps")
    awk -v n="$name" -v u="$url" -v d="$desc" '
        /"apps"/ { in_apps=1 }
        in_apps && /^  }$/ {
            printf "    \"%s\": {\"url\": \"%s\", \"desc\": \"%s\", \"icon\": \"★\"},\n", n, u, d
        }
        { print }
    ' "$SHORTCUTS_FILE" > "$tmp" && mv "$tmp" "$SHORTCUTS_FILE"

    echo "[apps] added: $name → $url"
}

cmd_remove() {
    name=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    init_shortcuts
    tmp=$(mktemp)
    awk -v n="\"$name\"" '$0 ~ n":"{skip=1} skip && /},/{skip=0; next} !skip{print}' \
        "$SHORTCUTS_FILE" > "$tmp" && mv "$tmp" "$SHORTCUTS_FILE"
    echo "[apps] removed: $name"
}

cmd_search() {
    query=$(echo "$*" | tr '[:upper:]' '[:lower:]')
    init_shortcuts
    echo "[apps] searching for: $query"
    grep -i "$query" "$SHORTCUTS_FILE" | grep '"url"\|"desc"' | \
        sed 's/.*"url": *"//; s/".*//' | head -10
}

CMD="${1:-list}"
shift 2>/dev/null
case "$CMD" in
    add)     cmd_add "$@" ;;
    open)    cmd_open "$@" ;;
    list)    list_apps ;;
    remove|rm|delete) cmd_remove "$@" ;;
    search)  cmd_search "$@" ;;
    *)       list_apps ;;
esac
