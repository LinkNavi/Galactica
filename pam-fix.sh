#!/bin/bash
# Complete X11/GUI fix for Galactica Linux in QEMU
# Fixes: kernel DRM, X.Org config, and QEMU settings

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

ROOTFS="${1:-galactica-rootfs.img}"
KERNEL_DIR="${2:-./linux-6.18.4}"

echo -e "${BLUE}=== Galactica Complete GUI Fix ===${NC}"
echo ""

# ============================================
# PART 1: Check/Fix Kernel for DRM/KMS
# ============================================
echo -e "${CYAN}[1/4] Checking Kernel for Graphics Support${NC}"
echo ""

KERNEL_NEEDS_REBUILD=0

if [[ -f "$KERNEL_DIR/.config" ]]; then
    echo "Checking kernel config..."
    
    # Required for virtio-gpu
    REQUIRED_OPTIONS=(
        "CONFIG_DRM=y"
        "CONFIG_DRM_KMS_HELPER=y"
        "CONFIG_DRM_VIRTIO_GPU=y"
        "CONFIG_DRM_FBDEV_EMULATION=y"
        "CONFIG_FB=y"
        "CONFIG_FB_VESA=y"
        "CONFIG_FRAMEBUFFER_CONSOLE=y"
    )
    
    for opt in "${REQUIRED_OPTIONS[@]}"; do
        KEY=$(echo "$opt" | cut -d= -f1)
        if grep -q "^$opt" "$KERNEL_DIR/.config"; then
            echo -e "  ${GREEN}✓${NC} $KEY enabled"
        else
            echo -e "  ${RED}✗${NC} $KEY missing or not =y"
            KERNEL_NEEDS_REBUILD=1
        fi
    done
    
    if [[ $KERNEL_NEEDS_REBUILD -eq 1 ]]; then
        echo ""
        echo -e "${YELLOW}Kernel needs additional options for GUI support!${NC}"
        echo "Add these to your kernel .config and rebuild:"
        echo ""
        cat << 'EOFKERNEL'
# Graphics/DRM support for QEMU
CONFIG_DRM=y
CONFIG_DRM_KMS_HELPER=y
CONFIG_DRM_GEM_SHMEM_HELPER=y
CONFIG_DRM_VIRTIO_GPU=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DRM_BOCHS=y
CONFIG_DRM_QXL=y
CONFIG_DRM_SIMPLEDRM=y

# Framebuffer
CONFIG_FB=y
CONFIG_FB_VESA=y
CONFIG_FB_EFI=y
CONFIG_FB_SIMPLE=y
CONFIG_FRAMEBUFFER_CONSOLE=y
CONFIG_FRAMEBUFFER_CONSOLE_DETECT_PRIMARY=y

# Input for X11
CONFIG_INPUT_EVDEV=y
CONFIG_INPUT_KEYBOARD=y
CONFIG_INPUT_MOUSE=y
CONFIG_INPUT_MISC=y
EOFKERNEL
        echo ""
    else
        echo ""
        echo -e "${GREEN}Kernel has required graphics options!${NC}"
    fi
else
    echo -e "${YELLOW}Kernel config not found at $KERNEL_DIR/.config${NC}"
    echo "Skipping kernel check..."
fi

# ============================================
# PART 2: Fix X.Org Configuration
# ============================================
echo ""
echo -e "${CYAN}[2/4] Fixing X.Org Configuration${NC}"
echo ""

if [[ ! -f "$ROOTFS" ]]; then
    echo -e "${RED}Error: $ROOTFS not found${NC}"
    exit 1
fi

MOUNT_POINT="/tmp/galactica-gui-fix"
mkdir -p "$MOUNT_POINT"
sudo mount -o loop "$ROOTFS" "$MOUNT_POINT"

cleanup() {
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    rmdir "$MOUNT_POINT" 2>/dev/null || true
}
trap cleanup EXIT

# Fix hostname (causes xauth errors)
echo "galactica" | sudo tee "$MOUNT_POINT/etc/hostname" > /dev/null
sudo tee "$MOUNT_POINT/etc/hosts" > /dev/null << 'EOF'
127.0.0.1   localhost galactica
::1         localhost
EOF
echo -e "  ${GREEN}✓${NC} Fixed hostname"

# Create xorg.conf that uses modesetting (the modern way)
sudo mkdir -p "$MOUNT_POINT/etc/X11/xorg.conf.d"

