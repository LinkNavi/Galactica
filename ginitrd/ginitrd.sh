#!/bin/bash
# ginitrd - Galactica Initramfs Builder
# Builds a minimal initramfs with only the modules needed to mount root
set -e

VERSION="1.0.0"
WORK_DIR=$(mktemp -d /tmp/ginitrd.XXXXXX)
trap 'rm -rf "$WORK_DIR"' EXIT

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
die()  { err "$1"; exit 1; }

usage() {
    cat << EOF
ginitrd v$VERSION - Galactica Initramfs Builder

Usage: ginitrd [OPTIONS]

Options:
  -k, --kernel VERSION    Kernel version (default: running kernel)
  -o, --output FILE       Output initramfs path (default: /boot/initramfs-galactica.img)
  -r, --root DEVICE       Root device hint for autodetect (e.g. /dev/sda3, /dev/vda)
  -m, --modules LIST      Extra modules to include (comma separated)
  -f, --fallback          Build fallback image (include ALL storage/fs modules)
  -c, --compress METHOD   Compression: zstd (default), gzip, none
  -v, --verbose           Verbose output
  -h, --help              Show this help

Examples:
  ginitrd                                    # autodetect everything
  ginitrd -k 6.18.4-galactica               # specific kernel
  ginitrd -o /boot/initramfs.img -f          # fallback with all modules
  ginitrd -m "r8169,iwlwifi" -r /dev/nvme0n1p3
EOF
    exit 0
}

# ============================================================
# Defaults
# ============================================================
KERNEL_VER=$(uname -r)
OUTPUT="/boot/initramfs-galactica.img"
ROOT_DEVICE=""
EXTRA_MODULES=""
FALLBACK=false
COMPRESS="zstd"
VERBOSE=false

# ============================================================
# Arg parsing
# ============================================================
while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--kernel)   KERNEL_VER="$2";    shift 2 ;;
        -o|--output)   OUTPUT="$2";        shift 2 ;;
        -r|--root)     ROOT_DEVICE="$2";   shift 2 ;;
        -m|--modules)  EXTRA_MODULES="$2"; shift 2 ;;
        -f|--fallback) FALLBACK=true;      shift   ;;
        -c|--compress) COMPRESS="$2";      shift 2 ;;
        -v|--verbose)  VERBOSE=true;       shift   ;;
        -h|--help)     usage ;;
        *) die "Unknown option: $1" ;;
    esac
done

MODULES_DIR="/lib/modules/$KERNEL_VER"
[[ -d "$MODULES_DIR" ]] || die "Kernel modules not found at $MODULES_DIR"

vlog() { $VERBOSE && echo "  [v] $1" || true; }

# ============================================================
# Step 1: Build the initramfs directory structure
# ============================================================
build_structure() {
    info "Building directory structure..."
    mkdir -p "$WORK_DIR"/{bin,sbin,lib,lib64,dev,proc,sys,run,tmp,etc,mnt/root,usr/bin,usr/sbin}
    chmod 1777 "$WORK_DIR/tmp"
    ok "Structure ready"
}

