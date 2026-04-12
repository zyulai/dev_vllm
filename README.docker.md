# Docker 开发环境使用说明（Claude Code + Codex + OpenCode）

这个文档说明如何使用本项目中的 `Dockerfile.ai-toolchain` 和脚本，快速拉起一个可开发的容器，并持续更新 CLI 与插件。

---

## 1. 文件说明

- `Dockerfile.ai-toolchain`
  - 基于 `vllm/vllm-openai:latest`
  - 构建阶段预装：Claude Code / Codex / oh-my-codex / OpenCode / oh-my-opencode
  - 默认 `ENTRYPOINT` 为 `bash`

- `scripts/setup_ai_toolchain.sh`
  - 一体化安装/更新入口
  - 支持两种模式：
    - `install`：完整安装（用于新镜像或首次初始化）
    - `update`：升级 CLI + 插件 + skills

- `scripts/update_ai_plugins_daily.sh`
  - 宿主机执行脚本
  - 自动进入目标容器执行每日更新流程

---

## 2. 前置要求

宿主机需要：

- Docker
- 可访问 npm / GitHub（更新插件市场和 npm 包）
- （可选）NVIDIA GPU + Docker GPU Runtime（若需要 `--gpus all`）

---

## 3. 构建镜像

在项目根目录执行：

```bash
docker build -f Dockerfile.ai-toolchain -t vllm-dev-ai-toolchain:latest .
```

> 首次构建会较慢，因为会安装多个 CLI 与插件。

---

## 4. 启动容器（映射当前项目目录）

### 4.1 GPU 版本（推荐）

```bash
docker run -d \
  --name vllm-dev-ai \
  --gpus all \
  -v "/home/norma/Desktop/vllm_tools:/workspace" \
  -w /workspace \
  --entrypoint bash \
  vllm-dev-ai-toolchain:latest \
  -lc "sleep infinity"
```

### 4.2 无 GPU 版本

```bash
docker run -d \
  --name vllm-dev-ai \
  -v "/home/norma/Desktop/vllm_tools:/workspace" \
  -w /workspace \
  --entrypoint bash \
  vllm-dev-ai-toolchain:latest \
  -lc "sleep infinity"
```

---

## 5. 进入容器并验证

```bash
docker exec -it vllm-dev-ai bash
```

在容器里检查版本：

```bash
claude --version
codex --version
omx version
opencode --version
oh-my-opencode --version
```

检查 Claude 插件：

```bash
claude plugin list
```

---

## 6. 首次认证建议

进入容器后，按需执行：

```bash
codex auth
opencode providers login
```

如果使用 oh-my-claude，启动 `claude` 后可执行：

```text
/oh-my-claude:setup
```

---

## 7. 手动更新（推荐定期执行）

### 7.1 在容器内执行

```bash
/usr/local/bin/setup_ai_toolchain.sh update
```

或（如果你用的是项目里的脚本）：

```bash
/workspace/scripts/setup_ai_toolchain.sh update
```

### 7.2 在宿主机执行（更新指定容器）

```bash
./scripts/update_ai_plugins_daily.sh vllm-dev-ai
```

如果不传容器名，脚本会自动选取运行中的 `vllm-dev-*` 容器。

---

## 8. 每天自动更新（cron 示例）

示例：每天凌晨 `03:17` 自动更新并写日志。

```bash
(crontab -l 2>/dev/null; echo '17 3 * * * /home/norma/Desktop/vllm_tools/scripts/update_ai_plugins_daily.sh vllm-dev-ai >> /home/norma/Desktop/vllm_tools/scripts/update_ai_plugins_daily.log 2>&1') | crontab -
```

查看当前 cron：

```bash
crontab -l
```

查看日志：

```bash
tail -f /home/norma/Desktop/vllm_tools/scripts/update_ai_plugins_daily.log
```

---

## 9. 可选：同步 Claude 本地配置

`setup_ai_toolchain.sh install` 会尝试从以下路径同步配置到容器 `/root/.claude/`：

- `CLAUDE_SETTINGS_SRC`（默认 `/workspace/.claude/settings.json`）
- `CLAUDE_SETTINGS_LOCAL_SRC`（默认 `/workspace/.claude/settings.local.json`）

如果你想自定义路径，可以在容器内设置环境变量后执行：

```bash
PROJECT_DIR=/workspace \
CLAUDE_SETTINGS_SRC=/workspace/.claude/settings.json \
CLAUDE_SETTINGS_LOCAL_SRC=/workspace/.claude/settings.local.json \
/usr/local/bin/setup_ai_toolchain.sh install
```

---

## 10. 常见问题

### Q1: 插件更新报 marketplace 或网络错误
- 先确认容器能访问 GitHub / npm。
- 重试：
  ```bash
  claude plugin marketplace update
  /usr/local/bin/setup_ai_toolchain.sh update
  ```

### Q2: 容器启动失败（GPU）
- 去掉 `--gpus all` 按无 GPU 模式启动。

### Q3: 容器内没有目标命令
- 执行：
  ```bash
  /usr/local/bin/setup_ai_toolchain.sh install
  ```

### Q4: 如何清理容器

```bash
docker stop vllm-dev-ai
docker rm -f vllm-dev-ai
```

---

## 11. 推荐工作流

1. 构建镜像
2. 启动容器并挂载项目目录
3. 在容器内完成认证（codex/opencode）
4. 日常开发
5. 用 `setup_ai_toolchain.sh update` 或 `update_ai_plugins_daily.sh` 做周期更新
