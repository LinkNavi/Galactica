#!/bin/bash
# Galactica Complete Build Script
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
ROOTFS_SIZE=512
KERNEL_VERSION="6.18.4"

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
    echo -e "${BOLD}=== Galactica Build v4.1 ===${NC}"
    echo ""
}

print_step()    { echo -e "\n${BOLD}${BLUE}[STEP $1/$2]${NC} ${BOLD}$3${NC}\n${CYAN}$(printf '=%.0s' {1..60})${NC}\n"; }
print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error()   { echo -e "${RED}✗${NC} $1"; }
print_warning() { echo -e "${YELLOW}!${NC} $1"; }
print_info()    { echo -e "${CYAN}→${NC} $1"; }

# ---------------------------------------------------------------------------
# Step 0 – Pre-flight checks
# ---------------------------------------------------------------------------
preflight_checks() {
    print_step 0 10 "Pre-flight Checks"
    local all_ok=true

    for cmd in gcc g++ make bc flex bison dd mkfs.ext4; do
        if command -v "$cmd" &>/dev/null; then
            print_success "$cmd found"
        else
            print_error "$cmd not found"
            all_ok=false
        fi
    done

    command -v busybox &>/dev/null && print_success "busybox found" \
        || { print_warning "busybox not found"; all_ok=false; }
    command -v qemu-system-x86_64 &>/dev/null && print_success "QEMU found" \
        || print_warning "QEMU not found (needed to run, not to build)"

    [[ "$all_ok" == "true" ]] && print_success "All required dependencies satisfied" \
        || { print_error "Missing dependencies — install them and retry"; return 1; }
}

# ---------------------------------------------------------------------------
# Step 1 – Build kernel
# The kernel config is maintained externally in kernel.config.
# Place your .config (or a file named kernel.config) next to this script
# before running, and it will be copied into the kernel source tree.
# ---------------------------------------------------------------------------
build_kernel() {
    print_step 1 10 "Build Linux Kernel"

    local TARBALL KURL KDIR CACHE_DIR GCC_VER rebuild
    TARBALL="linux-${KERNEL_VERSION}.tar.xz"
    KURL="https://cdn.kernel.org/pub/linux/kernel/v6.x/${TARBALL}"
    KDIR="./linux-${KERNEL_VERSION}"
    CACHE_DIR="./kernel-cache"

    # Set global so later steps can find the source tree
    KERNEL_DIR="$KDIR"

    # Skip if already built
    if [[ -f "$TARGET_ROOT/boot/vmlinuz-galactica" ]] && \
       [[ -f "$TARGET_ROOT/boot/.kernel-version" ]] && \
       [[ "$(cat "$TARGET_ROOT/boot/.kernel-version")" == "$KERNEL_VERSION" ]]; then
        print_success "Kernel $KERNEL_VERSION already built"
        read -rp "Rebuild? (y/n) [n]: " rebuild
        [[ "$rebuild" != "y" ]] && return 0
    fi

    mkdir -p "$CACHE_DIR"

    # Download tarball if not cached
    if [[ ! -f "$CACHE_DIR/$TARBALL" ]]; then
        print_info "Downloading kernel $KERNEL_VERSION ..."
        wget -O "$CACHE_DIR/$TARBALL" "$KURL" \
            || curl -L -o "$CACHE_DIR/$TARBALL" "$KURL" \
            || { print_error "Download failed"; return 1; }
    fi

    # Extract if source dir missing
    if [[ ! -d "$KDIR" ]]; then
        print_info "Extracting kernel source..."
        tar -xf "$CACHE_DIR/$TARBALL" \
            || { print_error "Extraction failed"; return 1; }
    fi

    cd "$KDIR"

    # GCC 13+ needs gnu11
    GCC_VER=$(gcc -dumpversion | cut -d. -f1)
    if [[ $GCC_VER -ge 13 ]]; then
        export KCFLAGS="-std=gnu11" HOSTCFLAGS="-std=gnu11" \
               CC="gcc -std=gnu11" HOSTCC="gcc -std=gnu11"
    fi

    # Load external config if no .config yet
    if [[ ! -f .config ]]; then
        if [[ -f "../kernel.config" ]]; then
            print_info "Using ../kernel.config"
            cp ../kernel.config .config
            make olddefconfig
        else
            print_error "No .config found and no ../kernel.config provided."
            print_error "Place your kernel config as kernel.config next to this script."
            cd ..
            return 1
        fi
    fi

    # Sanity-check critical options
    for opt in CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_INET CONFIG_EXT4_FS; do
        grep -q "^${opt}=y" .config \
            || { print_error "$opt is NOT enabled in .config"; cd ..; return 1; }
    done
    print_success "Kernel config validated"

    if [[ ! -f arch/x86/boot/bzImage ]]; then
        print_info "Compiling kernel (this takes a while) ..."
        make -j"$(nproc)" 2>&1 | tee ../kernel-build.log
    fi

    if [[ -f arch/x86/boot/bzImage ]]; then
        print_success "Kernel built successfully"
    else
        print_error "Kernel build failed — see kernel-build.log"
        cd ..
        return 1
    fi

    cd ..
}

