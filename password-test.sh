#!/bin/bash
# Test the password hash without booting

set -e

echo "=== Testing Password Hash ==="
echo ""

# Get the hash from rootfs
ROOTFS="galactica-rootfs.img"

if [[ ! -f "$ROOTFS" ]]; then
    echo "Error: $ROOTFS not found"
    exit 1
fi

echo "Step 1: Extracting hash from rootfs..."
sudo mkdir -p /mnt/test-hash
sudo mount -o loop "$ROOTFS" /mnt/test-hash

SHADOW_HASH=$(sudo cat /mnt/test-hash/etc/shadow | grep '^root:' | cut -d: -f2)
echo "  Hash: $SHADOW_HASH"

sudo umount /mnt/test-hash
sudo rmdir /mnt/test-hash

echo ""
echo "Step 2: Testing with mkpasswd (if available)..."

if command -v mkpasswd &> /dev/null; then
    TEST_RESULT=$(mkpasswd -m sha-512 -S galactica galactica)
    if [[ "$TEST_RESULT" == "$SHADOW_HASH" ]]; then
        echo "  ✓ Password 'galactica' matches! Login will work."
    else
        echo "  ✗ Hashes don't match"
        echo "    In shadow: $SHADOW_HASH"
        echo "    Generated: $TEST_RESULT"
    fi
else
    echo "  mkpasswd not found, trying openssl..."
fi

echo ""
echo "Step 3: Testing with openssl..."

OPENSSL_HASH=$(openssl passwd -6 -salt galactica galactica)
if [[ "$OPENSSL_HASH" == "$SHADOW_HASH" ]]; then
    echo "  ✓ Password 'galactica' matches! Login will work."
else
    echo "  ✗ Hashes don't match"
    echo "    In shadow: $SHADOW_HASH"
    echo "    Generated: $OPENSSL_HASH"
fi

echo ""
echo "Step 4: Manual verification with chroot (requires your system utilities)..."

# Create a test chroot environment
sudo mkdir -p /mnt/test-chroot
sudo mount -o loop "$ROOTFS" /mnt/test-chroot

echo ""
echo "Checking if we can verify with the system's login tools..."

# Try to use the host's crypt library to verify
cat > /tmp/test_crypt.c << 'EOFC'
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <crypt.h>
#include <unistd.h>

int main() {
    char *password = "galactica";
    char *hash = "$SHADOW_HASH_PLACEHOLDER";
    
    char *result = crypt(password, hash);
    
    if (result == NULL) {
        fprintf(stderr, "crypt() failed\n");
        return 1;
    }
    
    if (strcmp(result, hash) == 0) {
        printf("✓ Password verification SUCCESSFUL\n");
        printf("  The password 'galactica' will work in the VM\n");
        return 0;
    } else {
        printf("✗ Password verification FAILED\n");
        printf("  Expected: %s\n", hash);
        printf("  Got:      %s\n", result);
        return 1;
    }
}
EOFC

# Replace placeholder with actual hash
sed -i "s|\$SHADOW_HASH_PLACEHOLDER|$SHADOW_HASH|g" /tmp/test_crypt.c

# Compile and run
if gcc /tmp/test_crypt.c -o /tmp/test_crypt -lcrypt 2>/dev/null; then
    echo ""
    /tmp/test_crypt
    TEST_RESULT=$?
    rm /tmp/test_crypt /tmp/test_crypt.c
    
    sudo umount /mnt/test-chroot
    sudo rmdir /mnt/test-chroot
    
    echo ""
    if [[ $TEST_RESULT -eq 0 ]]; then
        echo "=== ✓ Password Test PASSED ==="
        echo ""
        echo "The password 'galactica' will work when you boot!"
        echo "Safe to run: ./run-galactica.sh"
    else
        echo "=== ✗ Password Test FAILED ==="
        echo ""
        echo "The password may not work. Consider regenerating:"
        echo "  ./quick-fix-password.sh"
    fi
else
    echo "  Could not compile test program (missing gcc or libcrypt)"
    sudo umount /mnt/test-chroot
    sudo rmdir /mnt/test-chroot
    
    echo ""
    echo "=== Test Summary ==="
    echo ""
    echo "Hash in shadow file: $SHADOW_HASH"
    echo "Generated with openssl: $OPENSSL_HASH"
    echo ""
    if [[ "$OPENSSL_HASH" == "$SHADOW_HASH" ]]; then
        echo "✓ Hashes match - password should work"
    else
        echo "✗ Hashes don't match - password may not work"
    fi
fi

echo ""
