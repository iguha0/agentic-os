#!/bin/bash
# Rebuild initramfs.cpio from rootfs/ for Agentic OS.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOTFS_DIR="${SCRIPT_DIR}/../rootfs"
OUTPUT="${SCRIPT_DIR}/../initramfs.cpio"

cd "$ROOTFS_DIR"

# Use a newline-delimited file list so cpio can handle paths with spaces.
find . -print0 | cpio --null -o -H newc > "$OUTPUT"

echo "Built ${OUTPUT}"
ls -lh "$OUTPUT"
