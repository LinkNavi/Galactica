#!/bin/bash
set -euo pipefail

ISO="galactica-installer.iso"
INSTALL_IMG="test-install.img"
INSTALL_SIZE="8G"

# Boot installed image directly
if [[ "${1:-}" == "boot" ]]; then
    [[ -f "$INSTALL_IMG" ]] || { echo "No install image found: $INSTALL_IMG"; exit 1; }
    echo "Booting $INSTALL_IMG..."
    exec qemu-system-x86_64 \
        -m 2G \
        -smp 2 \
        -drive file="$INSTALL_IMG",format=raw,if=virtio,cache=none \
        -display gtk \
        -vga virtio \
        -usb -device usb-tablet \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        -serial stdio
fi

[[ -f "$ISO" ]] || { echo "ISO not found: $ISO — run make-iso.sh first"; exit 1; }

echo "Creating fresh install drive ($INSTALL_SIZE)..."
qemu-img create -f raw "$INSTALL_IMG" "$INSTALL_SIZE" > /dev/null
echo "Install drive: $INSTALL_IMG"

echo "Launching installer..."
qemu-system-x86_64 \
    -m 2G \
    -smp 2 \
    -drive file="$ISO",format=raw,media=cdrom,readonly=on \
    -drive file="$INSTALL_IMG",format=raw,if=virtio,cache=none \
    -boot order=d \
    -display gtk \
    -vga virtio \
    -usb -device usb-tablet \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -no-reboot

echo ""
echo "Done. To boot installed system:"
echo "  bash test.sh boot"
