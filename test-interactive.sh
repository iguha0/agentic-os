#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

KERNEL="vmlinuz"
INITRD="initramfs.cpio"
MODEL_DISK="$SCRIPT_DIR/model-disk-qwen.img"
VM_MEMORY="${VM_MEMORY:-3G}"
UI_PORT="${UI_PORT:-7080}"

while nc -z 127.0.0.1 "$UI_PORT" >/dev/null 2>&1; do
    UI_PORT=$((UI_PORT + 1))
done

if qemu-system-aarch64 -accel help 2>&1 | grep -q '^hvf$'; then
    ACCEL_FLAGS=(-accel hvf -cpu host)
    ACCEL_NAME="HVF"
else
    ACCEL_FLAGS=(-accel tcg,thread=multi -cpu cortex-a72)
    ACCEL_NAME="TCG"
fi

echo "========================================="
echo "  Agentic OS — Interactive QEMU Test"
echo "========================================="

for f in "$KERNEL" "$INITRD" "$MODEL_DISK"; do
    if [ ! -f "$f" ]; then echo "ERROR: Missing: $f"; exit 1; fi
done

STORAGE_FLAGS=(
    -drive "file=${MODEL_DISK},if=none,id=modeldisk,format=raw,readonly=on"
    -device virtio-blk-pci,drive=modeldisk,id=blk0
)

if [ -f "$SCRIPT_DIR/agentic-data.img" ]; then
    STORAGE_FLAGS+=(
        -drive "file=$SCRIPT_DIR/agentic-data.img,if=none,id=datadisk,format=raw"
        -device virtio-blk-pci,drive=datadisk,id=blk1
    )
fi

echo ""
echo "Files:"
ls -lh "$KERNEL" "$INITRD" "$MODEL_DISK"
echo "VM memory: $VM_MEMORY"
echo "Acceleration: $ACCEL_NAME"
echo ""
echo "Starting QEMU... (Ctrl+A then X to exit)"
echo ""
echo "  ┌─ Agentic OS UI ──────────────────────────────────────┐"
echo "  │  After the VM finishes loading, open in your browser:│"
printf '  │  http://localhost:%-5s                                │\n' "$UI_PORT"
echo "  └───────────────────────────────────────────────────────┘"
echo ""

run_qemu() {
    qemu-system-aarch64 \
        -machine virt \
        "${ACCEL_FLAGS[@]}" \
        -smp 2 \
        -m "$VM_MEMORY" \
        -kernel "$KERNEL" \
        -initrd "$INITRD" \
        -device virtio-net-pci,netdev=net0 \
        -netdev "$1" \
        "${STORAGE_FLAGS[@]}" \
        -append "console=ttyAMA0 root=/dev/ram init=/init panic=5" \
        -nographic \
        2>qemu-errors.log
}

# Redirect QEMU's own stderr (device errors etc.) to a log file.
# If this environment cannot bind a host port, retry without forwarding.
set +e
run_qemu "user,id=net0,hostfwd=tcp:127.0.0.1:${UI_PORT}-:7080"
QEMU_STATUS=$?
if [ "$QEMU_STATUS" -ne 0 ] &&
   grep -q "Could not set up host forwarding rule" qemu-errors.log; then
    echo "UI port forwarding unavailable; retrying console-only."
    run_qemu "user,id=net0"
    QEMU_STATUS=$?
fi
set -e

# After VM exits, show any QEMU-level errors
if [ -s qemu-errors.log ]; then
    echo ""
    echo "=== QEMU device errors (qemu-errors.log) ==="
    cat qemu-errors.log
fi

exit "$QEMU_STATUS"
