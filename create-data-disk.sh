#!/bin/bash
# Create the writable ext4 disk used for Agentic OS memory and identity.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT="${DATA_DISK:-$SCRIPT_DIR/agentic-data.img}"
SIZE="${DATA_DISK_SIZE:-1G}"
OUTPUT_DIR="$(cd "$(dirname "$OUTPUT")" && pwd)"
OUTPUT_NAME="$(basename "$OUTPUT")"

if [ -e "$OUTPUT" ]; then
    echo "Data disk already exists: $OUTPUT"
    exit 0
fi

command -v qemu-img >/dev/null 2>&1 || {
    echo "ERROR: qemu-img is required."
    exit 1
}

qemu-img create -f raw "$OUTPUT" "$SIZE"

# Prefer Homebrew e2fsprogs full paths if available (avoids PATH issues on macOS)
MKFS=""
DEBUGFS=""
if command -v brew >/dev/null 2>&1; then
  E2FS_PREFIX=$(brew --prefix e2fsprogs 2>/dev/null || true)
  if [ -n "$E2FS_PREFIX" ] && [ -x "$E2FS_PREFIX/sbin/mkfs.ext4" ] && [ -x "$E2FS_PREFIX/sbin/debugfs" ]; then
    MKFS="$E2FS_PREFIX/sbin/mkfs.ext4"
    DEBUGFS="$E2FS_PREFIX/sbin/debugfs"
  fi
fi

if [ -n "$MKFS" ] && [ -n "$DEBUGFS" ]; then
    "$MKFS" -F -L AGENTIC_DATA "$OUTPUT"
    marker=$(mktemp)
    printf 'agentic-data\n' > "$marker"
    "$DEBUGFS" -w -R "write $marker .agentic-data" "$OUTPUT" >/dev/null
    "$DEBUGFS" -w -R "mkdir agentic" "$OUTPUT" >/dev/null
    rm -f "$marker"
elif command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    docker run --rm \
        -v "$OUTPUT_DIR:/work" \
        -e "IMAGE_NAME=$OUTPUT_NAME" \
        alpine:3.19 \
        sh -eu -c '
apk add --no-cache e2fsprogs >/dev/null
mkfs.ext4 -F -L AGENTIC_DATA "/work/$IMAGE_NAME" >/dev/null
printf "agentic-data\n" > /tmp/marker
debugfs -w -R "write /tmp/marker .agentic-data" "/work/$IMAGE_NAME" >/dev/null
debugfs -w -R "mkdir agentic" "/work/$IMAGE_NAME" >/dev/null
'
else
    rm -f "$OUTPUT"
    echo "ERROR: creating ext4 requires mkfs.ext4/debugfs or a running Docker daemon."
    exit 1
fi

echo "Created persistent data disk:"
ls -lh "$OUTPUT"
