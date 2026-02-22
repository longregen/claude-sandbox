#!/usr/bin/env bash
set -euo pipefail

GCS_BASE="https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases"

# Get the latest version from the GCS release channel
echo "Checking latest version of Claude Code..."
LATEST_VERSION=$(curl -sf "$GCS_BASE/latest")
echo "Latest version: $LATEST_VERSION"

# Get current version from default.nix
CURRENT_VERSION=$(grep -oP 'version = "\K[^"]*' default.nix)
echo "Current version: $CURRENT_VERSION"

if [ "$LATEST_VERSION" != "$CURRENT_VERSION" ]; then
    echo "New version available: $LATEST_VERSION"

    # Fetch the release manifest for checksum verification
    echo "Fetching manifest..."
    MANIFEST=$(curl -sf "$GCS_BASE/$LATEST_VERSION/manifest.json")
    EXPECTED_SHA256=$(echo "$MANIFEST" | jq -r '.platforms["linux-x64"].checksum')
    if [ -z "$EXPECTED_SHA256" ] || [ "$EXPECTED_SHA256" = "null" ]; then
        echo "ERROR: Could not extract linux-x64 checksum from manifest" >&2
        echo "$MANIFEST" >&2
        exit 1
    fi
    echo "Manifest SHA256: $EXPECTED_SHA256"

    # Download the native binary and compute its Nix hash
    BINARY_URL="$GCS_BASE/$LATEST_VERSION/linux-x64/claude"
    echo "Downloading $BINARY_URL..."

    PREFETCH_OUTPUT=$(nix-prefetch-url --type sha256 --print-path "$BINARY_URL")
    NEW_HASH=$(echo "$PREFETCH_OUTPUT" | head -1)
    NIX_STORE_PATH=$(echo "$PREFETCH_OUTPUT" | tail -1)

    # Verify download against the manifest checksum
    ACTUAL_SHA256=$(sha256sum "$NIX_STORE_PATH" | cut -d' ' -f1)
    if [ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]; then
        echo "ERROR: SHA256 checksum mismatch!" >&2
        echo "  Manifest expects: $EXPECTED_SHA256" >&2
        echo "  Binary has:       $ACTUAL_SHA256" >&2
        exit 1
    fi
    echo "Checksum verified: $ACTUAL_SHA256"

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
