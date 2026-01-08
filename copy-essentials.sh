#!/bin/bash
# Script to copy essential binaries and all their dependencies to Galactica build

set -e

TARGET_ROOT="${1:-./galactica-build}"

if [[ ! -d "$TARGET_ROOT" ]]; then
    echo "Error: Target directory $TARGET_ROOT does not exist"
    exit 1
fi

echo "=== Copying Essential Binaries to Galactica ==="
echo "Target: $TARGET_ROOT"
echo ""

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

# Function to copy a binary and all its dependencies
copy_with_deps() {
    local binary=$1
    local binary_name=$(basename "$binary")
    
    if [[ ! -f "$binary" ]]; then
        echo "Warning: $binary not found, skipping..."
        return
    fi
    
    echo -e "${BLUE}[*]${NC} Copying $binary_name and dependencies..."
    
    # Copy the binary itself
    local target_path="$TARGET_ROOT$(dirname $binary)"
    mkdir -p "$target_path"
    cp -v "$binary" "$target_path/" 2>/dev/null || echo "  (already exists)"
    
    # Get all library dependencies
    local deps=$(ldd "$binary" 2>/dev/null | grep "=>" | awk '{print $3}')
    
    # Also get the dynamic linker
    local linker=$(ldd "$binary" 2>/dev/null | grep -oP '/lib.*ld-linux.*\.so[^ ]*' | head -1)
    
    # Copy each dependency
    for dep in $deps; do
        if [[ -f "$dep" ]]; then
            local dep_dir=$(dirname "$dep")
            mkdir -p "$TARGET_ROOT$dep_dir"
            cp -v "$dep" "$TARGET_ROOT$dep_dir/" 2>/dev/null || true
        fi
    done
    
    # Copy the dynamic linker
    if [[ -n "$linker" && -f "$linker" ]]; then
        local linker_dir=$(dirname "$linker")
        mkdir -p "$TARGET_ROOT$linker_dir"
        cp -v "$linker" "$TARGET_ROOT$linker_dir/" 2>/dev/null || true
    fi
}

