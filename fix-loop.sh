#!/bin/bash
# Check kernel configuration for disk support

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_FILE="$SCRIPT_DIR/test-galactica-disk.img"

echo -e "${CYAN}=== Kernel Diagnostics ===${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root: sudo ./check-kernel.sh${NC}"
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
MOUNT_ROOT="/mnt/galactica-check"
MOUNT_BOOT="$MOUNT_ROOT/boot"

mkdir -p "$MOUNT_ROOT"
mkdir -p "$MOUNT_BOOT"

mount "$ROOT_PART" "$MOUNT_ROOT" || exit 1
mount "$BOOT_PART" "$MOUNT_BOOT" || exit 1

echo ""
echo -e "${CYAN}=== Checking Kernel ===${NC}"
echo ""

# Check kernel exists
if [ -f "$MOUNT_BOOT/vmlinuz-galactica" ]; then
    echo -e "${GREEN}✓ Kernel found${NC}"
    ls -lh "$MOUNT_BOOT/vmlinuz-galactica"
    file "$MOUNT_BOOT/vmlinuz-galactica"
else
    echo -e "${RED}✗ Kernel not found!${NC}"
    exit 1
fi

echo ""
echo -e "${CYAN}=== Checking Kernel Modules ===${NC}"
echo ""

# Check for kernel modules
if [ -d "$MOUNT_ROOT/lib/modules" ]; then
    echo -e "${GREEN}✓ Modules directory exists${NC}"
    ls -la "$MOUNT_ROOT/lib/modules/"
    
    # Look for important drivers
    echo ""
    echo -e "${BLUE}Looking for critical drivers:${NC}"
    
    MODULES_DIR=$(ls -d "$MOUNT_ROOT/lib/modules"/* 2>/dev/null | head -1)
    if [ -n "$MODULES_DIR" ]; then
        echo "Module directory: $MODULES_DIR"
        echo ""
        
        # Check for disk drivers
        echo -e "${YELLOW}SATA/ATA drivers:${NC}"
        find "$MODULES_DIR" -name "*ata*" -o -name "*ahci*" -o -name "*sata*" 2>/dev/null | head -10
        
        echo ""
        echo -e "${YELLOW}SCSI drivers:${NC}"
        find "$MODULES_DIR" -name "*scsi*" -o -name "*sd_mod*" 2>/dev/null | head -10
        
        echo ""
        echo -e "${YELLOW}Virtio drivers (for QEMU):${NC}"
        find "$MODULES_DIR" -name "*virtio*" 2>/dev/null | head -10
    else
        echo -e "${YELLOW}No kernel modules installed${NC}"
    fi
else
    echo -e "${YELLOW}⚠ No kernel modules directory found!${NC}"
    echo "This means disk drivers must be built into the kernel"
fi

echo ""
echo -e "${CYAN}=== Checking Init System ===${NC}"
echo ""

if [ -f "$MOUNT_ROOT/sbin/init" ] || [ -L "$MOUNT_ROOT/sbin/init" ]; then
    echo -e "${GREEN}✓ /sbin/init exists${NC}"
    ls -lh "$MOUNT_ROOT/sbin/init"
    if [ -L "$MOUNT_ROOT/sbin/init" ]; then
        echo "Points to: $(readlink "$MOUNT_ROOT/sbin/init")"
        TARGET=$(readlink "$MOUNT_ROOT/sbin/init")
        if [ -f "$MOUNT_ROOT/sbin/$TARGET" ]; then
            echo -e "${GREEN}✓ Target exists${NC}"
        else
            echo -e "${RED}✗ Target missing!${NC}"
        fi
    fi
else
    echo -e "${RED}✗ /sbin/init not found!${NC}"
fi

echo ""
echo -e "${CYAN}=== Summary ===${NC}"
echo ""
echo "The kernel is loading but can't find /dev/sda3."
echo "This usually means one of these issues:"
echo ""
echo "1. ${YELLOW}Disk drivers not built into kernel${NC}"
echo "   - Need CONFIG_ATA=y or CONFIG_SCSI=y"
echo "   - Need CONFIG_BLK_DEV_SD=y (for SCSI/SATA disks)"
echo "   - For QEMU: Need CONFIG_VIRTIO_BLK=y"
echo ""
echo "2. ${YELLOW}Using wrong disk interface in QEMU${NC}"
echo "   - Try: -drive file=disk.img,if=ide"
echo "   - Or: -drive file=disk.img,if=virtio (needs virtio driver)"
echo ""
echo "3. ${YELLOW}Kernel modules not loading${NC}"
echo "   - Need initramfs to load modules"
echo "   - Or compile drivers into kernel"
echo ""
