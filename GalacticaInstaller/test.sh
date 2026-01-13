#!/bin/bash
# test-installer-loop.sh

# Create a 10GB disk image
dd if=/dev/zero of=test-disk.img bs=1M count=10240

# Setup loop device
sudo losetup -fP test-disk.img

# Find which loop device was created
LOOP_DEV=$(sudo losetup -j test-disk.img | cut -d: -f1)
echo "Created loop device: $LOOP_DEV"

# Now run your installer
sudo go run ./src/

# After testing, cleanup:
# sudo losetup -d $LOOP_DEV
# rm test-disk.img