# Modesetting driver - works with DRM/KMS
sudo tee "$MOUNT_POINT/etc/X11/xorg.conf" > /dev/null << 'EOFXORG'
# Galactica X.Org Configuration
# Uses modesetting driver with DRM/KMS

Section "ServerLayout"
    Identifier     "Layout0"
    Screen      0  "Screen0"
EndSection

Section "ServerFlags"
    Option "AutoAddDevices" "true"
    Option "AutoEnableDevices" "true"
    Option "AllowEmptyInput" "true"
EndSection

Section "Device"
    Identifier  "GPU"
    Driver      "modesetting"
    Option      "AccelMethod" "glamor"
    Option      "DRI" "3"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device     "GPU"
    Monitor    "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth   24
        Modes   "1024x768" "800x600"
    EndSubSection
EndSection

Section "Monitor"
    Identifier "Monitor0"
EndSection
EOFXORG
echo -e "  ${GREEN}✓${NC} Created X.Org config with modesetting driver"

# Create startup script
sudo tee "$MOUNT_POINT/usr/bin/startgui" > /dev/null << 'EOFSTART'
#!/bin/sh
# Galactica GUI Starter

set -e

# Fix hostname for xauth
HNAME=$(cat /etc/hostname 2>/dev/null || echo "galactica")
hostname "$HNAME" 2>/dev/null || true

# Environment
export DISPLAY=:0
export HOME="${HOME:-/root}"
export XAUTHORITY="$HOME/.Xauthority"

# Check for DRM devices
if [ ! -d /sys/class/drm ]; then
    echo "Warning: No DRM devices found"
    echo "Make sure kernel has CONFIG_DRM_VIRTIO_GPU=y"
fi

# List available DRM devices
echo "Available graphics:"
ls -la /dev/dri/ 2>/dev/null || echo "  No /dev/dri (no DRM support)"
ls -la /dev/fb* 2>/dev/null || echo "  No framebuffer devices"

# Create Xauthority
touch "$XAUTHORITY"

echo ""
echo "Starting X server..."
echo "If this fails, check /var/log/Xorg.0.log"
echo ""

# Start X
cd "$HOME"
exec startx "$HOME/.xinitrc" -- -keeptty 2>&1
EOFSTART
sudo chmod 755 "$MOUNT_POINT/usr/bin/startgui"
echo -e "  ${GREEN}✓${NC} Created startgui command"

# Create xinitrc
sudo tee "$MOUNT_POINT/root/.xinitrc" > /dev/null << 'EOFXI'
#!/bin/sh
# Galactica X Session

# Set background
xsetroot -solid "#1e1e2e" 2>/dev/null &

# Start window manager if available
if command -v openbox >/dev/null 2>&1; then
    openbox &
elif command -v twm >/dev/null 2>&1; then
    twm &
elif command -v fvwm >/dev/null 2>&1; then
    fvwm &
fi

# Run xterm as main app
exec xterm -fa "Monospace" -fs 11 -bg "#1e1e2e" -fg "#cdd6f4" -geometry 100x30
EOFXI
sudo chmod 755 "$MOUNT_POINT/root/.xinitrc"
echo -e "  ${GREEN}✓${NC} Created .xinitrc"

# Create device nodes
sudo mkdir -p "$MOUNT_POINT/dev/dri"
sudo mknod -m 666 "$MOUNT_POINT/dev/dri/card0" c 226 0 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_POINT/dev/dri/renderD128" c 226 128 2>/dev/null || true
sudo mknod -m 666 "$MOUNT_POINT/dev/fb0" c 29 0 2>/dev/null || true
echo -e "  ${GREEN}✓${NC} Created DRM device nodes"

# ============================================
# PART 3: Check Installed X Packages
# ============================================
echo ""
echo -e "${CYAN}[3/4] Checking X11 Packages${NC}"
echo ""

MISSING_PKGS=()

# Check for X server
if [[ -f "$MOUNT_POINT/usr/bin/X" ]] || [[ -f "$MOUNT_POINT/usr/bin/Xorg" ]]; then
    echo -e "  ${GREEN}✓${NC} X server installed"
else
    echo -e "  ${RED}✗${NC} X server NOT installed"
    MISSING_PKGS+=("xorg-server")
fi

# Check for xterm
if [[ -f "$MOUNT_POINT/usr/bin/xterm" ]]; then
    echo -e "  ${GREEN}✓${NC} xterm installed"
else
    echo -e "  ${RED}✗${NC} xterm NOT installed"
    MISSING_PKGS+=("xterm")
fi

