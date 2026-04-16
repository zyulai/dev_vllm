# vllm_tools

Open-source benchmark utilities for **vLLM** to measure latency/throughput-related metrics under different input/output settings.

> Docker 开发环境（Claude Code / Codex / OpenCode 一体化）请看 [`README.docker.md`](README.docker.md)
>
> 如果你想直接在 Ubuntu 宿主机上把 zsh、Claude Code、Codex、OpenCode、Hermes 和常用 CLI 一次性装好，请使用 `tools/bootstrap-ubuntu.sh`。

This repo currently focuses on generating a **single figure** with:

- **TTFT** (time-to-first-token)
- **TPOP/TPOT** (time-per-output-token during decode, seconds/token)

(You can still compute tok/s if/when tokenization is made exact; see notes below.)

## Install

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -U pip
pip install -e .
```

## Ubuntu host bootstrap (zsh + AI toolchain)

如果你是在一台新的 Ubuntu / Debian 机器上开发，并且希望直接把 shell 和 AI 工具链配好，可以运行：

```bash
cd /home/norma/Desktop/vllm_tools
./tools/bootstrap-ubuntu.sh install
```

这个脚本会安装并配置：

- zsh / oh-my-zsh / powerlevel10k
- 常见命令行工具：`ripgrep`、`jq`、`fzf`、`fd-find`、`neovim`、`tmux` 等
- Claude Code
- Codex
- oh-my-codex / OMX
- OpenCode / oh-my-opencode
- Hermes Agent
- Claude 插件市场与常用插件
- OpenCode 项目级 / 全局插件

安装完成后建议执行：

```bash
exec zsh
./tools/bootstrap-ubuntu.sh verify
```

首次使用时，认证通常还需要手动完成：

```bash
claude login
codex auth
opencode providers login
hermes setup
```

如果仓库里存在 `.claude/settings.json` 或 `.claude/settings.local.json`，脚本也会同步到当前用户的 `~/.claude/` 目录。

## Quickstart: smoke test (no GPU / no vLLM server)

```bash
cd /home/norma/Desktop/vllm_tools
PYTHONPATH=src python3 scripts/smoke_test.py
```

This will create:
- `results/<timestamp>/requests.jsonl`
- `results/<timestamp>/runs.jsonl`
- `plots/ttft_tpop.png`

## Quickstart: real benchmark against a running vLLM server

### 1) Start vLLM OpenAI-compatible server

Example:

```bash
python3 -m vllm.entrypoints.openai.api_server \
  --model <MODEL> \
  --host 0.0.0.0 --port 8000 \
  --dtype bfloat16 \
  --gpu-memory-utilization 0.9 \
  --max-model-len 16384 \
  --max-num-seqs 64
```

### 2) Run benchmark

Edit `configs/small.yaml` as needed, then:

```bash
PYTHONPATH=src python3 scripts/run_bench.py \
  --server http://127.0.0.1:8000 \
  --config configs/small.yaml \
  --out results/real_run
```

### 3) Plot

```bash
PYTHONPATH=src python3 scripts/plot.py \
  --in results/real_run/runs.jsonl \
  --out plots/ttft_tpop.png
```

## Metrics

Per-request we record timestamps (`t_start`, `t_first_token`, `t_end`) and derive:

- `ttft_s = t_first_token - t_start`
- `decode_s = t_end - t_first_token`
- `tpop_s = decode_s / output_tokens` (seconds/token)

Aggregated outputs (`runs.jsonl`) include p50/p90/p99 of TTFT and TPOP.

### Note on tokens
To compute tok/s accurately across *any* model, token counting must match the model tokenizer.
This MVP keeps smoke tests dependency-light; extending to exact HF tokenizer counting is straightforward.

## License

MIT
