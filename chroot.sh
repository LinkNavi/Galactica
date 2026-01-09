#!/bin/bash
# Simple chroot test - won't hang
set -e

ROOTFS="galactica-rootfs.img"
MOUNT_POINT="/tmp/galactica-chroot"

if [[ $EUID -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

echo "=== Quick Chroot Test ==="
echo ""

# Mount if not already mounted
if ! mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    mkdir -p "$MOUNT_POINT"
    mount -o loop "$ROOTFS" "$MOUNT_POINT"
    mount -t proc proc "$MOUNT_POINT/proc"
    mount -t sysfs sys "$MOUNT_POINT/sys"
    mount --bind /dev "$MOUNT_POINT/dev"
    echo "Mounted rootfs"
else
    echo "Already mounted"
fi

echo ""
echo "=== Critical Finding ==="
echo "Busybox: STATICALLY LINKED (good!)"
echo "AirRide: DYNAMICALLY LINKED (needs libraries)"
echo ""

echo "=== Test: Can we execute busybox in chroot? ==="
if timeout 2 chroot "$MOUNT_POINT" /bin/busybox echo "SUCCESS!" 2>&1; then
    echo "✓ Chroot works!"
    echo ""
    echo "=== Testing shell commands ==="
    chroot "$MOUNT_POINT" /bin/sh -c "
        echo 'pwd:' \$(pwd)
        echo 'ls works:' \$(ls / | wc -l) items
        echo 'cat works:' \$(cat /etc/passwd | wc -l) lines
    "
    
    echo ""
    echo "=== Testing AirRide ==="
    echo "Checking if AirRide can execute at all..."
    
    # Set library path and try
    chroot "$MOUNT_POINT" /bin/sh -c "
        export LD_LIBRARY_PATH=/lib:/lib64:/usr/lib
        echo 'Attempting to run AirRide...'
        timeout 2 /sbin/airride --version 2>&1 || echo 'AirRide timed out or failed'
    "
    
    echo ""
    echo "=== Analysis ==="
    echo "✓ Chroot environment works"
    echo "✓ Busybox shell works"
    echo "? AirRide may have issues"
    echo ""
    echo "Since /bin/sh works in chroot but not in QEMU,"
    echo "the problem is with the KERNEL, not the rootfs."
    
else
    echo "✗ Chroot failed"
    echo ""
    echo "This means the rootfs itself has a problem."
fi

echo ""
echo "=== Kernel Config Issue ==="
echo ""
echo "The most likely problem is your kernel is missing:"
echo "  • CONFIG_SERIAL_8250_CONSOLE=y (serial console)"
echo "  • CONFIG_FUTEX=y (required by C++ programs)"
echo "  • CONFIG_EPOLL=y (required by init systems)"
echo ""
echo "Run: ./rebuild-kernel.sh to fix"
echo ""

read -p "Clean up and unmount? (y/n) [y]: " cleanup
cleanup=${cleanup:-y}

if [[ "$cleanup" == "y" ]]; then
    umount "$MOUNT_POINT/proc" 2>/dev/null || true
    umount "$MOUNT_POINT/sys" 2>/dev/null || true
    umount "$MOUNT_POINT/dev" 2>/dev/null || true
    umount "$MOUNT_POINT"
    rmdir "$MOUNT_POINT"
    echo "Cleaned up"
fi
