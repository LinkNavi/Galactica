#!/bin/bash
# package-release.sh — Package all Galactica components for GalacticaRepository
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
PINK='\033[38;5;213m'
BOLD='\033[1m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1" >&2; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
die()  { err "$1"; exit 1; }

# ---------------------------------------------------------------------------
# Config — adjust versions here
# ---------------------------------------------------------------------------
GITHUB_USER="LinkNavi"
GITHUB_REPO="Galactica"
POYO_VERSION="1.1.0"
AIRRIDE_VERSION="1.0.0"
DREAMLAND_VERSION="1.0.0"
GINITRD_VERSION="1.0.0"
BUSYBOX_VERSION="1.35.0"
BASE_CONFIG_VERSION="1.0.0"
BASE_VERSION="1.0.0"

# Source dirs
POYO_DIR="./Poyo"
AIRRIDE_DIR="./AirRide"
DREAMLAND_DIR="./Dreamland"
GINITRD_DIR="./ginitrd"

# Output dirs
OUT_DIR="./galactica-packages"
TARBALLS_DIR="$OUT_DIR/tarballs"
PKG_DIR="$OUT_DIR/pkg-files"
WORKFLOWS_DIR="$OUT_DIR/workflows"

BASE_URL="https://github.com/$GITHUB_USER/$GITHUB_REPO/releases/download"

# ---------------------------------------------------------------------------
print_banner() {
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
    echo -e "${BOLD}=== Galactica Package Builder ===${NC}"
    echo ""
}

# ---------------------------------------------------------------------------
check_binaries() {
    info "Checking for built binaries..."
    local ok_flag=true
    [[ -f "$POYO_DIR/poyo" ]]                       || { err "poyo not built — run build-and-launch.sh first"; ok_flag=false; }
    [[ -f "$AIRRIDE_DIR/Init/build/airride" ]]       || { err "airride not built"; ok_flag=false; }
    [[ -f "$AIRRIDE_DIR/Ctl/build/airridectl" ]]     || { err "airridectl not built"; ok_flag=false; }
    [[ -f "$DREAMLAND_DIR/build/dreamland" ]]        || { err "dreamland not built"; ok_flag=false; }
    [[ -f "$GINITRD_DIR/ginitrd.sh" ]]               || { err "ginitrd.sh not found"; ok_flag=false; }
    [[ "$ok_flag" == "true" ]] || die "Missing binaries. Run build-and-launch.sh first."
    ok "All binaries found"
}

# ---------------------------------------------------------------------------
package_poyo() {
    info "Packaging poyo $POYO_VERSION..."
    local tmp=$(mktemp -d)
    cp "$POYO_DIR/poyo" "$tmp/poyo"
    tar -czf "$TARBALLS_DIR/poyo-$POYO_VERSION.tar.gz" -C "$tmp" .
    rm -rf "$tmp"
    ok "poyo-$POYO_VERSION.tar.gz"
}

package_airride() {
    info "Packaging airride $AIRRIDE_VERSION..."
    local tmp=$(mktemp -d)
    cp "$AIRRIDE_DIR/Init/build/airride"    "$tmp/airride"
    cp "$AIRRIDE_DIR/Ctl/build/airridectl"  "$tmp/airridectl"
    tar -czf "$TARBALLS_DIR/airride-$AIRRIDE_VERSION.tar.gz" -C "$tmp" .
    rm -rf "$tmp"
    ok "airride-$AIRRIDE_VERSION.tar.gz"
}

package_dreamland() {
    info "Packaging dreamland $DREAMLAND_VERSION..."
    local tmp=$(mktemp -d)
    cp "$DREAMLAND_DIR/build/dreamland" "$tmp/dreamland"
    tar -czf "$TARBALLS_DIR/dreamland-$DREAMLAND_VERSION.tar.gz" -C "$tmp" .
    rm -rf "$tmp"
    ok "dreamland-$DREAMLAND_VERSION.tar.gz"
}

