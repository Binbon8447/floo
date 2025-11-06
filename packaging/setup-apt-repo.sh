#!/bin/bash
#
# Set up APT repository structure and generate repository metadata
# This script creates an APT repository that can be hosted on GitHub Pages
#
# Usage: ./setup-apt-repo.sh REPO_DIR VERSION
# Example: ./setup-apt-repo.sh apt-repo 0.1.2

set -e

if [ -z "$1" ] || [ -z "$2" ]; then
    echo "Usage: $0 REPO_DIR VERSION"
    echo "Example: $0 apt-repo 0.1.2"
    exit 1
fi

REPO_DIR="$1"
VERSION="$2"

# Check for required tools
if ! command -v dpkg-scanpackages &> /dev/null; then
    echo "Error: dpkg-scanpackages not found. Install with: apt-get install dpkg-dev"
    exit 1
fi

echo "Setting up APT repository in ${REPO_DIR}..."
echo ""

# Create repository structure
mkdir -p "${REPO_DIR}/pool/main"
mkdir -p "${REPO_DIR}/dists/stable/main/binary-amd64"
mkdir -p "${REPO_DIR}/dists/stable/main/binary-arm64"

# Copy .deb packages
echo "Copying .deb packages..."
cp build-deb/floo_${VERSION}-1_amd64.deb "${REPO_DIR}/pool/main/"
cp build-deb/floo_${VERSION}-1_arm64.deb "${REPO_DIR}/pool/main/"

# Generate Packages files
echo "Generating Packages files..."
cd "${REPO_DIR}"

# amd64
dpkg-scanpackages --arch amd64 pool/ > dists/stable/main/binary-amd64/Packages
gzip -k -f dists/stable/main/binary-amd64/Packages

# arm64
dpkg-scanpackages --arch arm64 pool/ > dists/stable/main/binary-arm64/Packages
gzip -k -f dists/stable/main/binary-arm64/Packages

# Generate Release file
cat > dists/stable/Release << EOF
Origin: Floo
Label: Floo
Suite: stable
Codename: stable
Version: 1.0
Architectures: amd64 arm64
Components: main
Description: Floo APT Repository - High-performance tunneling in Zig
Date: $(date -R)
EOF

# Calculate checksums for Release file
echo "MD5Sum:" >> dists/stable/Release
find dists/stable/main -type f -exec md5sum {} \; | sed 's|dists/stable/||' >> dists/stable/Release

echo "SHA1:" >> dists/stable/Release
find dists/stable/main -type f -exec sha1sum {} \; | sed 's|dists/stable/||' >> dists/stable/Release

echo "SHA256:" >> dists/stable/Release
find dists/stable/main -type f -exec sha256sum {} \; | sed 's|dists/stable/||' >> dists/stable/Release

cd ..

echo ""
echo "=== APT Repository Created ==="
echo "Location: ${REPO_DIR}"
echo ""
echo "Repository structure:"
tree "${REPO_DIR}" 2>/dev/null || find "${REPO_DIR}" -type f

echo ""
echo "=== Next Steps ==="
echo ""
echo "Option 1: Host on GitHub Pages"
echo "  1. Create a new repo: floo-apt"
echo "  2. Copy ${REPO_DIR}/* to the repo"
echo "  3. Enable GitHub Pages (Settings → Pages → Branch: main)"
echo "  4. Users add with:"
echo "     curl -fsSL https://USERNAME.github.io/floo-apt/pubkey.gpg | sudo gpg --dearmor -o /usr/share/keyrings/floo.gpg"
echo "     echo 'deb [signed-by=/usr/share/keyrings/floo.gpg] https://USERNAME.github.io/floo-apt stable main' | sudo tee /etc/apt/sources.list.d/floo.list"
echo "     sudo apt update"
echo "     sudo apt install floo"
echo ""
echo "Option 2: Sign with GPG (Recommended for production)"
echo "  1. Generate GPG key:"
echo "     gpg --full-generate-key"
echo "  2. Sign Release file:"
echo "     cd ${REPO_DIR}/dists/stable"
echo "     gpg --default-key YOUR_KEY_ID -abs -o Release.gpg Release"
echo "     gpg --default-key YOUR_KEY_ID --clearsign -o InRelease Release"
echo "  3. Export public key:"
echo "     gpg --armor --export YOUR_KEY_ID > ${REPO_DIR}/pubkey.gpg"
echo ""
echo "Option 3: Use cloudsmith.io or packagecloud.io"
echo "  These services provide free APT hosting for open source projects"
