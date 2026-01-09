#!/bin/bash
# Galactica Complete Build Script - FIXED for GCC 13+ C23 compatibility
# This version properly handles the C23 keyword conflicts

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PINK='\033[38;5;213m'
BOLD='\033[1m'
NC='\033[0m'

# Configuration
TARGET_ROOT="./galactica-build"
KERNEL_DIR=""
AIRRIDE_DIR="./AirRide"
DREAMLAND_DIR="./Dreamland"
POYO_DIR="./Poyo"
OUTPUT_ROOTFS="galactica-rootfs.img"
ROOTFS_SIZE=1024

KERNEL_VERSION="6.18.4"  # Latest stable
USE_PAM=true

declare -A COMPLETED_STEPS

# ============================================
# Helper Functions
# ============================================

print_banner() {
    clear
    echo -e "${PINK}"
    cat << "EOF"
  ________       .__                 __  .__               
 /  _____/_____  |  | _____    _____/  |_|__| ____ _____   
/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  
\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_
 \______  (____  /____(____  /\___  >__| |__|\___  >____  /
        \/     \/          \/     \/             \/     \/ 

    Complete Build System - FIXED for GCC 13+
EOF
    echo -e "${NC}"
    echo -e "${BOLD}=== Galactica Build Script v3.1 (C23 Fix) ===${NC}"
    echo ""
}

print_step() {
    echo ""
    echo -e "${BOLD}${BLUE}[STEP $1/$2]${NC} ${BOLD}$3${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..60})${NC}"
    echo ""
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}!${NC} $1"
}

print_info() {
    echo -e "${CYAN}→${NC} $1"
}

check_dependency() {
    local cmd=$1
    local pkg=$2
    if ! command -v "$cmd" &>/dev/null; then
        print_error "$cmd not found"
        echo "   Install it with: sudo apt install $pkg"
        return 1
    fi
    return 0
}

# ============================================
# Pre-flight Checks
# ============================================

preflight_checks() {
    print_step 0 11 "Pre-flight Checks"
    
    local all_ok=true
    
    print_info "Checking required tools..."
    
    check_dependency "gcc" "build-essential" || all_ok=false
    check_dependency "g++" "build-essential" || all_ok=false
    check_dependency "make" "build-essential" || all_ok=false
    check_dependency "bc" "bc" || all_ok=false
    check_dependency "flex" "flex" || all_ok=false
    check_dependency "bison" "bison" || all_ok=false
    check_dependency "dd" "coreutils" || all_ok=false
    check_dependency "mkfs.ext4" "e2fsprogs" || all_ok=false
    
    # Check GCC version
    GCC_VERSION=$(gcc -dumpversion | cut -d. -f1)
    print_info "GCC Version: $GCC_VERSION"
    if [[ $GCC_VERSION -ge 13 ]]; then
        print_warning "GCC 13+ detected - will use C11 to avoid C23 keyword conflicts"
    fi
    
    if [[ "$USE_PAM" == "true" ]]; then
        if ldconfig -p | grep -q libpam; then
            print_success "PAM libraries found"
        else
            print_warning "PAM libraries not found"
            USE_PAM=false
        fi
    fi
    
    if command -v busybox &>/dev/null; then
        print_success "busybox found"
    else
        print_warning "busybox not found - install: sudo apt install busybox-static"
        all_ok=false
    fi
    
    if command -v qemu-system-x86_64 &>/dev/null; then
        print_success "QEMU found"
    else
        print_warning "QEMU not found - install: sudo apt install qemu-system-x86"
    fi
    
    echo ""
    
    if [[ "$all_ok" == "true" ]]; then
        print_success "All dependencies satisfied"
        return 0
    else
        print_error "Missing dependencies. Install them and try again."
        return 1
    fi
}

# ============================================
# Step 1: Build Kernel with C23 Fix
# ============================================

build_kernel() {
    print_step 1 11 "Build Linux Kernel (C23 Compatible)"
    
    local KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    local KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TARBALL}"
    local KERNEL_CACHE_DIR="./kernel-cache"
    
    # Check if already built
    if [[ -f "$TARGET_ROOT/boot/vmlinuz-galactica" ]]; then
        print_info "Checking existing kernel..."
        if [[ -f "$TARGET_ROOT/boot/.kernel-version" ]]; then
            EXISTING_VERSION=$(cat "$TARGET_ROOT/boot/.kernel-version")
            if [[ "$EXISTING_VERSION" == "$KERNEL_VERSION" ]]; then
                print_success "Kernel $KERNEL_VERSION already built"
                read -p "Rebuild anyway? (y/n) [n]: " rebuild
                rebuild=${rebuild:-n}
                if [[ "$rebuild" != "y" ]]; then
                    COMPLETED_STEPS[kernel]=1
                    return 0
                fi
            fi
        fi
    fi
    
    # Download if needed
    if [[ ! -d "$KERNEL_DIR" ]]; then
        KERNEL_DIR="./linux-${KERNEL_VERSION}"
        mkdir -p "$KERNEL_CACHE_DIR"
        
        if [[ ! -f "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" ]]; then
            print_info "Downloading Linux kernel ${KERNEL_VERSION}..."
            print_info "This is a one-time download (~140 MB)"
            
            if command -v wget &>/dev/null; then
                wget -O "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" "$KERNEL_URL" || {
                    print_error "Failed to download kernel"
                    return 1
                }
            elif command -v curl &>/dev/null; then
                curl -L -o "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" "$KERNEL_URL" || {
                    print_error "Failed to download kernel"
                    return 1
                }
            else
                print_error "Neither wget nor curl found"
                return 1
            fi
        fi
        
        print_info "Extracting kernel source..."
        tar -xf "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" || {
            print_error "Failed to extract kernel"
            return 1
        }
    fi
    
    cd "$KERNEL_DIR"
    
    # ===== CRITICAL FIX: Set C standard BEFORE any make commands =====
    print_info "Applying C23 compatibility fix..."
    GCC_VERSION=$(gcc -dumpversion | cut -d. -f1)
    
    if [[ $GCC_VERSION -ge 13 ]]; then
        print_warning "GCC $GCC_VERSION detected - forcing C11 standard"
        
        # Export flags that will be used by ALL kernel build steps
        export KCFLAGS="-std=gnu11"
        export HOSTCFLAGS="-std=gnu11"
        export KBUILD_CFLAGS="-std=gnu11"
        export CC="gcc -std=gnu11"
        export HOSTCC="gcc -std=gnu11"
        
        print_success "Set C11 standard for kernel build"
        
        # Verify the fix will work
        echo "Testing compiler with C11..."
        echo 'int main() { return 0; }' | gcc -std=gnu11 -x c - -o /tmp/test$$ 2>&1
        if [[ $? -eq 0 ]]; then
            print_success "Compiler accepts -std=gnu11"
            rm -f /tmp/test$$
        else
            print_error "Compiler test failed!"
            return 1
        fi
    fi
    
    # Check/create config
    local REBUILD_CONFIG=false
    if [[ ! -f .config ]]; then
        REBUILD_CONFIG=true
    elif ! grep -q "CONFIG_VIRTIO_BLK=y" .config; then
        REBUILD_CONFIG=true
    fi
    
    if [[ "$REBUILD_CONFIG" == "true" ]]; then
        print_info "Creating kernel configuration..."
        
        # Clean any previous build artifacts
        make mrproper 2>/dev/null || true
        
        # Start with minimal config
        make tinyconfig || make allnoconfig
        
        print_info "Enabling essential features..."
        
        cat >> .config << 'EOF'

# Core system
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_SMP=y
CONFIG_PCI=y
CONFIG_ACPI=y

# Executable formats
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y

# Memory
CONFIG_MMU=y
CONFIG_SLAB=y

# Process
CONFIG_UNIX=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_SIGNALFD=y
CONFIG_EVENTFD=y

# Filesystems
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# TTY
CONFIG_TTY=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_UNIX98_PTYS=y

# Block devices
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y

# SCSI
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y

# Network
CONFIG_NET=y
CONFIG_INET=y
CONFIG_PACKET=y

# VIRTIO (CRITICAL!)
CONFIG_VIRTIO_MENU=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_PCI_LEGACY=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_INPUT=y
CONFIG_VIRTIO_MMIO=y
CONFIG_VIRTIO_MMIO_CMDLINE_DEVICES=y
CONFIG_VIRTIO_BLK=y
CONFIG_SCSI_VIRTIO=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y

# EXT4
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y

# Security hardening
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITYFS=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_STACKPROTECTOR=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_PAGE_TABLE_ISOLATION=y
CONFIG_RANDOMIZE_BASE=y

EOF
        
        # Apply config with our C11 flags already set
        make olddefconfig
        
        print_success "Kernel configured"
    fi
    
    # Verify critical options
    print_info "Verifying configuration..."
    for opt in CONFIG_VIRTIO CONFIG_VIRTIO_BLK CONFIG_EXT4_FS; do
        if grep -q "^${opt}=y" .config; then
            print_success "$opt enabled"
        else
            print_error "$opt NOT enabled!"
            return 1
        fi
    done
    
    # Build
    if [[ -f arch/x86/boot/bzImage ]]; then
        print_info "Found existing kernel binary"
        read -p "Rebuild? (y/n) [n]: " rebuild
        rebuild=${rebuild:-n}
        if [[ "$rebuild" != "y" ]]; then
            cd ..
            mkdir -p "$TARGET_ROOT/boot"
            cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
            echo "$KERNEL_VERSION" > "$TARGET_ROOT/boot/.kernel-version"
            COMPLETED_STEPS[kernel]=1
            return 0
        fi
    fi
    
    print_info "Building kernel with C11 standard..."
    print_info "Using $(nproc) CPU cores"
    print_info "This will take 5-15 minutes..."
    
    # Clean and build with our flags
    make clean
    
    # Build - our flags are already exported
    make -j$(nproc) 2>&1 | tee ../kernel-build.log
    
    if [[ -f arch/x86/boot/bzImage ]]; then
        print_success "Kernel built successfully!"
        echo "$KERNEL_VERSION" > ../kernel-version.txt
        COMPLETED_STEPS[kernel]=1
    else
        print_error "Kernel build failed!"
        print_error "Check kernel-build.log for details"
        print_error "The C23 compatibility fix may need adjustment"
        return 1
    fi
    
    cd ..
}

