#!/bin/bash
# test.sh — Launch Galactica installer in QEMU for testing

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ISO="galactica-installer.iso"
INSTALL_IMG="test-install.img"
INSTALL_SIZE="8G"

ok()  { echo -e "${GREEN}[✓]${NC} $1"; }
err() { echo -e "${RED}[✗]${NC} $1" >&2; }
info(){ echo -e "${CYAN}[→]${NC} $1"; }
die() { err "$1"; exit 1; }

[[ -f "$ISO" ]] || die "ISO not found: $ISO — run make-iso.sh first"

# Create fresh install target drive
info "Creating fresh install drive ($INSTALL_SIZE)..."
qemu-img create -f raw "$INSTALL_IMG" "$INSTALL_SIZE" > /dev/null
ok "Install drive: $INSTALL_IMG"

echo ""
echo -e "${BOLD}Launching QEMU...${NC}"
echo -e "  Installer ISO:  ${CYAN}$ISO${NC}  (bootloader + galactica.sqf embedded)"
echo -e "  Install target: ${CYAN}$INSTALL_IMG${NC}  (blank hard drive)"
echo ""
echo -e "${YELLOW}Drive layout inside VM:${NC}"
echo -e "  vda = ISO (installer boots from here, reads squashfs from here)"
echo -e "  vdb = blank hard drive (Galactica installs here)"
echo ""
echo -e "${YELLOW}The installer will install to /dev/vdb.${NC}"
echo -e "${YELLOW}Close the QEMU window or press Ctrl+A X to quit.${NC}"
echo ""

# Extract kernel + initrd from ISO for direct boot (bypasses GRUB quirks)
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

info "Extracting kernel and initrd from ISO..."
if command -v 7z &>/dev/null; then
    7z x "$ISO" -o"$TMPDIR" boot/vmlinuz boot/initrd.img -y > /dev/null 2>&1
elif command -v isoinfo &>/dev/null; then
    isoinfo -i "$ISO" -x /boot/vmlinuz  > "$TMPDIR/vmlinuz"  2>/dev/null
    isoinfo -i "$ISO" -x /boot/initrd.img > "$TMPDIR/initrd.img" 2>/dev/null
else
    die "Need 7z or isoinfo to extract kernel from ISO"
fi

KERNEL="$TMPDIR/boot/vmlinuz"
INITRD="$TMPDIR/boot/initrd.img"

# Fallback paths depending on extraction tool
[[ -f "$KERNEL" ]] || KERNEL="$TMPDIR/vmlinuz"
[[ -f "$INITRD" ]] || INITRD="$TMPDIR/initrd.img"

[[ -f "$KERNEL" ]] || die "Failed to extract kernel from ISO"
[[ -f "$INITRD" ]] || die "Failed to extract initrd from ISO"
ok "Kernel and initrd extracted"

# Drive layout inside QEMU:
#   vda — blank install target  (installer writes Galactica here)
#   vdb — source image           (contains galactica.sqf, read-only)
qemu-system-x86_64 \
    -enable-kvm \
    -m 2G \
    -cpu host \
    -smp 2 \
    -drive file="$ISO",format=raw,if=virtio,readonly=on \
    -drive file="$INSTALL_IMG",format=raw,if=virtio,cache=none \
    -display gtk \
    -kernel "$KERNEL" \
    -initrd "$INITRD" \
    -append "root=/dev/ram0 rw console=tty0 quiet" \
    -no-reboot \
    -serial stdio 2>/dev/null

echo ""
echo -e "${GREEN}QEMU exited.${NC}"
echo ""
echo "To boot the installed system:"
echo -e "  ${YELLOW}qemu-system-x86_64 -enable-kvm -m 2G -cpu host -drive file=$INSTALL_IMG,format=raw,if=virtio${NC}"
