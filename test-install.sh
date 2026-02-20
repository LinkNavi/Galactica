#!/bin/bash
set -euo pipefail

ISO="galactica-installer.iso"
INSTALL_IMG="test-install.img"
INSTALL_SIZE="8G"

# Boot installed image directly
if [[ "${1:-}" == "boot" ]]; then
    [[ -f "$INSTALL_IMG" ]] || { echo "No install image found: $INSTALL_IMG"; exit 1; }
    echo "Booting $INSTALL_IMG..."
    exec qemu-system-x86_64     -enable-kvm     -m 2G     -cpu host     -smp 2     -drive file="$INSTALL_IMG",format=raw,if=virtio,cache=none     -display gtk     -vga virtio     -usb -device usb-tablet     -netdev user,id=net0 -device virtio-net-pci,netdev=net0     -serial stdio
fi

[[ -f "$ISO" ]] || { echo "ISO not found: $ISO — run make-iso.sh first"; exit 1; }

echo "Creating fresh install drive ($INSTALL_SIZE)..."
qemu-img create -f raw "$INSTALL_IMG" "$INSTALL_SIZE" > /dev/null
echo "Install drive: $INSTALL_IMG"

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

echo "Extracting kernel and initrd from ISO..."
if command -v 7z &>/dev/null; then
    7z x "$ISO" -o"$TMPDIR" boot/vmlinuz boot/initrd.img -y > /dev/null 2>&1
elif command -v isoinfo &>/dev/null; then
    isoinfo -i "$ISO" -x /boot/vmlinuz    > "$TMPDIR/vmlinuz"    2>/dev/null
    isoinfo -i "$ISO" -x /boot/initrd.img > "$TMPDIR/initrd.img" 2>/dev/null
else
    echo "Need 7z or isoinfo to extract kernel from ISO"; exit 1
fi

KERNEL="$TMPDIR/boot/vmlinuz"
INITRD="$TMPDIR/boot/initrd.img"
[[ -f "$KERNEL" ]] || KERNEL="$TMPDIR/vmlinuz"
[[ -f "$INITRD" ]] || INITRD="$TMPDIR/initrd.img"
[[ -f "$KERNEL" ]] || { echo "Failed to extract kernel"; exit 1; }
[[ -f "$INITRD" ]] || { echo "Failed to extract initrd"; exit 1; }

echo "Launching installer (GTK window)..."
qemu-system-x86_64 \
    -enable-kvm \
    -m 2G \
    -cpu host \
    -smp 2 \
    -drive file="$ISO",format=raw,if=virtio,readonly=on \
    -drive file="$INSTALL_IMG",format=raw,if=virtio,cache=none \
    -display gtk \
    -vga virtio \
    -usb -device usb-tablet \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "root=/dev/ram0 rw console=tty0 quiet" \
    -no-reboot

echo ""
echo "Done. To boot installed system:"
echo "  qemu-system-x86_64 -enable-kvm -m 2G -cpu host -drive file=$INSTALL_IMG,format=raw,if=virtio -display gtk -vga virtio"
