#!/bin/bash
# Fix shadow file and setup multi-TTY login for Galactica
set -e

ROOTFS="${1:-galactica-rootfs.img}"

if [[ ! -f "$ROOTFS" ]]; then
    echo "Error: $ROOTFS not found"
    exit 1
fi

echo "=== Fixing Galactica Login ==="

MOUNT_POINT="/tmp/galactica-login-fix"
mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$ROOTFS" "$MOUNT_POINT"

trap "sudo umount $MOUNT_POINT 2>/dev/null; rmdir $MOUNT_POINT 2>/dev/null" EXIT

# 1. Fix/regenerate shadow file with correct format
echo ""
echo "[1] Fixing /etc/shadow..."

# Generate proper password hash for 'galactica'
HASH=$(openssl passwd -6 -salt "galactica" "galactica")

echo "  Password hash: $HASH"

# Check if hash starts with $ (valid) or something else
if [[ "$HASH" != \$* ]]; then
    echo "  ERROR: Hash generation failed!"
    exit 1
fi

# Create proper shadow file
sudo tee "$MOUNT_POINT/etc/shadow" > /dev/null << EOF
root:${HASH}:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF

sudo chmod 600 "$MOUNT_POINT/etc/shadow"
sudo chown root:root "$MOUNT_POINT/etc/shadow"

echo "  ✓ Shadow file fixed"

# Verify the shadow file
echo ""
echo "  Verifying shadow file:"
sudo cat "$MOUNT_POINT/etc/shadow" | head -1 | cut -d: -f1-2 | sed 's/:/:.../'
echo ""

# 2. Create proper passwd file
echo "[2] Fixing /etc/passwd..."

sudo tee "$MOUNT_POINT/etc/passwd" > /dev/null << 'EOF'
root:x:0:0:root:/root:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

sudo chmod 644 "$MOUNT_POINT/etc/passwd"
echo "  ✓ Passwd file fixed"

# 3. Create proper group file
echo "[3] Fixing /etc/group..."

sudo tee "$MOUNT_POINT/etc/group" > /dev/null << 'EOF'
root:x:0:
tty:x:5:
nogroup:x:65534:
EOF

sudo chmod 644 "$MOUNT_POINT/etc/group"
echo "  ✓ Group file fixed"

# 4. Create TTY service files for AirRide
echo ""
echo "[4] Creating TTY services..."

# Serial console (ttyS0) - this is the default
sudo tee "$MOUNT_POINT/etc/airride/services/ttyS0.service" > /dev/null << 'EOF'
[Service]
name=ttyS0
description=Serial Console Login
type=simple
exec_start=/sbin/poyo /dev/ttyS0
autostart=true
restart=always
restart_delay=2
foreground=true

[Dependencies]
EOF
echo "  ✓ ttyS0.service created"

# Virtual console 1 (tty1)
sudo tee "$MOUNT_POINT/etc/airride/services/tty1.service" > /dev/null << 'EOF'
[Service]
name=tty1
description=Virtual Console 1 Login
type=simple
exec_start=/sbin/poyo /dev/tty1
autostart=true
restart=always
restart_delay=2
foreground=true
parallel=true

[Dependencies]
after=hostname
EOF
echo "  ✓ tty1.service created"

# Remove old getty service that might conflict
sudo rm -f "$MOUNT_POINT/etc/airride/services/getty.service"

# 5. Create hostname service
echo ""
echo "[5] Creating hostname service..."

sudo tee "$MOUNT_POINT/etc/airride/services/hostname.service" > /dev/null << 'EOF'
[Service]
name=hostname
description=Set System Hostname
type=oneshot
exec_start=/bin/hostname galactica
autostart=true
parallel=true

[Dependencies]
EOF
echo "  ✓ hostname.service created"

# 6. Set hostname
echo "galactica" | sudo tee "$MOUNT_POINT/etc/hostname" > /dev/null
sudo tee "$MOUNT_POINT/etc/hosts" > /dev/null << 'EOF'
127.0.0.1   localhost galactica
::1         localhost
EOF
echo "  ✓ Hostname configured"

# 7. Create device nodes for TTYs
echo ""
echo "[6] Creating TTY device nodes..."

sudo mkdir -p "$MOUNT_POINT/dev"
sudo mknod -m 620 "$MOUNT_POINT/dev/tty0" c 4 0 2>/dev/null || true
sudo mknod -m 620 "$MOUNT_POINT/dev/tty1" c 4 1 2>/dev/null || true
sudo mknod -m 620 "$MOUNT_POINT/dev/tty2" c 4 2 2>/dev/null || true
sudo mknod -m 660 "$MOUNT_POINT/dev/ttyS0" c 4 64 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_POINT/dev/tty" c 5 0 2>/dev/null || true
sudo mknod -m 600 "$MOUNT_POINT/dev/console" c 5 1 2>/dev/null || true
echo "  ✓ TTY devices created"

# 8. Update startgui script
echo ""
echo "[7] Updating GUI starter..."

sudo tee "$MOUNT_POINT/usr/bin/startgui" > /dev/null << 'EOF'
#!/bin/sh
# Galactica GUI Starter

hostname galactica 2>/dev/null || true

export DISPLAY=:0
export HOME="${HOME:-/root}"
export XAUTHORITY="$HOME/.Xauthority"

echo "Available graphics devices:"
ls -la /dev/dri/ 2>/dev/null || echo "  No DRI devices"
ls -la /dev/fb* 2>/dev/null || echo "  No framebuffer"

touch "$XAUTHORITY"

echo ""
echo "Starting X... (check /var/log/Xorg.0.log if it fails)"
echo ""

cd "$HOME"
exec startx "$HOME/.xinitrc" -- -keeptty 2>&1
EOF
sudo chmod 755 "$MOUNT_POINT/usr/bin/startgui"
echo "  ✓ startgui updated"

# 9. Fix xinitrc for fonts
echo ""
echo "[8] Fixing .xinitrc..."

sudo tee "$MOUNT_POINT/root/.xinitrc" > /dev/null << 'EOF'
#!/bin/sh
xsetroot -solid "#1e1e2e" 2>/dev/null &

if command -v twm >/dev/null 2>&1; then
    twm &
fi

# Use default font (no -fa option)
exec xterm -bg black -fg white -geometry 100x30
EOF
sudo chmod 755 "$MOUNT_POINT/root/.xinitrc"
echo "  ✓ .xinitrc fixed"

echo ""
echo "=== Fix Complete ==="
echo ""
echo "Login credentials:"
echo "  Username: root"
echo "  Password: galactica"
echo ""
echo "TTY services configured:"
echo "  - ttyS0 (serial console)"
echo "  - tty1  (virtual console)"
echo ""
echo "To test, run:"
echo "  ./run-galactica.sh"
