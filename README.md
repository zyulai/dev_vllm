# vllm_tools

Open-source benchmark utilities for **vLLM** to measure latency/throughput-related metrics under different input/output settings.

> Docker 开发环境（Claude Code / Codex / OpenCode 一体化）请看 [`README.docker.md`](README.docker.md)

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