# ---------------------------------------------------------------------------
# Step 2 – Build Poyo
# ---------------------------------------------------------------------------
build_poyo() {
    print_step 2 10 "Build Poyo Getty/Login"
    cd "$POYO_DIR"
    gcc -Wall -Wextra -O2 -D_GNU_SOURCE -fstack-protector-strong \
        -o poyo src/main.c -lcrypt || { cd ..; return 1; }
    print_success "Poyo built"
    cd ..
}

# ---------------------------------------------------------------------------
# Step 3 – Build AirRide init
# ---------------------------------------------------------------------------
build_airride() {
    print_step 3 10 "Build AirRide Init"
    cd "$AIRRIDE_DIR/Init"
    mkdir -p build
    g++ -o build/airride src/main.cpp \
        -Wall -Wextra -O2 -std=c++17 -fstack-protector-strong \
        || { cd ../..; return 1; }
    print_success "AirRide built"
    cd ../..
}

# ---------------------------------------------------------------------------
# Step 4 – Build AirRideCtl
# ---------------------------------------------------------------------------
build_airridectl() {
    print_step 4 10 "Build AirRideCtl"
    cd "$AIRRIDE_DIR/Ctl"
    mkdir -p build
    g++ -o build/airridectl src/main.cpp \
        -Wall -Wextra -O2 -std=c++17 \
        || { cd ../..; return 1; }
    print_success "AirRideCtl built"
    cd ../..
}

# ---------------------------------------------------------------------------
# Step 5 – Build Dreamland
# ---------------------------------------------------------------------------
build_dreamland() {
    print_step 5 10 "Build Dreamland Package Manager"
    cd "$DREAMLAND_DIR"
    pkg-config --exists libcurl libarchive 2>/dev/null \
        || print_warning "Some libraries may be missing — attempting build anyway"
    mkdir -p build
    g++ -o build/dreamland src/main.cpp \
        -std=c++17 -O2 -Wall -Wextra -fPIC \
        -lcurl -lssl -lcrypto -lz -lzstd -larchive -lpthread -ldl \
        || { print_error "Dreamland build failed"; cd ..; return 1; }
    print_success "Dreamland built"
    cd ..
}

# ---------------------------------------------------------------------------
# Step 6 – Prepare root filesystem tree
# ---------------------------------------------------------------------------
prepare_build_dir() {
    print_step 6 10 "Prepare Root Filesystem Tree"

    if [[ -d "$TARGET_ROOT" ]]; then
        read -rp "Clean build directory? (y/n) [y]: " clean
        [[ "${clean:-y}" == "y" ]] && rm -rf "$TARGET_ROOT"
    fi

    mkdir -p "$TARGET_ROOT"/{bin,sbin,dev,proc,sys,run,tmp,root,home/user}
    mkdir -p "$TARGET_ROOT"/etc/{airride/services,ssl/certs,wpa_supplicant}
    mkdir -p "$TARGET_ROOT"/{lib,lib64}
    mkdir -p "$TARGET_ROOT"/usr/{bin,sbin,lib,lib64,share/udhcpc}
    mkdir -p "$TARGET_ROOT"/var/{log,run}

    chmod 1777 "$TARGET_ROOT/tmp"
    chmod 700  "$TARGET_ROOT/root"
    print_success "Directory structure created"
}

