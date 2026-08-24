#!/bin/sh
# workflows.sh — Agentic OS Web Automation Runner
#
# Executes multi-step workflows: a sequence of browser actions defined in JSON.
# The agent (shell + LLM) creates and runs these to automate repetitive tasks:
#   - Log into a service
#   - Fill and submit a form
#   - Navigate a multi-page flow
#   - Extract structured data from a site
#
# Each step is a single CDP action. The agent chains steps using browser-ctl.
# Workflows can be public (shared), private (user only), or team-shared.
#
# Usage:
#   workflows.sh create <name> <json-steps>        # create a workflow
#   workflows.sh run <name>                        # execute it
#   workflows.sh show <name>                       # display definition
#   workflows.sh list [scope]                      # list by scope (all/my,public,team)
#   workflows.sh delete <name>                     # remove one
#   workflows.sh share <name> <public|private|team:group>  # set visibility
#   workflows.sh import <url-or-file>              # install from file/URL
#   workflows.sh export <name>                     # get JSON for sharing
#
# Scope (visibility):
#   private    — only this user can run (default)
#   public     — anyone can discover and run
#   team:<id>  — accessible to users in the same team group
#
# Storage:
#   ~/.agentic/workflows/<scope>/<name>.json
#
# Example workflow (login to a service):
#   workflows.sh create github-login '[
#     {"action":"navigate","url":"https://github.com/login"},
#     {"action":"wait","selector":"input[name=\"login\"]","timeout":10},
#     {"action":"type","selector":"input[name=\"login\"]","credential":"github_user"},
#     {"action":"type","selector":"input[name=\"password\"]","credential":"github_pass"},
#     {"action":"click","selector":"input[type=\"submit\"]"},
#     {"action":"wait","selector":".dashboard","timeout":15},
#     {"action":"eval","js":"document.title"}
#   ]'
#
# The "credential" field references a stored credential by name.
# Credentials are resolved at runtime from the credentials store.

set -e

AGENTIC_DIR="${AGENTIC_DIR:-/usr/share/agentic}"
WORKFLOWS_DIR="$AGENTIC_DIR/workflows"
CREDENTIALS_DIR="$AGENTIC_DIR/credentials"
BROWSER_CTL="/usr/local/bin/browser-ctl"

mkdir -p "$WORKFLOWS_DIR" "$CREDENTIALS_DIR"

# ── Scope directories ─────────────────────────────────────────────────────────
scope_dir() {
    case "${1:-private}" in
        public)  echo "$WORKFLOWS_DIR/public" ;;
        team:*)  echo "$WORKFLOWS_DIR/team" ;;
        *)       echo "$WORKFLOWS_DIR/private" ;;
    esac
}

# ── Workflow file path ────────────────────────────────────────────────────────
workflow_path() {
    local name="$1" scope="${2:-private}"
    local dir
    dir=$(scope_dir "$scope")
    mkdir -p "$dir"
    echo "$dir/${name}.json"
}

