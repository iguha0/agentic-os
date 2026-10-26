#!/bin/bash
# phone/qemu-test.sh — rehearse the real phone install inside QEMU.
#
# Simulates a phone: a vendor "stock" boot.img (generic arm64 kernel standing
# in for the phone kernel) and an eMMC/UFS disk with a GPT partition named
# "userdata". Then does exactly what the install guide does:
#   1. repack the stock boot.img with the PryzentOS ramdisk (build.sh bootimg)
#   2. "flash" pryzent-rootfs.img onto userdata
#   3. boot the repacked boot.img → stage 1 → switch_root → PryzentOS init
# and runs the on-device self test (pryzent.selftest=1).
#
#   phone/qemu-test.sh                 # boot header v2 (most MediaTek phones)
#   BOOT_VERSION=4 phone/qemu-test.sh  # Android 12+ GKI layout
#   MTK=1 BOOT_VERSION=0 phone/qemu-test.sh  # old MediaTek segment headers
#   INTERACTIVE=1 phone/qemu-test.sh   # no self test; agent shell on the
#                                      # serial console (Ctrl-A X quits)
#
# Needs: qemu-system-aarch64, sfdisk, python3; run build.sh rootfs first.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="${OUT:-$HERE/out}"
T="$OUT/qemu-test"
BOOT_VERSION="${BOOT_VERSION:-2}"
KERNEL_URL="http://ports.ubuntu.com/pool/main/l/linux/linux-image-unsigned-6.8.0-147-generic_6.8.0-147.147_arm64.deb"

say() { printf '\033[1;36m[qemu-test]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[qemu-test] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

[ -f "$OUT/pryzent-rootfs.img" ] || die "run phone/build.sh rootfs first"
command -v qemu-system-aarch64 >/dev/null || die "install qemu-system-arm"
mkdir -p "$T" "$OUT/cache"

# 1. A stand-in phone kernel.
KERNEL="${KERNEL:-$OUT/cache/test-kernel.gz}"
if [ ! -f "$KERNEL" ]; then
    say "fetching generic arm64 test kernel"
    deb="$OUT/cache/kernel.deb"
    curl -fsSL -o "$deb" "$KERNEL_URL" || die "download failed; set KERNEL=/path/to/arm64/Image(.gz)"
    x="$OUT/cache/kx"; rm -rf "$x"; mkdir -p "$x"
    dpkg-deb --fsys-tarfile "$deb" | tar -x -C "$x" --wildcards './boot/vmlinuz-*'
    cp "$x"/boot/vmlinuz-* "$KERNEL"; rm -rf "$x" "$deb"
fi

# 2. A fake vendor boot.img with the vendor's own (Android) ramdisk.
say "making stand-in stock boot.img (header v$BOOT_VERSION${MTK:+, MediaTek})"
mkdir -p "$T/stock-rd"; echo "android-init" > "$T/stock-rd/init"
python3 "$HERE/tools/mkcpio.py" "$T/stock-rd" "$T/stock-ramdisk.gz"
python3 "$HERE/tools/bootimg.py" create --kernel "$KERNEL" --ramdisk "$T/stock-ramdisk.gz" \
    --version "$BOOT_VERSION" ${MTK:+--mtk} -o "$T/stock-boot.img" \
    --cmdline "console=ttyAMA0 androidboot.hardware=mt6765" >/dev/null

# 3. The real repack step from the install guide.
OUT="$OUT" "$HERE/build.sh" bootimg STOCK_BOOT="$T/stock-boot.img" | tail -n 1

# 4. Pull kernel/ramdisk/cmdline back out (what the bootloader would load).
rm -rf "$T/unpacked"
python3 "$HERE/tools/bootimg.py" unpack "$OUT/pryzent-boot.img" "$T/unpacked" >/dev/null
if command -v unpack_bootimg >/dev/null; then   # independent AOSP parser
    unpack_bootimg --boot_img "$OUT/pryzent-boot.img" --out "$T/aosp" >/dev/null ||
        die "AOSP unpack_bootimg rejected the repacked image"
    # (with MTK=1 AOSP keeps the 512-byte MediaTek header; ours strips it)
    cmp -s "$T/aosp/ramdisk" "$T/unpacked/ramdisk" || [ -n "${MTK:-}" ] ||
        die "AOSP parser sees a different ramdisk"
    say "AOSP unpack_bootimg agrees with the repacked image"
fi
CMDLINE="$(tr -d '\0' < "$T/unpacked/cmdline")"
say "boot cmdline: $CMDLINE"

# 5. Phone storage: GPT with boot + userdata, rootfs "flashed" to userdata.
RSZ=$(stat -c %s "$OUT/pryzent-rootfs.img")
DISK="$T/emmc.img"
rm -f "$DISK"
truncate -s $(( RSZ + 64 * 1024 * 1024 )) "$DISK"
printf 'label: gpt\nstart=2048, size=32768, name=boot\nstart=34816, size=%d, name=userdata\n' \
    $(( RSZ / 512 )) | sfdisk -q "$DISK"
dd if="$OUT/pryzent-boot.img" of="$DISK" bs=512 seek=2048 conv=notrunc status=none
dd if="$OUT/pryzent-rootfs.img" of="$DISK" bs=512 seek=34816 conv=notrunc status=none

# 6. Boot.
EXTRA="pryzent.selftest=1"
[ -n "${INTERACTIVE:-}" ] && EXTRA=""
say "booting (log: $T/serial.log)"
set +e
timeout "${TIMEOUT:-420}" qemu-system-aarch64 -M virt -cpu cortex-a72 -smp 4 -m 2G \
    -kernel "$T/unpacked/kernel" -initrd "$T/unpacked/ramdisk" \
    -append "$CMDLINE $EXTRA" \
    -drive if=none,file="$DISK",format=raw,id=emmc -device virtio-blk-pci,drive=emmc \
    -nographic -no-reboot ${INTERACTIVE:+-serial mon:stdio} \
    $( [ -n "${INTERACTIVE:-}" ] || echo "-serial file:$T/serial.log -monitor none" )
set -e
[ -n "${INTERACTIVE:-}" ] && exit 0

grep -aE 'pryzent-stage1|agentic-init\] platform|SELFTEST' "$T/serial.log" | sed 's/^/    /'
grep -aq 'SELFTEST RESULT: ALL PASS' "$T/serial.log" || die "self test did not pass (see $T/serial.log)"
say "PASS: phone boot flow works (boot.img v$BOOT_VERSION${MTK:+ MediaTek})"
