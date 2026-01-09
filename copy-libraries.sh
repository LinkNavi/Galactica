#!/bin/bash
# Simple library copy script - direct approach

set -e

ROOTFS="galactica-rootfs.img"

echo "=== Simple Library Copy ==="
echo ""

if [[ ! -f "$ROOTFS" ]]; then
    echo "Error: $ROOTFS not found"
    exit 1
fi

read -p "This will copy ALL system libraries to your rootfs. Continue? (y/n): " confirm
[[ "$confirm" != "y" ]] && exit 0

# Mount
echo "Mounting rootfs..."
mkdir -p /tmp/galactica-fix
sudo mount -o loop "$ROOTFS" /tmp/galactica-fix

# Create lib directories
echo "Creating library directories..."
sudo mkdir -p /tmp/galactica-fix/lib
sudo mkdir -p /tmp/galactica-fix/lib64
sudo mkdir -p /tmp/galactica-fix/usr/lib

# Copy ALL libraries from host system
echo ""
echo "Copying libraries from host system..."

# Method 1: Copy from /lib/x86_64-linux-gnu (Ubuntu/Debian)
if [[ -d /lib/x86_64-linux-gnu ]]; then
    echo "Copying from /lib/x86_64-linux-gnu..."
    sudo cp -av /lib/x86_64-linux-gnu/*.so* /tmp/galactica-fix/lib/ 2>/dev/null || true
    COUNT1=$(find /tmp/galactica-fix/lib -name "*.so*" | wc -l)
    echo "  Copied $COUNT1 files"
fi

# Method 2: Copy from /usr/lib/x86_64-linux-gnu
if [[ -d /usr/lib/x86_64-linux-gnu ]]; then
    echo "Copying from /usr/lib/x86_64-linux-gnu..."
    sudo cp -av /usr/lib/x86_64-linux-gnu/*.so* /tmp/galactica-fix/usr/lib/ 2>/dev/null || true
    COUNT2=$(find /tmp/galactica-fix/usr/lib -name "*.so*" | wc -l)
    echo "  Copied $COUNT2 files"
fi

# Method 3: Copy from /lib64 (dynamic linker)
if [[ -d /lib64 ]]; then
    echo "Copying from /lib64..."
    sudo cp -av /lib64/ld-linux-x86-64.so* /tmp/galactica-fix/lib64/ 2>/dev/null || true
fi

# Method 4: Copy from /lib (if exists)
if [[ -d /lib ]] && [[ ! -L /lib ]]; then
    echo "Copying from /lib..."
    sudo cp -av /lib/*.so* /tmp/galactica-fix/lib/ 2>/dev/null || true
fi

# Ensure we have the dynamic linker in multiple places
echo ""
echo "Ensuring dynamic linker is present..."
if [[ -f /lib64/ld-linux-x86-64.so.2 ]]; then
    sudo cp -v /lib64/ld-linux-x86-64.so.2 /tmp/galactica-fix/lib64/ 2>/dev/null || true
    sudo cp -v /lib64/ld-linux-x86-64.so.2 /tmp/galactica-fix/lib/ 2>/dev/null || true
fi

# Create lib64 -> lib symlink if needed
if [[ ! -L /tmp/galactica-fix/lib64 ]]; then
    cd /tmp/galactica-fix
    sudo rm -rf lib64
    sudo ln -s lib lib64
    cd - > /dev/null
    echo "Created lib64 -> lib symlink"
fi

# Count total libraries
echo ""
TOTAL=$(find /tmp/galactica-fix -name "*.so*" | wc -l)
echo "Total libraries in rootfs: $TOTAL"

if [[ $TOTAL -lt 20 ]]; then
    echo ""
    echo "WARNING: Still not enough libraries!"
    echo ""
    echo "Your system may use a different library layout."
    echo "Check these directories on your host:"
    echo "  ls /lib/"
    echo "  ls /usr/lib/"
    echo "  ls /lib64/"
    echo ""
    echo "Then manually copy the .so files you need."
else
    echo "✓ Libraries copied successfully!"
fi

# Unmount
echo ""
echo "Unmounting..."
sync
sudo umount /tmp/galactica-fix
rmdir /tmp/galactica-fix

echo ""
echo "Done! Run ./diagnose.sh to verify."
