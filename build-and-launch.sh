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
# ============================================
# WIRELESS CORE SUPPORT
# ============================================
CONFIG_WIRELESS=y
CONFIG_WIRELESS_EXT=y
CONFIG_WEXT_CORE=y
CONFIG_WEXT_PROC=y
CONFIG_WEXT_PRIV=y
CONFIG_WEXT_SPY=y

# cfg80211 wireless configuration API
CONFIG_CFG80211=y
CONFIG_CFG80211_WEXT=y
CONFIG_CFG80211_DEFAULT_PS=y

# nl80211 testmode command
CONFIG_NL80211_TESTMODE=y

# ============================================
# MAC80211 STACK
# ============================================
CONFIG_MAC80211=y
CONFIG_MAC80211_HAS_RC=y
CONFIG_MAC80211_RC_MINSTREL=y
CONFIG_MAC80211_RC_DEFAULT_MINSTREL=y
CONFIG_MAC80211_RC_DEFAULT="minstrel_ht"
CONFIG_MAC80211_LEDS=y

# ============================================
# WIRELESS DRIVERS (as modules)
# ============================================

# Intel WiFi (iwlwifi) - Very common in laptops
CONFIG_IWLWIFI=m
CONFIG_IWLDVM=m          # Intel Wireless WiFi DVM Firmware support
CONFIG_IWLMVM=m          # Intel Wireless WiFi MVM Firmware support
CONFIG_IWLWIFI_LEDS=y
CONFIG_IWLWIFI_OPMODE_MODULAR=y

# Atheros (ath9k) - Common in many devices
CONFIG_ATH_COMMON=m
CONFIG_ATH9K=m
CONFIG_ATH9K_HW=m
CONFIG_ATH9K_COMMON=m
CONFIG_ATH9K_PCI=m
CONFIG_ATH9K_LEDS=y

# Realtek (rtl8192) - Common in USB adapters
CONFIG_RTL8192CE=m
CONFIG_RTL8192CU=m
CONFIG_RTL8192DE=m
CONFIG_RTL8192SE=m
CONFIG_RTL8192C_COMMON=m

# Broadcom (b43) - Common in older devices
CONFIG_B43=m
CONFIG_B43_PHY_N=y
CONFIG_B43_PHY_LP=y
CONFIG_B43_LEDS=y

# Ralink/MediaTek (rt2x00) - USB adapters
CONFIG_RT2X00=m
CONFIG_RT2800USB=m
CONFIG_RT2800PCI=m

# ============================================
# ADDITIONAL WIFI VENDOR SUPPORT
# ============================================
CONFIG_WLAN=y
CONFIG_WLAN_VENDOR_ADMTEK=y
CONFIG_WLAN_VENDOR_ATH=y
CONFIG_WLAN_VENDOR_ATMEL=y
CONFIG_WLAN_VENDOR_BROADCOM=y
CONFIG_WLAN_VENDOR_INTEL=y
CONFIG_WLAN_VENDOR_INTERSIL=y
CONFIG_WLAN_VENDOR_MARVELL=y
CONFIG_WLAN_VENDOR_MEDIATEK=y
CONFIG_WLAN_VENDOR_RALINK=y
CONFIG_WLAN_VENDOR_REALTEK=y
CONFIG_WLAN_VENDOR_RSI=y
CONFIG_WLAN_VENDOR_ZYDAS=y

# ============================================
# LED SUPPORT (for WiFi status LEDs)
# ============================================
CONFIG_LEDS_CLASS=y
CONFIG_LEDS_TRIGGERS=y
CONFIG_LEDS_TRIGGER_PHY=y

# ============================================
# RFKILL (WiFi hardware switches)
# ============================================
CONFIG_RFKILL=y
CONFIG_RFKILL_INPUT=y
CONFIG_RFKILL_LEDS=y

# ============================================
# POWER MANAGEMENT FOR WIRELESS
# ============================================
CONFIG_PM=y
CONFIG_PM_SLEEP=y

# ============================================
# CRYPTO (required by WPA/WPA2)
# ============================================
CONFIG_CRYPTO=y
CONFIG_CRYPTO_ARC4=y
CONFIG_CRYPTO_ECB=y
CONFIG_CRYPTO_CMAC=y
CONFIG_CRYPTO_HMAC=y
CONFIG_CRYPTO_SHA1=y
CONFIG_CRYPTO_SHA256=y
CONFIG_CRYPTO_AES=y
CONFIG_CRYPTO_CCM=y
CONFIG_CRYPTO_GCM=y

