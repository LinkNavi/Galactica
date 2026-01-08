#!/bin/bash
# Debug QEMU boot for Galactica - adds verbose kernel debugging

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Galactica Debug Boot ===${NC}"
echo ""

# Check files exist
if [[ ! -f "$KERNEL" ]]; then
    echo -e "${RED}Error: Kernel not found at $KERNEL${NC}"
    echo ""
    echo "You need to build the kernel first!"
    echo "Run: ./build-and-launch.sh"
    exit 1
fi

if [[ ! -f "$ROOTFS" ]]; then
    echo -e "${RED}Error: Root filesystem not found at $ROOTFS${NC}"
    echo ""
    echo "You need to create the root filesystem!"
    echo "Run: sudo ./fix.sh"
    exit 1
fi

echo -e "${GREEN}✓${NC} Kernel found: $KERNEL"
echo -e "${GREEN}✓${NC} Rootfs found: $ROOTFS ($(du -h $ROOTFS | cut -f1))"
echo ""
echo -e "${YELLOW}Debug Mode Features:${NC}"
echo "  • Verbose kernel messages (loglevel=7)"
echo "  • Early printk enabled"
echo "  • Init debugging"
echo "  • Serial console output"
echo ""
echo -e "${YELLOW}What to watch for:${NC}"
echo "  1. Kernel boot messages"
echo "  2. 'VFS: Mounted root' - means filesystem found"
echo "  3. 'Run /sbin/init' - means kernel trying to start init"
echo "  4. AirRide startup messages"
echo ""
echo -e "${YELLOW}Common boot failures:${NC}"
echo "  • Kernel panic: Can't mount root - wrong filesystem driver"
echo "  • Kernel panic: No init found - missing /sbin/init"
echo "  • Init exits immediately - missing libraries or shell"
echo "  • Black screen - init started but crashed silently"
echo ""
echo "Press Enter to boot (or Ctrl+C to cancel)..."
read

echo ""
echo -e "${BLUE}Starting QEMU with full debug output...${NC}"
echo -e "${YELLOW}Press Ctrl+A then X to exit QEMU${NC}"
echo ""
sleep 2

# Boot with extensive debugging
qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -drive "file=$ROOTFS,format=raw,if=virtio" \
    -m 512M \
    -smp 2 \
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init debug loglevel=7 earlyprintk=serial,ttyS0,115200" \
    -nographic \
    -serial mon:stdio

echo ""
echo -e "${BLUE}QEMU exited${NC}"
