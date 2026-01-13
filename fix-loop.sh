#!/bin/bash
# Diagnostic script for loop device issues

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Loop Device Diagnostics ===${NC}"
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo -e "${RED}Please run as root: sudo ./diagnose-loop.sh${NC}"
    exit 1
fi

# 1. Check loop module
echo -e "${YELLOW}[1] Checking loop kernel module...${NC}"
if lsmod | grep -q "^loop"; then
    echo -e "${GREEN}✓ Loop module is loaded${NC}"
    lsmod | grep "^loop"
else
    echo -e "${RED}✗ Loop module is NOT loaded${NC}"
    echo "Attempting to load..."
    modprobe loop
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}✓ Loop module loaded successfully${NC}"
    else
        echo -e "${RED}✗ Failed to load loop module${NC}"
    fi
fi
echo ""

# 2. Check loop devices
echo -e "${YELLOW}[2] Checking loop devices...${NC}"
if ls /dev/loop* > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Loop devices exist${NC}"
    echo "Available loop devices:"
    ls -la /dev/loop* | head -20
else
    echo -e "${RED}✗ No loop devices found${NC}"
    echo "Creating loop devices..."
    for i in {0..7}; do
        mknod -m 660 "/dev/loop$i" b 7 "$i" 2>/dev/null || true
    done
fi
echo ""

# 3. Check currently used loop devices
echo -e "${YELLOW}[3] Currently active loop devices...${NC}"
ACTIVE=$(losetup -a)
if [ -z "$ACTIVE" ]; then
    echo "None in use"
else
    echo "$ACTIVE"
fi
echo ""

# 4. Check for free loop device
echo -e "${YELLOW}[4] Checking for free loop device...${NC}"
FREE_LOOP=$(losetup -f 2>/dev/null)
if [ -n "$FREE_LOOP" ]; then
    echo -e "${GREEN}✓ Next available: $FREE_LOOP${NC}"
else
    echo -e "${RED}✗ No free loop devices available${NC}"
fi
echo ""

# 5. Check max_loop parameter
echo -e "${YELLOW}[5] Checking max_loop parameter...${NC}"
if [ -f /sys/module/loop/parameters/max_loop ]; then
    MAX_LOOP=$(cat /sys/module/loop/parameters/max_loop)
    echo "max_loop = $MAX_LOOP"
    if [ "$MAX_LOOP" = "0" ]; then
        echo -e "${YELLOW}Note: max_loop=0 means dynamic allocation${NC}"
    fi
else
    echo "max_loop parameter not found (might be using dynamic allocation)"
fi
echo ""

# 6. Test creating a loop device
echo -e "${YELLOW}[6] Testing loop device creation...${NC}"
TEST_FILE="/tmp/test-loop-$(date +%s).img"
echo "Creating test file: $TEST_FILE"

dd if=/dev/zero of="$TEST_FILE" bs=1M count=10 2>/dev/null
sync

if [ ! -f "$TEST_FILE" ]; then
    echo -e "${RED}✗ Failed to create test file${NC}"
else
    echo -e "${GREEN}✓ Test file created${NC}"
    ls -lh "$TEST_FILE"
    
    echo "Attempting to create loop device..."
    TEST_LOOP=$(losetup -f --show "$TEST_FILE" 2>&1)
    RESULT=$?
    
    if [ $RESULT -eq 0 ] && [ -b "$TEST_LOOP" ]; then
        echo -e "${GREEN}✓ Successfully created loop device: $TEST_LOOP${NC}"
        echo "Cleaning up test loop device..."
        losetup -d "$TEST_LOOP" 2>/dev/null || true
    else
        echo -e "${RED}✗ Failed to create loop device${NC}"
        echo "Error: $TEST_LOOP"
    fi
    
    rm -f "$TEST_FILE"
fi
echo ""

# 7. Check /dev/loop-control
echo -e "${YELLOW}[7] Checking /dev/loop-control...${NC}"
if [ -c /dev/loop-control ]; then
    echo -e "${GREEN}✓ /dev/loop-control exists${NC}"
    ls -la /dev/loop-control
else
    echo -e "${RED}✗ /dev/loop-control does not exist${NC}"
fi
echo ""

# 8. Check permissions
echo -e "${YELLOW}[8] Checking permissions...${NC}"
echo "Current user: $(whoami) (UID: $EUID)"
echo "Groups: $(groups)"
echo ""

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo ""

if [ -n "$FREE_LOOP" ]; then
    echo -e "${GREEN}✓ System appears ready for loop device operations${NC}"
    echo "  Next available: $FREE_LOOP"
else
    echo -e "${RED}✗ System may have issues with loop devices${NC}"
    echo ""
    echo "Possible solutions:"
    echo "  1. Reload loop module: modprobe -r loop && modprobe loop max_loop=8"
    echo "  2. Check kernel config: zgrep LOOP /proc/config.gz"
    echo "  3. Reboot the system"
fi
echo ""
