#!/bin/bash
# launch-graphical.sh — Boot PryzentOS with graphical display
#
# Opens a QEMU window showing X11 + Openbox.
# - Chromium kiosk home screen (local agent UI at :7080)
# - Full Chromium browser instance (agent controllable via CDP on port 9222)
# - xterm running the agentic shell
# Use the shell or web UI to drive real web actions with browser-ctl / CDP.
#
# Requirements:
#   - Run build-graphical-rootfs.sh first
#   - Run create-data-disk.sh for persistent memory and identity

set -e
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL="vmlinuz"
INITRD="initramfs-graphical.cpio"
MODEL_DISK="$SCRIPT_DIR/model-disk-qwen.img"
DATA_DISK="$SCRIPT_DIR/agentic-data.img"
VM_MEMORY="${VM_MEMORY:-3G}"

if qemu-system-aarch64 -accel help 2>&1 | grep -q '^hvf$'; then
    ACCEL_FLAGS="-accel hvf -cpu host"
    ACCEL_NAME="HVF"
else
    ACCEL_FLAGS="-accel tcg,thread=multi -cpu cortex-a72"
    ACCEL_NAME="TCG"
fi

if [ ! -f "$INITRD" ]; then
    echo "ERROR: $INITRD not found."
    echo "Chromium/X11 is not present in the text initramfs."
    echo "Build it first with ./build-graphical-rootfs.sh"
    exit 1
fi

for f in "$KERNEL" "$INITRD" "$MODEL_DISK" "$DATA_DISK"; do
    [ -f "$f" ] || { echo "ERROR: Missing: $f"; exit 1; }
done

echo "═══════════════════════════════════════════════════════"
echo "  PryzentOS — Graphical Mode"
echo "  X11 + Openbox + Chromium home (kiosk :7080) + full browser (CDP 9222)"
echo "  + xterm running agentic-shell2"
echo "═══════════════════════════════════════════════════════"
echo ""
echo "  Kernel:  $KERNEL"
echo "  Initrd:  $INITRD"
echo "  Model:   $MODEL_DISK"
echo "  Data:    $DATA_DISK"
echo "  Memory:  $VM_MEMORY"
echo "  Accel:   $ACCEL_NAME"
echo "  Display: QEMU window (1280x800)"
echo "  USB tablet + kbd for input (reliable for kiosk). Click inside the QEMU window to capture mouse/keyboard from your Mac."
echo "  The main Chromium kiosk (agent home UI) will be auto-focused."
echo ""

# ── Detect best display backend ───────────────────────────────────────────────
DISPLAY_FLAGS="-device virtio-gpu-pci,xres=1280,yres=800"

# macOS: prefer cocoa (native window)
if [[ "$OSTYPE" == "darwin"* ]]; then
    if qemu-system-aarch64 -display help 2>&1 | grep -q cocoa; then
        DISPLAY_FLAGS="$DISPLAY_FLAGS -display cocoa,show-cursor=on"
        echo "  Display backend: cocoa (native Mac window)"
    else
        DISPLAY_FLAGS="$DISPLAY_FLAGS -display sdl,show-cursor=on"
        echo "  Display backend: SDL"
    fi
else
    # Linux: use GTK or SDL
    if qemu-system-aarch64 -display help 2>&1 | grep -q gtk; then
        DISPLAY_FLAGS="$DISPLAY_FLAGS -display gtk,show-cursor=on"
    else
        DISPLAY_FLAGS="$DISPLAY_FLAGS -display sdl,show-cursor=on"
    fi
fi

# ── Input devices: USB tablet + keyboard (most reliable for kiosk Chromium + X11 on macOS host) ─
# Virtio-gpu for display, USB for input (better pointer/keyboard passthrough in practice)
INPUT_FLAGS="\
    -device usb-ehci,id=ehci \
    -device usb-tablet,bus=ehci.0 \
    -device usb-kbd,bus=ehci.0"

# Additional flags sometimes help input on macOS hosts
QEMU_INPUT_EXTRA="-usb"

# ── Network (same as text mode) ───────────────────────────────────────────────
# Forward the local UI port so you can also access the web UI from your Mac browser
NET_FLAGS="-device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::7080-:7080"

MODEL_FLAGS="-drive file=${MODEL_DISK},if=none,id=modeldisk,format=raw,readonly=on \
             -device virtio-blk-pci,drive=modeldisk,id=blk0 \
             -drive file=${DATA_DISK},if=none,id=datadisk,format=raw \
             -device virtio-blk-pci,drive=datadisk,id=blk1"

echo ""
echo "Starting QEMU... (close the window or Ctrl+C to stop)"
echo ""

qemu-system-aarch64 \
    -machine virt \
    $ACCEL_FLAGS \
    -smp 2 \
    -m "$VM_MEMORY" \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    $DISPLAY_FLAGS \
    $INPUT_FLAGS \
    $QEMU_INPUT_EXTRA \
    $NET_FLAGS \
    $MODEL_FLAGS \
    -device virtio-balloon \
    -append "console=ttyAMA0 root=/dev/ram init=/init agentic.mode=graphical panic=30 quiet" \
    -serial mon:stdio \
    2>qemu-graphical-errors.log

echo ""
echo "QEMU exited."
[ -s qemu-graphical-errors.log ] && echo "=== QEMU errors ===" && cat qemu-graphical-errors.log
