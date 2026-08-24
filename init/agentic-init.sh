#!/bin/sh
# Agentic OS — custom init.
# Replaces /sbin/init. Mounts filesystems, mounts the model drive,
# sets up the agent as PID 1, drops to agent shell.
#
# Written to be parseable by busybox ash (no process substitution,
# no redirections on globs in for-loops).

# The model payload can contain any GGUF, but keep a canonical path for
# boot-time llama-server startup and UI status.
MODEL_NAME="Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
MODEL_PATH="/usr/share/agentic/models/$MODEL_NAME"
LEGACY_MODEL_PATH="/usr/share/agentic/models/gemma-4-e4b-it-q4_k_m.gguf"
# Accept any GGUF on the external model payload. The canonical path stays
# stable so existing shell/UI code can keep using MODEL_PATH.
MODEL_GLOB="*.gguf"
LLAMA_SERVER_PATH=""

echo "[agentic-init] booting..."

# Mount pseudo-filesystems. Tolerate "already mounted" / missing devtmpfs
# so this can be re-run safely during debugging.
mount -t proc none /proc 2>/dev/null
mount -t sysfs none /sys 2>/dev/null
mount -t devtmpfs none /dev 2>/dev/null
mount -t tmpfs none /tmp 2>/dev/null
mount -t tmpfs none /run 2>/dev/null

# Setup pseudo-terminals (required for xterm and other apps in graphical mode)
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts -o mode=0620,gid=5,ptmxmode=666 2>/dev/null || true
[ -e /dev/ptmx ] || ln -s /dev/pts/ptmx /dev/ptmx 2>/dev/null || true
chmod 666 /dev/ptmx 2>/dev/null || true

# Hostname
hostname agentic-os 2>/dev/null

case " $(cat /proc/cmdline 2>/dev/null) " in
    *" agentic.mode=graphical "*) AGENTIC_MODE="graphical" ;;
    *)                            AGENTIC_MODE="shell" ;;
esac

