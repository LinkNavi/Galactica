#!/bin/bash
# Verify Galactica build is correct

TARGET_ROOT="./galactica-build"
KERNEL_DIR="./linux-6.18.3"
ROOTFS="galactica-rootfs.img"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_check() {
    if [[ $1 -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} $2"
    else
        echo -e "${RED}✗${NC} $2"
    fi
}

echo "=== Galactica Build Verification ==="
echo ""

ISSUES=0

# Check 1: Kernel configuration
echo -e "${BLUE}[1] Kernel Configuration${NC}"
if [[ -f "$KERNEL_DIR/.config" ]]; then
    if grep -q "^CONFIG_VIRTIO_BLK=y" "$KERNEL_DIR/.config"; then
        print_check 0 "VIRTIO_BLK enabled in kernel"
    else
        print_check 1 "VIRTIO_BLK NOT enabled - kernel won't boot!"
        ISSUES=$((ISSUES + 1))
    fi
    
    if grep -q "^CONFIG_VIRTIO_PCI=y" "$KERNEL_DIR/.config"; then
        print_check 0 "VIRTIO_PCI enabled in kernel"
    else
        print_check 1 "VIRTIO_PCI NOT enabled"
        ISSUES=$((ISSUES + 1))
    fi
    
    if grep -q "^CONFIG_EXT4_FS=y" "$KERNEL_DIR/.config"; then
        print_check 0 "EXT4_FS enabled in kernel"
    else
        print_check 1 "EXT4_FS NOT enabled"
        ISSUES=$((ISSUES + 1))
    fi
else
    print_check 1 "Kernel .config not found"
    ISSUES=$((ISSUES + 1))
fi

# Check 2: Kernel binary
echo ""
echo -e "${BLUE}[2] Kernel Binary${NC}"
if [[ -f "$KERNEL_DIR/arch/x86/boot/bzImage" ]]; then
    print_check 0 "Kernel built"
else
    print_check 1 "Kernel not built"
    ISSUES=$((ISSUES + 1))
fi

if [[ -f "$TARGET_ROOT/boot/vmlinuz-galactica" ]]; then
    print_check 0 "Kernel installed to build directory"
else
    print_check 1 "Kernel not installed"
    ISSUES=$((ISSUES + 1))
fi

# Check 3: Build directory
echo ""
echo -e "${BLUE}[3] Build Directory${NC}"
if [[ -d "$TARGET_ROOT" ]]; then
    print_check 0 "Build directory exists"
    
    if [[ -x "$TARGET_ROOT/sbin/airride" ]]; then
        print_check 0 "AirRide binary present"
    else
        print_check 1 "AirRide binary missing or not executable"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [[ -L "$TARGET_ROOT/sbin/init" ]]; then
        target=$(readlink "$TARGET_ROOT/sbin/init")
        if [[ "$target" == "airride" ]]; then
            print_check 0 "Init symlink correct (-> airride)"
        else
            print_check 1 "Init symlink wrong (-> $target)"
            ISSUES=$((ISSUES + 1))
        fi
    else
        print_check 1 "Init symlink missing"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [[ -x "$TARGET_ROOT/bin/sh" ]]; then
        print_check 0 "Shell present"
    else
        print_check 1 "Shell missing or not executable"
        ISSUES=$((ISSUES + 1))
    fi
    
    if [[ -c "$TARGET_ROOT/dev/console" ]]; then
        print_check 0 "Console device node present"
    else
        print_check 1 "Console device node missing"
        ISSUES=$((ISSUES + 1))
    fi
else
    print_check 1 "Build directory not found"
    ISSUES=$((ISSUES + 1))
fi

# Check 4: Libraries
echo ""
echo -e "${BLUE}[4] Libraries${NC}"
if [[ -f "$TARGET_ROOT/sbin/airride" ]]; then
    echo "Checking AirRide dependencies:"
    MISSING_LIBS=0
    ldd "$TARGET_ROOT/sbin/airride" 2>/dev/null | while read line; do
        if echo "$line" | grep -q "not found"; then
            echo -e "  ${RED}✗ $line${NC}"
            MISSING_LIBS=$((MISSING_LIBS + 1))
        fi
    done
    
    if [[ $MISSING_LIBS -eq 0 ]]; then
        print_check 0 "All AirRide libraries present"
    else
        print_check 1 "Missing $MISSING_LIBS libraries"
        ISSUES=$((ISSUES + 1))
    fi
fi

# Check 5: Root filesystem
echo ""
echo -e "${BLUE}[5] Root Filesystem Image${NC}"
if [[ -f "$ROOTFS" ]]; then
    print_check 0 "Root filesystem exists ($(du -h $ROOTFS | cut -f1))"
    
    # Mount and check
    mkdir -p /tmp/galactica-verify
    if sudo mount -o loop "$ROOTFS" /tmp/galactica-verify 2>/dev/null; then
        print_check 0 "Filesystem mountable"
        
        if [[ -x /tmp/galactica-verify/sbin/init ]]; then
            print_check 0 "Init executable in filesystem"
        else
            print_check 1 "Init not executable in filesystem"
            ISSUES=$((ISSUES + 1))
        fi
        
        if [[ -x /tmp/galactica-verify/bin/sh ]]; then
            print_check 0 "Shell executable in filesystem"
        else
            print_check 1 "Shell not executable in filesystem"
            ISSUES=$((ISSUES + 1))
        fi
        
        sudo umount /tmp/galactica-verify
    else
        print_check 1 "Cannot mount filesystem"
        ISSUES=$((ISSUES + 1))
    fi
    rmdir /tmp/galactica-verify 2>/dev/null
else
    print_check 1 "Root filesystem not found"
    ISSUES=$((ISSUES + 1))
fi

# Check 6: Launch scripts
echo ""
echo -e "${BLUE}[6] Launch Scripts${NC}"
if [[ -x "run-galactica.sh" ]]; then
    print_check 0 "run-galactica.sh present"
else
    print_check 1 "run-galactica.sh missing"
fi

if [[ -x "run-galactica-debug.sh" ]]; then
    print_check 0 "run-galactica-debug.sh present"
else
    print_check 1 "run-galactica-debug.sh missing"
fi

# Summary
echo ""
echo "=== Summary ==="
echo ""

if [[ $ISSUES -eq 0 ]]; then
    echo -e "${GREEN}✓ Build verification passed!${NC}"
    echo ""
    echo "Your Galactica system is ready to boot."
    echo ""
    echo "To start:"
    echo -e "  ${YELLOW}./run-galactica.sh${NC}"
    echo ""
    echo "To debug:"
    echo -e "  ${YELLOW}./run-galactica-debug.sh${NC}"
else
    echo -e "${RED}✗ Found $ISSUES issues!${NC}"
    echo ""
    echo "To fix, run:"
    echo -e "  ${YELLOW}./build-galactica.sh${NC}"
fi
