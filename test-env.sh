#!/bin/bash
# test-env.sh - Build a Galactica test rootfs and boot it in QEMU
set -euo pipefail

TESTROOT="/tmp/galactica-testenv"
IMG="/tmp/galactica-testenv.img"
IMG_SIZE="4G"

require() { command -v "$1" &>/dev/null || { echo "ERROR: $1 not found"; exit 1; }; }

if [[ "${1:-}" == "clean" ]]; then
    rm -rf "$TESTROOT" "$IMG"
    echo "Cleaned."
    exit 0
fi

if [[ "${1:-}" == "boot" ]]; then
    [[ -f "$IMG" ]] || { echo "No image found, run without args first"; exit 1; }
    exec qemu-system-x86_64 \
        -m 2G -smp 2 \
        -drive file="$IMG",format=raw,if=virtio \
        -display gtk -vga virtio \
        -usb -device usb-tablet \
        -netdev user,id=net0 -device e1000,netdev=net0 \
        -no-reboot
fi

require qemu-system-x86_64
require qemu-img
require openssl
require grub-install

echo "==> Building Galactica test rootfs..."
rm -rf "$TESTROOT"
mkdir -p "$TESTROOT"/{bin,sbin,usr/bin,usr/sbin,etc,lib,lib64,proc,sys,dev,run,tmp,root,home,boot,var/log}
chmod 1777 "$TESTROOT/tmp"
chmod 700  "$TESTROOT/root"

echo "==> Copying busybox..."
cp /bin/busybox "$TESTROOT/bin/busybox"
for cmd in sh ash ls cat echo cp mv rm mkdir mount umount sleep grep sed \
            awk ps kill ln chmod chown ip ping hostname uname tar gzip \
            gunzip touch date mdev; do
    ln -sf busybox "$TESTROOT/bin/$cmd" 2>/dev/null || true
done

echo "==> Building/finding dreamland..."
DREAMLAND=""
for p in /sbin/dreamland /usr/bin/dreamland; do
    [[ -f "$p" ]] && DREAMLAND="$p" && break
done
if [[ -z "$DREAMLAND" ]]; then
    [[ -d Dreamland ]] || { echo "ERROR: no dreamland binary and no Dreamland/ source dir"; exit 1; }
    make -C Dreamland -j$(nproc)
    DREAMLAND="$(find Dreamland -name dreamland -type f | head -1)"
    [[ -f "$DREAMLAND" ]] || { echo "ERROR: dreamland build failed"; exit 1; }
fi
cp "$DREAMLAND" "$TESTROOT/usr/bin/dreamland"
chmod 755 "$TESTROOT/usr/bin/dreamland"
ln -sf dreamland "$TESTROOT/usr/bin/dl"

echo "==> Copying libs..."
cp -a /lib/.   "$TESTROOT/lib/"   2>/dev/null || true
cp -a /lib64/. "$TESTROOT/lib64/" 2>/dev/null || true
[[ -d /usr/lib ]] && { mkdir -p "$TESTROOT/usr/lib"; cp -a /usr/lib/. "$TESTROOT/usr/lib/" 2>/dev/null || true; }

echo "==> Copying curl + certs..."
for p in /usr/bin/curl /bin/curl; do [[ -f "$p" ]] && cp "$p" "$TESTROOT/usr/bin/curl" && break; done
mkdir -p "$TESTROOT/etc/ssl/certs"
for cert in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    [[ -f "$cert" ]] && cp "$cert" "$TESTROOT/etc/ssl/certs/ca-certificates.crt" && break
done
cp /etc/resolv.conf "$TESTROOT/etc/resolv.conf"

echo "==> Setting up users (password: test)..."
cat > "$TESTROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/sh
testuser:x:1000:1000:Test User:/home/testuser:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF
cat > "$TESTROOT/etc/group" << 'EOF'
root:x:0:
wheel:x:10:testuser
testuser:x:1000:
EOF
HASH=$(openssl passwd -6 -salt galactica "test")
printf "root:%s:19000:0:99999:7:::\ntestuser:%s:19000:0:99999:7:::\n" "$HASH" "$HASH" > "$TESTROOT/etc/shadow"
chmod 600 "$TESTROOT/etc/shadow"
mkdir -p "$TESTROOT/home/testuser"
echo "galactica-test" > "$TESTROOT/etc/hostname"

echo "==> Installing packages via chroot..."
mount --bind /proc "$TESTROOT/proc"
mount --bind /sys  "$TESTROOT/sys"
mount --bind /dev  "$TESTROOT/dev"

cleanup_mounts() {
    umount "$TESTROOT/proc" 2>/dev/null || true
    umount "$TESTROOT/sys"  2>/dev/null || true
    umount "$TESTROOT/dev"  2>/dev/null || true
}
trap cleanup_mounts EXIT

chroot "$TESTROOT" /usr/bin/dreamland sync
for pkg in busybox airride poyo ginitrd base-config; do
    echo "--> $pkg"
    chroot "$TESTROOT" /usr/bin/dreamland install "$pkg" || echo "WARNING: $pkg failed"
done

cleanup_mounts
trap - EXIT

echo "==> Creating disk image..."
qemu-img create -f raw "$IMG" "$IMG_SIZE" > /dev/null
LOOP=$(losetup -f)
losetup "$LOOP" "$IMG"
parted -s "$LOOP" mklabel msdos
parted -s -a optimal "$LOOP" mkpart primary ext4 1MiB 100%
parted -s "$LOOP" set 1 boot on
partx -u "$LOOP"; sleep 1
PART="${LOOP}p1"
mkfs.ext4 -F -L GalacticaTest "$PART" > /dev/null 2>&1
MNTDIR=$(mktemp -d)
mount "$PART" "$MNTDIR"
cp -a "$TESTROOT/." "$MNTDIR/"

echo "==> Downloading kernel..."
KVER="6.18.4"
curl -L -o /tmp/gk.tar.gz "https://github.com/LinkNavi/Galactica/releases/download/galactica-kernel-${KVER}/galactica-kernel-${KVER}.tar.gz"
tar -xzf /tmp/gk.tar.gz -C "$MNTDIR/"

echo "==> Installing grub..."
grub-install --target=i386-pc --boot-directory="$MNTDIR/boot" --recheck "$LOOP" 2>/dev/null || true
ROOTUUID=$(blkid -s UUID -o value "$PART")
mkdir -p "$MNTDIR/boot/grub"
cat > "$MNTDIR/boot/grub/grub.cfg" << EOF
set timeout=3
set default=0
menuentry "Galactica Test" {
    search --no-floppy --label --set=root GalacticaTest
    linux /boot/vmlinuz-galactica root=UUID=$ROOTUUID rw console=tty0 quiet
    initrd /boot/initramfs-galactica.img
}
menuentry "Galactica Test (no initrd)" {
    search --no-floppy --label --set=root GalacticaTest
    linux /boot/vmlinuz-galactica root=UUID=$ROOTUUID rw console=tty0
}
EOF

umount "$MNTDIR"; rmdir "$MNTDIR"
losetup -d "$LOOP"

echo ""
echo "==> Done! Login: testuser/test or root/test"
echo ""

qemu-system-x86_64 \
    -m 2G -smp 2 \
    -drive file="$IMG",format=raw,if=virtio \
    -display gtk -vga virtio \
    -usb -device usb-tablet \
    -netdev user,id=net0 -device e1000,netdev=net0 \
    -no-reboot
