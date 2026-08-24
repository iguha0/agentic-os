#!/bin/sh
# download-model.sh — fetch the Qwen2.5-1.5B-Instruct GGUF (Apache-2.0)
# and package it as the read-only model disk PryzentOS boots from.
set -e

MODEL_URL="${MODEL_URL:-https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf}"
OUT="${1:-models/Qwen2.5-1.5B-Instruct-Q4_K_M.gguf}"
DISK="model-disk-qwen.img"

mkdir -p "$(dirname "$OUT")"

if [ -f "$OUT" ]; then
    echo "[model] already present: $OUT"
else
    echo "[model] downloading Qwen2.5-1.5B-Instruct (Q4_K_M, ~1.0GB)…"
    wget -q --show-progress -O "$OUT" "$MODEL_URL"
fi

echo "[model] building $DISK (4GB ext4)…"
qemu-img create -f raw "$DISK" 4G
mkfs.ext4 -F "$DISK"
TMP=$(mktemp -d)
mount -o loop "$DISK" "$TMP" 2>/dev/null || {
    echo "[model] NOTE: auto-mount needs root/linux. On macOS use:"
    echo "        ./create-model-disk.sh helper or attach manually."
    rmdir "$TMP"; exit 0
}
mkdir -p "$TMP/usr/local/bin" "$TMP/usr/share/agentic/models"
cp "$OUT" "$TMP/usr/share/agentic/models/$(basename "$OUT")"
umount "$TMP"; rmdir "$TMP"
echo "[model] done: $DISK"
