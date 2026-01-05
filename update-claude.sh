#!/usr/bin/env bash
set -euo pipefail

WITH_LOCAL_REPO=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --with-local-repo)
            WITH_LOCAL_REPO=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

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

if [ "$WITH_LOCAL_REPO" = true ]; then
    echo ""
    echo "=== Local repo workflow ==="

    # Step b: Run flake-lint -f
    echo "Running flake-lint -f..."
    flake-lint -f

    # Step c: nix flake update
    echo "Running nix flake update..."
    nix flake update

    # Step d: Git commit
    echo "Committing changes..."
    git add -A
    git commit -m "chore: update to v${LATEST_VERSION}"

    # Step e: Git tag
    echo "Tagging v${LATEST_VERSION}..."
    git tag "v${LATEST_VERSION}"

    # Step f: Push to gitea
    echo "Pushing to gitea..."
    git push gitea main
    git push gitea "v${LATEST_VERSION}"

    # Step g: Run flake-lint -r
    echo "Running flake-lint -r..."
    flake-lint -r

    # Step h: nix flake update
    echo "Running nix flake update..."
    nix flake update

    # Step i: Amend commit and re-tag
    echo "Amending commit..."
    git add -A
    git commit --amend --no-edit

    echo "Re-tagging v${LATEST_VERSION}..."
    git tag -d "v${LATEST_VERSION}"
    git tag "v${LATEST_VERSION}"

    # Step j: Push to origin
    echo "Pushing to origin..."
    git push origin main
    git push origin "v${LATEST_VERSION}"

    echo ""
    echo "=== Local repo workflow complete ==="
fi