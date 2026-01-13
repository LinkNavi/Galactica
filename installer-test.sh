#!/bin/bash
# Safe installer test with loop device

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}"
cat << "EOF"
  ________       .__                 __  .__               
 /  _____/_____  |  | _____    _____/  |_|__| ____ _____   
/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  
\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_
 \______  (____  /____(____  /\___  >__| |__|\___  >____  /
        \/     \/          \/     \/             \/     \/ 
EOF
echo -e "${NC}"
echo -e "${BLUE}=== Safe Installer Test ===${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root: sudo ./test.sh${NC}"
    exit 1
fi

# Configuration
DISK_SIZE=10240  # 10GB in MB
DISK_FILE="test-galactica-disk.img"

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up...${NC}"
    
    # Unmount if mounted
    umount /mnt/galactica/boot 2>/dev/null || true
    umount /mnt/galactica 2>/dev/null || true
    
    # Turn off swap
    swapoff -a 2>/dev/null || true
    
    # Find loop device
    LOOP_DEV=$(losetup -j "$DISK_FILE" 2>/dev/null | cut -d: -f1)
    
    if [ -n "$LOOP_DEV" ]; then
        echo "Detaching $LOOP_DEV"
        losetup -d "$LOOP_DEV" 2>/dev/null || true
    fi
    
    echo -e "${GREEN}Cleanup complete${NC}"
}

# Set trap for cleanup
trap cleanup EXIT

# Step 1: Create disk image
echo -e "${BLUE}[1/4] Creating ${DISK_SIZE}MB test disk image...${NC}"
if [ -f "$DISK_FILE" ]; then
    echo -e "${YELLOW}Test disk already exists, recreating...${NC}"
    # Cleanup old loop device
    OLD_LOOP=$(losetup -j "$DISK_FILE" 2>/dev/null | cut -d: -f1)
    if [ -n "$OLD_LOOP" ]; then
        losetup -d "$OLD_LOOP" 2>/dev/null || true
    fi
    rm -f "$DISK_FILE"
fi

dd if=/dev/zero of="$DISK_FILE" bs=1M count=$DISK_SIZE status=progress
echo ""

# Step 2: Setup loop device WITH PARTITION SUPPORT
echo -e "${BLUE}[2/4] Setting up loop device with partition support...${NC}"
LOOP_DEV=$(losetup -f --show -P "$DISK_FILE")
echo -e "${GREEN}✓ Created: $LOOP_DEV${NC}"

# CRITICAL: Use partx to force partition table scan
partx -u "$LOOP_DEV" 2>/dev/null || true

echo ""

# Wait for device to be ready
sleep 1

# Step 3: Show disk info
echo -e "${BLUE}[3/4] Test disk information:${NC}"
echo ""
lsblk "$LOOP_DEV" 2>/dev/null || echo "$LOOP_DEV (empty, not partitioned yet)"
echo ""
echo -e "${GREEN}✓ Loop device created with partition support (-P flag)${NC}"
echo -e "${YELLOW}  After partitioning, partitions will appear as ${LOOP_DEV}p1, ${LOOP_DEV}p2, etc.${NC}"
echo ""

# Step 4: Run installer
echo -e "${BLUE}[4/4] Starting installer...${NC}"
echo ""
echo -e "${CYAN}Instructions:${NC}"
echo "  1. Select the loop device (should be the only option)"
echo "  2. Choose automatic partitioning"
echo "  3. Accept defaults for user setup"
echo "  4. Watch the installation progress"
echo ""
read -p "Press Enter to start installer..."

cd GalacticaInstaller
go run ./src/

echo ""
echo -e "${GREEN}=== Installation Complete ===${NC}"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo ""
echo "1. Inspect the installation:"
echo -e "   ${YELLOW}sudo mkdir -p /mnt/test${NC}"
echo -e "   ${YELLOW}sudo mount ${LOOP_DEV}p3 /mnt/test${NC}"
echo -e "   ${YELLOW}sudo mount ${LOOP_DEV}p1 /mnt/test/boot${NC}"
echo -e "   ${YELLOW}ls -la /mnt/test${NC}"
echo ""
echo "2. Boot the installed system in QEMU:"
echo -e "   ${YELLOW}qemu-system-x86_64 -enable-kvm -m 2G -drive file=$DISK_FILE,format=raw -boot c${NC}"
echo ""
echo "3. Cleanup (done automatically on exit):"
echo -e "   ${YELLOW}sudo losetup -d $LOOP_DEV${NC}"
echo -e "   ${YELLOW}rm $DISK_FILE${NC}"
echo ""
