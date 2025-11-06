#!/bin/bash
#
# Build Snap package locally
# Usage: ./build-snap.sh [VERSION]
# Example: ./build-snap.sh 0.1.2

set -e

VERSION=${1:-$(grep -oP '\.version = "\K[^"]+' ../build.zig.zon)}

echo "Building Snap package for Floo v${VERSION}..."
echo ""

# Check for snapcraft
if ! command -v snapcraft &> /dev/null; then
    echo "Error: snapcraft not found."
    echo "Install with: sudo snap install snapcraft --classic"
    exit 1
fi

# Update version in snapcraft.yaml
cd snap
sed -i.bak "s/^version:.*/version: '${VERSION}'/" snapcraft.yaml
rm -f snapcraft.yaml.bak

# Build snap
echo "Building snap..."
snapcraft

SNAP_FILE="floo_${VERSION}_$(dpkg --print-architecture).snap"

echo ""
echo "=== Snap built successfully ==="
echo "File: packaging/snap/${SNAP_FILE}"
echo ""
echo "To install locally:"
echo "  sudo snap install ${SNAP_FILE} --dangerous"
echo ""
echo "To test:"
echo "  floo.flooc --version"
echo "  floo.floos --version"
echo ""
echo "To publish to Snap Store:"
echo "  snapcraft upload ${SNAP_FILE} --release=stable"
