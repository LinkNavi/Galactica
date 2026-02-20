#!/bin/bash
# Fixes two bugs in build-and-launch.sh:
# 1. Missing if/fi wrapper around kernel config block
# 2. copy_libs defined inside install_essentials but called from bundle_wifi_tools

set -e
TARGET="./build-and-launch.sh"

[[ ! -f "$TARGET" ]] && { echo "Error: $TARGET not found"; exit 1; }

cp "$TARGET" "${TARGET}.bak"
echo "Backup saved to ${TARGET}.bak"

# ── Fix 1: wrap the dangling kernel config block ──────────────────────────────
# Remove the orphaned blank+indent before print_info and wrap with if/fi
python3 - "$TARGET" << 'PYEOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    src = f.read()

# The broken pattern: fi (from gcc check), blank lines, then indented block with no if
old = '''    fi
    

        print_info "Creating kernel config with full networking..."
        make mrproper 2>/dev/null || true
        make tinyconfig || make allnoconfig'''

new = '''    fi

    if [[ ! -f arch/x86/boot/bzImage ]]; then
        print_info "Creating kernel config with full networking..."
        make mrproper 2>/dev/null || true
        make tinyconfig || make allnoconfig'''

if old not in src:
    print("ERROR: Could not find kernel config block to patch. Check the script manually.")
    sys.exit(1)

src = src.replace(old, new, 1)

# Now fix the closing: olddefconfig followed by blank then verify comment — insert fi
old2 = '''        make olddefconfig

    
    # Verify critical options'''

new2 = '''        make olddefconfig
    fi

    # Verify critical options'''

if old2 not in src:
    print("ERROR: Could not find olddefconfig closing to patch.")
    sys.exit(1)

src = src.replace(old2, new2, 1)

with open(sys.argv[1], 'w') as f:
    f.write(src)

print("Fix 1 applied: kernel config if/fi wrapper")
PYEOF

# ── Fix 2: promote copy_libs to top-level function ────────────────────────────
python3 - "$TARGET" << 'PYEOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    src = f.read()

# The top-level copy_libs function to inject after the print_* helpers
COPY_LIBS_FUNC = '''
copy_libs() {
    local binary=$1
    [[ ! -f "$binary" ]] && return
    ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
        [[ -f "$lib" && ! -f "$TARGET_ROOT$lib" ]] && {
            mkdir -p "$TARGET_ROOT$(dirname $lib)"
            cp "$lib" "$TARGET_ROOT$lib" 2>/dev/null || true
        }
    done
}

'''

# Inject after the last print_* helper (print_info line)
inject_after = '''print_info() { echo -e "${CYAN}→${NC} $1"; }'''

if inject_after not in src:
    print("ERROR: Could not find print_info line to inject after.")
    sys.exit(1)

if 'copy_libs()' in src.split(inject_after)[0]:
    print("copy_libs already at top level, skipping injection")
else:
    src = src.replace(inject_after, inject_after + COPY_LIBS_FUNC, 1)
    print("Fix 2a applied: copy_libs injected as top-level function")

# Remove the local copy_libs definition inside install_essentials
local_def = '''    copy_libs() {
        local binary=$1
        [[ ! -f "$binary" ]] && return
        ldd "$binary" 2>/dev/null | grep -o '/[^ ]*' | while read lib; do
            [[ -f "$lib" && ! -f "$TARGET_ROOT$lib" ]] && { mkdir -p "$TARGET_ROOT$(dirname $lib)"; cp "$lib" "$TARGET_ROOT$lib" 2>/dev/null || true; }
        done
    }
    
    for binary'''

replacement = '''    for binary'''

if local_def in src:
    src = src.replace(local_def, replacement, 1)
    print("Fix 2b applied: removed local copy_libs from install_essentials")
else:
    print("WARNING: local copy_libs definition not found (may already be removed)")

with open(sys.argv[1], 'w') as f:
    f.write(src)
PYEOF

# ── Verify syntax ─────────────────────────────────────────────────────────────
echo ""
if bash -n "$TARGET" 2>&1; then
    echo "✓ Syntax check passed"
else
    echo "✗ Syntax errors remain — restoring backup"
    cp "${TARGET}.bak" "$TARGET"
    exit 1
fi

echo "Done. Run: ./build-and-launch.sh"
