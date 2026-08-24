#!/bin/bash
# get-kernel-modules.sh
# Downloads virtio_blk + 9p kernel modules from the Alpine linux-virt package.
# These are needed so the VM can mount the model disk on its own.
#
# Run this on your Mac ONCE, then run add-modules-to-initramfs.sh
#
# Usage: ./scripts/get-kernel-modules.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

ALPINE_VERSION="3.19"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION}"
ARCH="aarch64"
TMP="$SCRIPT_DIR/tmp-modules"
mkdir -p "$TMP"

echo "═══════════════════════════════════════════════════════"
echo "  PryzentOS — Kernel Module Downloader"
echo "  Gets virtio_blk + 9p so the VM can mount its own disks"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Find the right kernel version ────────────────────────────────────────────
# We need the linux-virt package version that MATCHES the vmlinuz we're booting
KERNEL_VER=$(strings vmlinuz 2>/dev/null | grep "Linux version" | head -1 | awk '{print $3}')
echo "Detected kernel version: ${KERNEL_VER:-unknown}"

# Download the APKINDEX to find the right package version
echo "Fetching Alpine package index..."
curl -s -o "$TMP/APKINDEX.main.tar.gz" \
    "$ALPINE_MIRROR/main/$ARCH/APKINDEX.tar.gz" 2>/dev/null || \
wget -q -O "$TMP/APKINDEX.main.tar.gz" \
    "$ALPINE_MIRROR/main/$ARCH/APKINDEX.tar.gz" 2>/dev/null

# Extract and find linux-virt version
tar -xf "$TMP/APKINDEX.main.tar.gz" -C "$TMP" APKINDEX 2>/dev/null || true
LINUX_PKG=$(grep -A5 "^P:linux-virt$" "$TMP/APKINDEX" 2>/dev/null | grep "^V:" | head -1 | cut -c3-)

if [ -z "$LINUX_PKG" ]; then
    # Fallback: try known good versions
    echo "Could not detect exact version, trying known versions..."
    for ver in "6.6.7-r0" "6.6.2-r0" "6.1.67-r0" "6.1.63-r0"; do
        URL="$ALPINE_MIRROR/main/$ARCH/linux-virt-${ver}.apk"
        echo "  Trying: linux-virt-${ver}..."
        if curl -sf -o "$TMP/linux-virt.apk" "$URL" 2>/dev/null; then
            LINUX_PKG="$ver"
            break
        fi
    done
else
    echo "Found linux-virt version: $LINUX_PKG"
    URL="$ALPINE_MIRROR/main/$ARCH/linux-virt-${LINUX_PKG}.apk"
    echo "Downloading: linux-virt-${LINUX_PKG}.apk..."
    curl -sf -o "$TMP/linux-virt.apk" "$URL" 2>/dev/null || \
    wget -q -O "$TMP/linux-virt.apk" "$URL" 2>/dev/null
fi

if [ ! -s "$TMP/linux-virt.apk" ]; then
    echo ""
    echo "ERROR: Could not download linux-virt package."
    echo ""
    echo "Manual steps:"
    echo "  1. Go to: $ALPINE_MIRROR/main/$ARCH/"
    echo "  2. Download linux-virt-*.apk"
    echo "  3. Put it at: $TMP/linux-virt.apk"
    echo "  4. Re-run this script"
    exit 1
fi

echo "✓ Downloaded linux-virt package ($(du -sh "$TMP/linux-virt.apk" | cut -f1))"

# ── Extract the modules we need ───────────────────────────────────────────────
echo ""
echo "Extracting storage, network, 9p, and virtio-gpu modules..."

mkdir -p "$TMP/extract"
# Alpine .apk is a gzipped tar
cd "$TMP/extract"
tar -xzf "$TMP/linux-virt.apk" 2>/dev/null || true

# Find the modules directory
MODS_DIR=$(find "$TMP/extract" -name "modules" -type d 2>/dev/null | head -1)
if [ -z "$MODS_DIR" ]; then
    # Try lib/modules
    MODS_DIR=$(find "$TMP/extract/lib" -maxdepth 2 -type d 2>/dev/null | head -1)
fi

KVER_DIR=$(find "$TMP/extract" -path "*/kernel/drivers/block/virtio_blk.ko*" 2>/dev/null | head -1)
if [ -z "$KVER_DIR" ]; then
    KVER_DIR=$(find "$TMP/extract" -name "virtio_blk.ko*" 2>/dev/null | head -1)
fi

