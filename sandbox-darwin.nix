{ writeShellScript, stdenv }:

writeShellScript "claude-sandbox" ''
  # Parse command line flags
  ENABLE_SSH_GIT=0
  ENABLE_DOCKER=0
  EXTRA_ENVS=()
  CLAUDE_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ssh-git)
        ENABLE_SSH_GIT=1
        shift
        ;;
      --docker)
        ENABLE_DOCKER=1
        shift
        ;;
      --env)
        EXTRA_ENVS+=("$2")
        shift 2
        ;;
      --env=*)
        EXTRA_ENVS+=("''${1#*=}")
        shift
        ;;
      --socks-proxy|--socks-proxy=*)
        echo "Warning: --socks-proxy is not supported on macOS (no network namespace isolation)." >&2
        [[ "$1" == --socks-proxy ]] && shift 2 || shift
        ;;
      --fuse|--libvirt|--gui|--nvidia|--kvm|--audio)
        echo "Warning: $1 is not supported on macOS, ignoring." >&2
        shift
        ;;
      *)
        CLAUDE_ARGS+=("$1")
        shift
        ;;
    esac
  done

  USER=$(whoami)

  # Seed installMethod so `claude doctor` doesn't warn about unknown install
  mkdir -p "$HOME/.claude"
  CLAUDE_CFG="$HOME/.claude/.config.json"
  if [ -f "$CLAUDE_CFG" ]; then
    if command -v jq >/dev/null 2>&1; then
      if ! jq -e '.installMethod == "native"' "$CLAUDE_CFG" >/dev/null 2>&1; then
        jq '.installMethod = "native" | .autoUpdates = false' "$CLAUDE_CFG" > "$CLAUDE_CFG.tmp" && mv "$CLAUDE_CFG.tmp" "$CLAUDE_CFG"
      fi
    fi
  else
    echo '{"installMethod":"native","autoUpdates":false}' > "$CLAUDE_CFG"
  fi

  # ── Build the Seatbelt (sandbox-exec) profile ────────────────────────

  # Collect read-write paths for the sandbox profile
  RW_PATHS=()
  RO_PATHS=()

  # Current project directory (read-write)
  RW_PATHS+=( "$PWD" )

  # Claude config/state
  RW_PATHS+=( "$HOME/.claude" )
  [ -f "$HOME/.claude.json" ] && RW_PATHS+=( "$HOME/.claude.json" )
  [ -d "$HOME/.config/claude" ] && RW_PATHS+=( "$HOME/.config/claude" )
  [ -f "$HOME/.config/claude-sandbox.json" ] && RW_PATHS+=( "$HOME/.config/claude-sandbox.json" )

  # Cache directories
  CACHE_DIRS=(
    go pip deno pnpm yarn uv huggingface cached-nix-shell nix nix-hug gradle zig
    bun black gopls jedi lua-language-server pylint staticcheck typescript
    fish fontconfig prisma prisma-nodejs puppeteer tokenizer whisper
  )
  for cache_dir in "''${CACHE_DIRS[@]}"; do
    if [ -d "$HOME/.cache/$cache_dir" ]; then
      RW_PATHS+=( "$HOME/.cache/$cache_dir" )
    fi
  done

  # Home dot-dirs that Claude may need
  HOME_ALLOW=(
    .android .ansible .cargo .config/nix .cursor .docker .go .java
    .nix-defexpr .nix-channels .nix-profile .npm .yarn
  )
  for item in "''${HOME_ALLOW[@]}"; do
    if [ -e "$HOME/$item" ]; then
      RW_PATHS+=( "$HOME/$item" )
    fi
  done

  # SSH / git access
  if [ "$ENABLE_SSH_GIT" -eq 1 ]; then
    [ -d "$HOME/.ssh" ]             && RO_PATHS+=( "$HOME/.ssh" )
    [ -e "$HOME/.gitconfig" ]       && RO_PATHS+=( "$HOME/.gitconfig" )
    [ -e "$HOME/.git-credentials" ] && RW_PATHS+=( "$HOME/.git-credentials" )
    [ -d "$HOME/.gnupg" ]           && RW_PATHS+=( "$HOME/.gnupg" )
  fi

  # Docker socket
  if [ "$ENABLE_DOCKER" -eq 1 ]; then
    [ -S "/var/run/docker.sock" ] && RW_PATHS+=( "/var/run/docker.sock" )
    [ -S "$HOME/.docker/run/docker.sock" ] && RW_PATHS+=( "$HOME/.docker/run/docker.sock" )
  fi

  # ── Read config file ─────────────────────────────────────────────────
  CONFIG_FILE="''${XDG_CONFIG_HOME:-$HOME/.config}/claude-sandbox.json"
  if [ -f "$CONFIG_FILE" ] && ! command -v jq >/dev/null 2>&1; then
    echo "Warning: jq not found. Please install jq for proper config parsing." >&2
  fi
  if [ -f "$CONFIG_FILE" ] && command -v jq >/dev/null 2>&1; then
    while IFS= read -r folder; do
      expanded_folder=$(echo "$folder" | sed "s|^~|$HOME|")
      [ -d "$expanded_folder" ] && RW_PATHS+=( "$expanded_folder" )
    done < <(jq -r '.includeFolders[]? // empty' "$CONFIG_FILE" 2>/dev/null)

    while IFS= read -r pattern; do
      [ -e "$HOME/$pattern" ] && RW_PATHS+=( "$HOME/$pattern" )
    done < <(jq -r '.includeHomePatterns[]? // empty' "$CONFIG_FILE" 2>/dev/null)

    if jq -e '.docker == true' "$CONFIG_FILE" >/dev/null 2>&1; then
      ENABLE_DOCKER=1
      [ -S "/var/run/docker.sock" ] && RW_PATHS+=( "/var/run/docker.sock" )
      [ -S "$HOME/.docker/run/docker.sock" ] && RW_PATHS+=( "$HOME/.docker/run/docker.sock" )
    fi

    # Warn about unsupported config options
    for key in socksProxy gui nvidia kvm audio; do
      if jq -e ".$key != null and .$key != false" "$CONFIG_FILE" >/dev/null 2>&1; then
        echo "Warning: config option '$key' is not supported on macOS, ignoring." >&2
      fi
    done

    while IFS= read -r env_pair; do
      EXTRA_ENVS+=("$env_pair")
    done < <(jq -r '.extraEnvs[]? // empty' "$CONFIG_FILE" 2>/dev/null)

    if jq -e '.yolo == true' "$CONFIG_FILE" >/dev/null 2>&1; then
      CLAUDE_ARGS+=("--allow-dangerously-skip-permissions" "--dangerously-skip-permissions")
    fi
  fi

  # ── Assemble the Seatbelt profile ───────────────────────────────────

  PROFILE='(version 1)
