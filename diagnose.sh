#!/bin/bash
# Diagnose Galactica boot issues

set -e

ROOTFS="galactica-rootfs.img"
BUILD_DIR="galactica-build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Galactica Boot Diagnostics ===${NC}"
echo ""

ISSUES=0

# Check if rootfs exists
if [[ ! -f "$ROOTFS" ]]; then
    echo -e "${RED}✗${NC} Root filesystem not found: $ROOTFS"
    exit 1
fi

echo -e "${GREEN}✓${NC} Root filesystem found ($(du -h $ROOTFS | cut -f1))"

# Mount and check
echo ""
echo "Mounting rootfs for inspection..."
mkdir -p /tmp/galactica-diag
sudo mount -o loop "$ROOTFS" /tmp/galactica-diag 2>/dev/null || {
    echo -e "${RED}✗${NC} Cannot mount rootfs"
    exit 1
}

echo ""
echo -e "${BLUE}[Critical Files Check]${NC}"

# Check init
if [[ -x /tmp/galactica-diag/sbin/init ]]; then
    echo -e "${GREEN}✓${NC} /sbin/init is executable"
    
    # Check if it's a symlink
    if [[ -L /tmp/galactica-diag/sbin/init ]]; then
        TARGET=$(readlink /tmp/galactica-diag/sbin/init)
        echo "  → Symlink to: $TARGET"
        
        if [[ -x /tmp/galactica-diag/sbin/$TARGET ]]; then
            echo -e "${GREEN}✓${NC} Target exists: /sbin/$TARGET"
        else
            echo -e "${RED}✗${NC} Target missing or not executable!"
            ISSUES=$((ISSUES + 1))
        fi
    fi
else
    echo -e "${RED}✗${NC} /sbin/init missing or not executable!"
    ISSUES=$((ISSUES + 1))
fi

# Check shell
if [[ -x /tmp/galactica-diag/bin/sh ]]; then
    echo -e "${GREEN}✓${NC} /bin/sh is executable"
else
    echo -e "${RED}✗${NC} /bin/sh missing or not executable!"
    ISSUES=$((ISSUES + 1))
fi

# Check poyo
if [[ -x /tmp/galactica-diag/sbin/poyo ]]; then
    echo -e "${GREEN}✓${NC} /sbin/poyo is executable"
else
    echo -e "${YELLOW}!${NC} /sbin/poyo missing or not executable"
fi

# Check device nodes
echo ""
echo -e "${BLUE}[Device Nodes]${NC}"

if [[ -c /tmp/galactica-diag/dev/console ]]; then
    echo -e "${GREEN}✓${NC} /dev/console exists"
else
    echo -e "${RED}✗${NC} /dev/console missing!"
    ISSUES=$((ISSUES + 1))
fi

if [[ -c /tmp/galactica-diag/dev/null ]]; then
    echo -e "${GREEN}✓${NC} /dev/null exists"
else
    echo -e "${RED}✗${NC} /dev/null missing!"
    ISSUES=$((ISSUES + 1))
fi

# Check libraries
echo ""
echo -e "${BLUE}[Library Dependencies]${NC}"

check_binary_deps() {
    local binary=$1
    local name=$2
    
    if [[ ! -f "/tmp/galactica-diag$binary" ]]; then
        echo -e "${YELLOW}!${NC} $name not found"
        return
    fi
    
    echo "Checking $name..."
    
    # Try to check dependencies
    MISSING=$(sudo chroot /tmp/galactica-diag /bin/sh -c "LD_LIBRARY_PATH=/lib:/lib64:/usr/lib ldd $binary 2>&1" | grep "not found" || true)
    
    if [[ -n "$MISSING" ]]; then
        echo -e "${RED}✗${NC} Missing libraries:"
        echo "$MISSING" | sed 's/^/    /'
        ISSUES=$((ISSUES + 1))
    else
        echo -e "${GREEN}✓${NC} All dependencies satisfied"
    fi
}

check_binary_deps "/sbin/airride" "AirRide"
check_binary_deps "/sbin/poyo" "Poyo"

# Check directory structure
echo ""
echo -e "${BLUE}[Directory Structure]${NC}"

for dir in proc sys dev run tmp etc bin sbin usr/bin; do
    if [[ -d /tmp/galactica-diag/$dir ]]; then
        echo -e "${GREEN}✓${NC} /$dir exists"
    else
        echo -e "${RED}✗${NC} /$dir missing!"
        ISSUES=$((ISSUES + 1))
    fi
done

# Check configuration files
echo ""
echo -e "${BLUE}[Configuration Files]${NC}"

if [[ -f /tmp/galactica-diag/etc/passwd ]]; then
    echo -e "${GREEN}✓${NC} /etc/passwd exists"
    echo "  Users: $(cut -d: -f1 /tmp/galactica-diag/etc/passwd | tr '\n' ' ')"
else
    echo -e "${RED}✗${NC} /etc/passwd missing!"
    ISSUES=$((ISSUES + 1))
fi

if [[ -f /tmp/galactica-diag/etc/shadow ]]; then
    echo -e "${GREEN}✓${NC} /etc/shadow exists"
else
    echo -e "${YELLOW}!${NC} /etc/shadow missing"
fi

# List what's actually in the filesystem
echo ""
echo -e "${BLUE}[Filesystem Contents]${NC}"
echo "Files in /sbin:"
ls -lh /tmp/galactica-diag/sbin/ 2>/dev/null | head -10

echo ""
echo "Files in /bin:"
ls -lh /tmp/galactica-diag/bin/ 2>/dev/null | head -10

echo ""
echo "Libraries in /lib:"
find /tmp/galactica-diag/lib* -name "*.so*" 2>/dev/null | wc -l
echo "  Total .so files found: $(find /tmp/galactica-diag/lib* -name "*.so*" 2>/dev/null | wc -l)"

# Unmount
sudo umount /tmp/galactica-diag
rmdir /tmp/galactica-diag

# Summary
echo ""
echo -e "${BLUE}=== Summary ===${NC}"
echo ""

if [[ $ISSUES -eq 0 ]]; then
    echo -e "${GREEN}✓ No critical issues found${NC}"
    echo ""
    echo "Possible causes of blinking cursor:"
    echo "  1. Kernel panic (check with debug boot)"
    echo "  2. Init starting but crashing immediately"
    echo "  3. Missing library at runtime"
    echo ""
    echo "Try booting with debug:"
    echo -e "  ${YELLOW}./run-galactica-debug.sh${NC}"
    echo ""
    echo "Or use emergency shell for debugging:"
    echo "  Modify kernel append line to add: init=/bin/sh"
else
    echo -e "${RED}✗ Found $ISSUES critical issues!${NC}"
    echo ""
    echo "These must be fixed before the system can boot."
    echo ""
    echo "Recommended: Rebuild with the fixed script"
fi
