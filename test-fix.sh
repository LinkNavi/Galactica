#!/bin/bash
# Fix the hardcoded /dev/loop device in bootloader config

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_FILE="$SCRIPT_DIR/test-galactica-disk.img"

echo -e "${CYAN}=== Fix Bootloader Root Device ===${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root: sudo ./fix-root-device.sh${NC}"
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

# Get UUID
ROOT_UUID=$(blkid -s UUID -o value "$ROOT_PART")
echo -e "${BLUE}Root partition UUID: ${CYAN}$ROOT_UUID${NC}"
echo ""

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

# Create new config using UUID instead of /dev/loop
echo -e "${GREEN}Creating new config with UUID...${NC}"

cat > "$MOUNT_BOOT/extlinux.conf" << EOF
DEFAULT galactica
PROMPT 1
TIMEOUT 50
SAY Booting Galactica Linux...

LABEL galactica
    MENU LABEL Galactica Linux
    LINUX /vmlinuz-galactica
    APPEND root=UUID=$ROOT_UUID rw console=tty0 console=ttyS0,115200

LABEL galactica-quiet
    MENU LABEL Galactica Linux (Quiet)
    LINUX /vmlinuz-galactica
    APPEND root=UUID=$ROOT_UUID rw quiet

LABEL recovery
    MENU LABEL Galactica Linux (Recovery Shell)
    LINUX /vmlinuz-galactica
    APPEND root=UUID=$ROOT_UUID rw init=/bin/sh
EOF

echo -e "${YELLOW}New extlinux.conf:${NC}"
cat "$MOUNT_BOOT/extlinux.conf"
echo ""

echo -e "${GREEN}✓ Bootloader config updated!${NC}"
echo ""
echo -e "${CYAN}The system should now boot properly in QEMU.${NC}"
echo "Changes made:"
echo "  • Changed root=/dev/loop1p3 → root=UUID=$ROOT_UUID"
echo "  • Added serial console output (console=ttyS0)"
echo "  • Added boot menu with PROMPT 1"
echo ""
echo "Try booting now with:"
echo "  ./boot-qemu.sh"