# ── Parse a workflow JSON and return the scope ─────────────────────────────────
workflow_scope() {
    local file="$1"
    if [ ! -f "$file" ]; then echo "private"; return; fi
    local scope
    scope=$(grep -o '"scope"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" 2>/dev/null | head -1 | sed 's/.*"scope"[[:space:]]*:[[:space:]]*"//;s/"//')
    echo "${scope:-private}"
}

# ── Run a single workflow step ────────────────────────────────────────────────
run_step() {
    local step_file="$1" step_index="$2"
    local action url selector text credential timeout eval_js screenshot

    action=$(json_field "$step_file" "action" 2>/dev/null || echo "")

    if [ -z "$action" ]; then
        echo "  [WARN] step $step_index: no action, skipping"
        return 0
    fi

    echo "  [step $step_index] $action"

    case "$action" in
        navigate|go)
            url=$(json_field "$step_file" "url")
            if [ -z "$url" ]; then
                echo "  [ERROR] navigate: url= required"; return 1
            fi
            $BROWSER_CTL navigate "$url" || return 1
            ;;

        wait)
            selector=$(json_field "$step_file" "selector")
            timeout=$(json_field "$step_file" "timeout")
            timeout=${timeout:-10}
            if [ -z "$selector" ]; then
                echo "  [ERROR] wait: selector= required"; return 1
            fi
            $BROWSER_CTL wait "$selector" "$timeout" || return 1
            ;;

        click)
            selector=$(json_field "$step_file" "selector")
            if [ -z "$selector" ]; then
                echo "  [ERROR] click: selector= required"; return 1
            fi
            $BROWSER_CTL click "$selector" || return 1
            ;;

        type)
            selector=$(json_field "$step_file" "selector")
            text=$(json_field "$step_file" "text")
            credential=$(json_field "$step_file" "credential")
            if [ -n "$credential" ]; then
                text=$(credentials_get "$credential")
            fi
            if [ -z "$selector" ] || [ -z "$text" ]; then
                echo "  [ERROR] type: selector= and text= (or credential=) required"; return 1
            fi
            $BROWSER_CTL type "$selector" "$text" || return 1
            ;;

        clear)
            selector=$(json_field "$step_file" "selector")
            if [ -z "$selector" ]; then
                echo "  [ERROR] clear: selector= required"; return 1
            fi
            $BROWSER_CTL clear "$selector" || return 1
            ;;

        press)
            key=$(json_field "$step_file" "key")
            if [ -z "$key" ]; then
                echo "  [ERROR] press: key= required"; return 1
            fi
            $BROWSER_CTL press "$key" || return 1
            ;;

        select)
            selector=$(json_field "$step_file" "selector")
            text=$(json_field "$step_file" "text")
            if [ -z "$selector" ] || [ -z "$text" ]; then
                echo "  [ERROR] select: selector= and text= required"; return 1
            fi
            $BROWSER_CTL select "$selector" "$text" || return 1
            ;;

        eval)
            eval_js=$(json_field "$step_file" "js")
            if [ -z "$eval_js" ]; then
                echo "  [ERROR] eval: js= required"; return 1
            fi
            $BROWSER_CTL eval "$eval_js" || return 1
            ;;

        screenshot)
            screenshot=$(json_field "$step_file" "path")
            $BROWSER_CTL screenshot "${screenshot:-/tmp/workflow_step_${step_index}.png}" || return 1
            ;;

        scroll)
            direction=$(json_field "$step_file" "direction")
            direction=${direction:-down}
            $BROWSER_CTL scroll "$direction" || return 1
            ;;

        find)
            text=$(json_field "$step_file" "text")
            if [ -z "$text" ]; then
                echo "  [ERROR] find: text= required"; return 1
            fi
            $BROWSER_CTL find "$text" || return 1
            ;;

        keyinfo)
            selector=$(json_field "$step_file" "selector")
            if [ -z "$selector" ]; then
                echo "  [ERROR] keyinfo: selector= required"; return 1
            fi
            $BROWSER_CTL keyinfo "$selector" || return 1
            ;;

        back)
            $BROWSER_CTL back || return 1
            ;;

        forward)
            $BROWSER_CTL forward || return 1
            ;;

        reload)
            $BROWSER_CTL reload || return 1
            ;;

        sleep)
            secs=$(json_field "$step_file" "seconds")
            secs=${secs:-1}
            echo "  [step $step_index] sleeping ${secs}s"
            sleep "$secs"
            ;;

        *)
            echo "  [WARN] step $step_index: unknown action '$action', skipping"
            ;;
    esac

    return 0
}

# ── Execute a workflow ────────────────────────────────────────────────────────
cmd_run() {
    local name="$1"
    local scope="${2:-private}"
    local wf_file
    wf_file=$(workflow_path "$name" "$scope")

    if [ ! -f "$wf_file" ]; then
        echo "ERROR: workflow not found: $name (scope: $scope)"
        echo "  Run: workflows.sh list to see available workflows"
        return 1
    fi

    if [ ! -x "$BROWSER_CTL" ]; then
        echo "ERROR: browser-ctl not found at $BROWSER_CTL"
        echo "  Is Chromium running with --remote-debugging-port=9222?"
        return 1
    fi

    # Extract metadata
    local desc
    desc=$(json_field "$wf_file" "description" 2>/dev/null || echo "")
    echo "══════════════════════════════════════════════"
    echo "  Workflow: $name"
    echo "  Scope:    $scope"
    [ -n "$desc" ] && echo "  Desc:     $desc"
    echo "══════════════════════════════════════════════"

    # Extract steps — each step is a JSON object in the "steps" array
    # We create temp files for each step
    local tmpdir
    tmpdir=$(mktemp -d /tmp/wf_steps.XXXXXX)

    # Parse the steps array using a lightweight approach:
    # Extract each step object between { and } inside the steps: [...] block
    python3 -c "
import json, sys
try:
    with open('$wf_file') as f:
        data = json.load(f)
    steps = data.get('steps', [])
    for i, step in enumerate(steps):
        with open('$tmpdir/step_%d.json' % i, 'w') as f:
            json.dump(step, f)
    print(len(steps))
except Exception as e:
    print('ERROR parsing workflow: ' + str(e), file=sys.stderr)
    sys.exit(1)
" 2>/dev/null || {
        echo "ERROR: could not parse workflow JSON"
        rm -rf "$tmpdir"
        return 1
    }

    local step_count
    step_count=$(ls "$tmpdir"/step_*.json 2>/dev/null | wc -l | tr -d ' ')

    if [ "$step_count" = "0" ]; then
        echo "ERROR: workflow has no steps"
        rm -rf "$tmpdir"
        return 1
    fi

    echo "  Steps: $step_count"
    echo ""

    local failed=0
    for i in $(seq 0 $((step_count - 1))); do
        local step_file="$tmpdir/step_${i}.json"
        echo -n "  [${i}/${step_count}] "
        if ! run_step "$step_file" "$i"; then
            echo "  [FAILED] step $i failed — stopping workflow"
            failed=1
            break
        fi
        echo ""
    done

    rm -rf "$tmpdir"

    if [ "$failed" = "1" ]; then
        echo "Workflow $name: FAILED at step $i"
        return 1
    else
        echo "Workflow $name: COMPLETE ($step_count steps)"
        return 0
    fi
}

