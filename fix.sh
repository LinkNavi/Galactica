#!/bin/bash
# Comprehensive Galactica Fix - Libraries and Console
set -e

ROOTFS="galactica-rootfs.img"
BUILD_DIR="galactica-build"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Galactica Comprehensive Fix ===${NC}"
echo ""

if [[ ! -f "$ROOTFS" ]] || [[ ! -d "$BUILD_DIR" ]]; then
    echo -e "${RED}Error: Missing rootfs or build directory${NC}"
    exit 1
fi

echo "This will fix:"
echo "  1. Missing libraries in rootfs"
echo "  2. Library symlinks and search paths"
echo "  3. Verify all binaries can load"
echo ""
read -p "Continue? (y/n) [y]: " confirm
confirm=${confirm:-y}
[[ "$confirm" != "y" ]] && exit 0

echo ""
echo -e "${GREEN}=== Step 1: Mount Rootfs ===${NC}"
mkdir -p /tmp/galactica-fix
sudo mount -o loop "$ROOTFS" /tmp/galactica-fix || {
    echo -e "${RED}Failed to mount rootfs${NC}"
    exit 1
}

echo ""
echo -e "${GREEN}=== Step 2: Check Current State ===${NC}"
LIBS_BEFORE=$(sudo find /tmp/galactica-fix -name "*.so*" 2>/dev/null | wc -l)
echo "Libraries currently in rootfs: $LIBS_BEFORE"

LIBS_IN_BUILD=$(find "$BUILD_DIR" -name "*.so*" 2>/dev/null | wc -l)
echo "Libraries in build directory: $LIBS_IN_BUILD"

if [[ $LIBS_IN_BUILD -gt 10 ]] && [[ $LIBS_BEFORE -lt 10 ]]; then
    echo -e "${YELLOW}Libraries exist in build dir but not in rootfs!${NC}"
    echo "This means the rootfs creation step didn't copy them."
fi

echo ""
echo -e "${GREEN}=== Step 3: Copy All Libraries ===${NC}"

# Method 1: Copy from build directory
if [[ -d "$BUILD_DIR/lib" ]]; then
    echo "Copying from $BUILD_DIR/lib..."
    sudo cp -av "$BUILD_DIR/lib/"* /tmp/galactica-fix/lib/ 2>&1 | grep -v "omitting directory" | head -20
fi

if [[ -d "$BUILD_DIR/lib64" ]]; then
    echo "Copying from $BUILD_DIR/lib64..."
    sudo mkdir -p /tmp/galactica-fix/lib64
    sudo cp -av "$BUILD_DIR/lib64/"* /tmp/galactica-fix/lib64/ 2>&1 | grep -v "omitting directory" | head -20
fi

if [[ -d "$BUILD_DIR/usr/lib" ]]; then
    echo "Copying from $BUILD_DIR/usr/lib..."
    sudo mkdir -p /tmp/galactica-fix/usr/lib
    sudo cp -av "$BUILD_DIR/usr/lib/"* /tmp/galactica-fix/usr/lib/ 2>&1 | grep -v "omitting directory" | head -20
fi

# Method 2: Also copy directly from host system as backup
echo ""
echo "Also copying critical libraries from host system..."

CRITICAL_LIBS=(
    "libc.so.6"
    "libm.so.6"
    "libdl.so.2"
    "libpthread.so.0"
    "libgcc_s.so.1"
    "libstdc++.so.6"
    "ld-linux-x86-64.so.2"
)

for lib in "${CRITICAL_LIBS[@]}"; do
    # Find library on host
    LIB_PATH=$(find /lib* /usr/lib* -name "$lib" 2>/dev/null | head -1)
    if [[ -n "$LIB_PATH" ]]; then
        # Determine destination
        if [[ "$lib" == "ld-linux-x86-64.so.2" ]]; then
            DEST="/tmp/galactica-fix/lib64/$lib"
            sudo mkdir -p /tmp/galactica-fix/lib64
        else
            DEST="/tmp/galactica-fix/lib/$lib"
            sudo mkdir -p /tmp/galactica-fix/lib
        fi
        
        # Copy if not exists
        if [[ ! -f "$DEST" ]]; then
            sudo cp -L "$LIB_PATH" "$DEST"
            echo -e "  ${GREEN}✓${NC} Copied $lib"
        else
            echo -e "  ${GREEN}✓${NC} $lib already present"
        fi
    else
        echo -e "  ${YELLOW}!${NC} $lib not found on host"
    fi
done

echo ""
echo -e "${GREEN}=== Step 4: Create Library Symlinks ===${NC}"

# Enter rootfs to create symlinks
cd /tmp/galactica-fix

# Create lib -> lib64 compatibility if needed
if [[ -d lib64 ]] && [[ ! -L lib/x86_64-linux-gnu ]]; then
    sudo mkdir -p lib
    cd lib
    # Create symlinks for common library files from lib64
    for lib in ../lib64/*.so*; do
        [[ ! -f "$lib" ]] && continue
        BASENAME=$(basename "$lib")
        if [[ ! -e "$BASENAME" ]]; then
            sudo ln -sf "../lib64/$BASENAME" "$BASENAME"
            echo -e "  ${GREEN}✓${NC} lib/$BASENAME -> ../lib64/$BASENAME"
        fi
    done
    cd ..
fi

# Create .so -> .so.X symlinks in all lib directories
for libdir in lib lib64 usr/lib; do
    [[ ! -d "$libdir" ]] && continue
    cd "$libdir"
    
    for lib in *.so.*; do
        [[ ! -f "$lib" ]] && continue
        
        # Extract base name (e.g., libc.so.6 -> libc.so)
        BASE=$(echo "$lib" | sed 's/\.so\..*/\.so/')
        if [[ "$BASE" != "$lib" ]] && [[ ! -e "$BASE" ]]; then
            sudo ln -sf "$lib" "$BASE"
            echo -e "  ${GREEN}✓${NC} $libdir/$BASE -> $lib"
        fi
    done
    
    cd /tmp/galactica-fix
