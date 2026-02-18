#!/bin/bash
# Boot Galactica with VirtIO (improved)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_FILE="$SCRIPT_DIR/test-galactica-disk.img"

echo -e "${CYAN}=== Boot Galactica with VirtIO ===${NC}"
echo ""

if [ ! -f "$DISK_FILE" ]; then
    echo -e "${RED}Error: Disk image not found: $DISK_FILE${NC}"
    exit 1
fi

# Fix ownership if needed
OWNER=$(stat -c '%U' "$DISK_FILE" 2>/dev/null)
CURRENT_USER=$(whoami)

if [ "$OWNER" != "$CURRENT_USER" ]; then
    echo -e "${YELLOW}Fixing disk ownership...${NC}"
    sudo chown "$CURRENT_USER:$CURRENT_USER" "$DISK_FILE"
fi

echo -e "${GREEN}✓ Disk image: $DISK_FILE${NC}"

# Check if KVM is available
if [ -w /dev/kvm ]; then
    KVM_FLAG="-enable-kvm"
    echo -e "${GREEN}✓ Using KVM acceleration${NC}"
else
    KVM_FLAG=""
    echo -e "${YELLOW}⚠ KVM not available${NC}"
fi

echo ""
echo -e "${CYAN}Checking bootloader configuration...${NC}"

# Check if bootloader is configured for vda
LOOP_DEV=$(sudo losetup -f --show -P "$DISK_FILE")
sleep 2
sudo partx -u "$LOOP_DEV" 2>/dev/null || true

BOOT_PART="${LOOP_DEV}p1"
ROOT_PART="${LOOP_DEV}p3"

MOUNT_ROOT="/tmp/galactica-vda-check"
MOUNT_BOOT="$MOUNT_ROOT/boot"

sudo mkdir -p "$MOUNT_ROOT"
sudo mkdir -p "$MOUNT_BOOT"

sudo mount "$ROOT_PART" "$MOUNT_ROOT" 2>/dev/null
sudo mount "$BOOT_PART" "$MOUNT_BOOT" 2>/dev/null

if grep -q "/dev/vda3" "$MOUNT_BOOT/extlinux.conf" 2>/dev/null; then
    echo -e "${GREEN}✓ Bootloader already configured for VirtIO${NC}"
else
    echo -e "${YELLOW}Updating bootloader for VirtIO (/dev/vda3)...${NC}"
    
    ROOT_UUID=$(sudo blkid -s UUID -o value "$ROOT_PART")
    
    sudo tee "$MOUNT_BOOT/extlinux.conf" > /dev/null << EOF
DEFAULT galactica
PROMPT 1
TIMEOUT 50
SAY Booting Galactica Linux...

LABEL galactica
    MENU LABEL Galactica Linux (VirtIO)
    LINUX /vmlinuz-galactica
    APPEND root=/dev/vda3 rw rootwait console=ttyS0,115200n8

LABEL galactica-uuid
    MENU LABEL Galactica Linux (with UUID)
    LINUX /vmlinuz-galactica
    APPEND root=UUID=$ROOT_UUID rw rootwait console=ttyS0,115200n8

LABEL recovery
    MENU LABEL Galactica Linux (Recovery Shell)
    LINUX /vmlinuz-galactica
    APPEND root=/dev/vda3 rw rootwait init=/bin/sh
EOF
    
    echo -e "${GREEN}✓ Bootloader updated${NC}"
fi

sudo umount "$MOUNT_BOOT" 2>/dev/null || true
sudo umount "$MOUNT_ROOT" 2>/dev/null || true
sudo losetup -d "$LOOP_DEV" 2>/dev/null || true

echo ""
echo -e "${CYAN}=== Starting QEMU with VirtIO ===${NC}"
echo ""
echo -e "${YELLOW}Controls:${NC}"
echo "  • Ctrl+A then X to exit QEMU"
echo "  • Ctrl+A then C for QEMU monitor"
echo ""
echo "Press Enter to boot..."
read

# Boot with VirtIO using proper console redirection
qemu-system-x86_64 \
    $KVM_FLAG \
    -m 2G \
    -drive file="$DISK_FILE",format=raw,if=virtio \
    -boot c \
    -nographic \
    -serial mon:stdio

echo ""
echo -e "${GREEN}QEMU exited${NC}"
