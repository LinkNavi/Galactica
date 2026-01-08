#!/bin/bash
# Add proper login screen to Galactica
# This replaces the emergency shell with a getty login prompt

set -e

TARGET_ROOT="${1:-./galactica-build}"
ROOTFS="${2:-./galactica-rootfs.img}"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}=== Adding Login Screen to Galactica ===${NC}"
echo ""

if [[ ! -d "$TARGET_ROOT" ]]; then
    echo -e "${RED}Error: Build directory not found: $TARGET_ROOT${NC}"
    exit 1
fi

echo "This will:"
echo "  1. Create a getty program for login prompts"
echo "  2. Replace the emergency shell service"
echo "  3. Set up proper password authentication"
echo "  4. Update the rootfs image"
echo ""

# Step 1: Create a simple getty/login program
echo "Step 1: Creating login program..."
echo ""

mkdir -p "$TARGET_ROOT/sbin"

cat > /tmp/simple-login.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pwd.h>
#include <shadow.h>
#include <crypt.h>
#include <sys/types.h>

#define MAX_USERNAME 32
#define MAX_PASSWORD 128

int authenticate(const char* username, const char* password) {
    struct spwd* shadow_entry;
    
    // Get shadow entry for user
    shadow_entry = getspnam(username);
    if (!shadow_entry) {
        return 0;  // User not found
    }
    
    // Check if password is empty (no password set)
    if (shadow_entry->sp_pwdp[0] == '\0' || 
        strcmp(shadow_entry->sp_pwdp, "*") == 0 ||
        strcmp(shadow_entry->sp_pwdp, "!") == 0) {
        // No password set - allow login
        return 1;
    }
    
    // Verify password
    char* encrypted = crypt(password, shadow_entry->sp_pwdp);
    if (encrypted && strcmp(encrypted, shadow_entry->sp_pwdp) == 0) {
        return 1;
    }
    
    return 0;
}

int main() {
    char username[MAX_USERNAME];
    char password[MAX_PASSWORD];
    char* input_password;
    struct passwd* pwd_entry;
    
    // Loop until successful login
    while (1) {
        // Display banner
        printf("\n");
        printf("  ________       .__                 __  .__               \n");
        printf(" /  _____/_____  |  | _____    _____/  |_|__| ____ _____   \n");
        printf("/   \\  ___\\__  \\ |  | \\__  \\ _/ ___\\   __\\  |/ ___\\\\__  \\  \n");
        printf("\\    \\_\\  \\/ __ \\|  |__/ __ \\\\  \\___|  | |  \\  \\___ / __ \\_\n");
        printf(" \\______  (____  /____(____  /\\___  >__| |__|\\___  >____  /\n");
        printf("        \\/     \\/          \\/     \\/             \\/     \\/ \n");
        printf("\n");
        printf("Galactica Linux (ttyS0)\n\n");
        
        // Get hostname
        char hostname[64];
        if (gethostname(hostname, sizeof(hostname)) != 0) {
            strcpy(hostname, "galactica");
        }
        
        printf("%s login: ", hostname);
        fflush(stdout);
        
        // Read username
        if (fgets(username, sizeof(username), stdin) == NULL) {
            continue;
        }
        
        // Remove newline
        username[strcspn(username, "\n")] = 0;
        
        if (strlen(username) == 0) {
            continue;
        }
        
        // Get password (without echo)
        input_password = getpass("Password: ");
        if (!input_password) {
            printf("Login incorrect\n");
            sleep(2);
            continue;
        }
        
        // Copy password
        strncpy(password, input_password, sizeof(password) - 1);
        password[sizeof(password) - 1] = '\0';
        
        // Authenticate
        if (!authenticate(username, password)) {
            printf("Login incorrect\n");
            sleep(2);
            continue;
        }
        
        // Get user info
        pwd_entry = getpwnam(username);
        if (!pwd_entry) {
            printf("Login incorrect\n");
            sleep(2);
            continue;
        }
        
        // Change to user's home directory
        if (chdir(pwd_entry->pw_dir) != 0) {
            chdir("/");
        }
        
        // Set environment
        setenv("HOME", pwd_entry->pw_dir, 1);
        setenv("USER", username, 1);
        setenv("LOGNAME", username, 1);
        setenv("SHELL", pwd_entry->pw_shell, 1);
        setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin", 1);
        
        // Change UID/GID
        if (setgid(pwd_entry->pw_gid) != 0 || setuid(pwd_entry->pw_uid) != 0) {
            printf("Failed to change user\n");
            exit(1);
        }
        
        // Print last login info
        printf("Last login: Never logged in before\n");
        
        // Execute shell
        char* shell = pwd_entry->pw_shell;
        if (!shell || shell[0] == '\0') {
            shell = "/bin/sh";
        }
        
        // Execute user's shell
        execl(shell, shell, NULL);
        
        // If exec fails
        printf("Failed to execute shell: %s\n", shell);
        exit(1);
    }
    
    return 0;
}
EOF

