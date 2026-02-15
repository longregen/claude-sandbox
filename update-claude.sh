#!/usr/bin/env bash
set -euo pipefail

# Get the latest version from npm
echo "Checking latest version of @anthropic-ai/claude-code..."
LATEST_VERSION=$(curl -s https://registry.npmjs.org/@anthropic-ai/claude-code/latest | jq -r '.version')
echo "Latest version: $LATEST_VERSION"

# Get current version from default.nix
CURRENT_VERSION=$(grep -oP 'version = "\K[^"]*' default.nix)
echo "Current version: $CURRENT_VERSION"

if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
    echo "New version available: $LATEST_VERSION"

    # Download the new tarball and get its hash
    TARBALL_URL="https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${LATEST_VERSION}.tgz"
    echo "Downloading $TARBALL_URL..."

    NEW_HASH=$(nix-prefetch-url --type sha256 "$TARBALL_URL")
    echo "New hash: $NEW_HASH"

    echo "Updating default.nix..."
    sed -i "s/version = \".*\";/version = \"$LATEST_VERSION\";/" default.nix
    sed -i "s/sha256 = \".*\";/sha256 = \"$NEW_HASH\";/" default.nix

    echo "  Version: $CURRENT_VERSION -> $LATEST_VERSION"
fi

echo "Running nix flake update..."
nix flake update

if [ -z "$(git status --porcelain)" ]; then
    echo "No changes to commit."
else
    echo "Committing changes..."
    git add -A
    git commit -m "chore: update to v${LATEST_VERSION}"
fi

if git rev-parse "v${LATEST_VERSION}" >/dev/null 2>&1; then
    echo "Tag v${LATEST_VERSION} already exists."
else
    echo "Tagging v${LATEST_VERSION}..."
    git tag "v${LATEST_VERSION}"
fi

echo "Pushing to origin..."
git push -f origin main
git push -f origin "v${LATEST_VERSION}"