# ── Create a workflow ─────────────────────────────────────────────────────────
# Accepts JSON from stdin or as the 3rd arg.
# Usage: workflows.sh create <name> [scope]   (then pipe JSON, or: workflows.sh create <name> <scope> '<json>')
cmd_create() {
    local name="$1"
    local scope="${2:-private}"
    local steps_json=""

    # If 3rd arg is provided, use it; otherwise read from stdin
    if [ -n "${3:-}" ]; then
        steps_json="$3"
    else
        steps_json=$(cat)
    fi

    if [ -z "$name" ] || [ -z "$steps_json" ]; then
        echo "usage: workflows.sh create <name> [scope]   (pipe JSON to stdin)"
        echo "  scope: private (default), public, team:<group>"
        return 1
    fi

    # Validate JSON
    echo "$steps_json" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null || {
        echo "ERROR: invalid JSON for steps"
        return 1
    }

    local wf_file
    wf_file=$(workflow_path "$name" "$scope")

    # Wrap steps in a workflow object with metadata
    python3 -c "
import json, sys
steps = json.loads(sys.argv[1])
wf = {
    'name': sys.argv[2],
    'scope': sys.argv[3],
    'created': __import__('time').strftime('%Y-%m-%dT%H:%M:%SZ', __import__('time').gmtime()),
    'steps': steps
}
with open(sys.argv[4], 'w') as f:
    json.dump(wf, f, indent=2)
print('OK created: $name (scope: $scope)')
" "$steps_json" "$name" "$scope" "$wf_file" || return 1

    return 0
}

# ── Show a workflow ───────────────────────────────────────────────────────────
cmd_show() {
    local name="$1" scope="${2:-private}"
    local wf_file
    wf_file=$(workflow_path "$name" "$scope")

    if [ ! -f "$wf_file" ]; then
        echo "ERROR: workflow not found: $name"
        return 1
    fi
    cat "$wf_file"
    echo ""
}

