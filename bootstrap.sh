#!/bin/bash
# Galactica Bootstrap System
# First-boot setup wizard for minimal Galactica Linux

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
PINK='\033[38;5;213m'
NC='\033[0m'

clear

echo -e "${CYAN}"
cat << "EOF"

  ________       .__                 __  .__               
 /  _____/_____  |  | _____    _____/  |_|__| ____ _____   
/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  
\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_
 \______  (____  /____(____  /\___  >__| |__|\___  >____  /
        \/     \/          \/     \/             \/     \/ 


         Minimal Linux Distribution
EOF
echo -e "${NC}"

echo -e "${BLUE}=== Galactica Bootstrap System v$GALACTICA_VERSION ===${NC}"
echo ""

# Check if already bootstrapped
if [[ -f "$BOOTSTRAP_DONE" ]]; then
    echo -e "${GREEN}System already bootstrapped!${NC}"
    echo ""
    echo "Current configuration:"
    cat "$CONFIG_DIR/bootstrap.conf" 2>/dev/null || echo "Configuration file not found"
    echo ""
    echo "To re-run setup, remove: $BOOTSTRAP_DONE"
    echo "To access package manager: dreamland --help"
    exit 0
fi

echo -e "${YELLOW}Welcome to Galactica Linux!${NC}"
echo ""
echo "This is a minimal Linux distribution with:"
echo "  • Custom kernel (6.18.3-galactica)"
echo "  • AirRide init system (lightweight PID 1)"
echo "  • Dreamland package manager (source-based)"
echo "  • Minimal base system"
echo ""
echo "This bootstrap wizard will:"
echo "  1. Configure basic system settings"
echo "  2. Set up user accounts"
echo "  3. Initialize the package manager"
echo "  4. Install essential packages (optional)"
echo ""
read -p "Press Enter to continue..."

# ============================================
# Step 1: System Configuration
# ============================================
clear
echo -e "${BLUE}=== Step 1: System Configuration ===${NC}"
echo ""

# Hostname
read -p "Enter hostname [galactica]: " hostname
hostname=${hostname:-galactica}
echo "$hostname" > /etc/hostname

cat > /etc/hosts << EOF
127.0.0.1   localhost
127.0.1.1   $hostname
::1         localhost ip6-localhost ip6-loopback
EOF

echo -e "${GREEN}✓${NC} Hostname set to: $hostname"
echo ""

# Timezone (simplified)
echo "Select timezone:"
echo "  1) UTC"
echo "  2) America/New_York"
echo "  3) America/Los_Angeles"
echo "  4) Europe/London"
echo "  5) Asia/Tokyo"
read -p "Select timezone (1-5) [1]: " tz_choice
tz_choice=${tz_choice:-1}

case $tz_choice in
    1) TZ="UTC" ;;
    2) TZ="America/New_York" ;;
    3) TZ="America/Los_Angeles" ;;
    4) TZ="Europe/London" ;;
    5) TZ="Asia/Tokyo" ;;
    *) TZ="UTC" ;;
esac

echo "$TZ" > /etc/timezone
echo -e "${GREEN}✓${NC} Timezone set to: $TZ"
echo ""

sleep 1

# ============================================
# Step 2: User Accounts
# ============================================
clear
echo -e "${BLUE}=== Step 2: User Accounts ===${NC}"
echo ""

# Root password
echo "Current root password is: ${CYAN}galactica${NC}"
echo ""
read -p "Change root password? (y/n) [n]: " change_root
change_root=${change_root:-n}

