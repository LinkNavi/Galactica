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
    step 1 5 "Preflight Checks"

    local ok_flag=true

    for cmd in go gcc grub-mkrescue xorriso; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd found"
        else
            err "$cmd not found"
            ok_flag=false
        fi
    done

    [[ -d "$INSTALLER_DIR" ]] && ok "Installer source found" || { err "GalacticaInstaller/ not found"; ok_flag=false; }
    [[ -d "$GALACTICA_BUILD" ]] && ok "galactica-build found" || { err "galactica-build/ not found — run build-and-launch.sh first"; ok_flag=false; }
[[ -f "./ginitrd/ginitrd.sh" ]] && ok "ginitrd found" || { err "ginitrd/ginitrd.sh not found"; ok_flag=false; }
    if [[ ! -f "$KERNEL_SRC" ]]; then
        warn "Kernel not found at $KERNEL_SRC — will try to use host kernel"
        KERNEL_SRC=""
    else
        ok "Kernel found: $KERNEL_SRC"
    fi

    [[ "$ok_flag" == "true" ]] || die "Missing dependencies. Install them and retry."
}

build_installer() {
    step 2 5 "Build Installer Binary"

    if [[ -z "$GOROOT" ]]; then
        GOROOT=$(go env GOROOT 2>/dev/null || true)
    fi
    if [[ -z "$GOROOT" ]]; then
        GO_BIN=$(command -v go)
        GOROOT=$(dirname "$(dirname "$(realpath "$GO_BIN")")")
    fi
    export GOROOT
    export PATH="$GOROOT/bin:$PATH"

    CURRENT_PROXY=$(go env GOPROXY 2>/dev/null || true)
    if [[ -z "$CURRENT_PROXY" || "$CURRENT_PROXY" == "off" ]]; then
        export GOPROXY="https://proxy.golang.org,direct"
    fi
    export GONOSUMCHECK="*"

    cd "$INSTALLER_DIR"
    info "Downloading dependencies... (GOPROXY=$GOPROXY)"
    go mod download || die "go mod download failed"

    MODULE_NAME=$(grep '^module ' go.mod 2>/dev/null | awk '{print $2}')
    [[ -z "$MODULE_NAME" ]] && die "Could not read module name from go.mod"
    info "Running go build... (module=$MODULE_NAME)"

    go build -o ../iso-installer-bin . 2>/dev/null || \
    go build -o ../iso-installer-bin ./src/ 2>/dev/null || \
    go build -o ../iso-installer-bin "$MODULE_NAME/src" || \
    die "go build failed"

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
        cp -L "$lib" "$dest" 2>/dev/null || true
    done
    return 0
}

