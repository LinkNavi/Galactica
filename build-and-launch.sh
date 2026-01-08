#!/bin/bash
# Galactica Complete Build Script - Uses Standard GCC/G++
# Builds everything without requiring Zora

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
KERNEL_DIR=""  # Will be set dynamically based on downloaded version
AIRRIDE_DIR="./AirRide"
DREAMLAND_DIR="./Dreamland"
POYO_DIR="./Poyo"
OUTPUT_ROOTFS="galactica-rootfs.img"
ROOTFS_SIZE=1024  # Size in MB

# Kernel version options:
# - "6.12.6"  - Latest mainline (bleeding edge)
# - "6.6.67"  - LTS (stable until Dec 2026) - RECOMMENDED
# - "6.1.119" - Older LTS (stable until Dec 2026)
KERNEL_VERSION="6.18.4"  # Change this to use different kernel

# Build options
USE_PAM=true  # Set to true to enable PAM support in Poyo

# Track completed steps
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

    Complete Build System - Standard C/C++ Compilers
EOF
    echo -e "${NC}"
    echo -e "${BOLD}=== Galactica Master Build Script v3.0 ===${NC}"
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
    
    # Check for optional PAM libraries
    if [[ "$USE_PAM" == "true" ]]; then
        if ldconfig -p | grep -q libpam; then
            print_success "PAM libraries found"
        else
            print_warning "PAM libraries not found - install: sudo apt install libpam0g-dev"
            print_warning "PAM support will be disabled"
            USE_PAM=false
        fi
    fi
    
    # Check for busybox
    if command -v busybox &>/dev/null; then
        print_success "busybox found"
    else
        print_warning "busybox not found - install: sudo apt install busybox-static"
        all_ok=false
    fi
    
    # Check for QEMU
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
# Step 1: Download, Configure and Build Kernel (with caching)
# ============================================

build_kernel() {
    print_step 1 11 "Configure and Build Linux Kernel with VIRTIO Support"
    
    local KERNEL_VERSION="6.12.6"  # Latest stable as of Jan 2025
    local KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    local KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TARBALL}"
    local KERNEL_CACHE_DIR="./kernel-cache"
    
    # Check if kernel already built
    if [[ -f "$TARGET_ROOT/boot/vmlinuz-galactica" ]]; then
        print_info "Checking existing kernel..."
        
        # Check version
        if [[ -f "$TARGET_ROOT/boot/.kernel-version" ]]; then
            EXISTING_VERSION=$(cat "$TARGET_ROOT/boot/.kernel-version")
            if [[ "$EXISTING_VERSION" == "$KERNEL_VERSION" ]]; then
                print_success "Kernel $KERNEL_VERSION already built and installed"
                read -p "Rebuild anyway? (y/n) [n]: " rebuild
                rebuild=${rebuild:-n}
                if [[ "$rebuild" != "y" ]]; then
                    COMPLETED_STEPS[kernel]=1
                    return 0
                fi
            else
                print_info "Existing kernel: $EXISTING_VERSION, latest: $KERNEL_VERSION"
            fi
        fi
    fi
    
    # Check if kernel source exists
    if [[ ! -d "$KERNEL_DIR" ]]; then
        print_info "Kernel source not found, will download..."
        KERNEL_DIR="./linux-${KERNEL_VERSION}"
        
        # Create cache directory
        mkdir -p "$KERNEL_CACHE_DIR"
        
        # Check if tarball is cached
        if [[ -f "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" ]]; then
            print_success "Found cached kernel tarball"
        else
            print_info "Downloading Linux kernel ${KERNEL_VERSION}..."
            print_info "Source: $KERNEL_URL"
            print_info "This is a one-time download (~140 MB, will be cached)"
            
            # Download with progress
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
                print_error "Neither wget nor curl found. Install one:"
                echo "  sudo apt install wget"
                return 1
            fi
            
            print_success "Downloaded kernel tarball"
        fi
        
        # Extract
        print_info "Extracting kernel source..."
        tar -xf "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" || {
            print_error "Failed to extract kernel"
            return 1
        }
        print_success "Extracted to $KERNEL_DIR"
    else
        print_success "Found existing kernel source: $KERNEL_DIR"
    fi
    
    cd "$KERNEL_DIR"
    
    # Check if .config exists and is up to date
    local REBUILD_CONFIG=false
    if [[ ! -f .config ]]; then
        print_info "No kernel configuration found"
        REBUILD_CONFIG=true
    elif [[ -f .config ]] && ! grep -q "CONFIG_VIRTIO_BLK=y" .config; then
        print_warning "Existing config missing VIRTIO support"
        REBUILD_CONFIG=true
    fi
    
    if [[ "$REBUILD_CONFIG" == "true" ]]; then
        print_info "Creating optimized kernel configuration..."
        
        # Check GCC version for C23 compatibility issues
        GCC_VERSION=$(gcc -dumpversion | cut -d. -f1)
        if [[ $GCC_VERSION -ge 13 ]]; then
            print_info "Detected GCC $GCC_VERSION - applying C11 standard for compatibility"
            # Force C11 standard to avoid C23 'bool' and 'false' keyword conflicts
            export KCFLAGS="-std=gnu11"
            export HOSTCFLAGS="-std=gnu11"
        fi
        
        # Start with minimal config for faster builds
        make tinyconfig || make allnoconfig
        
        print_info "Enabling essential features..."
        
        # Create a comprehensive config
        cat >> .config << 'EOF'