# ============================================
# FIRMWARE LOADING
# ============================================
CONFIG_FW_LOADER=y
CONFIG_FW_LOADER_USER_HELPER=y
CONFIG_EXTRA_FIRMWARE=""

		
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
bundle_wifi_tools() {
    print_step 9 12 "Bundle WiFi Tools (for bootstrapping)"
    
    print_info "Copying WiFi tools from host system..."
    
    # wpa_supplicant
    if command -v wpa_supplicant &>/dev/null; then
        cp "$(command -v wpa_supplicant)" "$TARGET_ROOT/usr/sbin/"
        copy_libs "$(command -v wpa_supplicant)"
        print_success "wpa_supplicant bundled"
    else
        print_warning "wpa_supplicant not found on host (WiFi won't work)"
    fi
    
    # wpa_passphrase
    if command -v wpa_passphrase &>/dev/null; then
        cp "$(command -v wpa_passphrase)" "$TARGET_ROOT/usr/sbin/"
        print_success "wpa_passphrase bundled"
    fi
    
    # wpa_cli
    if command -v wpa_cli &>/dev/null; then
        cp "$(command -v wpa_cli)" "$TARGET_ROOT/usr/sbin/"
        copy_libs "$(command -v wpa_cli)"
        print_success "wpa_cli bundled"
    fi
    
    # iw
    if command -v iw &>/dev/null; then
        cp "$(command -v iw)" "$TARGET_ROOT/usr/sbin/"
        copy_libs "$(command -v iw)"
        print_success "iw bundled"
    else
        print_warning "iw not found on host"
    fi
    
    # dhclient
    if command -v dhclient &>/dev/null; then
        cp "$(command -v dhclient)" "$TARGET_ROOT/usr/sbin/"
        copy_libs "$(command -v dhclient)"
        print_success "dhclient bundled"
        
        # dhclient-script
        for script in /sbin/dhclient-script /usr/sbin/dhclient-script; do
            if [[ -f "$script" ]]; then
                cp "$script" "$TARGET_ROOT/usr/sbin/"
                chmod 755 "$TARGET_ROOT/usr/sbin/dhclient-script"
                break
            fi
        done
    fi
    
    # WiFi connection script (uses wifi-start for reliability)
    cat > "$TARGET_ROOT/usr/bin/wifi-connect" << 'EOFWIFI'
#!/bin/sh
# wifi-connect [ssid] [password]
[ "$(id -u)" -eq 0 ] || { echo "Must run as root"; exit 1; }

IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wl' | head -1)
[ -z "$IFACE" ] && { echo "No WiFi interface found"; exit 1; }

SSID="$1"
PASSWORD="$2"
[ -z "$SSID" ]     && { printf "SSID: ";                     read -r SSID; }
[ -z "$PASSWORD" ] && { printf "Password (blank=open): ";    read -rs PASSWORD; echo; }

mkdir -p /etc/wpa_supplicant
if [ -n "$PASSWORD" ]; then
    wpa_passphrase "$SSID" "$PASSWORD" > /etc/wpa_supplicant/wpa_supplicant.conf
else
    cat > /etc/wpa_supplicant/wpa_supplicant.conf << EOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
    ssid="$SSID"
    key_mgmt=NONE
}
EOF
fi

