#!/usr/bin/env python3
"""
patch-sudo.py
Patches build-and-launch.sh to copy the sudo and su binaries
from the host into the Galactica rootfs with proper SUID bits.

Usage:  python3 patch-sudo.py [build-and-launch.sh]
"""

import sys, pathlib, shutil, datetime

TARGET = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "build-and-launch.sh")

if not TARGET.exists():
    print(f"Error: {TARGET} not found")
    sys.exit(1)

backup = TARGET.with_suffix(f".bak.{datetime.datetime.now():%Y%m%d%H%M%S}")
shutil.copy2(TARGET, backup)
print(f"Backup saved to {backup}")

text = TARGET.read_text()

# ============================================================
# Inject sudo/su copy block into install_essentials()
# We anchor to the existing "copy_libs" loop that copies
# the dreamland/airride binaries — insert right after it.
# ============================================================

ANCHOR = '    for binary in "$TARGET_ROOT/sbin/airride" "$TARGET_ROOT/sbin/poyo" "$TARGET_ROOT/usr/bin/airridectl" "$TARGET_ROOT/usr/bin/dreamland"; do\n        copy_libs "$binary"\n    done'

SUDO_BLOCK = '''    for binary in "$TARGET_ROOT/sbin/airride" "$TARGET_ROOT/sbin/poyo" "$TARGET_ROOT/usr/bin/airridectl" "$TARGET_ROOT/usr/bin/dreamland"; do
        copy_libs "$binary"
    done

    # ---- sudo / su (SUID binaries) ----
    print_info "Installing sudo and su..."
    for tool in sudo su; do
        TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
        if [[ -n "$TOOL_PATH" ]]; then
            cp "$TOOL_PATH" "$TARGET_ROOT/usr/bin/$tool"
            copy_libs "$TOOL_PATH"
            sudo chown root:root "$TARGET_ROOT/usr/bin/$tool"
            sudo chmod 4755    "$TARGET_ROOT/usr/bin/$tool"
            print_success "$tool installed with SUID"
        else
            print_warning "$tool not found on host — skipping"
        fi
    done
    # Symlink su into /bin as well (some scripts expect it there)
    ln -sf ../usr/bin/su "$TARGET_ROOT/bin/su" 2>/dev/null || true'''

if ANCHOR in text:
    text = text.replace(ANCHOR, SUDO_BLOCK, 1)
    print("  ✓ Injected sudo/su copy block into install_essentials()")
else:
    print("  ! Primary anchor not found, trying fallback...")
    # Fallback: anchor on the static curl download block
    FALLBACK_ANCHOR = '    # Install static curl for HTTPS support'
    SUDO_INJECT = '''    # ---- sudo / su (SUID binaries) ----
    print_info "Installing sudo and su..."
    for tool in sudo su; do
        TOOL_PATH=$(command -v "$tool" 2>/dev/null || true)
        if [[ -n "$TOOL_PATH" ]]; then
            cp "$TOOL_PATH" "$TARGET_ROOT/usr/bin/$tool"
            copy_libs "$TOOL_PATH"
            sudo chown root:root "$TARGET_ROOT/usr/bin/$tool"
            sudo chmod 4755    "$TARGET_ROOT/usr/bin/$tool"
            print_success "$tool installed with SUID"
        else
            print_warning "$tool not found on host — skipping"
        fi
    done
    ln -sf ../usr/bin/su "$TARGET_ROOT/bin/su" 2>/dev/null || true

    # Install static curl for HTTPS support'''
    if FALLBACK_ANCHOR in text:
        text = text.replace(FALLBACK_ANCHOR, SUDO_INJECT, 1)
        print("  ✓ Injected sudo/su copy block (fallback anchor)")
    else:
        print("  ! Could not find injection point — no changes made")
        sys.exit(1)

# ============================================================
# Make sure the SUID chmod in create_system_files() also
# covers /usr/bin/sudo explicitly (it may only list /bin/su).
# Find the suid bits loop and ensure both paths are present.
# ============================================================

import re

# The existing loop looks like:
# for bin in "/bin/su" "/usr/bin/sudo" "/bin/mount" "/bin/umount"; do
# If sudo is already there, this is a no-op. If not, add it.
suid_pattern = r'(for bin in[^;]+do\s*\n\s*path="\$TARGET_ROOT\$bin"[^\n]+\n\s*\[\[.*?\]\].*?chmod.*?\n\s*done)'

def ensure_sudo_in_suid(match):
    block = match.group(1)
    if '/usr/bin/sudo' not in block:
        block = block.replace('for bin in "', 'for bin in "/usr/bin/sudo" "', 1)
    if '/usr/bin/su' not in block and '"/usr/bin/sudo"' in block:
        block = block.replace('"/usr/bin/sudo"', '"/usr/bin/sudo" "/usr/bin/su"', 1)
    return block

text, n = re.subn(suid_pattern, ensure_sudo_in_suid, text, flags=re.DOTALL)
if n:
    print("  ✓ Verified SUID chmod loop covers sudo and su")
else:
    # Just do a simple string patch on the known line
    old_suid = 'for bin in "/bin/su" "/usr/bin/sudo" "/bin/mount" "/bin/umount"'
    new_suid = 'for bin in "/bin/su" "/usr/bin/sudo" "/usr/bin/su" "/bin/mount" "/bin/umount"'
    if old_suid in text:
        text = text.replace(old_suid, new_suid, 1)
        print("  ✓ Updated SUID chmod loop")
    else:
        print("  ! SUID chmod loop not found — sudo will still work but SUID is set during copy")

TARGET.write_text(text)
print(f"\nPatch applied to {TARGET}")
print(f"Backup at {backup}")