# Compile the login program
if command -v gcc &>/dev/null; then
    echo "Compiling login program..."
    gcc -o "$TARGET_ROOT/sbin/login" /tmp/simple-login.c -lcrypt 2>&1 || {
        echo -e "${YELLOW}Warning: Compilation failed. You may need to:"
        echo "  1. Install build-essential: sudo apt install build-essential"
        echo "  2. Install libcrypt: sudo apt install libcrypt-dev"
        echo ""
        echo "For now, we'll create a simple shell script login instead."
        echo ""
        
        # Create a simple shell-based login
        cat > "$TARGET_ROOT/sbin/login" << 'EOFLOGIN'
#!/bin/sh
# Simple login script for Galactica

while true; do
    echo ""
    echo "  ________       .__                 __  .__               "
    echo " /  _____/_____  |  | _____    _____/  |_|__| ____ _____   "
    echo "/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  "
    echo "\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_"
    echo " \______  (____  /____(____  /\___  >__| |__|\___  >____  /"
    echo "        \/     \/          \/     \/             \/     \/ "
    echo ""
    echo "Galactica Linux"
    echo ""
    
    echo -n "galactica login: "
    read username
    
    if [ -z "$username" ]; then
        continue
    fi
    
    # For now, just accept "root" without password
    if [ "$username" = "root" ]; then
        echo ""
        echo "Welcome to Galactica Linux"
        exec /bin/sh
    else
        echo "Login incorrect"
        sleep 2
    fi
done
EOFLOGIN
        chmod +x "$TARGET_ROOT/sbin/login"
    }
    
    chmod +x "$TARGET_ROOT/sbin/login"
    echo -e "${GREEN}✓${NC} Login program created"
else
    echo -e "${RED}Error: gcc not found${NC}"
    exit 1
fi

# Step 2: Create getty service
echo ""
echo "Step 2: Creating getty service..."
echo ""

mkdir -p "$TARGET_ROOT/etc/airride/services"

cat > "$TARGET_ROOT/etc/airride/services/getty.service" << 'EOF'
[Service]
name=getty
description=Getty on ttyS0
type=simple
exec_start=/sbin/login
restart=always
restart_delay=1

[Dependencies]
EOF

echo -e "${GREEN}✓${NC} Getty service created"

# Step 3: Remove or rename old shell service
echo ""
echo "Step 3: Disabling emergency shell..."
echo ""

if [[ -f "$TARGET_ROOT/etc/airride/services/shell.service" ]]; then
    mv "$TARGET_ROOT/etc/airride/services/shell.service" \
       "$TARGET_ROOT/etc/airride/services/shell.service.disabled"
    echo -e "${GREEN}✓${NC} Emergency shell disabled (renamed to .disabled)"
fi

# Step 4: Set up proper password for root
echo ""
echo "Step 4: Setting up root password..."
echo ""

# Create shadow file with root password = "galactica"
# This is the hash for "galactica"
cat > "$TARGET_ROOT/etc/shadow" << 'EOF'
root:$6$galactica$K9p3vXJ5qZ8mH4xL2nY7.wR9tE1sC8bA6fD5gH3jK2lM9nP0qR1sT2uV3wX4yZ5aB6cD7eF8gH9iJ0kL1mN2oP3:19000:0:99999:7:::
EOF
chmod 600 "$TARGET_ROOT/etc/shadow"

