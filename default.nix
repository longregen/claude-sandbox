{ lib
, stdenv
, fetchFromGitHub
, buildNpmPackage
, nodejs_22
, bubblewrap
, makeWrapper
, writeShellScript
, fetchurl
, cacert
}:

let
  # Create the sandboxed wrapper script
  sandboxWrapper = writeShellScript "claude-sandbox" ''
    #!${stdenv.shell}
    
    # Create isolated sandbox home directory
    SANDBOX_HOME="/tmp/claude-sandbox-home-$$"
    SANDBOX_TMP="/tmp/claude-sandbox-tmp-$$"
    trap 'rm -rf "$SANDBOX_HOME" "$SANDBOX_TMP"' EXIT

    mkdir -p "$SANDBOX_TMP"
    mkdir -p "$SANDBOX_HOME"
    mkdir -p "$SANDBOX_HOME/.cache"
    mkdir -p "$SANDBOX_HOME/.config"
    # Make sure the working directory path exists in the sandbox  
    mkdir -p "$SANDBOX_HOME/$(echo "$PWD" | sed "s|^/home/$USER||")"
    USER=$(whoami)
    
    # Only allow access to current project directory and essential system files
    ALLOWLIST=(
      "$SANDBOX_HOME:/home/$USER"
      "$PWD"                # current project dir (read-write)
      "/etc/ssl"            # SSL certificates and config
      "/etc/resolv.conf"    # DNS resolution
      "/nix"
      "/etc/nix"            # Nix configuration
      "ro:/run/current-system/sw"
      "ro:/bin/sh"
      "$SANDBOX_TMP:/tmp"
      "$HOME/.claude.json"
      "$HOME/.claude"
      "$HOME/.config/claude"
    )
    CACHE_DIRS=(
      "go"
      "pip"
      "deno"
      "pnpm"
      "yarn"
      "uv"
      "huggingface"
      "cached-nix-shell"
      "nix"
      "nix-hug"
      "gradle"
      "zig"
      # Additional language-specific caches and tools
      "bun"
      "black"
      "gopls"
      "jedi"
      "lua-language-server"
      "pylint"
      "staticcheck"
      "typescript"
      "fish"
      "fontconfig"
      "prisma"
      "prisma-nodejs"
      "puppeteer"
      "tokenizer"
      "whisper"
    )
    for cache_dir in "''${CACHE_DIRS[@]}"; do
      if [ -d "$HOME/.cache/$cache_dir" ]; then
        ALLOWLIST+=( "$HOME/.cache/$cache_dir" )
      fi
    done

    # Add XDG config directories containing 'nix'
    if [ -d "$HOME/.config" ]; then
      for dir in "$HOME/.config"/*nix*; do
        if [ -d "$dir" ]; then
          ALLOWLIST+=( "$dir" )
        fi
      done
    fi
    
    # Add XDG data directories containing 'nix'
    if [ -d "$HOME/.local/share" ]; then
      for dir in "$HOME/.local/share"/*nix*; do
        if [ -d "$dir" ]; then
          ALLOWLIST+=( "$dir" )
        fi
      done
    fi

    whitelisted_envs=(
      "SHELL"
      "PATH"
      "HOME"
      "USER"
      "LOGNAME"
      "MAIL"
      "TERM"
      "SSL_CERT_FILE"
      "NIX_SSL_CERT_FILE"
      "CURL_CA_BUNDLE"
    )
    env_args=()
    for env in "''${whitelisted_envs[@]}"; do
      if [ -n "''${!env}" ]; then
        env_args+=( --setenv "$env" "''${!env}" )
      fi
    done
    env_args+=( --setenv "NODE_ENV" "production" )
    env_args+=( --setenv "SHELL" "$(readlink $(which $SHELL))" )

    # Build bwrap argument list
    args=(
      --unshare-all                         # isolate every namespace except network
      --unshare-user                        # isolate user namespace
      --unshare-pid                         # isolate pid namespace
      --unshare-uts                         # isolate uts namespace
      --unshare-ipc                         # isolate ipc namespace
      --share-net                           # keep Internet access for API calls
      --die-with-parent                     # auto-kill if parent shell exits
      --proc /proc --dev /dev               # minimal /proc and /dev
      --ro-bind /nix /nix                   # Nix store read-only
    )

    # Create /usr/bin directory and bind node
    args+=(
      --tmpfs /usr
      --dir /usr/bin
      --ro-bind ${nodejs_22}/bin/node /usr/bin/node
      "''${env_args[@]}"
    )

    # Check if env exists and bind it
    if [ -f "${nodejs_22}/bin/env" ]; then
      args+=(--ro-bind ${nodejs_22}/bin/env /usr/bin/env)
    fi

    for p in "''${ALLOWLIST[@]}"; do
      if [[ "$p" == ro:* ]]; then
        p="''${p#ro:}"; 
        if [ -e "$p" ]; then
          args+=( --ro-bind "$p" "$p" )
        fi
      elif [[ "$p" == *:* ]]; then
        source="''${p%%:*}"
        dest="''${p#*:}"
        if [ -e "$source" ]; then
          args+=( --bind "$source" "$dest" )
        fi
      else
        if [ -e "$p" ]; then
          args+=( --bind "$p" "$p" )
        fi
      fi
    done

    # Use the claude executable from the npm package
    if [ $DRY_RUN ]; then
      echo ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$out/bin/claude-achtung-achtung" "$@"
    elif [ $START_SHELL ]; then
      exec ${bubblewrap}/bin/bwrap "''${args[@]}" -- $(readlink $(which $SHELL))
    else
      exec ${bubblewrap}/bin/bwrap "''${args[@]}" -- "$out/bin/claude-achtung-achtung" "$@"
    fi
  '';

in stdenv.mkDerivation rec {
  pname = "claude-sandbox";
  version = "1.0.34";

  src = fetchurl {
    url = "https://registry.npmjs.org/@anthropic-ai/claude-code/-/claude-code-${version}.tgz";
    sha256 = "sha256-8f7XdvWRMv+icI8GMQW7AAmesdvpr/3SaWCRC723iSs=";
  };
  
  nativeBuildInputs = [ makeWrapper ];
  buildInputs = [ nodejs_22 bubblewrap cacert ];

  # No build phase needed
  dontBuild = true;

  installPhase = ''
    # Create directories
    mkdir -p $out/lib/node_modules/@anthropic-ai/claude-code
    mkdir -p $out/bin

    # Copy package contents
    cp -r * $out/lib/node_modules/@anthropic-ai/claude-code/
    rm -rf $out/lib/node_modules/@anthropic-ai/claude-code/{scripts,vendor}

    cat > $out/bin/claude-achtung-achtung << EOF
#!/usr/bin/env node
process.env.SSL_CERT_FILE = process.env.SSL_CERT_FILE || '${cacert}/etc/ssl/certs/ca-bundle.crt';
process.env.NIX_SSL_CERT_FILE = process.env.NIX_SSL_CERT_FILE || '${cacert}/etc/ssl/certs/ca-bundle.crt';
process.env.CURL_CA_BUNDLE = process.env.CURL_CA_BUNDLE || '${cacert}/etc/ssl/certs/ca-bundle.crt';
import('$out/lib/node_modules/@anthropic-ai/claude-code/cli.js');
EOF
    chmod +x $out/bin/claude-achtung-achtung

    # Create our sandboxed wrapper
    cp ${sandboxWrapper} $out/bin/claude-sandbox
    chmod +x $out/bin/claude-sandbox

    # Alias the sandboxed claude to the original claude
    ln -s $out/bin/claude-sandbox $out/bin/claude

    # Substitute the $out placeholder with actual output path
    substituteInPlace $out/bin/claude-sandbox \
      --replace '$out/bin/claude-achtung-achtung' "$out/bin/claude-achtung-achtung"
  '';

  meta = with lib; {
    description = "Sandboxed Claude Code environment using bubblewrap";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.mit;
    maintainers = [ ];
    platforms = platforms.linux;
    mainProgram = "claude-sandbox";
  };
}