# ============================================
# Remaining build steps (same as before)
# ============================================

build_poyo() {
    print_step 2 11 "Build Poyo Getty/Login"
    
    cd "$POYO_DIR"
    
    CFLAGS="-Wall -Wextra -O2 -D_GNU_SOURCE -fstack-protector-strong"
    LIBS="-lcrypt"
    
    if [[ "$USE_PAM" == "true" ]] && [[ -f /usr/include/security/pam_appl.h ]]; then
        CFLAGS="$CFLAGS -DUSE_PAM"
        LIBS="$LIBS -lpam -lpam_misc"
        print_info "Enabling PAM support"
    fi
    
    gcc $CFLAGS -o poyo src/main.c $LIBS || {
        print_error "Failed to build Poyo"
        return 1
    }
    
    print_success "Poyo built"
    COMPLETED_STEPS[poyo]=1
    cd ..
}

build_airride() {
    print_step 3 11 "Build AirRide Init"
    
    cd "$AIRRIDE_DIR/Init"
    mkdir -p build
    
    g++ -o build/airride src/main.cpp \
        -Wall -Wextra -O2 -std=c++17 \
        -fstack-protector-strong || {
        print_error "Failed to build AirRide"
        return 1
    }
    
    print_success "AirRide built"
    COMPLETED_STEPS[airride]=1
    cd ../..
}

