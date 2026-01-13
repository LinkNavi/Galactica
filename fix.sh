#!/bin/bash
# Update SOURCE_DIR in install.go to current directory

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_GO="$SCRIPT_DIR/GalacticaInstaller/src/install.go"

if [ ! -f "$INSTALL_GO" ]; then
    echo "Error: install.go not found at $INSTALL_GO"
    exit 1
fi

# Update SOURCE_DIR
sed -i "s|SOURCE_DIR.*=.*\"/.*\"|SOURCE_DIR  = \"$SCRIPT_DIR/galactica-build\"|" "$INSTALL_GO"

echo "Updated SOURCE_DIR in install.go to: $SCRIPT_DIR/galactica-build"