(deny default)

;; Allow basic process operations
(allow process-exec
  (subpath "/nix")
  (subpath "/usr/bin")
  (subpath "/bin"))
(allow process-fork)
(allow signal (target self))
(allow sysctl-read)
;; mach-lookup must be broad: Node.js/Bun pull in many system services
;; (Security framework, CoreFoundation preferences, DNS resolution, etc.)
;; Restricting this would require enumerating dozens of Mach service names
;; and would break across macOS versions.
(allow mach-lookup)
(allow ipc-posix-shm-read-data)
(allow ipc-posix-shm-write-data)
(allow ipc-posix-shm-write-create)
(allow file-ioctl)

;; Allow network (outbound)
(allow network-outbound)
(allow network-bind)
(allow system-socket)

;; Allow reading system essentials
(allow file-read*
  (subpath "/nix")
  (subpath "/usr/lib")
  (subpath "/usr/bin")
  (subpath "/bin")
  (subpath "/System")
  (subpath "/Library")
  (subpath "/etc")
  (subpath "/private/etc")
  (subpath "/dev")
  (subpath "/var/select")
  (subpath "/private/var/select")
  (literal "/AppleInternal")
  (literal "/private/tmp")
  (literal "/tmp")
)

;; Allow temp directories (read-write)
(allow file-read* file-write*
  (subpath "/private/tmp")
  (subpath "/tmp")
  (subpath "/private/var/folders")
  (subpath "/var/folders")
)
'

  # Sanitize and add paths to the profile
  # Reject paths containing characters that could break or inject into the Seatbelt DSL
  _sb_path() {
    local p="$1"
    if [[ "$p" == *'"'* ]] || [[ "$p" == *')'* ]] || [[ "$p" == *'('* ]]; then
      echo "Warning: skipping path with unsafe characters for sandbox profile: $p" >&2
      return 1
    fi
    return 0
  }

  # Add read-write paths
  for p in "''${RW_PATHS[@]}"; do
    _sb_path "$p" && PROFILE+="