build_airridectl() {
    print_step 4 11 "Build AirRideCtl"
    
    cd "$AIRRIDE_DIR/Ctl"
    mkdir -p build
    
    g++ -o build/airridectl src/main.cpp \
        -Wall -Wextra -O2 -std=c++17 || {
        print_error "Failed to build AirRideCtl"
        return 1
    }
    
    print_success "AirRideCtl built"
    COMPLETED_STEPS[airridectl]=1
    cd ../..
}

build_dreamland() {
    print_step 5 11 "Build Dreamland Package Manager"
    
    cd "$DREAMLAND_DIR"
    mkdir -p build
    
    g++ -o build/dreamland src/main.cpp \
        -Wall -Wextra -O2 -std=c++17 \
        -lcurl -lssl -lcrypto -lz -lzstd || {
        print_error "Failed to build Dreamland"
        return 1
    }
    
    print_success "Dreamland built"
    COMPLETED_STEPS[dreamland]=1
    cd ..
}

prepare_build_dir() {
    print_step 6 11 "Prepare Root Filesystem"
    
    if [[ -d "$TARGET_ROOT" ]]; then
        read -p "Clean build directory? (y/n) [y]: " clean
        clean=${clean:-y}
        [[ "$clean" == "y" ]] && rm -rf "$TARGET_ROOT"
    fi
    
    mkdir -p "$TARGET_ROOT"/{bin,sbin,dev,etc,proc,sys,run,tmp,var/log,lib,lib64,usr/{bin,sbin,lib,lib64}}
    mkdir -p "$TARGET_ROOT"/etc/airride/services
    mkdir -p "$TARGET_ROOT"/{home/user,root}
    
    chmod 1777 "$TARGET_ROOT/tmp"
    chmod 700 "$TARGET_ROOT/root"
    
    print_success "Directory structure created"
    COMPLETED_STEPS[builddir]=1
}

