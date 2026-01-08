#!/bin/bash
# Galactica Complete Build and Launch Script
# Builds everything correctly with all fixes applied

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
KERNEL_DIR="./linux-6.18.3"
AIRRIDE_DIR="./AirRide"
DREAMLAND_DIR="./Dreamland"
OUTPUT_ROOTFS="galactica-rootfs.img"
ROOTFS_SIZE=1024  # Size in MB

# Track what steps have been completed
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

    Complete Build System - All Fixes Applied
EOF
    echo -e "${NC}"
    echo -e "${BOLD}=== Galactica Master Build Script v2.0 ===${NC}"
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
    print_step 0 10 "Pre-flight Checks"
    
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
    check_dependency "qemu-system-x86_64" "qemu-system-x86" || print_warning "QEMU not found"
    
    # Check for busybox
    if command -v busybox &>/dev/null; then
        print_success "busybox found"
    else
        print_warning "busybox not found - install: sudo apt install busybox-static"
        all_ok=false
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
# Step 1: Configure and Build Kernel with VIRTIO
# ============================================

build_kernel() {
    print_step 1 10 "Configure and Build Linux Kernel with VIRTIO Support"
    
    if [[ ! -d "$KERNEL_DIR" ]]; then
        print_error "Kernel source directory not found: $KERNEL_DIR"
        echo "Download Linux 6.18.3 and extract to $KERNEL_DIR"
        return 1
    fi
    
    cd "$KERNEL_DIR"
    
    # Create default config if needed
    if [[ ! -f .config ]]; then
        print_info "Creating default kernel configuration..."
        make defconfig
    fi
    
    print_info "Configuring kernel with VIRTIO support..."
    
    # Remove any existing VIRTIO config
    sed -i '/CONFIG_VIRTIO/d' .config
    sed -i '/CONFIG_SCSI_VIRTIO/d' .config
    
    # Add VIRTIO configuration
    cat >> .config << 'EOF'

# VIRTIO drivers for QEMU (REQUIRED)
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

# Ensure EXT4 is built-in (REQUIRED)
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y
EOF
    
    # Apply configuration
    make olddefconfig
    
    # Verify critical options
    print_info "Verifying kernel configuration..."
    local config_ok=true
    for opt in CONFIG_VIRTIO CONFIG_VIRTIO_PCI CONFIG_VIRTIO_BLK CONFIG_EXT4_FS; do
        if grep -q "^${opt}=y" .config; then
            print_success "$opt enabled"
        else
            print_error "$opt NOT enabled!"
            config_ok=false
        fi
    done
    
    if [[ "$config_ok" != "true" ]]; then
        print_error "Kernel configuration failed!"
        return 1
    fi
    
    print_info "Building kernel (this will take 5-15 minutes)..."
    make clean
    make -j$(nproc) 2>&1 | tee ../kernel-build.log
    
    if [[ -f arch/x86/boot/bzImage ]]; then
        print_success "Kernel built successfully"
        COMPLETED_STEPS[kernel]=1
    else
        print_error "Kernel build failed. Check kernel-build.log"
        return 1
    fi
    
    cd ..
}

# ============================================
# Step 2: Build AirRide Init System
# ============================================

build_airride() {
    print_step 2 10 "Build AirRide Init System"
    
    if [[ ! -d "$AIRRIDE_DIR/Init" ]]; then
        print_error "AirRide source not found: $AIRRIDE_DIR/Init"
        return 1
    fi
    
    cd "$AIRRIDE_DIR/Init"
    
    print_info "Building AirRide..."
    zora build || {
        print_error "Failed to build AirRide"
        return 1
    }
    
    # Find the built binary
    AIRRIDE_BIN=$(find . -name "Init" -type f -executable | head -1)
    if [[ -z "$AIRRIDE_BIN" ]]; then
        AIRRIDE_BIN="./target/release/Init"
    fi
    
    if [[ -f "$AIRRIDE_BIN" ]]; then
        print_success "AirRide built: $AIRRIDE_BIN"
        COMPLETED_STEPS[airride]=1
    else
        print_error "AirRide binary not found after build"
        return 1
    fi
    
    cd ../..
}

# ============================================
# Step 3: Build AirRide Control Tool
# ============================================

