#!/bin/bash
# Fix shutdown, users, and permissions
set -e

ROOTFS="${1:-galactica-rootfs.img}"
[[ -f "$ROOTFS" ]] || { echo "Usage: $0 <rootfs.img>"; exit 1; }

MNT="/tmp/fix-shutdown-$$"
mkdir -p "$MNT"
sudo mount -o loop "$ROOTFS" "$MNT"
trap "sudo umount '$MNT'; rmdir '$MNT'" EXIT

echo "=== Fixing Galactica ==="

# Create poweroff/reboot/halt scripts
echo "[1] Adding shutdown commands..."
sudo tee "$MNT/sbin/poweroff" > /dev/null << 'EOF'
#!/bin/sh
echo "Syncing disks..."
sync
sync
echo "Powering off..."
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo o > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox poweroff -f
EOF

sudo tee "$MNT/sbin/halt" > /dev/null << 'EOF'
#!/bin/sh
exec /sbin/poweroff "$@"
EOF

sudo tee "$MNT/sbin/reboot" > /dev/null << 'EOF'
#!/bin/sh
echo "Syncing disks..."
sync
sync
echo "Rebooting..."
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo s > /proc/sysrq-trigger 2>/dev/null
echo b > /proc/sysrq-trigger 2>/dev/null
sleep 1
busybox reboot -f
EOF

sudo tee "$MNT/sbin/shutdown" > /dev/null << 'EOF'
#!/bin/sh
case "$1" in
    -r) exec /sbin/reboot ;;
    -h|-P|*) exec /sbin/poweroff ;;
esac
EOF

sudo chmod 755 "$MNT/sbin/poweroff" "$MNT/sbin/halt" "$MNT/sbin/reboot" "$MNT/sbin/shutdown"

# Fix groups
echo "[2] Creating groups..."
sudo tee "$MNT/etc/group" > /dev/null << 'EOF'
root:x:0:
tty:x:5:link
wheel:x:10:link
audio:x:11:link
video:x:12:link
input:x:13:link
users:x:100:link
nogroup:x:65534:
EOF

# Fix passwd
echo "[3] Creating users..."
sudo tee "$MNT/etc/passwd" > /dev/null << 'EOF'
root:x:0:0:root:/root:/bin/sh
link:x:1000:100:Link:/home/link:/bin/sh
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

# Fix shadow (root=galactica, link=lonk)
echo "[4] Setting passwords..."
ROOT_HASH=$(openssl passwd -6 -salt galactica galactica)
LINK_HASH=$(openssl passwd -6 -salt link lonk)
sudo tee "$MNT/etc/shadow" > /dev/null << EOF
root:${ROOT_HASH}:19000:0:99999:7:::
link:${LINK_HASH}:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF
sudo chmod 600 "$MNT/etc/shadow"

# Create home directory
echo "[5] Creating home directory..."
sudo mkdir -p "$MNT/home/link"
sudo cp -a "$MNT/root/.xinitrc" "$MNT/home/link/.xinitrc" 2>/dev/null || true
sudo chown -R 1000:100 "$MNT/home/link"
sudo chmod 755 "$MNT/home/link"

# Fix input device permissions on boot
echo "[6] Adding input device fix to startup..."
sudo tee "$MNT/etc/airride/services/input-perms.service" > /dev/null << 'EOF'
[Service]
name=input-perms
description=Fix input device permissions
type=oneshot
exec_start=/bin/sh -c "chmod 666 /dev/input/event* 2>/dev/null; chmod 666 /dev/tty* 2>/dev/null"
autostart=true
parallel=true

[Dependencies]
EOF

echo ""
echo "=== Done ==="
echo "Users:"
echo "  root / galactica"
echo "  link / lonk"
echo ""
echo "Remember: use 'poweroff' or 'sync' before closing QEMU"
