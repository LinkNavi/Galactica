#!/bin/bash
# Galactica Bootstrap System
# This is the ONLY additional tool in the minimal base
# It helps users set up their system on first boot

set -e

GALACTICA_VERSION="0.1.0"
CONFIG_DIR="/etc/galactica"
BOOTSTRAP_DONE="$CONFIG_DIR/.bootstrap_complete"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

clear

echo -e "${CYAN}"
cat << "EOF"
   ____       _            _   _           
  / __ \     | |          | | (_)          
 | |  | | ___| | __ _  ___| |_ _  ___ __ _ 
 | |  | |/ __| |/ _` |/ __| __| |/ __/ _` |
 | |__| | (__| | (_| | (__| |_| | (_| (_| |
  \____/ \___|_|\__,_|\___|\__|_|\___\__,_|
                                            
         Minimal Linux Distribution
EOF
echo -e "${NC}"

echo -e "${BLUE}=== Galactica Bootstrap System v$GALACTICA_VERSION ===${NC}"
echo ""

# Check if already bootstrapped
if [[ -f "$BOOTSTRAP_DONE" ]]; then
    echo -e "${GREEN}System already bootstrapped!${NC}"
    echo ""
    echo "To re-run setup, remove: $BOOTSTRAP_DONE"
    exit 0
fi

echo -e "${YELLOW}Welcome to Galactica Linux!${NC}"
echo ""
echo "This is a minimal Linux distribution. You are currently running"
echo "with only the kernel and init system installed."
echo ""
echo "This bootstrap wizard will help you set up your system by:"
echo "  1. Choosing and installing a package manager"
echo "  2. Installing essential system components"
echo "  3. Configuring your environment"
echo ""
read -p "Press Enter to continue..."

# ============================================
# Step 1: Choose Package Manager
# ============================================
clear
echo -e "${BLUE}=== Step 1: Package Manager Selection ===${NC}"
echo ""
echo "Galactica needs a package manager to install software."
echo ""
echo "Available options:"
echo ""
echo "  1) Galactic Package Manager (GPM) - Recommended"
echo "     • Built from source for your hardware"
echo "     • Optimized compilation"
echo "     • Full control over build flags"
echo ""
echo "  2) Binary Package Manager"
echo "     • Pre-compiled packages"
echo "     • Faster installation"
echo "     • Less customization"
echo ""
echo "  3) Minimal Ports System"
echo "     • FreeBSD-style ports"
echo "     • Simple Makefiles"
echo "     • Maximum simplicity"
echo ""
echo "  4) Install later (drop to emergency shell)"
echo ""

read -p "Select package manager (1-4): " pkg_choice

case $pkg_choice in
    1)
        PKG_MANAGER="gpm"
        echo -e "${GREEN}Selected: Galactic Package Manager${NC}"
        ;;
    2)
        PKG_MANAGER="binary"
        echo -e "${GREEN}Selected: Binary Package Manager${NC}"
        ;;
    3)
        PKG_MANAGER="ports"
        echo -e "${GREEN}Selected: Minimal Ports System${NC}"
        ;;
    4)
        echo -e "${YELLOW}Dropping to emergency shell...${NC}"
        echo "Run this script again when ready to continue setup."
        exec /bin/sh
        ;;
    *)
        echo -e "${RED}Invalid choice. Defaulting to GPM.${NC}"
        PKG_MANAGER="gpm"
        ;;
esac

sleep 1

# ============================================
# Step 2: Essential Components
# ============================================
clear
echo -e "${BLUE}=== Step 2: Essential Components ===${NC}"
echo ""
echo "Select components to install:"
echo ""

# Shell selection
echo "Shell:"
echo "  1) Bash (full-featured)"
echo "  2) Dash (minimal, fast)"
echo "  3) Zsh (powerful, customizable)"
echo "  4) Fish (user-friendly)"
read -p "Select shell (1-4) [1]: " shell_choice
shell_choice=${shell_choice:-1}

# Core utilities
echo ""
echo "Core Utilities:"
echo "  1) GNU Coreutils (standard)"
echo "  2) BusyBox (minimal, all-in-one)"
echo "  3) uutils (Rust reimplementation)"
read -p "Select core utilities (1-3) [1]: " utils_choice
utils_choice=${utils_choice:-1}

# Text editor
echo ""
echo "Text Editor:"
echo "  1) Nano (beginner-friendly)"
echo "  2) Vim (powerful)"
echo "  3) Emacs (extensible)"
echo "  4) None (install later)"
read -p "Select editor (1-4) [1]: " editor_choice
editor_choice=${editor_choice:-1}

# Network tools
echo ""
read -p "Install network tools? (y/n) [y]: " install_network
install_network=${install_network:-y}

# Development tools
echo ""
read -p "Install development tools (gcc, make, etc.)? (y/n) [n]: " install_dev
install_dev=${install_dev:-n}

# ============================================
# Step 3: System Configuration
# ============================================
clear
echo -e "${BLUE}=== Step 3: System Configuration ===${NC}"
echo ""

# Hostname
read -p "Enter hostname [galactica]: " hostname
hostname=${hostname:-galactica}

