#!/bin/bash
# Inspect the Galactica installation

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DISK_FILE="$SCRIPT_DIR/test-galactica-disk.img"

echo -e "${CYAN}=== Galactica Installation Inspector ===${NC}"
echo ""

if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root: sudo ./inspect-installation.sh${NC}"
    exit 1
fi

if [ ! -f "$DISK_FILE" ]; then
    echo -e "${RED}Error: Disk image not found: $DISK_FILE${NC}"
    exit 1
fi

# Setup loop device
echo -e "${BLUE}Setting up loop device...${NC}"
LOOP_DEV=$(losetup -f --show -P "$DISK_FILE")
if [ -z "$LOOP_DEV" ]; then
    echo -e "${RED}Failed to create loop device${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Loop device: $LOOP_DEV${NC}"
echo ""

# Wait for partitions
sleep 2
partx -u "$LOOP_DEV" 2>/dev/null || true
sleep 1

# Check partitions
echo -e "${BLUE}Partition table:${NC}"
fdisk -l "$LOOP_DEV" | grep "^$LOOP_DEV"
echo ""

# Determine partition naming
if [[ "$LOOP_DEV" =~ loop ]]; then
    BOOT_PART="${LOOP_DEV}p1"
    ROOT_PART="${LOOP_DEV}p3"
else
    BOOT_PART="${LOOP_DEV}1"
    ROOT_PART="${LOOP_DEV}3"
fi

# Mount partitions
MOUNT_ROOT="/mnt/galactica-inspect"
MOUNT_BOOT="$MOUNT_ROOT/boot"

echo -e "${BLUE}Mounting partitions...${NC}"
mkdir -p "$MOUNT_ROOT"
mkdir -p "$MOUNT_BOOT"

if ! mount "$ROOT_PART" "$MOUNT_ROOT" 2>/dev/null; then
    echo -e "${RED}Failed to mount root partition${NC}"
    losetup -d "$LOOP_DEV"
    exit 1
fi

if ! mount "$BOOT_PART" "$MOUNT_BOOT" 2>/dev/null; then
    echo -e "${YELLOW}Warning: Failed to mount boot partition${NC}"
fi

echo -e "${GREEN}✓ Mounted${NC}"
echo ""

# Check boot partition contents
echo -e "${CYAN}=== Boot Partition Contents ===${NC}"
if [ -d "$MOUNT_BOOT" ]; then
    ls -lah "$MOUNT_BOOT"
    echo ""
    
    # Check for kernel
    if [ -f "$MOUNT_BOOT/vmlinuz-galactica" ]; then
        echo -e "${GREEN}✓ Kernel found: vmlinuz-galactica${NC}"
        ls -lh "$MOUNT_BOOT/vmlinuz-galactica"
    else
        echo -e "${RED}✗ Kernel NOT found!${NC}"
        echo "Expected: $MOUNT_BOOT/vmlinuz-galactica"
    fi
    echo ""
    
    # Check for bootloader config
    if [ -f "$MOUNT_BOOT/extlinux.conf" ]; then
        echo -e "${GREEN}✓ Bootloader config found${NC}"
        echo -e "${YELLOW}Contents of extlinux.conf:${NC}"
        cat "$MOUNT_BOOT/extlinux.conf"
    elif [ -f "$MOUNT_BOOT/syslinux.cfg" ]; then
        echo -e "${GREEN}✓ Bootloader config found (syslinux.cfg)${NC}"
        echo -e "${YELLOW}Contents of syslinux.cfg:${NC}"
        cat "$MOUNT_BOOT/syslinux.cfg"
    else
        echo -e "${RED}✗ Bootloader config NOT found!${NC}"
    fi
    echo ""
    
    # Check for ldlinux.sys (syslinux component)
    if [ -f "$MOUNT_BOOT/ldlinux.sys" ]; then
        echo -e "${GREEN}✓ SYSLINUX boot files found${NC}"
    else
        echo -e "${YELLOW}⚠ ldlinux.sys not found (might be an issue)${NC}"
    fi
else
    echo -e "${RED}Boot partition not accessible${NC}"
fi

echo ""
echo -e "${CYAN}=== Root Partition Structure ===${NC}"
ls -lah "$MOUNT_ROOT" | head -20
echo ""

# Check critical directories
echo -e "${BLUE}Checking critical directories:${NC}"
for dir in bin sbin lib lib64 etc usr; do
    if [ -d "$MOUNT_ROOT/$dir" ]; then
        COUNT=$(ls "$MOUNT_ROOT/$dir" 2>/dev/null | wc -l)
        echo -e "${GREEN}✓ /$dir exists ($COUNT files)${NC}"
    else
        echo -e "${RED}✗ /$dir missing${NC}"
    fi
done
echo ""

# Check fstab
if [ -f "$MOUNT_ROOT/etc/fstab" ]; then
    echo -e "${YELLOW}Contents of /etc/fstab:${NC}"
    cat "$MOUNT_ROOT/etc/fstab"
else
    echo -e "${RED}✗ /etc/fstab not found${NC}"
fi
echo ""

# Check init system
echo -e "${BLUE}Init system:${NC}"
if [ -f "$MOUNT_ROOT/sbin/init" ]; then
    echo -e "${GREEN}✓ /sbin/init exists${NC}"
    ls -lh "$MOUNT_ROOT/sbin/init"
    file "$MOUNT_ROOT/sbin/init"
elif [ -f "$MOUNT_ROOT/bin/init" ]; then
    echo -e "${GREEN}✓ /bin/init exists${NC}"
    ls -lh "$MOUNT_ROOT/bin/init"
else
    echo -e "${RED}✗ No init found!${NC}"
fi
echo ""

# Cleanup
echo -e "${YELLOW}Cleaning up...${NC}"
umount "$MOUNT_BOOT" 2>/dev/null || true
umount "$MOUNT_ROOT" 2>/dev/null || true
rmdir "$MOUNT_BOOT" 2>/dev/null || true
rmdir "$MOUNT_ROOT" 2>/dev/null || true
losetup -d "$LOOP_DEV"

echo -e "${GREEN}Done!${NC}"
echo ""
echo -e "${CYAN}=== Summary ===${NC}"
echo "If the kernel is missing or the bootloader config is wrong,"
echo "the installation needs to be fixed."
