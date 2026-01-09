#!/bin/bash
# Enhanced Galactica launcher with debug modes

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

if [[ ! -f "$KERNEL" ]] || [[ ! -f "$ROOTFS" ]]; then
    echo "Error: Kernel or rootfs not found!"
    echo "Kernel: $KERNEL"
    echo "Rootfs: $ROOTFS"
    exit 1
fi

echo "=== Galactica Boot Menu ==="
echo ""
echo "Choose boot mode:"
echo ""
echo "  1) Normal boot (AirRide init)"
echo "  2) Debug boot (verbose kernel output)"
echo "  3) Emergency shell (bypass AirRide)"
echo "  4) Single user mode (skip services)"
echo "  5) Init debug (show what init does)"
echo ""
read -p "Select mode (1-5) [1]: " mode
mode=${mode:-1}

# Base QEMU command
QEMU_CMD="qemu-system-x86_64 \
    -kernel $KERNEL \
    -drive file=$ROOTFS,format=raw,if=virtio \
    -m 512M \
    -smp 2 \
    -nographic \
    -serial mon:stdio"

case $mode in
    1)
        echo ""
        echo "Starting normal boot..."
        echo "Press Ctrl+A then X to exit"
        echo ""
        $QEMU_CMD \
            -append "root=/dev/vda rw console=ttyS0 init=/sbin/init"
        ;;
    
    2)
        echo ""
        echo "Starting debug boot with verbose output..."
        echo "Watch for errors in the kernel messages"
        echo "Press Ctrl+A then X to exit"
        echo ""
        $QEMU_CMD \
            -append "root=/dev/vda rw console=ttyS0 init=/sbin/init debug loglevel=7 earlyprintk=serial"
        ;;
    
    3)
        echo ""
        echo "Starting emergency shell..."
        echo "This bypasses AirRide and gives you /bin/sh"
        echo "Press Ctrl+A then X to exit"
        echo ""
        $QEMU_CMD \
            -append "root=/dev/vda rw console=ttyS0 init=/bin/sh"
        ;;
    
    4)
        echo ""
        echo "Starting single user mode..."
        echo "This starts AirRide but may skip services"
        echo "Press Ctrl+A then X to exit"
        echo ""
        $QEMU_CMD \
            -append "root=/dev/vda rw console=ttyS0 init=/sbin/init single"
        ;;
    
    5)
        echo ""
        echo "Starting with init debugging..."
        echo "This shows what the init system is doing"
        echo "Press Ctrl+A then X to exit"
        echo ""
        $QEMU_CMD \
            -append "root=/dev/vda rw console=ttyS0 init=/sbin/init debug loglevel=7"
        ;;
    
    *)
        echo "Invalid selection"
        exit 1
        ;;
esac