/sbin/wifi-start "$IFACE"
IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep inet | awk '{print $2}')
[ -n "$IP" ] && echo "Connected! IP: $IP" || echo "Failed to get IP"
EOFWIFI
    chmod 755 "$TARGET_ROOT/usr/bin/wifi-connect"
    
    print_success "WiFi tools bundled from host system"
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

    # ---- sudo / su (SUID binaries) ----
    print_info "Installing sudo and su..."
    for tool in sudo su; do
        TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
        if [[ -n "$TOOL_PATH" ]]; then
            cp "$TOOL_PATH" "$TARGET_ROOT/usr/bin/$tool"
            copy_libs "$TOOL_PATH"
            sudo chown root:root "$TARGET_ROOT/usr/bin/$tool"
            sudo chmod 4755    "$TARGET_ROOT/usr/bin/$tool"
            print_success "$tool installed with SUID"
        else
            print_warning "$tool not found on host — skipping"
        fi
    done
    # Symlink su into /bin as well (some scripts expect it there)
    ln -sf ../usr/bin/su "$TARGET_ROOT/bin/su" 2>/dev/null || true
    
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

    # ─── Device nodes ───────────────────────────────────────────────
    cd "$TARGET_ROOT/dev"
    sudo mknod -m 666 null    c 1 3  2>/dev/null || true
    sudo mknod -m 666 zero    c 1 5  2>/dev/null || true
    sudo mknod -m 666 random  c 1 8  2>/dev/null || true
    sudo mknod -m 666 urandom c 1 9  2>/dev/null || true
    sudo mknod -m 600 console c 5 1  2>/dev/null || true
    sudo mknod -m 666 tty     c 5 0  2>/dev/null || true
    sudo mknod -m 666 ptmx    c 5 2  2>/dev/null || true

    for i in 0 1 2 3 4 5 6; do
        sudo mknod -m 660 "tty$i" c 4 "$i" 2>/dev/null || true
        sudo chown root:tty "tty$i"          2>/dev/null || true
    done
    sudo mknod -m 660 ttyS0 c 4 64 2>/dev/null || true
    sudo chown root:tty ttyS0              2>/dev/null || true

    sudo mknod -m 666 fb0 c 29 0 2>/dev/null || true
    sudo mkdir -p dri
    sudo mknod -m 666 dri/card0      c 226 0   2>/dev/null || true
    sudo mknod -m 666 dri/renderD128 c 226 128 2>/dev/null || true

    sudo mkdir -p input
    for i in $(seq 0 10); do
        sudo mknod -m 660 "input/event$i" c 13 "$((64 + i))" 2>/dev/null || true
    done
    sudo mknod -m 660 input/mice c 13 63 2>/dev/null || true
    cd - > /dev/null

    # ─── Users and groups ───────────────────────────────────────────
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
storage:x:11:root
nogroup:x:65534:
EOF

    local HASH
    HASH=$(openssl passwd -6 -salt "galactica" "galactica")
    cat > "$TARGET_ROOT/etc/shadow" << EOF
root:${HASH}:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF
    chmod 600 "$TARGET_ROOT/etc/shadow"

    # ─── Base config files ───────────────────────────────────────────
    echo "galactica" > "$TARGET_ROOT/etc/hostname"

    cat > "$TARGET_ROOT/etc/hosts" << 'EOF'
127.0.0.1   localhost galactica
::1         localhost
EOF

    cat > "$TARGET_ROOT/etc/resolv.conf" << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

    cat > "$TARGET_ROOT/etc/nsswitch.conf" << 'EOF'
passwd:     files
group:      files
shadow:     files
hosts:      files dns
networks:   files
protocols:  files
services:   files
EOF

    cat > "$TARGET_ROOT/etc/sudoers" << 'EOF'
Defaults env_reset
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 440 "$TARGET_ROOT/etc/sudoers"

    # ─── Network setup script ────────────────────────────────────────
    cat > "$TARGET_ROOT/sbin/network-setup" << 'EOF'
#!/bin/sh
LOG="/var/log/airride/network.log"
mkdir -p /var/log/airride /usr/share/udhcpc /run
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%H:%M:%S')] $1"; }
log "=== Network Setup ==="

cat > /usr/share/udhcpc/default.script << 'DHCP'
#!/bin/sh
case "$1" in
    deconfig)
        ip addr flush dev "$interface" 2>/dev/null
        ip link set "$interface" up
        ;;
    bound|renew)
        ip addr flush dev "$interface" 2>/dev/null
        mask2prefix() {
            local mask="$1" bits=0 IFS=.
            for octet in $mask; do
                case "$octet" in
                    255) bits=$((bits+8));; 254) bits=$((bits+7));;
                    252) bits=$((bits+6));; 248) bits=$((bits+5));;
                    240) bits=$((bits+4));; 224) bits=$((bits+3));;
                    192) bits=$((bits+2));; 128) bits=$((bits+1));;
                esac
            done
            echo $bits
        }
        PREFIX=$(mask2prefix "${subnet:-255.255.255.0}")
        ip addr add "$ip/$PREFIX" dev "$interface"
        [ -n "$router" ] && {
            while ip route del default 2>/dev/null; do :; done
            for gw in $router; do ip route add default via "$gw" dev "$interface" && break; done
        }
        { echo "# DHCP $(date)"; for ns in $dns 8.8.8.8 8.8.4.4; do echo "nameserver $ns"; done; } > /etc/resolv.conf
        ;;
