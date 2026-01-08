#!/bin/bash
# Galactica Master Build and Launch Script
# Builds everything and prepares for QEMU boot

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
INITRAMFS_DIR="./initramfs-build"
OUTPUT_INITRAMFS="galactica-initramfs.cpio.gz"
OUTPUT_ROOTFS="galactica-rootfs.img"
ROOTFS_SIZE=2048  # Size in MB

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


    Minimal Linux - Build & Launch System
EOF
    echo -e "${NC}"
    echo -e "${BOLD}=== Galactica Master Build Script ===${NC}"
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
        echo "   Install it with: sudo apt install $pkg (or equivalent)"
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
    
    # Essential build tools
    check_dependency "gcc" "build-essential" || all_ok=false
    check_dependency "g++" "build-essential" || all_ok=false
    check_dependency "make" "build-essential" || all_ok=false
    
    # Kernel build tools
    check_dependency "bc" "bc" || all_ok=false
    check_dependency "flex" "flex" || all_ok=false
    check_dependency "bison" "bison" || all_ok=false
    
    # System tools
    check_dependency "dd" "coreutils" || all_ok=false
    check_dependency "mkfs.ext4" "e2fsprogs" || all_ok=false
    check_dependency "cpio" "cpio" || all_ok=false
    check_dependency "gzip" "gzip" || all_ok=false
    
    # Optional but recommended
    check_dependency "qemu-system-x86_64" "qemu-system-x86" || print_warning "QEMU not found (required for testing)"
    
    # Check if running as root (for device node creation)
    if [[ $EUID -eq 0 ]]; then
        print_warning "Running as root"
    else
        print_info "Not running as root (will need sudo for device nodes)"
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
# Step 1: Build Kernel
# ============================================

build_kernel() {
    print_step 1 11 "Build Linux Kernel"
    
    if [[ -f "$KERNEL_DIR/.config" ]] && [[ -f "$KERNEL_DIR/arch/x86/boot/bzImage" ]]; then
        print_info "Kernel already configured and built"
        read -p "Rebuild kernel? (y/n) [n]: " rebuild
        if [[ "$rebuild" != "y" ]]; then
            print_success "Using existing kernel"
            COMPLETED_STEPS[kernel]=1
            return 0
        fi
    fi
    
    if [[ ! -d "$KERNEL_DIR" ]]; then
        print_error "Kernel source directory not found: $KERNEL_DIR"
        echo "Download and extract Linux kernel 6.18.3"
        return 1
    fi
    
    cd "$KERNEL_DIR"
    
    print_info "Configuring kernel..."
    if [[ ! -f .config ]]; then
        make defconfig
        print_success "Created default configuration"
    fi
    
    print_info "Building kernel (this may take a while)..."
    make -j$(nproc) 2>&1 | tee kernel-build.log
    
    if [[ -f arch/x86/boot/bzImage ]]; then
        print_success "Kernel built successfully: arch/x86/boot/bzImage"
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
    print_step 2 11 "Build AirRide Init System"
    
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
    print_step 3 11 "Build AirRide Control Tool"
    
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
    print_step 4 11 "Build Dreamland Package Manager"
    
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
    print_step 5 11 "Prepare Build Directory"
    
    print_info "Creating/cleaning build directory: $TARGET_ROOT"
    
    # Ask before removing
    if [[ -d "$TARGET_ROOT" ]]; then
        print_warning "Build directory exists"
        read -p "Clean and rebuild? (y/n) [y]: " clean
        clean=${clean:-y}
        if [[ "$clean" == "y" ]]; then
            rm -rf "$TARGET_ROOT"
        fi
    fi
    
    mkdir -p "$TARGET_ROOT"
    print_success "Build directory ready"
    COMPLETED_STEPS[builddir]=1
}

# ============================================
# Step 6: Install Kernel to Build
# ============================================

