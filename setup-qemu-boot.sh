#!/bin/bash
# Setup script to prepare Galactica for QEMU boot

set -e

TARGET_ROOT="${1:-./galactica-build}"

if [[ ! -d "$TARGET_ROOT" ]]; then
    echo "Error: Target directory $TARGET_ROOT does not exist"
    exit 1
fi

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== Setting up Galactica for QEMU Boot ===${NC}"
echo ""

cd "$TARGET_ROOT"

# ============================================
# 1. Create Essential Directories
# ============================================
echo -e "${GREEN}[1/8]${NC} Creating essential directories..."

mkdir -p {bin,dev,etc,home,mnt,opt,proc,root,run,sys,tmp,var}
mkdir -p etc/{airride,init.d}
mkdir -p var/{log,tmp,cache}
mkdir -p home/user

chmod 1777 tmp
chmod 700 root

# ============================================
# 2. Create Init as PID 1
# ============================================
echo -e "${GREEN}[2/8]${NC} Setting up init system..."

# Create init symlink pointing to airride
ln -sf /sbin/airride sbin/init

# Verify airride is executable
if [[ ! -x sbin/airride ]]; then
    echo -e "${RED}Error: sbin/airride is not executable!${NC}"
    exit 1
fi

# ============================================
# 3. Create Device Nodes
# ============================================
echo -e "${GREEN}[3/8]${NC} Creating device nodes..."

# Essential device nodes (QEMU needs these)
sudo mknod -m 666 dev/null c 1 3 2>/dev/null || true
sudo mknod -m 666 dev/zero c 1 5 2>/dev/null || true
sudo mknod -m 666 dev/random c 1 8 2>/dev/null || true
sudo mknod -m 666 dev/urandom c 1 9 2>/dev/null || true
sudo mknod -m 600 dev/console c 5 1 2>/dev/null || true
sudo mknod -m 666 dev/tty c 5 0 2>/dev/null || true
sudo mknod -m 666 dev/tty0 c 4 0 2>/dev/null || true

# Block devices for root filesystem
sudo mknod -m 660 dev/sda b 8 0 2>/dev/null || true
sudo mknod -m 660 dev/sda1 b 8 1 2>/dev/null || true
sudo mknod -m 660 dev/vda b 253 0 2>/dev/null || true
sudo mknod -m 660 dev/vda1 b 253 1 2>/dev/null || true

# ============================================
# 4. Create Essential System Files
# ============================================
echo -e "${GREEN}[4/8]${NC} Creating system configuration files..."

# /etc/fstab
cat > etc/fstab << 'EOF'
# <filesystem> <mount point> <type> <options> <dump> <pass>
proc           /proc         proc   defaults          0      0
sysfs          /sys          sysfs  defaults          0      0
devtmpfs       /dev          devtmpfs defaults        0      0
tmpfs          /run          tmpfs  defaults          0      0
tmpfs          /tmp          tmpfs  defaults          0      0
EOF

# /etc/passwd
cat > etc/passwd << 'EOF'
root:x:0:0:root:/root:/bin/sh
EOF

# /etc/group
cat > etc/group << 'EOF'
root:x:0:
EOF

# /etc/shadow (root with no password initially)
cat > etc/shadow << 'EOF'
root::19000:0:99999:7:::
EOF
chmod 600 etc/shadow

# /etc/hostname
echo "galactica" > etc/hostname

# /etc/hosts
cat > etc/hosts << 'EOF'
127.0.0.1   localhost
127.0.1.1   galactica
::1         localhost ip6-localhost ip6-loopback
EOF

# /etc/inittab (even though AirRide doesn't use it, good to have)
cat > etc/inittab << 'EOF'
# AirRide Init System
# Services are managed through /etc/airride/services/
EOF

# /etc/profile
cat > etc/profile << 'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export HOME=/root
export TERM=linux
PS1='[\u@\h \W]\$ '
EOF

# ============================================
# 5. Create Emergency Shell Service
# ============================================
echo -e "${GREEN}[5/8]${NC} Creating emergency shell service..."

mkdir -p etc/airride/services

cat > etc/airride/services/shell.service << 'EOF'
[Service]
name=shell
description=Emergency Shell
type=simple
exec_start=/bin/sh
restart=always
restart_delay=1

[Dependencies]
EOF

# ============================================
# 6. Create Shell (Minimal busybox-like)
# ============================================
echo -e "${GREEN}[6/8]${NC} Setting up basic shell..."

# If we don't have a shell, we need to add busybox or bash
if [[ ! -f bin/sh ]]; then
    echo -e "${YELLOW}Warning: No shell found in bin/sh${NC}"
    echo "You need to either:"
    echo "  1. Copy /bin/busybox and create symlinks"
    echo "  2. Copy /bin/bash and libraries"
    echo ""
    echo "Quick fix with busybox:"
    echo "  sudo cp /bin/busybox $TARGET_ROOT/bin/"
    echo "  cd $TARGET_ROOT/bin"
    echo "  for cmd in sh ash ls cat; do ln -s busybox \$cmd; done"
fi

# ============================================
# 7. Create Initramfs (Optional but Recommended)
# ============================================
echo -e "${GREEN}[7/8]${NC} Preparing for initramfs generation..."

cat > ../create-initramfs.sh << 'INITRAMFS_EOF'
#!/bin/bash
# Generate initramfs for Galactica

set -e

TARGET_ROOT="./galactica-build"
INITRAMFS_DIR="./initramfs-build"
OUTPUT="galactica-initramfs.cpio.gz"

echo "Creating initramfs..."

# Create temporary directory
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"

cd "$INITRAMFS_DIR"

# Create basic structure
mkdir -p {bin,sbin,etc,proc,sys,dev,run,tmp,lib,lib64,usr/bin,usr/sbin}

