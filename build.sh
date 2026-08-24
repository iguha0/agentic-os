#!/bin/bash
set -e

# Agentic OS Shell Build Script
# Builds the agentic shell for aarch64-linux-musl target

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "========================================="
echo "  Agentic OS Shell Build"
echo "========================================="

# Check for cross-compiler
COMPILER="/opt/homebrew/bin/aarch64-linux-musl-gcc"
if [ ! -f "$COMPILER" ]; then
    echo "ERROR: aarch64-linux-musl-gcc not found at $COMPILER"
    echo "Install with: brew install FiloSottile/musl-cross/musl-cross"
    exit 1
fi

echo "Using compiler: $COMPILER"
$COMPILER --version | head -1

# Create build directory
mkdir -p build

# Compile shell
echo ""
echo "Compiling agentic-shell..."
$COMPILER \
    -static \
    -Os -s \
    -Wall -Wextra -Wno-unused-function -Wno-unused-parameter \
    -std=gnu11 \
    -fno-stack-protector -fomit-frame-pointer \
    -I sysroot/usr/include \
    -D_GNU_SOURCE -D_POSIX_C_SOURCE=200112L \
    -o build/agentic-shell \
    shell/shell.c shell/stubs.c

echo ""
echo "========================================="
echo "  Build Successful!"
echo "========================================="
echo "Output: $SCRIPT_DIR/build/agentic-shell"
ls -lh build/agentic-shell
echo ""
file build/agentic-shell