build_initrd() {
    step 3 5 "Build Initrd"

    rm -rf "$ISO_INITRD"
    mkdir -p "$ISO_INITRD"/{bin,sbin,dev,proc,sys,run,tmp,etc,lib,lib64,usr/bin,usr/lib,usr/sbin,galactica-build}
    chmod 1777 "$ISO_INITRD/tmp"

    # busybox
    BUSYBOX=$(command -v busybox 2>/dev/null)
    [[ -z "$BUSYBOX" ]] && die "busybox not found"
    cp "$BUSYBOX" "$ISO_INITRD/bin/busybox"
    chmod +x "$ISO_INITRD/bin/busybox"
    for cmd in sh ash ls cat echo cp mv rm mkdir mount umount sleep \
           grep sed awk ps kill ln chmod chown ip ifconfig ping \
           hostname uname dmesg mkswap swapon losetup dd sync udhcpc \
           setsid chvt openvt clear reset head tail sort uniq wc find \
           cut du dirname basename tr xargs readlink realpath stat; do
        ln -sf busybox "$ISO_INITRD/bin/$cmd" 2>/dev/null || true
    done
    ok "busybox installed"

    # bash (needed for ginitrd which uses bash arrays)
    BASH=$(command -v bash)
    if [[ -n "$BASH" ]]; then
        cp "$BASH" "$ISO_INITRD/bin/bash"
        copy_libs "$BASH"
        # override busybox sh symlink with bash
        ln -sf bash "$ISO_INITRD/bin/sh" || cp "$ISO_INITRD/bin/bash" "$ISO_INITRD/bin/sh"
        # bash runtime libs
        for lib in libreadline.so.8 libncursesw.so.6 libtinfo.so.6; do
            P=$(find /lib /lib64 /usr/lib /usr/lib64 -name "$lib" 2>/dev/null | head -1)
            [[ -n "$P" ]] && { mkdir -p "$ISO_INITRD$(dirname "$P")"; cp -L "$P" "$ISO_INITRD$(dirname "$P")/"; }
        done
        ok "bash installed"
    else
        warn "bash not found on host — ginitrd may fail"
    fi

    # installer binary
    cp iso-installer-bin "$ISO_INITRD/sbin/galactica-installer"
    chmod 755 "$ISO_INITRD/sbin/galactica-installer"
    ok "installer binary installed"

    # essential tools
    for tool in parted mkfs.ext4 mkfs.fat mkswap swapon blkid findfs partx \
            rsync grub-install grub-bios-setup openssl zstd cpio \
            mktemp file ldd mknod; do
        TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
        if [[ -n "$TOOL_PATH" ]]; then
            cp "$TOOL_PATH" "$ISO_INITRD/sbin/" 2>/dev/null && ok "  tool: $tool" || warn "  could not copy $tool"
        else
            warn "  tool not found (skipping): $tool"
        fi
    done

if [[ -f "./ginitrd/ginitrd.sh" ]]; then
    cp "./ginitrd/ginitrd.sh" "$ISO_INITRD/sbin/ginitrd"
    chmod +x "$ISO_INITRD/sbin/ginitrd"
    ok "ginitrd installed from ./ginitrd/ginitrd.sh"
else
    warn "ginitrd not found at ./ginitrd/ginitrd.sh"
fi
# ldd is usually a shell script, copy it properly
LDD_PATH=$(command -v ldd)
if [[ -n "$LDD_PATH" ]]; then
    cp "$LDD_PATH" "$ISO_INITRD/sbin/ldd"
    # ldd may reference the dynamic linker path directly — already copied above
    ok "ldd installed"
fi

# file needs its magic database
FILE_PATH=$(command -v file)
if [[ -n "$FILE_PATH" ]]; then
    cp "$FILE_PATH" "$ISO_INITRD/sbin/file"
    copy_libs "$FILE_PATH"
    MAGIC=$(file --version 2>&1 | grep -oP 'magic file.*?\K/\S+' || true)
    [[ -z "$MAGIC" ]] && MAGIC="/usr/share/misc/magic.mgc"
    if [[ -f "$MAGIC" ]]; then
        mkdir -p "$ISO_INITRD$(dirname "$MAGIC")"
        cp "$MAGIC" "$ISO_INITRD$(dirname "$MAGIC")/"
    fi
    # Also try the magic directory
    [[ -d "/usr/share/misc/magic" ]] && {
        mkdir -p "$ISO_INITRD/usr/share/misc"
        cp -r /usr/share/misc/magic "$ISO_INITRD/usr/share/misc/"
    }
    ok "file installed"
fi
MKTEMP=$(command -v mktemp)
[[ -n "$MKTEMP" ]] && cp "$MKTEMP" "$ISO_INITRD/bin/mktemp"
    # grub modules for BIOS install
    GRUB_MODS_SRC=""
    for d in /usr/lib/grub/i386-pc /usr/share/grub/i386-pc; do
        [[ -d "$d" ]] && GRUB_MODS_SRC="$d" && break
    done
    if [[ -n "$GRUB_MODS_SRC" ]]; then
        mkdir -p "$ISO_INITRD/usr/lib/grub/i386-pc"
        cp -r "$GRUB_MODS_SRC"/. "$ISO_INITRD/usr/lib/grub/i386-pc/"
        ok "grub i386-pc modules copied"
    else
        warn "grub i386-pc modules not found on host — bootloader install will fail"
    fi

    # grub modules for UEFI install
    for d in /usr/lib/grub/x86_64-efi /usr/share/grub/x86_64-efi; do
        [[ -d "$d" ]] && {
            mkdir -p "$ISO_INITRD/usr/lib/grub/x86_64-efi"
            cp -r "$d"/. "$ISO_INITRD/usr/lib/grub/x86_64-efi/"
            ok "grub x86_64-efi modules copied"
            break
        }
    done

    # grub shared data files
    for d in /usr/share/grub /usr/lib/grub; do
        [[ -d "$d" ]] && {
            mkdir -p "$ISO_INITRD$d"
            cp -r "$d"/. "$ISO_INITRD$d/"
        }
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

    # kernel modules
    info "Copying kernel modules..."
    GALACTICA_MODS=$(ls "$GALACTICA_BUILD/lib/modules/" 2>/dev/null | head -1)
    if [[ -n "$GALACTICA_MODS" ]]; then
        KVER="$GALACTICA_MODS"
        KMOD_SRC="$GALACTICA_BUILD/lib/modules/$KVER"
        info "Using Galactica kernel modules: $KVER"
    else
        KVER=$(uname -r)
        KMOD_SRC="/lib/modules/$KVER"
        warn "No galactica modules found — using host kernel ($KVER)"
    fi

    mkdir -p "$ISO_INITRD/lib/modules/$KVER"
    for mod in virtio virtio_pci virtio_blk virtio_ring virtio_net scsi_mod sd_mod; do
        find "$KMOD_SRC" -name "${mod}.ko*" 2>/dev/null | while read -r m; do
            rel="${m#$KMOD_SRC/}"
            dest="$ISO_INITRD/lib/modules/$KVER/$rel"
            mkdir -p "$(dirname "$dest")"
            cp "$m" "$dest" 2>/dev/null || true
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

    # Bundle galactica-build BEFORE packing
   info "Bundling galactica-build into initrd..."
sudo cp -a "$GALACTICA_BUILD/." "$ISO_INITRD/galactica-build/"
ok "galactica-build bundled"

    # init script
    cat > "$ISO_INITRD/init" << 'INIT_EOF'
#!/bin/sh

export PATH=/usr/bin:/usr/sbin:/bin:/sbin
mount -t proc     proc     /proc
mount -t sysfs    sysfs    /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
mount -t devpts   devpts   /dev/pts 2>/dev/null || true
mount -t tmpfs    tmpfs    /run
mount -t tmpfs    tmpfs    /tmp

KVER=$(uname -r)
MODDIR="/lib/modules/$KVER"

insmod_mod() {
    local name="$1"
    local alt="${name//-/_}"
    for ko in \
        "$MODDIR/kernel/drivers/virtio/${name}.ko" \
        "$MODDIR/kernel/drivers/virtio/${alt}.ko" \
        "$MODDIR/kernel/drivers/block/${name}.ko" \
        "$MODDIR/kernel/drivers/block/${alt}.ko" \
        "$MODDIR/kernel/drivers/ata/${name}.ko" \
        "$MODDIR/kernel/drivers/scsi/${name}.ko" \
        "$MODDIR/kernel/drivers/nvme/host/${name}.ko" \
        "$MODDIR/kernel/drivers/nvme/host/${alt}.ko"; do
        [ -f "$ko" ] && insmod "$ko" 2>/dev/null && return 0
        for ext in gz zst xz; do
            [ -f "${ko}.${ext}" ] && insmod "${ko}.${ext}" 2>/dev/null && return 0
        done
    done
    return 0
}

echo "[init] Loading modules (kernel $KVER)..."
for m in virtio virtio_ring virtio_pci_modern_dev virtio_pci virtio_blk; do
    insmod_mod "$m"
done
for m in libata ata_piix ahci libahci scsi_mod sd_mod nvme_core nvme; do
    insmod_mod "$m"
done
echo "[init] Modules done"

sleep 1
[ -x /bin/mdev ] && { echo /bin/mdev > /proc/sys/kernel/hotplug 2>/dev/null; mdev -s 2>/dev/null; } || true
ip link set lo up 2>/dev/null || true

for iface in eth0 ens3 enp0s3 enp0s2; do
    [ -e "/sys/class/net/$iface" ] || continue
    ip link set "$iface" up
    udhcpc -i "$iface" -n -q -t 5 -T 3 2>/dev/null &
    break
done

if [ -d "/galactica-build/boot" ]; then
    echo "[init] galactica-build OK"
else
    echo "[init] WARNING: /galactica-build/boot missing"
    ls /galactica-build 2>/dev/null || echo "(empty)"
fi

export TERM=linux
export HOME=/root
export PATH=/usr/bin:/usr/sbin:/bin:/sbin

CONSOLE=$(cat /sys/class/tty/console/active 2>/dev/null | awk '{print $NF}')
CONSOLE_DEV="/dev/${CONSOLE:-tty0}"
chown root:tty "$CONSOLE_DEV" 2>/dev/null || true
chmod 620 "$CONSOLE_DEV" 2>/dev/null || true

echo ""
echo "[init] Press Enter to launch installer (or wait 5s)..."
read -t 5 _DUMMY || true
clear

while true; do
    setsid sh -c "exec /sbin/galactica-installer <$CONSOLE_DEV >$CONSOLE_DEV 2>$CONSOLE_DEV"
    EXIT_CODE=$?
    echo ""
    echo "[init] installer exited ($EXIT_CODE) — shell (exit to relaunch)"
    sh <$CONSOLE_DEV >$CONSOLE_DEV 2>$CONSOLE_DEV
done
INIT_EOF
    chmod 755 "$ISO_INITRD/init"

    # Pack initrd
    info "Packing initrd..."
INITRD_OUT="$(realpath "$BUILD_DIR")/initrd.img"
(cd "$ISO_INITRD" && sudo find . | sudo cpio -H newc -o 2>/dev/null | gzip -1 > "$INITRD_OUT") || true 
[[ -f "$INITRD_OUT" ]] || die "initrd.img not created"
    ok "Initrd packed → $INITRD_OUT ($(du -sh "$INITRD_OUT" | cut -f1))"
}

