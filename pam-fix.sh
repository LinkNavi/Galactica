#!/bin/bash
# Verify and fix the root password in /etc/shadow

set -e

echo "=== Galactica Password Fix ==="
echo ""
echo "This will verify and fix the root password in your rootfs."
echo "Target password: galactica"
echo ""

# Generate the correct password hash
echo "Step 1: Generating correct password hash..."
CORRECT_HASH=$(openssl passwd -6 -salt galactica galactica)
echo "  Hash: $CORRECT_HASH"
echo ""

# Check build directory
BUILD_SHADOW="./galactica-build/etc/shadow"
if [[ -f "$BUILD_SHADOW" ]]; then
    echo "Step 2: Checking build directory shadow file..."
    CURRENT_HASH=$(grep '^root:' "$BUILD_SHADOW" | cut -d: -f2)
    echo "  Current hash: $CURRENT_HASH"
    
    if [[ "$CURRENT_HASH" == "$CORRECT_HASH" ]]; then
        echo "  ✓ Build directory password is correct"
    else
        echo "  ✗ Build directory password is WRONG"
        echo "  Fixing..."
        cat > "$BUILD_SHADOW" << EOF
root:$CORRECT_HASH:19000:0:99999:7:::
EOF
        chmod 600 "$BUILD_SHADOW"
        echo "  ✓ Fixed build directory"
    fi
else
    echo "  ! Build shadow file not found"
fi

echo ""

# Check rootfs
ROOTFS="./galactica-rootfs.img"
if [[ -f "$ROOTFS" ]]; then
    echo "Step 3: Checking rootfs shadow file..."
    
    mkdir -p /tmp/shadow-fix
    sudo mount -o loop "$ROOTFS" /tmp/shadow-fix
    
    ROOTFS_HASH=$(sudo grep '^root:' /tmp/shadow-fix/etc/shadow | cut -d: -f2)
    echo "  Current hash: $ROOTFS_HASH"
    
    if [[ "$ROOTFS_HASH" == "$CORRECT_HASH" ]]; then
        echo "  ✓ Rootfs password is correct"
    else
        echo "  ✗ Rootfs password is WRONG"
        echo "  Fixing..."
        sudo tee /tmp/shadow-fix/etc/shadow > /dev/null << EOF
root:$CORRECT_HASH:19000:0:99999:7:::
EOF
        sudo chmod 600 /tmp/shadow-fix/etc/shadow
        echo "  ✓ Fixed rootfs"
    fi
    
    sudo umount /tmp/shadow-fix
    rmdir /tmp/shadow-fix
else
    echo "  ! Rootfs image not found"
fi

echo ""
echo "=== Password Verification Complete ==="
echo ""
echo "Testing the hash manually:"
echo ""

# Test with Python
python3 << 'PYEOF'
import crypt

password = "galactica"
hash_from_shadow = "$CORRECT_HASH"

# Test if password matches
result = crypt.crypt(password, hash_from_shadow)
if result == hash_from_shadow:
    print("  ✓ Password 'galactica' matches the hash")
else:
    print("  ✗ Password 'galactica' does NOT match")
    print(f"    Expected: {hash_from_shadow}")
    print(f"    Got:      {result}")
PYEOF

echo ""
echo "Now test your system:"
echo "  ./run-galactica.sh"
echo ""
echo "Login with:"
echo "  Username: root"
echo "  Password: galactica"
echo ""
