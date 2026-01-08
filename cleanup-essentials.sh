#!/bin/bash
# Script to clean up copied binaries and libraries from Galactica build

set -e

TARGET_ROOT="${1:-./galactica-build}"

if [[ ! -d "$TARGET_ROOT" ]]; then
    echo "Error: Target directory $TARGET_ROOT does not exist"
    exit 1
fi

echo "=== Cleaning Galactica Build Directory ==="
echo "Target: $TARGET_ROOT"
echo ""

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${YELLOW}WARNING: This will remove all copied binaries and libraries${NC}"
echo -e "${YELLOW}It will keep: boot/, lib/modules/, etc/airride/, and AirRide binaries${NC}"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [[ "$confirm" != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo -e "${RED}[*]${NC} Removing copied binaries..."

# Remove copied binaries but keep directories we want
cd "$TARGET_ROOT"

# Keep a list of what to preserve
PRESERVE=(
    "boot"
    "lib/modules"
    "etc/airride"
    "sbin/airride"
    "usr/bin/airridectl"
)

# Remove everything from bin/ except what we preserve
if [[ -d bin ]]; then
    echo "Cleaning bin/..."
    rm -rf bin/* 2>/dev/null || true
fi

# Remove everything from sbin/ except airride
if [[ -d sbin ]]; then
    echo "Cleaning sbin/..."
    find sbin/ -type f ! -name "airride" -delete 2>/dev/null || true
fi

# Remove usr/bin except airridectl
if [[ -d usr/bin ]]; then
    echo "Cleaning usr/bin/..."
    find usr/bin/ -type f ! -name "airridectl" -delete 2>/dev/null || true
fi

# Remove usr/sbin
if [[ -d usr/sbin ]]; then
    echo "Cleaning usr/sbin/..."
    rm -rf usr/sbin/* 2>/dev/null || true
fi

# Remove library directories but preserve kernel modules
echo "Cleaning library directories..."

# Remove lib/ contents except modules/
if [[ -d lib ]]; then
    find lib/ -mindepth 1 -maxdepth 1 ! -name "modules" -exec rm -rf {} + 2>/dev/null || true
fi

# Remove lib64/ completely
if [[ -d lib64 ]]; then
    rm -rf lib64/* 2>/dev/null || true
fi

# Remove usr/lib/ contents
if [[ -d usr/lib ]]; then
    rm -rf usr/lib/* 2>/dev/null || true
fi

# Remove usr/lib64/
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

# Remove device nodes (if they were created)
echo "Removing device nodes..."
if [[ -d dev ]]; then
    sudo rm -f dev/null dev/zero dev/random dev/urandom dev/console dev/tty 2>/dev/null || true
fi

# Remove usr/share directories
if [[ -d usr/share ]]; then
    echo "Cleaning usr/share/..."
    rm -rf usr/share/* 2>/dev/null || true
fi

# Remove empty directories
echo "Removing empty directories..."
find . -type d -empty -delete 2>/dev/null || true

echo ""
echo -e "${GREEN}=== Cleanup Complete! ===${NC}"
echo ""
echo "Preserved:"
echo "  ✓ boot/ (kernel files)"
echo "  ✓ lib/modules/ (kernel modules)"
echo "  ✓ etc/airride/ (AirRide config)"
echo "  ✓ sbin/airride (AirRide init)"
echo "  ✓ usr/bin/airridectl (AirRide control)"
echo ""
echo "Your build directory is now clean and ready for git!"