# ============================================================
# Step 2: Copy busybox (provides all basic userspace tools)
# ============================================================
install_busybox() {
    info "Installing busybox..."

    BUSYBOX_PATH=$(command -v busybox 2>/dev/null || true)
    # Also check common static locations
    for p in /usr/bin/busybox /bin/busybox /usr/sbin/busybox; do
        [[ -f "$p" ]] && BUSYBOX_PATH="$p" && break
    done
    [[ -z "$BUSYBOX_PATH" ]] && die "busybox not found — install it first"

    cp "$BUSYBOX_PATH" "$WORK_DIR/bin/busybox"
    chmod 755 "$WORK_DIR/bin/busybox"

    # Symlink all applets
    for applet in sh ash cat echo ls mkdir rm cp mv ln chmod chown \
                  mount umount switch_root grep sed awk cut sort uniq \
                  find xargs sleep head tail wc printf test [ \
                  modprobe insmod lsmod rmmod depmod \
                  blkid findfs \
                  mdev \
                  uname dmesg sysctl \
                  hexdump od \
                  gunzip zcat; do
        ln -sf busybox "$WORK_DIR/bin/$applet" 2>/dev/null || true
    done

    ok "Busybox installed ($(du -sh "$BUSYBOX_PATH" | cut -f1))"
}

# ============================================================
# Step 3: Collect required libraries for any non-static binaries
# ============================================================
copy_libs() {
    local binary="$1"
    [[ ! -f "$binary" ]] && return 0

    # Check if static
    file "$binary" 2>/dev/null | grep -q "statically linked" && return 0

    ldd "$binary" 2>/dev/null | grep -oP '/\S+' | while read -r lib; do
        [[ ! -f "$lib" ]] && continue
        local dest="$WORK_DIR$lib"
        [[ -f "$dest" ]] && continue
        mkdir -p "$(dirname "$dest")"
        cp -L "$lib" "$dest"
        vlog "lib: $lib"
    done
}

install_libs() {
    info "Copying essential libraries..."

    # Always need the dynamic linker and libc
    for lib in \
        ld-linux-x86-64.so.2 \
        libc.so.6 \
        libm.so.6 \
        libdl.so.2 \
        libpthread.so.0 \
        libgcc_s.so.1; do
        found=$(find /lib /lib64 /usr/lib /usr/lib64 -name "$lib" 2>/dev/null | head -1)
        if [[ -n "$found" ]]; then
            dest="$WORK_DIR$(dirname "$found")"
            mkdir -p "$dest"
            cp -L "$found" "$dest/"
            vlog "base lib: $lib"
        fi
    done

    # Copy libs for busybox (usually static but just in case)
    copy_libs "$WORK_DIR/bin/busybox"

    ok "Libraries installed"
}

# ============================================================
# Step 4: Module detection and collection
# ============================================================

# Resolve a module name to its .ko path
find_module() {
    local modname="${1//-/_}"  # normalize dashes to underscores
    find "$MODULES_DIR" -name "${modname}.ko" -o -name "${modname}.ko.zst" \
         -o -name "${modname}.ko.gz" -o -name "${modname}.ko.xz" 2>/dev/null | head -1
}

# Copy a module and all its dependencies
copy_module_with_deps() {
    local modname="$1"
    local modpath

    modpath=$(find_module "$modname")
    if [[ -z "$modpath" ]]; then
        vlog "module not found: $modname (may be built-in)"
        return 0
    fi

    # Get relative path from modules dir
    local relpath="${modpath#$MODULES_DIR/}"
    local destpath="$WORK_DIR/lib/modules/$KERNEL_VER/$relpath"

    # Skip if already copied
    [[ -f "$destpath" ]] && return 0

    mkdir -p "$(dirname "$destpath")"
    cp "$modpath" "$destpath"
    vlog "module: $modname -> $relpath"

    # Resolve dependencies from modules.dep
    if [[ -f "$MODULES_DIR/modules.dep" ]]; then
        # modules.dep lines look like: kernel/path/mod.ko: kernel/dep1.ko kernel/dep2.ko
        grep "^$relpath:" "$MODULES_DIR/modules.dep" | cut -d: -f2 | tr ' ' '\n' | while read -r dep; do
            [[ -z "$dep" ]] && continue
            local dep_name
            dep_name=$(basename "$dep" | sed 's/\.ko.*//')
            copy_module_with_deps "$dep_name"
        done
    fi
}

# Autodetect modules from currently loaded modules
autodetect_modules() {
    if [[ ! -f /proc/modules ]]; then
        warn "Can't autodetect: /proc/modules not available"
        return
    fi

    info "Autodetecting modules from running system..."
    local count=0
    while read -r modname _rest; do
        modname="${modname//-/_}"
        copy_module_with_deps "$modname"
        ((count++)) || true
    done < /proc/modules
    ok "Autodetected $count modules"
}

# Core modules always needed to mount root
STORAGE_MODULES=(
    # Virtual (QEMU)
    virtio
    virtio_ring
    virtio_pci
    virtio_pci_modern_dev
    virtio_blk

    # SATA/ATA (real hardware)
    libata
    ata_piix
    ahci
    libahci

    # NVMe
    nvme
    nvme_core

    # SD/MMC
    mmc_core
    mmc_block
    sdhci
    sdhci_pci

    # USB storage (needed if root is on USB)
    usbcore
    usb_common
    xhci_hcd
    xhci_pci
    ehci_hcd
    ehci_pci
    usb_storage
    uas

    # SCSI layer
    scsi_mod
    sd_mod
    sr_mod
)

FS_MODULES=(
    ext4
    ext2
    jbd2
    mbcache
    crc32c_generic
    crc16
)

CRYPTO_MODULES=(
    # Needed for ext4 metadata checksums
    crc32c_intel
    crc32c_generic
)

collect_modules() {
    info "Collecting modules..."

    mkdir -p "$WORK_DIR/lib/modules/$KERNEL_VER"

    if $FALLBACK; then
        # Fallback: include everything storage/fs related
        info "Fallback mode: including all storage and filesystem modules..."
        for mod in "${STORAGE_MODULES[@]}" "${FS_MODULES[@]}" "${CRYPTO_MODULES[@]}"; do
            copy_module_with_deps "$mod"
        done

        # Also grab everything under block/ and fs/ subdirs
        find "$MODULES_DIR/kernel/drivers/ata" \
             "$MODULES_DIR/kernel/drivers/scsi" \
             "$MODULES_DIR/kernel/drivers/nvme" \
             "$MODULES_DIR/kernel/drivers/mmc" \
             "$MODULES_DIR/kernel/fs" \
             "$MODULES_DIR/kernel/drivers/virtio" \
             -name "*.ko*" 2>/dev/null | while read -r ko; do
            local rel="${ko#$MODULES_DIR/}"
            local dest="$WORK_DIR/lib/modules/$KERNEL_VER/$rel"
            [[ -f "$dest" ]] && continue
            mkdir -p "$(dirname "$dest")"
            cp "$ko" "$dest"
        done
    else
        # Always include the core storage modules
        for mod in "${STORAGE_MODULES[@]}" "${FS_MODULES[@]}" "${CRYPTO_MODULES[@]}"; do
            copy_module_with_deps "$mod"
        done

        # Autodetect from running system
        autodetect_modules
    fi

    # Extra modules requested by -m flag
    if [[ -n "$EXTRA_MODULES" ]]; then
        info "Adding extra modules from -m flag: $EXTRA_MODULES"
        IFS=',' read -ra EXTRA_LIST <<< "$EXTRA_MODULES"
        for mod in "${EXTRA_LIST[@]}"; do
            mod=$(echo "$mod" | tr -d ' ')
            copy_module_with_deps "$mod"
        done
    fi

    # Persistent extra modules from /etc/ginitrd/modules.conf
    # Format: one module name per line, # = comment
    local GINITRD_MODULES_CONF="/etc/ginitrd/modules.conf"
    if [[ -f "$GINITRD_MODULES_CONF" ]]; then
        info "Loading persistent modules from $GINITRD_MODULES_CONF..."
        local pmod_count=0
        while IFS= read -r line; do
            line=$(echo "$line" | sed 's/#.*//' | tr -d ' \t')
            [[ -z "$line" ]] && continue
            copy_module_with_deps "$line"
            ((pmod_count++)) || true
        done < "$GINITRD_MODULES_CONF"
        ok "Loaded $pmod_count persistent modules from config"
    fi

    # Copy modules metadata files (needed for modprobe to work)
    for f in modules.dep modules.alias modules.symbols modules.builtin modules.order modules.softdep; do
        [[ -f "$MODULES_DIR/$f" ]] && cp "$MODULES_DIR/$f" "$WORK_DIR/lib/modules/$KERNEL_VER/"
    done

    local mod_count
    mod_count=$(find "$WORK_DIR/lib/modules" -name "*.ko*" | wc -l)
    ok "Collected $mod_count modules"
}

# ============================================================
# Step 5: Write the init script
# ============================================================
write_init() {
    info "Writing init script..."

    cat > "$WORK_DIR/init" << 'INIT_EOF'
#!/bin/sh
# ginitrd - Galactica initramfs init
# Mounts essential filesystems, loads modules, finds and mounts root

# Kernel log levels: only show warnings and above during boot
# (uncomment to debug: remove the sysctl line)
# echo "7" > /proc/sys/kernel/printk

mount_pseudo() {
    mount -t proc     proc     /proc     2>/dev/null
    mount -t sysfs    sysfs    /sys      2>/dev/null
    mount -t devtmpfs devtmpfs /dev      2>/dev/null || \
        mount -t tmpfs tmpfs /dev -o mode=755 2>/dev/null
    mount -t devpts   devpts   /dev/pts  -o mode=620 2>/dev/null
    mount -t tmpfs    tmpfs    /run      -o mode=755 2>/dev/null
    mount -t tmpfs    tmpfs    /tmp      2>/dev/null
}

log() {
    echo "[ginitrd] $1"
    echo "[ginitrd] $1" > /dev/kmsg 2>/dev/null || true
}

panic() {
    log "PANIC: $1"
    log "Dropping to emergency shell"
    log "Type 'exit' to retry, or diagnose with: ls /dev, blkid"
    exec /bin/sh
}

# ── Bootstrap ────────────────────────────────────────────────
mount_pseudo

# Suppress kernel messages to console during boot (cleaner output)
echo "3" > /proc/sys/kernel/printk 2>/dev/null || true

log "Galactica initramfs starting..."
log "Kernel: $(uname -r)"

# ── Load modules ─────────────────────────────────────────────
load_modules() {
    local KERNEL_VER
    KERNEL_VER=$(uname -r)
    local MOD_DIR="/lib/modules/$KERNEL_VER"

    [ -d "$MOD_DIR" ] || { log "No modules dir: $MOD_DIR"; return; }

    # Use depmod-generated order if available
    if [ -f "$MOD_DIR/modules.order" ]; then
        while IFS= read -r rel; do
            local ko="$MOD_DIR/$rel"
            [ -f "$ko" ] || continue
            local name
            name=$(basename "$ko" | sed 's/\.ko.*//')
            insmod "$ko" 2>/dev/null && log "loaded: $name" || true
        done < "$MOD_DIR/modules.order"
    else
        # Fallback: load in dependency order manually
        # virtio core first
        for mod in virtio virtio_ring virtio_pci virtio_pci_modern_dev; do
            ko=$(find "$MOD_DIR" -name "${mod}.ko*" | head -1)
            [ -n "$ko" ] && insmod "$ko" 2>/dev/null || true
        done

        # Storage
        for mod in libata ata_piix ahci libahci virtio_blk \
                   nvme_core nvme scsi_mod sd_mod \
                   usbcore usb_common xhci_hcd xhci_pci usb_storage uas \
                   mmc_core mmc_block sdhci sdhci_pci; do
            ko=$(find "$MOD_DIR" -name "${mod}.ko*" | head -1)
            [ -n "$ko" ] && insmod "$ko" 2>/dev/null || true
        done

        # Filesystems
        for mod in crc32c_generic crc32c_intel mbcache crc16 jbd2 ext4; do
            ko=$(find "$MOD_DIR" -name "${mod}.ko*" | head -1)
            [ -n "$ko" ] && insmod "$ko" 2>/dev/null || true
        done
    fi

    log "Module loading complete"
}

load_modules

# Wait for block devices to settle after module loading
sleep 1

# Trigger udev-style device detection if mdev is available
if [ -x /bin/mdev ]; then
    echo /bin/mdev > /proc/sys/kernel/hotplug 2>/dev/null || true
    mdev -s 2>/dev/null || true
fi

# ── Parse kernel cmdline ──────────────────────────────────────
ROOT_DEVICE=""
ROOT_FSTYPE="ext4"
ROOT_FLAGS="ro"
INIT="/sbin/init"

for param in $(cat /proc/cmdline); do
    case "$param" in
        root=UUID=*)   ROOT_DEVICE=$(findfs "UUID=${param#root=UUID=}" 2>/dev/null) ;;
        root=LABEL=*)  ROOT_DEVICE=$(findfs "LABEL=${param#root=LABEL=}" 2>/dev/null) ;;
        root=*)        ROOT_DEVICE="${param#root=}" ;;
        rootfstype=*)  ROOT_FSTYPE="${param#rootfstype=}" ;;
        rootflags=*)   ROOT_FLAGS="${param#rootflags=}" ;;
        rw)            ROOT_FLAGS="rw" ;;
        ro)            ROOT_FLAGS="ro" ;;
        init=*)        INIT="${param#init=}" ;;
    esac
