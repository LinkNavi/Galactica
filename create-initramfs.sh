#!/bin/bash
# Generate initramfs for Galactica

set -e

TARGET_ROOT="./galactica-build"
INITRAMFS_DIR="./initramfs-build"
OUTPUT="galactica-initramfs.cpio.gz"

echo "Creating initramfs..."

# Create temporary directory
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"

cd "$INITRAMFS_DIR"

# Create basic structure
mkdir -p {bin,sbin,etc,proc,sys,dev,run,tmp,lib,lib64,usr/bin,usr/sbin}

# Copy init (AirRide)
cp ../"$TARGET_ROOT"/sbin/airride sbin/init

# Copy essential binaries (if you have them)
if [[ -f ../"$TARGET_ROOT"/bin/sh ]]; then
    cp ../"$TARGET_ROOT"/bin/sh bin/
fi

# Copy libraries needed by init
if command -v ldd &>/dev/null; then
    echo "Copying libraries for init..."
    for lib in $(ldd ../galactica-build/sbin/airride | grep -o '/lib[^ ]*'); do
        if [[ -f "$lib" ]]; then
            mkdir -p ".$(dirname $lib)"
            cp "$lib" ".$lib" 2>/dev/null || true
        fi
    done
fi

# Create device nodes
sudo mknod -m 600 dev/console c 5 1
sudo mknod -m 666 dev/null c 1 3
sudo mknod -m 666 dev/zero c 1 5
sudo mknod -m 666 dev/tty c 5 0

# Create init script wrapper (optional)
cat > init << 'EOF'
#!/sbin/init
# This is executed as PID 1
exec /sbin/init "$@"
EOF
chmod +x init

# Generate cpio archive
echo "Creating cpio archive..."
find . -print0 | cpio --null --create --verbose --format=newc | gzip -9 > "../$OUTPUT"

cd ..
echo "Initramfs created: $OUTPUT"
echo "Size: $(du -h $OUTPUT | cut -f1)"
