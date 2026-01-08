#!/bin/bash
# Launch Galactica with debug output

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

if [[ ! -f "$KERNEL" ]] || [[ ! -f "$ROOTFS" ]]; then
    echo "Error: Kernel or rootfs not found!"
    exit 1
fi

echo "=== Galactica Debug Boot ==="
echo ""
echo "Watch for:"
echo "  • 'virtio_blk virtio0' - VIRTIO driver loading"
echo "  • 'VFS: Mounted root' - Root filesystem mounted"
echo "  • 'Run /sbin/init' - Init starting"
echo "  • AirRide startup messages"
echo "  • Poyo login prompt"
echo ""
echo "Press Enter to boot..."
read

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -drive "file=$ROOTFS,format=raw,if=virtio" \
    -m 512M \
    -smp 2 \
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init debug loglevel=7 earlyprintk=serial,ttyS0,115200" \
    -nographic \
    -serial mon:stdio