# Core system support
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_SMP=y
CONFIG_PCI=y
CONFIG_ACPI=y

# Executable formats
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y

# Memory management
CONFIG_MMU=y
CONFIG_SLAB=y

# Process features
CONFIG_UNIX=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_SIGNALFD=y
CONFIG_EVENTFD=y

# Pseudo filesystems
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y

# TTY and console
CONFIG_TTY=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_UNIX98_PTYS=y

# Block device support
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y

# SCSI support (for virtio-scsi)
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y

# Networking (basic)
CONFIG_NET=y
CONFIG_INET=y
CONFIG_PACKET=y

# VIRTIO drivers (CRITICAL for QEMU)
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

# Filesystem support
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
CONFIG_EXT4_FS_POSIX_ACL=y
CONFIG_EXT4_FS_SECURITY=y

# Security features (hardening)
CONFIG_SECURITY=y
CONFIG_SECURITY_NETWORK=y
CONFIG_SECURITYFS=y
CONFIG_SECURITY_PATH=y
CONFIG_HAVE_HARDENED_USERCOPY_ALLOCATOR=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_FORTIFY_SOURCE=y
CONFIG_INIT_ON_ALLOC_DEFAULT_ON=y
CONFIG_INIT_ON_FREE_DEFAULT_ON=y

# Kernel hardening
CONFIG_BUG=y
CONFIG_DEBUG_KERNEL=y
CONFIG_PANIC_ON_OOPS=y
CONFIG_STACKPROTECTOR=y
CONFIG_STACKPROTECTOR_STRONG=y
CONFIG_STRICT_KERNEL_RWX=y
CONFIG_STRICT_MODULE_RWX=y
CONFIG_PAGE_TABLE_ISOLATION=y
CONFIG_RANDOMIZE_BASE=y
CONFIG_RANDOMIZE_MEMORY=y

# Remove unneeded features for faster build
# CONFIG_MODULES is not set (build everything statically)
# CONFIG_WIRELESS is not set
# CONFIG_WLAN is not set
# CONFIG_SOUND is not set
# CONFIG_DRM is not set
# CONFIG_FB is not set
# CONFIG_USB is not set
# CONFIG_STAGING is not set

EOF
        
        # Apply configuration
        make olddefconfig
        
        print_success "Kernel configured with security hardening"
    else
        print_success "Using existing kernel configuration"
    fi
    
    # Verify critical options
    print_info "Verifying kernel configuration..."
    local config_ok=true
    local failed_opts=""
    
    for opt in CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK CONFIG_EXT4_FS \
               CONFIG_HARDENED_USERCOPY CONFIG_STACKPROTECTOR_STRONG; do
        if grep -q "^${opt}=y" .config; then
            print_success "$opt enabled"
        else
            print_error "$opt NOT enabled!"
            failed_opts="$failed_opts $opt"
            config_ok=false
        fi
    done
    
    if [[ "$config_ok" != "true" ]]; then
        print_error "Kernel configuration failed! Missing: $failed_opts"
        return 1
    fi
    
    # Check if kernel already built
    if [[ -f arch/x86/boot/bzImage ]]; then
        print_info "Found existing kernel binary"
        read -p "Rebuild kernel? (y/n) [n]: " rebuild
        rebuild=${rebuild:-n}
        if [[ "$rebuild" != "y" ]]; then
            print_success "Using existing kernel"
            cd ..
            
            # Copy to target
            mkdir -p "$TARGET_ROOT/boot"
            cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
            echo "$KERNEL_VERSION" > "$TARGET_ROOT/boot/.kernel-version"
            
            COMPLETED_STEPS[kernel]=1
            return 0
        fi
    fi
    
    print_info "Building kernel (this will take 5-15 minutes)..."
    print_info "Using $(nproc) CPU cores for parallel build"
    
    # Clean previous build
    make clean
    
    # Build
    make -j$(nproc) 2>&1 | tee ../kernel-build.log
    
    if [[ -f arch/x86/boot/bzImage ]]; then
        print_success "Kernel built successfully"
        
        # Save version
        echo "$KERNEL_VERSION" > ../kernel-version.txt
        
        COMPLETED_STEPS[kernel]=1
    else
        print_error "Kernel build failed. Check kernel-build.log"
        return 1
    fi
    
    cd ..
}

# ============================================
# Step 2: Build Poyo Getty/Login (C)
# ============================================

