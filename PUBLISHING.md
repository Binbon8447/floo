# Publishing Checklist

Quick reference for releasing a new version of Floo to all distribution channels.

## Pre-Release

- [ ] All tests pass: `zig build test`
- [ ] Update version in `build.zig.zon`
- [ ] Update CHANGELOG or release notes
- [ ] Commit changes: `git commit -am "Bump version to X.Y.Z"`

## Create Release

```bash
# Tag the release
git tag vX.Y.Z
git push origin main --tags

# GitHub Actions will automatically:
# - Run tests
# - Build all platform binaries
# - Create GitHub release with artifacts
```

## Update Package Managers

### 1. Calculate Checksums

```bash
./packaging/calculate-checksums.sh vX.Y.Z
```

This will output SHA256 checksums for all release artifacts.

### 2. Update Homebrew

```bash
# Clone your tap (first time only)
git clone https://github.com/YUX/homebrew-floo

cd homebrew-floo

# Update Formula/floo.rb with:
# - New version number
# - New SHA256 checksums (from step 1)

git add Formula/floo.rb
git commit -m "Update Floo to vX.Y.Z"
git push
```

**Users will update with**: `brew update && brew upgrade floo`

### 3. Update AUR

```bash
# Clone AUR repo (first time only)
git clone ssh://aur@aur.archlinux.org/floo.git floo-aur

cd floo-aur

# Copy latest PKGBUILD
cp ../floo/packaging/aur/PKGBUILD .

# Update PKGBUILD with:
# - pkgver=X.Y.Z
# - pkgrel=1 (increment for each re-release of same version)
# - New SHA256 checksums (from step 1)

# Generate .SRCINFO
makepkg --printsrcinfo > .SRCINFO

# Commit and push
git add PKGBUILD .SRCINFO
git commit -m "Update to vX.Y.Z"
git push
```

**Users will update with**: `yay -Syu floo` or `paru -Syu floo`

### 4. APT Repository (Automated)

APT packages are automatically built and published via GitHub Actions when you create a release.

**Manual trigger** (if needed):
```bash
gh workflow run publish-apt.yml -f version=X.Y.Z
```

**Users will update with**: `sudo apt update && sudo apt upgrade floo`

### 5. Snap (Automated)

Snap packages are automatically built and published via GitHub Actions when you create a release.

**Manual trigger** (if needed):
```bash
gh workflow run publish-snap.yml -f version=X.Y.Z
```

**Users will update with**: `sudo snap refresh floo`

## Post-Release

- [ ] Test installation from each package manager
- [ ] Announce release (social media, mailing lists, etc.)
- [ ] Close milestone (if using GitHub milestones)

## First-Time Setup

### Homebrew Tap

1. Create GitHub repo: `homebrew-floo`
2. Add formula: `mkdir Formula && cp packaging/homebrew/floo.rb Formula/`
3. Push to GitHub

### AUR Account

1. Register at https://aur.archlinux.org/register
2. Add SSH key to AUR account
3. Set git config:
   ```bash
   git config --global user.name "Your Name"
   git config --global user.email "your.email@example.com"
   ```

### APT Repository

1. Create GitHub repo: `floo-apt`
2. Enable GitHub Pages (Settings → Pages → Branch: main)
3. Add `APT_REPO_TOKEN` secret to main repo (personal access token with repo write)
4. Workflow runs automatically on each release

### Snap Store

1. Create account at https://snapcraft.io/
2. Register snap name: `snapcraft register floo`
3. Export credentials: `snapcraft export-login --snaps=floo --channels=stable snapcraft-token.txt`
4. Add contents as `SNAPCRAFT_TOKEN` secret in GitHub repo
5. Workflow runs automatically on each release

See [packaging/README.md](packaging/README.md) for detailed instructions.