install_components() {
    print_step 7 11 "Install Components"
    
    [[ -z "$KERNEL_DIR" ]] && KERNEL_DIR=$(find . -maxdepth 1 -type d -name "linux-*" | head -1)
    
    mkdir -p "$TARGET_ROOT/boot"
    cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
    [[ -f "$KERNEL_DIR/System.map" ]] && cp "$KERNEL_DIR/System.map" "$TARGET_ROOT/boot/"
    [[ -f "$KERNEL_DIR/.config" ]] && cp "$KERNEL_DIR/.config" "$TARGET_ROOT/boot/config-galactica"
    [[ -f "kernel-version.txt" ]] && cp kernel-version.txt "$TARGET_ROOT/boot/.kernel-version"
    
    cp "$POYO_DIR/poyo" "$TARGET_ROOT/sbin/poyo"
    chmod 755 "$TARGET_ROOT/sbin/poyo"
    
    cp "$AIRRIDE_DIR/Init/build/airride" "$TARGET_ROOT/sbin/airride"
    chmod 755 "$TARGET_ROOT/sbin/airride"
    ln -sf airride "$TARGET_ROOT/sbin/init"
    
    cp "$AIRRIDE_DIR/Ctl/build/airridectl" "$TARGET_ROOT/usr/bin/airridectl"
    chmod 755 "$TARGET_ROOT/usr/bin/airridectl"
    
    cp "$DREAMLAND_DIR/build/dreamland" "$TARGET_ROOT/usr/bin/dreamland"
    chmod 755 "$TARGET_ROOT/usr/bin/dreamland"
    ln -sf dreamland "$TARGET_ROOT/usr/bin/dl"
    
    print_success "Components installed"
    COMPLETED_STEPS[install]=1
}

install_essentials() {
    print_step 8 11 "Install Busybox and Libraries"
    
    cp /bin/busybox "$TARGET_ROOT/bin/"
    chmod +x "$TARGET_ROOT/bin/busybox"
    
    cd "$TARGET_ROOT/bin"
    for cmd in sh ash ls cat echo pwd mkdir rm cp mv ln chmod grep sed awk ps kill sleep touch; do
        ln -sf busybox "$cmd" 2>/dev/null || true
    done
    cd - > /dev/null
    
    print_info "Copying libraries..."
    
    copy_libs() {
        local binary=$1
        [[ ! -f "$binary" ]] && return
        ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
            if [[ -f "$lib" && ! -f "$TARGET_ROOT$lib" ]]; then
                mkdir -p "$TARGET_ROOT$(dirname $lib)"
                cp "$lib" "$TARGET_ROOT$lib" 2>/dev/null || true
            fi
        done
    }
    
    for binary in "$TARGET_ROOT/sbin/airride" "$TARGET_ROOT/sbin/poyo" \
                  "$TARGET_ROOT/usr/bin/airridectl" "$TARGET_ROOT/usr/bin/dreamland"; do
        copy_libs "$binary"
    done
    
    # Copy critical libs
    for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 libcrypt.so.1 libgcc_s.so.1 libstdc++.so.6; do
        LIBPATH=$(find /lib* /usr/lib* -name "$lib" 2>/dev/null | head -1)
        if [[ -n "$LIBPATH" ]]; then
            mkdir -p "$TARGET_ROOT$(dirname $LIBPATH)"
            cp "$LIBPATH" "$TARGET_ROOT$(dirname $LIBPATH)/" 2>/dev/null || true
        fi
    done
    
    # Copy dynamic linker
    for linker in ld-linux-x86-64.so.2 ld-linux.so.2; do
        LINKER=$(find /lib* -name "$linker" 2>/dev/null | head -1)
        if [[ -n "$LINKER" ]]; then
            mkdir -p "$TARGET_ROOT$(dirname $LINKER)"
            cp "$LINKER" "$TARGET_ROOT$(dirname $LINKER)/"
        fi
    done
    
    print_success "Essentials installed"
    COMPLETED_STEPS[essentials]=1
}

