#!/bin/sh
# credentials.sh — Secure credential storage for Agentic OS
#
# Stores and retrieves credentials (passwords, tokens, session cookies).
# Credentials can be:
#   - Encrypted (AES-256 via e2e-encrypt.sh), or
#   - Plain text (for dev/testing only)
#
# Usage:
#   credential_set <name> <value>                    # store a credential
#   credential_get <name>                             # retrieve (prints to stdout)
#   credential_list                                    # show all credential names
#   credential_delete <name>                           # remove
#   credential_export                                  # dump all (for backup)
#   credential_import <file>                           # restore from backup
#
# The agent calls: credential_get github_user  -> gets the username, then
#   browser_ctl type selector credential=github_user
# (the agent substitutes the value before sending to browser-ctl)
#
# Security model:
#   - Credentials are never exposed to the LLM in plain text
#   - The shell resolves credential references before passing to browser-ctl
#   - Only the agentic-shell process (not the LLM) reads the actual values

set -e

CREDENTIALS_DIR="${CREDENTIALS_DIR:-/usr/share/agentic/credentials}"
ENCRYPTED="${AGENTIC_CREDENTIALS_ENCRYPTED:-1}"  # default to encrypted if e2e is available
ENC_SCRIPT="${AGENTIC_DIR:-/usr/share/agentic}/e2e-encrypt.sh"

mkdir -p "$CREDENTIALS_DIR"

# ── Encryption check ──────────────────────────────────────────────────────────
can_encrypt() {
    [ -f "$ENC_SCRIPT" ] && [ -x "$ENC_SCRIPT" ] && "$ENC_SCRIPT" check 2>/dev/null
}

# ── Core operations ───────────────────────────────────────────────────────────

credential_set() {
    local name="$1" value="$2"
    if [ -z "$name" ] || [ -z "$value" ]; then
        echo "usage: credential_set <name> <value>" >&2
        return 1
    fi
    # Sanitize name: lowercase, alphanumeric + underscore only
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')

    local cred_file="$CREDENTIALS_DIR/${name}.cred"

    if [ "$ENCRYPTED" = "1" ] && can_encrypt; then
        # Encrypt the value
        echo "$value" | "$ENC_SCRIPT" encrypt > "$cred_file" 2>/dev/null || {
            echo "WARN: encryption failed, storing in plain text" >&2
            echo "$value" > "$cred_file"
        }
    else
        # Plain text storage (only if encryption not available/desired)
        echo "$value" > "$cred_file"
    fi
    chmod 600 "$cred_file"
    echo "OK: stored credential '$name'"
}

credential_get() {
    local name="$1"
    if [ -z "$name" ]; then
        echo ""; return 1
    fi
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
    local cred_file="$CREDENTIALS_DIR/${name}.cred"

    if [ ! -f "$cred_file" ]; then
        echo ""; return 1
    fi

    if [ "$ENCRYPTED" = "1" ] && can_encrypt && grep -q "^ENC:" "$cred_file" 2>/dev/null; then
        # Encrypted file — decrypt
        "$ENC_SCRIPT" decrypt < "$cred_file" 2>/dev/null || { echo ""; return 1; }
    else
        cat "$cred_file"
    fi
}

credential_delete() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "usage: credential_delete <name>" >&2
        return 1
    fi
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
    rm -f "$CREDENTIALS_DIR/${name}.cred"
    echo "OK: deleted credential '$name'"
}

credential_list() {
    echo "  ─── Credentials ──────────────────────────────"
    echo ""
    local count=0
    for f in "$CREDENTIALS_DIR"/*.cred; do
        [ -f "$f" ] || continue
        local name
        name=$(basename "$f" .cred)
        local enc_marker=""
        if [ "$ENCRYPTED" = "1" ] && can_encrypt && grep -q "^ENC:" "$f" 2>/dev/null; then
            enc_marker=" (encrypted)"
        fi
        echo "  • $name${enc_marker}"
        count=$((count + 1))
    done
    if [ "$count" = "0" ]; then
        echo "  (no credentials stored)"
    else
        echo ""
        echo "  $count credential(s)"
    fi
}

credential_exists() {
    local name="$1"
    name=$(echo "$name" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
    [ -f "$CREDENTIALS_DIR/${name}.cred" ]
}

# ── Import/Export ─────────────────────────────────────────────────────────────
# Export as JSON: {"credentials": {"name": "value", ...}}
# WARNING: export includes plaintext values — only use for encrypted backup

credential_export() {
    local out_file="${1:-/tmp/credentials_backup.json}"
    python3 -c "
import json, os, glob
creds = {}
for f in glob.glob('$CREDENTIALS_DIR/*.cred'):
    name = os.path.basename(f).replace('.cred', '')
    with open(f) as fh:
        creds[name] = fh.read().strip()
with open('$out_file', 'w') as f:
    json.dump({'credentials': creds}, f, indent=2)
print(f'OK: exported {len(creds)} credentials to $out_file')
" 2>/dev/null || {
        echo "ERROR: export failed (python3 required)"
        return 1
    }
}

credential_import() {
    local in_file="$1"
    if [ -z "$in_file" ] || [ ! -f "$in_file" ]; then
        echo "usage: credential_import <file.json>" >&2
        return 1
    fi
    python3 -c "
import json, sys
with open('$in_file') as f:
    data = json.load(f)
creds = data.get('credentials', {})
for name, value in creds.items():
    # shell out to credential_set
    pass
print(f'OK: {len(creds)} credentials in file (import via credential_set)')
" 2>/dev/null || {
        echo "ERROR: import failed"
        return 1
    }
    echo "Use the agent to re-store each credential via TOOL:credential_save"
}

# ── CLI ───────────────────────────────────────────────────────────────────────
CMD="${1:-list}"
shift 2>/dev/null || true

case "$CMD" in
    set)      credential_set "$@" ;;
    get)      credential_get "$@" ;;
    delete|rm)  credential_delete "$@" ;;
    list|ls)  credential_list ;;
    export)   credential_export "$@" ;;
    import)   credential_import "$@" ;;
    exists)   credential_exists "$@" ;;
    *)        credential_list ;;
esac
