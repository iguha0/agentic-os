#!/bin/bash
# add-modules-to-initramfs.sh
# Packs downloaded kernel modules into rootfs so modprobe works at boot.
# Run after get-kernel-modules.sh

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SCRIPT_DIR"

echo "Adding kernel modules to rootfs..."

MODS_SRC="$SCRIPT_DIR/modules"
if [ ! -d "$MODS_SRC" ]; then
    echo "ERROR: No modules directory found. Run scripts/get-kernel-modules.sh first."
    exit 1
fi

# Determine kernel version from extracted package if available, else use directory name.
if [ -f "$SCRIPT_DIR/tmp-modules/extract/usr/share/kernel/virt/kernel.release" ]; then
    KVER=$(cat "$SCRIPT_DIR/tmp-modules/extract/usr/share/kernel/virt/kernel.release")
else
    KVER=$(find "$MODS_SRC" -mindepth 1 -maxdepth 1 -type d | sed 's|.*/||' | head -n 1)
fi
echo "Kernel version: $KVER"

# Install into rootfs
DEST="$SCRIPT_DIR/rootfs/lib/modules/$KVER"
mkdir -p "$DEST"
# If the modules are stored under a generic 'kernel' subdir, copy them into the versioned tree.
if [ -d "$MODS_SRC/kernel" ]; then
    cp -r "$MODS_SRC/kernel" "$DEST/"
    cp "$MODS_SRC/"modules.* "$DEST/" 2>/dev/null || true
else
    cp -r "$MODS_SRC/$KVER/"* "$DEST/" 2>/dev/null || true
fi

# Busybox modprobe looks for modules.dep in the version dir root. If an older
# extraction produced modules/kernel/modules.*, copy those indexes up without
# rewriting paths; the module files themselves live under $DEST/kernel/...
if [ ! -f "$DEST/modules.dep" ] && [ -f "$DEST/kernel/modules.dep" ]; then
    cp "$DEST/kernel/modules.dep" "$DEST/modules.dep"
    cp "$DEST/kernel/modules.dep.bin" "$DEST/modules.dep.bin" 2>/dev/null || true
    cp "$DEST/kernel/modules.builtin" "$DEST/modules.builtin" 2>/dev/null || true
    cp "$DEST/kernel/modules.order" "$DEST/modules.order" 2>/dev/null || true
fi

echo "✓ Modules installed to rootfs/lib/modules/$KVER/"
find "$DEST" -maxdepth 3 -type f | head -10

# Rebuild initramfs
echo ""
echo "Repacking initramfs..."
cd "$SCRIPT_DIR/rootfs"
find . | sort | cpio -o -H newc 2>/dev/null > "$SCRIPT_DIR/initramfs.cpio"
echo "✓ initramfs.cpio rebuilt ($(ls -lh $SCRIPT_DIR/initramfs.cpio | awk '{print $5}'))"
echo ""
echo "Now run: ./test-interactive.sh"
echo "The VM will be able to mount the model disk via virtio_blk."