if [[ "$change_root" == "y" ]]; then
    echo ""
    read -s -p "New password: " root_pass
    echo ""
    read -s -p "Confirm password: " root_pass_confirm
    echo ""
    
    if [[ "$root_pass" == "$root_pass_confirm" ]] && [[ -n "$root_pass" ]]; then
        echo "root:$root_pass" | chpasswd 2>/dev/null || {
            # Fallback: use openssl to generate hash
            if command -v openssl &>/dev/null; then
                HASH=$(openssl passwd -6 "$root_pass")
                sed -i "s|^root:[^:]*:|root:$HASH:|" /etc/shadow
                echo -e "${GREEN}✓${NC} Root password changed"
            else
                echo -e "${YELLOW}!${NC} Could not change password (no chpasswd or openssl)"
            fi
        }
        echo -e "${GREEN}✓${NC} Root password changed"
    else
        echo -e "${RED}✗${NC} Passwords do not match or empty, keeping 'galactica'"
    fi
else
    echo -e "${GREEN}✓${NC} Keeping default password 'galactica'"
fi
echo ""

# User creation
read -p "Create a regular user? (y/n) [y]: " create_user
create_user=${create_user:-y}

username=""
if [[ "$create_user" == "y" ]]; then
    read -p "Username: " username
    
    if [[ -n "$username" ]]; then
        # Check if useradd exists
        if command -v useradd &>/dev/null; then
            useradd -m -s /bin/sh "$username" 2>/dev/null || {
                # Fallback: manually create user
                echo "$username:x:1000:1000:$username:/home/$username:/bin/sh" >> /etc/passwd
                echo "$username:x:1000:" >> /etc/group
                mkdir -p "/home/$username"
                chown 1000:1000 "/home/$username"
            }
        else
            # Manual user creation
            echo "$username:x:1000:1000:$username:/home/$username:/bin/sh" >> /etc/passwd
            echo "$username:x:1000:" >> /etc/group
            mkdir -p "/home/$username"
        fi
        
        read -s -p "Password for $username: " user_pass
        echo ""
        
        if [[ -n "$user_pass" ]]; then
            echo "$username:$user_pass" | chpasswd 2>/dev/null || {
                # Fallback: add to shadow manually
                echo "$username:$(openssl passwd -6 "$user_pass" 2>/dev/null || echo '*'):19000:0:99999:7:::" >> /etc/shadow
            }
        fi
        
        echo -e "${GREEN}✓${NC} User $username created"
    fi
fi
echo ""

sleep 1

# ============================================
# Step 3: Package Manager Setup
# ============================================
clear
echo -e "${BLUE}=== Step 3: Package Manager - Dreamland ===${NC}"
echo ""

echo "Dreamland is Galactica's source-based package manager."
echo "It builds software from source and fetches packages from:"
echo "  ${CYAN}https://github.com/LinkNavi/GalacticaRepository${NC}"
echo ""

# Check if dreamland is installed
if command -v dreamland &>/dev/null || command -v dl &>/dev/null; then
    echo -e "${GREEN}✓${NC} Dreamland package manager found"
    
    read -p "Initialize package database? (y/n) [y]: " init_pkg
    init_pkg=${init_pkg:-y}
    
    if [[ "$init_pkg" == "y" ]]; then
        echo ""
        echo "Syncing package repository..."
        
        # Create dreamland directories
        mkdir -p /var/dreamland/{cache,build}
        mkdir -p /var/dreamland/cache
        
        # Sync package index
        if command -v dreamland &>/dev/null; then
            dreamland sync || echo -e "${YELLOW}Warning: Could not sync repository (network may not be configured)${NC}"
        elif command -v dl &>/dev/null; then
            dl sync || echo -e "${YELLOW}Warning: Could not sync repository (network may not be configured)${NC}"
        fi
        
        echo -e "${GREEN}✓${NC} Package manager initialized"
    fi
else
    echo -e "${YELLOW}!${NC} Dreamland not found in PATH"
    echo ""
    echo "To install Dreamland later:"
    echo "  1. Build it from AirRide/Dreamland/"
    echo "  2. Copy the binary to /usr/bin/dreamland"
    echo "  3. Run: dreamland sync"
fi
echo ""

sleep 1

