#!/bin/bash
#
# Calculate SHA256 checksums for Floo release artifacts
# Usage: ./calculate-checksums.sh VERSION
# Example: ./calculate-checksums.sh v0.1.2

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 VERSION"
    echo "Example: $0 v0.1.2"
    exit 1
fi

VERSION=$1
BASE_URL="https://github.com/YUX/floo/releases/download/${VERSION}"

# Create temp directory
TEMP_DIR=$(mktemp -d)
cd "$TEMP_DIR"

echo "Downloading release artifacts for $VERSION..."
echo ""

# Homebrew artifacts
echo "=== Homebrew (macOS) ==="
wget -q "${BASE_URL}/floo-aarch64-macos-m1.tar.gz"
wget -q "${BASE_URL}/floo-x86_64-macos-haswell.tar.gz"

echo "ARM64 (Apple Silicon M1+):"
if command -v shasum &> /dev/null; then
    shasum -a 256 floo-aarch64-macos-m1.tar.gz
else
    sha256sum floo-aarch64-macos-m1.tar.gz
fi

echo ""
echo "x86_64 (Intel Haswell+):"
if command -v shasum &> /dev/null; then
    shasum -a 256 floo-x86_64-macos-haswell.tar.gz
else
    sha256sum floo-x86_64-macos-haswell.tar.gz
fi

echo ""
echo "=== AUR (Linux) ==="
wget -q "${BASE_URL}/floo-x86_64-linux-gnu-haswell.tar.gz"
wget -q "${BASE_URL}/floo-aarch64-linux-gnu.tar.gz"

echo "x86_64 (Haswell+):"
if command -v shasum &> /dev/null; then
    shasum -a 256 floo-x86_64-linux-gnu-haswell.tar.gz
else
    sha256sum floo-x86_64-linux-gnu-haswell.tar.gz
fi

echo ""
echo "aarch64:"
if command -v shasum &> /dev/null; then
    shasum -a 256 floo-aarch64-linux-gnu.tar.gz
else
    sha256sum floo-aarch64-linux-gnu.tar.gz
fi

# Cleanup
cd -
rm -rf "$TEMP_DIR"

echo ""
echo "Done! Update the checksums in:"
echo "  - packaging/homebrew/floo.rb"
echo "  - packaging/aur/PKGBUILD"