# Copy init (AirRide)
cp ../"$TARGET_ROOT"/sbin/airride sbin/init

# Copy essential binaries (if you have them)
if [[ -f ../"$TARGET_ROOT"/bin/sh ]]; then
    cp ../"$TARGET_ROOT"/bin/sh bin/
fi

# Copy libraries needed by init
if command -v ldd &>/dev/null; then
    echo "Copying libraries for init..."
    for lib in $(ldd ../galactica-build/sbin/airride | grep -o '/lib[^ ]*'); do
        if [[ -f "$lib" ]]; then
            mkdir -p ".$(dirname $lib)"
            cp "$lib" ".$lib" 2>/dev/null || true
        fi
    done
fi

# Create device nodes
sudo mknod -m 600 dev/console c 5 1
sudo mknod -m 666 dev/null c 1 3
sudo mknod -m 666 dev/zero c 1 5
sudo mknod -m 666 dev/tty c 5 0

# Create init script wrapper (optional)
cat > init << 'EOF'
#!/sbin/init
# This is executed as PID 1
exec /sbin/init "$@"
EOF
chmod +x init

# Generate cpio archive
echo "Creating cpio archive..."
find . -print0 | cpio --null --create --verbose --format=newc | gzip -9 > "../$OUTPUT"

cd ..
echo "Initramfs created: $OUTPUT"
echo "Size: $(du -h $OUTPUT | cut -f1)"
INITRAMFS_EOF

chmod +x ../create-initramfs.sh

# ============================================
# 8. Create QEMU Launch Script
# ============================================
echo -e "${GREEN}[8/8]${NC} Creating QEMU launch script..."

cat > ../run-qemu.sh << 'QEMU_EOF'
#!/bin/bash
# Launch Galactica in QEMU

set -e

KERNEL="galactica-build/boot/vmlinuz-galactica"
INITRAMFS="galactica-initramfs.cpio.gz"
ROOTFS="galactica-rootfs.img"

# Check if kernel exists
if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found at $KERNEL"
    exit 1
fi

# Create root filesystem image (if it doesn't exist)
if [[ ! -f "$ROOTFS" ]]; then
    echo "Creating root filesystem image..."
    
    # Create a 1GB ext4 image
    dd if=/dev/zero of="$ROOTFS" bs=1M count=1024
    mkfs.ext4 -F "$ROOTFS"
    
    # Mount and copy files
    mkdir -p mnt
    sudo mount -o loop "$ROOTFS" mnt
    sudo cp -a galactica-build/* mnt/
    sudo umount mnt
    rmdir mnt
    
    echo "Root filesystem created: $ROOTFS"
fi

# QEMU command
QEMU_CMD=(
    qemu-system-x86_64
    -kernel "$KERNEL"
    -m 512M
    -smp 2
    -drive "file=$ROOTFS,format=raw,if=virtio"
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init"
    -nographic
    -serial mon:stdio
)

# Add initramfs if it exists
if [[ -f "$INITRAMFS" ]]; then
    QEMU_CMD+=(-initrd "$INITRAMFS")
fi

echo "Starting QEMU..."
echo "Command: ${QEMU_CMD[@]}"
echo ""
echo "Press Ctrl+A then X to exit QEMU"
echo ""

"${QEMU_CMD[@]}"
QEMU_EOF

chmod +x ../run-qemu.sh

# ============================================
# Alternative: Direct kernel boot (no disk)
# ============================================
cat > ../run-qemu-direct.sh << 'QEMU_DIRECT_EOF'
#!/bin/bash
# Launch Galactica directly from kernel (no disk image)

set -e

KERNEL="galactica-build/boot/vmlinuz-galactica"

if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found at $KERNEL"
    exit 1
fi

echo "Starting QEMU with direct kernel boot..."
echo "This boots directly into your AirRide init system"
echo ""

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -m 256M \
    -smp 1 \
    -append "console=ttyS0 init=/sbin/airride" \
    -nographic \
    -serial mon:stdio

# Note: This won't work without an initramfs containing your init system!
QEMU_DIRECT_EOF

chmod +x ../run-qemu-direct.sh

# ============================================
# Summary
# ============================================
echo ""
echo -e "${GREEN}=== Setup Complete! ===${NC}"
echo ""
echo "Created:"
echo "  ✓ Essential directory structure"
echo "  ✓ Device nodes"
echo "  ✓ System configuration files"
echo "  ✓ Init system setup"
echo "  ✓ Emergency shell service"
echo ""
echo "Scripts created:"
echo "  • ../create-initramfs.sh - Generate initramfs"
echo "  • ../run-qemu.sh - Boot from disk image"
echo "  • ../run-qemu-direct.sh - Direct kernel boot"
echo ""
echo "Next steps:"
echo ""
echo "1. Add a shell (REQUIRED):"
echo "   ${YELLOW}sudo cp /bin/busybox $TARGET_ROOT/bin/${NC}"
echo "   ${YELLOW}cd $TARGET_ROOT/bin && ln -s busybox sh${NC}"
echo ""
echo "2. Create initramfs:"
echo "   ${YELLOW}../create-initramfs.sh${NC}"
echo ""
echo "3. Boot in QEMU:"
echo "   ${YELLOW}../run-qemu.sh${NC}"
echo ""
echo "Missing components to add:"
echo "  • Shell binary (busybox or bash + libraries)"
echo "  • Basic utilities (ls, cat, echo, etc.)"
echo "  • C library (libc.so.6 and ld-linux.so.2)"
echo ""
echo "Quick bootstrap option:"
echo "  ${YELLOW}./copy-essentials.sh $TARGET_ROOT${NC}"
