#!/bin/bash
set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}[✓]${NC} $1"; }
fail() { echo -e "${RED}[✗]${NC} $1"; }
info() { echo -e "${CYAN}[→]${NC} $1"; }

echo -e "${CYAN}=== Galactica Docker Test Suite ===${NC}"
echo ""

# Build
info "Building images..."
docker build -t galactica:test . --target runtime --quiet && ok "Build succeeded" || { fail "Build failed"; exit 1; }

# Test 1: binaries exist and run
info "Testing binaries..."
docker run --rm galactica:test /sbin/airride --help 2>/dev/null; true
docker run --rm galactica:test /usr/bin/airridectl 2>&1 | grep -q "Usage" && ok "airridectl OK" || fail "airridectl broken"
docker run --rm galactica:test /usr/bin/dreamland 2>&1 | grep -q "sync\|Usage\|★" && ok "dreamland OK" || fail "dreamland broken"

# Test 2: AirRide socket control (runs airride in bg, tests ctl)
info "Testing AirRide control socket..."
docker run --rm --privileged -d --name airride-sock-test galactica:test /sbin/airride > /dev/null
sleep 2
docker exec airride-sock-test /usr/bin/airridectl list 2>&1 | grep -qi "service\|shell" && ok "AirRide socket OK" || fail "AirRide socket broken"
docker stop airride-sock-test > /dev/null

# Test 3: Dreamland sync (needs network)
info "Testing Dreamland sync (requires internet)..."
docker run --rm galactica:test /usr/bin/dreamland sync 2>&1 | grep -qi "sync\|package\|★" && ok "Dreamland sync OK" || echo -e "${YELLOW}[!]${NC} Dreamland sync skipped (no internet?)"

# Test 4: Service file parsing
info "Testing service loading..."
docker run --rm --privileged \
    -v "$(pwd)/docker/services:/etc/airride/services:ro" \
    galactica:test \
    /bin/bash -c "/sbin/airride & sleep 3 && /usr/bin/airridectl list && kill %1" \
    2>&1 | grep -qi "service" && ok "Service loading OK" || fail "Service loading broken"

echo ""
echo -e "${GREEN}Tests complete.${NC} Run interactively with:"
echo "  docker run --rm -it --privileged galactica:test"
