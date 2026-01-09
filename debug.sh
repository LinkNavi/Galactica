#!/bin/bash
# Advanced Galactica Boot Debugger
# Captures full boot log and helps diagnose issues

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"
LOG_FILE="boot-debug-$(date +%Y%m%d-%H%M%S).log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}=== Galactica Advanced Boot Debugger ===${NC}"
echo ""

if [[ ! -f "$KERNEL" ]] || [[ ! -f "$ROOTFS" ]]; then
    echo -e "${RED}Error: Kernel or rootfs not found!${NC}"
    exit 1
fi

echo "This will boot Galactica with maximum debug output and capture the log."
echo ""
echo "What to watch for:"
echo "  ${GREEN}✓${NC} Kernel decompressing"
echo "  ${GREEN}✓${NC} virtio_blk virtio0: [vda] (device detected)"
echo "  ${GREEN}✓${NC} VFS: Mounted root (ext4 filesystem)"
echo "  ${GREEN}✓${NC} Freeing unused kernel memory"
echo "  ${GREEN}✓${NC} Run /sbin/init as init process"
echo "  ${YELLOW}!${NC} Kernel panic (system crash)"
echo "  ${RED}✗${NC} Init exits or crashes (returns to blinking cursor)"
echo ""
echo "Output will be saved to: ${CYAN}$LOG_FILE${NC}"
echo ""

# Create a test to see if init exists and is executable in rootfs
echo -e "${BLUE}Pre-flight checks:${NC}"
mkdir -p /tmp/galactica-preflight
sudo mount -o loop "$ROOTFS" /tmp/galactica-preflight

echo -n "  /sbin/init exists: "
if [[ -f /tmp/galactica-preflight/sbin/init ]]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ NOT FOUND${NC}"
fi

echo -n "  /sbin/init is executable: "
if [[ -x /tmp/galactica-preflight/sbin/init ]]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗ NOT EXECUTABLE${NC}"
fi

echo -n "  /sbin/init target: "
if [[ -L /tmp/galactica-preflight/sbin/init ]]; then
    TARGET=$(readlink /tmp/galactica-preflight/sbin/init)
    echo "$TARGET"
    echo -n "  Target exists: "
    if [[ -f /tmp/galactica-preflight/sbin/$TARGET ]]; then
        echo -e "${GREEN}✓${NC}"
    else
        echo -e "${RED}✗ NOT FOUND${NC}"
    fi
fi

echo -n "  /bin/sh exists: "
if [[ -x /tmp/galactica-preflight/bin/sh ]]; then
    echo -e "${GREEN}✓${NC}"
else
    echo -e "${RED}✗${NC}"
fi

echo ""
echo "Library count:"
LIBS=$(sudo find /tmp/galactica-preflight -name "*.so*" 2>/dev/null | wc -l)
echo "  Total .so files: $LIBS"

if [[ $LIBS -lt 10 ]]; then
    echo -e "  ${RED}✗ WARNING: Too few libraries!${NC}"
    echo "  Expected: 20-30 libraries"
fi

sudo umount /tmp/galactica-preflight
rmdir /tmp/galactica-preflight

echo ""
echo -e "${YELLOW}Choose boot mode:${NC}"
echo ""
echo "  ${BOLD}1)${NC} Maximum debug (recommended)"
echo "  ${BOLD}2)${NC} Emergency shell (bypass init)"
echo "  ${BOLD}3)${NC} Test init directly"
echo "  ${BOLD}4)${NC} Kernel panic test"
echo ""
read -p "Select mode (1-4) [1]: " mode
mode=${mode:-1}

echo ""
echo -e "${CYAN}Starting boot...${NC}"
echo "Press Ctrl+A then X to exit QEMU"
echo "Log will be saved to: $LOG_FILE"
echo ""
sleep 2

case $mode in
    1)
        # Maximum debug mode
        echo "=== MAXIMUM DEBUG MODE ===" | tee "$LOG_FILE"
        echo "Boot started: $(date)" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        
        qemu-system-x86_64 \
            -kernel "$KERNEL" \
            -drive file="$ROOTFS",format=raw,if=virtio \
            -m 512M \
            -smp 2 \
            -append "root=/dev/vda rw console=ttyS0 init=/sbin/init debug loglevel=8 earlyprintk=serial,ttyS0,115200 initcall_debug ignore_loglevel" \
            -nographic \
            -serial mon:stdio 2>&1 | tee -a "$LOG_FILE"
        ;;
    
    2)
        # Emergency shell - bypass init completely
        echo "=== EMERGENCY SHELL MODE ===" | tee "$LOG_FILE"
        echo "This boots directly to /bin/sh" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        
        qemu-system-x86_64 \
            -kernel "$KERNEL" \
            -drive file="$ROOTFS",format=raw,if=virtio \
            -m 512M \
            -smp 2 \
            -append "root=/dev/vda rw console=ttyS0 init=/bin/sh loglevel=7" \
            -nographic \
            -serial mon:stdio 2>&1 | tee -a "$LOG_FILE"
        ;;
    
    3)
        # Test init with strace-like output
        echo "=== INIT DIRECT TEST ===" | tee "$LOG_FILE"
        echo "This tests if init can execute" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        
        # First try with wrapper
        cat > /tmp/init-wrapper.sh << 'EOFWRAP'
