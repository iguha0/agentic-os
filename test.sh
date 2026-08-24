#!/bin/bash
set -e

# Agentic OS QEMU Test — boot with model disk image
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL="vmlinuz"
INITRD="initramfs.cpio"
MODEL_DISK="model-disk.img"

echo "========================================="
echo "  Agentic OS QEMU Test"
echo "========================================="

# Check required files
for f in "$KERNEL" "$INITRD" "$MODEL_DISK"; do
    if [ ! -f "$f" ]; then
        echo "ERROR: Missing file: $f"
        exit 1
    fi
done

echo "Files:"
ls -lh "$KERNEL" "$INITRD" "$MODEL_DISK"

echo ""
echo "Starting QEMU..."
echo "Press Ctrl+A, X to exit QEMU"
echo ""

qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a72 \
    -smp 2 \
    -m 8G \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -drive "file=$MODEL_DISK,format=raw,if=virtio,readonly=on" \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0 \
    -append "console=ttyAMA0 root=/dev/ram init=/init panic=5" \
    -nographic \
    -monitor none 2>&1 | tee qemu.log

echo ""
echo "QEMU exited with code: ${PIPESTATUS[0]}"
