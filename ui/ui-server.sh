#!/bin/sh
# ui-server.sh — start the Agentic OS web UI server
# Uses busybox httpd (already in Alpine rootfs)
#
# Serves:
#   http://localhost:7080/           → home.html (the home screen)
#   http://localhost:7080/cgi-bin/   → API endpoints

UI_DIR="/usr/share/agentic/ui"
PORT=7080
PID_FILE="/var/run/agentic-ui.pid"

mkdir -p "$UI_DIR/cgi-bin"

# Copy web files if not already there
[ -f "$UI_DIR/index.html" ] || cp /usr/local/share/agentic-ui/home.html "$UI_DIR/index.html" 2>/dev/null
for f in /usr/local/share/agentic-ui/cgi-bin/*.sh; do
    [ -f "$f" ] || continue
    cp "$f" "$UI_DIR/cgi-bin/$(basename $f)"
    chmod 755 "$UI_DIR/cgi-bin/$(basename $f)"
done

CMD="$1"
case "$CMD" in
    stop)
        [ -f "$PID_FILE" ] && kill "$(cat $PID_FILE)" 2>/dev/null
        echo "[ui-server] stopped"
        ;;
    status)
        if [ -f "$PID_FILE" ] && kill -0 "$(cat $PID_FILE)" 2>/dev/null; then
            echo "[ui-server] running on http://localhost:$PORT (pid $(cat $PID_FILE))"
        else
            echo "[ui-server] not running"
        fi
        ;;
    *)
        # Kill old instance
        [ -f "$PID_FILE" ] && kill "$(cat $PID_FILE)" 2>/dev/null; rm -f "$PID_FILE"

        echo "[ui-server] starting on http://localhost:$PORT"
        echo "[ui-server] web root: $UI_DIR"

        # Use aghttpd (our built-in static server with CGI support)
        /usr/local/bin/aghttpd -p "$PORT" -h "$UI_DIR" &
        echo $! > "$PID_FILE"
        echo "[ui-server] started (pid $!)"
        ;;
esac
