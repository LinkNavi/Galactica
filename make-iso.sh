#!/bin/bash
# make-iso.sh — Build a bootable Galactica Installer ISO

# Removed set -e — use explicit error checks instead
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

    cd "$INSTALLER_DIR"
    info "Running go build..."
    go build -o ../iso-installer-bin ./src/ || die "go build failed"
    cd ..
    ok "Installer binary built → iso-installer-bin"
}

# Copy all shared libs for a given binary into the initrd
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
               hostname uname dmesg parted mkfs.ext4 mkswap swapon \
               blkid lsblk partx losetup dd sync rsync udhcpc; do
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

    # shared libraries for everything we copied
    info "Copying shared libraries..."
    copy_libs "$ISO_INITRD/sbin/galactica-installer"
    for f in "$ISO_INITRD/sbin/"*; do
        copy_libs "$f"
    done
    copy_libs "$ISO_INITRD/bin/busybox"

    # essential libc/linker — find and copy explicitly
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
    for i in 0 1 2 3; do
        sudo mknod -m 660 "$ISO_INITRD/dev/tty$i" c 4 "$i" 2>/dev/null || true
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
mount -t tmpfs    tmpfs    /run
mount -t tmpfs    tmpfs    /tmp

ip link set lo up 2>/dev/null

for iface in eth0 ens3 enp0s3 enp0s2; do
    if [ -e "/sys/class/net/$iface" ]; then
        ip link set "$iface" up
        udhcpc -i "$iface" -n -q -t 5 -T 3 2>/dev/null &
        break
    fi
done

mkdir -p /cdrom /galactica-build
for dev in /dev/sr0 /dev/sr1 /dev/cdrom; do
    mount -t iso9660 -o ro "$dev" /cdrom 2>/dev/null && break
done
mount --bind /cdrom/galactica-build /galactica-build 2>/dev/null || true

export TERM=linux
export HOME=/root
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

clear
echo ""
echo "  Galactica Linux Installer"
echo "  Loading..."
echo ""
sleep 1

# Debug: test basic things before launching installer
echo "[init] mount done"
echo "[init] testing shell..."
ls /sbin/galactica-installer && echo "[init] installer binary found" || echo "[init] installer binary MISSING"
ls /bin/sh && echo "[init] shell found" || echo "[init] shell MISSING"
echo "[init] ldd check:"
ldd /sbin/galactica-installer 2>&1 || echo "[init] ldd failed"
echo "[init] launching installer..."

/sbin/galactica-installer
echo ""
echo "[init] installer exited with code $?"
echo "[init] dropping to debug shell"
exec /bin/sh
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

    rm -rf "$ISO_ROOT"
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

    if [[ -d "$GALACTICA_BUILD" ]]; then
        info "Embedding galactica-build into ISO..."
        cp -a "$GALACTICA_BUILD" "$ISO_ROOT/galactica-build"
        ok "galactica-build embedded ($(du -sh "$ISO_ROOT/galactica-build" | cut -f1))"
    else
        die "galactica-build not found — run build-and-launch.sh first"
    fi

    cp "$BUILD_DIR/initrd.img" "$ISO_ROOT/boot/initrd.img"

    cat > "$ISO_ROOT/boot/grub/grub.cfg" << 'GRUB_EOF'
set timeout=5
set default=0

menuentry "Install Galactica Linux" {
    linux  /boot/vmlinuz root=/dev/ram0 rw console=tty0 console=ttyS0,115200 quiet
    initrd /boot/initrd.img
}

menuentry "Install Galactica Linux (serial console)" {
    linux  /boot/vmlinuz root=/dev/ram0 rw console=ttyS0,115200
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
echo -e "${GREEN}${BOLD}=== ISO Build Complete! ===${NC}"
echo ""
echo -e "  Output:  ${CYAN}$OUTPUT_ISO${NC}"
echo -e "  Size:    $(du -sh "$OUTPUT_ISO" | cut -f1)"
echo ""
echo "Test with QEMU:"
echo -e "  ${YELLOW}qemu-system-x86_64 -enable-kvm -m 2G -cdrom $OUTPUT_ISO -boot d -hda test-install.img${NC}"
echo ""
echo "Write to USB:"
echo -e "  ${YELLOW}sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress${NC}"
echo ""