done

log "Root device: ${ROOT_DEVICE:-not set}"
log "Root fstype: $ROOT_FSTYPE"

# ── Wait for root device ──────────────────────────────────────
wait_for_device() {
    local device="$1"
    local timeout=20
    local i=0

    while [ $i -lt $timeout ]; do
        [ -b "$device" ] && return 0
        sleep 1
        i=$((i + 1))
        log "Waiting for $device... ($i/$timeout)"

        # Re-trigger device detection
        [ -x /bin/mdev ] && mdev -s 2>/dev/null || true
    done

    return 1
}

# If root not specified, try to autodetect
if [ -z "$ROOT_DEVICE" ]; then
    log "root= not set, attempting autodetect..."

    # Wait a moment for devices to appear
    sleep 2
    [ -x /bin/mdev ] && mdev -s 2>/dev/null || true

    # Try common virtio/sata paths
    for candidate in /dev/vda3 /dev/vda1 /dev/sda3 /dev/sda1 \
                     /dev/nvme0n1p3 /dev/nvme0n1p1 /dev/mmcblk0p3; do
        if [ -b "$candidate" ]; then
            # Check it has a filesystem
            if blkid "$candidate" > /dev/null 2>&1; then
                ROOT_DEVICE="$candidate"
                log "Autodetected root: $ROOT_DEVICE"
                break
            fi
        fi
    done