package_ginitrd() {
    info "Packaging ginitrd $GINITRD_VERSION..."
    local tmp=$(mktemp -d)
    cp "$GINITRD_DIR/ginitrd.sh" "$tmp/ginitrd.sh"
    tar -czf "$TARBALLS_DIR/ginitrd-$GINITRD_VERSION.tar.gz" -C "$tmp" .
    rm -rf "$tmp"
    ok "ginitrd-$GINITRD_VERSION.tar.gz"
}

package_busybox() {
    info "Packaging busybox $BUSYBOX_VERSION..."
    local tmp=$(mktemp -d)
    BUSYBOX_PATH=$(command -v busybox 2>/dev/null || true)
    [[ -n "$BUSYBOX_PATH" ]] || die "busybox not found on host"
    cp "$BUSYBOX_PATH" "$tmp/busybox"
    tar -czf "$TARBALLS_DIR/busybox-$BUSYBOX_VERSION.tar.gz" -C "$tmp" .
    rm -rf "$tmp"
    ok "busybox-$BUSYBOX_VERSION.tar.gz"
}

package_base_config() {
    info "Packaging base-config $BASE_CONFIG_VERSION..."
    local tmp=$(mktemp -d)
    mkdir -p "$tmp/etc/airride/services"
    mkdir -p "$tmp/sbin"
    mkdir -p "$tmp/usr/bin"
    mkdir -p "$tmp/usr/share/udhcpc"

    # network-setup
    cat > "$tmp/sbin/network-setup" << 'EOF'
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

    # network-watchdog
    cat > "$tmp/sbin/network-watchdog" << 'EOF'
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

    # poweroff/reboot/halt/shutdown
    cat > "$tmp/sbin/poweroff" << 'EOF'
#!/bin/sh
sync
[ -w /sys/power/state ] && echo poweroff > /sys/power/state 2>/dev/null
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo o > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox poweroff -f
EOF
    cat > "$tmp/sbin/reboot" << 'EOF'
#!/bin/sh
sync
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo b > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox reboot -f
EOF
    cat > "$tmp/sbin/halt"     << 'EOF'
#!/bin/sh
exec /sbin/poweroff "$@"
EOF
    cat > "$tmp/sbin/shutdown" << 'EOF'
#!/bin/sh
case "$1" in -r) exec /sbin/reboot ;; *) exec /sbin/poweroff ;; esac
EOF

    # wifi-connect
    cat > "$tmp/usr/bin/wifi-connect" << 'EOF'
#!/bin/sh
[ "$(id -u)" -eq 0 ] || { echo "Must run as root"; exit 1; }
IFACE=$(ls /sys/class/net/ 2>/dev/null | grep -E '^wl' | head -1)
[ -z "$IFACE" ] && { echo "No WiFi interface found"; exit 1; }
SSID="$1"; PASSWORD="$2"
[ -z "$SSID" ]     && { printf "SSID: ";                  read -r SSID; }
[ -z "$PASSWORD" ] && { printf "Password (blank=open): "; read -rs PASSWORD; echo; }
mkdir -p /etc/wpa_supplicant
if [ -n "$PASSWORD" ]; then
    wpa_passphrase "$SSID" "$PASSWORD" > /etc/wpa_supplicant/wpa_supplicant.conf
else
    cat > /etc/wpa_supplicant/wpa_supplicant.conf << WEOF
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

    # AirRide service units
    cat > "$tmp/etc/airride/services/hostname.service" << 'EOF'
[Service]
name=hostname
description=Set System Hostname
type=oneshot
exec_start=/bin/hostname galactica
autostart=true
parallel=true

[Dependencies]
EOF
    cat > "$tmp/etc/airride/services/network.service" << 'EOF'
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
    cat > "$tmp/etc/airride/services/network-watchdog.service" << 'EOF'
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
    cat > "$tmp/etc/airride/services/ttyS0.service" << 'EOF'
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
    cat > "$tmp/etc/airride/services/tty1.service" << 'EOF'
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

    # motd
    cat > "$tmp/etc/motd" << 'EOF'
Welcome to Galactica Linux!

  dl sync               sync package repository
  dl install <pkg>      install a package
  airridectl list       list services
  wifi-connect          connect to WiFi
  network-setup         reconfigure wired network
