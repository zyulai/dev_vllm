#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MANAGED_MARKER="# Managed by tools/bootstrap-ubuntu.sh"
CURRENT_USER="$(id -un)"
TARGET_USER="${SUDO_USER:-$CURRENT_USER}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
TARGET_GROUP="$(id -gn "$TARGET_USER")"
PROJECT_DIR="${PROJECT_DIR:-$REPO_ROOT}"
CLAUDE_SETTINGS_SRC="${CLAUDE_SETTINGS_SRC:-$PROJECT_DIR/.claude/settings.json}"
CLAUDE_SETTINGS_LOCAL_SRC="${CLAUDE_SETTINGS_LOCAL_SRC:-$PROJECT_DIR/.claude/settings.local.json}"
CLAUDE_HOME="$TARGET_HOME/.claude"
OPENCODE_GLOBAL_CONFIG="$TARGET_HOME/.config/opencode/opencode.json"
HERMES_HOME="${HERMES_HOME:-$TARGET_HOME/.hermes}"
HERMES_INSTALL_DIR="${HERMES_INSTALL_DIR:-$HERMES_HOME/hermes-agent}"
ZSH_DIR="$TARGET_HOME/.oh-my-zsh"
ZSH_CUSTOM_DIR="$ZSH_DIR/custom"
P10K_DIR="$ZSH_CUSTOM_DIR/themes/powerlevel10k"

APT_PACKAGES=(
  zsh
  git
  curl
  ca-certificates
  gnupg
  jq
  ripgrep
  fd-find
  fzf
  neovim
  git-flow
  build-essential
  unzip
  zip
  tmux
  tree
  python3
  python3-venv
  clangd
  cmake
)

NPM_GLOBAL_PACKAGES=(
  @anthropic-ai/claude-code@latest
  @openai/codex@latest
  oh-my-codex@latest
  opencode-ai@latest
  oh-my-opencode@latest
  @tarquinen/opencode-dcp@latest
  opencode-supermemory@latest
  pyright@latest
)

CLAUDE_MARKETPLACES=(
  https://github.com/anthropics/claude-plugins-official
  https://github.com/thedotmack/claude-mem
  https://github.com/2lab-ai/oh-my-claude
)

CLAUDE_TARGET_PLUGINS=(
  clangd-lsp@claude-plugins-official
  code-review@claude-plugins-official
  context7@claude-plugins-official
  data-engineering@claude-plugins-official
  feature-dev@claude-plugins-official
  learning-output-style@claude-plugins-official
  lua-lsp@claude-plugins-official
  pyright-lsp@claude-plugins-official
  ralph-loop@claude-plugins-official
  skill-creator@claude-plugins-official
  typescript-lsp@claude-plugins-official
  gopls-lsp@claude-plugins-official
  rust-analyzer-lsp@claude-plugins-official
  csharp-lsp@claude-plugins-official
  goodmem@claude-plugins-official
  claude-mem@thedotmack
  oh-my-claude@oh-my-claude
  powertoy@oh-my-claude
  stv@oh-my-claude
  claude-and-me@oh-my-claude
)

usage() {
  cat <<EOF
Usage:
  $SCRIPT_NAME install
  $SCRIPT_NAME verify
  $SCRIPT_NAME -h|--help

Commands:
  install   Install zsh, oh-my-zsh, common CLI tools, Claude/Codex/OpenCode/Hermes, and related plugins
  verify    Verify the installed shell + AI toolchain without making changes
EOF
}

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

run_as_root() {
  if [[ "$(id -u)" -eq 0 ]]; then
    "$@"
    return
  fi

  need_cmd sudo
  sudo "$@"
}

run_as_target_user() {
  if [[ "$CURRENT_USER" == "$TARGET_USER" ]]; then
    "$@"
    return
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    if command -v runuser >/dev/null 2>&1; then
      runuser -u "$TARGET_USER" -- "$@"
      return
    fi

    if command -v su >/dev/null 2>&1; then
      local arg
      local -a quoted=()
      for arg in "$@"; do
        quoted+=("$(printf '%q' "$arg")")
      done
      su -s /bin/bash "$TARGET_USER" -c "${quoted[*]}"
      return
    fi

    die "missing command to switch user: need runuser or su"
  fi

  need_cmd sudo
  sudo -u "$TARGET_USER" -H "$@"
}