fi

[ -z "$ROOT_DEVICE" ] && panic "No root device found. Boot with root=/dev/sdXN or root=UUID=..."

wait_for_device "$ROOT_DEVICE" || panic "Root device $ROOT_DEVICE did not appear"

# ── Mount root ────────────────────────────────────────────────
log "Mounting root: $ROOT_DEVICE ($ROOT_FSTYPE, $ROOT_FLAGS)"

if ! mount -t "$ROOT_FSTYPE" -o "$ROOT_FLAGS" "$ROOT_DEVICE" /mnt/root 2>/dev/null; then
    # Try without specifying fstype
    log "Typed mount failed, trying auto..."
    mount -o "$ROOT_FSTYPE" "$ROOT_DEVICE" /mnt/root 2>/dev/null || \
    mount "$ROOT_DEVICE" /mnt/root || \
    panic "Failed to mount $ROOT_DEVICE"
fi

log "Root mounted successfully"

# Verify the mounted root looks valid
[ -d /mnt/root/sbin ] || [ -d /mnt/root/usr/sbin ] || \
    panic "Mounted root doesn't look like a valid system (no /sbin or /usr/sbin)"

# ── Switch root ───────────────────────────────────────────────
log "Switching to real root, starting $INIT"

# Move pseudo-filesystems into the new root
mount --move /proc /mnt/root/proc 2>/dev/null || true
mount --move /sys  /mnt/root/sys  2>/dev/null || true
mount --move /dev  /mnt/root/dev  2>/dev/null || true
mount --move /run  /mnt/root/run  2>/dev/null || true

