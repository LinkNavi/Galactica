#!/bin/bash
# Safe installer test with loop device - IMPROVED VERSION

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
echo -e "${BLUE}=== Safe Installer Test (Fixed) ===${NC}"
echo ""

# Check root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root: sudo ./installer-test.sh${NC}"
    exit 1
fi

# Get absolute path to script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Configuration
DISK_SIZE=10240  # 10GB in MB
DISK_FILE="$SCRIPT_DIR/test-galactica-disk.img"

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
echo -e "${BLUE}[1/5] Creating ${DISK_SIZE}MB test disk image...${NC}"
if [ -f "$DISK_FILE" ]; then
    echo -e "${YELLOW}Test disk already exists, recreating...${NC}"
    # Cleanup old loop device
    OLD_LOOP=$(losetup -j "$DISK_FILE" 2>/dev/null | cut -d: -f1)
    if [ -n "$OLD_LOOP" ]; then
        echo "Detaching old loop device: $OLD_LOOP"
        losetup -d "$OLD_LOOP" 2>/dev/null || true
    fi
    rm -f "$DISK_FILE"
fi

# Create the disk image
dd if=/dev/zero of="$DISK_FILE" bs=1M count=$DISK_SIZE status=progress
sync  # Force filesystem sync to ensure file is written

echo ""
echo -e "${GREEN}✓ Created disk image: $DISK_FILE${NC}"
echo ""

# Verify the file exists and show details
if [ ! -f "$DISK_FILE" ]; then
    echo -e "${RED}Error: Disk image was not created!${NC}"
    exit 1
fi

echo -e "${YELLOW}Disk image details:${NC}"
ls -lh "$DISK_FILE"
file "$DISK_FILE" 2>/dev/null || echo "File type: data"
echo ""

# Step 2: Check loop device availability
echo -e "${BLUE}[2/5] Checking loop device availability...${NC}"

# Check if loop module is loaded
if ! lsmod | grep -q "^loop"; then
    echo -e "${YELLOW}Loop module not loaded, attempting to load...${NC}"
    modprobe loop 2>/dev/null || true
fi

# Check available loop devices
AVAILABLE_LOOP=$(losetup -f 2>/dev/null)
if [ -z "$AVAILABLE_LOOP" ]; then
    echo -e "${YELLOW}No free loop devices found. Available loop devices:${NC}"
    ls -la /dev/loop* 2>/dev/null || echo "No /dev/loop* devices found"
    echo ""
    echo -e "${YELLOW}Attempting to create more loop devices...${NC}"
    
    # Try to create more loop devices
    for i in {0..15}; do
        if [ ! -b "/dev/loop$i" ]; then
            mknod -m 660 "/dev/loop$i" b 7 "$i" 2>/dev/null || true
        fi
    done
    
    AVAILABLE_LOOP=$(losetup -f 2>/dev/null)
fi

if [ -n "$AVAILABLE_LOOP" ]; then
    echo -e "${GREEN}✓ Next available loop device: $AVAILABLE_LOOP${NC}"
else
    echo -e "${RED}Error: No loop devices available${NC}"
    echo "Currently in use:"
    losetup -a
    exit 1
fi
echo ""

# Step 3: Setup loop device WITH PARTITION SUPPORT
echo -e "${BLUE}[3/5] Setting up loop device with partition support...${NC}"
echo "Disk file path: $DISK_FILE"
echo "Attempting to create loop device..."

# Try to create loop device with better error handling
LOOP_DEV=$(losetup -f --show -P "$DISK_FILE" 2>&1)
LOSETUP_EXIT=$?

if [ $LOSETUP_EXIT -ne 0 ]; then
    echo -e "${RED}Error: losetup failed with exit code $LOSETUP_EXIT${NC}"
    echo "Error output: $LOOP_DEV"
    echo ""
    echo -e "${YELLOW}Debugging information:${NC}"
    echo "Current directory: $(pwd)"
    echo "Disk file: $DISK_FILE"
    echo "File exists: $(test -f "$DISK_FILE" && echo "YES" || echo "NO")"
    echo "File readable: $(test -r "$DISK_FILE" && echo "YES" || echo "NO")"
    echo "File writable: $(test -w "$DISK_FILE" && echo "YES" || echo "NO")"
    echo ""
    echo "Current loop devices:"
    losetup -a
    echo ""
    echo "Available loop devices:"
    ls -la /dev/loop* 2>/dev/null | head -20
    exit 1
fi

if [ -z "$LOOP_DEV" ] || [ ! -b "$LOOP_DEV" ]; then
    echo -e "${RED}Error: Failed to create loop device${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Created: $LOOP_DEV${NC}"

# CRITICAL: Use partx to force partition table scan
partx -u "$LOOP_DEV" 2>/dev/null || true

echo ""

# Wait for device to be ready
sleep 1

# Step 4: Verify loop device
echo -e "${BLUE}[4/5] Verifying loop device...${NC}"
if [ -b "$LOOP_DEV" ]; then
    echo -e "${GREEN}✓ Loop device exists and is a block device${NC}"
else
    echo -e "${RED}✗ Loop device does not exist or is not a block device${NC}"
    exit 1
fi

lsblk "$LOOP_DEV" 2>/dev/null || echo "$LOOP_DEV (empty, not partitioned yet)"
echo ""
echo -e "${GREEN}✓ Loop device created with partition support (-P flag)${NC}"
echo -e "${YELLOW}  After partitioning, partitions will appear as ${LOOP_DEV}p1, ${LOOP_DEV}p2, etc.${NC}"
echo ""

# Step 5: Prepare source directory
echo -e "${BLUE}[5/5] Checking Galactica source files...${NC}"

# Check if galactica-build exists
if [ ! -d "$SCRIPT_DIR/galactica-build" ]; then
    echo -e "${YELLOW}Warning: galactica-build directory not found${NC}"
    echo -e "${YELLOW}Creating minimal source directory for testing...${NC}"
    
    mkdir -p "$SCRIPT_DIR/galactica-build"/{boot,bin,sbin,etc,dev,proc,sys,tmp,var,home,root}
    
    # Create a fake kernel for testing
    echo "This is a test kernel" > "$SCRIPT_DIR/galactica-build/boot/vmlinuz-galactica"
    
    echo -e "${GREEN}✓ Created test source directory${NC}"
else
    echo -e "${GREEN}✓ Found galactica-build directory${NC}"
fi

# Update SOURCE_DIR in the installer
echo ""
echo -e "${YELLOW}NOTE: Make sure to update SOURCE_DIR in GalacticaInstaller/src/install.go to:${NC}"
echo -e "${CYAN}const SOURCE_DIR = \"$SCRIPT_DIR/galactica-build\"${NC}"
echo ""

# Step 6: Run installer
echo -e "${BLUE}[6/6] Starting installer...${NC}"
echo ""
echo -e "${CYAN}Instructions:${NC}"
echo "  1. Select the loop device: $LOOP_DEV"
echo "  2. Choose automatic partitioning"
echo "  3. Accept defaults for user setup"
echo "  4. Watch the installation progress"
echo ""
read -p "Press Enter to start installer..."

if [ ! -d "$SCRIPT_DIR/GalacticaInstaller" ]; then
    echo -e "${RED}Error: Installer directory not found at $SCRIPT_DIR/Installer${NC}"
    exit 1
fi

cd "$SCRIPT_DIR/GalacticaInstaller"
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
echo "3. The cleanup will run automatically on exit"
echo ""