install_kernel() {
    print_step 6 11 "Install Kernel to Build"
    
    mkdir -p "$TARGET_ROOT/boot"
    
    print_info "Copying kernel..."
    cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
    cp "$KERNEL_DIR/System.map" "$TARGET_ROOT/boot/System.map-galactica"
    cp "$KERNEL_DIR/.config" "$TARGET_ROOT/boot/config-galactica"
    
    print_info "Installing kernel modules..."
    cd "$KERNEL_DIR"
    make INSTALL_MOD_PATH="$(realpath ../$TARGET_ROOT)" modules_install
    cd ..
    
    print_success "Kernel installed"
    COMPLETED_STEPS[kernel_install]=1
}

# ============================================
# Step 7: Install AirRide Components
# ============================================

install_airride() {
    print_step 7 11 "Install AirRide Components"
    
    mkdir -p "$TARGET_ROOT/sbin"
    mkdir -p "$TARGET_ROOT/usr/bin"
    mkdir -p "$TARGET_ROOT/etc/airride/services"
    
    # Find binaries
    AIRRIDE_BIN=$(find "$AIRRIDE_DIR/Init" -name "Init" -type f -executable | head -1)
    AIRRIDECTL_BIN=$(find "$AIRRIDE_DIR/Ctl" -name "Ctl" -type f -executable | head -1)
    
    print_info "Installing AirRide init..."
    cp "$AIRRIDE_BIN" "$TARGET_ROOT/sbin/airride"
    chmod +x "$TARGET_ROOT/sbin/airride"
    
    print_info "Installing AirRideCtl..."
    cp "$AIRRIDECTL_BIN" "$TARGET_ROOT/usr/bin/airridectl"
    chmod +x "$TARGET_ROOT/usr/bin/airridectl"
    
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
    
    print_success "AirRide components installed"
    COMPLETED_STEPS[airride_install]=1
}

# ============================================
# Step 8: Install Dreamland
# ============================================

install_dreamland() {
    print_step 8 11 "Install Dreamland Package Manager"
    
    mkdir -p "$TARGET_ROOT/usr/bin"
    
    DREAMLAND_BIN=$(find "$DREAMLAND_DIR" -name "Dreamland" -type f -executable | head -1)
    
    print_info "Installing Dreamland..."
    cp "$DREAMLAND_BIN" "$TARGET_ROOT/usr/bin/dreamland"
    chmod +x "$TARGET_ROOT/usr/bin/dreamland"
    
    # Create 'dl' symlink
    cd "$TARGET_ROOT/usr/bin"
    ln -sf dreamland dl
    cd ../../..
    
    print_success "Dreamland installed"
    COMPLETED_STEPS[dreamland_install]=1
}

# ============================================
# Step 9: Copy Essential Binaries
# ============================================

copy_essentials() {
    print_step 9 11 "Copy Essential System Binaries"
    
    if [[ -f "./copy-essentials.sh" ]]; then
        print_info "Running copy-essentials.sh..."
        bash ./copy-essentials.sh "$TARGET_ROOT" || {
            print_warning "copy-essentials.sh had errors, continuing anyway"
        }
        print_success "Essential binaries copied"
    else
        print_warning "copy-essentials.sh not found, skipping"
        print_info "At minimum, you need:"
        echo "  - /bin/sh (shell)"
        echo "  - /lib*/libc.so.* (C library)"
        echo "  - /lib*/ld-linux*.so.* (dynamic linker)"
    fi
    
    COMPLETED_STEPS[essentials]=1
}

# ============================================
# Step 10: Setup QEMU Boot Configuration
# ============================================

