#!/bin/bash
# Improved cleanup script - removes copied files AND unneeded scripts

set -e

TARGET_ROOT="${1:-./galactica-build}"

if [[ ! -d "$TARGET_ROOT" ]]; then
    echo "Error: Target directory $TARGET_ROOT does not exist"
    exit 1
fi

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=== Galactica Cleanup (Enhanced) ===${NC}"
echo "Target: $TARGET_ROOT"
echo ""
echo "This will:"
echo "  1. Remove copied binaries and libraries"
echo "  2. Keep: boot/, lib/modules/, etc/airride/, AirRide binaries"
echo "  3. Remove unnecessary build scripts"
echo ""

read -p "Continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}Phase 1: Cleaning build directory${NC}"
echo ""

cd "$TARGET_ROOT"

# Remove copied binaries but keep directories we want
echo "Cleaning bin/..."
if [[ -d bin ]]; then
    rm -rf bin/* 2>/dev/null || true
fi

# Remove everything from sbin/ except airride
echo "Cleaning sbin/..."
if [[ -d sbin ]]; then
    find sbin/ -type f ! -name "airride" -delete 2>/dev/null || true
    find sbin/ -type l ! -name "init" -delete 2>/dev/null || true
fi

# Remove usr/bin except airridectl and dreamland
echo "Cleaning usr/bin/..."
if [[ -d usr/bin ]]; then
    find usr/bin/ -type f ! -name "airridectl" ! -name "dreamland" -delete 2>/dev/null || true
    find usr/bin/ -type l ! -name "dl" -delete 2>/dev/null || true
fi

# Remove usr/sbin
echo "Cleaning usr/sbin/..."
if [[ -d usr/sbin ]]; then
    rm -rf usr/sbin/* 2>/dev/null || true
fi

# Remove library directories but preserve kernel modules
echo "Cleaning library directories..."
if [[ -d lib ]]; then
    find lib/ -mindepth 1 -maxdepth 1 ! -name "modules" -exec rm -rf {} + 2>/dev/null || true
fi

if [[ -d lib64 ]]; then
    rm -rf lib64/* 2>/dev/null || true
fi

if [[ -d usr/lib ]]; then
    rm -rf usr/lib/* 2>/dev/null || true
fi

if [[ -d usr/lib64 ]]; then
    rm -rf usr/lib64/* 2>/dev/null || true
fi

# Remove copied config files in etc/ but preserve airride/
echo "Cleaning etc/..."
if [[ -d etc ]]; then
    find etc/ -mindepth 1 -maxdepth 1 ! -name "airride" -exec rm -rf {} + 2>/dev/null || true
fi

# Remove root config files
if [[ -f root/.bashrc ]]; then
    rm -f root/.bashrc
fi

# Remove device nodes
echo "Removing device nodes..."
if [[ -d dev ]]; then
    sudo rm -f dev/null dev/zero dev/random dev/urandom dev/console dev/tty* dev/sda* dev/vda* 2>/dev/null || true
fi

# Remove usr/share directories
if [[ -d usr/share ]]; then
    echo "Cleaning usr/share/..."
    rm -rf usr/share/* 2>/dev/null || true
fi

# Remove empty directories
echo "Removing empty directories..."
find . -type d -empty -delete 2>/dev/null || true

cd ..

echo ""
echo -e "${GREEN}Phase 2: Cleaning unnecessary scripts${NC}"
echo ""

# Scripts to keep
KEEP_SCRIPTS=(
    "build-and-launch.sh"
    "bootstrap.sh"
    "run-galactica.sh"
    "run-galactica-debug.sh"
    "cleanup-essentials.sh"
    "verify.sh"
)

# Scripts to remove
REMOVE_SCRIPTS=(
    "copy-essentials.sh"
    "create-initramfs.sh"
    "run-qemu.sh"
    "run-qemu-debug.sh"
    "run-qemu-direct.sh"
    "run-qemu-disk.sh"
    "run-qemu-initramfs.sh"
    "galactica-rootfs.img"
    "setup-qemu-boot.sh"
    "kernel-build.log"
    "kernel-cache"
    "linux-*"
)

for script in "${REMOVE_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        echo "Removing: $script"
        rm -f "$script"
    fi
done

echo ""
echo -e "${GREEN}=== Cleanup Complete! ===${NC}"
echo ""
echo "Preserved in build directory:"
echo "  ✓ boot/ (kernel files)"
echo "  ✓ lib/modules/ (kernel modules)"
echo "  ✓ etc/airride/ (AirRide config)"
echo "  ✓ sbin/airride (AirRide init)"
echo "  ✓ sbin/init (symlink)"
echo "  ✓ usr/bin/airridectl (AirRide control)"
echo "  ✓ usr/bin/dreamland (Package manager)"
echo "  ✓ usr/bin/dl (symlink to dreamland)"
echo ""
echo "Preserved scripts:"
for script in "${KEEP_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        echo "  ✓ $script"
    fi
done
echo ""
echo "Your directory is now clean and ready for git!"
echo ""
echo "Next steps:"
echo "  1. Add busybox: sudo cp /bin/busybox $TARGET_ROOT/bin/"
echo "  2. Create symlinks: cd $TARGET_ROOT/bin && for cmd in sh ls cat; do ln -s busybox \$cmd; done"
echo "  3. Rebuild rootfs: ./build-and-launch.sh (or run steps manually)"