EOF

    tar -czf "$TARBALLS_DIR/base-config-$BASE_CONFIG_VERSION.tar.gz" -C "$tmp" .
    rm -rf "$tmp"
    ok "base-config-$BASE_CONFIG_VERSION.tar.gz"
}

# ---------------------------------------------------------------------------
write_pkg_files() {
    info "Writing .pkg files..."

    cat > "$PKG_DIR/core/poyo.pkg" << EOF
[Package]
name = "poyo"
version = "$POYO_VERSION"
description = "Poyo getty and login manager"
url = "$BASE_URL/poyo-$POYO_VERSION/poyo-$POYO_VERSION.tar.gz"
category = "core"

[Script]
install -Dm755 poyo /sbin/poyo
EOF

    cat > "$PKG_DIR/core/airride.pkg" << EOF
[Package]
name = "airride"
version = "$AIRRIDE_VERSION"
description = "AirRide init system"
url = "$BASE_URL/airride-$AIRRIDE_VERSION/airride-$AIRRIDE_VERSION.tar.gz"
category = "core"

[Script]
install -Dm755 airride /sbin/airride
install -Dm755 airridectl /usr/bin/airridectl
ln -sf airride /sbin/init
EOF

    cat > "$PKG_DIR/core/dreamland.pkg" << EOF
[Package]
name = "dreamland"
version = "$DREAMLAND_VERSION"
description = "Dreamland package manager"
url = "$BASE_URL/dreamland-$DREAMLAND_VERSION/dreamland-$DREAMLAND_VERSION.tar.gz"
category = "core"

[Script]
install -Dm755 dreamland /usr/bin/dreamland
ln -sf dreamland /usr/bin/dl
EOF

    cat > "$PKG_DIR/core/ginitrd.pkg" << EOF
[Package]
name = "ginitrd"
version = "$GINITRD_VERSION"
description = "Galactica initramfs generator"
url = "$BASE_URL/ginitrd-$GINITRD_VERSION/ginitrd-$GINITRD_VERSION.tar.gz"
category = "core"

[Script]
install -Dm755 ginitrd.sh /usr/sbin/ginitrd
EOF

    cat > "$PKG_DIR/core/busybox.pkg" << EOF
[Package]
name = "busybox"
version = "$BUSYBOX_VERSION"
description = "BusyBox userland utilities"
url = "$BASE_URL/busybox-$BUSYBOX_VERSION/busybox-$BUSYBOX_VERSION.tar.gz"
category = "core"

[Script]
install -Dm755 busybox /bin/busybox
for cmd in sh ash ls cat echo pwd mkdir rm cp mv tar udhcpc gunzip gzip \
           ln chmod chown grep sed awk ps kill sleep touch date mount \
           umount ip ifconfig route ping hostname uname dmesg; do
    ln -sf busybox /bin/\$cmd 2>/dev/null || true
done
EOF

    cat > "$PKG_DIR/core/base-config.pkg" << EOF
[Package]
name = "base-config"
version = "$BASE_CONFIG_VERSION"
description = "Base system configuration and scripts"
url = "$BASE_URL/base-config-$BASE_CONFIG_VERSION/base-config-$BASE_CONFIG_VERSION.tar.gz"
category = "core"

[Script]
cp -r etc/. /etc/
cp -r sbin/. /sbin/
cp -r usr/. /usr/
chmod +x /sbin/network-setup /sbin/network-watchdog
chmod +x /sbin/poweroff /sbin/reboot /sbin/halt /sbin/shutdown
chmod +x /usr/bin/wifi-connect
EOF

    cat > "$PKG_DIR/core/base.pkg" << EOF
[Package]
name = "base"
version = "$BASE_VERSION"
description = "Galactica base system metapackage"
category = "core"

[Dependencies]
depends = "busybox airride poyo dreamland ginitrd base-config"
EOF

    ok "pkg files written"
}

# ---------------------------------------------------------------------------
write_index() {
    info "Writing INDEX..."
    cat > "$PKG_DIR/INDEX" << EOF
core/base.pkg
core/busybox.pkg
core/airride.pkg
core/poyo.pkg
core/dreamland.pkg
core/ginitrd.pkg
core/base-config.pkg
core/linux.pkg
EOF
    ok "INDEX written"
}