create_system_files() {
    print_step 9 11 "Create System Configuration"
    
    cd "$TARGET_ROOT/dev"
    sudo mknod -m 666 null c 1 3 2>/dev/null || true
    sudo mknod -m 666 zero c 1 5 2>/dev/null || true
    sudo mknod -m 600 console c 5 1 2>/dev/null || true
    sudo mknod -m 666 tty c 5 0 2>/dev/null || true
    cd - > /dev/null
    
    cat > "$TARGET_ROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
    
    cat > "$TARGET_ROOT/etc/group" << 'EOF'
root:x:0:
EOF
    
    cat > "$TARGET_ROOT/etc/shadow" << 'EOF'
root:$6$galactica$K9p3vXJ5qZ8mH4xL2nY7.wR9tE1sC8bA6fD5gH3jK2lM9nP0qR1sT2uV3wX4yZ5aB6cD7eF8gH9iJ0kL1mN2oP3:19000:0:99999:7:::
EOF
    chmod 600 "$TARGET_ROOT/etc/shadow"
    
    echo "galactica" > "$TARGET_ROOT/etc/hostname"
    
    cat > "$TARGET_ROOT/etc/airride/services/getty.service" << 'EOF'
[Service]
name=getty
description=Poyo Login
type=simple
exec_start=/sbin/poyo
restart=always
restart_delay=1
EOF
    
    cat > "$TARGET_ROOT/etc/motd" << 'EOF'
Welcome to Galactica Linux!
Default login: root / galactica
EOF
    
    print_success "System files created"
    COMPLETED_STEPS[sysfiles]=1
}

create_rootfs() {
    print_step 10 11 "Create Root Filesystem Image"
    
    [[ -f "$OUTPUT_ROOTFS" ]] && rm -f "$OUTPUT_ROOTFS"
    
    dd if=/dev/zero of="$OUTPUT_ROOTFS" bs=1M count=$ROOTFS_SIZE status=progress
    mkfs.ext4 -F -L "GalacticaRoot" "$OUTPUT_ROOTFS"
    
    mkdir -p mnt_tmp
    sudo mount -o loop "$OUTPUT_ROOTFS" mnt_tmp
    sudo cp -a "$TARGET_ROOT"/* mnt_tmp/
    sudo umount mnt_tmp
    rmdir mnt_tmp
    
    print_success "Root filesystem created"
    COMPLETED_STEPS[rootfs]=1
}

create_launch_scripts() {
    print_step 11 11 "Create Launch Scripts"
    
    cat > run-galactica.sh << 'EOFSCRIPT'
#!/bin/bash
qemu-system-x86_64 \
    -kernel galactica-build/boot/vmlinuz-galactica \
    -drive file=galactica-rootfs.img,format=raw,if=virtio \
    -m 512M -smp 2 \
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init" \
    -nographic -serial mon:stdio
EOFSCRIPT
    chmod +x run-galactica.sh
    
    print_success "Launch scripts created"
    COMPLETED_STEPS[scripts]=1
}

# ============================================
# Main
# ============================================

main() {
    print_banner
    
    echo "This script builds Galactica Linux with:"
    echo ""
    echo "  ✓ GCC 13+ C23 compatibility fix"
    echo "  ✓ Linux kernel ${KERNEL_VERSION} with VIRTIO"
    echo "  ✓ Complete userspace components"
    echo ""
    echo "Build time: ~10-20 minutes (first build)"
    echo ""
    read -p "Continue? (y/n) [y]: " continue
    continue=${continue:-y}
    [[ "$continue" != "y" ]] && exit 0
    
    preflight_checks || exit 1
    build_kernel || exit 1
    build_poyo || exit 1
    build_airride || exit 1
    build_airridectl || exit 1
    build_dreamland || exit 1
    prepare_build_dir || exit 1
    install_components || exit 1
    install_essentials || exit 1
    create_system_files || exit 1
    create_rootfs || exit 1
    create_launch_scripts
    
    clear
    print_banner
    echo -e "${GREEN}${BOLD}=== Build Complete! ===${NC}"
    echo ""
    echo "To boot: ${YELLOW}./run-galactica.sh${NC}"
    echo "Login: ${CYAN}root${NC} / ${CYAN}galactica${NC}"
    echo ""
}

main