# ── List workflows ────────────────────────────────────────────────────────────
cmd_list() {
    local filter="${1:-all}"
    echo "  ─── Workflows ──────────────────────────────────────"
    echo ""

    for dir in private public team; do
        [ "$filter" = "public" ] && [ "$dir" != "public" ] && continue
        [ "$filter" = "private" ] && [ "$dir" != "private" ] && continue
        [ "$filter" = "team" ] && [ "$dir" != "team" ] && continue

        local wdir="$WORKFLOWS_DIR/$dir"
        [ -d "$wdir" ] || continue

        for f in "$wdir"/*.json; do
            [ -f "$f" ] || continue
            local name desc scope
            name=$(basename "$f" .json)
            desc=$(json_field "$f" "description" 2>/dev/null || echo "")
            scope=$(workflow_scope "$f")
            local icon="●"
            case "$scope" in
                public)  icon="🌐" ;;
                team:*)  icon="👥" ;;
                *)       icon="🔒" ;;
            esac
            echo "  $icon $name  ${desc:-(no description)}"
        done
    done
    echo ""
}

# ── Delete ────────────────────────────────────────────────────────────────────
cmd_delete() {
    local name="$1" scope="${2:-private}"
    local wf_file
    wf_file=$(workflow_path "$name" "$scope")
    if [ -f "$wf_file" ]; then
        rm "$wf_file"
        echo "OK deleted: $name"
    else
        echo "ERROR: workflow not found: $name"
        return 1
    fi
}

# ── Share (set scope) ─────────────────────────────────────────────────────────
cmd_share() {
    local name="$1" new_scope="$2"
    local old_scope="${3:-private}"

    if [ -z "$name" ] || [ -z "$new_scope" ]; then
        echo "usage: workflows.sh share <name> <private|public|team:<id>>"
        return 1
    fi

    local old_file
    old_file=$(workflow_path "$name" "$old_scope")
    if [ ! -f "$old_file" ]; then
        # try any scope
        for d in private public team; do
            old_file=$(workflow_path "$name" "$d")
            [ -f "$old_file" ] && { old_scope="$d"; break; }
        done
    fi

    if [ ! -f "$old_file" ]; then
        echo "ERROR: workflow not found: $name"
        return 1
    fi

    local new_file
    new_file=$(workflow_path "$name" "$new_scope")
    mkdir -p "$(dirname "$new_file")"

    # Update scope in JSON
    python3 -c "
import json
with open('$old_file') as f:
    data = json.load(f)
data['scope'] = '$new_scope'
with open('$new_file', 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null || {
        echo "ERROR: failed to update scope"
        return 1
    }

    # Remove old if different directory
    [ "$(dirname "$old_file")" != "$(dirname "$new_file")" ] && rm "$old_file"
    echo "OK: $name is now $new_scope"
}

# ── Export ────────────────────────────────────────────────────────────────────
cmd_export() {
    local name="$1" scope="${2:-private}"
    cmd_show "$name" "$scope"
}

# ── Import ────────────────────────────────────────────────────────────────────
cmd_import() {
    local source="$1"
    if [ -z "$source" ]; then
        echo "usage: workflows.sh import <url-or-file>"
        return 1
    fi

    local json_content
    if [[ "$source" == http*://* ]]; then
        json_content=$(wget -q -O - --timeout=15 "$source" 2>/dev/null) || {
            echo "ERROR: failed to fetch $source"; return 1
        }
    elif [ -f "$source" ]; then
        json_content=$(cat "$source")
    else
        echo "ERROR: not a file or URL: $source"
        return 1
    fi

    # Validate and extract name
    local name
    name=$(echo "$json_content" | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    print(data.get('name', 'unnamed'))
except:
    sys.exit(1)
" 2>/dev/null) || {
        echo "ERROR: invalid workflow JSON"; return 1
    }

    local wf_file
    wf_file=$(workflow_path "$name" "public")
    echo "$json_content" > "$wf_file"
    echo "OK imported: $name (scope: public)"
}

# ── Credential helpers ────────────────────────────────────────────────────────
# Lightweight wrapper around credentials.sh (defined below if not sourced)
credentials_get() {
    local name="$1"
    if [ -f "$AGENTIC_DIR/credentials/credentials.sh" ]; then
        # shellcheck disable=SC1090
        . "$AGENTIC_DIR/credentials/credentials.sh"
        credential_get "$name" 2>/dev/null && return 0
    fi
    # Fallback: plain text file (NOT encrypted, only for dev)
    local cred_file="$AGENTIC_DIR/credentials/${name}.txt"
    if [ -f "$cred_file" ]; then
        cat "$cred_file"
        return 0
    fi
    echo ""
    return 1
}

# ── Lightweight JSON field extractor (no jq dependency) ───────────────────────
json_field() {
    local file="$1" field="$2"
    python3 -c "
import json
with open('$file') as f:
    data = json.load(f)
val = data.get('$field', '')
if isinstance(val, (dict, list)):
    print(json.dumps(val))
else:
    print(val)
" 2>/dev/null || echo ""
}

# ── CLI ───────────────────────────────────────────────────────────────────────
CMD="${1:-list}"
shift 2>/dev/null || true

case "$CMD" in
    create)   cmd_create "$@" ;;
    run)      cmd_run "$@" ;;
    show)     cmd_show "$@" ;;
    list)     cmd_list "$@" ;;
    delete|rm)  cmd_delete "$@" ;;
    share)    cmd_share "$@" ;;
    export)   cmd_export "$@" ;;
    import)   cmd_import "$@" ;;
    *)        cmd_list ;;
esac