# ---------------------------------------------------------------------------
write_workflows() {
    info "Writing GitHub Actions workflows..."

    # Helper function used in each workflow
    local release_template='
      - name: Upload Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: PKG_TAG
          name: PKG_NAME
          files: TARBALL
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}'

    # ── poyo ──
    cat > "$WORKFLOWS_DIR/release-poyo.yml" << EOF
name: Release Poyo

on:
  push:
    tags:
      - 'poyo-*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        default: '$POYO_VERSION'

jobs:
  build-and-release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Build Poyo
        run: |
          cd Poyo
          gcc -Wall -Wextra -O2 -D_GNU_SOURCE -fstack-protector-strong \\
              -o poyo src/main.c -lcrypt

      - name: Package
        run: |
          mkdir release
          cp Poyo/poyo release/
          tar -czf poyo-\${{ github.ref_name || inputs.version }}.tar.gz -C release .

      - name: Upload Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: \${{ github.ref_name || format('poyo-{0}', inputs.version) }}
          name: Poyo \${{ inputs.version || github.ref_name }}
          files: poyo-*.tar.gz
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
EOF

    # ── airride ──
    cat > "$WORKFLOWS_DIR/release-airride.yml" << EOF
name: Release AirRide

on:
  push:
    tags:
      - 'airride-*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        default: '$AIRRIDE_VERSION'

jobs:
  build-and-release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install deps
        run: sudo apt-get install -y g++ make

      - name: Build AirRide
        run: |
          cd AirRide/Init
          mkdir -p build
          g++ -o build/airride src/main.cpp -Wall -Wextra -O2 -std=c++17 -fstack-protector-strong
          cd ../Ctl
          mkdir -p build
          g++ -o build/airridectl src/main.cpp -Wall -Wextra -O2 -std=c++17

      - name: Package
        run: |
          mkdir release
          cp AirRide/Init/build/airride release/
          cp AirRide/Ctl/build/airridectl release/
          tar -czf airride-\${{ github.ref_name || inputs.version }}.tar.gz -C release .

      - name: Upload Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: \${{ github.ref_name || format('airride-{0}', inputs.version) }}
          name: AirRide \${{ inputs.version || github.ref_name }}
          files: airride-*.tar.gz
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
EOF

    # ── dreamland ──
    cat > "$WORKFLOWS_DIR/release-dreamland.yml" << EOF
name: Release Dreamland

on:
  push:
    tags:
      - 'dreamland-*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        default: '$DREAMLAND_VERSION'

jobs:
  build-and-release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install deps
        run: sudo apt-get install -y g++ libcurl4-openssl-dev libssl-dev libarchive-dev libzstd-dev zlib1g-dev

      - name: Build Dreamland
        run: |
          cd Dreamland
          mkdir -p build
          g++ -o build/dreamland src/main.cpp \\
              -std=c++20 -O2 -Wall -Wextra -fPIC \\
              -lcurl -lssl -lcrypto -lz -lzstd -larchive -lpthread -ldl

      - name: Package
        run: |
          mkdir release
          cp Dreamland/build/dreamland release/
          tar -czf dreamland-\${{ github.ref_name || inputs.version }}.tar.gz -C release .

      - name: Upload Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: \${{ github.ref_name || format('dreamland-{0}', inputs.version) }}
          name: Dreamland \${{ inputs.version || github.ref_name }}
          files: dreamland-*.tar.gz
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
EOF

    # ── ginitrd ──
    cat > "$WORKFLOWS_DIR/release-ginitrd.yml" << EOF
name: Release ginitrd

on:
  push:
    tags:
      - 'ginitrd-*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        default: '$GINITRD_VERSION'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Package
        run: |
          mkdir release
          cp ginitrd/ginitrd.sh release/
          tar -czf ginitrd-\${{ github.ref_name || inputs.version }}.tar.gz -C release .

      - name: Upload Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: \${{ github.ref_name || format('ginitrd-{0}', inputs.version) }}
          name: ginitrd \${{ inputs.version || github.ref_name }}
          files: ginitrd-*.tar.gz
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
EOF

    # ── busybox ──
    cat > "$WORKFLOWS_DIR/release-busybox.yml" << EOF
name: Release Busybox

