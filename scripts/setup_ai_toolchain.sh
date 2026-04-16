#!/usr/bin/env bash
set -euo pipefail

# 一体化安装/更新脚本（容器内执行）
# 覆盖：Claude Code, Codex, OpenCode 及相关插件
#
# 用法：
#   scripts/setup_ai_toolchain.sh install
#   scripts/setup_ai_toolchain.sh update
#
# 可选环境变量：
#   PROJECT_DIR=/workspace
#   CLAUDE_SETTINGS_SRC=/workspace/.claude/settings.json
#   CLAUDE_SETTINGS_LOCAL_SRC=/workspace/.claude/settings.local.json

MODE="${1:-}"
PROJECT_DIR="${PROJECT_DIR:-/workspace}"
CLAUDE_SETTINGS_SRC="${CLAUDE_SETTINGS_SRC:-$PROJECT_DIR/.claude/settings.json}"
CLAUDE_SETTINGS_LOCAL_SRC="${CLAUDE_SETTINGS_LOCAL_SRC:-$PROJECT_DIR/.claude/settings.local.json}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    log "ERROR: missing command: $1"
    exit 1
  }
}

usage() {
  cat <<'EOF'
Usage:
  setup_ai_toolchain.sh install
  setup_ai_toolchain.sh update

Env:
  PROJECT_DIR                default: /workspace
  CLAUDE_SETTINGS_SRC        default: $PROJECT_DIR/.claude/settings.json
  CLAUDE_SETTINGS_LOCAL_SRC  default: $PROJECT_DIR/.claude/settings.local.json
EOF
}

ensure_base_deps() {
  log "Ensure base dependencies"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg git clangd cmake

  if ! command -v node >/dev/null 2>&1; then
    mkdir -p /etc/apt/keyrings
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_25.x nodistro main" > /etc/apt/sources.list.d/nodesource.list
    apt-get update
    apt-get install -y nodejs
  fi

  need_cmd node
  need_cmd npm
  need_cmd python3
}

install_or_update_core_clis() {
  log "Install/update core CLIs"
  npm install -g \
    @anthropic-ai/claude-code@latest \
    @openai/codex@latest \
    oh-my-codex@latest \
    opencode-ai@latest \
    oh-my-opencode@latest \
    @tarquinen/opencode-dcp@latest \
    opencode-supermemory@latest \
    pyright@latest

  need_cmd claude
  need_cmd codex
  need_cmd omx
  need_cmd opencode
  need_cmd oh-my-opencode
}

sync_claude_settings_if_present() {
  mkdir -p /root/.claude

  if [[ -f "$CLAUDE_SETTINGS_SRC" ]]; then
    cp "$CLAUDE_SETTINGS_SRC" /root/.claude/settings.json
    log "Synced Claude settings: $CLAUDE_SETTINGS_SRC"
  fi

  if [[ -f "$CLAUDE_SETTINGS_LOCAL_SRC" ]]; then
    cp "$CLAUDE_SETTINGS_LOCAL_SRC" /root/.claude/settings.local.json
    log "Synced Claude local settings: $CLAUDE_SETTINGS_LOCAL_SRC"
  fi
}

setup_claude_marketplaces() {
  log "Setup/update Claude marketplaces"

  claude plugin marketplace add https://github.com/anthropics/claude-plugins-official || true
  claude plugin marketplace add https://github.com/thedotmack/claude-mem || true
  claude plugin marketplace add https://github.com/2lab-ai/oh-my-claude || true

  claude plugin marketplace update || true
}

install_or_update_claude_plugins() {
  log "Install/update Claude plugins"

  # 先确保目标插件都已安装（可重复执行）
  declare -a TARGET_PLUGINS=(
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

  for plugin in "${TARGET_PLUGINS[@]}"; do
    claude plugin install "$plugin" || true
  done

  # 再对当前已安装插件做 update
  mapfile -t INSTALLED_PLUGIN_IDS < <(claude plugin list | sed -n 's/^  ❯ \(.*\)$/\1/p')
  for plugin_id in "${INSTALLED_PLUGIN_IDS[@]}"; do
    updated=0
    for scope in user project local managed; do
      if claude plugin update --scope "$scope" "$plugin_id" >/tmp/claude_plugin_update.log 2>&1; then
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
  log "Setup OMX (oh-my-codex skills/prompts/agents)"
  omx setup --scope user --force --verbose || true
}

setup_opencode_stack() {
  log "Setup OpenCode stack"

  # 安装并写入全局配置（幂等）
  oh-my-opencode install --no-tui \
    --claude=yes \
    --openai=yes \
    --gemini=no \
    --copilot=no \
    --opencode-zen=no \
    --zai-coding-plan=no \
    --kimi-for-coding=no \
    --opencode-go=no \
    --skip-auth || true

  # 项目级插件（如果项目目录存在）
  if [[ -d "$PROJECT_DIR" ]]; then
    (
      cd "$PROJECT_DIR"
      opencode plugin oh-my-opencode -f || true
      opencode plugin @tarquinen/opencode-dcp -f || true
      opencode plugin opencode-supermemory -f || true
    )
  fi

  # 全局配置中的插件也做刷新
  if [[ -f /root/.config/opencode/opencode.json ]]; then
    mapfile -t GLOBAL_OC_PLUGINS < <(python3 - <<'PY'
import json
path = '/root/.config/opencode/opencode.json'
try:
    with open(path, 'r', encoding='utf-8') as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)
for item in data.get('plugin', []):
    if isinstance(item, str) and item.strip():
        print(item.strip())
PY
)

    for plugin in "${GLOBAL_OC_PLUGINS[@]}"; do
      opencode plugin "$plugin" -g -f || true
    done
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
  clangd --version | head -n 1 || true
  cmake --version | head -n 1 || true
}

run_install() {
  ensure_base_deps
  install_or_update_core_clis
  sync_claude_settings_if_present
  setup_claude_marketplaces
  install_or_update_claude_plugins
  setup_omx
  setup_opencode_stack
  print_versions

  log "Install complete"
}

run_update() {
  # update 默认也会确保依赖与 CLI 存在
  ensure_base_deps
  install_or_update_core_clis
  setup_claude_marketplaces
  install_or_update_claude_plugins
  setup_omx
  setup_opencode_stack
  print_versions

  log "Update complete"
}

main() {
  case "$MODE" in
    install)
      run_install
      ;;
    update)
      run_update
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
