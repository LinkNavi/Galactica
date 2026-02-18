#!/bin/bash
# Check kernel configuration for required drivers

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${CYAN}=== Kernel Config Checker ===${NC}"
echo ""

# Look for kernel config in common locations
CONFIG_LOCATIONS=(
    "/home/kirby/Programming/Galactica/galactica-build/boot/config-6.18.4"
    "/home/kirby/Programming/Galactica/linux-6.18.4/.config"
    "/home/kirby/Programming/Galactica/kernel/.config"
    "/boot/config-$(uname -r)"
)

CONFIG_FILE=""
for loc in "${CONFIG_LOCATIONS[@]}"; do
    if [ -f "$loc" ]; then
        CONFIG_FILE="$loc"
        break
    fi
done

if [ -z "$CONFIG_FILE" ]; then
    echo -e "${RED}✗ Could not find kernel .config file${NC}"
    echo ""
    echo "Please locate your kernel source directory and run:"
    echo "  cd /path/to/linux-source"
    echo "  cat .config | grep -E 'ATA|SCSI|VIRTIO_BLK|BLK_DEV_SD'"
    echo ""
    echo "Or if you have the config in /boot:"
    echo "  zcat /proc/config.gz | grep -E 'ATA|SCSI|VIRTIO_BLK|BLK_DEV_SD'"
    exit 1
fi

echo -e "${GREEN}✓ Found config: $CONFIG_FILE${NC}"
echo ""

# Check critical disk drivers
echo -e "${CYAN}=== Critical Disk Driver Settings ===${NC}"
echo ""

REQUIRED_CONFIGS=(
    "CONFIG_ATA"
    "CONFIG_SATA_AHCI"
    "CONFIG_ATA_PIIX"
    "CONFIG_BLK_DEV_SD"
    "CONFIG_SCSI"
    "CONFIG_SCSI_LOWLEVEL"
    "CONFIG_VIRTIO"
    "CONFIG_VIRTIO_BLK"
    "CONFIG_VIRTIO_PCI"
)

MISSING=0
MODULES=0
BUILTIN=0

for conf in "${REQUIRED_CONFIGS[@]}"; do
    VALUE=$(grep "^${conf}=" "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$VALUE" ]; then
        echo -e "${RED}✗ $conf: not set${NC}"
        ((MISSING++))
    elif [[ "$VALUE" == *"=y"* ]]; then
        echo -e "${GREEN}✓ $conf: built-in${NC}"
        ((BUILTIN++))
    elif [[ "$VALUE" == *"=m"* ]]; then
        echo -e "${YELLOW}⚠ $conf: module (needs initramfs!)${NC}"
        ((MODULES++))
    else
        echo -e "${YELLOW}? $conf: $VALUE${NC}"
    fi
done

echo ""
echo -e "${CYAN}=== Summary ===${NC}"
echo "Built-in: $BUILTIN"
echo "Modules: $MODULES"
echo "Missing: $MISSING"
echo ""

if [ $MODULES -gt 0 ]; then
    echo -e "${YELLOW}⚠ Some drivers are compiled as modules!${NC}"
    echo "Without an initramfs, these won't load during boot."
    echo ""
    echo "Solutions:"
    echo "1. Rebuild kernel with drivers built-in (=y)"
    echo "2. Create an initramfs"
    echo ""
fi

if [ $MISSING -gt 0 ]; then
    echo -e "${RED}✗ Some required drivers are missing!${NC}"
    echo "You need to enable these in kernel config and rebuild."
    echo ""
fi

if [ $BUILTIN -lt 3 ]; then
    echo -e "${RED}⚠ Not enough disk drivers built into kernel!${NC}"
    echo ""
    echo -e "${CYAN}Required kernel config for QEMU:${NC}"
    echo ""
    cat << 'EOF'
# Basic block device support
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y

# SCSI support (needed for SATA/AHCI)
CONFIG_SCSI=y
CONFIG_SCSI_LOWLEVEL=y
CONFIG_BLK_DEV_SD=y

# ATA/SATA support
CONFIG_ATA=y
CONFIG_SATA_AHCI=y
CONFIG_ATA_PIIX=y

# For QEMU with -drive if=virtio
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=y

# File systems
CONFIG_EXT4_FS=y
EOF
    echo ""
    echo -e "${YELLOW}To fix:${NC}"
    echo "1. cd to your kernel source directory"
    echo "2. Run: make menuconfig"
    echo "3. Enable the configs above (press Y to build-in, not M)"
    echo "4. Save and rebuild: make -j\$(nproc)"
    echo "5. Copy new kernel to galactica-build/boot/"
else
    echo -e "${GREEN}✓ Kernel config looks good!${NC}"
    echo ""
    echo "The drivers are built-in, so the issue might be:"
    echo "1. Wrong disk interface in QEMU"
    echo "2. Kernel binary doesn't match config"
    echo ""
    echo "Try booting with IDE interface:"
    echo "  ./boot-ide.sh"
fi
