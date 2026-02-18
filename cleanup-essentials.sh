#!/bin/bash
# Galactica Enhanced Cleanup Script

set -e

TARGET_ROOT="${1:-./galactica-build}"

if [[ ! -d "$TARGET_ROOT" ]]; then
    echo "Error: Target directory $TARGET_ROOT does not exist"
    exit 1
fi

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}=== Galactica Enhanced Cleanup ===${NC}"
echo "Target: $TARGET_ROOT"
echo ""
echo "This will:"
echo "  1. Remove copied binaries and libraries from build directory"
echo "  2. Keep: boot/, lib/modules/, etc/airride/, core binaries"
echo "  3. Remove build artifacts (logs, caches, temporary files)"
echo "  4. Remove one-time use scripts"
echo "  5. Keep essential scripts for running/rebuilding"
echo "  6. Remove obsolete installer/test scripts"
echo ""

read -p "Continue? (yes/no): " confirm
if [[ "$confirm" != "yes" ]]; then
    echo "Cleanup cancelled."
    exit 0
fi

echo ""
echo -e "${GREEN}=== Phase 1: Cleaning build directory ===${NC}"
echo ""

cd "$TARGET_ROOT"

echo "Cleaning bin/..."
[[ -d bin ]] && rm -rf bin/* 2>/dev/null || true

echo "Cleaning sbin/ (keeping airride, network-setup, network-watchdog, poweroff, reboot, halt, shutdown, fix-input-perms, setup-xorg)..."
if [[ -d sbin ]]; then
    find sbin/ -type f \
        ! -name "airride" \
        ! -name "network-setup" \
        ! -name "network-watchdog" \
        ! -name "poweroff" \
        ! -name "reboot" \
        ! -name "halt" \
        ! -name "shutdown" \
        ! -name "fix-input-perms" \
        ! -name "setup-xorg" \
        -delete 2>/dev/null || true
    find sbin/ -type l ! -name "init" -delete 2>/dev/null || true
fi

echo "Cleaning usr/bin/ (keeping airridectl, dreamland, dl, startgui, wifi-connect, makeuser)..."
if [[ -d usr/bin ]]; then
    find usr/bin/ -type f \
        ! -name "airridectl" \
        ! -name "dreamland" \
        ! -name "startgui" \
        ! -name "wifi-connect" \
        ! -name "makeuser" \
        -delete 2>/dev/null || true
    find usr/bin/ -type l ! -name "dl" -delete 2>/dev/null || true
fi

echo "Cleaning usr/sbin/..."
[[ -d usr/sbin ]] && rm -rf usr/sbin/* 2>/dev/null || true

echo "Cleaning library directories (preserving kernel modules)..."
if [[ -d lib ]]; then
    find lib/ -mindepth 1 -maxdepth 1 ! -name "modules" -exec rm -rf {} + 2>/dev/null || true
fi
[[ -d lib64 ]]     && rm -rf lib64/* 2>/dev/null || true
[[ -d usr/lib ]]   && rm -rf usr/lib/* 2>/dev/null || true
[[ -d usr/lib64 ]] && rm -rf usr/lib64/* 2>/dev/null || true

echo "Cleaning etc/ (keeping airride/)..."
if [[ -d etc ]]; then
    find etc/ -mindepth 1 -maxdepth 1 ! -name "airride" -exec rm -rf {} + 2>/dev/null || true
fi

echo "Cleaning root config files..."
rm -f root/.bashrc root/.xinitrc 2>/dev/null || true

echo "Removing device nodes..."
if [[ -d dev ]]; then
    sudo rm -f dev/null dev/zero dev/random dev/urandom dev/console \
        dev/tty* dev/sda* dev/vda* dev/fb* 2>/dev/null || true
    sudo rm -rf dev/dri dev/input 2>/dev/null || true
fi

echo "Cleaning usr/share/..."
[[ -d usr/share ]] && rm -rf usr/share/* 2>/dev/null || true

echo "Removing empty directories..."
find . -type d -empty -delete 2>/dev/null || true

cd ..

echo ""
echo -e "${GREEN}=== Phase 2: Cleaning build artifacts ===${NC}"
echo ""

rm -f kernel-build.log kernel-rebuild*.log kernel-version.txt 2>/dev/null || true
rm -f boot-debug-*.log 2>/dev/null || true
find linux-*/ -name ".config.backup" -o -name ".config.before-fix" -o -name ".config.old" 2>/dev/null | xargs rm -f 2>/dev/null || true
rmdir mnt_tmp 2>/dev/null || true
echo "Build artifacts removed."

echo ""
echo -e "${GREEN}=== Phase 3: Cleaning temporary and obsolete scripts ===${NC}"
echo ""

# Scripts to remove — one-time use, superseded, or obsolete
REMOVE_SCRIPTS=(
    # Old copy/setup scripts
    "copy-essentials.sh"
    "copy-libraries.sh"
    "create-initramfs.sh"
    "add-login-screen.sh"
    "setup-qemu-boot.sh"

    # Old QEMU run scripts
    "run-qemu.sh"
    "run-qemu-debug.sh"
    "run-qemu-direct.sh"
    "run-qemu-disk.sh"
    "run-qemu-initramfs.sh"

    # Fix/patch scripts (no longer needed)
    "fix-libraries.sh"
    "sync-rootfs.sh"
    "comprehensive-fix.sh"
    "quick-kernel-fix.sh"
    "rebuild-kernel.sh"
    "kernel-fix.sh"
    "manual-fix-guide.sh"
    "fix-for-qemu.sh"
    "fix-loop.sh"
    "pam-fix.sh"

    # Debug/test scripts (one-time use)
    "chroot-debug.sh"
    "chroot.sh"
    "quick-chroot-test.sh"
    "check-rootfs-libs.sh"
    "check-kernel.sh"
    "password-test.sh"
    "test-boot.sh"
    "test-fix.sh"
    "debug.sh"

    # Installer test scripts (keep make-iso.sh instead)
    "installer-test.sh"
    "inspect-installation.sh"

    # Applied docs
    "BUILD-SCRIPT-PATCH.md"
    "dreamland-fixed-summary.md"
    "kernel-config-fixed.txt"
)