# ---------------------------------------------------------------------------
# Step 7 – Install built components
# ---------------------------------------------------------------------------
install_components() {
    print_step 7 10 "Install Built Components"

    [[ -z "$KERNEL_DIR" ]] && KERNEL_DIR=$(find . -maxdepth 1 -type d -name "linux-*" | head -1)

    mkdir -p "$TARGET_ROOT/boot"
    cp "$KERNEL_DIR/arch/x86/boot/bzImage" "$TARGET_ROOT/boot/vmlinuz-galactica"
    echo "$KERNEL_VERSION" > "$TARGET_ROOT/boot/.kernel-version"
    print_success "Kernel image installed"

    install -m755 "$POYO_DIR/poyo"                       "$TARGET_ROOT/sbin/poyo"
    install -m755 "$AIRRIDE_DIR/Init/build/airride"      "$TARGET_ROOT/sbin/airride"
    install -m755 "$AIRRIDE_DIR/Ctl/build/airridectl"    "$TARGET_ROOT/usr/bin/airridectl"
    install -m755 "$DREAMLAND_DIR/build/dreamland"       "$TARGET_ROOT/usr/bin/dreamland"

    ln -sf airride   "$TARGET_ROOT/sbin/init"
    ln -sf dreamland "$TARGET_ROOT/usr/bin/dl"

    print_success "Components installed"
}

# ---------------------------------------------------------------------------
# Step 8 – Install busybox, libraries, tools
# ---------------------------------------------------------------------------

# Helper: copy all shared libs needed by a binary
copy_libs() {
    local binary="$1"
    [[ ! -f "$binary" ]] && return
    ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | while read -r lib; do
        [[ -f "$lib" && ! -f "$TARGET_ROOT$lib" ]] && {
            mkdir -p "$TARGET_ROOT$(dirname "$lib")"
            cp "$lib" "$TARGET_ROOT$lib" 2>/dev/null || true
        }
    done
}

