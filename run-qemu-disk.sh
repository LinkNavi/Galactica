#!/bin/bash
# Launch Galactica with disk image

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found"
    exit 1
fi

if [[ ! -f "$ROOTFS" ]]; then
    echo "Error: Root filesystem not found"
    exit 1
fi

echo "Starting Galactica (disk mode)..."
echo "Press Ctrl+A then X to exit"
echo ""

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -drive "file=$ROOTFS,format=raw,if=virtio" \
    -m 512M \
    -smp 2 \
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init" \
    -nographic \
    -serial mon:stdio
