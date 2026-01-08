#!/bin/bash
# Launch Galactica directly from kernel (no disk image)

set -e

KERNEL="galactica-build/boot/vmlinuz-galactica"

if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found at $KERNEL"
    exit 1
fi

echo "Starting QEMU with direct kernel boot..."
echo "This boots directly into your AirRide init system"
echo ""

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -m 256M \
    -smp 1 \
    -append "console=ttyS0 init=/sbin/airride" \
    -nographic \
    -serial mon:stdio

# Note: This won't work without an initramfs containing your init system!
