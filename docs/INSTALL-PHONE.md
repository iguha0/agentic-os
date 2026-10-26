# Installing PryzentOS on a phone (Lava and other MediaTek phones)

PryzentOS **replaces Android completely**. Nothing from Android runs: no
Android init, no `/system`, no Google services. The only thing kept from the
phone's original software is its **Linux kernel**, because that is where the
drivers for this exact phone's screen, touchscreen, storage and battery live.
Everything above the kernel is PryzentOS:

```
 ┌──────────────── boot partition (pryzent-boot.img) ────────────────┐
 │  Lava's own kernel + device tree   +   PryzentOS stage-1 ramdisk   │
 └──────────────────────────────┬────────────────────────────────────┘
                                │ finds "userdata", switch_root
 ┌──────────────── userdata partition (pryzent-rootfs.img) ──────────┐
 │  PryzentOS: agentic-init → agent, on-device LLM, AgentoNet,        │
 │  touch home screen (Chromium kiosk), Wi-Fi settings, …             │
 └───────────────────────────────────────────────────────────────────┘
```

> ⚠️ **This wipes the phone.** Use a phone you do not need. Unlocking the
> bootloader erases all data, and installing PryzentOS overwrites the
> `userdata` partition. Make the backup in step 1 so you can return to Android.

---

## What to expect

| Part | Status on a typical Lava (MediaTek) phone |
|---|---|
| Boot, storage, PryzentOS init, agent, web UI | ✅ works (tested end to end in QEMU, see below) |
| Screen | ✅ usually: the framebuffer `/dev/fb0` exists on almost every Android kernel |
| Touch | ✅ usually: touch drivers are in the kernel |
| USB networking + debug shell to a PC | ✅ if the kernel has USB gadget support (nearly all do) |
| Internet through the PC over USB | ✅ |
| Wi-Fi | ⚠️ maybe: MediaTek Wi-Fi needs firmware from Android's vendor partition (see Wi-Fi below) |
| Calls / SMS / mobile data | ❌ not yet: needs a modem stack |
| Camera, GPU acceleration, sleep | ❌ not yet |

PostmarketOS-style "downstream" ports always start like this: boot and
display first, then one driver at a time.

---

## 0. Identify your phone

On the phone: **Settings → About phone**. Note the **model** (for example
"Lava Blaze 5G", "Lava Agni 2", "Lava Yuva 3"). To get the chipset:

```bash
# on the PC, with USB debugging enabled on the phone
adb shell getprop ro.product.model
adb shell getprop ro.board.platform     # mt67xx / mt68xx = MediaTek, ums/sp = Unisoc
adb shell getprop ro.build.version.release
```

* **MediaTek** (`mt…`): supported by this guide.
* **Unisoc** (`ums…`, `sp…`, `sc…`): bootloader unlocking needs a token
  signed by the manufacturer, which Lava does not hand out. Usually impossible.

## 1. Set up the PC and back up the phone

You need **Linux** (Ubuntu 24.04), or **Windows 10/11 with WSL2 (Ubuntu
24.04)**. On a Mac, use an Ubuntu VM or a Linux PC.

```bash
sudo apt install git python3 curl e2fsprogs android-sdk-libsparse-utils \
    gcc-aarch64-linux-gnu g++-aarch64-linux-gnu cmake \
    qemu-user-static binfmt-support adb fastboot fdisk qemu-system-arm
pip install git+https://github.com/bkerler/mtkclient   # MediaTek tool (backup + unlock)
git clone <this repository> && cd agentic-os
```