#!/bin/sh
echo "=== Init Wrapper Started ==="
echo "Current directory: $(pwd)"
echo "Init path: /sbin/init"
echo "Init exists: $(test -f /sbin/init && echo YES || echo NO)"
echo "Init executable: $(test -x /sbin/init && echo YES || echo NO)"
echo ""
echo "Attempting to run init..."
exec /sbin/init
EOFWRAP
        
        # Copy wrapper to rootfs
        mkdir -p /tmp/galactica-wrapper
        sudo mount -o loop "$ROOTFS" /tmp/galactica-wrapper
        sudo cp /tmp/init-wrapper.sh /tmp/galactica-wrapper/init-wrapper.sh
        sudo chmod +x /tmp/galactica-wrapper/init-wrapper.sh
        sudo umount /tmp/galactica-wrapper
        rmdir /tmp/galactica-wrapper
        
        qemu-system-x86_64 \
            -kernel "$KERNEL" \
            -drive file="$ROOTFS",format=raw,if=virtio \
            -m 512M \
            -smp 2 \
            -append "root=/dev/vda rw console=ttyS0 init=/init-wrapper.sh debug loglevel=7" \
            -nographic \
            -serial mon:stdio 2>&1 | tee -a "$LOG_FILE"
        ;;
    
    4)
        # Kernel panic test - intentionally break init
        echo "=== KERNEL PANIC TEST ===" | tee "$LOG_FILE"
        echo "Using non-existent init to see kernel panic" | tee -a "$LOG_FILE"
        echo "" | tee -a "$LOG_FILE"
        
        qemu-system-x86_64 \
            -kernel "$KERNEL" \
            -drive file="$ROOTFS",format=raw,if=virtio \
            -m 512M \
            -smp 2 \
            -append "root=/dev/vda rw console=ttyS0 init=/nonexistent panic=10 loglevel=7" \
            -nographic \
            -serial mon:stdio 2>&1 | tee -a "$LOG_FILE"
        ;;
esac

echo ""
echo ""
echo -e "${BLUE}=== Boot Log Analysis ===${NC}"
echo ""

# Analyze the log
if [[ -f "$LOG_FILE" ]]; then
    echo "Log saved to: ${CYAN}$LOG_FILE${NC}"
    echo ""
    
    echo "Key events found:"
    
    if grep -q "virtio_blk" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓${NC} VIRTIO disk driver loaded"
    else
        echo -e "  ${RED}✗${NC} VIRTIO disk driver NOT found"
    fi
    
    if grep -q "VFS: Mounted root" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓${NC} Root filesystem mounted"
    else
        echo -e "  ${RED}✗${NC} Root filesystem NOT mounted"
    fi
    
    if grep -q "Run /sbin/init" "$LOG_FILE"; then
        echo -e "  ${GREEN}✓${NC} Kernel attempted to run init"
    else
        echo -e "  ${YELLOW}!${NC} Kernel did not mention init"
    fi
    
    if grep -q "Kernel panic" "$LOG_FILE"; then
        echo -e "  ${RED}✗${NC} KERNEL PANIC detected"
        echo ""
        echo "Panic message:"
        grep -A 5 "Kernel panic" "$LOG_FILE" | sed 's/^/    /'
    fi
    
    if grep -q "Failed to execute" "$LOG_FILE"; then
        echo -e "  ${RED}✗${NC} Failed to execute init"
        grep "Failed to execute" "$LOG_FILE" | sed 's/^/    /'
    fi
    
    if grep -iq "segmentation fault\|segfault" "$LOG_FILE"; then
        echo -e "  ${RED}✗${NC} Segmentation fault detected"
    fi
    
    # Check for library errors
    if grep -iq "error while loading shared libraries" "$LOG_FILE"; then
        echo -e "  ${RED}✗${NC} Missing shared libraries"
        grep -i "error while loading shared libraries" "$LOG_FILE" | sed 's/^/    /'
    fi
    
    # Look for the last message before cursor
    echo ""
    echo "Last 20 messages before stopping:"
    tail -20 "$LOG_FILE" | sed 's/^/  /'
    
    echo ""
    echo -e "${YELLOW}Full log:${NC} $LOG_FILE"
fi

echo ""
echo -e "${BLUE}=== Possible Issues ===${NC}"
echo ""
echo "If you see a blinking cursor, the likely causes are:"
echo ""
echo "  ${YELLOW}1. Init exits immediately${NC}"
echo "     - Init runs but crashes or exits with error"
echo "     - Check: Does AirRide have all its libraries?"
echo "     - Test: Boot with mode 2 (emergency shell) to check manually"
echo ""
echo "  ${YELLOW}2. Init cannot execute${NC}"
echo "     - Missing shared libraries"
echo "     - Wrong architecture (32-bit vs 64-bit)"
echo "     - Run: ldd galactica-build/sbin/airride"
echo ""
echo "  ${YELLOW}3. Device/filesystem issue${NC}"
echo "     - /dev/console missing"
echo "     - Wrong root= parameter"
echo "     - Filesystem corruption"
echo ""
echo "  ${YELLOW}4. Silent crash${NC}"
echo "     - Init crashes without error message"
echo "     - May need to add error handling to AirRide"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. Review the log: ${YELLOW}less $LOG_FILE${NC}"
echo "  2. Try emergency shell (mode 2) to debug manually"
echo "  3. Check init dependencies: ${YELLOW}ldd galactica-build/sbin/airride${NC}"
echo "  4. Verify libraries were synced: ${YELLOW}./diagnose.sh${NC}"
echo ""
