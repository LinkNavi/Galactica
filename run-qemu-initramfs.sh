#!/bin/bash
# Launch Galactica with initramfs

KERNEL="galactica-build/boot/vmlinuz-galactica"
INITRAMFS="galactica-initramfs.cpio.gz"

if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found"
    exit 1
fi

if [[ ! -f "$INITRAMFS" ]]; then
    echo "Error: Initramfs not found"
    exit 1
fi

echo "Starting Galactica (initramfs mode)..."
echo "Press Ctrl+A then X to exit"
echo ""

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -m 512M \
    -smp 2 \
    -append "console=ttyS0 init=/sbin/init" \
    -nographic \
    -serial mon:stdio