build_poyo() {
    print_step 2 11 "Build Poyo Getty/Login System"
    
    if [[ ! -f "$POYO_DIR/src/main.c" ]]; then
        print_error "Poyo source not found: $POYO_DIR/src/main.c"
        return 1
    fi
    
    cd "$POYO_DIR"
    
    print_info "Building Poyo with gcc..."
    
    # Set compiler flags
    CFLAGS="-Wall -Wextra -Wpedantic -O2 -D_GNU_SOURCE"
    CFLAGS="$CFLAGS -fstack-protector-strong -Wformat -Wformat-security"
    LIBS="-lcrypt"
    
    # Add PAM support if enabled
    if [[ "$USE_PAM" == "true" ]]; then
        print_info "Checking for PAM support..."
        
        # Check if PAM headers exist
        if [[ -f /usr/include/security/pam_appl.h ]]; then
            print_info "Enabling PAM authentication support..."
            CFLAGS="$CFLAGS -DUSE_PAM"
            LIBS="$LIBS -lpam -lpam_misc"
        else
            print_warning "PAM headers not found (security/pam_appl.h)"
            print_warning "Install with: sudo apt install libpam0g-dev"
            print_warning "Building without PAM support..."
            USE_PAM=false
        fi
    fi
    
    # Compile
    gcc $CFLAGS -o poyo src/main.c $LIBS 2>&1 || {
        print_error "Failed to build Poyo"
        return 1
    }
    
    if [[ -f poyo ]]; then
        print_success "Poyo built successfully"
        
        # Show features
        echo ""
        echo "Compiled with:"
        if [[ "$USE_PAM" == "true" ]]; then
            print_success "PAM authentication"
        else
            print_success "/etc/shadow authentication"
        fi
        print_success "utmp/wtmp session logging"
        print_success "Security features (password clearing, rate limiting)"
        
        COMPLETED_STEPS[poyo]=1
    else
        print_error "Poyo binary not found after build"
        return 1
    fi
    
    cd ..
}

# ============================================
# Step 3: Build AirRide Init System (C++)
# ============================================

build_airride() {
    print_step 3 11 "Build AirRide Init System"
    
    if [[ ! -f "$AIRRIDE_DIR/Init/src/main.cpp" ]]; then
        print_error "AirRide source not found: $AIRRIDE_DIR/Init/src/main.cpp"
        return 1
    fi
    
    cd "$AIRRIDE_DIR/Init"
    
    print_info "Building AirRide with g++..."
    
    # Create build directory
    mkdir -p build
    
    # Compile
    g++ -o build/airride src/main.cpp \
        -Wall -Wextra -Wpedantic -O2 -std=c++17 \
        -fstack-protector-strong \
        2>&1 || {
        print_error "Failed to build AirRide"
        return 1
    }
    
    if [[ -f build/airride ]]; then
        print_success "AirRide built: build/airride"
        COMPLETED_STEPS[airride]=1
    else
        print_error "AirRide binary not found after build"
        return 1
    fi
    
    cd ../..
}

# ============================================
# Step 4: Build AirRideCtl Control Tool (C++)
# ============================================

build_airridectl() {
    print_step 4 11 "Build AirRideCtl Control Tool"
    
    if [[ ! -f "$AIRRIDE_DIR/Ctl/src/main.cpp" ]]; then
        print_error "AirRideCtl source not found: $AIRRIDE_DIR/Ctl/src/main.cpp"
        return 1
    fi
    
    cd "$AIRRIDE_DIR/Ctl"
    
    print_info "Building AirRideCtl with g++..."
    
    # Create build directory
    mkdir -p build
    
    # Compile
    g++ -o build/airridectl src/main.cpp \
        -Wall -Wextra -Wpedantic -O2 -std=c++17 \
        2>&1 || {
        print_error "Failed to build AirRideCtl"
        return 1
    }
    
    if [[ -f build/airridectl ]]; then
        print_success "AirRideCtl built: build/airridectl"
        COMPLETED_STEPS[airridectl]=1
    else
        print_error "AirRideCtl binary not found after build"
        return 1
    fi
    
    cd ../..
}

# ============================================
# Step 5: Build Dreamland Package Manager (C++)
# ============================================

build_dreamland() {
    print_step 5 11 "Build Dreamland Package Manager"
    
    if [[ ! -f "$DREAMLAND_DIR/src/main.cpp" ]]; then
        print_error "Dreamland source not found: $DREAMLAND_DIR/src/main.cpp"
        return 1
    fi
    
    cd "$DREAMLAND_DIR"
    
    print_info "Building Dreamland with g++..."
    
    # Create build directory
    mkdir -p build
    
    # Compile with curl support
    g++ -o build/dreamland src/main.cpp \
        -Wall -Wextra -O2 -std=c++17 \
        -lcurl -lssl -lcrypto -lz -lzstd \
        2>&1 || {
        print_error "Failed to build Dreamland"
        print_warning "Make sure libcurl-dev is installed: sudo apt install libcurl4-openssl-dev"
        return 1
    }
    
    if [[ -f build/dreamland ]]; then
        print_success "Dreamland built: build/dreamland"
        COMPLETED_STEPS[dreamland]=1
    else
        print_error "Dreamland binary not found after build"
        return 1
    fi
    
    cd ..
}

# ============================================
# Step 6: Prepare Build Directory
# ============================================

