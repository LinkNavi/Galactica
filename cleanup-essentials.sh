#!/bin/bash
# Enhanced cleanup script - removes copied files, build artifacts, and temporary scripts

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
CYAN='\033[0;36m'
NC='\033[0m'

echo -e "${BLUE}=== Galactica Enhanced Cleanup ===${NC}"
echo "Target: $TARGET_ROOT"
echo ""
echo "This will:"
echo "  1. Remove copied binaries and libraries from build directory"
echo "  2. Keep: boot/, lib/modules/, etc/airride/, AirRide binaries"
echo "  3. Remove build artifacts (logs, caches, temporary files)"
echo "  4. Remove one-time use scripts"
echo "  5. Keep essential scripts for running/rebuilding"
echo ""

# Show what will be removed
echo -e "${YELLOW}Files and directories to be removed:${NC}"
echo ""
echo "Build artifacts:"
echo "  • kernel-build.log, kernel-rebuild*.log"
echo "  • kernel-cache/ directory (optional)"
echo "  • kernel-version.txt"
echo "  • mnt_tmp/ (if empty)"
echo "  • boot-debug-*.log files"
echo ""
echo "Kernel compilation:"
echo "  • All linux-* source directories (asks first)"
echo "  • Built kernels (bzImage files) - except in galactica-build/boot/"
echo "  • .config backups"
echo "  • Kernel build artifacts"
echo ""
echo "Temporary/one-time scripts:"
echo "  • copy-essentials.sh"
echo "  • create-initramfs.sh"
echo "  • add-login-screen.sh"
echo "  • copy-libraries.sh"
echo "  • diagnose.sh (optional - can be useful)"
echo "  • fix-libraries.sh"
echo "  • sync-rootfs.sh"
echo "  • comprehensive-fix.sh"
echo "  • quick-kernel-fix.sh"
echo "  • rebuild-kernel.sh"
echo "  • chroot-debug.sh"
echo "  • quick-chroot-test.sh"
echo "  • manual-fix-guide.sh"
echo "  • debug-boot.sh (optional - can be useful)"
echo ""
echo "Old QEMU scripts:"
echo "  • run-qemu*.sh (various old versions)"
echo "  • setup-qemu-boot.sh"
echo ""
echo -e "${GREEN}Scripts to keep:${NC}"
echo "  ✓ build-and-launch.sh (main build script)"
echo "  ✓ bootstrap.sh (first-boot setup)"
echo "  ✓ run-galactica.sh (boot script)"
echo "  ✓ verify.sh (system verification)"
echo "  ✓ cleanup-essentials.sh (this script)"
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
echo -e "${GREEN}=== Phase 2: Cleaning build artifacts ===${NC}"
echo ""

# Remove kernel build artifacts
echo "Removing kernel build logs..."
rm -f kernel-build.log kernel-rebuild*.log kernel-version.txt 2>/dev/null || true

echo "Removing boot debug logs..."
rm -f boot-debug-*.log 2>/dev/null || true

echo "Removing kernel cache..."
if [[ -d kernel-cache ]]; then
    echo "  Found kernel-cache/ ($(du -sh kernel-cache 2>/dev/null | cut -f1))"
    rm -rf kernel-cache
fi

echo "Removing temporary mount points..."
rmdir mnt_tmp 2>/dev/null || true

echo "Removing .config backups..."
find linux-*/  -name ".config.backup" -o -name ".config.before-fix" -o -name ".config.old" 2>/dev/null | while read file; do
    rm -f "$file"
    echo "  Removed: $file"
done

echo ""
echo -e "${GREEN}=== Phase 3: Cleaning temporary scripts ===${NC}"
echo ""

# Scripts to keep (essential for operation)
KEEP_SCRIPTS=(
    "build-and-launch.sh"
    "bootstrap.sh"
    "run-galactica.sh"
    "verify.sh"
    "cleanup-essentials.sh"
)

# Optional scripts (ask user)
OPTIONAL_SCRIPTS=(
    "diagnose.sh"
    "debug-boot.sh"
    "run-galactica-debug.sh"
)

# Scripts to remove (one-time use or superseded)
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
    
    # Fix scripts (no longer needed after successful build)
    "fix-libraries.sh"
    "sync-rootfs.sh"
    "comprehensive-fix.sh"
    "quick-kernel-fix.sh"
    "rebuild-kernel.sh"
    "kernel-fix.sh"
    "manual-fix-guide.sh"
    
    # Debug scripts (one-time use)
    "chroot-debug.sh"
    "quick-chroot-test.sh"
    "check-rootfs-libs.sh"
    
    # Documentation that's been applied
    "BUILD-SCRIPT-PATCH.md"
    "dreamland-fixed-summary.md"
    "kernel-config-fixed.txt"
)

# Remove one-time use scripts
for script in "${REMOVE_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        echo "Removing: $script"
        rm -f "$script"
    fi
done

# Ask about optional scripts
echo ""
echo -e "${CYAN}Optional scripts found:${NC}"
for script in "${OPTIONAL_SCRIPTS[@]}"; do
    if [[ -f "$script" ]]; then
        echo "  • $script"
    fi
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
echo -e "${GREEN}=== Phase 4: Cleaning large directories ===${NC}"
echo ""

# Check for all kernel source directories
KERNEL_DIRS=$(find . -maxdepth 1 -type d -name "linux-*" 2>/dev/null)