write_target_file() {
  local path="$1"

  if [[ "$CURRENT_USER" == "$TARGET_USER" ]]; then
    cat > "$path"
    return
  fi

  if [[ "$(id -u)" -eq 0 ]]; then
    mkdir -p "$(dirname "$path")"
    cat > "$path"
    chown "$TARGET_USER:$TARGET_GROUP" "$path"
    return
  fi

  need_cmd sudo
  sudo -u "$TARGET_USER" -H tee "$path" >/dev/null
}

copy_file_to_target() {
  local source="$1"
  local target="$2"
  local mode="${3:-600}"

  if [[ "$CURRENT_USER" == "$TARGET_USER" ]]; then
    cp "$source" "$target"
    chmod "$mode" "$target"
    return
  fi

  run_as_root install -m "$mode" -o "$TARGET_USER" -g "$TARGET_GROUP" "$source" "$target"
}

ensure_supported_os() {
  [[ -f /etc/os-release ]] || die "/etc/os-release not found"
  # shellcheck disable=SC1091
  . /etc/os-release

  case "${ID:-}" in
    ubuntu|debian)
      return
      ;;
  esac

  if [[ " ${ID_LIKE:-} " == *" debian "* ]]; then
    return
  fi

  die "this script only supports Ubuntu/Debian systems"
}

backup_if_unmanaged() {
  local path="$1"
  local backup_path

  if ! run_as_target_user test -f "$path"; then
    return
  fi

  if run_as_target_user grep -Fq "$MANAGED_MARKER" "$path"; then
    return
  fi

  backup_path="$path.pre-bootstrap.$(date '+%Y%m%d%H%M%S').bak"
  run_as_target_user cp "$path" "$backup_path"
  log "Backed up $(basename "$path") to $backup_path"
}

backup_target_file_if_different() {
  local source="$1"
  local target="$2"
  local backup_path

  if [[ ! -f "$source" ]]; then
    return
  fi

  if [[ -f "$target" ]] && cmp -s "$source" "$target"; then
    return
  fi

  if [[ -f "$target" ]]; then
    backup_path="$target.pre-bootstrap.$(date '+%Y%m%d%H%M%S').bak"
    run_as_target_user cp "$target" "$backup_path"
    log "Backed up $(basename "$target") to $backup_path"
  fi
}

sync_target_file_if_present() {
  local source="$1"
  local target="$2"
  local mode="${3:-600}"

  if [[ ! -f "$source" ]]; then
    return
  fi

  backup_target_file_if_different "$source" "$target"
  run_as_target_user mkdir -p "$(dirname "$target")"
  copy_file_to_target "$source" "$target" "$mode"
  log "Synced $(basename "$source") to $target"
}

clone_or_update_repo() {
  local name="$1"
  local dest="$2"
  shift 2

  if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
    die "$dest exists and is not a git repository"
  fi

  if [[ -d "$dest/.git" ]]; then
    log "Repo already exists: $name"
    if ! run_as_target_user git -C "$dest" pull --ff-only --quiet; then
      log "WARN: could not fast-forward $name; keeping existing checkout"
    fi
    return
  fi

  local url
  local tmp_dest
  tmp_dest="$dest.tmp.$$"

  for url in "$@"; do
    run_as_target_user rm -rf "$tmp_dest"
    log "Cloning $name from $url"
    if run_as_target_user git clone --depth 1 "$url" "$tmp_dest"; then
      run_as_target_user mv "$tmp_dest" "$dest"
      return
    fi
    log "WARN: failed to clone $name from $url"
  done

  run_as_target_user rm -rf "$tmp_dest"
  die "failed to clone $name from all configured sources"
}