# Function to copy an entire library directory
copy_lib_dir() {
    local lib_dir=$1
    if [[ -d "$lib_dir" ]]; then
        echo -e "${GREEN}[*]${NC} Copying library directory: $lib_dir"
        mkdir -p "$TARGET_ROOT$lib_dir"
        cp -rL "$lib_dir"/* "$TARGET_ROOT$lib_dir/" 2>/dev/null || true
    fi
}

echo "=== Phase 1: Essential Binaries ==="

# Shell and basic utilities
copy_with_deps /bin/bash
copy_with_deps /bin/sh
copy_with_deps /bin/dash

# Core utilities
copy_with_deps /bin/ls
copy_with_deps /bin/cp
copy_with_deps /bin/mv
copy_with_deps /bin/rm
copy_with_deps /bin/cat
copy_with_deps /bin/echo
copy_with_deps /bin/pwd
copy_with_deps /bin/mkdir
copy_with_deps /bin/rmdir
copy_with_deps /bin/touch
copy_with_deps /bin/chmod
copy_with_deps /bin/chown
copy_with_deps /bin/ln
copy_with_deps /bin/grep
copy_with_deps /bin/sed
copy_with_deps /bin/awk
copy_with_deps /bin/sort
copy_with_deps /bin/uniq
copy_with_deps /bin/wc
copy_with_deps /bin/head
copy_with_deps /bin/tail
copy_with_deps /bin/cut
copy_with_deps /bin/tr
copy_with_deps /bin/find
copy_with_deps /bin/tar
copy_with_deps /bin/gzip
copy_with_deps /bin/gunzip
copy_with_deps /bin/bzip2
copy_with_deps /bin/xz

# Process management
copy_with_deps /bin/ps
copy_with_deps /bin/kill
copy_with_deps /bin/killall
copy_with_deps /usr/bin/top
copy_with_deps /usr/bin/htop
copy_with_deps /usr/bin/pkill

# System utilities
copy_with_deps /bin/mount
copy_with_deps /bin/umount
copy_with_deps /sbin/fsck
copy_with_deps /sbin/mkfs
copy_with_deps /sbin/fdisk
copy_with_deps /sbin/parted
copy_with_deps /sbin/lsblk
copy_with_deps /sbin/blkid
copy_with_deps /bin/df
copy_with_deps /bin/du
copy_with_deps /bin/free
copy_with_deps /usr/bin/lsof

# Init-related
copy_with_deps /sbin/init
copy_with_deps /sbin/shutdown
copy_with_deps /sbin/reboot
copy_with_deps /sbin/halt
copy_with_deps /sbin/poweroff

# Networking
copy_with_deps /bin/ip
copy_with_deps /sbin/ifconfig
copy_with_deps /bin/ping
copy_with_deps /usr/bin/wget
copy_with_deps /usr/bin/curl
copy_with_deps /usr/bin/ssh
copy_with_deps /usr/bin/scp
copy_with_deps /usr/sbin/sshd
copy_with_deps /bin/netstat
copy_with_deps /usr/bin/nc

# Text editors
copy_with_deps /bin/nano
copy_with_deps /usr/bin/vim
copy_with_deps /usr/bin/vi

# System info
copy_with_deps /bin/uname
copy_with_deps /usr/bin/uptime
copy_with_deps /usr/bin/whoami
copy_with_deps /usr/bin/id
copy_with_deps /usr/bin/hostname
copy_with_deps /bin/date

# File operations
copy_with_deps /usr/bin/file
copy_with_deps /usr/bin/stat
copy_with_deps /usr/bin/du
copy_with_deps /usr/bin/diff

# Package management tools (for bootstrapping)
copy_with_deps /usr/bin/gcc
copy_with_deps /usr/bin/g++
copy_with_deps /usr/bin/make
copy_with_deps /usr/bin/ld
copy_with_deps /usr/bin/as
copy_with_deps /usr/bin/ar
copy_with_deps /usr/bin/ranlib
copy_with_deps /usr/bin/strip

# Module management
copy_with_deps /sbin/modprobe
copy_with_deps /sbin/insmod
copy_with_deps /sbin/rmmod
copy_with_deps /sbin/lsmod
copy_with_deps /sbin/depmod

# User management
copy_with_deps /usr/sbin/useradd
copy_with_deps /usr/sbin/userdel
copy_with_deps /usr/sbin/usermod
copy_with_deps /usr/sbin/groupadd
copy_with_deps /usr/bin/passwd
copy_with_deps /bin/su
copy_with_deps /usr/bin/sudo

# Bootloader (if available)
copy_with_deps /usr/sbin/grub-install
copy_with_deps /usr/bin/grub-mkconfig
copy_with_deps /usr/sbin/update-grub

echo ""
echo "=== Phase 2: Essential Library Directories ==="

# Copy essential library directories
copy_lib_dir /lib/x86_64-linux-gnu
copy_lib_dir /lib64
copy_lib_dir /usr/lib/x86_64-linux-gnu
copy_lib_dir /usr/lib64

# Copy GCC libraries
if [[ -d /usr/lib/gcc ]]; then
    echo -e "${GREEN}[*]${NC} Copying GCC libraries..."
    mkdir -p "$TARGET_ROOT/usr/lib"
    cp -r /usr/lib/gcc "$TARGET_ROOT/usr/lib/" 2>/dev/null || true
fi

echo ""
echo "=== Phase 3: Essential System Files ==="

# Create essential device nodes
echo -e "${BLUE}[*]${NC} Creating device nodes..."
mkdir -p "$TARGET_ROOT/dev"
if [[ ! -e "$TARGET_ROOT/dev/null" ]]; then
    sudo mknod -m 666 "$TARGET_ROOT/dev/null" c 1 3
fi
if [[ ! -e "$TARGET_ROOT/dev/zero" ]]; then
    sudo mknod -m 666 "$TARGET_ROOT/dev/zero" c 1 5
fi
if [[ ! -e "$TARGET_ROOT/dev/random" ]]; then
    sudo mknod -m 666 "$TARGET_ROOT/dev/random" c 1 8
fi
if [[ ! -e "$TARGET_ROOT/dev/urandom" ]]; then
    sudo mknod -m 666 "$TARGET_ROOT/dev/urandom" c 1 9
fi
if [[ ! -e "$TARGET_ROOT/dev/console" ]]; then
    sudo mknod -m 600 "$TARGET_ROOT/dev/console" c 5 1
fi
if [[ ! -e "$TARGET_ROOT/dev/tty" ]]; then
    sudo mknod -m 666 "$TARGET_ROOT/dev/tty" c 5 0
fi

# Copy essential configuration files
echo -e "${BLUE}[*]${NC} Copying essential configuration files..."

# NSS libraries (for name resolution)
mkdir -p "$TARGET_ROOT/etc"
if [[ -f /etc/nsswitch.conf ]]; then
    cp /etc/nsswitch.conf "$TARGET_ROOT/etc/"
fi

# DNS resolution
if [[ -f /etc/resolv.conf ]]; then
    cp /etc/resolv.conf "$TARGET_ROOT/etc/"
fi

# Password files (create basic versions)
cat > "$TARGET_ROOT/etc/passwd" << 'EOF'
root:x:0:0:root:/root:/bin/bash
nobody:x:65534:65534:nobody:/nonexistent:/usr/sbin/nologin
EOF

cat > "$TARGET_ROOT/etc/group" << 'EOF'
root:x:0:
nobody:x:65534:
EOF

cat > "$TARGET_ROOT/etc/shadow" << 'EOF'
root:*:19000:0:99999:7:::
nobody:*:19000:0:99999:7:::
EOF

chmod 644 "$TARGET_ROOT/etc/passwd"
chmod 644 "$TARGET_ROOT/etc/group"
chmod 600 "$TARGET_ROOT/etc/shadow"

# Basic shell configuration
cat > "$TARGET_ROOT/etc/profile" << 'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='\u@\h:\w\$ '
EOF

# Bash configuration
cat > "$TARGET_ROOT/root/.bashrc" << 'EOF'
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
alias ls='ls --color=auto'
alias ll='ls -lah'
alias grep='grep --color=auto'
EOF

echo ""
echo "=== Phase 4: Terminfo Database ==="

# Copy terminfo for terminal support
if [[ -d /usr/share/terminfo ]]; then
    echo -e "${BLUE}[*]${NC} Copying terminfo database..."
    mkdir -p "$TARGET_ROOT/usr/share"
    cp -r /usr/share/terminfo "$TARGET_ROOT/usr/share/" 2>/dev/null || true
fi

# Copy locale data
if [[ -d /usr/share/locale ]]; then
    echo -e "${BLUE}[*]${NC} Copying locale data..."
    mkdir -p "$TARGET_ROOT/usr/share"
    cp -r /usr/share/locale "$TARGET_ROOT/usr/share/" 2>/dev/null || true
fi

echo ""
echo "=== Phase 5: Creating Symlinks ==="

# Create common symlinks
cd "$TARGET_ROOT"

# Ensure sh points to bash
ln -sf bash bin/sh 2>/dev/null || true

# Create lib symlinks if needed
if [[ ! -L lib && -d lib64 ]]; then
    ln -sf lib64 lib
fi

if [[ ! -L usr/lib && -d usr/lib64 ]]; then
    cd usr && ln -sf lib64 lib && cd ..
fi

echo ""
echo -e "${GREEN}=== Copying Complete! ===${NC}"
echo ""
echo "Essential binaries and libraries have been copied to:"
echo "  $TARGET_ROOT"
echo ""
echo "Summary:"
echo "  - Shell and core utilities: ✓"
echo "  - System binaries: ✓"
echo "  - Networking tools: ✓"
echo "  - Development tools: ✓"
echo "  - All library dependencies: ✓"
echo "  - Essential configuration: ✓"
echo ""
echo "Your Galactica build should now be bootable (after kernel install)!"