install_essentials() {
    print_step 8 10 "Install Busybox, Libraries, and Tools"

    # Busybox
    cp /bin/busybox "$TARGET_ROOT/bin/"
    chmod +x "$TARGET_ROOT/bin/busybox"

    # Busybox symlinks — /bin
    for cmd in sh ash ls cat echo pwd mkdir rm cp mv ln chmod chown \
                grep sed awk ps kill sleep touch date mount umount \
                ip ifconfig route ping hostname uname dmesg; do
        ln -sf busybox "$TARGET_ROOT/bin/$cmd" 2>/dev/null || true
    done

    # Busybox symlinks — /sbin
    for cmd in ifconfig route ip; do
        ln -sf ../bin/busybox "$TARGET_ROOT/sbin/$cmd" 2>/dev/null || true
    done

    print_info "Copying runtime libraries..."

    # Libraries for our own binaries
    for bin in "$TARGET_ROOT/sbin/airride" \
               "$TARGET_ROOT/sbin/poyo" \
               "$TARGET_ROOT/usr/bin/airridectl" \
               "$TARGET_ROOT/usr/bin/dreamland"; do
        copy_libs "$bin"
    done

    # Core libs by name (fallback)
    for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 \
               libcrypt.so.1 libgcc_s.so.1 libstdc++.so.6 \
               libresolv.so.2 libnss_dns.so.2 libnss_files.so.2; do
        LIBPATH=$(find /lib* /usr/lib* -name "$lib" 2>/dev/null | head -1)
        [[ -n "$LIBPATH" ]] && {
            mkdir -p "$TARGET_ROOT$(dirname "$LIBPATH")"
            cp "$LIBPATH" "$TARGET_ROOT$(dirname "$LIBPATH")/" 2>/dev/null || true
        }
    done

    # Dynamic linker
    for linker in ld-linux-x86-64.so.2 ld-linux.so.2; do
        LINKER=$(find /lib* -name "$linker" 2>/dev/null | head -1)
        [[ -n "$LINKER" ]] && {
            mkdir -p "$TARGET_ROOT$(dirname "$LINKER")"
            cp "$LINKER" "$TARGET_ROOT$(dirname "$LINKER")/"
        }
    done

    # sudo / su (SUID)
    for tool in sudo su; do
        TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
        if [[ -n "$TOOL_PATH" ]]; then
            cp "$TOOL_PATH" "$TARGET_ROOT/usr/bin/$tool"
            copy_libs "$TOOL_PATH"
            sudo chown root:root "$TARGET_ROOT/usr/bin/$tool"
            sudo chmod 4755     "$TARGET_ROOT/usr/bin/$tool"
            print_success "$tool installed (SUID)"
        else
            print_warning "$tool not found on host — skipping"
        fi
    done
    ln -sf ../usr/bin/su "$TARGET_ROOT/bin/su" 2>/dev/null || true

    # WiFi tools
    for tool in wpa_supplicant wpa_passphrase wpa_cli iw; do
        TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
        if [[ -n "$TOOL_PATH" ]]; then
            cp "$TOOL_PATH" "$TARGET_ROOT/usr/sbin/"
            copy_libs "$TOOL_PATH"
            print_success "$tool installed"
        else
            print_warning "$tool not found on host"
        fi
    done

    # Static curl for HTTPS in the guest
    print_info "Fetching static curl..."
    CURL_URL="https://github.com/moparisthebest/static-curl/releases/download/v8.5.0/curl-amd64"
    if curl -sL -o "$TARGET_ROOT/usr/bin/curl" "$CURL_URL" 2>/dev/null \
       || wget -qO "$TARGET_ROOT/usr/bin/curl" "$CURL_URL" 2>/dev/null; then
        chmod 755 "$TARGET_ROOT/usr/bin/curl"
        print_success "curl installed"
    else
        print_warning "Could not download static curl"
    fi

    # CA certificates
    for cert in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        [[ -f "$cert" ]] && {
            cp "$cert" "$TARGET_ROOT/etc/ssl/certs/ca-certificates.crt"
            break
        }
    done

    # Strip binaries
    print_info "Stripping binaries..."
    find "$TARGET_ROOT/usr/bin" "$TARGET_ROOT/sbin" "$TARGET_ROOT/bin" \
         -type f -executable \
         -exec strip --strip-unneeded {} 2>/dev/null \;
    find "$TARGET_ROOT/lib" "$TARGET_ROOT/usr/lib" \
         -name '*.so*' -type f \
         -exec strip --strip-unneeded {} 2>/dev/null \;

    print_success "Essentials installed"
}