done

cd - > /dev/null

echo ""
echo -e "${GREEN}=== Step 5: Configure Dynamic Linker ===${NC}"

# Create ld.so.conf
cat << 'EOFLD' | sudo tee /tmp/galactica-fix/etc/ld.so.conf > /dev/null
/lib
/lib64
/usr/lib
/usr/lib64
EOFLD
echo -e "${GREEN}✓${NC} Created /etc/ld.so.conf"

# Create ld.so.conf.d directory
sudo mkdir -p /tmp/galactica-fix/etc/ld.so.conf.d

echo ""
echo -e "${GREEN}=== Step 6: Verify Libraries ===${NC}"

LIBS_AFTER=$(sudo find /tmp/galactica-fix -name "*.so*" 2>/dev/null | wc -l)
echo "Libraries now in rootfs: $LIBS_AFTER"

if [[ $LIBS_AFTER -gt $LIBS_BEFORE ]]; then
    ADDED=$((LIBS_AFTER - LIBS_BEFORE))
    echo -e "${GREEN}✓ Added $ADDED libraries${NC}"
else
    echo -e "${YELLOW}! No new libraries added${NC}"
fi

# Check specific libraries needed by our binaries
echo ""
echo "Checking critical libraries:"

check_lib() {
    local lib=$1
    if sudo find /tmp/galactica-fix -name "$lib" | grep -q .; then
        echo -e "  ${GREEN}✓${NC} $lib"
        return 0
    else
        echo -e "  ${RED}✗${NC} $lib MISSING"
        return 1
    fi
}

MISSING=0
check_lib "libc.so.6" || MISSING=$((MISSING+1))
check_lib "libm.so.6" || MISSING=$((MISSING+1))
check_lib "libstdc++.so.6" || MISSING=$((MISSING+1))
check_lib "libgcc_s.so.1" || MISSING=$((MISSING+1))
check_lib "ld-linux-x86-64.so.2" || MISSING=$((MISSING+1))

echo ""
echo -e "${GREEN}=== Step 7: Test Binary Loading ===${NC}"

# Try to check if binaries would load (limited by chroot)
echo "Testing if /sbin/airride can find its libraries..."

# Create a test script
cat << 'EOFTEST' | sudo tee /tmp/galactica-fix/test-libs.sh > /dev/null
#!/bin/sh
export LD_LIBRARY_PATH=/lib:/lib64:/usr/lib
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo "Testing /sbin/airride..."
if [ -x /sbin/airride ]; then
    echo "Binary is executable"
    # Try to get help output (it should fail but show it tried to load)
    /sbin/airride --help 2>&1 | head -5 || echo "Binary attempted to execute"
else
    echo "Binary not executable!"
fi
EOFTEST

sudo chmod +x /tmp/galactica-fix/test-libs.sh

# Run test in chroot (requires /bin/sh to work)
if sudo chroot /tmp/galactica-fix /bin/sh -c "test -x /sbin/airride"; then
    echo -e "${GREEN}✓${NC} /sbin/airride is executable in rootfs"
else
    echo -e "${RED}✗${NC} /sbin/airride not executable"
fi

echo ""
echo -e "${GREEN}=== Step 8: Cleanup ===${NC}"
sudo rm -f /tmp/galactica-fix/test-libs.sh

# Ensure permissions
sudo chmod 755 /tmp/galactica-fix/sbin/init
sudo chmod 755 /tmp/galactica-fix/sbin/airride
sudo chmod 755 /tmp/galactica-fix/bin/sh

echo ""
echo -e "${GREEN}=== Step 9: Unmount ===${NC}"
sync
sudo umount /tmp/galactica-fix
rmdir /tmp/galactica-fix

echo ""
echo -e "${GREEN}=== Fix Complete! ===${NC}"
echo ""
echo "Summary:"
echo "  Libraries before: $LIBS_BEFORE"
echo "  Libraries after:  $LIBS_AFTER"
echo "  Added:            $((LIBS_AFTER - LIBS_BEFORE))"

if [[ $MISSING -gt 0 ]]; then
    echo -e "  ${RED}Missing critical libs: $MISSING${NC}"
    echo ""
    echo "Some critical libraries are still missing!"
    echo "Your system may not boot properly."
else
    echo -e "  ${GREEN}✓ All critical libraries present${NC}"
fi

echo ""
echo "Next steps:"
echo "  1. Verify: ${YELLOW}./diagnose.sh${NC}"
echo "  2. Boot:   ${YELLOW}./debug-boot.sh${NC} (choose mode 2 for emergency shell)"
echo ""

if [[ $LIBS_AFTER -lt 10 ]]; then
    echo -e "${RED}WARNING: Still very few libraries!${NC}"
    echo ""
    echo "The sync from build directory may have failed."
    echo "Try manually copying:"
    echo "  sudo mount -o loop $ROOTFS /mnt"
    echo "  sudo cp -r $BUILD_DIR/usr/lib/* /mnt/usr/lib/"
    echo "  sudo umount /mnt"
fi
