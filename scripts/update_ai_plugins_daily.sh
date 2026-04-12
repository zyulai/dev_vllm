#!/usr/bin/env bash
set -euo pipefail

# 每日自动更新容器内 AI 工具与插件
# 用法:
#   scripts/update_ai_plugins_daily.sh
#   scripts/update_ai_plugins_daily.sh <container_name>
#
# 可选环境变量:
#   VLLM_DEV_CONTAINER=<container_name>  # 指定容器名（优先级低于位置参数）
#   PROJECT_DIR=/workspace               # 容器内项目目录（用于本地 OpenCode 插件）
#   DRY_RUN=1                            # 仅打印目标容器，不执行更新

PROJECT_DIR="${PROJECT_DIR:-/workspace}"
TARGET_CONTAINER="${1:-${VLLM_DEV_CONTAINER:-}}"
DRY_RUN="${DRY_RUN:-0}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

resolve_container() {
  if [[ -n "$TARGET_CONTAINER" ]]; then
    printf '%s\n' "$TARGET_CONTAINER"
    return 0
  fi

  # docker ps 默认按创建时间倒序，取第一个匹配的运行中 vllm-dev-* 容器
  docker ps --format '{{.Names}}' | grep '^vllm-dev-' | head -n 1 || true
}

main() {
  command -v docker >/dev/null 2>&1 || fail "docker 未安装或不在 PATH"

  TARGET_CONTAINER="$(resolve_container)"
  [[ -n "$TARGET_CONTAINER" ]] || fail "未找到运行中的 vllm-dev-* 容器，请传入容器名"

  if ! docker ps --format '{{.Names}}' | grep -qx "$TARGET_CONTAINER"; then
    fail "容器 $TARGET_CONTAINER 未运行，请先 docker start $TARGET_CONTAINER"
  fi

  log "目标容器: $TARGET_CONTAINER"
  log "容器内项目目录: $PROJECT_DIR"

  if [[ "$DRY_RUN" == "1" ]]; then
    log "DRY_RUN=1，仅检查容器，不执行更新"
    exit 0
  fi

  docker exec -i "$TARGET_CONTAINER" bash -s -- "$PROJECT_DIR" <<'EOS'
set -euo pipefail
PROJECT_DIR="$1"

echo "[container] Start update at $(date '+%F %T')"

for cmd in npm claude opencode omx python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "[container] missing command: $cmd"
    exit 1
  }
done

echo "[container] 1/6 Update core CLI packages"
npm install -g \
  @anthropic-ai/claude-code@latest \
  @openai/codex@latest \
  oh-my-codex@latest \
  opencode-ai@latest \
  oh-my-opencode@latest \
  @tarquinen/opencode-dcp@latest \
  opencode-supermemory@latest \
  pyright@latest

echo "[container] 2/6 Update Claude marketplaces"
claude plugin marketplace update || true

echo "[container] 3/6 Update Claude plugins"
mapfile -t CLAUDE_PLUGIN_IDS < <(claude plugin list | sed -n 's/^  ❯ \(.*\)$/\1/p')
for plugin_id in "${CLAUDE_PLUGIN_IDS[@]}"; do
  updated=0
  for scope in user project local managed; do
    if claude plugin update --scope "$scope" "$plugin_id" >/tmp/claude_plugin_update.log 2>&1; then
      echo "[container] updated claude plugin: $plugin_id (scope=$scope)"
      updated=1
      break
    fi
  done

  if [[ "$updated" -eq 0 ]]; then
    reason="$(tail -n 1 /tmp/claude_plugin_update.log 2>/dev/null || true)"
    echo "[container] WARN: failed to update claude plugin: $plugin_id $reason"
  fi
done

read_plugin_list() {
  local json_path="$1"
  if [[ ! -f "$json_path" ]]; then
    return 0
  fi

  python3 - "$json_path" <<'PY'
import json
import sys

path = sys.argv[1]
try:
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
except Exception:
    raise SystemExit(0)

plugins = data.get("plugin", [])
if isinstance(plugins, list):
    for item in plugins:
        if isinstance(item, str) and item.strip():
            print(item.strip())
PY
}

echo "[container] 4/6 Update OpenCode local plugins"
if [[ -d "$PROJECT_DIR" ]]; then
  mapfile -t LOCAL_OC_PLUGINS < <(read_plugin_list "$PROJECT_DIR/.opencode/opencode.json")
  if [[ "${#LOCAL_OC_PLUGINS[@]}" -eq 0 ]]; then
    LOCAL_OC_PLUGINS=(oh-my-opencode @tarquinen/opencode-dcp opencode-supermemory)
  fi

  for plugin in "${LOCAL_OC_PLUGINS[@]}"; do
    (cd "$PROJECT_DIR" && opencode plugin "$plugin" -f >/tmp/opencode_local_plugin_update.log 2>&1 || true)
    echo "[container] local opencode plugin refreshed: $plugin"
  done
else
  echo "[container] WARN: project dir not found: $PROJECT_DIR (skip local OpenCode plugins)"
fi

echo "[container] 5/6 Update OpenCode global plugins"
mapfile -t GLOBAL_OC_PLUGINS < <(read_plugin_list "/root/.config/opencode/opencode.json")
for plugin in "${GLOBAL_OC_PLUGINS[@]}"; do
  opencode plugin "$plugin" -g -f >/tmp/opencode_global_plugin_update.log 2>&1 || true
  echo "[container] global opencode plugin refreshed: $plugin"
done

echo "[container] 6/6 Refresh OMX skills/prompts"
omx setup --scope user --force >/tmp/omx_setup.log 2>&1 || {
  echo "[container] WARN: omx setup failed, showing tail"
  tail -n 80 /tmp/omx_setup.log
}

echo "[container] Version summary"
claude --version || true
codex --version || true
omx version || true
opencode --version || true
oh-my-opencode --version || true

echo "[container] Done at $(date '+%F %T')"
EOS

  log "更新完成"
}

main "$@"
