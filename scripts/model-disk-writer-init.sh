#!/bin/sh
set -eu

MODEL_NAME="Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
HOST_MODEL="/host/$MODEL_NAME"
HOST_SERVER="/host/build-llama-server-aarch64-os/bin/llama-server"
DISK="/mnt/model-disk"

echo "[model-writer] booting"

mount -t proc none /proc 2>/dev/null || true
mount -t sysfs none /sys 2>/dev/null || true
mount -t devtmpfs none /dev 2>/dev/null || true
mount -t tmpfs none /tmp 2>/dev/null || true

load_mod() {
    modprobe "$1" >/dev/null 2>&1 || true
}

load_mod failover
load_mod net_failover
load_mod virtio_net
load_mod virtio_blk
load_mod netfs
load_mod fscache
load_mod crc32c_generic
load_mod crc32_generic
load_mod libcrc32c
load_mod crc16
load_mod mbcache
load_mod jbd2
load_mod ext4
load_mod 9pnet
load_mod 9pnet_virtio
load_mod 9p

sleep 2

mkdir -p /host "$DISK"

echo "[model-writer] mounting host 9p share"
mount -t 9p -o trans=virtio,version=9p2000.L hostshare /host

echo "[model-writer] mounting model disk"
mount -t ext4 -o rw /dev/vda "$DISK"

test -f "$HOST_MODEL"
test -f "$HOST_SERVER"

echo "[model-writer] source model: $(stat -c %s "$HOST_MODEL") bytes"
echo "[model-writer] source server: $(stat -c %s "$HOST_SERVER") bytes"

mkdir -p "$DISK/usr/local/bin"
find "$DISK" -maxdepth 6 -type f -iname "*.gguf" -exec rm -f {} \;

echo "[model-writer] copying model"
cp "$HOST_MODEL" "$DISK/$MODEL_NAME.tmp"
mv "$DISK/$MODEL_NAME.tmp" "$DISK/$MODEL_NAME"

echo "[model-writer] copying llama-server"
cp "$HOST_SERVER" "$DISK/usr/local/bin/llama-server.tmp"
mv "$DISK/usr/local/bin/llama-server.tmp" "$DISK/usr/local/bin/llama-server"
chmod 755 "$DISK/usr/local/bin/llama-server"

echo "[model-writer] copied model: $(stat -c %s "$DISK/$MODEL_NAME") bytes"
echo "[model-writer] copied server: $(stat -c %s "$DISK/usr/local/bin/llama-server") bytes"

sync
umount "$DISK"
umount /host

echo "[model-writer] complete; powering off"
poweroff -f
sleep 5
echo o > /proc/sysrq-trigger 2>/dev/null || true
while true; do sleep 60; done