assemble_iso_root() {
    step 4 5 "Assemble ISO Root"

    sudo rm -rf "$ISO_ROOT"
    mkdir -p "$ISO_ROOT/boot/grub"

    if [[ -n "$KERNEL_SRC" && -f "$KERNEL_SRC" ]]; then
        cp "$KERNEL_SRC" "$ISO_ROOT/boot/vmlinuz"
        ok "Kernel copied from $KERNEL_SRC"
    else
        HOST_KERNEL=$(find /boot -name "vmlinuz*" 2>/dev/null | sort -V | tail -1)
        [[ -n "$HOST_KERNEL" ]] || die "No kernel found."
        cp "$HOST_KERNEL" "$ISO_ROOT/boot/vmlinuz"
        warn "Using host kernel: $HOST_KERNEL"
    fi

    cp "$BUILD_DIR/initrd.img" "$ISO_ROOT/boot/initrd.img"

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

build_iso() {
    step 5 5 "Build ISO with grub-mkrescue"

    grub-mkrescue -o "$OUTPUT_ISO" "$ISO_ROOT" -- \
        -volid "GALACTICA_INSTALL" \
        -rational-rock \
        -joliet 2>/dev/null || \
    grub-mkrescue -o "$OUTPUT_ISO" "$ISO_ROOT" || die "grub-mkrescue failed"

    ok "ISO built: $OUTPUT_ISO ($(du -sh "$OUTPUT_ISO" | cut -f1))"
}

cleanup_build() {
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