exec switch_root /mnt/root "$INIT"

# Should never reach here
panic "switch_root failed"
INIT_EOF

    chmod 755 "$WORK_DIR/init"
    ok "Init script written"
}

# ============================================================
# Step 6: Device nodes (fallback if devtmpfs unavailable)
# ============================================================
create_dev_nodes() {
    info "Creating device nodes..."
    cd "$WORK_DIR/dev"
    mknod -m 600 console c 5 1  2>/dev/null || true
    mknod -m 666 null    c 1 3  2>/dev/null || true
    mknod -m 666 zero    c 1 5  2>/dev/null || true
    mknod -m 666 urandom c 1 9  2>/dev/null || true
    mknod -m 666 tty     c 5 0  2>/dev/null || true
    mknod -m 666 kmsg    c 1 11 2>/dev/null || true
    cd - > /dev/null
    ok "Device nodes created"
}

# ============================================================
# Step 7: Pack into cpio archive and compress
# ============================================================
pack_initramfs() {
    info "Packing initramfs..."

    mkdir -p "$(dirname "$OUTPUT")"

    local tmp_cpio="$WORK_DIR/initramfs.cpio"

    # Build cpio — must be run from inside the work dir
    (
        cd "$WORK_DIR"
        find . | sort | cpio -H newc -o --quiet > "$tmp_cpio"
    )

    local raw_size
    raw_size=$(du -sh "$tmp_cpio" | cut -f1)
    info "Uncompressed size: $raw_size"

    case "$COMPRESS" in
        zstd)
            if command -v zstd &>/dev/null; then
                zstd -9 -q -o "$OUTPUT" "$tmp_cpio"
            else
                warn "zstd not found, falling back to gzip"
                gzip -9 -c "$tmp_cpio" > "$OUTPUT"
            fi
            ;;
        gzip)
            gzip -9 -c "$tmp_cpio" > "$OUTPUT"
            ;;
        none)
            cp "$tmp_cpio" "$OUTPUT"
            ;;
        *)
            die "Unknown compression: $COMPRESS (use zstd, gzip, or none)"
            ;;
    esac

    local final_size
    final_size=$(du -sh "$OUTPUT" | cut -f1)
    ok "Initramfs packed: $OUTPUT ($final_size)"
}