load_one_module() {
    name="$1"
    rel="$2"

    if modprobe "$name" >/dev/null 2>&1; then
        echo "[agentic-init] module loaded: $name"
        return 0
    fi

    KVER_DIR=$(ls -d /lib/modules/* 2>/dev/null | head -n 1)
    if [ -n "$KVER_DIR" ] && [ -n "$rel" ]; then
        for ko in "$KVER_DIR/$rel.ko" "$KVER_DIR/$rel.ko.gz"; do
            if [ -f "$ko" ] && insmod "$ko" >/dev/null 2>&1; then
                echo "[agentic-init] module inserted: $name"
                return 0
            fi
        done
    fi

    echo "[agentic-init] module unavailable or built-in: $name"
    return 1
}

# Load kernel modules if /lib/modules exists (Alpine linux-virt package supplies
# virtio_net, virtio_blk, 9p, etc. as modules). We do this before network and
# block-device setup so those devices actually appear.
echo "[agentic-init] loading kernel modules..."
if [ -d /lib/modules ]; then
    load_one_module failover "kernel/net/core/failover" || true
    load_one_module net_failover "kernel/drivers/net/net_failover" || true
    load_one_module virtio_net "kernel/drivers/net/virtio_net" || true
    load_one_module virtio_blk "kernel/drivers/block/virtio_blk" || true
    load_one_module virtio_gpu "kernel/drivers/gpu/drm/virtio/virtio-gpu" || true
    load_one_module virtio_input "kernel/drivers/virtio/virtio_input" || true
    # For good measure, USB input if needed
    load_one_module ehci_pci "kernel/drivers/usb/host/ehci-pci" || true
    load_one_module usbhid "kernel/drivers/hid/usbhid/usbhid" || true
    load_one_module hid_generic "kernel/drivers/hid/hid-generic" || true
    load_one_module netfs "kernel/fs/netfs/netfs" || true
    load_one_module fscache "kernel/fs/fscache/fscache" || true
    load_one_module crc32c_generic "kernel/crypto/crc32c_generic" || true
    load_one_module crc32_generic "kernel/crypto/crc32_generic" || true
    load_one_module libcrc32c "kernel/lib/libcrc32c" || true
    load_one_module crc16 "kernel/lib/crc16" || true
    load_one_module mbcache "kernel/fs/mbcache" || true
    load_one_module jbd2 "kernel/fs/jbd2/jbd2" || true
    load_one_module ext4 "kernel/fs/ext4/ext4" || true
    load_one_module 9pnet "kernel/net/9p/9pnet" || true
    load_one_module 9pnet_virtio "kernel/net/9p/9pnet_virtio" || true
    load_one_module 9p "kernel/fs/9p/9p" || true
    sleep 2
fi

# Mount writable state from a separate ext4 disk when present. The data image
# carries a marker so it cannot be confused with the read-only model payload.
mount_persistent_state() {
    mkdir -p /mnt/agentic-data

    set -- /sys/block/* ""
    for bdev in "$@"; do
        [ -z "$bdev" ] && break
        [ -d "$bdev" ] || continue
        name=$(basename "$bdev")
        case "$name" in
            loop*|ram*|initrd|initramfs) continue ;;
        esac

        if mount -t ext4 -o rw "/dev/$name" /mnt/agentic-data 2>/dev/null; then
            if [ -f /mnt/agentic-data/.agentic-data ]; then
                mkdir -p /mnt/agentic-data/agentic
                if [ ! -f /mnt/agentic-data/agentic/.initialized ]; then
                    cp -a /usr/share/agentic/. /mnt/agentic-data/agentic/ 2>/dev/null || true
                    touch /mnt/agentic-data/agentic/.initialized
                fi
                mount -o bind /mnt/agentic-data/agentic /usr/share/agentic
                echo "[agentic-init] persistent state mounted from /dev/$name"
                return 0
            fi
            umount /mnt/agentic-data 2>/dev/null
        fi
    done

    echo "[agentic-init] persistent state disk not found; state is volatile"
    return 1
}

mount_persistent_state || true

mkdir -p /usr/share/agentic
if command -v openssl >/dev/null 2>&1; then
    /usr/local/bin/gen-identity.sh 2>/dev/null || true
    /usr/local/bin/e2e-encrypt.sh keygen 2>/dev/null || true
fi

# Network setup (QEMU user networking defaults)
ip link set lo up 2>/dev/null
ip link set eth0 up 2>/dev/null
ip addr add 10.0.2.15/24 dev eth0 2>/dev/null
ip route add default via 10.0.2.2 2>/dev/null

# DNS: QEMU user networking provides a forwarder at 10.0.2.3.
mkdir -p /etc
printf 'nameserver 10.0.2.3\nnameserver 8.8.8.8\n' > /etc/resolv.conf

echo "[agentic-init] network interfaces: $(ls /sys/class/net 2>/dev/null | tr '\n' ' ')"
echo "[agentic-init] ip: $(ip addr show eth0 2>/dev/null | grep 'inet ' | awk '{print $2}') default via 10.0.2.2"

# Quick connectivity sanity check (best-effort, not fatal)
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "[agentic-init] external network: reachable (pinged 8.8.8.8)"
else
    echo "[agentic-init] external network: not confirmed (ping to 8.8.8.8 failed)"
fi

mkdir -p /mnt/models /usr/share/agentic/models
MODEL_MOUNTED=0

# Try to mount a device as ext4 read-only, then locate the model by glob
# and symlink it to the canonical path. Echoes "ok:<source>" on success.
try_mount() {
    dev="$1"
    if [ ! -b "$dev" ]; then
        echo "no-device"
        return
    fi
    if mount -t ext4 -o ro "$dev" /mnt/models 2>/dev/null; then
        found=$(find /mnt/models -maxdepth 6 -type f -iname "$MODEL_GLOB" 2>/dev/null | head -n 1)
        if [ -n "$found" ]; then
            echo "ok:$found"
            return
        fi
        umount /mnt/models 2>/dev/null
    fi
    echo "no-match"
}

remember_llama_server() {
    root="$1"
    for candidate in \
        "$root/usr/local/bin/llama-server" \
        "$root/usr/bin/llama-server" \
        "$root/bin/llama-server" \
        "$root/llama-server"; do
        if [ -f "$candidate" ]; then
            chmod +x "$candidate" 2>/dev/null || true
            LLAMA_SERVER_PATH="$candidate"
            return
        fi
    done
}

link_model() {
    source="$1"
    ln -sf "$source" "$MODEL_PATH"
    ln -sf "$source" "$LEGACY_MODEL_PATH"
}

# 1) Enumerate /sys/block/* and try each. The glob may match nothing;
#    guard with a placeholder so the for-loop body never runs in that case.
echo "[agentic-init] scanning for model drive..."
set -- /sys/block/* ""
for bdev in "$@"; do
    [ -z "$bdev" ] && break
    [ -d "$bdev" ] || continue
    name=$(basename "$bdev")
    case "$name" in
        loop*|ram*|initrd|initramfs) continue ;;
    esac
    echo "[agentic-init] trying /dev/$name..."
    result=$(try_mount "/dev/$name")
    case "$result" in
        ok:*)
            MODEL_MOUNTED=1
            MODEL_DEV="/dev/$name"
            SOURCE_FILE="${result#ok:}"
            link_model "$SOURCE_FILE"
            remember_llama_server /mnt/models
            break
            ;;
    esac
done

# 2) Fallback: try common names explicitly.
if [ "$MODEL_MOUNTED" != "1" ]; then
    for dev in /dev/vda /dev/vda1 /dev/sda /dev/sda1 /dev/vdb /dev/sdb; do
        echo "[agentic-init] trying $dev..."
        result=$(try_mount "$dev")
        case "$result" in
            ok:*)
                MODEL_MOUNTED=1
                MODEL_DEV="$dev"
                SOURCE_FILE="${result#ok:}"
                link_model "$SOURCE_FILE"
                remember_llama_server /mnt/models
                break
                ;;
        esac
    done
fi

# 3) 9p filesystem share from QEMU (mount_tag=models). This is the normal
#    path for test-interactive.sh, which exposes $SCRIPT_DIR/models.
if [ "$MODEL_MOUNTED" != "1" ]; then
    echo "[agentic-init] trying 9p mount (mount_tag=models)..."
    mkdir -p /mnt/models-9p
    if mount -t 9p -o trans=virtio,version=9p2000.L,ro models /mnt/models-9p 2>/dev/null; then
        echo "[agentic-init] 9p share mounted"
        found=$(find /mnt/models-9p -maxdepth 2 \( -type f -o -type l \) -iname "$MODEL_GLOB" 2>/dev/null | head -n 1)
        if [ -n "$found" ]; then
            link_model "$found"
            MODEL_MOUNTED=1
            MODEL_DEV="9p(models)"
            remember_llama_server /mnt/models-9p
        else
            echo "[agentic-init] 9p share mounted but model not found; listing share"
            ls -la /mnt/models-9p 2>/dev/null || true
            umount /mnt/models-9p 2>/dev/null
        fi
    else
        echo "[agentic-init] 9p mount failed"
    fi
fi

# 4) Last-resort: model embedded in the initramfs itself.
if [ "$MODEL_MOUNTED" != "1" ]; then
    found=$(find /usr/share/agentic/models -maxdepth 1 -type f -iname "$MODEL_GLOB" 2>/dev/null | head -n 1)
    if [ -n "$found" ] && [ "$found" != "$MODEL_PATH" ]; then
        link_model "$found"
        MODEL_MOUNTED=1
        MODEL_DEV="(initramfs)"
        echo "[agentic-init] model present in initramfs; no bind needed"
    elif [ -f "$MODEL_PATH" ]; then
        ln -sf "$MODEL_PATH" "$LEGACY_MODEL_PATH"
        MODEL_MOUNTED=1
        MODEL_DEV="(initramfs)"
        echo "[agentic-init] model present in initramfs; no bind needed"
    fi
fi

if [ "$MODEL_MOUNTED" = "1" ]; then
    MODEL_SIZE=$(stat -L -c %s "$MODEL_PATH" 2>/dev/null || stat -c %s "$MODEL_PATH" 2>/dev/null)
    echo "[agentic-init] model ready: $MODEL_NAME (${MODEL_SIZE:-0} bytes) from $MODEL_DEV"
    if [ -n "$LLAMA_SERVER_PATH" ] && [ -x "$LLAMA_SERVER_PATH" ]; then
        echo "[agentic-init] starting on-device llama-server: $LLAMA_SERVER_PATH"
        "$LLAMA_SERVER_PATH" \
            -m "$MODEL_PATH" \
            --host 127.0.0.1 \
            --port 8080 \
            --ctx-size 1024 \
            --batch-size 128 \
            --ubatch-size 128 \
            --threads 2 \
            --threads-batch 2 \
            --parallel 1 \
            --cache-ram 0 \
            -ngl 0 \
            --no-mmap \
            --no-warmup \
            >/tmp/llama-server.log 2>&1 &
        i=0
        while [ "$i" -lt 180 ]; do
            if wget -q -T 1 -O - http://127.0.0.1:8080/health >/dev/null 2>&1; then
                echo "[agentic-init] llama-server ready on 127.0.0.1:8080"
                break
            fi
            i=$((i + 1))
            sleep 1
        done
        if [ "$i" -ge 180 ]; then
            echo "[agentic-init] llama-server not ready after 180s; recent log:"
            tail -n 40 /tmp/llama-server.log 2>/dev/null || true
        fi
    else
        echo "[agentic-init] llama-server binary not found on model payload; using host fallback if available"
    fi
else
    echo "[agentic-init] WARNING: model drive not found — llama-server mode is the only local-AI option"
    echo "[agentic-init]   On your Mac run: scripts/run-llama-server.sh"
    echo "[agentic-init]   Then inside the VM type: !llama"
fi

# Start the on-device SearXNG metasearch daemon (provides real web search to the
# agent shell on 127.0.0.1:8888). Mirrors the llama-server lifecycle: launch in
# background, poll health, never block boot. Non-fatal if absent or slow.
start_searxng() {
    SEARX_DIR=/opt/searxng
    SEARX_SETTINGS=/etc/searxng/settings.yml
    if [ ! -x "$SEARX_DIR/bin/python" ] || [ ! -f "$SEARX_SETTINGS" ]; then
        echo "[agentic-init] SearXNG not installed; agent web search uses fallback"
        return 0
    fi

    # Generate a fresh secret key on boot if the placeholder is still present.
    if grep -q 'PLACEHOLDER_SECRET' "$SEARX_SETTINGS" 2>/dev/null; then
        SECRET=$(openssl rand -hex 32 2>/dev/null || \
                 head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
        sed -i "s/PLACEHOLDER_SECRET/$SECRET/" "$SEARX_SETTINGS" 2>/dev/null || true
    fi

    echo "[agentic-init] starting on-device SearXNG on 127.0.0.1:8888..."
    # SearXNG reads os.environ["PATH"] at import; PID1 has no PATH, so set one.
    SEARXNG_SETTINGS_PATH="$SEARX_SETTINGS" \
    PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
        "$SEARX_DIR/bin/python" -m searx.webapp >/tmp/searxng.log 2>&1 &

    i=0
    while [ "$i" -lt 40 ]; do
        if wget -q -T 1 -O - http://127.0.0.1:8888/healthz >/dev/null 2>&1; then
            echo "[agentic-init] SearXNG ready on 127.0.0.1:8888"
            return 0
        fi
        i=$((i + 1))
        sleep 1
    done
    echo "[agentic-init] SearXNG not ready after 40s (non-fatal); recent log:"
    tail -n 20 /tmp/searxng.log 2>/dev/null || true
}

start_graphical_home() {
    echo "[agentic-init] starting graphical home screen..."

    # Bring up web search in the background so it doesn't delay the GUI.
    start_searxng &

    mkdir -p /run/dbus /root/.config/openbox
    export HOME=/root
    export DISPLAY=:0
    export XDG_RUNTIME_DIR=/run/user/0
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"

    dbus-daemon --system --fork >/tmp/dbus.log 2>&1 || true
    /usr/local/bin/ui-server.sh >/tmp/ui-server.log 2>&1

    Xorg :0 -nolisten tcp -noreset >/tmp/xorg.log 2>&1 &
    i=0
    while [ "$i" -lt 30 ]; do
        [ -S /tmp/.X11-unix/X0 ] && break
        i=$((i + 1))
        sleep 1
    done

    if [ ! -S /tmp/.X11-unix/X0 ]; then
        echo "[agentic-init] Xorg failed to start; recent log:"
        tail -n 40 /tmp/xorg.log 2>/dev/null || true
        exec /bin/agentic-shell2
    fi

    # Wait for input devices (tablet/keyboard) to be ready before starting clients
    echo "[agentic-init] waiting for input devices..."
    for i in $(seq 1 30); do
        if ls /dev/input/event* 2>/dev/null | head -1 >/dev/null; then
            echo "[agentic-init] input devices detected"
            echo "[agentic-init] devices: $(ls /dev/input/event* 2>/dev/null)"
            break
        fi
        sleep 0.2
    done
    cat /proc/bus/input/devices 2>/dev/null | grep -E 'Name|Handlers' | head -8 || true

    openbox-session >/tmp/openbox.log 2>&1 &

    # Make sure pointer cursor is visible
    xsetroot -cursor_name left_ptr || true

    CHROMIUM=""
    for candidate in /usr/bin/chromium-browser /usr/bin/chromium; do
        if [ -x "$candidate" ]; then
            CHROMIUM="$candidate"
            break
        fi
    done

    if [ -z "$CHROMIUM" ]; then
        echo "[agentic-init] Chromium is missing; falling back to the agent shell"
        exec /bin/agentic-shell2
    fi

    echo "[agentic-init] Starting Chromium home UI (kiosk with CDP on 9222)..."
    # Launch the kiosk Chromium 
    # Home screen: the local agent web UI (chat/gui).
    "$CHROMIUM" \
        --kiosk \
        --no-sandbox \
        --disable-dev-shm-usage \
        --disable-gpu-sandbox \
        --disable-session-crashed-bubble \
        --disable-translate \
        --no-first-run \
        --password-store=basic \
        --force-device-scale-factor=1 \
        --user-data-dir=/usr/share/agentic/browser-profile \
        --remote-debugging-port=9222 \
        --remote-allow-origins=http://127.0.0.1,http://localhost \
        --app=http://127.0.0.1:7080 \
        >/tmp/chromium-home.log 2>&1 &

    # Wait for Chromium to appear, then force focus/raise multiple times
    # Use multiple search patterns because WM_CLASS can vary
    sleep 2
    for i in 1 2 3 4 5 6 7 8 9 10; do
        if xdotool search --onlyvisible --class "Chromium-browser" windowactivate --sync 2>/dev/null || \
           xdotool search --onlyvisible --class "chromium" windowactivate --sync 2>/dev/null || \
           xdotool search --onlyvisible --name "Agentic" windowactivate --sync 2>/dev/null; then
            echo "[agentic-init] Chromium kiosk focused (attempt $i)"
            break
        fi
        sleep 0.5
    done

    echo "[agentic-init] Launching xterm + agentic shell (you can also use the web home at :7080)"
    # Launch xterm iconic (minimized) AFTER the kiosk has focus
    env SHELL=/bin/sh TERM=xterm /usr/bin/xterm -iconic -geometry 90x28 -fa 'Monospace' -fs 11 -xrm 'XTerm*shell: /bin/sh' -e /bin/sh -c 'exec /bin/agentic-shell2' &

    # Keep PID 1 alive (do not exec xterm directly). If xterm exits we don't want
    # a kernel panic ("Attempted to kill init"). The graphical apps run in background.
    exec /bin/sh -c 'while true; do sleep 86400; done'
}

if [ "$AGENTIC_MODE" = "graphical" ]; then
    start_graphical_home
fi

# Banner
clear
cat <<'BANNER'
================================================================
  AGENTIC OS v0.1.0 — Qwen2.5 1.5B Instruct
  A phone OS where the home screen is an agent.
  This is a real init — no Android, no systemd, just mine.
================================================================
BANNER

echo
echo "Welcome to Agentic OS. The agent is your shell."
echo "Type what you want. Ctrl-D to exit. Type 'help' for commands."
echo "AI commands: !local  !cloud  !auto  !keywords  !mode  !help"
echo

# Drop into the agent shell as PID 1's child
exec /bin/agentic-shell2