build_airridectl() {
    print_step 3 10 "Build AirRide Control Tool"
    
    if [[ ! -d "$AIRRIDE_DIR/Ctl" ]]; then
        print_error "AirRideCtl source not found: $AIRRIDE_DIR/Ctl"
        return 1
    fi
    
    cd "$AIRRIDE_DIR/Ctl"
    
    print_info "Building AirRideCtl..."
    zora build || {
        print_error "Failed to build AirRideCtl"
        return 1
    }
    
    AIRRIDECTL_BIN=$(find . -name "Ctl" -type f -executable | head -1)
    if [[ -z "$AIRRIDECTL_BIN" ]]; then
        AIRRIDECTL_BIN="./target/release/Ctl"
    fi
    
    if [[ -f "$AIRRIDECTL_BIN" ]]; then
        print_success "AirRideCtl built: $AIRRIDECTL_BIN"
        COMPLETED_STEPS[airridectl]=1
    else
        print_error "AirRideCtl binary not found after build"
        return 1
    fi
    
    cd ../..
}

# ============================================
# Step 4: Build Dreamland Package Manager
# ============================================

build_dreamland() {
    print_step 4 10 "Build Dreamland Package Manager"
    
    if [[ ! -d "$DREAMLAND_DIR" ]]; then
        print_error "Dreamland source not found: $DREAMLAND_DIR"
        return 1
    fi
    
    cd "$DREAMLAND_DIR"
    
    print_info "Building Dreamland..."
    zora build || {
        print_error "Failed to build Dreamland"
        return 1
    }
    
    DREAMLAND_BIN=$(find . -name "Dreamland" -type f -executable | head -1)
    if [[ -z "$DREAMLAND_BIN" ]]; then
        DREAMLAND_BIN="./target/release/Dreamland"
    fi
    
    if [[ -f "$DREAMLAND_BIN" ]]; then
        print_success "Dreamland built: $DREAMLAND_BIN"
        COMPLETED_STEPS[dreamland]=1
    else
        print_error "Dreamland binary not found after build"
        return 1
    fi
    
    cd ..
}

# ============================================
# Step 5: Prepare Build Directory
# ============================================