clone_or_update_optional_repo() {
  local name="$1"
  local dest="$2"
  shift 2

  if [[ -e "$dest" && ! -d "$dest/.git" ]]; then
    log "WARN: $dest exists and is not a git repository; skipping $name"
    return 1
  fi

  if [[ -d "$dest/.git" ]]; then
    log "Optional repo already exists: $name"
    if ! run_as_target_user git -C "$dest" pull --ff-only --quiet; then
      log "WARN: could not fast-forward optional repo $name; keeping existing checkout"
    fi
    return 0
  fi

  local url
  local tmp_dest
  tmp_dest="$dest.tmp.$$"

  for url in "$@"; do
    run_as_target_user rm -rf "$tmp_dest"
    log "Cloning optional repo $name from $url"
    if run_as_target_user git clone --depth 1 "$url" "$tmp_dest"; then
      run_as_target_user mv "$tmp_dest" "$dest"
      return 0
    fi
    log "WARN: failed to clone optional repo $name from $url"
  done

  run_as_target_user rm -rf "$tmp_dest"
  log "WARN: skipping optional repo $name because all sources failed"
  return 1
}

read_json_string_array() {
  local json_path="$1"
  local key="$2"

  python3 - "$json_path" "$key" <<'PY'
import json
import sys

path = sys.argv[1]
key = sys.argv[2]

try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)

items = data.get(key, [])
if isinstance(items, list):
    for item in items:
        if isinstance(item, str) and item.strip():
            print(item.strip())
PY
}

install_packages() {
  log "Installing Ubuntu packages"
  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "${APT_PACKAGES[@]}"

  need_cmd git
  need_cmd curl
  need_cmd python3
  need_cmd gpg
}

ensure_nodejs() {
  if run_as_root bash -lc 'command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1'; then
    log "Node.js and npm already installed for global npm usage"
    return
  fi

  log "Installing Node.js 25.x"
  run_as_root mkdir -p /etc/apt/keyrings

  if [[ ! -f /etc/apt/keyrings/nodesource.gpg ]]; then
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | run_as_root gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
  fi

  if [[ ! -f /etc/apt/sources.list.d/nodesource.list ]] \
    || ! grep -Fq 'node_25.x' /etc/apt/sources.list.d/nodesource.list 2>/dev/null; then
    printf 'deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_25.x nodistro main\n' \
      | run_as_root tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  fi

  run_as_root apt-get update
  run_as_root env DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs

  run_as_root bash -lc 'command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1' \
    || die "node/npm are still unavailable for root after installation"
}

install_npm_global_clis() {
  log "Installing global AI CLI packages"
  run_as_root npm install -g "${NPM_GLOBAL_PACKAGES[@]}"

  need_cmd claude
  need_cmd codex
  need_cmd omx
  need_cmd opencode
  need_cmd oh-my-opencode
  need_cmd pyright
}

install_oh_my_zsh_stack() {
  log "Installing oh-my-zsh and shell plugins"

  clone_or_update_repo \
    "oh-my-zsh" \
    "$ZSH_DIR" \
    "https://gitee.com/mirrors/oh-my-zsh.git" \
    "https://github.com/ohmyzsh/ohmyzsh.git"

  run_as_target_user mkdir -p "$ZSH_CUSTOM_DIR/plugins" "$ZSH_CUSTOM_DIR/themes"

  clone_or_update_repo \
    "zsh-syntax-highlighting" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-syntax-highlighting" \
    "https://gitee.com/mirror-hub/zsh-syntax-highlighting.git" \
    "https://github.com/zsh-users/zsh-syntax-highlighting.git"

  clone_or_update_repo \
    "zsh-autosuggestions" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions" \
    "https://gitee.com/mirrors/zsh-autosuggestions.git" \
    "https://github.com/zsh-users/zsh-autosuggestions.git"

  clone_or_update_optional_repo \
    "zsh-completions" \
    "$ZSH_CUSTOM_DIR/plugins/zsh-completions" \
    "https://github.com/zsh-users/zsh-completions.git"

  clone_or_update_optional_repo \
    "git-flow-completion" \
    "$ZSH_CUSTOM_DIR/plugins/git-flow-completion" \
    "https://github.com/petervanderdoes/git-flow-completion.git"

  clone_or_update_optional_repo \
    "autoupdate-oh-my-zsh-plugins" \
    "$ZSH_CUSTOM_DIR/plugins/autoupdate" \
    "https://github.com/TamCore/autoupdate-oh-my-zsh-plugins.git"

  clone_or_update_repo \
    "powerlevel10k" \
    "$P10K_DIR" \
    "https://gitee.com/romkatv/powerlevel10k.git" \
    "https://github.com/romkatv/powerlevel10k.git"
}