if [[ -n "$KERNEL_DIRS" ]]; then
    echo "Found kernel source directories:"
    echo ""
    TOTAL_SIZE=0
    while IFS= read -r dir; do
        if [[ -n "$dir" ]]; then
            SIZE=$(du -sh "$dir" 2>/dev/null | cut -f1)
            SIZE_MB=$(du -sm "$dir" 2>/dev/null | cut -f1)
            TOTAL_SIZE=$((TOTAL_SIZE + SIZE_MB))
            echo "  • $dir ($SIZE)"
            
            # Show if it has build artifacts
            if [[ -f "$dir/arch/x86/boot/bzImage" ]]; then
                echo "    └─ Built kernel present"
            fi
            if [[ -f "$dir/.config" ]]; then
                echo "    └─ Configured"
            fi
        fi
    done <<< "$KERNEL_DIRS"
    
    echo ""
    echo "Total kernel source size: ~${TOTAL_SIZE}MB"
    echo ""
    echo "The kernel source directories are large and only needed for rebuilds."
    echo "You can safely remove them - the kernel tarball remains in kernel-cache/"
    echo "for future builds, and your built kernel is in galactica-build/boot/"
    echo ""
    read -p "Remove ALL kernel source directories? (y/n) [y]: " remove_kernel
    remove_kernel=${remove_kernel:-y}
    
    if [[ "$remove_kernel" == "y" ]]; then
        echo ""
        echo "Removing kernel source directories..."
        while IFS= read -r dir; do
            if [[ -n "$dir" ]]; then
                echo "  Removing: $dir"
                rm -rf "$dir"
            fi
        done <<< "$KERNEL_DIRS"
        echo ""
        echo "  Freed: ~${TOTAL_SIZE}MB"
        echo ""
        echo "Note: Kernel tarball is still in kernel-cache/ for future builds"
        echo "      Built kernel is preserved in galactica-build/boot/"
    else
        echo "Keeping kernel source directories"
    fi
else
    echo "No kernel source directories found"
fi

# Check for old rootfs images
if ls galactica-rootfs*.img 2>/dev/null | grep -q .; then
    echo ""
    echo "Found rootfs images:"
    ls -lh galactica-rootfs*.img 2>/dev/null
    echo ""
    echo "Old/backup rootfs images can be large."
    read -p "Remove old rootfs backups? (keeps galactica-rootfs.img) (y/n) [n]: " remove_old_rootfs
    remove_old_rootfs=${remove_old_rootfs:-n}
    
    if [[ "$remove_old_rootfs" == "y" ]]; then
        for img in galactica-rootfs*.img; do
            if [[ "$img" != "galactica-rootfs.img" ]]; then
                echo "  Removing: $img"
                rm -f "$img"
            fi
        done
    fi
fi

# Check kernel cache
if [[ -d kernel-cache ]]; then
    CACHE_SIZE=$(du -sh kernel-cache 2>/dev/null | cut -f1)
    echo ""
    echo "Found kernel cache: kernel-cache/ ($CACHE_SIZE)"
    echo ""
    echo "The kernel cache contains the downloaded kernel tarball (~140MB)."
    echo "Keeping it allows faster rebuilds without re-downloading."
    echo "Remove it only if you're done with kernel development."
    echo ""
    read -p "Remove kernel cache? (y/n) [n]: " remove_cache
    remove_cache=${remove_cache:-n}
    
    if [[ "$remove_cache" == "y" ]]; then
        echo "Removing kernel-cache/..."
        rm -rf kernel-cache
        echo "  Freed: $CACHE_SIZE"
        echo ""
        echo "Note: Will need to re-download kernel tarball for future builds"
    fi
fi

echo ""
echo -e "${GREEN}=== Cleanup Complete! ===${NC}"
echo ""

# Show what was cleaned
CLEANED_ITEMS=()
[[ ! -d "kernel-cache" ]] && CLEANED_ITEMS+=("kernel cache")
[[ -z "$(find . -maxdepth 1 -type d -name 'linux-*' 2>/dev/null)" ]] && CLEANED_ITEMS+=("kernel sources")
[[ ! -f "kernel-build.log" ]] && CLEANED_ITEMS+=("build logs")

if [[ ${#CLEANED_ITEMS[@]} -gt 0 ]]; then
    echo "Cleaned:"
    for item in "${CLEANED_ITEMS[@]}"; do
        echo "  ✓ $item"
    done
    echo ""
fi

# Calculate remaining important files
echo "Summary:"
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

if [[ "$remove_optional" != "y" ]]; then
    for script in "${OPTIONAL_SCRIPTS[@]}"; do
        if [[ -f "$script" ]]; then
            echo "  ✓ $script (optional, kept)"
        fi
    done
fi

echo ""
echo "Your directory is now clean and ready for git!"
echo ""
echo -e "${CYAN}Next steps:${NC}"
echo "  1. If you removed the build directory contents, rebuild with:"
echo "     ${YELLOW}./build-and-launch.sh${NC}"
echo ""
echo "  2. To commit to git:"
echo "     ${YELLOW}git add build-and-launch.sh run-galactica.sh bootstrap.sh${NC}"
echo "     ${YELLOW}git commit -m 'Clean build system'${NC}"
echo ""
echo "  3. Add .gitignore to exclude build artifacts:"
cat > .gitignore.recommended << 'EOFGITIGNORE'
# Build artifacts
galactica-build/
galactica-rootfs.img
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
EOFGITIGNORE

echo "     ${YELLOW}cat .gitignore.recommended >> .gitignore${NC}"
echo ""
echo "Recommended .gitignore saved to: .gitignore.recommended"