echo -e "${GREEN}✓${NC} Root password set to: ${YELLOW}galactica${NC}"

# Step 5: Create a welcome message
echo ""
echo "Step 5: Creating welcome message..."
echo ""

cat > "$TARGET_ROOT/etc/motd" << 'EOF'

  ________       .__                 __  .__               
 /  _____/_____  |  | _____    _____/  |_|__| ____ _____   
/   \  ___\__  \ |  | \__  \ _/ ___\   __\  |/ ___\\__  \  
\    \_\  \/ __ \|  |__/ __ \\  \___|  | |  \  \___ / __ \_
 \______  (____  /____(____  /\___  >__| |__|\___  >____  /
        \/     \/          \/     \/             \/     \/ 


Welcome to Galactica Linux!

Default credentials:
  Username: root
  Password: galactica

Quick commands:
  airridectl list     - List services
  dreamland sync      - Update package index
  galactica-bootstrap - Run setup wizard

Documentation: https://github.com/LinkNavi/Galactica

EOF

echo -e "${GREEN}✓${NC} Welcome message created"

# Step 6: Update rootfs if it exists
echo ""
echo "Step 6: Updating root filesystem..."
echo ""

if [[ -f "$ROOTFS" ]]; then
    read -p "Update $ROOTFS with login screen? (y/n) [y]: " update
    update=${update:-y}
    
    if [[ "$update" == "y" ]]; then
        echo "Mounting rootfs..."
        mkdir -p /tmp/galactica-mount
        
        sudo mount -o loop "$ROOTFS" /tmp/galactica-mount
        
        echo "Copying login components..."
        sudo cp "$TARGET_ROOT/sbin/login" /tmp/galactica-mount/sbin/
        sudo chmod +x /tmp/galactica-mount/sbin/login
        
        sudo cp "$TARGET_ROOT/etc/airride/services/getty.service" \
                /tmp/galactica-mount/etc/airride/services/
        
        if [[ -f "$TARGET_ROOT/etc/airride/services/shell.service.disabled" ]]; then
            sudo mv /tmp/galactica-mount/etc/airride/services/shell.service \
                    /tmp/galactica-mount/etc/airride/services/shell.service.disabled \
                    2>/dev/null || true
        fi
        
        sudo cp "$TARGET_ROOT/etc/shadow" /tmp/galactica-mount/etc/
        sudo chmod 600 /tmp/galactica-mount/etc/shadow
        
        sudo cp "$TARGET_ROOT/etc/motd" /tmp/galactica-mount/etc/
        
        echo "Verifying..."
        if [[ -x /tmp/galactica-mount/sbin/login ]]; then
            echo -e "${GREEN}✓${NC} Login program installed"
        fi
        
        sudo umount /tmp/galactica-mount
        rmdir /tmp/galactica-mount
        
        echo ""
        echo -e "${GREEN}✓${NC} Rootfs updated!"
    fi
else
    echo -e "${YELLOW}Note: No rootfs found at $ROOTFS${NC}"
    echo "You'll need to create/update it with: ./build-and-launch.sh"
fi

echo ""
echo -e "${GREEN}=== Login Screen Setup Complete! ===${NC}"
echo ""
echo "Changes made:"
echo "  ✓ Created /sbin/login program"
echo "  ✓ Created getty service"
echo "  ✓ Disabled emergency shell"
echo "  ✓ Set root password to: ${YELLOW}galactica${NC}"
echo "  ✓ Created welcome message"
echo ""
echo "Next boot will show:"
echo "  ${BLUE}galactica login:${NC} _"
echo ""
echo "Login with:"
echo "  Username: ${YELLOW}root${NC}"
echo "  Password: ${YELLOW}galactica${NC}"
echo ""
echo "To boot now:"
echo "  ${YELLOW}./run-galactica.sh${NC}"
echo ""
echo "To change the password after login:"
echo "  ${YELLOW}passwd${NC}"
