#!/bin/bash
# Build a graphical Agentic OS initramfs without modifying the text rootfs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BASE_ROOTFS="$SCRIPT_DIR/rootfs"
GRAPHICAL_ROOTFS="$SCRIPT_DIR/rootfs-graphical"
OUTPUT="$SCRIPT_DIR/initramfs-graphical.cpio"
ALPINE_VERSION="${ALPINE_VERSION:-3.19}"

cd "$SCRIPT_DIR"

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker Desktop is required to install Alpine ARM64 packages."
    echo "Install Docker Desktop, start it, then rerun this script."
    exit 1
fi

if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is installed but its daemon is not running."
    exit 1
fi

echo "Building graphical rootfs from the working text rootfs..."
rm -rf "$GRAPHICAL_ROOTFS"
cp -a "$BASE_ROOTFS" "$GRAPHICAL_ROOTFS"

docker run --rm \
    --platform linux/arm64 \
    -v "$GRAPHICAL_ROOTFS:/rootfs" \
    "alpine:${ALPINE_VERSION}" \
    sh -eu -c '
cat > /rootfs/etc/apk/repositories <<REPOS
https://dl-cdn.alpinelinux.org/alpine/v3.19/main
https://dl-cdn.alpinelinux.org/alpine/v3.19/community
REPOS

apk add --root /rootfs --initdb --no-cache \
    xorg-server \
    xinit \
    xrandr \
    xf86-input-libinput \
    openbox \
    chromium \
    xterm \
    xf86-input-libinput \
    xf86-input-evdev \
    xorg-server \
    xdotool \
    xset \
    mesa-dri-gallium \
    mesa-egl \
    libdrm \
    dbus \
    dbus-x11 \
    fontconfig \
    ttf-dejavu \
    ttf-freefont \
    font-misc-misc \
    openssl \
    ca-certificates \
    curl \
    wget \
    python3

mkdir -p /rootfs/etc/X11/xorg.conf.d /rootfs/root/.config/openbox
cat > /rootfs/etc/X11/xorg.conf.d/10-agentic.conf <<XORG
Section "Device"
    Identifier "Agentic GPU"
    Driver "modesetting"
EndSection
Section "Screen"
    Identifier "Agentic Screen"
    Device "Agentic GPU"
    DefaultDepth 24
EndSection

# Auto-config for input devices (libinput for tablet/keyboard from QEMU)
Section "InputClass"
    Identifier "libinput pointer catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection

Section "InputClass"
    Identifier "libinput keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "libinput"
EndSection
XORG

cat > /rootfs/root/.config/openbox/rc.xml <<OPENBOX
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc">
  <applications>
    <application class="Chromium-browser" name="chromium">
      <decor>no</decor>
      <maximized>true</maximized>
      <focus>yes</focus>
    </application>
  </applications>
</openbox_config>
OPENBOX

# ── SearXNG metasearch engine (in-guest web search on 127.0.0.1:8888) ─────────
# Runtime libraries the GUEST needs to run searxng/lxml (installed into /rootfs):
apk add --root /rootfs --no-cache \
    libxml2 \
    libxslt \
    libffi \
    yaml
# Build toolchain + python live in the CONTAINER (same Alpine arm64 userland as
# the guest) so we can create the venv and compile C extensions. These stay in
# the ephemeral build container and never bloat the image.
apk add --no-cache \
    python3 \
    py3-pip \
    git \
    build-base \
    python3-dev \
    libxml2-dev \
    libxslt-dev \
    libffi-dev \
    openssl-dev \
    yaml-dev

