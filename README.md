# Sandboxed Claude Code

This project provides a sandboxed environment for running Claude Code using Nix and bubblewrap.

** WARNING **: It was not properly security reviewed. It's just a stub. Don't use it outside of a VM.


## Usage

On NixOS systems, run `nix run github:longregen/claude-sandbox`

## What's Mounted

### Essential System Files
- `/etc/ssl` - SSL certificates for HTTPS
- `/etc/resolv.conf` - DNS resolution
- `/nix` - Nix store (read-only)

### Development Directories
- Current working directory (read-write)
- Development cache directories (if they exist):
  - `.go`, `.pip`, `.deno`, `.pnpm`, `.yarn`, `.uv`
  - `.huggingface`, `.cached-nix-shell`, `.nix`, `.gradle`, `.zig`
  - Language server caches: `.gopls`, `.jedi`, `.lua-language-server`, etc.

## Development

The sandbox configuration is in `default.nix`. Key components:

- `sandboxWrapper`: Shell script that sets up the bubblewrap environment
- `ALLOWLIST`: Directories and files that are mounted in the sandbox

## Debugging

To see what the sandbox would execute without running it:
```bash
DRY_RUN=1 ./result/bin/claude-sandbox --help
```

To start a shell in the sandbox environment:
```bash
START_SHELL=1 ./result/bin/claude-sandbox


Tip: useful to run with strace to know what's going on.
