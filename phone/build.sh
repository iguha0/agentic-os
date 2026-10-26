#!/bin/bash
# phone/build.sh — build PryzentOS for a real phone.
#
# Produces, in phone/out/:
#   pryzent-initramfs.cpio.gz  first-stage ramdisk (busybox + stage-1 init)
#   pryzent-rootfs.img         the whole OS (ext4) → flash to "userdata"
#   pryzent-rootfs.simg        same, Android sparse format (if img2simg exists)
#   pryzent-boot.img           your phone's kernel + PryzentOS ramdisk → "boot"
#
# Usage:
#   sudo phone/build.sh all  STOCK_BOOT=/path/to/stock/boot.img
#   sudo phone/build.sh <step> [VAR=value ...]
#
# Steps: binaries · initramfs · rootfs · bootimg · llama · all · clean
#
# Variables (env or VAR=value args):
#   STOCK_BOOT      the phone's original boot.img (from its firmware package)
#   BOOT_CMDLINE    extra kernel args, e.g. "pryzent.root=<partition>" or
#                   "pryzent.debug=1"
#   PACKAGES        full (default: touch UI, Wi-Fi, Chromium…) | minimal
#   MODEL           .gguf to bundle (default: first models/*.gguf if present)
#   LLAMA_SERVER    aarch64 llama-server binary (default: out/bin/llama-server
#                   if `build.sh llama` was run)
#   ALPINE_VERSION  base distribution release (default 3.20)
#   ALPINE_MIRROR   default https://dl-cdn.alpinelinux.org/alpine
#   FIRMWARE_DIR    vendor firmware to bundle into /lib/firmware (e.g. Wi-Fi
#                   blobs copied from the stock vendor partition)
#   ROOTFS_FREE_MB  free space left in the image before first-boot grow (512)
#   CROSS_CC        aarch64 C compiler (default: autodetect)
#
# Runs on Linux (Ubuntu/Debian, or WSL2 on Windows) as root. On x86 hosts it
# needs qemu-user-static (binfmt) to run arm64 package installs.
#
# Copyright (C) Indrajit Guha — AGPL-3.0
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

for kv in "$@"; do
    case "$kv" in *=*) export "${kv?}" ;; esac