# Create the venv INSIDE the rootfs and install SearXNG into it. The venv binary
# is a symlink to /usr/bin/python3.11, which exists in the guest (apk python3
# above), so `\/opt\/searxng\/bin\/python -m searx.webapp` works at boot. Tracks
# master (SearXNG is not on PyPI and its release tags are unstable); pin a commit
# here for reproducible rebuilds.
python3 -m venv /rootfs/opt/searxng
/rootfs/opt/searxng/bin/pip install --no-cache-dir --upgrade pip setuptools wheel
# SearXNG imports its own package (msgspec etc.) during the wheel build, so deps
# must be installed FIRST. Then install the package itself non-editable (copied
# into site-packages so it survives into the guest) with build isolation off.
git clone --depth 1 https://github.com/searxng/searxng /tmp/searxng-src
/rootfs/opt/searxng/bin/pip install --no-cache-dir -r /tmp/searxng-src/requirements.txt
/rootfs/opt/searxng/bin/pip install --no-cache-dir --no-build-isolation /tmp/searxng-src
rm -rf /tmp/searxng-src

# Freeze the version so SearXNG never shells out to git at runtime. The guest has
# no git binary and no repo, so without this searx/version.py raises
# FileNotFoundError on import and the daemon never starts.
cat > /rootfs/opt/searxng/lib/python3.11/site-packages/searx/version_frozen.py <<'"'"'VFEOF'"'"'
VERSION_STRING = "1.0.0-agentic"
VERSION_TAG = "1.0.0-agentic"
DOCKER_TAG = "1.0.0-agentic"
GIT_URL = "https://github.com/searxng/searxng"
GIT_BRANCH = "master"
VFEOF
'

mkdir -p "$GRAPHICAL_ROOTFS/usr/local/share/agentic-ui/cgi-bin"

# SearXNG runtime config. secret_key is filled in at boot by agentic-init.
mkdir -p "$GRAPHICAL_ROOTFS/etc/searxng"
cat > "$GRAPHICAL_ROOTFS/etc/searxng/settings.yml" <<'SEARXCONF'
# Agentic OS — SearXNG settings. Inherits SearXNG defaults (all standard
# engines incl. Google, Bing, Brave, DuckDuckGo) and overrides only what we need.
use_default_settings: true

general:
  instance_name: "Agentic OS Search"
  debug: false

server:
  bind_address: "127.0.0.1"
  port: 8888
  secret_key: "PLACEHOLDER_SECRET"   # replaced at boot by agentic-init
  limiter: false                      # single local user; no bot rate-limiting
  public_instance: false

search:
  safe_search: 0
  autocomplete: ""
  formats:
    - html
    - json

ui:
  static_use_hash: true
SEARXCONF
cp ui/home.html "$GRAPHICAL_ROOTFS/usr/local/share/agentic-ui/home.html"
cp ui/cgi-bin/*.sh "$GRAPHICAL_ROOTFS/usr/local/share/agentic-ui/cgi-bin/"
cp ui/ui-server.sh "$GRAPHICAL_ROOTFS/usr/local/bin/ui-server.sh"
cp rootfs/init "$GRAPHICAL_ROOTFS/init"

# browser-ctl (CDP driver for graphical Chromium remote debugging)
cp browser/browser-ctl.py "$GRAPHICAL_ROOTFS/usr/local/bin/browser-ctl"
# workflow runner (multi-step browser automations)
cp browser/workflows.sh "$GRAPHICAL_ROOTFS/usr/local/bin/workflows.sh"
# credential storage (secure, encrypted)
cp identity/credentials.sh "$GRAPHICAL_ROOTFS/usr/local/bin/credentials.sh"
chmod 755 \
    "$GRAPHICAL_ROOTFS/init" \
    "$GRAPHICAL_ROOTFS/usr/local/bin/ui-server.sh" \
    "$GRAPHICAL_ROOTFS/usr/local/share/agentic-ui/cgi-bin/"*.sh \
    "$GRAPHICAL_ROOTFS/usr/local/bin/browser-ctl" \
    "$GRAPHICAL_ROOTFS/usr/local/bin/workflows.sh" \
    "$GRAPHICAL_ROOTFS/usr/local/bin/credentials.sh"

echo "Packing $OUTPUT..."
(
    cd "$GRAPHICAL_ROOTFS"
    find . -print0 | cpio --null -o -H newc > "$OUTPUT"
)

echo "Built graphical Agentic OS:"
ls -lh "$OUTPUT"
echo "Next: ./create-data-disk.sh && ./launch-graphical.sh"
