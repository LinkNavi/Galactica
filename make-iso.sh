#!/bin/bash
# make-iso.sh — Build a bootable Galactica Installer ISO

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
PINK='\033[38;5;213m'
BOLD='\033[1m'
NC='\033[0m'

INSTALLER_DIR="./GalacticaInstaller"
BUILD_DIR="./iso-build"
ISO_ROOT="$BUILD_DIR/iso-root"
ISO_INITRD="$BUILD_DIR/initrd"
OUTPUT_ISO="galactica-installer.iso"
GALACTICA_BUILD="./galactica-build"
KERNEL_SRC="$GALACTICA_BUILD/boot/vmlinuz-galactica"

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1" >&2; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
step() { echo -e "\n${BOLD}${BLUE}[$1/$2]${NC} ${BOLD}$3${NC}\n${CYAN}$(printf '=%.0s' {1..55})${NC}\n"; }
die()  { err "$1"; exit 1; }

banner() {
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
    echo -e "${BOLD}=== Galactica Installer ISO Builder ===${NC}"
    echo ""
}

preflight() {
    step 1 6 "Preflight Checks"

    local ok_flag=true

    for cmd in go gcc grub-mkrescue xorriso mksquashfs; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found"
        else
            err "$cmd not found"
            ok_flag=false
        fi
    done

    [[ -d "$INSTALLER_DIR" ]] && ok "Installer source found" || { err "GalacticaInstaller/ not found"; ok_flag=false; }

    if [[ ! -f "$KERNEL_SRC" ]]; then
        warn "Kernel not found at $KERNEL_SRC — will try to use host kernel"
        KERNEL_SRC=""
    else
        ok "Kernel found: $KERNEL_SRC"
    fi

    [[ "$ok_flag" == "true" ]] || die "Missing dependencies. Install them and retry."
}

build_installer() {
    step 2 6 "Build Installer Binary"

    # Resolve GOROOT — needed when Go binary is trimmed and GOROOT is unset
    if [[ -z "$GOROOT" ]]; then
        GOROOT=$(go env GOROOT 2>/dev/null || true)
    fi
    if [[ -z "$GOROOT" ]]; then
        GO_BIN=$(command -v go)
        GOROOT=$(dirname "$(dirname "$(realpath "$GO_BIN")")")
    fi
    export GOROOT
    export PATH="$GOROOT/bin:$PATH"

    # Fix GOPROXY if empty/broken — use direct + fallback to sum DB
    CURRENT_PROXY=$(go env GOPROXY 2>/dev/null || true)
    if [[ -z "$CURRENT_PROXY" || "$CURRENT_PROXY" == "off" ]]; then
        export GOPROXY="https://proxy.golang.org,direct"
    fi
    export GONOSUMCHECK="*"

    cd "$INSTALLER_DIR"

    # Download dependencies first so we can surface errors clearly
    info "Downloading dependencies... (GOPROXY=$GOPROXY)"
    go mod download || die "go mod download failed — check network or run: go mod vendor"

    # Detect the correct package path from go.mod
    MODULE_NAME=$(grep '^module ' go.mod 2>/dev/null | awk '{print $2}')
    if [[ -z "$MODULE_NAME" ]]; then
        die "Could not read module name from go.mod"
    fi
    info "Running go build... (module=$MODULE_NAME)"

    # Build using . (current dir) — avoids wrong package path issues
    go build -o ../iso-installer-bin . 2>/dev/null ||     go build -o ../iso-installer-bin ./src/ 2>/dev/null ||     go build -o ../iso-installer-bin "$MODULE_NAME/src" ||     die "go build failed"

    cd ..
    ok "Installer binary built → iso-installer-bin"
}

copy_libs() {
    local bin="$1"
    [[ ! -f "$bin" ]] && return 0
    ldd "$bin" 2>/dev/null | grep -oP '/\S+\.so\S*' | while read -r lib; do
        [[ ! -f "$lib" ]] && continue
        local dest="$ISO_INITRD$lib"
        [[ -f "$dest" ]] && continue
        mkdir -p "$(dirname "$dest")"
        cp -L "$lib" "$dest" 2>/dev/null && echo "  lib: $lib" || true
    done
    return 0
}