# ---------------------------------------------------------------------------
# Step 9 – Create system config files
# ---------------------------------------------------------------------------
create_system_files() {
    print_step 9 10 "Create System Configuration"

    # Device nodes
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
        sudo chown root:tty "tty$i"         2>/dev/null || true
    done
    sudo mknod -m 660 ttyS0 c 4 64 2>/dev/null || true
    sudo chown root:tty ttyS0             2>/dev/null || true
    sudo mknod -m 666 fb0 c 29 0  2>/dev/null || true
    sudo mkdir -p dri
    sudo mknod -m 666 dri/card0      c 226 0   2>/dev/null || true
    sudo mknod -m 666 dri/renderD128 c 226 128 2>/dev/null || true
    sudo mkdir -p input
    for i in $(seq 0 10); do
        sudo mknod -m 660 "input/event$i" c 13 "$((64 + i))" 2>/dev/null || true
    done
    sudo mknod -m 660 input/mice c 13 63 2>/dev/null || true
    cd - > /dev/null

    # Users / groups / shadow
    cat > "$TARGET_ROOT/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

    cat > "$TARGET_ROOT/etc/group" <<'EOF'
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
    cat > "$TARGET_ROOT/etc/shadow" <<EOF
root:${HASH}:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF
    chmod 600 "$TARGET_ROOT/etc/shadow"

    # Basic networking config
    echo "galactica" > "$TARGET_ROOT/etc/hostname"

    cat > "$TARGET_ROOT/etc/hosts" <<'EOF'
127.0.0.1   localhost galactica
::1         localhost
EOF

    cat > "$TARGET_ROOT/etc/resolv.conf" <<'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

    cat > "$TARGET_ROOT/etc/nsswitch.conf" <<'EOF'
passwd:   files
group:    files
shadow:   files
hosts:    files dns
networks: files
protocols: files
services: files
EOF

    cat > "$TARGET_ROOT/etc/sudoers" <<'EOF'
Defaults env_reset
Defaults secure_path="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
root ALL=(ALL:ALL) ALL
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 440 "$TARGET_ROOT/etc/sudoers"

    # MOTD
    cat > "$TARGET_ROOT/etc/motd" <<'EOF'
Welcome to Galactica Linux!

  dl sync               sync package repository
  dl install <pkg>      install a package
  airridectl list       list services
  wifi-connect          connect to WiFi
  network-setup         reconfigure wired network
EOF

    # wifi-connect
    cat > "$TARGET_ROOT/usr/bin/wifi-connect" <<'EOF'
#!/bin/sh
[ "$(id -u)" -eq 0 ] || { echo "Must run as root"; exit 1; }

IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wl' | head -1)
[ -z "$IFACE" ] && { echo "No WiFi interface found"; exit 1; }

SSID="$1"
PASSWORD="$2"
[ -z "$SSID" ]     && { printf "SSID: ";                  read -r SSID; }
[ -z "$PASSWORD" ] && { printf "Password (blank=open): "; read -rs PASSWORD; echo; }

mkdir -p /etc/wpa_supplicant
if [ -n "$PASSWORD" ]; then
    wpa_passphrase "$SSID" "$PASSWORD" > /etc/wpa_supplicant/wpa_supplicant.conf
else
    cat > /etc/wpa_supplicant/wpa_supplicant.conf <<WEOF
ctrl_interface=/var/run/wpa_supplicant
update_config=1
network={
    ssid="$SSID"
    key_mgmt=NONE
}
WEOF
fi

ip link set "$IFACE" up
killall wpa_supplicant 2>/dev/null; sleep 1
wpa_supplicant -B -i "$IFACE" -c /etc/wpa_supplicant/wpa_supplicant.conf
sleep 2
udhcpc -i "$IFACE" -n -q -t 5 -T 3 2>/dev/null
IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep inet | awk '{print $2}')
[ -n "$IP" ] && echo "Connected! IP: $IP" || echo "Failed to get IP"
EOF
    chmod 755 "$TARGET_ROOT/usr/bin/wifi-connect"

    # udhcpc default script (written at runtime by network-setup)
    # network-setup
    cat > "$TARGET_ROOT/sbin/network-setup" <<'EOF'
#!/bin/sh
LOG="/var/log/airride/network.log"
mkdir -p /var/log/airride /usr/share/udhcpc /run
exec >> "$LOG" 2>&1

log() { echo "[$(date '+%H:%M:%S')] $1"; }
log "=== Network Setup ==="

cat > /usr/share/udhcpc/default.script <<'DHCP'
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

    # network-watchdog
    cat > "$TARGET_ROOT/sbin/network-watchdog" <<'EOF'
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
                kill "$(cat /run/udhcpc-wired.pid 2>/dev/null)" 2>/dev/null || true
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

    # Power management
    cat > "$TARGET_ROOT/sbin/poweroff" <<'EOF'