sync_claude_settings_if_present() {
  log "Syncing Claude settings if present"
  run_as_target_user mkdir -p "$CLAUDE_HOME"
  sync_target_file_if_present "$CLAUDE_SETTINGS_SRC" "$CLAUDE_HOME/settings.json" 600
  sync_target_file_if_present "$CLAUDE_SETTINGS_LOCAL_SRC" "$CLAUDE_HOME/settings.local.json" 600
}

setup_claude_marketplaces() {
  local marketplace

  log "Configuring Claude plugin marketplaces"
  for marketplace in "${CLAUDE_MARKETPLACES[@]}"; do
    run_as_target_user claude plugin marketplace add "$marketplace" || true
  done

  run_as_target_user claude plugin marketplace update || true
}

install_or_update_claude_plugins() {
  local plugin
  local plugin_id
  local scope
  local updated
  local reason
  local -a installed_plugin_ids=()

  log "Installing/updating Claude plugins"

  for plugin in "${CLAUDE_TARGET_PLUGINS[@]}"; do
    run_as_target_user claude plugin install "$plugin" || true
  done

  if mapfile -t installed_plugin_ids < <(run_as_target_user bash -lc "claude plugin list | sed -n 's/^  ❯ \(.*\)$/\\1/p'"); then
    :
  fi

  for plugin_id in "${installed_plugin_ids[@]}"; do
    updated=0
    for scope in user project local managed; do
      if run_as_target_user claude plugin update --scope "$scope" "$plugin_id" >/tmp/claude_plugin_update.log 2>&1; then
        log "Updated Claude plugin: $plugin_id (scope=$scope)"
        updated=1
        break
      fi
    done

    if [[ "$updated" -eq 0 ]]; then
      reason="$(tail -n 1 /tmp/claude_plugin_update.log 2>/dev/null || true)"
      log "WARN: failed to update Claude plugin: $plugin_id $reason"
    fi
  done
}

setup_omx() {
  log "Configuring OMX (oh-my-codex)"
  run_as_target_user omx setup --scope user --force --verbose || true
}

setup_opencode_stack() {
  local plugin
  local -a global_plugins=()

  log "Configuring OpenCode stack"

  run_as_target_user oh-my-opencode install --no-tui \
    --claude=yes \
    --openai=yes \
    --gemini=no \
    --copilot=no \
    --opencode-zen=no \
    --zai-coding-plan=no \
    --kimi-for-coding=no \
    --opencode-go=no \
    --skip-auth || true

  if [[ -d "$PROJECT_DIR" ]]; then
    run_as_target_user env PROJECT_DIR="$PROJECT_DIR" bash -lc 'cd "$PROJECT_DIR" && opencode plugin oh-my-opencode -f' || true
    run_as_target_user env PROJECT_DIR="$PROJECT_DIR" bash -lc 'cd "$PROJECT_DIR" && opencode plugin @tarquinen/opencode-dcp -f' || true
    run_as_target_user env PROJECT_DIR="$PROJECT_DIR" bash -lc 'cd "$PROJECT_DIR" && opencode plugin opencode-supermemory -f' || true
  else
    log "WARN: project dir not found, skipping project-level OpenCode plugins: $PROJECT_DIR"
  fi

  if [[ -f "$OPENCODE_GLOBAL_CONFIG" ]]; then
    if mapfile -t global_plugins < <(read_json_string_array "$OPENCODE_GLOBAL_CONFIG" plugin); then
      :
    fi

    for plugin in "${global_plugins[@]}"; do
      run_as_target_user opencode plugin "$plugin" -g -f || true
    done
  fi
}

install_hermes() {
  log "Installing Hermes Agent"
  run_as_target_user env HERMES_HOME="$HERMES_HOME" HERMES_INSTALL_DIR="$HERMES_INSTALL_DIR" bash -lc '
    set -euo pipefail
    curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh \
      | bash -s -- --skip-setup --hermes-home "$HERMES_HOME" --dir "$HERMES_INSTALL_DIR"
    command -v hermes >/dev/null 2>&1
  '
}

