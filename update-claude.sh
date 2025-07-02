#!/usr/bin/env bash
set -euo pipefail

# Get the latest version from npm
echo "Checking latest version of @anthropic-ai/claude-code..."
LATEST_VERSION=$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r '.version')
echo "Latest version: $LATEST_VERSION"

# Get current version from default.nix
CURRENT_VERSION=$(grep -oP 'version = "\K[^"]*' default.nix)
echo "Current version: $CURRENT_VERSION"

if [ "$LATEST_VERSION" = "$CURRENT_VERSION" ]; then
    echo "Already up to date!"
    exit 0
fi

echo "New version available: $LATEST_VERSION"

# Download the new tarball and get its hash
TARBALL_URL="https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${LATEST_VERSION}.tgz"
echo "Downloading $TARBALL_URL..."

# Use nix-prefetch-url to get the correct hash
NEW_HASH=$(nix-prefetch-url --type sha256 "$TARBALL_URL")
echo "New hash: $NEW_HASH"

# Update default.nix with new version and hash
echo "Updating default.nix..."
sed -i "s/version = \".*\";/version = \"$LATEST_VERSION\";/" default.nix
sed -i "s/sha256 = \".*\";/sha256 = \"$NEW_HASH\";/" default.nix

echo "Updated default.nix:"
echo "  Version: $CURRENT_VERSION -> $LATEST_VERSION"
echo "  Hash: updated"

echo ""
echo "You can now run 'nix build' to test the update."