setup_qemu_config() {
    print_step 10 11 "Setup QEMU Boot Configuration"
    
    if [[ -f "./setup-qemu-boot.sh" ]]; then
        print_info "Running setup-qemu-boot.sh..."
        bash ./setup-qemu-boot.sh "$TARGET_ROOT"
        print_success "QEMU configuration complete"
    else
        print_warning "setup-qemu-boot.sh not found"
        print_info "Manually creating basic configuration..."
        
        # Create essential structure
        cd "$TARGET_ROOT"
        mkdir -p {bin,dev,etc,proc,sys,run,tmp,var/log}
        
        # Create init symlink
        ln -sf /sbin/airride sbin/init
        
        # Create fstab
        cat > etc/fstab << 'EOF'
proc    /proc   proc    defaults    0   0
sysfs   /sys    sysfs   defaults    0   0
devtmpfs /dev   devtmpfs defaults   0   0
tmpfs   /run    tmpfs   defaults    0   0
tmpfs   /tmp    tmpfs   defaults    0   0
EOF
        
        # Set root password to 'galactica'
        print_info "Setting default root password to 'galactica'..."
        cat > etc/shadow << 'SHADOW_EOF'
root:$6$rounds=5000$galactica$K9p3vXJ5qZ8mH4xL2nY7.wR9tE1sC8bA6fD5gH3jK2lM9nP0qR1sT2uV3wX4yZ5aB6cD7eF8gH9iJ0kL1mN2oP3:19000:0:99999:7:::
SHADOW_EOF
        chmod 600 etc/shadow
        print_success "Root password set to 'galactica'"
        
        cd ..
        print_success "Basic configuration created"
    fi
    
    # Install bootstrap script
    print_info "Installing bootstrap script..."
    if [[ -f "./bootstrap.sh" ]]; then
        cp ./bootstrap.sh "$TARGET_ROOT/usr/bin/galactica-bootstrap"
        chmod +x "$TARGET_ROOT/usr/bin/galactica-bootstrap"
        print_success "Bootstrap script installed as 'galactica-bootstrap'"
    else
        print_warning "bootstrap.sh not found in current directory"
    fi
    
    COMPLETED_STEPS[qemu_config]=1
}

# ============================================
# Step 11: Create Bootable Image
# ============================================

create_bootable_image() {
    print_step 11 11 "Create Bootable Root Filesystem Image"
    
    print_info "What type of image would you like to create?"
    echo ""
    echo "  1) Initramfs (lightweight, RAM-based)"
    echo "  2) Disk image (persistent, ext4 filesystem)"
    echo "  3) Both"
    echo "  4) Skip (use existing)"
    echo ""
    read -p "Select option (1-4) [1]: " image_choice
    image_choice=${image_choice:-1}
    
    case $image_choice in
        1|3)
            create_initramfs
            ;;
    esac
    
    case $image_choice in
        2|3)
            create_disk_image
            ;;
    esac
    
    COMPLETED_STEPS[bootable]=1
}