write_zshenv() {
  backup_if_unmanaged "$TARGET_HOME/.zshenv"
  write_target_file "$TARGET_HOME/.zshenv" <<'EOF'
# Managed by tools/bootstrap-ubuntu.sh
# Keep user-local tools ahead of system binaries for every zsh invocation.
if [ -d "$HOME/.local/bin" ]; then
  path=("$HOME/.local/bin" $path)
fi
typeset -U path PATH
export PATH
EOF
}

write_zshrc() {
  backup_if_unmanaged "$TARGET_HOME/.zshrc"
  write_target_file "$TARGET_HOME/.zshrc" <<'EOF'
# Managed by tools/bootstrap-ubuntu.sh
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"

plugins=(
  git
  zsh-syntax-highlighting
  zsh-autosuggestions
)

for optional_plugin in zsh-completions git-flow-completion autoupdate; do
  if [ -d "$ZSH/custom/plugins/$optional_plugin" ]; then
    plugins+=("$optional_plugin")
  fi
done

source "$ZSH/oh-my-zsh.sh"

[[ -f "$HOME/.p10k.zsh" ]] && source "$HOME/.p10k.zsh"

alias vim="nvim"

if command -v fdfind >/dev/null 2>&1 && ! command -v fd >/dev/null 2>&1; then
  alias fd='fdfind'
fi

if [ -d "$HOME/.local/bin" ]; then
  case ":$PATH:" in
    *:"$HOME/.local/bin":*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
  esac
fi

[[ -f "$HOME/.zshrc.local" ]] && source "$HOME/.zshrc.local"
EOF
}

