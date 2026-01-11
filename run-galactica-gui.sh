#!/usr/bin/env bash
# galactica-boot.sh — simple, opinionated QEMU launcher
# Author: your friendly VM whisperer
set -euo pipefail
# === Config (edit if you must) ===
KERNEL="${KERNEL:-galactica-build/boot/vmlinuz-galactica}"
ROOTFS="${ROOTFS:-galactica-rootfs.img}"
MEM="${MEM:-512M}"
CPUS="${CPUS:-2}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"   # host port forwarded to guest 22
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
# === sanity checks ===
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
    echo "Error: qemu binary '$QEMU_BIN' not found in PATH." >&2
    exit 2
fi
[[ -f "$KERNEL" ]] || { echo "Error: Kernel not found at: $KERNEL" >&2; exit 3; }
[[ -f "$ROOTFS" ]] || { echo "Error: Rootfs not found at: $ROOTFS" >&2; exit 4; }
cat <<'EOF'
=== Galactica Boot Menu ===
  1) GUI window (GTK) + virtio GPU
  2) VNC server (:1) + QXL (connect with vncviewer localhost:5901)
  3) SPICE (recommended with virtio/ qxl clients)
  4) Headless serial (current behavior; console on terminal)
  5) Debug mode (verbose kernel log on serial)
  6) Emergency shell (init=/bin/sh)
EOF
read -r -p "Select (1-6) [1]: " mode
mode="${mode:-1}"
# Base qemu args common across modes
QEMU_ARGS=(
    -kernel "$KERNEL"
    -drive "file=$ROOTFS,format=raw,if=virtio"
    -m "$MEM"
    -smp "$CPUS"
    -serial "mon:stdio"
    -enable-kvm
)
# Networking (user-mode with SSH host forward)
NET_ARGS=(-netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22" -device virtio-net-pci,netdev=net0)
# Kernel append parameters common
COMMON_APPEND="root=/dev/vda rw console=ttyS0"
case "$mode" in
  1)  # GUI window using GTK and virtio-vga
        echo "Starting GUI (GTK) with virtio-vga..."
        QEMU_ARGS+=( -display gtk -vga virtio )
        QEMU_ARGS+=( -usb -device usb-tablet -device usb-kbd )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND console=tty0 init=/sbin/init quiet"
        ;;
    2)  # VNC server + QXL
        echo "Starting VNC server on :1 (port 5901) with QXL..."
        QEMU_ARGS+=( -vnc :1 -device qxl )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init quiet"
        ;;
    3)  # SPICE + QXL
        echo "Starting SPICE server (port 5930) with QXL..."
        QEMU_ARGS+=( -spice port=5930,addr=127.0.0.1,disable-ticketing -device qxl )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init quiet"
        ;;
    4)  # Headless serial (current default behavior)
        echo "Starting headless (serial). Use SSH on host port ${SSH_HOST_PORT} or use the serial console."
        QEMU_ARGS+=( -nographic )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init quiet"
        ;;
    5)  # Debug kernel log on serial
        echo "Starting debug mode (higher kernel loglevel) on serial..."
        QEMU_ARGS+=( -nographic )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init debug loglevel=7"
        ;;
    6)  # Emergency shell
        echo "Starting emergency shell (init=/bin/sh)..."
        QEMU_ARGS+=( -nographic )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/bin/sh"
        ;;
    *)
        echo "Invalid choice: $mode" >&2
        exit 5
        ;;
esac
# Print the exact command for debugging / reproducibility
echo
echo "QEMU will be launched with:"
printf '  %s\n' "$QEMU_BIN" "${QEMU_ARGS[@]}" -append "\"$APPEND\""
echo
# Finally exec QEMU
exec "$QEMU_BIN" "${QEMU_ARGS[@]}" -append "$APPEND"