# Root password
echo ""
echo "Set root password:"
read -s -p "Password: " root_pass
echo ""
read -s -p "Confirm password: " root_pass_confirm
echo ""

if [[ "$root_pass" != "$root_pass_confirm" ]]; then
    echo -e "${RED}Passwords do not match! Using default: 'galactica'${NC}"
    root_pass="galactica"
fi

# User creation
echo ""
read -p "Create a regular user? (y/n) [y]: " create_user
create_user=${create_user:-y}

if [[ "$create_user" == "y" ]]; then
    read -p "Username: " username
    read -s -p "Password: " user_pass
    echo ""
fi

# ============================================
# Step 4: Installation Summary
# ============================================
clear
echo -e "${BLUE}=== Installation Summary ===${NC}"
echo ""
echo "Package Manager: $PKG_MANAGER"
echo "Hostname: $hostname"
echo ""
echo "Components to install:"
case $shell_choice in
    1) echo "  • Shell: Bash" ;;
    2) echo "  • Shell: Dash" ;;
    3) echo "  • Shell: Zsh" ;;
    4) echo "  • Shell: Fish" ;;
esac

case $utils_choice in
    1) echo "  • Core Utils: GNU Coreutils" ;;
    2) echo "  • Core Utils: BusyBox" ;;
    3) echo "  • Core Utils: uutils" ;;
esac

case $editor_choice in
    1) echo "  • Editor: Nano" ;;
    2) echo "  • Editor: Vim" ;;
    3) echo "  • Editor: Emacs" ;;
    4) echo "  • Editor: None" ;;
esac

[[ "$install_network" == "y" ]] && echo "  • Network tools"
[[ "$install_dev" == "y" ]] && echo "  • Development tools"
[[ -n "$username" ]] && echo "  • User: $username"

echo ""
read -p "Proceed with installation? (y/n): " proceed

if [[ "$proceed" != "y" ]]; then
    echo "Installation cancelled."
    exit 1
fi

# ============================================
# Step 5: Installation
# ============================================
clear
echo -e "${BLUE}=== Installing Components ===${NC}"
echo ""

# Create directories
mkdir -p $CONFIG_DIR
mkdir -p /var/galactica/pkg

# Save configuration
cat > $CONFIG_DIR/bootstrap.conf << EOF
# Galactica Bootstrap Configuration
PACKAGE_MANAGER=$PKG_MANAGER
HOSTNAME=$hostname
SHELL_CHOICE=$shell_choice
UTILS_CHOICE=$utils_choice
EDITOR_CHOICE=$editor_choice
INSTALL_NETWORK=$install_network
INSTALL_DEV=$install_dev
BOOTSTRAP_DATE=$(date)
EOF

# Set hostname
echo "$hostname" > /etc/hostname
cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   $hostname
::1         localhost ip6-localhost ip6-loopback
EOF

# Install package manager
echo -e "${GREEN}[1/5]${NC} Installing package manager..."
# This would download and install your actual package manager
# For now, create placeholder
mkdir -p /usr/bin
cat > /usr/bin/gpkg << 'GPKG_EOF'
#!/bin/sh
echo "Galactic Package Manager - Not yet implemented"
echo "Usage: gpkg <install|remove|update|search> [package]"
GPKG_EOF
chmod +x /usr/bin/gpkg

sleep 1

# Install shell
echo -e "${GREEN}[2/5]${NC} Installing shell..."
# This would use the package manager to install chosen shell
# Placeholder for now
sleep 1

# Install core utilities
echo -e "${GREEN}[3/5]${NC} Installing core utilities..."
sleep 1

# Install optional components
echo -e "${GREEN}[4/5]${NC} Installing optional components..."
sleep 1

# Configure system
echo -e "${GREEN}[5/5]${NC} Configuring system..."

# Set root password
if command -v chpasswd &> /dev/null; then
    echo "root:$root_pass" | chpasswd
fi

# Create user if requested
if [[ -n "$username" ]]; then
    if command -v useradd &> /dev/null; then
        useradd -m -s /bin/bash "$username"
        echo "$username:$user_pass" | chpasswd
    fi
fi

sleep 1

# ============================================
# Completion
# ============================================
touch $BOOTSTRAP_DONE

clear
echo -e "${GREEN}"
cat << "EOF"
  ____                       _      _       _ 
 / ___|___  _ __ ___  _ __ | | ___| |_ ___| |
| |   / _ \| '_ ` _ \| '_ \| |/ _ \ __/ _ \ |
| |__| (_) | | | | | | |_) | |  __/ ||  __/_|
 \____\___/|_| |_| |_| .__/|_|\___|\__\___(_)
                     |_|                      
EOF
echo -e "${NC}"

echo -e "${GREEN}=== Bootstrap Complete! ===${NC}"
echo ""
echo "Your Galactica system is now set up!"
echo ""
echo "Next steps:"
echo "  • Explore installed packages: gpkg list"
echo "  • Install more software: gpkg install <package>"
echo "  • Configure services: airridectl list"
echo ""
echo "Documentation: /usr/share/doc/galactica"
echo ""
read -p "Press Enter to reboot..."

reboot