esac
exit 0
DHCP
    chmod +x /usr/share/udhcpc/default.script

    ip link set lo up 2>/dev/null

    for iface in eth0 ens3 enp0s3 enp0s2 enp1s0; do
        [ -e "/sys/class/net/$iface" ] || continue
        log "Wired: $iface"
        echo "$iface" > /run/network-iface
        ip link set "$iface" up
        sleep 1
        killall udhcpc 2>/dev/null || true
        sleep 0.5
        udhcpc -i "$iface" -s /usr/share/udhcpc/default.script \
               -p /run/udhcpc-wired.pid -b -R -t 5 -T 3 -A 60 \
            && log "DHCP bound on $iface" || log "DHCP failed on $iface"
        break
    done

    log "=== Network Setup Done ==="
EOF
    chmod +x "$TARGET_ROOT/sbin/network-setup"

    # ─── Network watchdog ────────────────────────────────────────────
    cat > "$TARGET_ROOT/sbin/network-watchdog" << 'EOF'
#!/bin/sh
LOG="/var/log/airride/network.log"
mkdir -p /var/log/airride

log() { echo "[$(date '+%H:%M:%S')] watchdog: $1" | tee -a "$LOG"; }

PING_TARGET="8.8.8.8"
CHECK_INTERVAL=30
FAIL_THRESHOLD=3
failures=0

log "Watchdog started"

while true; do
    sleep "$CHECK_INTERVAL"
    if ping -c 1 -W 3 "$PING_TARGET" >/dev/null 2>&1; then
        failures=0
    else
        failures=$((failures + 1))
        log "No connectivity (fail $failures/$FAIL_THRESHOLD)"
        if [ "$failures" -ge "$FAIL_THRESHOLD" ]; then
            log "Recovering..."
            IFACE=$(cat /run/network-iface 2>/dev/null)
            [ -n "$IFACE" ] && {
                kill $(cat /run/udhcpc-wired.pid 2>/dev/null) 2>/dev/null || true
                sleep 1
                ip link set "$IFACE" up
                udhcpc -i "$IFACE" -s /usr/share/udhcpc/default.script \
                       -p /run/udhcpc-wired.pid -b -R -t 5 -T 3 -A 60 2>>"$LOG" || true
            }
            failures=0
        fi
    fi
done
EOF
    chmod +x "$TARGET_ROOT/sbin/network-watchdog"

    # ─── Power management ────────────────────────────────────────────
    cat > "$TARGET_ROOT/sbin/poweroff" << 'EOF'
#!/bin/sh
sync
[ -w /sys/power/state ] && echo poweroff > /sys/power/state 2>/dev/null
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo o > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox poweroff -f
EOF

    cat > "$TARGET_ROOT/sbin/reboot" << 'EOF'
#!/bin/sh
sync
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo b > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox reboot -f
EOF

    cat > "$TARGET_ROOT/sbin/halt"     << 'EOF'
#!/bin/sh
exec /sbin/poweroff "$@"
EOF

    cat > "$TARGET_ROOT/sbin/shutdown" << 'EOF'
#!/bin/sh
case "$1" in -r) exec /sbin/reboot ;; *) exec /sbin/poweroff ;; esac
EOF

    chmod 755 \
        "$TARGET_ROOT/sbin/poweroff" \
        "$TARGET_ROOT/sbin/reboot" \
        "$TARGET_ROOT/sbin/halt" \
        "$TARGET_ROOT/sbin/shutdown"

    # ─── AirRide services ────────────────────────────────────────────
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

    cat > "$TARGET_ROOT/etc/airride/services/network.service" << 'EOF'
[Service]
name=network
description=Network Configuration
type=oneshot
exec_start=/sbin/network-setup
autostart=true
parallel=true

[Dependencies]
after=hostname
EOF

    cat > "$TARGET_ROOT/etc/airride/services/network-watchdog.service" << 'EOF'
[Service]
name=network-watchdog
description=Network Connectivity Watchdog
type=simple
exec_start=/sbin/network-watchdog
autostart=true
parallel=true
restart=always
restart_delay=5

[Dependencies]
after=network
EOF

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

    # ─── MOTD ────────────────────────────────────────────────────────
    cat > "$TARGET_ROOT/etc/motd" << 'EOF'
Welcome to Galactica Linux!

  dl sync                  sync package repository
  dl install <pkg>         install a package
  airridectl list          list services
  network-setup            reconfigure network
EOF

    print_success "System files created"
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
	bundle_wifi_tools || true
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