OPTIONAL_SCRIPTS=(
    "diagnose.sh"
    "debug-boot.sh"
    "run-galactica-debug.sh"
)

for script in "${REMOVE_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        rm -f "$script"
        echo "  Removed: $script"
    fi
done

echo ""
echo -e "${CYAN}Optional scripts:${NC}"
for script in "${OPTIONAL_SCRIPTS[@]}"; do
    [[ -f "$script" ]] && echo "  • $script"
done
echo ""
read -p "Remove optional debug scripts? (y/n) [n]: " remove_optional
remove_optional=${remove_optional:-n}
if [[ "$remove_optional" == "y" ]]; then
    for script in "${OPTIONAL_SCRIPTS[@]}"; do
        if [[ -f "$script" ]]; then
            rm -f "$script"
            echo "  Removed: $script"
        fi
    done
fi

echo ""
echo -e "${GREEN}=== Phase 4: Large directories ===${NC}"
echo ""

KERNEL_DIRS=$(find . -maxdepth 1 -type d -name "linux-*" 2>/dev/null)
if [[ -n "$KERNEL_DIRS" ]]; then
    echo "Found kernel source directories:"
    TOTAL_SIZE=0
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
        SIZE_MB=$(du -sm "$dir" 2>/dev/null | cut -f1)
        TOTAL_SIZE=$((TOTAL_SIZE + SIZE_MB))
        echo "  • $dir ($SIZE)"
        [[ -f "$dir/arch/x86/boot/bzImage" ]] && echo "    └─ Built kernel present"
    done <<< "$KERNEL_DIRS"
    echo ""
    echo "Total: ~${TOTAL_SIZE}MB"
    echo ""
    read -p "Remove ALL kernel source directories? (y/n) [y]: " remove_kernel
    remove_kernel=${remove_kernel:-y}
    if [[ "$remove_kernel" == "y" ]]; then
        while IFS= read -r dir; do
            [[ -z "$dir" ]] && continue
            echo "  Removing: $dir"
            rm -rf "$dir"
        done <<< "$KERNEL_DIRS"
        echo "  Freed: ~${TOTAL_SIZE}MB"
    fi
else
    echo "No kernel source directories found."
fi

# Kernel cache
if [[ -d kernel-cache ]]; then
    CACHE_SIZE=$(du -sh kernel-cache 2>/dev/null | cut -f1)
    echo ""
    echo "Kernel cache: kernel-cache/ ($CACHE_SIZE)"
    read -p "Remove kernel cache? (y/n) [n]: " remove_cache
    remove_cache=${remove_cache:-n}
    if [[ "$remove_cache" == "y" ]]; then
        rm -rf kernel-cache
        echo "  Freed: $CACHE_SIZE"
    fi
fi

# Old rootfs backups
if ls galactica-rootfs*.img 2>/dev/null | grep -q .; then
    echo ""
    echo "Found rootfs images:"
    ls -lh galactica-rootfs*.img 2>/dev/null
    read -p "Remove old rootfs backups? (keeps galactica-rootfs.img) (y/n) [n]: " remove_old
    remove_old=${remove_old:-n}
    if [[ "$remove_old" == "y" ]]; then
        for img in galactica-rootfs*.img; do
            [[ "$img" != "galactica-rootfs.img" ]] && rm -f "$img" && echo "  Removed: $img"
        done
    fi
fi

echo ""
echo -e "${GREEN}=== Cleanup Complete! ===${NC}"
echo ""
echo "Preserved in build directory:"
echo "  ✓ boot/ (kernel files)"
echo "  ✓ lib/modules/ (kernel modules)"
echo "  ✓ etc/airride/ (service definitions)"
echo "  ✓ sbin/airride + init symlink"
echo "  ✓ sbin/network-setup + network-watchdog"
echo "  ✓ sbin/poweroff, reboot, halt, shutdown"
echo "  ✓ sbin/fix-input-perms, setup-xorg"
echo "  ✓ usr/bin/airridectl, dreamland, dl"
echo "  ✓ usr/bin/startgui, wifi-connect, makeuser"
echo ""
echo "Essential scripts kept:"
KEEP=(
    "build-and-launch.sh"
    "bootstrap.sh"
    "run-galactica.sh"
    "run-galactica-gui.sh"
    "verify.sh"
    "cleanup-essentials.sh"
    "make-iso.sh"
    "fix-root.sh"
)
for s in "${KEEP[@]}"; do
    [[ -f "$s" ]] && echo "  ✓ $s"
done

# Update .gitignore
cat > .gitignore.recommended << 'EOF'
# Build artifacts
galactica-build/
galactica-rootfs.img
galactica-installer.iso
kernel-cache/
linux-*/
*.log

# Temporary files
mnt_tmp/
.config.backup
.config.old

# Editor files
*.swp
*.swo
*~
.vscode/
.idea/

# OS files
.DS_Store
Thumbs.db
GalacticaInstaller/test-disk.img
EOF

echo ""
echo "Updated .gitignore.recommended"
