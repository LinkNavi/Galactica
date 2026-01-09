#!/bin/bash
KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

[[ ! -f "$KERNEL" || ! -f "$ROOTFS" ]] && { echo "Error: Kernel or rootfs not found!"; exit 1; }

echo "=== Galactica Boot Menu ==="
echo ""
echo "  1) Normal boot (with networking)"
echo "  2) Debug boot (verbose)"
echo "  3) Emergency shell"
echo "  4) No networking"
echo ""
read -p "Select (1-4) [1]: " mode
mode=${mode:-1}

# Base QEMU command - ALWAYS include networking
QEMU_BASE="qemu-system-x86_64 \
    -kernel $KERNEL \
    -drive file=$ROOTFS,format=raw,if=virtio \
    -m 512M \
    -smp 2 \
    -nographic \
    -serial mon:stdio"

# User-mode networking with port forwarding
# - Guest can access internet through host
# - SSH to guest: ssh -p 2222 root@localhost
QEMU_NET="-netdev user,id=net0,hostfwd=tcp::2222-:22 -device e1000,netdev=net0"

case $mode in
    1) 
        echo "Starting with networking..."
        echo "SSH available at: ssh -p 2222 root@localhost"
        echo "Press Ctrl+A then X to exit"
        $QEMU_BASE $QEMU_NET -append "root=/dev/vda rw console=ttyS0 init=/sbin/init quiet"
        ;;
    2) 
        echo "Debug mode with networking..."
        $QEMU_BASE $QEMU_NET -append "root=/dev/vda rw console=ttyS0 init=/sbin/init debug loglevel=7"
        ;;
    3) 
        echo "Emergency shell..."
        $QEMU_BASE $QEMU_NET -append "root=/dev/vda rw console=ttyS0 init=/bin/sh"
        ;;
    4)
        echo "No networking..."
        $QEMU_BASE -append "root=/dev/vda rw console=ttyS0 init=/sbin/init"
        ;;
esac