# Check for xinit/startx
if [[ -f "$MOUNT_POINT/usr/bin/startx" ]] || [[ -f "$MOUNT_POINT/usr/bin/xinit" ]]; then
    echo -e "  ${GREEN}✓${NC} xinit/startx installed"
else
    echo -e "  ${RED}✗${NC} xinit NOT installed"
    MISSING_PKGS+=("xorg-xinit")
fi

# Check for modesetting driver
MODESETTING=$(find "$MOUNT_POINT/usr" -name "modesetting_drv.so" 2>/dev/null | head -1)
if [[ -n "$MODESETTING" ]]; then
    echo -e "  ${GREEN}✓${NC} modesetting driver found"
else
    echo -e "  ${RED}✗${NC} modesetting driver NOT found"
    MISSING_PKGS+=("xorg-server (includes modesetting)")
fi

# Check for libinput (input driver)
LIBINPUT=$(find "$MOUNT_POINT/usr" -name "libinput_drv.so" 2>/dev/null | head -1)
if [[ -n "$LIBINPUT" ]]; then
    echo -e "  ${GREEN}✓${NC} libinput driver found"
else
    echo -e "  ${YELLOW}!${NC} libinput driver not found (may need xf86-input-libinput)"
fi

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo ""
    echo -e "${YELLOW}Missing packages:${NC}"
    for pkg in "${MISSING_PKGS[@]}"; do
        echo "  - $pkg"
    done
    echo ""
    echo "Install in Galactica with:"
    echo "  dreamland install ${MISSING_PKGS[*]}"
fi

# ============================================
# PART 4: Create Updated QEMU Script
# ============================================
echo ""
echo -e "${CYAN}[4/4] Creating Updated QEMU Script${NC}"
echo ""

cat > /tmp/run-galactica-gui.sh << 'EOFQEMU'
#!/bin/bash
# Galactica with GUI support
# Uses virtio-gpu which works with modesetting driver

KERNEL="${KERNEL:-galactica-build/boot/vmlinuz-galactica}"
ROOTFS="${ROOTFS:-galactica-rootfs.img}"
MEM="${MEM:-1024M}"
CPUS="${CPUS:-2}"

if [[ ! -f "$KERNEL" ]] || [[ ! -f "$ROOTFS" ]]; then
    echo "Error: Kernel or rootfs not found"
    exit 1
fi

echo "=== Galactica GUI Boot ==="
echo ""
echo "Starting with virtio-gpu (for modesetting driver)"
echo ""
echo "After login, run: startgui"
echo ""

qemu-system-x86_64 \
    -enable-kvm \
    -kernel "$KERNEL" \
    -drive file="$ROOTFS",format=raw,if=virtio \
    -m "$MEM" \
    -smp "$CPUS" \
    -display gtk,gl=on \
    -device virtio-vga-gl \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    -netdev user,id=net0 \
    -device virtio-net-pci,netdev=net0 \
    -serial mon:stdio \
    -append "root=/dev/vda rw console=tty0 console=ttyS0 init=/sbin/init"
EOFQEMU

if [[ -w "." ]]; then
    cp /tmp/run-galactica-gui.sh ./run-galactica-gui.sh
    chmod +x ./run-galactica-gui.sh
    echo -e "  ${GREEN}✓${NC} Created run-galactica-gui.sh"
fi

echo ""
echo -e "${BLUE}=== Fix Complete ===${NC}"
echo ""

if [[ $KERNEL_NEEDS_REBUILD -eq 1 ]]; then
    echo -e "${YELLOW}ACTION REQUIRED:${NC}"
    echo "Your kernel needs DRM/virtio-gpu support."
    echo ""
    echo "Add these options to your kernel config and rebuild:"
    echo "  CONFIG_DRM=y"
    echo "  CONFIG_DRM_VIRTIO_GPU=y"
    echo "  CONFIG_DRM_KMS_HELPER=y"
    echo ""
fi

if [[ ${#MISSING_PKGS[@]} -gt 0 ]]; then
    echo -e "${YELLOW}PACKAGES NEEDED:${NC}"
    echo "Install these in Galactica:"
    echo "  dreamland install xorg-server xterm xorg-xinit"
    echo ""
fi

echo "To use GUI:"
echo ""
echo "1. Boot with: ${CYAN}./run-galactica-gui.sh${NC}"
echo "   (or run-galactica.sh option 1)"
echo ""
echo "2. After login: ${CYAN}startgui${NC}"
echo ""
echo "If X fails, check /var/log/Xorg.0.log for errors."