on:
  push:
    tags:
      - 'busybox-*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        default: '$BUSYBOX_VERSION'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Get busybox
        run: sudo apt-get install -y busybox-static

      - name: Package
        run: |
          mkdir release
          cp /bin/busybox release/
          tar -czf busybox-\${{ github.ref_name || inputs.version }}.tar.gz -C release .

      - name: Upload Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: \${{ github.ref_name || format('busybox-{0}', inputs.version) }}
          name: Busybox \${{ inputs.version || github.ref_name }}
          files: busybox-*.tar.gz
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
EOF

    # ── base-config ──
    cat > "$WORKFLOWS_DIR/release-base-config.yml" << EOF
name: Release Base Config

on:
  push:
    tags:
      - 'base-config-*'
  workflow_dispatch:
    inputs:
      version:
        description: 'Version to release'
        default: '$BASE_CONFIG_VERSION'

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Package
        run: bash package-release.sh --config-only

      - name: Upload Release
        uses: softprops/action-gh-release@v1
        with:
          tag_name: \${{ github.ref_name || format('base-config-{0}', inputs.version) }}
          name: Base Config \${{ inputs.version || github.ref_name }}
          files: galactica-packages/tarballs/base-config-*.tar.gz
        env:
          GITHUB_TOKEN: \${{ secrets.GITHUB_TOKEN }}
EOF

    ok "Workflows written"
}

# ---------------------------------------------------------------------------
print_instructions() {
    echo ""
    echo -e "${BOLD}=== Done! ===${NC}"
    echo ""
    echo -e "Output structure:"
    echo -e "  ${CYAN}$OUT_DIR/${NC}"
    echo -e "  ├── tarballs/       ← upload these as GitHub release assets"
    echo -e "  ├── pkg-files/      ← copy these to GalacticaRepository"
    echo -e "  │   ├── core/       ← copy to GalacticaRepository/core/"
    echo -e "  │   └── INDEX       ← copy to GalacticaRepository/INDEX"
    echo -e "  └── workflows/      ← copy to Galactica/.github/workflows/"
    echo ""
    echo -e "${BOLD}Steps:${NC}"
    echo -e "  1. Copy ${CYAN}$PKG_DIR/core/*.pkg${NC} → GalacticaRepository/core/"
    echo -e "  2. Copy ${CYAN}$PKG_DIR/INDEX${NC} → GalacticaRepository/INDEX (merge with existing)"
    echo -e "  3. Copy ${CYAN}$WORKFLOWS_DIR/*.yml${NC} → Galactica/.github/workflows/"
    echo -e "  4. Create initial releases by pushing tags:"
    echo -e "     ${YELLOW}git tag poyo-$POYO_VERSION && git push origin poyo-$POYO_VERSION${NC}"
    echo -e "     ${YELLOW}git tag airride-$AIRRIDE_VERSION && git push origin airride-$AIRRIDE_VERSION${NC}"
    echo -e "     ${YELLOW}git tag dreamland-$DREAMLAND_VERSION && git push origin dreamland-$DREAMLAND_VERSION${NC}"
    echo -e "     ${YELLOW}git tag ginitrd-$GINITRD_VERSION && git push origin ginitrd-$GINITRD_VERSION${NC}"
    echo -e "     ${YELLOW}git tag busybox-$BUSYBOX_VERSION && git push origin busybox-$BUSYBOX_VERSION${NC}"
    echo -e "     ${YELLOW}git tag base-config-$BASE_CONFIG_VERSION && git push origin base-config-$BASE_CONFIG_VERSION${NC}"
    echo ""
    echo -e "  Or trigger them manually from GitHub Actions → workflow_dispatch"
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
print_banner

# Handle --config-only flag (used by base-config workflow)
if [[ "$1" == "--config-only" ]]; then
    mkdir -p "$TARBALLS_DIR"
    package_base_config
    exit 0
fi

mkdir -p "$TARBALLS_DIR" "$PKG_DIR/core" "$WORKFLOWS_DIR"

check_binaries
package_poyo
package_airride
package_dreamland
package_ginitrd
package_busybox
package_base_config
write_pkg_files
write_index
write_workflows
print_instructions
