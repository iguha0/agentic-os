# Kernel Drivers — Setup Guide

The Alpine `linux-virt` kernel ships virtio and 9p as **loadable modules** (not built-in).
Without them the VM cannot mount block devices or 9p shares, so the model disk never loads.

This is a one-time setup you run on your Mac.

---

## Step 1 — Download the kernel modules (on your Mac)

```bash
cd agentic-os-qemu
./scripts/get-kernel-modules.sh
```

This downloads the Alpine `linux-virt` package for aarch64 and extracts:

- `virtio.ko` — base virtio bus
- `virtio_ring.ko` — virtio ring buffer
- `virtio_pci.ko` — virtio PCI transport
- `virtio_blk.ko` — **block device driver** (needed to mount the model disk)
- `9pnet.ko` — Plan 9 network protocol
- `9pnet_virtio.ko` — virtio 9p transport
- `9p.ko` — **9p filesystem** (needed for QEMU host folder sharing)

Modules are saved to `modules/<kernel-version>/`.

---

## Step 2 — Inject modules into the initramfs (on your Mac)

```bash
./scripts/add-modules-to-initramfs.sh
```

This copies the modules into `rootfs/lib/modules/<kver>/` and rebuilds `initramfs.cpio`.

---

## Step 3 — Boot and verify

```bash
./test-interactive.sh
```

At boot you should see:

```
[agentic-init] loading kernel modules...
[agentic-init] model ready: model.gguf (... bytes) from /dev/vda
```

If you see `model drive not found`, the module loaded but there's no disk attached.
Make sure your model file is in `agentic-os-qemu/models/` — the launch script
mounts that folder automatically via 9p.

---

## Troubleshooting

**"modprobe: module not found"**
The kernel version in the modules folder doesn't match the running kernel.
Run `get-kernel-modules.sh` again — it auto-detects the right version.

**Model disk mounts but model not found**
The glob pattern looks for `*.gguf`. Make sure your model file ends in `.gguf`.
Rename if needed: `mv models/mymodel models/model.gguf`

**9p mount fails**
Make sure `test-interactive.sh` includes `-virtfs` or `-fsdev` flags pointing to `./models`.
Check: `grep -i 9p test-interactive.sh`

---

## Model disk (alternative to 9p)

If you want to attach the model as a real block device instead of a 9p share:

```bash
# Create a disk image from your model file
qemu-img create -f raw models/model-disk.img 10G
# Format it
mkfs.ext4 models/model-disk.img
# Mount and copy
mkdir /tmp/mnt
mount -o loop models/model-disk.img /tmp/mnt
cp models/model.gguf /tmp/mnt/
umount /tmp/mnt
```

Then add to your QEMU launch command:
```bash
-drive file=models/model-disk.img,format=raw,if=virtio
```

The `virtio_blk` module will detect `/dev/vda` automatically at boot.
