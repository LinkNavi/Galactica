#!/bin/bash
# Launch Galactica in QEMU

set -e

KERNEL="galactica-build/boot/vmlinuz-galactica"
INITRAMFS="galactica-initramfs.cpio.gz"
ROOTFS="galactica-rootfs.img"

# Check if kernel exists
if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found at $KERNEL"
    exit 1
fi

# Create root filesystem image (if it doesn't exist)
if [[ ! -f "$ROOTFS" ]]; then
    echo "Creating root filesystem image..."
    
    # Create a 1GB ext4 image
    dd if=/dev/zero of="$ROOTFS" bs=1M count=1024
    mkfs.ext4 -F "$ROOTFS"
    
    # Mount and copy files
    mkdir -p mnt
    sudo mount -o loop "$ROOTFS" mnt
    sudo cp -a galactica-build/* mnt/
    sudo umount mnt
    rmdir mnt
    
    echo "Root filesystem created: $ROOTFS"
fi

# QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -kernel "$KERNEL"
    -m 512M
    -smp 2
    -drive "file=$ROOTFS,format=raw,if=virtio"
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init"
    -nographic
    -serial mon:stdio
)

# Add initramfs if it exists
if [[ -f "$INITRAMFS" ]]; then
    QEMU_CMD+=(-initrd "$INITRAMFS")
fi

echo "Starting QEMU..."
echo "Command: ${QEMU_CMD[@]}"
echo ""
echo "Press Ctrl+A then X to exit QEMU"
echo ""

"${QEMU_CMD[@]}"