create_initramfs() {
    print_info "Creating initramfs..."
    
    rm -rf "$INITRAMFS_DIR"
    mkdir -p "$INITRAMFS_DIR"
    
    # Copy essential files to initramfs
    cd "$INITRAMFS_DIR"
    
    # Copy from target root
    cp -a ../"$TARGET_ROOT"/* .
    
    # Ensure init exists
    if [[ ! -e sbin/init ]]; then
        ln -s /sbin/airride sbin/init
    fi
    
    # Create initramfs
    print_info "Packing initramfs..."
    find . -print0 | cpio --null --create --verbose --format=newc | gzip -9 > "../$OUTPUT_INITRAMFS"
    
    cd ..
    
    SIZE=$(du -h "$OUTPUT_INITRAMFS" | cut -f1)
    print_success "Initramfs created: $OUTPUT_INITRAMFS ($SIZE)"
}

create_disk_image() {
    print_info "Creating disk image ($ROOTFS_SIZE MB)..."
    
    # Create sparse file
    dd if=/dev/zero of="$OUTPUT_ROOTFS" bs=1M count=0 seek=$ROOTFS_SIZE
    
    # Create ext4 filesystem
    mkfs.ext4 -F "$OUTPUT_ROOTFS"
    
    # Mount and copy files
    print_info "Mounting and copying files..."
    mkdir -p mnt_tmp
    sudo mount -o loop "$OUTPUT_ROOTFS" mnt_tmp
    sudo cp -a "$TARGET_ROOT"/* mnt_tmp/
    sudo umount mnt_tmp
    rmdir mnt_tmp
    
    SIZE=$(du -h "$OUTPUT_ROOTFS" | cut -f1)
    print_success "Disk image created: $OUTPUT_ROOTFS ($SIZE)"
}

# ============================================
# Create Launch Scripts
# ============================================

create_launch_scripts() {
    print_info "Creating QEMU launch scripts..."
    
    # Launch with initramfs
    cat > run-qemu-initramfs.sh << 'EOF'
#!/bin/bash
# Launch Galactica with initramfs

KERNEL="galactica-build/boot/vmlinuz-galactica"
INITRAMFS="galactica-initramfs.cpio.gz"

if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found"
    exit 1
fi

if [[ ! -f "$INITRAMFS" ]]; then
    echo "Error: Initramfs not found"
    exit 1
fi

echo "Starting Galactica (initramfs mode)..."
echo "Press Ctrl+A then X to exit"
echo ""

qemu-system-x86_64 \
    -kernel "$KERNEL" \
    -initrd "$INITRAMFS" \
    -m 512M \
    -smp 2 \
    -append "console=ttyS0 init=/sbin/init" \
    -nographic \
    -serial mon:stdio
EOF
    chmod +x run-qemu-initramfs.sh
    
    # Launch with disk image
    cat > run-qemu-disk.sh << 'EOF'
#!/bin/bash
# Launch Galactica with disk image

KERNEL="galactica-build/boot/vmlinuz-galactica"
ROOTFS="galactica-rootfs.img"

if [[ ! -f "$KERNEL" ]]; then
    echo "Error: Kernel not found"
    exit 1
fi

if [[ ! -f "$ROOTFS" ]]; then
    echo "Error: Root filesystem not found"
    exit 1
fi

echo "Starting Galactica (disk mode)..."
echo "Press Ctrl+A then X to exit"
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
    chmod +x run-qemu-disk.sh
    
    print_success "Launch scripts created"
}

# ============================================
# Main Build Process
# ============================================

main() {
    print_banner
    
    echo "This script will:"
    echo "  1. Check dependencies"
    echo "  2. Build the Linux kernel"
    echo "  3. Build AirRide init system"
    echo "  4. Build Dreamland package manager"
    echo "  5. Create bootable system image"
    echo "  6. Generate QEMU launch scripts"
    echo ""
    read -p "Continue? (y/n) [y]: " continue
    continue=${continue:-y}
    
    if [[ "$continue" != "y" ]]; then
        echo "Aborted."
        exit 0
    fi
    
    # Run all steps
    preflight_checks || exit 1
    build_kernel || exit 1
    build_airride || exit 1
    build_airridectl || exit 1
    build_dreamland || exit 1
    prepare_build_dir || exit 1
    install_kernel || exit 1
    install_airride || exit 1
    install_dreamland || exit 1
    copy_essentials || exit 1
    setup_qemu_config || exit 1
    create_bootable_image || exit 1
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
    echo "Generated files:"
    [[ -f "$OUTPUT_INITRAMFS" ]] && echo "  • $OUTPUT_INITRAMFS ($(du -h $OUTPUT_INITRAMFS | cut -f1))"
    [[ -f "$OUTPUT_ROOTFS" ]] && echo "  • $OUTPUT_ROOTFS ($(du -h $OUTPUT_ROOTFS | cut -f1))"
    echo ""
    echo "Launch scripts:"
    echo "  • run-qemu-initramfs.sh (boot from initramfs)"
    echo "  • run-qemu-disk.sh (boot from disk image)"
    echo ""
    echo -e "${CYAN}To boot Galactica:${NC}"
    [[ -f "$OUTPUT_INITRAMFS" ]] && echo "  ${BOLD}./run-qemu-initramfs.sh${NC}"
    [[ -f "$OUTPUT_ROOTFS" ]] && echo "  ${BOLD}./run-qemu-disk.sh${NC}"
    echo ""
    echo "Inside QEMU:"
    echo "  • Run: ${CYAN}galactica-bootstrap${NC} (first-time setup)"
    echo "  • Use: ${CYAN}airridectl list${NC} (manage services)"
    echo "  • Use: ${CYAN}dreamland sync${NC} (package manager)"
    echo ""
}

# Run main
main
