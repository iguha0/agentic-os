#!/bin/bash
# install-rootfs.sh — sync all repo assets into rootfs/ (source of truth for initramfs)
# Run after every source change, then scripts/mkinitramfs.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$SCRIPT_DIR/../rootfs"
BIN="$ROOT/bin"
LOCAL="$ROOT/usr/local/bin"
UI="$ROOT/usr/local/share/agentic-ui"

mkdir -p "$BIN" "$LOCAL" "$UI/cgi-bin"

echo "[install] agent shell..."
cp "$SCRIPT_DIR/../shell2/agentic-shell2" "$BIN/agentic-shell2"
chmod 755 "$BIN/agentic-shell2"

echo "[install] tools & daemons -> /usr/local/bin (extensionless + .sh aliases)..."
install_sh() { # <src> <dst-noext>
    cp "$1" "$LOCAL/$2"
    chmod 755 "$LOCAL/$2"
    [ -f "$LOCAL/$2.sh" ] || cp "$1" "$LOCAL/$2.sh"
}
install_sh "$SCRIPT_DIR/../net/share/agentic-shared.sh" agentic-shared
install_sh "$SCRIPT_DIR/../net/share/share-tools.sh"   share-tools
install_sh "$SCRIPT_DIR/../net/share/e2e-encrypt.sh"   e2e-encrypt
install_sh "$SCRIPT_DIR/../net/share/agtunnel.sh"      agtunnel
install_sh "$SCRIPT_DIR/../net/share/share-open.sh"    share-open
cp "$SCRIPT_DIR/../net/share/open.sh" "$LOCAL/open"; chmod 755 "$LOCAL/open"
install_sh "$SCRIPT_DIR/../identity/gen-identity.sh"   gen-identity
install_sh "$SCRIPT_DIR/../identity/certify.sh"        certify
install_sh "$SCRIPT_DIR/../identity/certify-verify.sh" certify-verify
install_sh "$SCRIPT_DIR/../identity/credentials.sh"    credentials
install_sh "$SCRIPT_DIR/../learning/learn-profile.sh"  learn-profile
install_sh "$SCRIPT_DIR/../apps/shortcuts.sh"          shortcuts
install_sh "$SCRIPT_DIR/../net/nostr/nostr-publish.sh" nostr-publish
cp "$SCRIPT_DIR/../net/nostr/nostr-ws.py"   "$LOCAL/nostr-ws.py";  chmod 755 "$LOCAL/nostr-ws.py"
cp "$SCRIPT_DIR/../net/nostr/bip340.py"     "$LOCAL/bip340.py";    chmod 644 "$LOCAL/bip340.py"
install_sh "$SCRIPT_DIR/../net/lightning/lnurl-pay.sh" lnurl-pay
install_sh "$SCRIPT_DIR/../net/search/distributed-search.sh" distributed-search

# workflows + browser control keep their exact called names
cp "$SCRIPT_DIR/../browser/workflows.sh"  "$LOCAL/workflows.sh";  chmod 755 "$LOCAL/workflows.sh"
cp "$SCRIPT_DIR/../browser/browser-ctl.py" "$LOCAL/browser-ctl";  chmod 755 "$LOCAL/browser-ctl"
[ -f "$SCRIPT_DIR/../browser/agbrowser" ] && cp "$SCRIPT_DIR/../browser/agbrowser" "$LOCAL/agbrowser" && chmod 755 "$LOCAL/agbrowser"

echo "[install] libsodium sealed-box helper (agseal)..."
if [ -f "$SCRIPT_DIR/../prebuilt/agseal" ]; then
    cp "$SCRIPT_DIR/../prebuilt/agseal" "$LOCAL/agseal"; chmod 755 "$LOCAL/agseal"
else
    echo "  WARN: prebuilt/agseal missing — private shares will use openssl fallback"
fi

# lightning tip line on public shares
true
echo "[install] web ui..."
[ -f "$ROOT/usr/local/bin/aghttpd" ] || { echo "ERROR: rootfs/usr/local/bin/aghttpd missing (prebuilt)"; exit 1; }
cp "$SCRIPT_DIR/../ui/home.html"     "$UI/home.html"
cp "$SCRIPT_DIR/../ui/ui-server.sh"  "$LOCAL/ui-server.sh"; chmod 755 "$LOCAL/ui-server.sh"
for f in "$SCRIPT_DIR"/../ui/cgi-bin/*.sh; do
    cp "$f" "$UI/cgi-bin/$(basename "$f")"; chmod 755 "$UI/cgi-bin/$(basename "$f")"
done

echo "[install] init script..."
cp "$SCRIPT_DIR/../init/agentic-init.sh" "$ROOT/init"
chmod 755 "$ROOT/init"

echo "[install] done."