# ============================================================
# Step 8: Update grub.cfg to reflect the new initramfs
# ============================================================
update_grub() {
    # Find grub.cfg — check both BIOS and UEFI locations
    local grub_cfg=""
    for candidate in \
        /boot/grub/grub.cfg \
        /boot/grub2/grub.cfg \
        /boot/efi/EFI/Galactica/grub.cfg \
        /boot/efi/EFI/galactica/grub.cfg; do
        if [[ -f "$candidate" ]]; then
            grub_cfg="$candidate"
            break
        fi
    done

    if [[ -z "$grub_cfg" ]]; then
        warn "grub.cfg not found — skipping GRUB update"
        warn "Manually add:  initrd /$(basename "$OUTPUT")"
        return 0
    fi

    info "Updating $grub_cfg..."

    local initrd_name
    initrd_name=$(basename "$OUTPUT")

    # Check if this is a fallback image
    if $FALLBACK; then
        # For fallback: update or insert initrd line in fallback menuentry
        if grep -q "fallback initramfs" "$grub_cfg"; then
            # Update existing fallback entry's initrd line
            sed -i "/fallback initramfs/,/^}/ s|initrd .*|initrd /$initrd_name|" "$grub_cfg"
            ok "Updated fallback initrd line in $grub_cfg"
        else
            # No fallback entry exists yet — append one
            # Get root UUID from the existing normal entry
            local uuid
            uuid=$(grep -oP 'root=UUID=\K[^ ]+' "$grub_cfg" | head -1)
            if [[ -n "$uuid" ]]; then
                cat >> "$grub_cfg" << GRUBEOF

menuentry "Galactica Linux (fallback initramfs)" {
    linux  /vmlinuz-galactica root=UUID=$uuid rw
    initrd /$initrd_name
}
GRUBEOF
                ok "Appended fallback menuentry to $grub_cfg"
            else
                warn "Could not find UUID in existing grub.cfg — skipping fallback entry"
            fi
        fi
    else
        # For normal image: update or insert initrd line in first/normal menuentry
        if grep -q "initrd" "$grub_cfg"; then
            # Update the first initrd line (normal entry)
            # Use awk to only replace the first occurrence
            awk -v img="/$initrd_name" '
                /initrd / && !done && !/fallback/ {
                    sub(/initrd .*/, "initrd " img)
                    done=1
                }
                { print }
            ' "$grub_cfg" > "${grub_cfg}.tmp" && mv "${grub_cfg}.tmp" "$grub_cfg"
            ok "Updated initrd line in $grub_cfg"
        else
            # No initrd line exists — insert one after the linux line in the first menuentry
            awk -v img="/$initrd_name" '
                /^\s*linux / && !done {
                    print
                    print "    initrd " img
                    done=1
                    next
                }
                { print }
            ' "$grub_cfg" > "${grub_cfg}.tmp" && mv "${grub_cfg}.tmp" "$grub_cfg"
            ok "Inserted initrd line into $grub_cfg"
        fi
    fi

    # Patch kernel cmdline params from /etc/ginitrd/cmdline.conf
    # Format: one param per line, # = comment. Example: nvidia_drm.modeset=1
    local CMDLINE_CONF="/etc/ginitrd/cmdline.conf"
    if [[ -f "$CMDLINE_CONF" ]]; then
        info "Applying persistent cmdline params from $CMDLINE_CONF..."
        while IFS= read -r param; do
            param=$(echo "$param" | sed 's/#.*//' | tr -d ' \t\r')
            [[ -z "$param" ]] && continue
            if grep -q "$param" "$grub_cfg" 2>/dev/null; then
                vlog "cmdline param already present: $param"
            else
                sed -i "s|^\(\s*linux .*\)|\1 $param|" "$grub_cfg"
                vlog "Added cmdline param: $param"
            fi
        done < "$CMDLINE_CONF"
        ok "Cmdline params applied"
    fi

    vlog "grub.cfg after update:"
    $VERBOSE && cat "$grub_cfg" || true
}

