#!/bin/bash
# Update bootloader to use /dev/sda (for QEMU)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_FILE="$SCRIPT_DIR/test-galactica-disk.img"

echo -e "${CYAN}=== Fix Bootloader for QEMU ===${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root: sudo ./fix-for-qemu.sh${NC}"
    exit 1
fi

# Setup loop device
echo -e "${BLUE}Setting up loop device...${NC}"
LOOP_DEV=$(losetup -f --show -P "$DISK_FILE")
echo -e "${GREEN}✓ Loop device: $LOOP_DEV${NC}"

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    umount "$MOUNT_BOOT" 2>/dev/null || true
    umount "$MOUNT_ROOT" 2>/dev/null || true
    losetup -d "$LOOP_DEV" 2>/dev/null || true
    echo -e "${GREEN}Done${NC}"
}
trap cleanup EXIT

# Wait for partitions
sleep 2
partx -u "$LOOP_DEV" 2>/dev/null || true
sleep 1

# Determine partition naming
if [[ "$LOOP_DEV" =~ loop ]]; then
    BOOT_PART="${LOOP_DEV}p1"
    ROOT_PART="${LOOP_DEV}p3"
else
    BOOT_PART="${LOOP_DEV}1"
    ROOT_PART="${LOOP_DEV}3"
fi

# Mount partitions
MOUNT_ROOT="/mnt/galactica-fix"
MOUNT_BOOT="$MOUNT_ROOT/boot"

mkdir -p "$MOUNT_ROOT"
mkdir -p "$MOUNT_BOOT"

mount "$ROOT_PART" "$MOUNT_ROOT" || exit 1
mount "$BOOT_PART" "$MOUNT_BOOT" || exit 1

# Show current config
echo -e "${YELLOW}Current extlinux.conf:${NC}"
cat "$MOUNT_BOOT/extlinux.conf"
echo ""

# Create new config using /dev/sda for QEMU
echo -e "${GREEN}Creating QEMU-compatible config...${NC}"

cat > "$MOUNT_BOOT/extlinux.conf" << 'EOF'
DEFAULT galactica
PROMPT 1
TIMEOUT 50
SAY Booting Galactica Linux...

LABEL galactica
    MENU LABEL Galactica Linux
    LINUX /vmlinuz-galactica
    APPEND root=/dev/sda3 rw rootwait console=tty0 console=ttyS0,115200

LABEL galactica-quiet
    MENU LABEL Galactica Linux (Quiet)
    LINUX /vmlinuz-galactica
    APPEND root=/dev/sda3 rw rootwait quiet

LABEL recovery
    MENU LABEL Galactica Linux (Recovery Shell)
    LINUX /vmlinuz-galactica
    APPEND root=/dev/sda3 rw rootwait init=/bin/sh
EOF

echo -e "${YELLOW}New extlinux.conf:${NC}"
cat "$MOUNT_BOOT/extlinux.conf"
echo ""

echo -e "${GREEN}✓ Bootloader config updated for QEMU!${NC}"
echo ""
echo -e "${CYAN}Changes made:${NC}"
echo "  • Changed root=UUID=xxx → root=/dev/sda3"
echo "  • Added 'rootwait' to wait for disk"
echo "  • In QEMU, the disk appears as /dev/sda"
echo ""
echo "Try booting now with:"
echo "  ./boot-qemu.sh"
