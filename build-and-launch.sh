#!/bin/bash
# Galactica Complete Build Script - Enhanced Networking + Service Autostart
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PINK='\033[38;5;213m'
BOLD='\033[1m'
NC='\033[0m'

TARGET_ROOT="./galactica-build"
KERNEL_DIR=""
AIRRIDE_DIR="./AirRide"
DREAMLAND_DIR="./Dreamland"
POYO_DIR="./Poyo"
OUTPUT_ROOTFS="galactica-rootfs.img"
ROOTFS_SIZE=4096
KERNEL_VERSION="6.18.4"
USE_PAM=false

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
EOF
    echo -e "${NC}"
    echo -e "${BOLD}=== Galactica Build v4.0 - Full Networking ===${NC}"
    echo ""
}

print_step() { echo -e "\n${BOLD}${BLUE}[STEP $1/$2]${NC} ${BOLD}$3${NC}\n${CYAN}$(printf '=%.0s' {1..60})${NC}\n"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_info() { echo -e "${CYAN}→${NC} $1"; }

preflight_checks() {
    print_step 0 11 "Pre-flight Checks"
    local all_ok=true
    
    for cmd in gcc g++ make bc flex bison dd mkfs.ext4; do
        command -v "$cmd" &>/dev/null || { print_error "$cmd not found"; all_ok=false; }
    done
    
    command -v busybox &>/dev/null && print_success "busybox found" || { print_warning "busybox not found"; all_ok=false; }
    command -v qemu-system-x86_64 &>/dev/null && print_success "QEMU found" || print_warning "QEMU not found"
    
    [[ "$all_ok" == "true" ]] && print_success "All dependencies satisfied" || { print_error "Missing dependencies"; return 1; }
}

build_kernel() {
    print_step 1 11 "Build Linux Kernel with Full Networking"
    
    local KERNEL_TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    local KERNEL_URL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${KERNEL_TARBALL}"
    local KERNEL_CACHE_DIR="./kernel-cache"
    
    if [[ -f "$TARGET_ROOT/boot/vmlinuz-galactica" ]] && [[ -f "$TARGET_ROOT/boot/.kernel-version" ]]; then
        if [[ "$(cat $TARGET_ROOT/boot/.kernel-version)" == "$KERNEL_VERSION" ]]; then
            print_success "Kernel $KERNEL_VERSION already built"
            read -p "Rebuild? (y/n) [n]: " rebuild
            [[ "$rebuild" != "y" ]] && return 0
        fi
    fi
    
    [[ -z "$KERNEL_DIR" ]] && KERNEL_DIR="./linux-${KERNEL_VERSION}"
    mkdir -p "$KERNEL_CACHE_DIR"
    
    if [[ ! -f "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" ]]; then
        print_info "Downloading kernel..."
        wget -O "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" "$KERNEL_URL" || curl -L -o "$KERNEL_CACHE_DIR/$KERNEL_TARBALL" "$KERNEL_URL"
    fi
    
    [[ ! -d "$KERNEL_DIR" ]] && tar -xf "$KERNEL_CACHE_DIR/$KERNEL_TARBALL"
    
    cd "$KERNEL_DIR"
    
    GCC_VERSION=$(gcc -dumpversion | cut -d. -f1)
    if [[ $GCC_VERSION -ge 13 ]]; then
        export KCFLAGS="-std=gnu11" HOSTCFLAGS="-std=gnu11" CC="gcc -std=gnu11" HOSTCC="gcc -std=gnu11"
    fi
    
    if [[ ! -f .config ]] || ! grep -q "CONFIG_VIRTIO_NET=y" .config; then
        print_info "Creating kernel config with full networking..."
        make mrproper 2>/dev/null || true
        make tinyconfig || make allnoconfig
        
        cat >> .config << 'EOF'
# Architecture
CONFIG_64BIT=y
CONFIG_X86_64=y
CONFIG_SMP=y
CONFIG_PCI=y
CONFIG_ACPI=y

# Core input
CONFIG_INPUT=y
CONFIG_INPUT_EVDEV=y
CONFIG_INPUT_FF_MEMLESS=y

# Keyboard
CONFIG_INPUT_KEYBOARD=y
CONFIG_KEYBOARD_ATKBD=y

# Mouse
CONFIG_INPUT_MOUSE=y
CONFIG_MOUSE_PS2=y
CONFIG_MOUSE_PS2_ALPS=y
CONFIG_MOUSE_PS2_SYNAPTICS=y
CONFIG_MOUSE_PS2_TRACKPOINT=y

# PS/2 controller (i8042) - CRITICAL for QEMU
CONFIG_SERIO=y
CONFIG_SERIO_I8042=y
CONFIG_SERIO_LIBPS2=y
CONFIG_SERIO_SERPORT=y

# USB HID (for USB keyboard/mouse)
CONFIG_USB_SUPPORT=y
CONFIG_USB=y
CONFIG_USB_HID=y
CONFIG_USB_HIDDEV=y
CONFIG_HID=y
CONFIG_HID_GENERIC=y
CONFIG_USB_XHCI_HCD=y
CONFIG_USB_EHCI_HCD=y
CONFIG_USB_OHCI_HCD=y
CONFIG_USB_UHCI_HCD=y

# Virtio input (for virtio-keyboard-pci, virtio-mouse-pci)
CONFIG_VIRTIO_INPUT=y
# Graphics/DRM support for QEMU
CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_GEM_SHMEM_HELPER=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DRM_BOCHS=y
CONFIG_DRM_QXL=y
CONFIG_DRM_SIMPLEDRM=y

# Framebuffer
CONFIG_FB=y
CONFIG_FB_VESA=y
CONFIG_FB_EFI=y
CONFIG_FB_SIMPLE=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y

# Input for X11
CONFIG_INPUT_EVDEV=y
CONFIG_INPUT_KEYBOARD=y
CONFIG_INPUT_MOUSE=y
CONFIG_INPUT_MISC=y
# Essential
CONFIG_BINFMT_ELF=y
CONFIG_BINFMT_SCRIPT=y
CONFIG_MMU=y
CONFIG_SLAB=y
CONFIG_MULTIUSER=y
CONFIG_SYSVIPC=y
CONFIG_POSIX_MQUEUE=y
CONFIG_FUTEX=y
CONFIG_EPOLL=y
CONFIG_SIGNALFD=y
CONFIG_EVENTFD=y
CONFIG_TIMERFD=y
CONFIG_FILE_LOCKING=y

# Filesystems
CONFIG_PROC_FS=y
CONFIG_SYSFS=y
CONFIG_TMPFS=y
CONFIG_DEVTMPFS=y
CONFIG_DEVTMPFS_MOUNT=y
CONFIG_EXT4_FS=y
CONFIG_EXT4_USE_FOR_EXT2=y

# Block/Storage
CONFIG_BLOCK=y
CONFIG_BLK_DEV=y
CONFIG_SCSI=y
CONFIG_BLK_DEV_SD=y

# VIRTIO (for QEMU)
CONFIG_VIRTIO_MENU=y
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_PCI_LEGACY=y
CONFIG_VIRTIO_BLK=y
CONFIG_SCSI_VIRTIO=y
CONFIG_VIRTIO_NET=y
CONFIG_VIRTIO_CONSOLE=y
CONFIG_VIRTIO_BALLOON=y
CONFIG_VIRTIO_INPUT=y
CONFIG_VIRTIO_MMIO=y

# Console/TTY
CONFIG_TTY=y
CONFIG_VT=y
CONFIG_VT_CONSOLE=y
CONFIG_UNIX98_PTYS=y
CONFIG_SERIAL_8250=y
CONFIG_SERIAL_8250_CONSOLE=y
CONFIG_SERIAL_CORE=y
CONFIG_SERIAL_CORE_CONSOLE=y
CONFIG_HW_CONSOLE=y
CONFIG_VGA_CONSOLE=y
CONFIG_DUMMY_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_PRINTK=y

# ============================================
# FULL NETWORKING STACK
# ============================================
CONFIG_NET=y
CONFIG_INET=y
CONFIG_IP_MULTICAST=y
CONFIG_IP_ADVANCED_ROUTER=y
CONFIG_IP_PNP=y
CONFIG_IP_PNP_DHCP=y
CONFIG_IP_PNP_BOOTP=y

# TCP/IP
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_CUBIC=y
CONFIG_DEFAULT_TCP_CONG="cubic"
CONFIG_IPV6=y

# Packet handling
CONFIG_PACKET=y
CONFIG_PACKET_DIAG=y
CONFIG_UNIX=y
CONFIG_UNIX_DIAG=y
CONFIG_XFRM=y
CONFIG_XFRM_USER=y

# Netfilter/Firewall (basic)
CONFIG_NETFILTER=y
CONFIG_NETFILTER_ADVANCED=y
CONFIG_NF_CONNTRACK=y
CONFIG_NF_TABLES=y
CONFIG_NFT_CT=y
CONFIG_NFT_COUNTER=y
CONFIG_NFT_LOG=y
CONFIG_NFT_NAT=y
CONFIG_NFT_MASQ=y
CONFIG_NF_NAT=y
CONFIG_IP_NF_IPTABLES=y
CONFIG_IP_NF_FILTER=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y

# DNS/Resolver
CONFIG_DNS_RESOLVER=y

# Network device support
CONFIG_NETDEVICES=y
CONFIG_NET_CORE=y
CONFIG_ETHERNET=y
CONFIG_NET_VENDOR_INTEL=y
CONFIG_E1000=y
CONFIG_E1000E=y
CONFIG_NET_VENDOR_REALTEK=y
CONFIG_8139CP=y
CONFIG_8139TOO=y
CONFIG_R8169=y

# Wireless (basic support)
CONFIG_WLAN=y
CONFIG_CFG80211=m
CONFIG_MAC80211=m

# TUN/TAP for VPNs
CONFIG_TUN=y
CONFIG_TAP=y

# Bridge support
CONFIG_BRIDGE=y
CONFIG_BRIDGE_NETFILTER=y

# VLAN
CONFIG_VLAN_8021Q=y

# Bonding
CONFIG_BONDING=y

# Loopback
CONFIG_DUMMY=y

# ============================================
# Additional useful features
# ============================================
CONFIG_MODULES=y
CONFIG_MODULE_UNLOAD=y
CONFIG_SYSCTL=y
CONFIG_KALLSYMS=y
CONFIG_BUG=y
CONFIG_NAMESPACES=y
CONFIG_NET_NS=y
CONFIG_USER_NS=y
CONFIG_PID_NS=y
CONFIG_CGROUPS=y
CONFIG_BLK_DEV_INITRD=y

# Security
CONFIG_SECURITY=y
CONFIG_SECURITYFS=y
CONFIG_HARDENED_USERCOPY=y
CONFIG_STACKPROTECTOR=y
CONFIG_STACKPROTECTOR_STRONG=y

# Crypto (for networking)
CONFIG_CRYPTO=y
CONFIG_CRYPTO_AEAD=y
CONFIG_CRYPTO_CBC=y
CONFIG_CRYPTO_ECB=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_AES=y
CONFIG_CRYPTO_AES_NI_INTEL=y
CONFIG_CRYPTO_CRC32C=y
CONFIG_CRYPTO_CRC32C_INTEL=y

# Random number generation
CONFIG_HW_RANDOM=y
CONFIG_HW_RANDOM_VIRTIO=y

# KVM guest support
CONFIG_HYPERVISOR_GUEST=y
CONFIG_PARAVIRT=y
CONFIG_KVM_GUEST=y

# Fonts for console
CONFIG_FONT_SUPPORT=y
CONFIG_FONTS=y
CONFIG_FONT_8x16=y
EOF
        
        make olddefconfig
    fi
    
    # Verify critical options
    for opt in CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_INET CONFIG_EXT4_FS; do
        grep -q "^${opt}=y" .config || { print_error "$opt NOT enabled!"; return 1; }
    done
    print_success "Kernel configured with full networking"
    
    if [[ ! -f arch/x86/boot/bzImage ]]; then
        print_info "Building kernel..."
        make -j$(nproc) 2>&1 | tee ../kernel-build.log
    fi
    
    [[ -f arch/x86/boot/bzImage ]] && print_success "Kernel built" || { print_error "Kernel build failed"; return 1; }
    cd ..
}

build_poyo() {
    print_step 2 11 "Build Poyo Getty/Login"
    cd "$POYO_DIR"
    gcc -Wall -Wextra -O2 -D_GNU_SOURCE -fstack-protector-strong -o poyo src/main.c -lcrypt || return 1
    print_success "Poyo built"
    cd ..
}

build_airride() {
    print_step 3 11 "Build AirRide Init"
    cd "$AIRRIDE_DIR/Init"
    mkdir -p build
    g++ -o build/airride src/main.cpp -Wall -Wextra -O2 -std=c++17 -fstack-protector-strong || return 1
    print_success "AirRide built"
    cd ../..
}

build_airridectl() {
    print_step 4 11 "Build AirRideCtl"
    cd "$AIRRIDE_DIR/Ctl"
    mkdir -p build
    g++ -o build/airridectl src/main.cpp -Wall -Wextra -O2 -std=c++17 || return 1
    print_success "AirRideCtl built"
    cd ../..
}

build_dreamland() {
    print_step 5 12 "Build Dreamland Package Manager + Modules"
    cd "$DREAMLAND_DIR"
    
    # Check for required libraries
    if ! pkg-config --exists libcurl libarchive 2>/dev/null; then
        print_warning "Some libraries missing, trying anyway..."
    fi
    
    mkdir -p build
    
    # Build main binary
    print_info "Building dreamland binary..."
    g++ -o build/dreamland src/main.cpp \
        -std=c++17 -O2 -Wall -Wextra -fPIC \
        -lcurl -lssl -lcrypto -lz -lzstd -larchive -lpthread -ldl \
        2>&1 || {
        print_error "Dreamland build failed"
        return 1
    }
    print_success "Dreamland binary built"
    
  
    
    print_success "Dreamland built"
    cd ..
}

prepare_build_dir() {
    print_step 6 11 "Prepare Root Filesystem"
    
    [[ -d "$TARGET_ROOT" ]] && { read -p "Clean build directory? (y/n) [y]: " clean; [[ "${clean:-y}" == "y" ]] && rm -rf "$TARGET_ROOT"; }
    
    mkdir -p "$TARGET_ROOT"/{bin,sbin,dev,etc/airride/services,proc,sys,run,tmp,var/{log,run},lib,lib64,usr/{bin,sbin,lib,lib64,share},home/user,root}
    chmod 1777 "$TARGET_ROOT/tmp"
    chmod 700 "$TARGET_ROOT/root"
    print_success "Directory structure created"
}

install_components() {
    print_step 7 11 "Install Components"
    
    [[ -z "$KERNEL_DIR" ]] && KERNEL_DIR=$(find . -maxdepth 1 -type d -name "linux-*" | head -1)
    
    mkdir -p "$TARGET_ROOT/boot"
    cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
    echo "$KERNEL_VERSION" > "$TARGET_ROOT/boot/.kernel-version"
    
    cp "$POYO_DIR/poyo" "$TARGET_ROOT/sbin/poyo" && chmod 755 "$TARGET_ROOT/sbin/poyo"
    cp "$AIRRIDE_DIR/Init/build/airride" "$TARGET_ROOT/sbin/airride" && chmod 755 "$TARGET_ROOT/sbin/airride"
    ln -sf airride "$TARGET_ROOT/sbin/init"
    cp "$AIRRIDE_DIR/Ctl/build/airridectl" "$TARGET_ROOT/usr/bin/airridectl" && chmod 755 "$TARGET_ROOT/usr/bin/airridectl"
    cp "$DREAMLAND_DIR/build/dreamland" "$TARGET_ROOT/usr/bin/dreamland" && chmod 755 "$TARGET_ROOT/usr/bin/dreamland"


    ln -sf dreamland "$TARGET_ROOT/usr/bin/dl"
    
    print_success "Components installed"
}

install_essentials() {
    print_step 8 11 "Install Busybox, Libraries, and Build Tools"
    
    cp /bin/busybox "$TARGET_ROOT/bin/" && chmod +x "$TARGET_ROOT/bin/busybox"
    
    cd "$TARGET_ROOT/bin"
    for cmd in sh ash ls cat echo pwd mkdir rm cp mv ln chmod chown grep sed awk ps kill sleep touch date mount umount ip ifconfig route ping hostname uname dmesg; do
        ln -sf busybox "$cmd" 2>/dev/null || true
    done
    cd - > /dev/null
    
    # Also add network tools to sbin
    cd "$TARGET_ROOT/sbin"
    for cmd in ifconfig route ip; do
        ln -sf ../bin/busybox "$cmd" 2>/dev/null || true
    done
    cd - > /dev/null
    
    print_info "Copying libraries..."
    
    copy_libs() {
        local binary=$1
        [[ ! -f "$binary" ]] && return
        ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
            [[ -f "$lib" && ! -f "$TARGET_ROOT$lib" ]] && { mkdir -p "$TARGET_ROOT$(dirname $lib)"; cp "$lib" "$TARGET_ROOT$lib" 2>/dev/null || true; }
        done
    }
    
    for binary in "$TARGET_ROOT/sbin/airride" "$TARGET_ROOT/sbin/poyo" "$TARGET_ROOT/usr/bin/airridectl" "$TARGET_ROOT/usr/bin/dreamland"; do
        copy_libs "$binary"
    done
    
    for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 libcrypt.so.1 libgcc_s.so.1 libstdc++.so.6 libresolv.so.2 libnss_dns.so.2 libnss_files.so.2; do
        LIBPATH=$(find /lib* /usr/lib* -name "$lib" 2>/dev/null | head -1)
        [[ -n "$LIBPATH" ]] && { mkdir -p "$TARGET_ROOT$(dirname $LIBPATH)"; cp "$LIBPATH" "$TARGET_ROOT$(dirname $LIBPATH)/" 2>/dev/null || true; }
    done
    
    for linker in ld-linux-x86-64.so.2 ld-linux.so.2; do
        LINKER=$(find /lib* -name "$linker" 2>/dev/null | head -1)
        [[ -n "$LINKER" ]] && { mkdir -p "$TARGET_ROOT$(dirname $LINKER)"; cp "$LINKER" "$TARGET_ROOT$(dirname $LINKER)/"; }
    done
    
    # Install static curl for HTTPS support (BusyBox wget is HTTP-only)
    print_info "Installing curl with SSL support..."
    CURL_URL="https://github.com/moparisthebest/static-curl/releases/download/v8.5.0/curl-amd64"
    if curl -sL -o "$TARGET_ROOT/usr/bin/curl" "$CURL_URL" 2>/dev/null || wget -qO "$TARGET_ROOT/usr/bin/curl" "$CURL_URL" 2>/dev/null; then
        chmod 755 "$TARGET_ROOT/usr/bin/curl"
        print_info "curl installed"
    else
        print_info "Warning: Could not download static curl"
    fi
    
    # Install CA certificates for SSL
    mkdir -p "$TARGET_ROOT/etc/ssl/certs"
    if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
        cp /etc/ssl/certs/ca-certificates.crt "$TARGET_ROOT/etc/ssl/certs/"
    elif [[ -f /etc/pki/tls/certs/ca-bundle.crt ]]; then
        cp /etc/pki/tls/certs/ca-bundle.crt "$TARGET_ROOT/etc/ssl/certs/ca-certificates.crt"
    else
        curl -sL -o "$TARGET_ROOT/etc/ssl/certs/ca-certificates.crt" "https://curl.se/ca/cacert.pem" 2>/dev/null || \
        wget -qO "$TARGET_ROOT/etc/ssl/certs/ca-certificates.awddadsasd
	crt" "https://curl.se/ca/cacert.pem" 2>/dev/null || true
    fi
    
    # ============================================
    # BOOTSTRAP BUILD TOOLCHAIN
    # ============================================
    print_info "Installing build toolchain (gcc, g++, make, cmake)..."
    
    # Copy GCC toolchain from host
    if command -v gcc &>/dev/null; then
        mkdir -p "$TARGET_ROOT/usr/bin"
        
        # Copy compilers
        for tool in gcc g++ cc c++ cpp as ld ar ranlib nm objdump objcopy strip; do
            TOOL_PATH=$(command -v $tool 2>/dev/null)
            if [[ -n "$TOOL_PATH" ]]; then
                cp "$TOOL_PATH" "$TARGET_ROOT/usr/bin/" 2>/dev/null || true
                # Copy libraries for this tool
                copy_libs "$TOOL_PATH"
            fi
        done
        
        # Copy make
        if command -v make &>/dev/null; then
            MAKE_PATH=$(command -v make)
            cp "$MAKE_PATH" "$TARGET_ROOT/usr/bin/"
            copy_libs "$MAKE_PATH"
        fi
        
        # Copy cmake with its data files
        if command -v cmake &>/dev/null; then
            CMAKE_PATH=$(command -v cmake)
            cp "$CMAKE_PATH" "$TARGET_ROOT/usr/bin/"
            copy_libs "$CMAKE_PATH"
            
            # Copy CMake's data files (modules, templates, etc.)
            CMAKE_VERSION=$(cmake --version 2>/dev/null | head -1 | grep -oP '\d+\.\d+' || echo "3")
            for cmake_dir in /usr/share/cmake-${CMAKE_VERSION}* /usr/share/cmake; do
                if [[ -d "$cmake_dir" ]]; then
                    mkdir -p "$TARGET_ROOT/usr/share"
                    BASENAME=$(basename "$cmake_dir")
                    if [[ ! -d "$TARGET_ROOT/usr/share/$BASENAME" ]]; then
                        cp -a "$cmake_dir" "$TARGET_ROOT/usr/share/" 2>/dev/null || true
                        print_info "Copied CMake data from $cmake_dir"
                    fi
                fi
            done
            
            # Create symlink if needed
            if [[ ! -d "$TARGET_ROOT/usr/share/cmake" ]] && [[ -d "$TARGET_ROOT/usr/share/cmake-"* ]]; then
                CMAKE_ACTUAL=$(ls -d "$TARGET_ROOT/usr/share/cmake-"* 2>/dev/null | head -1)
                if [[ -n "$CMAKE_ACTUAL" ]]; then
                    ln -sf "$(basename "$CMAKE_ACTUAL")" "$TARGET_ROOT/usr/share/cmake"
                fi
            fi
        fi
        
        # Copy pkg-config (needed by many build systems)
        if command -v pkg-config &>/dev/null; then
            PKG_CONFIG_PATH=$(command -v pkg-config)
            cp "$PKG_CONFIG_PATH" "$TARGET_ROOT/usr/bin/"
            copy_libs "$PKG_CONFIG_PATH"
            
            # Copy pkg-config data files
            for pc_dir in /usr/share/pkgconfig /usr/lib/pkgconfig /usr/lib64/pkgconfig /usr/local/lib/pkgconfig; do
                if [[ -d "$pc_dir" ]]; then
                    mkdir -p "$TARGET_ROOT$pc_dir"
                    cp -a "$pc_dir"/* "$TARGET_ROOT$pc_dir/" 2>/dev/null || true
                fi
            done
        fi
        
        # Copy other essential build tools
        for tool in autoconf automake libtool m4 patch sed diff find xargs; do
            TOOL_PATH=$(command -v $tool 2>/dev/null)
            if [[ -n "$TOOL_PATH" ]]; then
                cp "$TOOL_PATH" "$TARGET_ROOT/usr/bin/" 2>/dev/null || true
                copy_libs "$TOOL_PATH"
            fi
        done
        
        # Copy GCC support files and libraries
        GCC_VERSION=$(gcc -dumpversion 2>/dev/null | cut -d. -f1)
        if [[ -n "$GCC_VERSION" ]]; then
            # Copy GCC's internal libraries and specs
            for gcc_libdir in /usr/lib/gcc /usr/lib64/gcc /usr/libexec/gcc; do
                if [[ -d "$gcc_libdir" ]]; then
                    mkdir -p "$TARGET_ROOT$gcc_libdir"
                    cp -a "$gcc_libdir"/* "$TARGET_ROOT$gcc_libdir/" 2>/dev/null || true
                fi
            done
            
            # Copy ALL GCC-related libraries (including dependencies like libisl, libmpc, libmpfr, libgmp)
            print_info "Copying GCC runtime and dependency libraries..."
            for lib_pattern in libgcc_s.so* libstdc++.so* libgomp.so* libatomic.so* libitm.so* libquadmath.so* \
                              libisl.so* libmpc.so* libmpfr.so* libgmp.so* libz.so* libzstd.so*; do
                find /lib* /usr/lib* -name "$lib_pattern" 2>/dev/null | while read LIBPATH; do
                    if [[ -f "$LIBPATH" && ! -f "$TARGET_ROOT$LIBPATH" ]]; then
                        mkdir -p "$TARGET_ROOT$(dirname $LIBPATH)"
                        cp -L "$LIBPATH" "$TARGET_ROOT$LIBPATH" 2>/dev/null || true
                    fi
                done
            done
        fi
        
        # Copy system headers (needed for compilation)
        if [[ -d /usr/include ]]; then
            mkdir -p "$TARGET_ROOT/usr/include"
            print_info "Copying system headers (this may take a moment)..."
            # Copy all headers for proper compilation support
            cp -a /usr/include/* "$TARGET_ROOT/usr/include/" 2>/dev/null || true
        fi
        
        # Copy binutils
        if [[ -d /usr/bin ]]; then
            for tool in ld.bfd ld.gold gold; do
                if [[ -f "/usr/bin/$tool" ]]; then
                    cp "/usr/bin/$tool" "$TARGET_ROOT/usr/bin/" 2>/dev/null || true
                    copy_libs "/usr/bin/$tool"
                fi
            done
        fi
        
        print_success "Build toolchain installed"
    else
        print_warning "gcc not found on host - skipping toolchain installation"
        print_warning "You won't be able to compile packages in the VM"
    fi
    
    print_success "Essentials installed"
}


create_system_files() {
    print_step 9 11 "Create System Configuration"
    
    # Device nodes
    cd "$TARGET_ROOT/dev"
    sudo mknod -m 666 null c 1 3 2>/dev/null || true
    sudo mknod -m 666 zero c 1 5 2>/dev/null || true
    sudo mknod -m 666 random c 1 8 2>/dev/null || true
    sudo mknod -m 666 urandom c 1 9 2>/dev/null || true
    sudo mknod -m 600 console c 5 1 2>/dev/null || true
    sudo mknod -m 666 tty c 5 0 2>/dev/null || true
    
    # TTY devices with proper group ownership for X11
    for i in 0 1 2 3 4 5 6; do
        sudo mknod -m 660 "tty$i" c 4 "$i" 2>/dev/null || true
        sudo chown root:tty "tty$i" 2>/dev/null || true
    done
    
    sudo mknod -m 660 ttyS0 c 4 64 2>/dev/null || true
    sudo chown root:tty ttyS0 2>/dev/null || true
    
    # Framebuffer and DRI devices with proper permissions
    sudo mknod -m 666 fb0 c 29 0 2>/dev/null || true
    sudo mkdir -p dri
    sudo mknod -m 666 dri/card0 c 226 0 2>/dev/null || true
    sudo mknod -m 666 dri/renderD128 c 226 128 2>/dev/null || true
    sudo chown -R root:video dri 2>/dev/null || true
    
    # Input devices for X11
    sudo mkdir -p input
    for i in $(seq 0 10); do
        sudo mknod -m 660 "input/event$i" c 13 "$((64 + i))" 2>/dev/null || true
        sudo chown root:input "input/event$i" 2>/dev/null || true
    done
    sudo mknod -m 660 input/mice c 13 63 2>/dev/null || true
    sudo chown root:input input/mice 2>/dev/null || true
    
    cd - > /dev/null
    
    # ============================================
    # USER AND GROUP DATABASE WITH X11 GROUPS
    # ============================================
    cat > "$TARGET_ROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
    
    cat > "$TARGET_ROOT/etc/group" << 'EOF'
root:x:0:root
tty:x:5:root
video:x:44:root
input:x:104:root
audio:x:29:root
wheel:x:10:root
nogroup:x:65534:
EOF
    
    # Generate password hash for 'galactica'
    HASH=$(openssl passwd -6 -salt "galactica" "galactica")
    cat > "$TARGET_ROOT/etc/shadow" << EOF
root:${HASH}:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF
    chmod 600 "$TARGET_ROOT/etc/shadow"
    
    # ============================================
    # UDEV RULES FOR AUTOMATIC PERMISSIONS
    # ============================================
    mkdir -p "$TARGET_ROOT/etc/udev/rules.d"
    
    cat > "$TARGET_ROOT/etc/udev/rules.d/99-input.rules" << 'EOF'
# Input devices
KERNEL=="event*", NAME="input/%k", MODE="0660", GROUP="input"
KERNEL=="mice", NAME="input/%k", MODE="0660", GROUP="input"
KERNEL=="mouse*", NAME="input/%k", MODE="0660", GROUP="input"
SUBSYSTEM=="input", GROUP="input", MODE="0660"
EOF

    cat > "$TARGET_ROOT/etc/udev/rules.d/99-tty.rules" << 'EOF'
# TTY devices
KERNEL=="tty[0-9]*", GROUP="tty", MODE="0660"
KERNEL=="ttyS[0-9]*", GROUP="tty", MODE="0660"
EOF

    cat > "$TARGET_ROOT/etc/udev/rules.d/99-video.rules" << 'EOF'
# DRI/GPU devices
KERNEL=="card[0-9]*", MODE="0666", GROUP="video"
KERNEL=="renderD[0-9]*", MODE="0666", GROUP="video"
SUBSYSTEM=="drm", GROUP="video", MODE="0666"
EOF

    # ============================================
    # X11 DIRECTORY STRUCTURE AND PERMISSIONS
    # ============================================
    mkdir -p "$TARGET_ROOT/tmp/.X11-unix"
    chmod 1777 "$TARGET_ROOT/tmp/.X11-unix"
    sudo chown root:root "$TARGET_ROOT/tmp/.X11-unix" 2>/dev/null || true
    
    mkdir -p "$TARGET_ROOT/usr/lib/dri"
    chmod 755 "$TARGET_ROOT/usr/lib/dri"
    
    # ============================================
    # TMPFILES.D FOR X11 SOCKET DIRECTORY
    # ============================================
    mkdir -p "$TARGET_ROOT/etc/tmpfiles.d"
    cat > "$TARGET_ROOT/etc/tmpfiles.d/x11.conf" << 'EOF'
D /tmp/.X11-unix 1777 root root -
EOF

    # Hostname
    echo "galactica" > "$TARGET_ROOT/etc/hostname"
    
    cat > "$TARGET_ROOT/etc/hosts" << 'EOF'
127.0.0.1   localhost galactica
::1         localhost
EOF
    
    # DNS
    cat > "$TARGET_ROOT/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
    
    # NSS config
    cat > "$TARGET_ROOT/etc/nsswitch.conf" << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
EOF

    # ============================================
    # SUDOERS CONFIGURATION
    # ============================================
    mkdir -p "$TARGET_ROOT/etc/sudoers.d"
    cat > "$TARGET_ROOT/etc/sudoers" << 'EOF'
# Sudoers configuration for Galactica
Defaults env_reset
Defaults mail_badpass
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# Root can run anything
root ALL=(ALL:ALL) ALL

# Wheel group can run anything
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 440 "$TARGET_ROOT/etc/sudoers"
    
    # Allow wheel group to use sudo
    cat > "$TARGET_ROOT/etc/sudoers.d/wheel" << 'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 440 "$TARGET_ROOT/etc/sudoers.d/wheel"

    # ============================================
    # NETWORK SETUP SCRIPT
    # ============================================
    cat > "$TARGET_ROOT/sbin/network-setup" << 'EOFNET'
#!/bin/sh
# Galactica Network Setup - Robust version

LOG="/var/log/airride/network.log"
mkdir -p /var/log/airride /usr/share/udhcpc /run

log() {
    echo "[$(date '+%H:%M:%S')] $1" >> "$LOG" 2>&1
    echo "$1"
}

log "=== Network Setup ==="

# Create udhcpc script
cat > /usr/share/udhcpc/default.script << 'DHCPSCRIPT'
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface" 2>/dev/null
        ip link set "$interface" up
        ;;
    bound|renew)
        ip addr flush dev "$interface" 2>/dev/null
        case "$subnet" in
            255.255.255.0) PREFIX=24 ;;
            255.255.0.0)   PREFIX=16 ;;
            *)             PREFIX=24 ;;
        esac
        ip addr add "$ip/$PREFIX" dev "$interface"
        if [ -n "$router" ]; then
            while ip route del default 2>/dev/null; do :; done
            for gw in $router; do
                ip route add default via "$gw" dev "$interface"
                break
            done
        fi
        echo "# DHCP $(date)" > /etc/resolv.conf
        for ns in $dns 8.8.8.8; do
            echo "nameserver $ns" >> /etc/resolv.conf
        done
        ;;
esac
exit 0
DHCPSCRIPT
chmod +x /usr/share/udhcpc/default.script

# Loopback
ip link set lo up 2>/dev/null

# Find interface
IFACE=""
for i in eth0 ens3 enp0s3 enp0s2; do
    [ -e "/sys/class/net/$i" ] && { IFACE="$i"; break; }
done
[ -z "$IFACE" ] && { log "No interface found"; exit 1; }

log "Interface: $IFACE"
echo "$IFACE" > /run/network-interface

# Bring up
ip link set "$IFACE" up
sleep 1

# Try DHCP
DHCP_OK=0
if command -v udhcpc >/dev/null 2>&1; then
    killall udhcpc 2>/dev/null
    udhcpc -i "$IFACE" -s /usr/share/udhcpc/default.script -n -q -t 5 -T 3 >> "$LOG" 2>&1 && DHCP_OK=1
fi

# Fallback static
if [ "$DHCP_OK" = "0" ]; then
    log "DHCP failed, using static"
    ip addr flush dev "$IFACE" 2>/dev/null
    ip addr add 10.0.2.15/24 dev "$IFACE"
    while ip route del default 2>/dev/null; do :; done
    ip route add default via 10.0.2.2 dev "$IFACE"
    cat > /etc/resolv.conf << EOF
nameserver 10.0.2.3
nameserver 8.8.8.8
EOF
fi

# Log result
ip addr show "$IFACE" >> "$LOG" 2>&1
log "=== Done ==="
EOFNET
    chmod +x "$TARGET_ROOT/sbin/network-setup"

    # ============================================
    # INPUT/DEVICE PERMISSIONS SCRIPT
    # ============================================
    cat > "$TARGET_ROOT/sbin/fix-input-perms" << 'EOFPERMS'
#!/bin/sh
# Fix permissions for input devices and X11

# Create directories if they don't exist
mkdir -p /tmp/.X11-unix /dev/input /dev/dri

# ============================================
# X11 socket directory
# ============================================
chmod 1777 /tmp/.X11-unix 2>/dev/null
chown root:root /tmp/.X11-unix 2>/dev/null

# ============================================
# TTY devices - CRITICAL for X11 console access
# ============================================
# Individual TTY devices
for tty in /dev/tty[0-9]*; do
    [ -e "$tty" ] && chmod 660 "$tty" 2>/dev/null
    [ -e "$tty" ] && chown root:tty "$tty" 2>/dev/null
done

# Console master device
[ -e /dev/tty0 ] && chmod 660 /dev/tty0 2>/dev/null
[ -e /dev/tty0 ] && chown root:tty /dev/tty0 2>/dev/null

# General TTY device
[ -e /dev/tty ] && chmod 666 /dev/tty 2>/dev/null

# Serial consoles
for ttyS in /dev/ttyS[0-9]*; do
    [ -e "$ttyS" ] && chmod 660 "$ttyS" 2>/dev/null
    [ -e "$ttyS" ] && chown root:tty "$ttyS" 2>/dev/null
done

# Console device
[ -e /dev/console ] && chmod 600 /dev/console 2>/dev/null
[ -e /dev/console ] && chown root:root /dev/console 2>/dev/null

# ============================================
# DRI/GPU devices - for hardware acceleration
# ============================================
for dri in /dev/dri/card* /dev/dri/renderD*; do
    [ -e "$dri" ] && chmod 666 "$dri" 2>/dev/null
    [ -e "$dri" ] && chown root:video "$dri" 2>/dev/null
done

# ============================================
# Input devices - CRITICAL for keyboard/mouse in X11
# ============================================
# All event devices (keyboard, mouse, etc.)
for input in /dev/input/event*; do
    [ -e "$input" ] && chmod 660 "$input" 2>/dev/null
    [ -e "$input" ] && chown root:input "$input" 2>/dev/null
done

# Mice devices
for mice in /dev/input/mice /dev/input/mouse*; do
    [ -e "$mice" ] && chmod 660 "$mice" 2>/dev/null
    [ -e "$mice" ] && chown root:input "$mice" 2>/dev/null
done

# Legacy mouse devices
for mouse in /dev/mouse* /dev/psaux; do
    [ -e "$mouse" ] && chmod 660 "$mouse" 2>/dev/null
    [ -e "$mouse" ] && chown root:input "$mouse" 2>/dev/null
done

# ============================================
# Framebuffer devices - for display
# ============================================
for fb in /dev/fb*; do
    [ -e "$fb" ] && chmod 660 "$fb" 2>/dev/null
    [ -e "$fb" ] && chown root:video "$fb" 2>/dev/null
done

# ============================================
# Audio devices - bonus for sound support
# ============================================
for snd in /dev/snd/*; do
    [ -e "$snd" ] && chmod 660 "$snd" 2>/dev/null
    [ -e "$snd" ] && chown root:audio "$snd" 2>/dev/null
done

# ============================================
# Other useful devices
# ============================================
# Null and zero devices (should already be correct)
[ -e /dev/null ] && chmod 666 /dev/null 2>/dev/null
[ -e /dev/zero ] && chmod 666 /dev/zero 2>/dev/null
[ -e /dev/random ] && chmod 666 /dev/random 2>/dev/null
[ -e /dev/urandom ] && chmod 666 /dev/urandom 2>/dev/null

# PTY master
[ -e /dev/ptmx ] && chmod 666 /dev/ptmx 2>/dev/null

# ============================================
# Log what was fixed
# ============================================
echo "[$(date '+%H:%M:%S')] Device permissions fixed" >> /var/log/airride/perms.log 2>&1

exit 0
EOFPERMS
    chmod +x "$TARGET_ROOT/sbin/fix-input-perms"
sudo tee "$TARGET_ROOT/usr/bin/adduser" > /dev/null << 'EOFCREATEUSER'


#!/bin/sh
# adduser - Galactica user creation wrapper
# Creates users with proper groups, sudo access, and X11 support

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔════════════════════════════════════════╗
║     Galactica User Creation Tool      ║
╚════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_info() { echo -e "${CYAN}→${NC} $1"; }

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

print_banner

# Get username
if [ -n "$1" ]; then
    USERNAME="$1"
else
    echo -e "${BOLD}Enter username:${NC} "
    read -r USERNAME
fi

# Validate username
if [ -z "$USERNAME" ]; then
    print_error "Username cannot be empty"
    exit 1
fi

# Check if user already exists
if id "$USERNAME" >/dev/null 2>&1; then
    print_error "User '$USERNAME' already exists"
    exit 1
fi

# Check for invalid characters
if ! echo "$USERNAME" | grep -qE '^[a-z_][a-z0-9_-]*$'; then
    print_error "Invalid username. Use only lowercase letters, numbers, underscore, and dash"
    exit 1
fi

# Get password
echo ""
echo -e "${BOLD}Enter password for $USERNAME:${NC}"
read -rs PASSWORD1
echo ""
echo -e "${BOLD}Confirm password:${NC}"
read -rs PASSWORD2
echo ""

if [ "$PASSWORD1" != "$PASSWORD2" ]; then
    print_error "Passwords do not match"
    exit 1
fi

if [ -z "$PASSWORD1" ]; then
    print_error "Password cannot be empty"
    exit 1
fi

# Get full name (optional)
echo -e "${BOLD}Enter full name (optional):${NC} "
read -r FULLNAME

# Ask if user should have sudo access
echo -e "${BOLD}Grant sudo access? [Y/n]:${NC} "
read -r SUDO_ACCESS
SUDO_ACCESS=${SUDO_ACCESS:-y}

echo ""
print_info "Creating user '$USERNAME'..."

# ============================================
# Create user in /etc/passwd
# ============================================

# Find next available UID (starting from 1000)
NEXT_UID=1000
while grep -q ":$NEXT_UID:" /etc/passwd; do
    NEXT_UID=$((NEXT_UID + 1))
done

# Add user to passwd
if [ -n "$FULLNAME" ]; then
    echo "$USERNAME:x:$NEXT_UID:$NEXT_UID:$FULLNAME:/home/$USERNAME:/bin/sh" >> /etc/passwd
else
    echo "$USERNAME:x:$NEXT_UID:$NEXT_UID::/home/$USERNAME:/bin/sh" >> /etc/passwd
fi

print_success "User entry created (UID: $NEXT_UID)"

# ============================================
# Create user's primary group
# ============================================

# Check if group already exists
if ! grep -q "^$USERNAME:" /etc/group; then
    echo "$USERNAME:x:$NEXT_UID:" >> /etc/group
    print_success "Primary group created (GID: $NEXT_UID)"
else
    print_info "Group '$USERNAME' already exists"
fi

# ============================================
# Add user to system groups
# ============================================

SYSTEM_GROUPS="wheel video audio input tty storage"

print_info "Adding to system groups..."

for group in $SYSTEM_GROUPS; do
    # Check if group exists
    if ! grep -q "^${group}:" /etc/group; then
        print_warning "Group '$group' does not exist, skipping"
        continue
    fi
    
    # Add user to group
    if grep -q "^${group}:x:[0-9]*:$" /etc/group; then
        # Group exists but has no members
        sed -i "s/^${group}:x:\([0-9]*\):$/${group}:x:\1:${USERNAME}/" /etc/group
    elif grep -q "^${group}:x:[0-9]*:.*$" /etc/group; then
        # Group exists and has members
        sed -i "s/^${group}:x:\([0-9]*\):\(.*\)$/${group}:x:\1:\2,${USERNAME}/" /etc/group
    fi
    
    print_success "Added to group: $group"
done

# ============================================
# Set password
# ============================================

print_info "Setting password..."

# Generate password hash
HASH=$(openssl passwd -6 -salt "$USERNAME" "$PASSWORD1")

# Add to shadow file
echo "$USERNAME:${HASH}:$(( $(date +%s) / 86400 )):0:99999:7:::" >> /etc/shadow
chmod 600 /etc/shadow

print_success "Password set"

# ============================================
# Configure sudo access
# ============================================

if [ "$SUDO_ACCESS" = "y" ] || [ "$SUDO_ACCESS" = "Y" ]; then
    print_info "Configuring sudo access..."
    
    # Verify wheel group configuration in sudoers
    if [ -f /etc/sudoers ]; then
        if ! grep -q "^%wheel ALL=(ALL:ALL) ALL" /etc/sudoers; then
            print_warning "Wheel group not configured in sudoers"
            print_info "Adding wheel group to sudoers..."
            
            # Backup sudoers
            cp /etc/sudoers /etc/sudoers.bak
            
            # Add wheel group
            echo "" >> /etc/sudoers
            echo "# Allow wheel group to use sudo" >> /etc/sudoers
            echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers
            
            chmod 440 /etc/sudoers
        fi
        
        print_success "Sudo access granted (via wheel group)"
    else
        print_warning "sudoers file not found, sudo may not be installed"
    fi
fi

# ============================================
# Create home directory
# ============================================

print_info "Creating home directory..."

mkdir -p "/home/$USERNAME"
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"
chmod 755 "/home/$USERNAME"

# Create basic home directory structure
mkdir -p "/home/$USERNAME"/{.config,.local/share,.cache,Documents,Downloads,Desktop}
chown -R "$USERNAME:$USERNAME" "/home/$USERNAME"

print_success "Home directory created"

# ============================================
# Create .xinitrc for X11
# ============================================

print_info "Creating X11 configuration..."

cat > "/home/$USERNAME/.xinitrc" << 'EOFXINITRC'
#!/bin/sh
sleep 2
export DISPLAY=:0

# Set background color
xsetroot -solid "#1e1e2e" 2>/dev/null &

# Start window manager if available
if command -v twm >/dev/null 2>&1; then
    twm &
elif command -v i3 >/dev/null 2>&1; then
    exec i3
elif command -v openbox >/dev/null 2>&1; then
    exec openbox-session
fi

# Start terminal
if command -v xterm >/dev/null 2>&1; then
    exec xterm -display :0 -bg black -fg white -geometry 100x30
elif command -v urxvt >/dev/null 2>&1; then
    exec urxvt
else
    # No terminal, just keep X running
    sleep 3600
fi
EOFXINITRC

chmod +x "/home/$USERNAME/.xinitrc"
chown "$USERNAME:$USERNAME" "/home/$USERNAME/.xinitrc"

print_success "X11 configuration created"

# ============================================
# Create .bashrc
# ============================================

cat > "/home/$USERNAME/.bashrc" << 'EOFBASHRC'
# .bashrc

# If not running interactively, don't do anything
[[ $- != *i* ]] && return

# Aliases
alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -lah'
alias grep='grep --color=auto'

# Prompt
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# History
HISTSIZE=1000
HISTFILESIZE=2000

# Environment
export EDITOR=vi
export VISUAL=vi
export PAGER=less

# Add user bin to PATH if it exists
if [ -d "$HOME/.local/bin" ]; then
    export PATH="$HOME/.local/bin:$PATH"
fi

# Welcome message
echo "Welcome to Galactica Linux!"
echo "Type 'startgui' to start X11"
EOFBASHRC

chown "$USERNAME:$USERNAME" "/home/$USERNAME/.bashrc"
print_success "Shell configuration created"

# ============================================
# Create .profile
# ============================================

cat > "/home/$USERNAME/.profile" << 'EOFPROFILE'
# .profile

# Add user's private bin to PATH
if [ -d "$HOME/.local/bin" ] ; then
    PATH="$HOME/.local/bin:$PATH"
fi

# Source .bashrc if it exists
if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
EOFPROFILE

chown "$USERNAME:$USERNAME" "/home/$USERNAME/.profile"
print_success "Profile configuration created"

# ============================================
# Summary
# ============================================

echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   User Created Successfully! 🎉        ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}${BOLD}User Details:${NC}"
echo -e "  Username:     ${YELLOW}$USERNAME${NC}"
echo -e "  UID/GID:      ${YELLOW}$NEXT_UID${NC}"
echo -e "  Home:         ${YELLOW}/home/$USERNAME${NC}"
echo -e "  Shell:        ${YELLOW}/bin/sh${NC}"
echo ""
echo -e "${CYAN}${BOLD}Groups:${NC}"
echo -e "  Primary:      ${YELLOW}$USERNAME${NC}"
echo -e "  Additional:   ${YELLOW}$SYSTEM_GROUPS${NC}"
echo ""
echo -e "${CYAN}${BOLD}Capabilities:${NC}"
if [ "$SUDO_ACCESS" = "y" ] || [ "$SUDO_ACCESS" = "Y" ]; then
    echo -e "  ${GREEN}✓${NC} Sudo access (via wheel group)"
else
    echo -e "  ${YELLOW}✗${NC} No sudo access"
fi
echo -e "  ${GREEN}✓${NC} X11 support"
echo -e "  ${GREEN}✓${NC} Audio/video access"
echo -e "  ${GREEN}✓${NC} Storage access"
echo ""
echo -e "${CYAN}${BOLD}Next Steps:${NC}"
echo -e "  1. Login as ${YELLOW}$USERNAME${NC}"
echo -e "  2. Run ${YELLOW}startgui${NC} to start X11"
echo -e "  3. Install packages with ${YELLOW}dreamland install <package>${NC}"
echo ""
echo -e "${YELLOW}Note:${NC} User must log out and back in for group changes to take effect"
echo ""


EOFCREATEUSER

sudo chmod 755 "$TARGET_ROOT/usr/bin/adduser"

cat > "$TARGET_ROOT/sbin/setup-xorg" << 'EOFSETUPXORG'

#!/bin/sh
# setup-xorg - Automated X11 setup for Galactica Linux
# This script installs and configures X11 with proper permissions

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

print_banner() {
    echo -e "${CYAN}${BOLD}"
    cat << 'EOF'
╔══════════════════════════════════════════════╗
║      Galactica X11 Setup Script              ║
║      Installing X.Org Server & Dependencies  ║
╚══════════════════════════════════════════════╝
EOF
    echo -e "${NC}"
}

print_step() {
    echo -e "\n${BOLD}${BLUE}[STEP $1]${NC} ${BOLD}$2${NC}"
    echo -e "${CYAN}$(printf '=%.0s' {1..50})${NC}"
}

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_info() { echo -e "${CYAN}→${NC} $1"; }

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root"
    exit 1
fi

print_banner

# ============================================
# STEP 1: Check package manager
# ============================================
print_step 1 "Checking package manager"
if ! command -v dreamland >/dev/null 2>&1; then
    print_error "dreamland package manager not found!"
    exit 1
fi
print_success "dreamland found"

# Update package database
print_info "Updating package database..."
dreamland sync || print_warning "Failed to sync package database (continuing anyway)"

# ============================================
# STEP 2: Install required packages
# ============================================
print_step 2 "Installing X11 packages"

PACKAGES="xorg-server xorg-xinit util-linux xf86-input-evdev"
OPTIONAL_PACKAGES="xterm twm xorg-xsetroot"

print_info "Required packages: $PACKAGES"
print_info "Optional packages: $OPTIONAL_PACKAGES"
echo ""

for pkg in $PACKAGES; do
    print_info "Installing $pkg..."
    if dreamland install "$pkg" 2>&1 | grep -q "installed\|already"; then
        print_success "$pkg installed"
    else
        print_error "Failed to install $pkg"
        exit 1
    fi
done

print_info "Installing optional packages..."
for pkg in $OPTIONAL_PACKAGES; do
    if dreamland install "$pkg" 2>&1 | grep -q "installed\|already"; then
        print_success "$pkg installed"
    else
        print_warning "$pkg installation failed (optional)"
    fi
done

# ============================================
# STEP 3: Create permission fix script
# ============================================
print_step 3 "Creating device permission script"

cat > /sbin/fix-input-perms << 'EOFPERMS'
#!/bin/sh
# Fix permissions for input devices and X11

# Create directories if they don't exist
mkdir -p /tmp/.X11-unix /dev/input /dev/dri

# X11 socket directory
chmod 1777 /tmp/.X11-unix 2>/dev/null
chown root:root /tmp/.X11-unix 2>/dev/null

# TTY devices - CRITICAL for X11 console access
for tty in /dev/tty[0-9]*; do
    [ -e "$tty" ] && chmod 660 "$tty" 2>/dev/null
    [ -e "$tty" ] && chown root:tty "$tty" 2>/dev/null
done

# Console master device
[ -e /dev/tty0 ] && chmod 660 /dev/tty0 2>/dev/null
[ -e /dev/tty0 ] && chown root:tty /dev/tty0 2>/dev/null

# General TTY device
[ -e /dev/tty ] && chmod 666 /dev/tty 2>/dev/null

# Serial consoles
for ttyS in /dev/ttyS[0-9]*; do
    [ -e "$ttyS" ] && chmod 660 "$ttyS" 2>/dev/null
    [ -e "$ttyS" ] && chown root:tty "$ttyS" 2>/dev/null
done

# Console device
[ -e /dev/console ] && chmod 600 /dev/console 2>/dev/null
[ -e /dev/console ] && chown root:root /dev/console 2>/dev/null

# DRI/GPU devices - for hardware acceleration
for dri in /dev/dri/card* /dev/dri/renderD*; do
    [ -e "$dri" ] && chmod 666 "$dri" 2>/dev/null
    [ -e "$dri" ] && chown root:video "$dri" 2>/dev/null
done

# Input devices - CRITICAL for keyboard/mouse in X11
for input in /dev/input/event*; do
    [ -e "$input" ] && chmod 660 "$input" 2>/dev/null
    [ -e "$input" ] && chown root:input "$input" 2>/dev/null
done

# Mice devices
for mice in /dev/input/mice /dev/input/mouse*; do
    [ -e "$mice" ] && chmod 660 "$mice" 2>/dev/null
    [ -e "$mice" ] && chown root:input "$mice" 2>/dev/null
done

# Framebuffer devices - for display
for fb in /dev/fb*; do
    [ -e "$fb" ] && chmod 660 "$fb" 2>/dev/null
    [ -e "$fb" ] && chown root:video "$fb" 2>/dev/null
done

# Audio devices
for snd in /dev/snd/*; do
    [ -e "$snd" ] && chmod 660 "$snd" 2>/dev/null
    [ -e "$snd" ] && chown root:audio "$snd" 2>/dev/null
done

# Other useful devices
[ -e /dev/null ] && chmod 666 /dev/null 2>/dev/null
[ -e /dev/zero ] && chmod 666 /dev/zero 2>/dev/null
[ -e /dev/random ] && chmod 666 /dev/random 2>/dev/null
[ -e /dev/urandom ] && chmod 666 /dev/urandom 2>/dev/null
[ -e /dev/ptmx ] && chmod 666 /dev/ptmx 2>/dev/null

exit 0
EOFPERMS

chmod +x /sbin/fix-input-perms
print_success "Permission fix script created at /sbin/fix-input-perms"

# ============================================
# STEP 4: Create X11 configuration
# ============================================
print_step 4 "Creating X11 configuration"

mkdir -p /etc/X11

cat > /etc/X11/xorg.conf << 'EOFXORG'
Section "ServerFlags"
    Option "AutoAddDevices" "False"
    Option "AllowEmptyInput" "False"
    Option "AllowMouseOpenFail" "True"
    Option "DontVTSwitch" "True"
EndSection

Section "InputDevice"
    Identifier "Keyboard"
    Driver "evdev"
    Option "Device" "/dev/input/event1"
    Option "XkbLayout" "us"
EndSection

Section "InputDevice"
    Identifier "Keyboard2"
    Driver "evdev"
    Option "Device" "/dev/input/event4"
    Option "XkbLayout" "us"
EndSection

Section "InputDevice"
    Identifier "Mouse"  
    Driver "evdev"
    Option "Device" "/dev/input/event3"
EndSection

Section "Device"
    Identifier "Card0"
    Driver "modesetting"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Card0"
EndSection

Section "ServerLayout"
    Identifier "Default"
    Screen "Screen0"
    InputDevice "Keyboard" "CoreKeyboard"
    InputDevice "Keyboard2" "SendCoreEvents"
    InputDevice "Mouse" "CorePointer"
EndSection
EOFXORG

print_success "X11 configuration created at /etc/X11/xorg.conf"

# ============================================
# STEP 5: Create startgui script
# ============================================
print_step 5 "Creating startgui launcher"

cat > /usr/bin/startgui << 'EOFSTARTGUI'
#!/bin/sh
hostname galactica 2>/dev/null

# Only try to fix permissions if we're root
if [ "$(id -u)" = "0" ]; then
    mkdir -p /tmp/.X11-unix
    chmod 1777 /tmp/.X11-unix
    chown root:root /tmp/.X11-unix 2>/dev/null
    
    chmod 660 /dev/tty* 2>/dev/null
    chown root:tty /dev/tty* 2>/dev/null
    chmod 666 /dev/dri/* 2>/dev/null
    chmod 660 /dev/input/* 2>/dev/null
    chown root:input /dev/input/* 2>/dev/null
fi

# Set up environment
export HOME="${HOME:-$(eval echo ~$(whoami))}"
export XAUTHORITY="$HOME/.Xauthority"
rm -f "$XAUTHORITY" 2>/dev/null
touch "$XAUTHORITY"
cd "$HOME"

# Get current VT number
VT=$(tty | sed 's|/dev/tty||')

# Start X on current VT without switching
exec startx "$HOME/.xinitrc" -- vt${VT} -keeptty -novtswitch 2>&1
EOFSTARTGUI

chmod +x /usr/bin/startgui
print_success "startgui script created at /usr/bin/startgui"

# ============================================
# STEP 6: Setup groups and permissions
# ============================================
print_step 6 "Configuring groups"

# Ensure required groups exist
for group_line in "tty:x:5:" "video:x:44:" "input:x:104:" "audio:x:29:" "wheel:x:10:"; do
    group_name=$(echo "$group_line" | cut -d: -f1)
    if ! grep -q "^${group_name}:" /etc/group; then
        echo "$group_line" >> /etc/group
        print_success "Created group: $group_name"
    else
        print_info "Group already exists: $group_name"
    fi
done

# ============================================
# STEP 7: Setup AirRide service
# ============================================
print_step 7 "Creating AirRide service for input permissions"

if [ -d /etc/airride/services ]; then
    cat > /etc/airride/services/input-perms.service << 'EOFSERVICE'
[Service]
name=input-perms
description=Set Input Device Permissions for X11
type=oneshot
exec_start=/sbin/fix-input-perms
autostart=true
parallel=true

[Dependencies]
after=hostname
EOFSERVICE
    print_success "AirRide service created"
else
    print_warning "AirRide service directory not found, skipping service creation"
fi

# ============================================
# STEP 8: Run permission fixes now
# ============================================
print_step 8 "Applying permissions"

/sbin/fix-input-perms
print_success "Permissions applied"

# ============================================
# STEP 9: Setup example .xinitrc for root
# ============================================
print_step 9 "Creating example .xinitrc"

if [ ! -f /root/.xinitrc ]; then
    cat > /root/.xinitrc << 'EOFXINITRC'
#!/bin/sh
sleep 2
export DISPLAY=:0

# Set background color
xsetroot -solid "#1e1e2e" 2>/dev/null &

# Start window manager if available
if command -v twm >/dev/null 2>&1; then
    twm &
fi

# Start terminal
if command -v xterm >/dev/null 2>&1; then
    exec xterm -display :0 -bg black -fg white -geometry 80x24
else
    # Fallback - keep X running
    sleep 3600
fi
EOFXINITRC
    chmod +x /root/.xinitrc
    print_success "Example .xinitrc created for root"
else
    print_info ".xinitrc already exists for root"
fi

# ============================================
# FINAL SUMMARY
# ============================================
echo ""
echo -e "${GREEN}${BOLD}╔════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║   X11 Setup Complete! 🎉                  ║${NC}"
echo -e "${GREEN}${BOLD}╚════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${CYAN}${BOLD}Usage:${NC}"
echo -e "  ${YELLOW}startgui${NC}               - Start X11 GUI"
echo ""
echo -e "${CYAN}${BOLD}For non-root users:${NC}"
echo -e "  1. Create user and add to required groups:"
echo -e "     ${YELLOW}usermod -aG wheel,video,input,audio,tty username${NC}"
echo -e "  2. Create ${YELLOW}~/.xinitrc${NC} for the user"
echo -e "  3. User must ${BOLD}log out and back in${NC} for groups to take effect"
echo ""
echo -e "${CYAN}${BOLD}Installed packages:${NC}"
for pkg in $PACKAGES $OPTIONAL_PACKAGES; do
    echo -e "  • $pkg"
done
echo ""
echo -e "${CYAN}${BOLD}Configuration files created:${NC}"
echo -e "  • /etc/X11/xorg.conf"
echo -e "  • /usr/bin/startgui"
echo -e "  • /sbin/fix-input-perms"
echo -e "  • /etc/airride/services/input-perms.service"
echo -e "  • /root/.xinitrc"
echo ""
echo -e "${GREEN}Try running: ${YELLOW}startgui${NC}"
echo ""
EOFSETUPXORG

    # ============================================
    # NETWORK WATCHDOG
    # ============================================
    cat > "$TARGET_ROOT/sbin/network-watchdog" << 'EOFWATCH'
#!/bin/sh
# Network watchdog - auto-recovers broken network
INTERVAL=30
FAILURES=0

while true; do
    sleep "$INTERVAL"
    
    if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
        FAILURES=$((FAILURES + 1))
        if [ "$FAILURES" -ge 2 ]; then
            /sbin/network-setup >/dev/null 2>&1
            FAILURES=0
        fi
    else
        FAILURES=0
    fi
done
EOFWATCH
    chmod +x "$TARGET_ROOT/sbin/network-watchdog"

    # ============================================
    # AIRRIDE SERVICES
    # ============================================
    
    # Hostname service (runs first)
    cat > "$TARGET_ROOT/etc/airride/services/hostname.service" << 'EOF'
[Service]
name=hostname
description=Set System Hostname
type=oneshot
exec_start=/bin/hostname galactica
autostart=true
parallel=true

[Dependencies]
EOF

    # Input/Device permissions service (for X11)
    cat > "$TARGET_ROOT/etc/airride/services/input-perms.service" << 'EOF'
[Service]
name=input-perms
description=Set Input Device Permissions
type=oneshot
exec_start=/sbin/fix-input-perms
autostart=true
parallel=true

[Dependencies]
after=hostname
EOF

    # Network setup service
    cat > "$TARGET_ROOT/etc/airride/services/network.service" << 'EOF'
[Service]
name=network
description=Network Configuration
type=oneshot
exec_start=/sbin/network-setup
autostart=true
parallel=true

[Dependencies]
after=hostname,input-perms
EOF

    # Network watchdog service
    cat > "$TARGET_ROOT/etc/airride/services/network-watchdog.service" << 'EOF'
[Service]
name=network-watchdog
description=Network Connectivity Watchdog
type=simple
exec_start=/sbin/network-watchdog
autostart=true
parallel=true
restart=always
restart_delay=10

[Dependencies]
after=network
EOF

    # Serial console login (ttyS0)
    cat > "$TARGET_ROOT/etc/airride/services/ttyS0.service" << 'EOF'
[Service]
name=ttyS0
description=Serial Console Login
type=simple
exec_start=/sbin/poyo /dev/ttyS0
tty=/dev/ttyS0
autostart=true
restart=always
restart_delay=2
foreground=true

[Dependencies]
after=network
EOF

    # Virtual console 1 login (tty1) - for GUI mode
    cat > "$TARGET_ROOT/etc/airride/services/tty1.service" << 'EOF'
[Service]
name=tty1
description=Virtual Console 1 Login
type=simple
exec_start=/sbin/poyo /dev/tty1
tty=/dev/tty1
autostart=true
restart=always
restart_delay=2
foreground=true

[Dependencies]
after=network
EOF

    # ============================================
    # POWER MANAGEMENT SCRIPTS
    # ============================================
    cat > "$TARGET_ROOT/sbin/poweroff" << 'EOF'
#!/bin/sh
echo "Syncing disks..."
sync
sync
echo "Sending ACPI shutdown..."
# Try ACPI shutdown first
if [ -w /sys/power/state ]; then
    echo poweroff > /sys/power/state 2>/dev/null
fi
# Force kernel to sync and power off
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null  # sync
echo o > /proc/sysrq-trigger 2>/dev/null  # poweroff
# If still running, use reboot syscall
sleep 1
reboot -f -p 2>/dev/null || busybox poweroff -f
EOF

    cat > "$TARGET_ROOT/sbin/halt" << 'EOF'
#!/bin/sh
exec /sbin/poweroff "$@"
EOF

    cat > "$TARGET_ROOT/sbin/reboot" << 'EOF'
#!/bin/sh
echo "Syncing disks..."
sync
sync
echo "Rebooting..."
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo b > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox reboot -f
EOF

    cat > "$TARGET_ROOT/sbin/shutdown" << 'EOF'
#!/bin/sh
case "$1" in
    -r) exec /sbin/reboot ;;
    -h|-P|*) exec /sbin/poweroff ;;
esac
EOF

    chmod 755 "$TARGET_ROOT/sbin/poweroff" "$TARGET_ROOT/sbin/halt" "$TARGET_ROOT/sbin/reboot" "$TARGET_ROOT/sbin/shutdown"

    # ============================================
    # GUI SUPPORT WITH PROPER X11 CONFIG
    # ============================================
    mkdir -p "$TARGET_ROOT/etc/X11/xorg.conf.d"
    
    cat > "$TARGET_ROOT/etc/X11/xorg.conf" << 'EOF'
Section "ServerFlags"
    Option "AutoAddDevices" "True"
    Option "AutoEnableDevices" "True"
    Option "DontVTSwitch" "False"
    Option "AllowMouseOpenFail" "True"
EndSection

Section "InputClass"
    Identifier "evdev keyboard catchall"
    MatchIsKeyboard "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
    Option "XkbLayout" "us"
EndSection

Section "InputClass"
    Identifier "evdev mouse catchall"
    MatchIsPointer "on"
    MatchDevicePath "/dev/input/event*"
    Driver "evdev"
EndSection

Section "Device"
    Identifier "GPU"
    Driver "modesetting"
    Option "AccelMethod" "glamor"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "GPU"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1024x768" "800x600"
    EndSubSection
EndSection
EOF

    cat > "$TARGET_ROOT/usr/bin/startgui" << 'EOF'
#!/bin/sh
hostname galactica 2>/dev/null

# Ensure proper permissions for X11
mkdir -p /tmp/.X11-unix
chmod 1777 /tmp/.X11-unix
chown root:root /tmp/.X11-unix 2>/dev/null

# Fix TTY permissions if running as root
if [ "$(id -u)" = "0" ]; then
    chmod 660 /dev/tty* 2>/dev/null
    chown root:tty /dev/tty* 2>/dev/null
    chmod 666 /dev/dri/* 2>/dev/null
    chmod 660 /dev/input/* 2>/dev/null
    chown root:input /dev/input/* 2>/dev/null
fi

export DISPLAY=:0
export HOME="${HOME:-/root}"
export XAUTHORITY="$HOME/.Xauthority"
touch "$XAUTHORITY"
cd "$HOME"

# Start X with proper options
exec startx "$HOME/.xinitrc" -- -keeptty -nolisten tcp 2>&1
EOF
    chmod +x "$TARGET_ROOT/usr/bin/startgui"

    cat > "$TARGET_ROOT/root/.xinitrc" << 'EOF'
#!/bin/sh
# Basic X11 session
xsetroot -solid "#1e1e2e" 2>/dev/null &
[ -x /usr/bin/twm ] && twm &
exec xterm -bg black -fg white -fa 'Monospace' -fs 10 -geometry 100x30
EOF
    chmod +x "$TARGET_ROOT/root/.xinitrc"

    # ============================================
    # MOTD
    # ============================================
    cat > "$TARGET_ROOT/etc/motd" << 'EOF'
Welcome to Galactica Linux!

Commands:
  startgui          - Start X11 GUI (in QEMU GUI mode)
  network-setup     - Reconfigure network
  airridectl list   - List services
  dreamland sync    - Sync packages

Network: DHCP auto-configured on boot
Default password: galactica

EOF
    
    print_success "System files created with proper X11 permissions"
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
}

create_launch_scripts() {
    print_step 11 11 "Create Launch Scripts"
    
    cat > run-galactica.sh << 'EOFSCRIPT'


#!/usr/bin/env bash
# galactica-boot.sh — simple, opinionated QEMU launcher
# Author: your friendly VM whisperer
set -euo pipefail
# === Config (edit if you must) ===
KERNEL="${KERNEL:-galactica-build/boot/vmlinuz-galactica}"
ROOTFS="${ROOTFS:-galactica-rootfs.img}"
MEM="${MEM:-512M}"
CPUS="${CPUS:-2}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"   # host port forwarded to guest 22
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"
# === sanity checks ===
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
    echo "Error: qemu binary '$QEMU_BIN' not found in PATH." >&2
    exit 2
fi
[[ -f "$KERNEL" ]] || { echo "Error: Kernel not found at: $KERNEL" >&2; exit 3; }
[[ -f "$ROOTFS" ]] || { echo "Error: Rootfs not found at: $ROOTFS" >&2; exit 4; }
cat <<'EOF'
=== Galactica Boot Menu ===
  1) GUI window (GTK) + virtio GPU
  2) VNC server (:1) + QXL (connect with vncviewer localhost:5901)
  3) SPICE (recommended with virtio/ qxl clients)
  4) Headless serial (current behavior; console on terminal)
  5) Debug mode (verbose kernel log on serial)
  6) Emergency shell (init=/bin/sh)
EOF
read -r -p "Select (1-6) [1]: " mode
mode="${mode:-1}"
# Base qemu args common across modes
QEMU_ARGS=(
    -kernel "$KERNEL"
    -drive "file=$ROOTFS,format=raw,if=virtio"
    -m "$MEM"
    -smp "$CPUS"
    -serial "mon:stdio"
    -enable-kvm
)
# Networking (user-mode with SSH host forward)
NET_ARGS=(-netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22" -device virtio-net-pci,netdev=net0)
# Kernel append parameters common
COMMON_APPEND="root=/dev/vda rw console=ttyS0"
case "$mode" in
  1)  # GUI window using GTK and virtio-vga
        echo "Starting GUI (GTK) with virtio-vga..."
        QEMU_ARGS+=( -display gtk -vga virtio )
        QEMU_ARGS+=( -usb -device usb-tablet -device usb-kbd )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND console=tty0 init=/sbin/init quiet"
        ;;
    2)  # VNC server + QXL
        echo "Starting VNC server on :1 (port 5901) with QXL..."
        QEMU_ARGS+=( -vnc :1 -device qxl )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init quiet"
        ;;
    3)  # SPICE + QXL
        echo "Starting SPICE server (port 5930) with QXL..."
        QEMU_ARGS+=( -spice port=5930,addr=127.0.0.1,disable-ticketing -device qxl )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init quiet"
        ;;
    4)  # Headless serial (current default behavior)
        echo "Starting headless (serial). Use SSH on host port ${SSH_HOST_PORT} or use the serial console."
        QEMU_ARGS+=( -nographic )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init quiet"
        ;;
    5)  # Debug kernel log on serial
        echo "Starting debug mode (higher kernel loglevel) on serial..."
        QEMU_ARGS+=( -nographic )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/sbin/init debug loglevel=7"
        ;;
    6)  # Emergency shell
        echo "Starting emergency shell (init=/bin/sh)..."
        QEMU_ARGS+=( -nographic )
        QEMU_ARGS+=( "${NET_ARGS[@]}" )
        APPEND="$COMMON_APPEND init=/bin/sh"
        ;;
    *)
        echo "Invalid choice: $mode" >&2
        exit 5
        ;;
esac
# Print the exact command for debugging / reproducibility
echo
echo "QEMU will be launched with:"
printf '  %s\n' "$QEMU_BIN" "${QEMU_ARGS[@]}" -append "\"$APPEND\""
echo
# Finally exec QEMU
exec "$QEMU_BIN" "${QEMU_ARGS[@]}" -append "$APPEND"

EOFSCRIPT
    chmod +x run-galactica.sh
    
    print_success "Launch scripts created"
}

main() {
    print_banner
    
    echo "This builds Galactica with:"
    echo "  ✓ Full networking stack (TCP/IP, DHCP, DNS)"
    echo "  ✓ Auto-starting services (getty, network)"
    echo "  ✓ Firewall support (iptables/nftables)"
    echo ""
    read -p "Continue? (y/n) [y]: " cont
    [[ "${cont:-y}" != "y" ]] && exit 0
    
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
    
    print_banner
    echo -e "${GREEN}${BOLD}=== Build Complete! ===${NC}"
    echo ""
    echo "Boot: ${YELLOW}./run-galactica.sh${NC}"
    echo "Login: ${CYAN}root${NC} / ${CYAN}galactica${NC}"
    echo ""
    echo "Features:"
    echo "  • Login screen auto-starts on boot"
    echo "  • Network auto-configures via DHCP"
    echo "  • Use mode 4 for networking in QEMU"
    echo ""
}

main
