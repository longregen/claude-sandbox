{ lib
, stdenv
, writeShellScript
, fetchurl
, cacert
, bubblewrap ? null
, autoPatchelfHook ? null
, tun2socks ? null
, slirp4netns ? null
, iproute2 ? null
, util-linux ? null
}:

let
  platformInfo = {
    "x86_64-linux"   = { platform = "linux-x64";    sha256 = "176fjx6y8qzlp6fckjsb16ps1k6rh71r8p39yd4iq2bw3f4gkhbh"; };
    "aarch64-linux"  = { platform = "linux-arm64";  sha256 = "1wk8173p2w3wn953pd8g62nrzk8ndw78d066xnc0lm9n16cq3q5g"; };
    "aarch64-darwin"  = { platform = "darwin-arm64"; sha256 = "08zwzihs91pzc6zpn09350qnkpw89vp982j5izl6kyhi66dw9s11"; };
    "x86_64-darwin"   = { platform = "darwin-x64";  sha256 = "1h4pxfv8wkhx5p2amzw01hfyd3a3vh292nfczxxh19wa4finyyj4"; };
  }.${stdenv.hostPlatform.system} or (throw "Unsupported system: ${stdenv.hostPlatform.system}");

  # Platform-specific sandbox wrapper
  sandboxWrapper =
    if stdenv.isDarwin
    then import ./sandbox-darwin.nix { inherit writeShellScript stdenv; }
    else import ./sandbox-linux.nix  { inherit writeShellScript stdenv bubblewrap tun2socks slirp4netns iproute2 util-linux; };

  # Script to add current directory to allowed folders
  allowDirScript = writeShellScript "claude-allow-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandbox.json"

    # Create config file with empty structure if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
      echo '{"includeFolders":[],"includeHomePatterns":[],"gui":false,"yolo":false}' > "$CONFIG_FILE"
    fi

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: jq is required but not found. Please install jq." >&2
      exit 1
    fi

    # Get absolute path of current directory
    DIR="$(pwd)"

    # Check if directory is already in the list
    if jq -e --arg dir "$DIR" '.includeFolders | index($dir) != null' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory already allowed: $DIR"
      exit 0
    fi

    # Add directory to includeFolders
    jq --arg dir "$DIR" '.includeFolders += [$dir]' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Added to allowed directories: $DIR"
  '';

  # Script to remove current directory from allowed folders
  forgetDirScript = writeShellScript "claude-forget-dir" ''
    CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandbox.json"

    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
      echo "No config file found at: $CONFIG_FILE"
      exit 0
    fi

    # Check if jq is available
    if ! command -v jq >/dev/null 2>&1; then
      echo "Error: jq is required but not found. Please install jq." >&2
      exit 1
    fi

    # Get absolute path of current directory
    DIR="$(pwd)"

    # Check if directory is in the list
    if ! jq -e --arg dir "$DIR" '.includeFolders | index($dir) != null' "$CONFIG_FILE" >/dev/null 2>&1; then
      echo "Directory not in allowed list: $DIR"
      exit 0
    fi

    # Remove directory from includeFolders
    jq --arg dir "$DIR" '.includeFolders = (.includeFolders | map(select(. != $dir)))' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    echo "Removed from allowed directories: $DIR"
  '';

  gcsBase = "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";

  # Wrapper that sets SSL certificates for Nix before exec-ing the native binary
  claudeWrapper = writeShellScript "claude-achtung-achtung" ''
    export SSL_CERT_FILE="''${SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}"
    export NIX_SSL_CERT_FILE="''${NIX_SSL_CERT_FILE:-${cacert}/etc/ssl/certs/ca-bundle.crt}"
    export CURL_CA_BUNDLE="''${CURL_CA_BUNDLE:-${cacert}/etc/ssl/certs/ca-bundle.crt}"
    exec @claude_native@ "$@"
  '';

in stdenv.mkDerivation rec {
  pname = "claude-sandbox";
  version = "2.1.52";

  # Native binary from Anthropic's GCS distribution bucket
  src = fetchurl {
    url = "${gcsBase}/${version}/${platformInfo.platform}/claude";
    sha256 = platformInfo.sha256;
  };

  dontUnpack = true;
  dontBuild = true;
  # The native binary is a Bun SEA — Nix's strip phase destroys the embedded application data.
  dontStrip = true;

  # autoPatchelfHook fixes the ELF interpreter for NixOS
  nativeBuildInputs = lib.optionals stdenv.isLinux [ autoPatchelfHook ];
  buildInputs = [ cacert ]
    ++ lib.optionals stdenv.isLinux [ stdenv.cc.cc.lib bubblewrap tun2socks slirp4netns iproute2 util-linux ];

  installPhase = ''
    mkdir -p $out/bin

    # Install the native Claude Code binary
    cp $src $out/bin/claude-native
    chmod +x $out/bin/claude-native

    # Install SSL-cert wrapper (writeShellScript gives us a proper Nix shebang)
    cp ${claudeWrapper} $out/bin/claude-achtung-achtung
    chmod +x $out/bin/claude-achtung-achtung
    substituteInPlace $out/bin/claude-achtung-achtung \
      --replace '@claude_native@' "$out/bin/claude-native"

    # Create our sandboxed wrapper
    cp ${sandboxWrapper} $out/bin/claude-sandbox
    chmod +x $out/bin/claude-sandbox

    # Alias the sandboxed claude to the original claude
    ln -s $out/bin/claude-sandbox $out/bin/claude

    # Install helper scripts for managing allowed directories
    cp ${allowDirScript} $out/bin/claude-allow-dir
    chmod +x $out/bin/claude-allow-dir
    cp ${forgetDirScript} $out/bin/claude-forget-dir
    chmod +x $out/bin/claude-forget-dir

    # Substitute the $out placeholder with actual output path
    substituteInPlace $out/bin/claude-sandbox \
      --replace '$out/bin/claude-achtung-achtung' "$out/bin/claude-achtung-achtung"
  '';

  meta = with lib; {
    description = "Sandboxed Claude Code environment";
    homepage = "https://github.com/anthropics/claude-code";
    license = licenses.mit;
    maintainers = [ ];
    platforms = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
    mainProgram = "claude-sandbox";
  };
}