prepare_build_dir() {
    print_step 6 11 "Prepare Root Filesystem Structure"
    
    if [[ -d "$TARGET_ROOT" ]]; then
        print_warning "Build directory exists"
        read -p "Clean and rebuild? (y/n) [y]: " clean
        clean=${clean:-y}
        if [[ "$clean" == "y" ]]; then
            rm -rf "$TARGET_ROOT"
        fi
    fi
    
    print_info "Creating directory structure..."
    mkdir -p "$TARGET_ROOT"/{bin,sbin,dev,etc,proc,sys,run,tmp,var/log,lib,lib64,usr/{bin,sbin,lib,lib64}}
    mkdir -p "$TARGET_ROOT"/etc/airride/services
    mkdir -p "$TARGET_ROOT"/home/user
    mkdir -p "$TARGET_ROOT"/root
    
    chmod 1777 "$TARGET_ROOT/tmp"
    chmod 700 "$TARGET_ROOT/root"
    
    print_success "Directory structure created"
    COMPLETED_STEPS[builddir]=1
}

# ============================================
# Step 7: Install System Components
# ============================================

install_components() {
    print_step 7 11 "Install System Components"
    
    # Determine kernel directory
    if [[ -z "$KERNEL_DIR" ]]; then
        # Find kernel directory
        KERNEL_DIR=$(find . -maxdepth 1 -type d -name "linux-*" | head -1)
        if [[ -z "$KERNEL_DIR" ]]; then
            print_error "Kernel directory not found!"
            return 1
        fi
        print_info "Using kernel directory: $KERNEL_DIR"
    fi
    
    # Install kernel
    print_info "Installing kernel..."
    mkdir -p "$TARGET_ROOT/boot"
    
    if [[ -f "$KERNEL_DIR/arch/x86/boot/bzImage" ]]; then
        cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
    else
        print_error "Kernel binary not found at $KERNEL_DIR/arch/x86/boot/bzImage"
        return 1
    fi
    
    if [[ -f "$KERNEL_DIR/System.map" ]]; then
        cp "$KERNEL_DIR/System.map" "$TARGET_ROOT/boot/System.map-galactica"
    fi
    
    if [[ -f "$KERNEL_DIR/.config" ]]; then
        cp "$KERNEL_DIR/.config" "$TARGET_ROOT/boot/config-galactica"
    fi
    
    # Save kernel version
    if [[ -f "kernel-version.txt" ]]; then
        cp kernel-version.txt "$TARGET_ROOT/boot/.kernel-version"
    fi
    
    # Install kernel modules
    cd "$KERNEL_DIR"
    make INSTALL_MOD_PATH="$(realpath ../$TARGET_ROOT)" modules_install 2>/dev/null || {
        print_warning "No kernel modules to install (static build)"
    }
    cd ..
    
    print_success "Kernel installed"
    
    # Install Poyo
    print_info "Installing Poyo getty/login..."
    cp "$POYO_DIR/poyo" "$TARGET_ROOT/sbin/poyo"
    chmod 755 "$TARGET_ROOT/sbin/poyo"
    print_success "Poyo installed"
    
    # Install AirRide
    print_info "Installing AirRide init system..."
    cp "$AIRRIDE_DIR/Init/build/airride" "$TARGET_ROOT/sbin/airride"
    chmod 755 "$TARGET_ROOT/sbin/airride"
    
    # Create init symlink
    cd "$TARGET_ROOT/sbin"
    ln -sf airride init
    cd - > /dev/null
    
    print_success "AirRide installed"
    
    # Install AirRideCtl
    print_info "Installing AirRideCtl..."
    cp "$AIRRIDE_DIR/Ctl/build/airridectl" "$TARGET_ROOT/usr/bin/airridectl"
    chmod 755 "$TARGET_ROOT/usr/bin/airridectl"
    print_success "AirRideCtl installed"
    
    # Install Dreamland
    print_info "Installing Dreamland..."
    cp "$DREAMLAND_DIR/build/dreamland" "$TARGET_ROOT/usr/bin/dreamland"
    chmod 755 "$TARGET_ROOT/usr/bin/dreamland"
    
    cd "$TARGET_ROOT/usr/bin"
    ln -sf dreamland dl
    cd - > /dev/null
    
    print_success "Dreamland installed"
    
    COMPLETED_STEPS[install]=1
}

# ============================================
# Step 8: Install Busybox and Libraries
# ============================================

