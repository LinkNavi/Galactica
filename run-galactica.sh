#!/usr/bin/env bash
set -euo pipefail

KERNEL="${KERNEL:-galactica-build/boot/vmlinuz-galactica}"
ROOTFS="${ROOTFS:-galactica-rootfs.img}"
MEM="${MEM:-512M}"
CPUS="${CPUS:-2}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

command -v "$QEMU_BIN" >/dev/null 2>&1 || { echo "qemu not found"; exit 2; }
[[ -f "$KERNEL" ]] || { echo "Kernel not found: $KERNEL"; exit 3; }
[[ -f "$ROOTFS" ]] || { echo "Rootfs not found: $ROOTFS"; exit 4; }

cat <<'EOF'
=== Galactica Boot ===
  1) GUI window (GTK + virtio-vga)
  2) VNC :1 (port 5901) + QXL
  3) SPICE port 5930 + QXL
  4) Headless serial (no display)
  5) Debug (loglevel=7 on serial)
  6) Emergency shell (init=/bin/sh)
EOF
read -r -p "Select (1-6) [1]: " mode
mode="${mode:-1}"

QEMU_ARGS=(
    -kernel "$KERNEL"
    -drive  "file=$ROOTFS,format=raw,if=virtio"
    -m      "$MEM"
    -smp    "$CPUS"
    -serial "mon:stdio"
    -enable-kvm
)
NET_ARGS=(-netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22" -device virtio-net-pci,netdev=net0)
BASE_APPEND="root=/dev/vda rw console=ttyS0"

case "$mode" in
    1)
        QEMU_ARGS+=(-display gtk -vga virtio -usb -device usb-tablet -device usb-kbd "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND console=tty0 init=/sbin/init quiet"
        ;;
    2)
        QEMU_ARGS+=(-vnc :1 -device qxl "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init quiet"
        ;;
    3)
        QEMU_ARGS+=(-spice port=5930,addr=127.0.0.1,disable-ticketing -device qxl "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init quiet"
        ;;
    4)
        QEMU_ARGS+=(-nographic "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init quiet"
        ;;
    5)
        QEMU_ARGS+=(-nographic "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init debug loglevel=7"
        ;;
    6)
        QEMU_ARGS+=(-nographic "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/bin/sh"
        ;;
    *)
        echo "Invalid choice"; exit 5 ;;
esac

echo "Launching QEMU..."
exec "$QEMU_BIN" "${QEMU_ARGS[@]}" -append "$APPEND"