done
STEPS=()
for a in "$@"; do case "$a" in *=*) ;; *) STEPS+=("$a") ;; esac; done
[ ${#STEPS[@]} -gt 0 ] || STEPS=(all)

OUT="${OUT:-$HERE/out}"
CACHE="$OUT/cache"
PACKAGES="${PACKAGES:-full}"
ALPINE_VERSION="${ALPINE_VERSION:-3.20}"
ALPINE_MIRROR="${ALPINE_MIRROR:-https://dl-cdn.alpinelinux.org/alpine}"
ROOTFS_FREE_MB="${ROOTFS_FREE_MB:-512}"
PRYZENT_VERSION="0.4.0-phone"

# Static aarch64 busybox for the first-stage ramdisk (Ubuntu 24.04 build).
BUSYBOX_URL="http://ports.ubuntu.com/pool/main/b/busybox/busybox-static_1.36.1-6ubuntu3.1_arm64.deb"
BUSYBOX_SHA256="d96535e0402c011e0ee43449799df2f4504d44b842e4f2b3a6cbc845508eaafc"

# Packages for the full phone OS (Alpine names).
PKGS_BASE="busybox-extras openssl ca-certificates curl wget python3 py3-qrcode
    wpa_supplicant iw wireless-regdb e2fsprogs-extra eudev tzdata"
PKGS_GUI="xorg-server xf86-video-fbdev xf86-input-libinput xf86-input-evdev
    mesa-dri-gallium openbox chromium xdotool xset xsetroot dbus dbus-x11
    fontconfig ttf-dejavu font-noto-emoji svkbd"

say()  { printf '\033[1;35m[pryzent]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[pryzent] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "missing tool '$1'. $2"; }

mkdir -p "$OUT/bin" "$CACHE"

# ── binaries ────────────────────────────────────────────────────────────────
find_cc() {
    if [ -n "${CROSS_CC:-}" ]; then echo "$CROSS_CC"; return; fi
    if [ "$(uname -m)" = "aarch64" ] && command -v gcc >/dev/null; then echo gcc; return; fi
    for c in aarch64-linux-gnu-gcc aarch64-linux-musl-gcc /opt/homebrew/bin/aarch64-linux-musl-gcc; do
        command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }
    done
    die "no aarch64 C compiler. Ubuntu: sudo apt install gcc-aarch64-linux-gnu"
}

step_binaries() {
    CC=$(find_cc)
    say "compiling PryzentOS programs with $CC"
    CFLAGS="-static -Os -s -D_GNU_SOURCE -w"
    $CC $CFLAGS -o "$OUT/bin/agentic-shell2" "$REPO/shell2/agentic-shell2.c"
    $CC $CFLAGS -o "$OUT/bin/aghttpd"        "$REPO/ui/aghttpd.c"
    $CC $CFLAGS -o "$OUT/bin/agbrowser"      "$REPO/browser/agbrowser.c"
    $CC $CFLAGS -I "$HERE/splash" -o "$OUT/bin/pryzent-splash" "$HERE/splash/pryzent-splash.c"
    ls -lh "$OUT/bin"
}

# ── first-stage ramdisk ─────────────────────────────────────────────────────
fetch_busybox() {
    BB="$CACHE/busybox"
    [ -x "$BB" ] && return
    say "fetching static busybox (arm64)"
    deb="$CACHE/busybox-static.deb"
    curl -fsSL -o "$deb" "$BUSYBOX_URL" || wget -q -O "$deb" "$BUSYBOX_URL" ||
        die "could not download $BUSYBOX_URL"
    echo "$BUSYBOX_SHA256  $deb" | sha256sum -c - >/dev/null || die "busybox checksum mismatch"
    x="$CACHE/bb-x"; rm -rf "$x"; mkdir -p "$x"
    if command -v dpkg-deb >/dev/null 2>&1; then
        dpkg-deb --fsys-tarfile "$deb" | tar -x -C "$x" ./usr/bin/busybox
    else
        need zstd "install zstd (or dpkg)"
        (cd "$x" && ar x "$deb" && zstd -dc data.tar.zst | tar -x ./usr/bin/busybox)
    fi
    cp "$x/usr/bin/busybox" "$BB"; chmod 755 "$BB"; rm -rf "$x" "$deb"
}

step_initramfs() {
    [ -x "$OUT/bin/pryzent-splash" ] || step_binaries
    fetch_busybox
    say "building first-stage ramdisk"
    S="$OUT/initramfs"
    rm -rf "$S"; mkdir -p "$S/bin" "$S/dev" "$S/proc" "$S/sys" "$S/run" "$S/tmp" "$S/sysroot"
    cp "$CACHE/busybox" "$S/bin/busybox"
    ln -s busybox "$S/bin/sh"
    cp "$OUT/bin/pryzent-splash" "$S/bin/pryzent-splash"
    cp "$HERE/initramfs/init" "$S/init"; chmod 755 "$S/init"
    python3 "$HERE/tools/mkcpio.py" "$S" "$OUT/pryzent-initramfs.cpio.gz" \
        --node /dev/console:600:5:1 --node /dev/null:666:1:3
    ls -lh "$OUT/pryzent-initramfs.cpio.gz"
}

# ── root filesystem ─────────────────────────────────────────────────────────
alpine_base() {
    T="$CACHE/alpine-$ALPINE_VERSION-aarch64.tar"
    [ -s "$T" ] && { echo "$T"; return; }
    if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
        say "exporting alpine:$ALPINE_VERSION (arm64) from Docker" >&2
        id=$(docker create --platform linux/arm64 "alpine:$ALPINE_VERSION" /bin/true)
        docker export "$id" > "$T"; docker rm "$id" >/dev/null
    else
        say "downloading Alpine $ALPINE_VERSION minirootfs" >&2
        base="$ALPINE_MIRROR/v$ALPINE_VERSION/releases/aarch64"
        f=$(curl -fsSL "$base/latest-releases.yaml" | sed -n 's/^ *file: *\(alpine-minirootfs-.*\)/\1/p' | head -n 1)
        [ -n "$f" ] || die "cannot reach $base (set ALPINE_MIRROR or install Docker)"
        curl -fsSL "$base/$f" | gunzip > "$T"
    fi
    echo "$T"
}

step_rootfs() {
    [ "$(id -u)" = 0 ] || die "the rootfs step must run as root (sudo) to keep file ownership"
    [ -x "$OUT/bin/aghttpd" ] || step_binaries
    need mke2fs "Ubuntu: sudo apt install e2fsprogs"
    S="$OUT/rootfs"
    say "assembling root filesystem in $S"
    rm -rf "$S"; mkdir -p "$S"
    tar -xpf "$(alpine_base)" -C "$S"
    chroot "$S" /bin/busybox true 2>/dev/null ||
        die "cannot run arm64 programs. Ubuntu: sudo apt install qemu-user-static binfmt-support"

    if [ "$PACKAGES" = "full" ]; then
        say "installing packages (this downloads ~400 MB)"
        printf '%s/v%s/main\n%s/v%s/community\n' "$ALPINE_MIRROR" "$ALPINE_VERSION" \
            "$ALPINE_MIRROR" "$ALPINE_VERSION" > "$S/etc/apk/repositories"
        cp /etc/resolv.conf "$S/etc/resolv.conf"
        mount --bind /dev "$S/dev"; mount -t proc proc "$S/proc"
        trap 'umount "$S/dev" "$S/proc" 2>/dev/null || true' EXIT
        # shellcheck disable=SC2086
        chroot "$S" /sbin/apk add --no-cache $PKGS_BASE $PKGS_GUI ||
            die "package install failed (network?). Retry, or use PACKAGES=minimal"
        umount "$S/dev" "$S/proc"; trap - EXIT
    else
        say "PACKAGES=minimal: no touch UI / Wi-Fi stack (USB web UI only)"
    fi

    say "installing PryzentOS"
    PRYZENT_ROOT="$S" PRYZENT_BIN="$OUT/bin" bash "$REPO/scripts/install-rootfs.sh"
    cp -r "$HERE/rootfs/." "$S/"
    cp "$OUT/bin/pryzent-splash" "$S/usr/local/bin/pryzent-splash"
    chmod 755 "$S/usr/local/bin/"*
    mkdir -p "$S/usr/local/share/agentic-ui" "$S/usr/local/share/agentic-ui/cgi-bin"
    cp "$REPO/ui/home.html" "$S/usr/local/share/agentic-ui/home.html"
    mkdir -p "$S/usr/share/agentic/models" "$S/var/log" "$S/root"
    echo pryzent > "$S/etc/hostname"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$S/etc/resolv.conf"
    rev=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null || echo unknown)
    echo "PryzentOS $PRYZENT_VERSION ($PACKAGES, git $rev, built $(date -u +%Y-%m-%d))" \
        > "$S/etc/pryzent-release"

    model="${MODEL:-$(ls "$REPO"/models/*.gguf 2>/dev/null | head -n 1 || true)}"
    if [ -n "$model" ] && [ -f "$model" ]; then
        say "bundling model $(basename "$model")"
        cp "$model" "$S/usr/share/agentic/models/"
    else
        say "no .gguf model bundled (run ./download-model.sh or set MODEL=)"
    fi
    if [ -n "${FIRMWARE_DIR:-}" ]; then
        [ -d "$FIRMWARE_DIR" ] || die "FIRMWARE_DIR not found: $FIRMWARE_DIR"
        say "bundling vendor firmware from $FIRMWARE_DIR"
        mkdir -p "$S/lib/firmware"; cp -r "$FIRMWARE_DIR/." "$S/lib/firmware/"
    fi
    llama="${LLAMA_SERVER:-$OUT/bin/llama-server}"
    if [ -f "$llama" ]; then
        cp "$llama" "$S/usr/local/bin/llama-server"; chmod 755 "$S/usr/local/bin/llama-server"
    else
        say "no llama-server bundled (run: phone/build.sh llama)"
    fi

    size=$(( $(du -sm "$S" | cut -f1) * 110 / 100 + ROOTFS_FREE_MB ))
    IMG="$OUT/pryzent-rootfs.img"
    say "creating ${size} MB ext4 image"
    rm -f "$IMG"
    # Phone kernels can be old (4.x): avoid ext4 features they cannot mount.
    mke2fs -q -F -t ext4 -L PRYZENT_ROOT -d "$S" \
        -O ^metadata_csum,^metadata_csum_seed,^orphan_file "$IMG" "${size}M" 2>/dev/null ||
    mke2fs -q -F -t ext4 -L PRYZENT_ROOT -d "$S" -O ^metadata_csum "$IMG" "${size}M"
    if command -v img2simg >/dev/null 2>&1; then
        img2simg "$IMG" "$OUT/pryzent-rootfs.simg"
    fi
    ls -lh "$OUT"/pryzent-rootfs.*
}

# ── boot image ──────────────────────────────────────────────────────────────
step_bootimg() {
    [ -n "${STOCK_BOOT:-}" ] || die "set STOCK_BOOT=/path/to/your/phone's/boot.img"
    [ -f "$STOCK_BOOT" ] || die "STOCK_BOOT not found: $STOCK_BOOT"
    [ -f "$OUT/pryzent-initramfs.cpio.gz" ] || step_initramfs
    say "stock image:"
    python3 "$HERE/tools/bootimg.py" info "$STOCK_BOOT" | sed 's/^/    /'
    python3 "$HERE/tools/bootimg.py" repack "$STOCK_BOOT" \
        --ramdisk "$OUT/pryzent-initramfs.cpio.gz" -o "$OUT/pryzent-boot.img" \
        --cmdline "pryzent.platform=phone ${BOOT_CMDLINE:-}"
}

# ── llama-server (on-device AI), optional ───────────────────────────────────
step_llama() {
    need cmake "Ubuntu: sudo apt install cmake"
    command -v aarch64-linux-gnu-g++ >/dev/null 2>&1 || [ "$(uname -m)" = aarch64 ] ||
        die "need aarch64-linux-gnu-g++ (Ubuntu: sudo apt install g++-aarch64-linux-gnu)"
    SRC="$CACHE/llama.cpp"
    [ -d "$SRC" ] || git clone --depth 1 https://github.com/ggml-org/llama.cpp "$SRC"
    say "cross-compiling llama-server (static, armv8.2 + dotprod)"
    TC=()
    [ "$(uname -m)" = aarch64 ] || TC=(-DCMAKE_SYSTEM_NAME=Linux -DCMAKE_SYSTEM_PROCESSOR=aarch64
        -DCMAKE_C_COMPILER=aarch64-linux-gnu-gcc -DCMAKE_CXX_COMPILER=aarch64-linux-gnu-g++)
    cmake -S "$SRC" -B "$CACHE/llama-build" "${TC[@]}" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DCMAKE_EXE_LINKER_FLAGS="-static" -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF \
        -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod -DLLAMA_CURL=OFF \
        -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=ON >/dev/null
    cmake --build "$CACHE/llama-build" --target llama-server -j"$(nproc)"
    cp "$CACHE/llama-build/bin/llama-server" "$OUT/bin/llama-server"
    aarch64-linux-gnu-strip "$OUT/bin/llama-server" 2>/dev/null || strip "$OUT/bin/llama-server" || true
    ls -lh "$OUT/bin/llama-server"
}

for s in "${STEPS[@]}"; do
    case "$s" in
        binaries)  step_binaries ;;
        initramfs) step_initramfs ;;
        rootfs)    step_rootfs ;;
        bootimg)   step_bootimg ;;
        llama)     step_llama ;;
        all)
            step_binaries; step_initramfs; step_rootfs
            if [ -n "${STOCK_BOOT:-}" ]; then step_bootimg
            else say "skipping boot image: pass STOCK_BOOT=/path/to/boot.img"; fi
            say "done. Next: docs/INSTALL-PHONE.md" ;;
        clean)     rm -rf "$OUT" ;;
        *) die "unknown step '$s' (binaries initramfs rootfs bootimg llama all clean)" ;;
    esac
done
