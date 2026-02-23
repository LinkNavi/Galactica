#!/bin/bash
KERNEL_VERSION="${1:-6.18.4}"
REPO="LinkNavi/Galactica"
ARTIFACT_NAME="galactica-kernel-${KERNEL_VERSION}"
KERNELS_DIR="$HOME/kernels/galactica"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
err()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[→]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }

command -v gh &>/dev/null || err "gh CLI not found"

info "Fetching latest completed run for workflow build-kernel.yml..."
RUN_ID=$(gh run list --repo "$REPO" --workflow build-kernel.yml --status success --limit 1 --json databaseId --jq '.[0].databaseId')
[[ -z "$RUN_ID" ]] && err "No successful runs found"
ok "Found run: $RUN_ID"

info "Downloading artifact: $ARTIFACT_NAME..."
TMPDIR=$(mktemp -d)
gh run download "$RUN_ID" --repo "$REPO" --name "$ARTIFACT_NAME" --dir "$TMPDIR" || err "Download failed"
ok "Downloaded to $TMPDIR"

TARBALL=$(find "$TMPDIR" -name "*.tar.gz" | head -1)
[[ -z "$TARBALL" ]] && err "No tarball found in artifact"

info "Extracting to $KERNELS_DIR..."
mkdir -p "$KERNELS_DIR"
tar -xzf "$TARBALL" -C "$KERNELS_DIR"
ok "Extracted"

# Verify
[[ -f "$KERNELS_DIR/boot/vmlinuz-galactica" ]] && ok "Kernel image present" || warn "Kernel image missing"
[[ -d "$KERNELS_DIR/lib/modules/$KERNEL_VERSION" ]] && ok "Modules present" || warn "Modules missing"

rm -rf "$TMPDIR"
ok "Done — kernel and modules ready in $KERNELS_DIR"