build_initrd() {
    step 3 6 "Build Initrd"

    rm -rf "$ISO_INITRD"
    mkdir -p "$ISO_INITRD"/{bin,sbin,dev,proc,sys,run,tmp,etc,lib,lib64,usr/bin,usr/lib,usr/sbin}
    chmod 1777 "$ISO_INITRD/tmp"

    # busybox
    BUSYBOX=$(command -v busybox 2>/dev/null)
    [[ -z "$BUSYBOX" ]] && die "busybox not found"
    cp "$BUSYBOX" "$ISO_INITRD/bin/busybox"
    chmod +x "$ISO_INITRD/bin/busybox"
    for cmd in sh ash ls cat echo cp mv rm mkdir mount umount sleep \
               grep sed awk ps kill ln chmod chown ip ifconfig ping \
               hostname uname dmesg mkswap swapon losetup dd sync udhcpc \
               setsid chvt openvt clear reset; do
        ln -sf busybox "$ISO_INITRD/bin/$cmd" 2>/dev/null || true
    done
    ok "busybox installed"

    # installer binary
    cp iso-installer-bin "$ISO_INITRD/sbin/galactica-installer"
    chmod 755 "$ISO_INITRD/sbin/galactica-installer"
    ok "installer binary installed"

    # essential tools
    for tool in parted mkfs.ext4 mkswap swapon blkid partx rsync grub-install openssl; do
        TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
        if [[ -n "$TOOL_PATH" ]]; then
            cp "$TOOL_PATH" "$ISO_INITRD/sbin/" 2>/dev/null && ok "  tool: $tool" || warn "  could not copy $tool"
        else
            warn "  tool not found (skipping): $tool"
        fi
    done

    # shared libraries
    info "Copying shared libraries..."
    copy_libs "$ISO_INITRD/sbin/galactica-installer"
    for f in "$ISO_INITRD/sbin/"*; do
        copy_libs "$f"
    done
    copy_libs "$ISO_INITRD/bin/busybox"

    # essential libc/linker
    for lib in libc.so.6 libm.so.6 libdl.so.2 libpthread.so.0 libgcc_s.so.1; do
        P=$(find /lib /lib64 /usr/lib /usr/lib64 -name "$lib" 2>/dev/null | head -1)
        if [[ -n "$P" ]]; then
            DEST="$ISO_INITRD$(dirname "$P")"
            mkdir -p "$DEST"
            cp -L "$P" "$DEST/" 2>/dev/null || true
        fi
    done
    for linker in ld-linux-x86-64.so.2 ld-linux.so.2; do
        L=$(find /lib /lib64 /usr/lib /usr/lib64 -name "$linker" 2>/dev/null | head -1)
        if [[ -n "$L" ]]; then
            DEST="$ISO_INITRD$(dirname "$L")"
            mkdir -p "$DEST"
            cp -L "$L" "$DEST/"
        fi
    done
    ok "libraries copied"

    # kernel modules — use Galactica kernel modules, not host kernel
    info "Copying kernel modules..."

    # Find Galactica kernel version from galactica-build/lib/modules/
    GALACTICA_MODS=$(ls "$GALACTICA_BUILD/lib/modules/" 2>/dev/null | head -1)
    if [[ -n "$GALACTICA_MODS" ]]; then
        KVER="$GALACTICA_MODS"
        KMOD_SRC="$GALACTICA_BUILD/lib/modules/$KVER"
        info "Using Galactica kernel modules: $KVER"
    else
        KVER=$(uname -r)
        KMOD_SRC="/lib/modules/$KVER"
        warn "galactica-build has no lib/modules — using host kernel modules ($KVER)"
        warn "Fix: run 'make modules_install INSTALL_MOD_PATH=./galactica-build' in your kernel build"
    fi

    mkdir -p "$ISO_INITRD/lib/modules/$KVER"
    for mod in virtio virtio_pci virtio_blk virtio_ring virtio_net squashfs isofs scsi_mod sd_mod; do
        find "$KMOD_SRC" -name "${mod}.ko*" 2>/dev/null | while read -r m; do
            rel="${m#$KMOD_SRC/}"
            dest="$ISO_INITRD/lib/modules/$KVER/$rel"
            mkdir -p "$(dirname "$dest")"
            cp "$m" "$dest" 2>/dev/null && echo "  module: $mod" || true
        done
    done
    for f in modules.dep modules.alias modules.symbols modules.builtin modules.order; do
        [[ -f "$KMOD_SRC/$f" ]] && cp "$KMOD_SRC/$f" "$ISO_INITRD/lib/modules/$KVER/" || true
    done
    ok "kernel modules copied (kernel: $KVER)"

    # CA certs
    mkdir -p "$ISO_INITRD/etc/ssl/certs"
    for f in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
        [[ -f "$f" ]] && { cp "$f" "$ISO_INITRD/etc/ssl/certs/ca-certificates.crt"; ok "CA certs copied"; break; }
    done

    # device nodes
    sudo mknod -m 600 "$ISO_INITRD/dev/console" c 5 1  2>/dev/null || true
    sudo mknod -m 666 "$ISO_INITRD/dev/null"    c 1 3  2>/dev/null || true
    sudo mknod -m 666 "$ISO_INITRD/dev/zero"    c 1 5  2>/dev/null || true
    sudo mknod -m 666 "$ISO_INITRD/dev/urandom" c 1 9  2>/dev/null || true
    sudo mknod -m 666 "$ISO_INITRD/dev/tty"     c 5 0  2>/dev/null || true
    sudo mknod -m 666 "$ISO_INITRD/dev/ptmx"    c 5 2  2>/dev/null || true
    for i in 0 1 2 3; do
        sudo mknod -m 620 "$ISO_INITRD/dev/tty$i" c 4 "$i" 2>/dev/null || true
    done
    sudo mknod -m 660 "$ISO_INITRD/dev/ttyS0" c 4 64 2>/dev/null || true
    ok "device nodes created"

    # /etc basics
    echo "127.0.0.1 localhost" > "$ISO_INITRD/etc/hosts"
    printf 'nameserver 8.8.8.8\nnameserver 8.8.4.4\n' > "$ISO_INITRD/etc/resolv.conf"

    # init script
    cat > "$ISO_INITRD/init" << 'INIT_EOF'
#!/bin/sh
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t devpts   devpts   /dev/pts 2>/dev/null || true
mount -t tmpfs    tmpfs    /run
mount -t tmpfs    tmpfs    /tmp

# Load virtio modules so /sys/block sees the disk
modprobe virtio_ring  2>/dev/null || insmod /lib/modules/$(uname -r)/kernel/drivers/virtio/virtio_ring.ko* 2>/dev/null || true
modprobe virtio       2>/dev/null || insmod /lib/modules/$(uname -r)/kernel/drivers/virtio/virtio.ko* 2>/dev/null || true
modprobe virtio_pci   2>/dev/null || insmod /lib/modules/$(uname -r)/kernel/drivers/virtio/virtio_pci.ko* 2>/dev/null || true
modprobe virtio_blk   2>/dev/null || insmod /lib/modules/$(uname -r)/kernel/drivers/block/virtio_blk.ko* 2>/dev/null || true

# Load storage + filesystem modules
modprobe scsi_mod  2>/dev/null || true
modprobe sd_mod    2>/dev/null || true
modprobe squashfs  2>/dev/null || true
modprobe isofs     2>/dev/null || insmod /lib/modules/$(uname -r)/kernel/fs/isofs/isofs.ko* 2>/dev/null || true

# Wait for block devices to appear
sleep 2

ip link set lo up 2>/dev/null

for iface in eth0 ens3 enp0s3 enp0s2; do
    if [ -e "/sys/class/net/$iface" ]; then
        ip link set "$iface" up
        udhcpc -i "$iface" -n -q -t 5 -T 3 2>/dev/null &
        break
    fi
done

mkdir -p /mnt/iso /mnt/sqf /galactica-build

# Mount the ISO we booted from — galactica.sqf is embedded inside it
# On USB, the device shows up as a regular block device (vda, sda, etc.)
ISO_MOUNTED=0
echo "[init] Scanning for Galactica installer ISO..."

for dev in /dev/vda /dev/sda /dev/vdb /dev/sdb /dev/vdc /dev/sdc; do
    [ -b "$dev" ] || continue
    if mount -t iso9660 -o ro "$dev" /mnt/iso 2>/dev/null; then
        if [ -f "/mnt/iso/galactica.sqf" ]; then
            echo "[init] Found galactica.sqf on $dev"
            ISO_MOUNTED=1
            break
        fi
        umount /mnt/iso 2>/dev/null
    fi
done

if [ "$ISO_MOUNTED" = "1" ]; then
    if mount -t squashfs -o ro /mnt/iso/galactica.sqf /mnt/sqf 2>/dev/null; then
        mount --bind /mnt/sqf /galactica-build
        echo "[init] galactica-build ready"
    else
        echo "[init] ERROR: squashfs mount failed"
        echo "[init] Available filesystems:"
        cat /proc/filesystems
    fi
else
    echo "[init] ERROR: Could not find galactica.sqf — no ISO9660 device found"
    echo "[init] Available block devices:"
    ls /dev/[sv]d* /dev/vd* 2>/dev/null || echo "none"
fi

export TERM=linux
export HOME=/root
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

# Set up TTY properly
chown root:tty /dev/tty1 2>/dev/null || true
chmod 620 /dev/tty1 2>/dev/null || true

clear

# Find the active console and launch installer with full TTY control
CONSOLE=$(cat /sys/class/tty/console/active 2>/dev/null | awk '{print $NF}')
CONSOLE_DEV="/dev/${CONSOLE:-tty0}"
chown root:tty "$CONSOLE_DEV" 2>/dev/null || true
chmod 620 "$CONSOLE_DEV" 2>/dev/null || true

while true; do
    setsid sh -c "exec /sbin/galactica-installer <$CONSOLE_DEV >$CONSOLE_DEV 2>$CONSOLE_DEV"
    EXIT_CODE=$?
    echo ""
    echo "[init] installer exited with code $EXIT_CODE"
    echo "[init] dropping to shell — type 'exit' to relaunch installer"
    sh <$CONSOLE_DEV >$CONSOLE_DEV 2>$CONSOLE_DEV
done
INIT_EOF
    chmod 755 "$ISO_INITRD/init"

    # pack initrd
    info "Packing initrd..."
    INITRD_OUT="$(realpath "$BUILD_DIR")/initrd.img"
    (cd "$ISO_INITRD" && find . | cpio -H newc -o 2>/dev/null | gzip -9 > "$INITRD_OUT") || true
    [[ -f "$INITRD_OUT" ]] || die "initrd.img not created — cpio/gzip failed"
    ok "Initrd packed → $INITRD_OUT ($(du -sh "$INITRD_OUT" | cut -f1))"
}