install_essentials() {
    print_step 8 11 "Install Shell and Essential Libraries"
    
    # Install busybox
    print_info "Installing busybox..."
    if command -v busybox &>/dev/null; then
        cp /bin/busybox "$TARGET_ROOT/bin/"
        chmod +x "$TARGET_ROOT/bin/busybox"
        
        cd "$TARGET_ROOT/bin"
        # Create essential symlinks
        for cmd in sh ash ls cat echo pwd mkdir rmdir rm cp mv ln chmod chown \
                   grep sed awk sort uniq wc head tail cut tr find mount umount \
                   ps kill killall sleep touch date hostname df du free vi; do
            ln -sf busybox "$cmd" 2>/dev/null || true
        done
        cd - > /dev/null
        
        CMD_COUNT=$(ls -1 "$TARGET_ROOT/bin/" | wc -l)
        print_success "Busybox installed with $CMD_COUNT commands"
    else
        print_error "Busybox not found!"
        return 1
    fi
    
    # Copy libraries
    print_info "Copying essential libraries..."
    
    # Function to copy libs recursively
    copy_libs() {
        local binary=$1
        if [[ ! -f "$binary" ]]; then
            return
        fi
        
        # Get all dependencies
        ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
            if [[ -f "$lib" ]]; then
                local lib_dir=$(dirname "$lib")
                mkdir -p "$TARGET_ROOT$lib_dir"
                
                # Copy library if not already present
                if [[ ! -f "$TARGET_ROOT$lib" ]]; then
                    cp "$lib" "$TARGET_ROOT$lib_dir/" 2>/dev/null || true
                    
                    # Copy symlink target if it's a symlink
                    if [[ -L "$lib" ]]; then
                        local target=$(readlink -f "$lib")
                        if [[ -f "$target" ]]; then
                            cp "$target" "$TARGET_ROOT$lib_dir/" 2>/dev/null || true
                        fi
                    fi
                fi
            fi
        done
    }
    
    # Copy libs for all our binaries
    print_info "Analyzing binary dependencies..."
    for binary in "$TARGET_ROOT/sbin/airride" "$TARGET_ROOT/sbin/poyo" \
                  "$TARGET_ROOT/usr/bin/airridectl" "$TARGET_ROOT/usr/bin/dreamland"; do
        if [[ -f "$binary" ]]; then
            print_info "  Copying libraries for $(basename $binary)..."
            copy_libs "$binary"
        fi
    done
    
    # Explicitly copy critical libraries that might be missed
    print_info "Ensuring critical libraries are present..."
    
    # List of critical libraries
    CRITICAL_LIBS=(
        "libc.so.6"
        "libm.so.6"
        "libdl.so.2"
        "libpthread.so.0"
        "librt.so.1"
        "libcrypt.so.1"
        "libcrypt.so.2"  # New crypt library
        "libgcc_s.so.1"
        "libstdc++.so.6"
    )
    
    for lib in "${CRITICAL_LIBS[@]}"; do
        # Find the library
        LIBPATH=$(find /lib* /usr/lib* -name "$lib" 2>/dev/null | head -1)
        if [[ -n "$LIBPATH" && -f "$LIBPATH" ]]; then
            LIB_DIR=$(dirname "$LIBPATH")
            mkdir -p "$TARGET_ROOT$LIB_DIR"
            
            # Copy the library
            cp "$LIBPATH" "$TARGET_ROOT$LIB_DIR/" 2>/dev/null || true
            print_success "  Copied $lib"
            
            # If it's a symlink, also copy the target
            if [[ -L "$LIBPATH" ]]; then
                TARGET=$(readlink -f "$LIBPATH")
                if [[ -f "$TARGET" ]]; then
                    cp "$TARGET" "$TARGET_ROOT$LIB_DIR/" 2>/dev/null || true
                    
                    # Recreate the symlink in the target
                    cd "$TARGET_ROOT$LIB_DIR"
                    ln -sf "$(basename $TARGET)" "$lib" 2>/dev/null || true
                    cd - > /dev/null
                fi
            fi
        else
            print_warning "  $lib not found (may not be needed)"
        fi
    done
    
    # Copy dynamic linker
    print_info "Copying dynamic linker..."
    for linker in "ld-linux-x86-64.so.2" "ld-linux.so.2"; do
        LINKER=$(find /lib* -name "$linker" 2>/dev/null | head -1)
        if [[ -n "$LINKER" ]]; then
            LINKER_DIR=$(dirname "$LINKER")
            mkdir -p "$TARGET_ROOT$LINKER_DIR"
            cp "$LINKER" "$TARGET_ROOT$LINKER_DIR/"
            print_success "  Copied $linker"
        fi
    done
    
    # Create lib64 -> lib symlink if needed
    if [[ -d "$TARGET_ROOT/lib" && ! -e "$TARGET_ROOT/lib64" ]]; then
        cd "$TARGET_ROOT"
        ln -s lib lib64
        cd - > /dev/null
        print_success "Created lib64 -> lib symlink"
    fi
    
    # Count libraries
    LIB_COUNT=$(find "$TARGET_ROOT/lib" "$TARGET_ROOT/lib64" "$TARGET_ROOT/usr/lib" \
                     -name "*.so*" 2>/dev/null | wc -l)
    print_success "Copied $LIB_COUNT libraries total"
    
    # Verify critical binaries have their dependencies
    print_info "Verifying binary dependencies..."
    
    local all_ok=true
    for binary in "$TARGET_ROOT/sbin/poyo" "$TARGET_ROOT/sbin/airride"; do
        if [[ -f "$binary" ]]; then
            MISSING=$(chroot "$TARGET_ROOT" /bin/sh -c "LD_LIBRARY_PATH=/lib:/lib64:/usr/lib ldd $(basename $binary) 2>&1" | grep "not found" || true)
            if [[ -n "$MISSING" ]]; then
                print_warning "  $(basename $binary) has missing libraries:"
                echo "$MISSING"
                all_ok=false
            else
                print_success "  $(basename $binary) - all dependencies satisfied"
            fi
        fi
    done
    
    if [[ "$all_ok" != "true" ]]; then
        print_warning "Some dependencies missing - may cause runtime errors"
    fi
    
    COMPLETED_STEPS[essentials]=1
}