**Back up every partition** with [mtkclient](https://github.com/bkerler/mtkclient)
(power the phone off, then hold **Vol+ and Vol−** while plugging in USB):

```bash
mtk rl lava-backup/        # dumps all partitions, including boot and vbmeta
```

Keep `lava-backup/` safe. It is your way back to Android.

## 2. Get the stock `boot.img`

From your backup: `lava-backup/boot.bin` (A/B phones: `boot_a.bin`). Copy it:

```bash
cp lava-backup/boot.bin ~/lava-boot.img      # or boot_a.bin
python3 phone/tools/bootimg.py info ~/lava-boot.img
```

The `info` output shows the header version and kernel command line. Keep it;
it is useful if you need help.

(Alternative: extract `boot.img` from Lava's official firmware package for
**exactly** your model and build number.)

## 3. Unlock the bootloader

1. Settings → About phone → tap **Build number** 7 times → Developer options.
2. Enable **OEM unlocking** and **USB debugging**.
3. On the PC:
   ```bash
   adb reboot bootloader
   fastboot flashing unlock        # older phones: fastboot oem unlock
   ```
   Confirm on the phone with the volume keys.

If fastboot refuses, use mtkclient instead (phone off, Vol+ and Vol− while
plugging in):
```bash
mtk da seccfg unlock
```

## 4. Disable verified boot

The phone checks that `boot` is signed by Lava; PryzentOS is not. Turn the
check off with the phone's own `vbmeta` image:

```bash
cp lava-backup/vbmeta.bin ~/lava-vbmeta.img
fastboot --disable-verity --disable-verification flash vbmeta ~/lava-vbmeta.img
```

(A/B phones: flash `vbmeta_a` and `vbmeta_b`.)

## 5. Build PryzentOS for your phone

```bash
./download-model.sh                     # Qwen2.5-1.5B (≈1 GB) → models/
sudo phone/build.sh llama               # on-device AI server (≈10 min)
sudo phone/build.sh all STOCK_BOOT=~/lava-boot.img
```

Output in `phone/out/`:

| File | Goes to | What it is |
|---|---|---|
| `pryzent-boot.img` | `boot` | Lava kernel + PryzentOS stage 1 |
| `pryzent-rootfs.simg` | `userdata` | The whole OS (sparse image) |

Want to rehearse first? `sudo phone/qemu-test.sh` boots the exact same
images in an emulator that pretends to be a phone, and runs the self test.

## 6. Test the screen without installing (optional, safe)

```bash
adb reboot bootloader       # or: power off, then Vol− + Power
fastboot boot phone/out/pryzent-boot.img
```

This boots PryzentOS's stage 1 **once** without writing anything. Since
`userdata` does not contain PryzentOS yet, you should see:

> **PryzentOS** / *Boot failed* / *…is not a PryzentOS ext4 filesystem…*

**This is the good result.** It proves your Lava kernel, the PryzentOS
ramdisk and the display all work. Hold **Power** for ~10 s to reboot.

* Black screen: see Troubleshooting.
* `fastboot boot` is not supported on many MediaTek phones (`unknown command`).
  That's normal; skip this step.

## 7. Install

```bash
fastboot flash userdata phone/out/pryzent-rootfs.simg
fastboot flash boot     phone/out/pryzent-boot.img     # A/B phones: --slot=all
fastboot reboot
```

First boot shows *"expanding storage"* briefly (the image grows to fill the
whole `userdata` partition), then the PryzentOS home screen.

## 8. Using it

* **Home screen**: tap apps; the 🤖 Agent is the main interface.
* **Wi-Fi**: ⚙️ Settings → 📶 Wi-Fi → *Scan* → tap a network → password → *Join*.
* **From a PC over USB**: plug in the cable; the PC gets a network adapter.
  * Web UI: <http://172.16.42.1:7080>
  * Root shell: `telnet 172.16.42.1` (only reachable over the cable; disable
    with `touch /usr/share/agentic/no-usb-shell`)
* **Internet through the PC** (when Wi-Fi does not work), on the Linux PC:
  ```bash
  sudo sysctl -w net.ipv4.ip_forward=1
  sudo iptables -t nat -A POSTROUTING -o <your-internet-interface> -j MASQUERADE
  telnet 172.16.42.1      # then on the phone:
  pryzent-phone usb-internet
  ```
* **Health check**: `pryzent-selftest` in the USB shell.

## Wi-Fi on MediaTek

MediaTek Wi-Fi drivers need firmware files from Android's vendor partition.
If Settings shows *"no Wi-Fi hardware"*:

1. Extract `vendor` from your backup (`lava-backup/vendor.bin`; on Android 10+
   phones it is inside `super.bin`; extract it with `lpunpack` from Android's partition tools).
2. Copy its `firmware/` folder and rebuild:
   ```bash
   sudo mount -o ro,loop vendor.img /mnt
   cp -r /mnt/firmware ~/lava-firmware
   sudo phone/build.sh rootfs FIRMWARE_DIR=~/lava-firmware
   fastboot flash userdata phone/out/pryzent-rootfs.simg
   ```
3. Some MediaTek chips also need Android's `wmt_loader` service to power the
   radio. If Wi-Fi still does not appear, send the logs (below) so support
   can be added for your chip.

## Troubleshooting

| Symptom | Meaning / fix |
|---|---|
| Phone goes straight back to fastboot / bootloops | Verified boot still on: redo step 4. Or the stock `boot.img` is from a different build: take it from *your* backup. |
| "Boot failed: no partition named 'userdata'" | Your phone names it differently. Find it with `grep PARTNAME /sys/class/block/*/uevent` in the USB shell, then `sudo phone/build.sh bootimg STOCK_BOOT=… BOOT_CMDLINE="pryzent.root=<name>"`. |
| "…is not a PryzentOS ext4 filesystem" after step 7 | `userdata` flash failed or was re-encrypted: flash `pryzent-rootfs.simg` again. |
| Black screen, but the PC sees a USB network adapter | Boot works and the display does not. Run `telnet 172.16.42.1`, then `cat /run/pryzent-stage1.log; ls /dev/fb0 /dev/dri`. |
| Black screen, nothing on USB | The kernel ignored the PryzentOS ramdisk. `bootimg.py info` warns if the cmdline has `skip_initramfs` (Android 9 A/B phones); those need a recovery-partition install instead. |
| "Display could not start" | Kernel and agent are fine but X11 failed: `cat /tmp/xorg.log` over USB. |

Logs to collect: `/run/pryzent-stage1.log`, `/var/log/pryzent-stage1.log`,
`/var/log/pryzent.log`, `/tmp/xorg.log`, `dmesg`.

To stop in the stage-1 debug shell without starting PryzentOS:
`sudo phone/build.sh bootimg STOCK_BOOT=… BOOT_CMDLINE="pryzent.debug=1"`.

## Going back to Android

```bash
fastboot flash boot     lava-backup/boot.bin
fastboot flash userdata lava-backup/userdata.bin   # or: fastboot -w
fastboot flash vbmeta   lava-backup/vbmeta.bin
fastboot flashing lock  # optional; wipes again
```

Or restore everything with `mtk wl lava-backup/`.

---

## How it was verified

`phone/qemu-test.sh` rehearses the real install inside QEMU: it builds a
fake vendor `boot.img`, repacks it with `phone/tools/bootimg.py` (cross-checked
by AOSP's `unpack_bootimg`), writes `pryzent-rootfs.img` into a GPT partition
named `userdata`, boots, and runs `pryzent-selftest` on the device. It passes
for boot image header v0 with MediaTek headers, v2 and v4. A vendor-module
(GKI `modules.load`) boot with a 720×1600 framebuffer showed the PryzentOS
splash screen.

**Not yet verified:** real Lava hardware, the `PACKAGES=full` build (Chromium
touch UI, Wi-Fi stack) and `phone/build.sh llama`. The full build needs
`dl-cdn.alpinelinux.org` and the llama step needs `github.com`; neither could be
run in the build environment used so far.