#!/bin/sh
sync
[ -w /sys/power/state ] && echo poweroff > /sys/power/state 2>/dev/null
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo o > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox poweroff -f
EOF

    cat > "$TARGET_ROOT/sbin/reboot" <<'EOF'
#!/bin/sh
sync
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo b > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox reboot -f
EOF

    cat > "$TARGET_ROOT/sbin/halt" <<'EOF'
#!/bin/sh
exec /sbin/poweroff "$@"
EOF

    cat > "$TARGET_ROOT/sbin/shutdown" <<'EOF'
#!/bin/sh
case "$1" in -r) exec /sbin/reboot ;; *) exec /sbin/poweroff ;; esac
EOF

    chmod 755 \
        "$TARGET_ROOT/sbin/poweroff" \
        "$TARGET_ROOT/sbin/reboot" \
        "$TARGET_ROOT/sbin/halt" \
        "$TARGET_ROOT/sbin/shutdown"

    # AirRide service units
    cat > "$TARGET_ROOT/etc/airride/services/hostname.service" <<'EOF'
[Service]
name=hostname
description=Set System Hostname
type=oneshot
exec_start=/bin/hostname galactica
autostart=true
parallel=true

[Dependencies]
EOF

    cat > "$TARGET_ROOT/etc/airride/services/network.service" <<'EOF'
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

    cat > "$TARGET_ROOT/etc/airride/services/network-watchdog.service" <<'EOF'
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

    cat > "$TARGET_ROOT/etc/airride/services/ttyS0.service" <<'EOF'
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

    cat > "$TARGET_ROOT/etc/airride/services/tty1.service" <<'EOF'
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

    print_success "System files created"
}

# ---------------------------------------------------------------------------
# Step 9b – Strip bloat
# ---------------------------------------------------------------------------
strip_bloat() {
    print_info "Removing unnecessary files..."
    rm -f  "$TARGET_ROOT/usr/bin/"{c++,make,find,patch,diff,xargs} 2>/dev/null || true
    rm -rf "$TARGET_ROOT/usr/share/pkgconfig"                       2>/dev/null || true
    rm -f  "$TARGET_ROOT/lib/x86_64-linux-gnu/libbfd"*.so          2>/dev/null || true
    rm -f  "$TARGET_ROOT/lib/x86_64-linux-gnu/libopcodes"*.so      2>/dev/null || true
    rm -f  "$TARGET_ROOT/usr/lib/x86_64-linux-gnu/libisl"*.so*     2>/dev/null || true
    rm -f  "$TARGET_ROOT/usr/lib/x86_64-linux-gnu/libmpfr"*.so*    2>/dev/null || true
    rm -f  "$TARGET_ROOT/usr/lib/x86_64-linux-gnu/libzstd"*.so*    2>/dev/null || true
    print_success "Bloat removed"
}

# ---------------------------------------------------------------------------
# Step 10 – Create ext4 root filesystem image
# ---------------------------------------------------------------------------
create_rootfs() {
    print_step 10 10 "Create Root Filesystem Image"

    [[ -f "$OUTPUT_ROOTFS" ]] && rm -f "$OUTPUT_ROOTFS"

    dd if=/dev/zero of="$OUTPUT_ROOTFS" bs=1M count="$ROOTFS_SIZE" status=progress
    mkfs.ext4 -F -L "GalacticaRoot" "$OUTPUT_ROOTFS"

    mkdir -p mnt_tmp
    sudo mount -o loop "$OUTPUT_ROOTFS" mnt_tmp
    sudo cp -a "$TARGET_ROOT"/. mnt_tmp/
    sudo umount mnt_tmp
    rmdir mnt_tmp

    print_success "Root filesystem image created: $OUTPUT_ROOTFS"
}