# ============================================
# Step 9: Create Device Nodes and Config
# ============================================

create_system_files() {
    print_step 9 11 "Create Device Nodes and System Configuration"
    
    # Create device nodes
    print_info "Creating device nodes..."
    cd "$TARGET_ROOT/dev"
    
    sudo mknod -m 666 null c 1 3 2>/dev/null || true
    sudo mknod -m 666 zero c 1 5 2>/dev/null || true
    sudo mknod -m 666 random c 1 8 2>/dev/null || true
    sudo mknod -m 666 urandom c 1 9 2>/dev/null || true
    sudo mknod -m 600 console c 5 1 2>/dev/null || true
    sudo mknod -m 666 tty c 5 0 2>/dev/null || true
    sudo mknod -m 666 tty0 c 4 0 2>/dev/null || true
    
    cd - > /dev/null
    print_success "Device nodes created"
    
    # Create system configuration files
    print_info "Creating system configuration..."
    
    cat > "$TARGET_ROOT/etc/fstab" << 'EOF'
proc    /proc   proc    defaults    0   0
sysfs   /sys    sysfs   defaults    0   0
devtmpfs /dev   devtmpfs defaults   0   0
tmpfs   /run    tmpfs   defaults    0   0
tmpfs   /tmp    tmpfs   defaults    0   0
EOF
    
    cat > "$TARGET_ROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
EOF
    
    cat > "$TARGET_ROOT/etc/group" << 'EOF'
root:x:0:
EOF
    
    # Password: galactica
    cat > "$TARGET_ROOT/etc/shadow" << 'EOF'
root:$6$galactica$K9p3vXJ5qZ8mH4xL2nY7.wR9tE1sC8bA6fD5gH3jK2lM9nP0qR1sT2uV3wX4yZ5aB6cD7eF8gH9iJ0kL1mN2oP3:19000:0:99999:7:::
EOF
    chmod 600 "$TARGET_ROOT/etc/shadow"
    
    echo "galactica" > "$TARGET_ROOT/etc/hostname"
    
    cat > "$TARGET_ROOT/etc/hosts" << 'EOF'
127.0.0.1   localhost
127.0.1.1   galactica
EOF
    
    cat > "$TARGET_ROOT/etc/profile" << 'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='[\u@\h \W]\$ '
export TERM=linux
EOF
    
    # Create Poyo getty service
    cat > "$TARGET_ROOT/etc/airride/services/getty.service" << 'EOF'
[Service]
name=getty
description=Poyo Login on Console
type=simple
exec_start=/sbin/poyo
restart=always
restart_delay=1

[Dependencies]
EOF
    
    # Create welcome message
    cat > "$TARGET_ROOT/etc/motd" << 'EOF'

  ________       .__                 __  .__               
 /  _____/_____  |  | _____    _____/  |_|__| ____ _____   
/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  
\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_
 \______  (____  /____(____  /\___  >__| |__|\___  >____  /
        \/     \/          \/     \/             \/     \/ 


Welcome to Galactica Linux!

You are now logged into a minimal Linux system with:
  • AirRide init system
  • Poyo secure login
  • Dreamland package manager

Quick commands:
  ls               - List files
  ps               - Show processes
  airridectl list  - Manage services
  dreamland sync   - Update packages
  passwd           - Change your password

Default credentials:
  Username: root
  Password: galactica

EOF
    
    # Install bootstrap script if available
    if [[ -f "./bootstrap.sh" ]]; then
        cp ./bootstrap.sh "$TARGET_ROOT/usr/bin/galactica-bootstrap"
        chmod +x "$TARGET_ROOT/usr/bin/galactica-bootstrap"
        print_success "Bootstrap script installed"
    fi
    
    print_success "System configuration created"
    COMPLETED_STEPS[sysfiles]=1
}

# ============================================
# Step 10: Create Root Filesystem Image
# ============================================

create_rootfs() {
    print_step 10 11 "Create Root Filesystem Image"
    
    # Pre-flight check: Verify all critical binaries work
    print_info "Pre-flight verification..."
    
    local verify_failed=false
    
    # Check Poyo specifically since it failed
    if [[ -x "$TARGET_ROOT/sbin/poyo" ]]; then
        print_info "Checking poyo dependencies..."
        
        # Try to check dependencies in a chroot-like way
        MISSING=$(LD_LIBRARY_PATH="$TARGET_ROOT/lib:$TARGET_ROOT/lib64:$TARGET_ROOT/usr/lib" \
                  ldd "$TARGET_ROOT/sbin/poyo" 2>&1 | grep "not found" || true)
        
        if [[ -n "$MISSING" ]]; then
            print_error "Poyo has missing libraries:"
            echo "$MISSING"
            echo ""
            echo "Attempting to fix..."
            
            # Try to find and copy missing libraries
            echo "$MISSING" | grep -o "lib[^ ]*" | while read missing_lib; do
                LIBPATH=$(find /lib* /usr/lib* -name "$missing_lib" 2>/dev/null | head -1)
                if [[ -n "$LIBPATH" ]]; then
                    LIB_DIR=$(dirname "$LIBPATH")
                    mkdir -p "$TARGET_ROOT$LIB_DIR"
                    cp "$LIBPATH" "$TARGET_ROOT$LIB_DIR/"
                    print_success "  Copied $missing_lib"
                    
                    # Also copy symlink target if it's a symlink
                    if [[ -L "$LIBPATH" ]]; then
                        TARGET=$(readlink -f "$LIBPATH")
                        cp "$TARGET" "$TARGET_ROOT$LIB_DIR/"
                        cd "$TARGET_ROOT$LIB_DIR"
                        ln -sf "$(basename $TARGET)" "$missing_lib" 2>/dev/null || true
                        cd - > /dev/null
                    fi
                fi
            done
            
            # Check again
            MISSING=$(LD_LIBRARY_PATH="$TARGET_ROOT/lib:$TARGET_ROOT/lib64:$TARGET_ROOT/usr/lib" \
                      ldd "$TARGET_ROOT/sbin/poyo" 2>&1 | grep "not found" || true)
            
            if [[ -n "$MISSING" ]]; then
                print_error "Still missing libraries - Poyo may not work in VM!"
                verify_failed=true
            else
                print_success "All Poyo dependencies now satisfied"
            fi
        else
            print_success "Poyo dependencies satisfied"
        fi
    fi
    
    if [[ "$verify_failed" == "true" ]]; then
        print_warning "Verification found issues - continuing anyway"
        read -p "Continue with rootfs creation? (y/n) [y]: " cont
        cont=${cont:-y}
        if [[ "$cont" != "y" ]]; then
            return 1
        fi
    fi
    
    if [[ -f "$OUTPUT_ROOTFS" ]]; then
        print_info "Removing old root filesystem..."
        rm -f "$OUTPUT_ROOTFS"
    fi
    
    print_info "Creating ${ROOTFS_SIZE}MB ext4 image..."
    dd if=/dev/zero of="$OUTPUT_ROOTFS" bs=1M count=$ROOTFS_SIZE status=progress
    
    print_info "Formatting filesystem..."
    mkfs.ext4 -F -L "GalacticaRoot" "$OUTPUT_ROOTFS"
    
    print_info "Mounting and copying files..."
    mkdir -p mnt_tmp
    sudo mount -o loop "$OUTPUT_ROOTFS" mnt_tmp
    
    sudo cp -a "$TARGET_ROOT"/* mnt_tmp/
    
    # Verify critical files
    print_info "Verifying filesystem..."
    local verify_ok=true
    
    if [[ -x mnt_tmp/sbin/init ]]; then
        print_success "Init is executable"
    else
        print_error "Init problem!"
        verify_ok=false
    fi
    
    if [[ -x mnt_tmp/sbin/poyo ]]; then
        print_success "Poyo is executable"
    else
        print_error "Poyo problem!"
        verify_ok=false
    fi
    
    if [[ -x mnt_tmp/bin/sh ]]; then
        print_success "Shell is executable"
    else
        print_error "Shell problem!"
        verify_ok=false
    fi
    
    if [[ -c mnt_tmp/dev/console ]]; then
        print_success "Console device exists"
    else
        print_error "Console device missing!"
        verify_ok=false
    fi
    
    sudo umount mnt_tmp
    rmdir mnt_tmp
    
    if [[ "$verify_ok" != "true" ]]; then
        print_error "Filesystem verification failed!"
        return 1
    fi
    
    SIZE=$(du -h "$OUTPUT_ROOTFS" | cut -f1)
    print_success "Root filesystem created ($SIZE)"
    
    COMPLETED_STEPS[rootfs]=1
}

# ============================================
# Step 11: Create Launch Scripts
# ============================================

create_launch_scripts() {
    print_step 11 11 "Create Launch Scripts"
    
    # Main launch script
    cat > run-galactica.sh << 'EOF'
#!/bin/bash
# Launch Galactica in QEMU

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

if [[ ! -f "$KERNEL" ]] || [[ ! -f "$ROOTFS" ]]; then
    echo "Error: Kernel or rootfs not found!"
    echo "Run: ./build-galactica.sh"
    exit 1
fi

echo "Starting Galactica Linux..."
echo "Press Ctrl+A then X to exit QEMU"
echo ""

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -drive "file=$ROOTFS,format=raw,if=virtio" \
    -m 512M \
    -smp 2 \
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init" \
    -nographic \
    -serial mon:stdio
EOF
    chmod +x run-galactica.sh
    
    # Debug launch script
    cat > run-galactica-debug.sh << 'EOF'
#!/bin/bash
# Launch Galactica with debug output

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

if [[ ! -f "$KERNEL" ]] || [[ ! -f "$ROOTFS" ]]; then
    echo "Error: Kernel or rootfs not found!"
    exit 1
fi

echo "=== Galactica Debug Boot ==="
echo ""
echo "Watch for:"
echo "  • 'virtio_blk virtio0' - VIRTIO driver loading"
echo "  • 'VFS: Mounted root' - Root filesystem mounted"
echo "  • 'Run /sbin/init' - Init starting"
echo "  • AirRide startup messages"
echo "  • Poyo login prompt"
echo ""
echo "Press Enter to boot..."
read

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -drive "file=$ROOTFS,format=raw,if=virtio" \
    -m 512M \
    -smp 2 \
    -append "root=/dev/vda rw console=ttyS0 init=/sbin/init debug loglevel=7 earlyprintk=serial,ttyS0,115200" \
    -nographic \
    -serial mon:stdio
EOF
    chmod +x run-galactica-debug.sh
    
    print_success "Launch scripts created"
    COMPLETED_STEPS[scripts]=1
}

# ============================================
# Main Build Process
# ============================================

main() {
    print_banner
    
    echo "This script will build a complete Galactica Linux system:"
    echo ""
    echo "  1. ✓ Linux kernel ${KERNEL_VERSION} with VIRTIO + security hardening"
    echo "     (Configurable - edit KERNEL_VERSION at top of script)"
    echo "  2. ✓ Poyo getty/login (with optional PAM)"
    echo "  3. ✓ AirRide init system"
    echo "  4. ✓ AirRideCtl control tool"
    echo "  5. ✓ Dreamland package manager"
    echo "  6. ✓ Busybox shell and utilities"
    echo "  7. ✓ Root filesystem with all components"
    echo "  8. ✓ Bootable ${ROOTFS_SIZE}MB disk image"
    echo "  9. ✓ QEMU launch scripts"
    echo ""
    echo "Kernel options:"
    echo "  • Current: ${KERNEL_VERSION}"
    echo "  • 6.12.x - Latest mainline (requires GCC 13+)"
    echo "  • 6.6.x  - LTS until Dec 2026 (RECOMMENDED)"
    echo "  • 6.1.x  - Older LTS until Dec 2026"
    echo ""
    echo "Kernel features:"
    echo "  • VIRTIO support (for QEMU)"
    echo "  • Security hardening enabled"
    echo "  • Stack protection"
    echo "  • Memory randomization (KASLR)"
    echo "  • Page table isolation"
    echo "  • Auto-download and caching"
    echo ""
    echo "Build configuration:"
    echo "  • Compiler: GCC/G++ (standard)"
    if [[ "$USE_PAM" == "true" ]]; then
        echo "  • PAM authentication: ENABLED"
    else
        echo "  • PAM authentication: disabled (/etc/shadow)"
    fi
    echo ""
    echo "Build time: ~10-20 minutes (first build includes kernel download)"
    echo "Subsequent builds: ~1-2 minutes (kernel cached)"
    echo ""
    read -p "Continue? (y/n) [y]: " continue
    continue=${continue:-y}
    
    if [[ "$continue" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
    
    # Run all build steps
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
    
    # Final summary
    clear
    print_banner
    echo -e "${GREEN}${BOLD}=== Build Complete! ===${NC}"
    echo ""
    echo "Built components:"
    for step in "${!COMPLETED_STEPS[@]}"; do
        echo -e "  ${GREEN}✓${NC} $step"
    done
    echo ""
    echo "System files:"
    echo "  • Kernel:     galactica-build/boot/vmlinuz-galactica"
    echo "  • Root FS:    $OUTPUT_ROOTFS ($(du -h $OUTPUT_ROOTFS | cut -f1))"
    echo "  • Build dir:  $TARGET_ROOT/"
    echo ""
    echo "Installed programs:"
    echo "  • /sbin/init (airride)    - Init system"
    echo "  • /sbin/poyo              - Getty/login"
    echo "  • /usr/bin/airridectl     - Service manager"
    echo "  • /usr/bin/dreamland      - Package manager"
    echo ""
    echo "Default credentials:"
    echo "  Username: ${CYAN}root${NC}"
    echo "  Password: ${CYAN}galactica${NC}"
    echo ""
    echo -e "${BOLD}${GREEN}To boot Galactica:${NC}"
    echo -e "  ${YELLOW}./run-galactica.sh${NC}"
    echo ""
    echo "For debug output:"
    echo -e "  ${YELLOW}./run-galactica-debug.sh${NC}"
    echo ""
    echo "After boot, you'll see:"
    echo -e "  ${BLUE}galactica login:${NC} root"
    echo -e "  ${BLUE}Password:${NC} galactica"
    echo ""
    echo "Then try:"
    echo "  • ls              - List files"
    echo "  • ps              - Show processes"
    echo "  • airridectl list - Manage services"
    echo "  • dreamland sync  - Update packages"
    echo ""
}

# Run main
main