assemble_iso_root() {
    step 4 6 "Assemble ISO Root"

    sudo rm -rf "$ISO_ROOT"
    mkdir -p "$ISO_ROOT/boot/grub"

    if [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC" ]]; then
        cp "$KERNEL_SRC" "$ISO_ROOT/boot/vmlinuz"
        ok "Kernel copied from $KERNEL_SRC"
    else
        HOST_KERNEL=$(find /boot -name "vmlinuz*" 2>/dev/null | sort -V | tail -1)
        [[ -n "$HOST_KERNEL" ]] || die "No kernel found. Build Galactica first."
        cp "$HOST_KERNEL" "$ISO_ROOT/boot/vmlinuz"
        warn "Using host kernel: $HOST_KERNEL"
    fi

    cp "$BUILD_DIR/initrd.img" "$ISO_ROOT/boot/initrd.img"

    # Build squashfs and embed directly into the ISO
    info "Building squashfs from galactica-build..."
    sudo mksquashfs "$GALACTICA_BUILD" "$ISO_ROOT/galactica.sqf" \
        -comp zstd -Xcompression-level 6 \
        -noappend -quiet 2>/dev/null || \
    sudo mksquashfs "$GALACTICA_BUILD" "$ISO_ROOT/galactica.sqf" \
        -comp gzip -noappend -quiet || \
    die "mksquashfs failed"
    sudo chown "$USER:$USER" "$ISO_ROOT/galactica.sqf"
    ok "squashfs embedded in ISO ($(du -sh "$ISO_ROOT/galactica.sqf" | cut -f1))"

    cat > "$ISO_ROOT/boot/grub/grub.cfg" << 'GRUB_EOF'
set timeout=5
set default=0

menuentry "Install Galactica Linux" {
    linux  /boot/vmlinuz root=/dev/ram0 rw console=tty0 console=ttyS0,115200
    initrd /boot/initrd.img
}

menuentry "Install Galactica Linux (debug)" {
    linux  /boot/vmlinuz root=/dev/ram0 rw console=tty0 debug loglevel=7
    initrd /boot/initrd.img
}

menuentry "Boot from first disk" {
    chainloader (hd0)+1
}
GRUB_EOF
    ok "GRUB config written"
}

# ── New: build squashfs source image ──────────────────────────────

build_iso() {
    step 5 6 "Build ISO with grub-mkrescue"

    grub-mkrescue -o "$OUTPUT_ISO" "$ISO_ROOT" -- \
        -volid "GALACTICA_INSTALL" \
        -rational-rock \
        -joliet 2>/dev/null || \
    grub-mkrescue -o "$OUTPUT_ISO" "$ISO_ROOT" || die "grub-mkrescue failed"

    ok "ISO built: $OUTPUT_ISO ($(du -sh "$OUTPUT_ISO" | cut -f1))"
}

cleanup_build() {
    step 6 6 "Cleanup"
    rm -f iso-installer-bin
    rm -rf "$BUILD_DIR"
    ok "Temp build files removed"
}

# ── main ──────────────────────────────────────────────────────────
banner

echo "This will build a bootable installer ISO for Galactica Linux."
echo ""
read -p "Continue? (y/n) [y]: " cont
[[ "${cont:-y}" != "y" ]] && exit 0

mkdir -p "$BUILD_DIR"

preflight
build_installer
build_initrd
assemble_iso_root
build_iso
cleanup_build

echo ""
echo -e "${GREEN}${BOLD}=== Build Complete! ===${NC}"
echo ""
echo -e "  Output: ${CYAN}$OUTPUT_ISO${NC}  ($(du -sh "$OUTPUT_ISO" | cut -f1))"
echo ""
echo "Test with QEMU:"
echo -e "  ${YELLOW}./test.sh${NC}"
echo ""
echo "Write to USB:"
echo -e "  ${YELLOW}sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress && sync${NC}"
echo ""