# ============================================
# Step 4: Essential Packages
# ============================================
clear
echo -e "${BLUE}=== Step 4: Essential Packages ===${NC}"
echo ""

echo "Would you like to install essential packages?"
echo ""
echo "Recommended packages:"
echo "  • coreutils (ls, cp, mv, rm, cat, etc.)"
echo "  • bash (full-featured shell)"
echo "  • vim or nano (text editor)"
echo "  • network tools (wget, curl, openssh)"
echo ""
echo -e "${YELLOW}Note: This requires network connectivity${NC}"
echo ""

read -p "Install essential packages? (y/n) [n]: " install_pkgs
install_pkgs=${install_pkgs:-n}

if [[ "$install_pkgs" == "y" ]]; then
    # List of essential packages to install
    PACKAGES=(
        "coreutils"
        "bash"
        "nano"
        "wget"
    )
    
    echo ""
    echo "Packages to install: ${PACKAGES[*]}"
    echo ""
    read -p "Proceed? (y/n) [y]: " proceed
    proceed=${proceed:-y}
    
    if [[ "$proceed" == "y" ]]; then
        if command -v dreamland &>/dev/null; then
            for pkg in "${PACKAGES[@]}"; do
                echo ""
                echo -e "${BLUE}Installing $pkg...${NC}"
                dreamland install "$pkg" || echo -e "${YELLOW}Failed to install $pkg${NC}"
            done
        else
            echo -e "${RED}✗${NC} Dreamland not available, skipping package installation"
        fi
    fi
else
    echo "Skipping package installation"
    echo ""
    echo "To install packages later:"
    echo "  dreamland search <query>    # Search for packages"
    echo "  dreamland install <package> # Install a package"
    echo "  dreamland list              # List installed packages"
fi
echo ""

sleep 1

# ============================================
# Step 5: Service Configuration
# ============================================
clear
echo -e "${BLUE}=== Step 5: Service Configuration ===${NC}"
echo ""

echo "AirRide manages system services."
echo "Currently available services are defined in: /etc/airride/services/"
echo ""