# ---------------------------------------------------------------------------
# QEMU launch script
# ---------------------------------------------------------------------------
create_launch_script() {
    cat > run-galactica.sh <<'LAUNCH'
#!/usr/bin/env bash
set -euo pipefail

KERNEL="${KERNEL:-galactica-build/boot/vmlinuz-galactica}"
ROOTFS="${ROOTFS:-galactica-rootfs.img}"
MEM="${MEM:-512M}"
CPUS="${CPUS:-2}"
SSH_HOST_PORT="${SSH_HOST_PORT:-2222}"
QEMU_BIN="${QEMU_BIN:-qemu-system-x86_64}"

command -v "$QEMU_BIN" >/dev/null 2>&1 || { echo "qemu not found"; exit 2; }
[[ -f "$KERNEL" ]] || { echo "Kernel not found: $KERNEL"; exit 3; }
[[ -f "$ROOTFS" ]] || { echo "Rootfs not found: $ROOTFS"; exit 4; }

cat <<'EOF'
=== Galactica Boot ===
  1) GUI window (GTK + virtio-vga)
  2) VNC :1 (port 5901) + QXL
  3) SPICE port 5930 + QXL
  4) Headless serial (no display)
  5) Debug (loglevel=7 on serial)
  6) Emergency shell (init=/bin/sh)
EOF
read -r -p "Select (1-6) [1]: " mode
mode="${mode:-1}"

QEMU_ARGS=(
    -kernel "$KERNEL"
    -drive  "file=$ROOTFS,format=raw,if=virtio"
    -m      "$MEM"
    -smp    "$CPUS"
    -serial "mon:stdio"
    -enable-kvm
)
NET_ARGS=(-netdev "user,id=net0,hostfwd=tcp::${SSH_HOST_PORT}-:22" -device virtio-net-pci,netdev=net0)
BASE_APPEND="root=/dev/vda rw console=ttyS0"

case "$mode" in
    1)
        QEMU_ARGS+=(-display gtk -vga virtio -usb -device usb-tablet -device usb-kbd "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND console=tty0 init=/sbin/init quiet"
        ;;
    2)
        QEMU_ARGS+=(-vnc :1 -device qxl "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init quiet"
        ;;
    3)
        QEMU_ARGS+=(-spice port=5930,addr=127.0.0.1,disable-ticketing -device qxl "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init quiet"
        ;;
    4)
        QEMU_ARGS+=(-nographic "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init quiet"
        ;;
    5)
        QEMU_ARGS+=(-nographic "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/sbin/init debug loglevel=7"
        ;;
    6)
        QEMU_ARGS+=(-nographic "${NET_ARGS[@]}")
        APPEND="$BASE_APPEND init=/bin/sh"
        ;;
    *)
        echo "Invalid choice"; exit 5 ;;
esac

echo "Launching QEMU..."
exec "$QEMU_BIN" "${QEMU_ARGS[@]}" -append "$APPEND"
LAUNCH
    chmod +x run-galactica.sh
    print_success "run-galactica.sh created"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    print_banner

    echo "This builds Galactica with:"
    echo "  ✓ Full networking stack (TCP/IP, DHCP, DNS)"
    echo "  ✓ Auto-starting services (getty, network)"
    echo "  ✓ Minimal footprint"
    echo ""
    echo "  NOTE: Kernel config must be provided as ./kernel.config"
    echo ""
    read -rp "Continue? (y/n) [y]: " cont
    [[ "${cont:-y}" != "y" ]] && exit 0

    preflight_checks    || exit 1
    build_kernel        || exit 1
    build_poyo          || exit 1
    build_airride       || exit 1
    build_airridectl    || exit 1
    build_dreamland     || exit 1
    prepare_build_dir   || exit 1
    install_components  || exit 1
    install_essentials  || exit 1
    create_system_files || exit 1
    strip_bloat
    create_rootfs       || exit 1
    create_launch_script

    print_banner
    echo -e "${GREEN}${BOLD}=== Build Complete! ===${NC}"
    echo ""
    echo "Boot:  ./run-galactica.sh"
    echo "Login: root / galactica"
    echo ""
}

main
