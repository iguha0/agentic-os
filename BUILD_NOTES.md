# PryzentOS Build Notes

## Build Issue Resolution

**Problem:** The `agentic-shell` was not compiling for aarch64-linux-musl target.

**Root Cause:** The compilation was missing the `_GNU_SOURCE` define flag, which is required for musl libc to expose the `sync()` function from `<unistd.h>`.

**Solution:** Added `-D_GNU_SOURCE` to the compiler flags, along with `-D_POSIX_C_SOURCE=200112L`.

## Cross-Compiler Setup

The project uses **musl-cross** for aarch64 cross-compilation:

```bash
brew install FiloSottile/musl-cross/musl-cross
```

Compiler path: `/opt/homebrew/bin/aarch64-linux-musl-gcc`

## Build Commands

### Quick Build
```bash
cd /Users/indrajitguha/agentic-os-qemu
./build.sh
```

### Using Make
```bash
make                    # Build for aarch64-musl (default)
make TARGET=native      # Build for host architecture
make clean              # Remove build artifacts
make install            # Install to rootfs/bin/
```

## Build Output

- **Binary:** `build/agentic-shell`
- **Size:** ~67 KB (statically linked, stripped)
- **Architecture:** ARM aarch64
- **Type:** ELF 64-bit LSB executable, statically linked

## Files Created/Modified

1. **Makefile** - Build system with target support
2. **build.sh** - Simple build script
3. **build/agentic-shell** - Compiled binary
4. **rootfs/bin/agentic-shell** - Installed binary

## Compilation Flags

```bash
-static -Os -s \
-Wall -Wextra -Wno-unused-function -Wno-unused-parameter \
-std=gnu11 \
-fno-stack-protector -fomit-frame-pointer \
-I sysroot/usr/include \
-D_GNU_SOURCE -D_POSIX_C_SOURCE=200112L
```

## Next Steps

To boot the OS in QEMU, you would need to:
1. Create a proper rootfs with the agentic-shell
2. Set up the init system
3. Configure the kernel and QEMU command line
4. Test the boot process

See the project's documentation for QEMU setup details.