if [ -z "$KVER_DIR" ]; then
    echo "ERROR: virtio_blk.ko not found in package."
    echo "Contents of extracted package:"
    find "$TMP/extract" -name "*.ko*" 2>/dev/null | head -20
    exit 1
fi

echo "✓ Found modules at: $(dirname $KVER_DIR)"

# Create output modules directory mirroring kernel path
# KVER_DIR looks like .../lib/modules/6.6.142-0-virt/kernel/drivers/block/virtio_blk.ko.gz
KVER=$(echo "$KVER_DIR" | sed -n 's|.*/lib/modules/\([^/]*\)/kernel/.*|\1|p')
if [ -z "$KVER" ]; then
    KVER="6.6.142-0-virt"
fi
OUT_MODS="$SCRIPT_DIR/modules/$KVER"
mkdir -p "$OUT_MODS/kernel/drivers/block"
mkdir -p "$OUT_MODS/kernel/drivers/virtio"
mkdir -p "$OUT_MODS/kernel/fs/9p"
mkdir -p "$OUT_MODS/kernel/net/9p"

# Copy key modules
copy_mod() {
    src=$(find "$TMP/extract" -name "$1" 2>/dev/null | head -1)
    if [ -n "$src" ]; then
        destdir="$OUT_MODS/$(echo $2)"
        mkdir -p "$destdir"
        cp "$src" "$destdir/"
        echo "  ✓ $1"
    else
        echo "  ✗ $1 (not found, may be built-in)"
    fi
}

copy_mod "virtio_blk.ko*"   "kernel/drivers/block"
copy_mod "virtio_net.ko*"   "kernel/drivers/net"
copy_mod "net_failover.ko*" "kernel/drivers/net"
copy_mod "failover.ko*"     "kernel/net/core"
copy_mod "virtio.ko*"       "kernel/drivers/virtio"
copy_mod "virtio_ring.ko*"  "kernel/drivers/virtio"
copy_mod "virtio_pci.ko*"   "kernel/drivers/virtio"
copy_mod "9p.ko*"           "kernel/fs/9p"
copy_mod "9pnet.ko*"        "kernel/net/9p"
copy_mod "9pnet_virtio.ko*" "kernel/net/9p"
copy_mod "netfs.ko*"        "kernel/fs/netfs"
copy_mod "fscache.ko*"      "kernel/fs/fscache"
copy_mod "crc32c_generic.ko*" "kernel/crypto"
copy_mod "crc32_generic.ko*"  "kernel/crypto"
copy_mod "libcrc32c.ko*"    "kernel/lib"
copy_mod "crc16.ko*"        "kernel/lib"
copy_mod "mbcache.ko*"      "kernel/fs"
copy_mod "jbd2.ko*"         "kernel/fs/jbd2"
copy_mod "ext4.ko*"         "kernel/fs/ext4"
copy_mod "virtio-gpu.ko*"   "kernel/drivers/gpu/drm/virtio"
copy_mod "virtio_dma_buf.ko*" "kernel/drivers/virtio"
copy_mod "drm.ko*"          "kernel/drivers/gpu/drm"
copy_mod "drm_shmem_helper.ko*" "kernel/drivers/gpu/drm"
copy_mod "drm_kms_helper.ko*" "kernel/drivers/gpu/drm"
copy_mod "drm_panel_orientation_quirks.ko*" "kernel/drivers/gpu/drm"
copy_mod "syscopyarea.ko*"  "kernel/drivers/video/fbdev/core"
copy_mod "sysfillrect.ko*"  "kernel/drivers/video/fbdev/core"
copy_mod "sysimgblt.ko*"    "kernel/drivers/video/fbdev/core"
copy_mod "fb_sys_fops.ko*"  "kernel/drivers/video/fbdev/core"
copy_mod "fb_io_fops.ko*"   "kernel/drivers/video/fbdev/core"
copy_mod "fb.ko*"           "kernel/drivers/video/fbdev/core"
copy_mod "i2c-core.ko*"     "kernel/drivers/i2c"
copy_mod "backlight.ko*"    "kernel/drivers/video/backlight"

# Copy modules.dep and modules.order if present
find "$TMP/extract" -name "modules.dep"   -exec cp {} "$OUT_MODS/" \; 2>/dev/null || true
find "$TMP/extract" -name "modules.order" -exec cp {} "$OUT_MODS/" \; 2>/dev/null || true
find "$TMP/extract" -name "modules.builtin" -exec cp {} "$OUT_MODS/" \; 2>/dev/null || true

echo ""
echo "✓ Modules saved to: $SCRIPT_DIR/modules/"
echo ""
echo "Next step: run scripts/add-modules-to-initramfs.sh"