(allow file-read* file-write* (subpath \"$p\"))"
  done

  # Add read-only paths
  for p in "''${RO_PATHS[@]}"; do
    _sb_path "$p" && PROFILE+="
(allow file-read* (subpath \"$p\"))"
  done

  # SSH agent socket (special — it's a single file, not a subpath)
  if [ "$ENABLE_SSH_GIT" -eq 1 ] && [ -n "$SSH_AUTH_SOCK" ] && [ -e "$SSH_AUTH_SOCK" ]; then
    SOCK_DIR=$(dirname "$SSH_AUTH_SOCK")
    PROFILE+="
(allow file-read* file-write* (subpath \"$SOCK_DIR\"))"
  fi

  # ── Build environment ───────────────────────────────────────────────

  ENV_ARGS=()
  ENV_ARGS+=( "PATH=/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin:$PATH" )
  ENV_ARGS+=( "HOME=$HOME" )
  ENV_ARGS+=( "USER=$USER" )
  ENV_ARGS+=( "LOGNAME=$USER" )
  [ -n "$TERM" ] && ENV_ARGS+=( "TERM=$TERM" )
  [ -n "$SHELL" ] && ENV_ARGS+=( "SHELL=$SHELL" )
  ENV_ARGS+=( "SSL_CERT_FILE=''${SSL_CERT_FILE:-}" )
  ENV_ARGS+=( "NIX_SSL_CERT_FILE=''${NIX_SSL_CERT_FILE:-}" )
  ENV_ARGS+=( "CURL_CA_BUNDLE=''${CURL_CA_BUNDLE:-}" )
  ENV_ARGS+=( "NODE_ENV=production" )
  ENV_ARGS+=( "CLAUDE_CODE_DISABLE_FEEDBACK_SURVEY=1" )
  ENV_ARGS+=( "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1" )
  ENV_ARGS+=( "CLAUDE_CODE_IDE_SKIP_AUTO_INSTALL=1" )
  ENV_ARGS+=( "DISABLE_AUTOUPDATER=1" )
  ENV_ARGS+=( "DISABLE_ERROR_REPORTING=1" )
  ENV_ARGS+=( "DISABLE_BUG_COMMAND=1" )
  ENV_ARGS+=( "DISABLE_TELEMETRY=1" )

  if [ "$ENABLE_SSH_GIT" -eq 1 ]; then
    [ -n "$SSH_AUTH_SOCK" ] && ENV_ARGS+=( "SSH_AUTH_SOCK=$SSH_AUTH_SOCK" )
    [ -n "$GPG_AGENT_INFO" ] && ENV_ARGS+=( "GPG_AGENT_INFO=$GPG_AGENT_INFO" )
    [ -n "$GPG_TTY" ] && ENV_ARGS+=( "GPG_TTY=$GPG_TTY" )
  fi

  if [ "$ENABLE_DOCKER" -eq 1 ] && [ -n "$DOCKER_HOST" ]; then
    ENV_ARGS+=( "DOCKER_HOST=$DOCKER_HOST" )
  fi

  for env_pair in "''${EXTRA_ENVS[@]}"; do
    [ -n "$env_pair" ] && ENV_ARGS+=( "$env_pair" )
  done

  # ── Execute under sandbox ───────────────────────────────────────────

  if [ -n "$DRY_RUN" ]; then
    echo "sandbox-exec profile:"
    echo "$PROFILE"
    echo ""
    echo "Command: env ''${ENV_ARGS[*]} $out/bin/claude-achtung-achtung ''${CLAUDE_ARGS[*]}"
    exit 0
  fi

  if [ -n "$START_SHELL" ]; then
    exec /usr/bin/sandbox-exec -p "$PROFILE" env "''${ENV_ARGS[@]}" "$SHELL"
  else
    exec /usr/bin/sandbox-exec -p "$PROFILE" env "''${ENV_ARGS[@]}" "$out/bin/claude-achtung-achtung" "''${CLAUDE_ARGS[@]}"
  fi
''