write_p10k_config() {
  backup_if_unmanaged "$TARGET_HOME/.p10k.zsh"
  write_target_file "$TARGET_HOME/.p10k.zsh" <<'EOF'
# Managed by tools/bootstrap-ubuntu.sh
'builtin' 'local' '-a' 'p10k_config_opts'
[[ ! -o 'aliases'         ]] || p10k_config_opts+=('aliases')
[[ ! -o 'sh_glob'         ]] || p10k_config_opts+=('sh_glob')
[[ ! -o 'no_brace_expand' ]] || p10k_config_opts+=('no_brace_expand')
'builtin' 'setopt' 'no_aliases' 'no_sh_glob' 'brace_expand'

() {
  emulate -L zsh -o extended_glob
  [[ $ZSH_VERSION == (5.<1->*|<6->.*) ]] || return

  typeset -g POWERLEVEL9K_MODE=ascii
  typeset -g POWERLEVEL9K_LEFT_PROMPT_ELEMENTS=(dir vcs newline prompt_char)
  typeset -g POWERLEVEL9K_RIGHT_PROMPT_ELEMENTS=(status command_execution_time background_jobs)
  typeset -g POWERLEVEL9K_PROMPT_ADD_NEWLINE=true
  typeset -g POWERLEVEL9K_MULTILINE_FIRST_PROMPT_PREFIX=''
  typeset -g POWERLEVEL9K_MULTILINE_LAST_PROMPT_PREFIX=''
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_CONTENT_EXPANSION='>'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_CONTENT_EXPANSION='>'
  typeset -g POWERLEVEL9K_PROMPT_CHAR_OK_VIINS_FOREGROUND=76
  typeset -g POWERLEVEL9K_PROMPT_CHAR_ERROR_VIINS_FOREGROUND=160
  typeset -g POWERLEVEL9K_STATUS_OK=false
  typeset -g POWERLEVEL9K_COMMAND_EXECUTION_TIME_THRESHOLD=3
  typeset -g POWERLEVEL9K_SHORTEN_STRATEGY=truncate_to_last
  typeset -g POWERLEVEL9K_SHORTEN_DIR_LENGTH=3
  typeset -g POWERLEVEL9K_BACKGROUND_JOBS_VERBOSE=false
}

(( ! ${#p10k_config_opts} )) || 'builtin' 'setopt' "${p10k_config_opts[@]}"
'builtin' 'unset' 'p10k_config_opts'
EOF
}

write_shell_config() {
  log "Writing shell configuration for $TARGET_USER"
  write_zshenv
  write_zshrc
  write_p10k_config
}

switch_default_shell() {
  local zsh_path
  local current_shell

  zsh_path="$(command -v zsh)"
  current_shell="$(getent passwd "$TARGET_USER" | cut -d: -f7)"

  if [[ "$current_shell" == "$zsh_path" ]]; then
    log "Default shell already set to zsh for $TARGET_USER"
    return
  fi

  log "Changing default shell for $TARGET_USER to $zsh_path"
  if [[ "$(id -un)" == "$TARGET_USER" ]]; then
    if ! chsh -s "$zsh_path" "$TARGET_USER"; then
      log "WARN: failed to change shell automatically; run: chsh -s $zsh_path $TARGET_USER"
    fi
    return
  fi

  if ! run_as_root chsh -s "$zsh_path" "$TARGET_USER"; then
    log "WARN: failed to change shell automatically; run: sudo chsh -s $zsh_path $TARGET_USER"
  fi
}

print_versions() {
  log "Version summary"
  claude --version || true
  codex --version || true
  omx version || true
  opencode --version || true
  oh-my-opencode --version || true
  pyright --version || true
  hermes --version || true
  node --version || true
  npm --version || true
}

verify_installation() {
  local failures=0
  local cmd

  check_cmd() {
    local candidate="$1"
    if run_as_target_user bash -lc "command -v $(printf '%q' "$candidate") >/dev/null 2>&1"; then
      log "OK: found command $candidate"
    else
      log "FAIL: missing command $candidate"
      failures=$((failures + 1))
    fi
  }

  check_target_path() {
    local label="$1"
    local candidate="$2"
    if run_as_target_user test -e "$candidate"; then
      log "OK: found $label at $candidate"
    else
      log "FAIL: missing $label at $candidate"
      failures=$((failures + 1))
    fi
  }

  check_target_grep() {
    local label="$1"
    local pattern="$2"
    local candidate="$3"
    if run_as_target_user grep -Fq "$pattern" "$candidate"; then
      log "OK: $label"
    else
      log "FAIL: $label"
      failures=$((failures + 1))
    fi
  }

  for cmd in zsh git curl python3 node npm rg jq fzf nvim claude codex omx opencode oh-my-opencode pyright; do
    check_cmd "$cmd"
  done

  check_target_path "oh-my-zsh" "$ZSH_DIR"
  check_target_path "zsh-syntax-highlighting" "$ZSH_CUSTOM_DIR/plugins/zsh-syntax-highlighting"
  check_target_path "zsh-autosuggestions" "$ZSH_CUSTOM_DIR/plugins/zsh-autosuggestions"
  check_target_path "powerlevel10k" "$P10K_DIR"
  check_target_path ".zshrc" "$TARGET_HOME/.zshrc"
  check_target_path ".zshenv" "$TARGET_HOME/.zshenv"
  check_target_path ".p10k.zsh" "$TARGET_HOME/.p10k.zsh"
  check_target_path "Claude home" "$CLAUDE_HOME"
  check_target_path "Hermes home" "$HERMES_HOME"
  check_target_path "Hermes install dir" "$HERMES_INSTALL_DIR"
  check_target_path "Hermes CLI symlink" "$TARGET_HOME/.local/bin/hermes"

  if [[ -f "$CLAUDE_SETTINGS_LOCAL_SRC" ]]; then
    check_target_path "synced Claude local settings" "$CLAUDE_HOME/settings.local.json"
  fi

  if [[ -f "$CLAUDE_SETTINGS_SRC" ]]; then
    check_target_path "synced Claude settings" "$CLAUDE_HOME/settings.json"
  fi

  if run_as_target_user test -e "$ZSH_CUSTOM_DIR/plugins/zsh-completions"; then
    log "OK: found optional plugin zsh-completions"
  else
    log "WARN: optional plugin zsh-completions is not installed"
  fi

  if run_as_target_user test -e "$ZSH_CUSTOM_DIR/plugins/git-flow-completion"; then
    log "OK: found optional plugin git-flow-completion"
  else
    log "WARN: optional plugin git-flow-completion is not installed"
  fi

  if run_as_target_user test -e "$ZSH_CUSTOM_DIR/plugins/autoupdate"; then
    log "OK: found optional plugin autoupdate"
  else
    log "WARN: optional plugin autoupdate is not installed"
  fi

  if [[ -f "$OPENCODE_GLOBAL_CONFIG" ]]; then
    log "OK: found OpenCode global config at $OPENCODE_GLOBAL_CONFIG"
  else
    log "WARN: OpenCode global config not found at $OPENCODE_GLOBAL_CONFIG"
  fi

  if run_as_target_user test -f "$TARGET_HOME/.zshrc"; then
    check_target_grep "zshrc enables oh-my-zsh" 'export ZSH="$HOME/.oh-my-zsh"' "$TARGET_HOME/.zshrc"
    check_target_grep "zshrc enables zsh-autosuggestions" 'zsh-autosuggestions' "$TARGET_HOME/.zshrc"
    check_target_grep "zshrc sets vim alias" 'alias vim="nvim"' "$TARGET_HOME/.zshrc"
    check_target_grep "zshrc loads powerlevel10k theme" 'ZSH_THEME="powerlevel10k/powerlevel10k"' "$TARGET_HOME/.zshrc"
  fi

  if run_as_target_user test -f "$TARGET_HOME/.zshenv"; then
    check_target_grep "zshenv adds ~/.local/bin" '$HOME/.local/bin' "$TARGET_HOME/.zshenv"
  fi

  if run_as_target_user bash -lc 'claude plugin list | grep -Fq "context7@claude-plugins-official"'; then
    log "OK: Claude context7 plugin is installed"
  else
    log "FAIL: Claude context7 plugin is missing"
    failures=$((failures + 1))
  fi

  if run_as_target_user bash -lc 'claude plugin list | grep -Fq "feature-dev@claude-plugins-official"'; then
    log "OK: Claude feature-dev plugin is installed"
  else
    log "FAIL: Claude feature-dev plugin is missing"
    failures=$((failures + 1))
  fi

  if run_as_target_user bash -lc 'claude plugin list | grep -Fq "claude-mem@thedotmack"'; then
    log "OK: Claude claude-mem plugin is installed"
  else
    log "FAIL: Claude claude-mem plugin is missing"
    failures=$((failures + 1))
  fi

  if run_as_target_user bash -lc 'omx version >/dev/null 2>&1'; then
    log "OK: OMX is available"
  else
    log "FAIL: OMX is unavailable"
    failures=$((failures + 1))
  fi

  if run_as_target_user bash -lc 'opencode plugin list >/dev/null 2>&1'; then
    log "OK: OpenCode plugin subsystem is available"
  else
    log "FAIL: OpenCode plugin subsystem is unavailable"
    failures=$((failures + 1))
  fi

  if run_as_target_user zsh -ic 'command -v rg >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v nvim >/dev/null 2>&1 && command -v claude >/dev/null 2>&1 && command -v codex >/dev/null 2>&1 && command -v opencode >/dev/null 2>&1 && command -v hermes >/dev/null 2>&1'; then
    log "OK: zsh interactive smoke test passed"
  else
    log "FAIL: zsh interactive smoke test failed"
    failures=$((failures + 1))
  fi

  if (( failures > 0 )); then
    die "verification failed with $failures issue(s)"
  fi

  log "Verification passed"
}

run_install() {
  ensure_supported_os
  need_cmd getent
  install_packages
  ensure_nodejs
  install_npm_global_clis
  install_oh_my_zsh_stack
  write_shell_config
  sync_claude_settings_if_present
  setup_claude_marketplaces
  install_or_update_claude_plugins
  setup_omx
  setup_opencode_stack
  install_hermes
  switch_default_shell
  print_versions
  log "Install complete. Next steps: claude login / codex auth / opencode providers login / hermes setup"
  log "Then run: exec zsh"
}

main() {
  case "${1:-}" in
    install)
      run_install
      ;;
    verify)
      ensure_supported_os
      verify_installation
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
}

main "$@"