# List available services
if [[ -d /etc/airride/services ]]; then
    echo "Available services:"
    for service in /etc/airride/services/*.service; do
        if [[ -f "$service" ]]; then
            name=$(basename "$service" .service)
            echo "  • $name"
        fi
    done
else
    mkdir -p /etc/airride/services
    echo "No services configured yet"
fi
echo ""

echo "Service management:"
echo "  airridectl start <service>   # Start a service"
echo "  airridectl stop <service>    # Stop a service"
echo "  airridectl status <service>  # Check service status"
echo "  airridectl list              # List all services"
echo ""

sleep 1

# ============================================
# Step 6: Network Configuration (Basic)
# ============================================
clear
echo -e "${BLUE}=== Step 6: Network Configuration ===${NC}"
echo ""

read -p "Configure network now? (y/n) [n]: " config_net
config_net=${config_net:-n}

if [[ "$config_net" == "y" ]]; then
    echo ""
    echo "Network configuration options:"
    echo "  1) DHCP (automatic)"
    echo "  2) Static IP"
    echo "  3) Skip for now"
    read -p "Select option (1-3) [1]: " net_choice
    net_choice=${net_choice:-1}
    
    case $net_choice in
        1)
            echo "Configuring DHCP..."
            if command -v dhclient &>/dev/null; then
                dhclient eth0 &
                echo -e "${GREEN}✓${NC} DHCP client started"
            elif command -v udhcpc &>/dev/null; then
                udhcpc -i eth0 &
                echo -e "${GREEN}✓${NC} DHCP client started"
            else
                echo -e "${YELLOW}!${NC} No DHCP client found"
                echo "Install dhclient or udhcpc: dreamland install dhcp"
            fi
            ;;
        2)
            echo "Static IP configuration:"
            read -p "IP Address: " ip_addr
            read -p "Netmask [255.255.255.0]: " netmask
            netmask=${netmask:-255.255.255.0}
            read -p "Gateway: " gateway
            read -p "DNS Server: " dns
            
            if command -v ip &>/dev/null; then
                ip addr add "$ip_addr/$netmask" dev eth0
                ip route add default via "$gateway"
                echo "nameserver $dns" > /etc/resolv.conf
                echo -e "${GREEN}✓${NC} Static IP configured"
            else
                echo -e "${YELLOW}!${NC} 'ip' command not found"
                echo "Manual configuration needed"
            fi
            ;;
        3)
            echo "Skipping network configuration"
            ;;
    esac
else
    echo "Network configuration skipped"
    echo ""
    echo "To configure network later:"
    echo "  DHCP: dhclient eth0"
    echo "  Static: ip addr add <ip>/<mask> dev eth0"
fi
echo ""

sleep 1

# ============================================
# Step 7: Save Configuration
# ============================================
clear
echo -e "${BLUE}=== Step 7: Finalizing Setup ===${NC}"
echo ""

# Create config directory
mkdir -p "$CONFIG_DIR"

# Save bootstrap configuration
cat > "$CONFIG_DIR/bootstrap.conf" << EOF
# Galactica Bootstrap Configuration
GALACTICA_VERSION=$GALACTICA_VERSION
HOSTNAME=$hostname
TIMEZONE=$TZ
USERNAME=$username
BOOTSTRAP_DATE=$(date)
PACKAGE_MANAGER=dreamland
EOF

# Create a helpful MOTD
cat > /etc/motd << 'EOF'

  ________       .__                 __  .__               
 /  _____/_____  |  | _____    _____/  |_|__| ____ _____   
/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  
\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_
 \______  (____  /____(____  /\___  >__| |__|\___  >____  /
        \/     \/          \/     \/             \/     \/ 


Welcome to Galactica Linux - Minimal by Design

Quick reference:
  • Package manager: dreamland (or 'dl')
    - dl sync              Sync package repository
    - dl search <query>    Search for packages
    - dl install <pkg>     Install a package
    - dl list              List installed packages

  • Service manager: airridectl
    - airridectl list              List services
    - airridectl start <service>   Start a service
    - airridectl status <service>  Check status

  • System info:
    - uname -a            Kernel version
    - free -h             Memory usage
    - df -h               Disk usage

Documentation: https://github.com/LinkNavi/Galactica

EOF

# Mark as complete
touch "$BOOTSTRAP_DONE"

echo -e "${GREEN}✓${NC} Configuration saved"
echo ""

# ============================================
# Completion
# ============================================
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
echo "Your Galactica system is configured:"
echo ""
echo "  Hostname:       $hostname"
echo "  Timezone:       $TZ"
[[ -n "$username" ]] && echo "  User:           $username"
echo "  Package Mgr:    Dreamland"
echo "  Init System:    AirRide"
echo ""
echo "Next steps:"
echo ""
echo "  1. Sync package repository:"
echo "     ${CYAN}dreamland sync${NC}"
echo ""
echo "  2. Search and install software:"
echo "     ${CYAN}dreamland search editor${NC}"
echo "     ${CYAN}dreamland install vim${NC}"
echo ""
echo "  3. Manage services:"
echo "     ${CYAN}airridectl list${NC}"
echo "     ${CYAN}airridectl start <service>${NC}"
echo ""
echo "  4. Explore the system:"
echo "     ${CYAN}cat /etc/motd${NC}"
echo ""
echo "Documentation: /usr/share/doc/galactica (if available)"
echo "Repository:    https://github.com/LinkNavi/GalacticaRepository"
echo ""

read -p "Press Enter to continue to shell..."

# Display MOTD
cat /etc/motd

echo ""
echo "You are now in the Galactica shell."
echo "Type 'exit' to return to the parent process."
echo ""

# Drop to shell
exec /bin/sh