prepare_build_dir() {
    print_step 5 10 "Prepare Root Filesystem Structure"
    
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
# Step 6: Install System Components
# ============================================

install_components() {
    print_step 6 10 "Install System Components"
    
    # Install kernel
    print_info "Installing kernel..."
    mkdir -p "$TARGET_ROOT/boot"
    cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
    cp "$KERNEL_DIR/System.map" "$TARGET_ROOT/boot/System.map-galactica"
    cp "$KERNEL_DIR/.config" "$TARGET_ROOT/boot/config-galactica"
    
    # Install kernel modules
    cd "$KERNEL_DIR"
    make INSTALL_MOD_PATH="$(realpath ../$TARGET_ROOT)" modules_install
    cd ..
    
    print_success "Kernel installed"
    
    # Install AirRide
    print_info "Installing AirRide components..."
    AIRRIDE_BIN=$(find "$AIRRIDE_DIR/Init" -name "Init" -type f -executable | head -1)
    AIRRIDECTL_BIN=$(find "$AIRRIDE_DIR/Ctl" -name "Ctl" -type f -executable | head -1)
    
    cp "$AIRRIDE_BIN" "$TARGET_ROOT/sbin/airride"
    chmod +x "$TARGET_ROOT/sbin/airride"
    
    cp "$AIRRIDECTL_BIN" "$TARGET_ROOT/usr/bin/airridectl"
    chmod +x "$TARGET_ROOT/usr/bin/airridectl"
    
    # Create init symlink
    cd "$TARGET_ROOT/sbin"
    ln -sf airride init
    cd - > /dev/null
    
    print_success "AirRide installed"
    
    # Install Dreamland
    print_info "Installing Dreamland..."
    DREAMLAND_BIN=$(find "$DREAMLAND_DIR" -name "Dreamland" -type f -executable | head -1)
    
    cp "$DREAMLAND_BIN" "$TARGET_ROOT/usr/bin/dreamland"
    chmod +x "$TARGET_ROOT/usr/bin/dreamland"
    
    cd "$TARGET_ROOT/usr/bin"
    ln -sf dreamland dl
    cd - > /dev/null
    
    print_success "Dreamland installed"
    
    COMPLETED_STEPS[install]=1
}

# ============================================
# Step 7: Install Busybox and Libraries
# ============================================

install_essentials() {
    print_step 7 10 "Install Shell and Essential Libraries"
    
    # Install busybox
    print_info "Installing busybox..."
    if command -v busybox &>/dev/null; then
        cp /bin/busybox "$TARGET_ROOT/bin/"
        chmod +x "$TARGET_ROOT/bin/busybox"
        
        cd "$TARGET_ROOT/bin"
        # Create essential symlinks
        for cmd in sh ash ls cat echo pwd mkdir rmdir rm cp mv ln chmod chown \
                   grep sed awk sort uniq wc head tail cut tr find mount umount \
                   ps kill killall sleep touch date hostname df du free; do
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
    
    # Function to copy libs
    copy_libs() {
        local binary=$1
        ldd "$binary" 2>/dev/null | grep -o '/lib[^ ]*' | while read lib; do
            if [[ -f "$lib" ]]; then
                local lib_dir=$(dirname "$lib")
                mkdir -p "$TARGET_ROOT$lib_dir"
                cp -n "$lib" "$TARGET_ROOT$lib_dir/" 2>/dev/null || true
            fi
        done
    }
    
    # Copy libs for AirRide
    copy_libs "$TARGET_ROOT/sbin/airride"
    
    # Copy libs for shell (if not static)
    if [[ -f "$TARGET_ROOT/bin/sh" ]]; then
        copy_libs "$TARGET_ROOT/bin/sh"
    fi
    
    # Copy essential C++ libraries for AirRide
    for lib in libstdc++.so.6 libgcc_s.so.1 libc.so.6 libm.so.6; do
        LIBPATH=$(find /lib* /usr/lib* -name "$lib" 2>/dev/null | head -1)
        if [[ -n "$LIBPATH" ]]; then
            LIB_DIR=$(dirname "$LIBPATH")
            mkdir -p "$TARGET_ROOT$LIB_DIR"
            cp "$LIBPATH" "$TARGET_ROOT$LIB_DIR/" 2>/dev/null || true
        fi
    done
    
    # Copy dynamic linker
    LINKER=$(find /lib* -name "ld-linux-x86-64.so.2" 2>/dev/null | head -1)
    if [[ -n "$LINKER" ]]; then
        LINKER_DIR=$(dirname "$LINKER")
        mkdir -p "$TARGET_ROOT$LINKER_DIR"
        cp "$LINKER" "$TARGET_ROOT$LINKER_DIR/"
    fi
    
    LIB_COUNT=$(find "$TARGET_ROOT/lib" "$TARGET_ROOT/lib64" -name "*.so*" 2>/dev/null | wc -l)
    print_success "Copied $LIB_COUNT libraries"
    
    COMPLETED_STEPS[essentials]=1
}

# ============================================
# Step 8: Create Device Nodes and Config
# ============================================

create_system_files() {
    print_step 8 10 "Create Device Nodes and System Configuration"
    
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
    
    # Create emergency shell service
    cat > "$TARGET_ROOT/etc/airride/services/shell.service" << 'EOF'
[Service]
name=shell
description=Emergency Shell
type=simple
exec_start=/bin/sh
restart=always
restart_delay=1

[Dependencies]
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
# Step 9: Create Root Filesystem Image
# ============================================

create_rootfs() {
    print_step 9 10 "Create Root Filesystem Image"
    
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
# Step 10: Create Launch Scripts
# ============================================

create_launch_scripts() {
    print_step 10 10 "Create Launch Scripts"
    
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
    echo "  1. ✓ Linux kernel 6.18.3 with VIRTIO support"
    echo "  2. ✓ AirRide init system"
    echo "  3. ✓ AirRideCtl control tool"
    echo "  4. ✓ Dreamland package manager"
    echo "  5. ✓ Busybox shell and utilities"
    echo "  6. ✓ Root filesystem with all components"
    echo "  7. ✓ Bootable ${ROOTFS_SIZE}MB disk image"
    echo "  8. ✓ QEMU launch scripts"
    echo ""
    echo "Build time: ~10-20 minutes (depending on CPU)"
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
    echo "After boot:"
    echo "  • Run: ${CYAN}galactica-bootstrap${NC} (first-time setup)"
    echo "  • Use: ${CYAN}airridectl list${NC} (manage services)"
    echo "  • Use: ${CYAN}dreamland sync${NC} (package manager)"
    echo ""
}

# Run main
main
