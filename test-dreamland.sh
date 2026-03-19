#!/bin/bash
# test-dreamland.sh — Test dreamland package installs in an isolated chroot
set -e

CHROOT_DIR="/tmp/dl-test-$$"
DREAMLAND="${1:-./Dreamland/build/dreamland}"
PKG="${2:-poyo}"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

cleanup() {
    umount "$CHROOT_DIR/proc" 2>/dev/null || true
    umount "$CHROOT_DIR/sys"  2>/dev/null || true
    umount "$CHROOT_DIR/dev"  2>/dev/null || true
    rm -rf "$CHROOT_DIR"
    info "Cleaned up"
}
trap cleanup EXIT

[[ -f "$DREAMLAND" ]] || { err "dreamland not found at $DREAMLAND"; exit 1; }

info "Setting up chroot at $CHROOT_DIR..."
mkdir -p "$CHROOT_DIR"/{bin,sbin,usr/bin,usr/sbin,lib,lib64,etc/ssl/certs,proc,sys,dev,run,tmp,root,home}
chmod 1777 "$CHROOT_DIR/tmp"

copy_libs() {
    local bin="$1"
    ldd "$bin" 2>/dev/null | grep -oP '/\S+\.so\S*' | while read -r lib; do
        [[ -f "$lib" ]] || continue
        local dest="$CHROOT_DIR$lib"
        [[ -f "$dest" ]] && continue
        mkdir -p "$(dirname "$dest")"
        cp -L "$lib" "$dest"
    done
}

# Dynamic linker
for linker in /lib64/ld-linux-x86-64.so.2 /lib/ld-linux-x86-64.so.2; do
    [[ -f "$linker" ]] && {
        mkdir -p "$CHROOT_DIR$(dirname "$linker")"
        cp -L "$linker" "$CHROOT_DIR$linker"
        break
    }
done

# dreamland
cp "$DREAMLAND" "$CHROOT_DIR/usr/bin/dreamland"
chmod 755 "$CHROOT_DIR/usr/bin/dreamland"
ln -sf dreamland "$CHROOT_DIR/usr/bin/dl"
copy_libs "$DREAMLAND"

# /usr/bin/env
for p in /usr/bin/env /bin/env; do
    [[ -f "$p" ]] && { cp "$p" "$CHROOT_DIR/usr/bin/env"; copy_libs "$p"; break; }
done

# curl
for p in /usr/bin/curl /bin/curl; do
    [[ -f "$p" ]] && { cp "$p" "$CHROOT_DIR/usr/bin/curl"; copy_libs "$p"; break; }
done

# busybox
for p in /bin/busybox /usr/bin/busybox; do
    [[ -f "$p" ]] && {
        cp "$p" "$CHROOT_DIR/bin/busybox"
        for cmd in sh bash cp mkdir chmod ln cat install; do
            ln -sf busybox "$CHROOT_DIR/bin/$cmd" 2>/dev/null || true
        done
        for cmd in install cp mkdir chmod ln; do
            ln -sf /bin/busybox "$CHROOT_DIR/usr/bin/$cmd" 2>/dev/null || true
        done
        break
    }
done

# CA certs
for cert in /etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt; do
    [[ -f "$cert" ]] && { cp "$cert" "$CHROOT_DIR/etc/ssl/certs/ca-certificates.crt"; break; }
done

cp /etc/resolv.conf "$CHROOT_DIR/etc/resolv.conf"

mount --bind /proc "$CHROOT_DIR/proc"
mount --bind /sys  "$CHROOT_DIR/sys"
mount --bind /dev  "$CHROOT_DIR/dev"

ok "Chroot ready"

run_in_chroot() {
    chroot "$CHROOT_DIR" /usr/bin/env \
        PATH=/usr/sbin:/usr/bin:/sbin:/bin \
        HOME=/root \
        TERM=linux \
        DREAMLAND_DEBUG=1 \
        "$@"
}

echo ""
info "=== dreamland sync ==="
if run_in_chroot /usr/bin/dreamland sync 2>&1; then
    ok "sync succeeded"
else
    err "sync failed"
    exit 1
fi

echo ""
info "=== dreamland install $PKG ==="
if run_in_chroot /usr/bin/dreamland install "$PKG" 2>&1; then
    ok "install $PKG succeeded"
else
    err "install $PKG failed"
fi

echo ""
info "=== Installed files ==="
find "$CHROOT_DIR/sbin" "$CHROOT_DIR/usr/bin" "$CHROOT_DIR/usr/sbin" "$CHROOT_DIR/bin" \
     -maxdepth 1 -type f 2>/dev/null \
     | grep -vE 'busybox|dreamland|curl|env$' \
     | sed "s|$CHROOT_DIR||" | sort

echo ""
info "=== installed.db ==="
cat "$CHROOT_DIR/root/.local/share/dreamland/installed.db" 2>/dev/null || echo "(empty)"

echo ""
info "=== build dir ==="
find "$CHROOT_DIR/root/.cache/dreamland/build" -maxdepth 3 2>/dev/null \
    | sed "s|$CHROOT_DIR||" | head -30