# ============================================================
# Step 9: Install modprobe.d configs into initramfs
# Ensures blacklists (e.g. nouveau) and module options apply at early boot
# ============================================================
install_modprobe_configs() {
    local MODPROBE_SRC="/etc/ginitrd/modprobe.d"
    local MODPROBE_DST="$WORK_DIR/etc/modprobe.d"

    mkdir -p "$MODPROBE_DST"
    local copied=0

    # ginitrd-specific overrides first
    if [[ -d "$MODPROBE_SRC" ]]; then
        for f in "$MODPROBE_SRC"/*.conf; do
            [[ -f "$f" ]] || continue
            cp "$f" "$MODPROBE_DST/"
            vlog "modprobe config: $f"
            ((copied++)) || true
        done
    fi

    # Also pull relevant configs from system /etc/modprobe.d
    for f in /etc/modprobe.d/blacklist*.conf /etc/modprobe.d/nvidia*.conf              /etc/modprobe.d/nouveau*.conf /etc/modprobe.d/options*.conf; do
        [[ -f "$f" ]] || continue
        local fname; fname=$(basename "$f")
        [[ -f "$MODPROBE_DST/$fname" ]] && continue  # don't overwrite ginitrd versions
        cp "$f" "$MODPROBE_DST/"
        vlog "system modprobe config: $f"
        ((copied++)) || true
    done

    [[ $copied -gt 0 ]] && ok "Installed $copied modprobe.d config(s) into initramfs"
}

# ============================================================
# Main
# ============================================================
echo ""
echo -e "${CYAN}ginitrd v$VERSION - Galactica Initramfs Builder${NC}"
echo -e "${CYAN}$(printf '=%.0s' {1..45})${NC}"
echo ""
info "Kernel:     $KERNEL_VER"
info "Output:     $OUTPUT"
info "Compress:   $COMPRESS"
info "Fallback:   $FALLBACK"
[[ -n "$ROOT_DEVICE" ]] && info "Root hint:  $ROOT_DEVICE"
[[ -n "$EXTRA_MODULES" ]] && info "Extra mods: $EXTRA_MODULES"
echo ""

[[ $EUID -ne 0 ]] && die "Must run as root (needed for mknod)"

build_structure
install_busybox
install_libs
collect_modules
install_modprobe_configs
write_init
create_dev_nodes
pack_initramfs
update_grub

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
