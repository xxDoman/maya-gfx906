# Maya + Strata on gfx906: DeepSeek-V4-Flash-0731 at 13.3 tok/s on one MI50

As far as we know this is the only public `gfx906` (MI50 / MI60 / Radeon VII) build that runs
DeepSeek-V4-Flash-0731 at all — llama.cpp gets it to 3.75 tok/s, nothing else publishes a working
image. If you know of another, open an issue and it will be listed here.

**Image:** `xxdoman/maya-gfx906:0.1` (alias `:latest`, digest
`sha256:245c0d79b4bfa3ee7568398b5944aff545651c8a148ead2c8df01864d112113d`, 7.79 GB) — the upstream Maya
dashboard (`serve/server.py`, unmodified) on top of the Strata engine built for `gfx906`, with the
pack-path fixes below. Same layout as `xxdoman/strata-mi50`: `/opt/strata/engine/strata`, Maya in
`/opt/maya`, volumes `/models` `/data` `/work`.

```
docker pull xxdoman/maya-gfx906:0.1
```

**Host measured on:** LianLi — 1× MI50 32 GB (`gfx906`), 61 GB DDR4, i5-12400F, NVMe, ROCm 7.2.1,
`power1_cap` 225 W (default, nothing limited), 8192-token context.

**Model:** `unsloth/DeepSeek-V4-Flash-0731-UD-IQ2_XXS` — 3 shards, 84.6 GB, 2.0625 bpw,
`general.architecture = deepseek4`, 43 blocks, 256 experts, 6 active, `n_embd` 4096, `n_ff` 2048,
native context 1 048 576.

---

## Numbers

Pack built with `tools/iq_pack.py --compat-bf16`: 184 MB, 1199 tensors, 494 served natively from
`dense.bin`, the 83.87 GB of experts stay in the GGUF shards.

| prompt | prefill | decode | VRAM hit | RAM tier | wall clock |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 14 tok | 11 tok/s | 11.4 tok/s | 66.0 % | 31.98 GB pinned, 4508 slots | 3.4 s |
| 1544 tok | 168 tok/s | 13.1 tok/s | 72.0 % | ” | 11.0 s |
| 6899 tok | `193–210` tok/s | 13.3 tok/s | 77.5 % | ” | 37.6–40.6 s |

Same box, same model, llama.cpp b12128 (`xxdoman/llama-mi50-rocm7.2:v5`) for comparison:

| engine | VRAM | RAM | decode | prefill |
| --- | ---: | ---: | ---: | ---: |
| llama.cpp `-ngl 99 -cmoe` | 10 GB (dense only) | 56 GB page cache | **3.75 tok/s** | 2.8 tok/s (cold, 10-token prompt) |
| llama.cpp `-ngl 99 -ncmoe 31` | 32.9 GB | 56 GB page cache | 3.75 tok/s | 1544-token prompt did not finish in 4 min |
| **Strata + 32 GB RAM tier** | 30 GB (6.17 dense + 23.85 pool) | 31.98 GB pinned | **13.3 tok/s** | 190–210 tok/s |

`-cmoe` keeps experts in RAM through mmap, but nothing pins them — and `--mlock` cannot help, the file is
84.6 GB against 61 GB RAM. `-ncmoe 31` does fill the card, and decode does not move: the bottleneck is
having no tiered expert cache (upstream `moe-cache` is CUDA-only), not the amount of VRAM.

Arithmetic for the ceiling on this host: 43 layers × 6 experts × 7 536 640 B = 1.94 GB of expert weights
touched per token. With 3354 slots on the card plus 4508 in pinned RAM, 71 % of the 11 008 experts are
resident, so a token still pulls ~430 MB through the NVMe — at 13 tok/s that is ~6 disk reads per token,
which is what `glm stat` reports (`6.3 reads/token, 3.3 RAM fetches/token`).

## Running it

```sh
docker run -d --name maya \
  --device /dev/kfd --device /dev/dri \
  --group-add video --group-add render \
  --ulimit memlock=-1 \
  -p 8092:8092 \
  -v /path/to/models:/models \
  -v maya-data:/data \
  xxdoman/maya-gfx906:0.1
```

Then `http://<host>:8092/` for the dashboard, `/v1/chat/completions` and `/v1/messages` for clients,
`/metrics`, `/slots`, `/status` as upstream.

**`--ulimit memlock=-1` is not optional.** A process with the default `ulimit -l` of 8 MB cannot pin an
expert tier: the engine reports `RAM tier 0.39 GB pinned, 48 slots` at best, and any tier above ~2 GB
deadlocks in `mlock` (uninterruptible sleep, RSS climbing to 10 GB, no progress). Inside a container the
limit is free; on the host it needs `sudo prlimit --memlock=unlimited:unlimited -- <server>`.

**Config lives on a volume, not in the image.** On the first start the entrypoint copies
`/opt/maya/defaults/strata-dsv4.json` to `/data/maya/strata-dsv4.json` and never overwrites it again, so
edits survive container restarts and image updates. Models are mounted at `/models`; the pack's shard
symlinks are relative for exactly that reason.

## The config is upstream's, not ours

Nothing here re-documents the settings — the server, the config format and every key are upstream's:

- **`docs/MANUAL.md`** — "Configure and start", "Using it", options:
  https://github.com/zephel01/Abyss/blob/c56e6d1/docs/MANUAL.md
- **`docs/SETTINGS.md`** — every key in the JSON, what it does, defaults:
  https://github.com/zephel01/Abyss/blob/c56e6d1/docs/SETTINGS.md

Our `maya/config/strata-dsv4.json` is that same file with three paths swapped: `exe` →
`/opt/strata/engine/strata`, the pack under `/models`, and `log` under `/data`. Everything else —
`--max-context`, `--prefill`, `sampling`, `env`, `model_name` — behaves as described there, and the
engine's own flags are the ones `strata --help` prints.

## Using it

The container starts the same server the host command starts — `serve/server.py --engine strata` — so
everything in the upstream `docs/MANUAL.md` applies, only the paths differ.

**Is it up?**

```sh
docker ps --filter name=maya
curl -s localhost:8092/health          # {"status": "ok", ...}
docker logs -f maya                   # the engine's own log
```

A start takes about a minute: the dense weights go to the GPU, then every expert is read into the VRAM
and RAM tiers (~20 s at 4 GB/s from an NVMe). The last line the entrypoint prints before that is
`[maya] dashboard na :8092`; the engine announces `RAM tier 31.98 GB pinned, 4508 slots` when the tier
is up.

**Browser:** `http://<host>:8092/` — chat, the live expert-tier/GPU monitor, settings.

**OpenAI-compatible API:** base URL `http://<host>:8092/v1`, any model name.

```sh
curl http://localhost:8092/v1/chat/completions -H 'Content-Type: application/json' -d '{
  "messages": [{"role": "user", "content": "What is 17*23?"}]}'
```

**Anthropic-compatible:** `POST /v1/messages` on the same port. Also `/v1/models`, `/v1/status`,
`/metrics`, `/slots`, `/status`.

**Changing the config** (context, RAM tier, sampling, log path):

```sh
docker exec -it maya sh -c 'vi /data/maya/strata-dsv4.json'   # or edit the file in the maya-data volume
docker restart maya
```

`STRATA_GLM_RAM_GB` can also be set on `docker run -e`, and the entrypoint passes it to the engine;
`--max-context` and the model paths live in the JSON.

**Exposing it beyond localhost.** The entrypoint binds `0.0.0.0` so the dashboard is reachable from the
LAN, and by default the API has **no key**. Either publish it on the loopback interface only —
`-p 127.0.0.1:8092:8092` — or set one:

```sh
docker run ... -e STRATA_API_KEY=secret -p 8092:8092 ...
```

The server reads `STRATA_API_KEY` itself (`--api-key`), so clients then send
`Authorization: Bearer secret`.

**Stopping:** `docker stop maya` (the server is PID 1 and shuts down cleanly). `docker rm maya` keeps
the config, because it lives in the `maya-data` volume.

## What does not work

- **No MTP / speculative decoding.** The original weights have one MTP layer
  (`num_nextn_predict_layers = 1`, tensors `mtp.0.hc_head_base`, `mtp.0.hc_attn_fn`, … in the safetensors
  index) — the unsloth GGUF does not: 1328 tensors, zero `mtp`/`nextn`, and no separate MTP file in the
  repo. So there is no draft head to serve, and `--spec-type draft-mtp` has nothing to point at. An
  external draft model would have to match this tokenizer.
- **Images and MCP** are off in the config (`images: false`, `mcp` disabled).
- **Prefill is disk-bound** on a 3-shard IQ2_XXS pack: 190–210 tok/s is a 6899-token prompt in 38 s, and
  it does not improve with more slots — the experts for a prompt are streamed, not cached.

## What the patch contains

`patches/gfx906-deepseek4.patch` (11 files, 146 insertions) against upstream `v1.3.116`:

| file | change |
| --- | --- |
| `src/kernels/cuda/glm_batch.cu` | `expert_count_kernel` assumed wave32 (lane `tid & 31`, ballot `0xffffffff`, 8 warps); on wave64/gfx906 it counted 128 experts instead of 96 and prefill above 31 tokens died with `glm router: prompt layer 0 invalid expert ID`. Rewritten on a shared-memory counter. |
| `src/kernels/cpu/expert_layout.cpp`, `include/…/expert_layout.hpp` | expert geometry (`n_embd`, `n_ff`, `n_expert`) and the layer count are taken from the pack header instead of the compile-time family defaults (`H=2560, FF=640, NE=512`, 48 layers). |
| `src/core/native_dense.cpp` | `NativeDense::eligible()` learns the MLA/dsv4 suffixes (`.attn_kv`, `.attn_q_a`, `.attn_q_b`, `.attn_output_a/.b`, `.ffn_gate_tid2eid`, `.output_hc_*`). |
| `src/core/native_head.cpp` | `token_embd` shape comes from the tensor, not from a fixed `n_embd × vocab`. |
| `cmake/hip_backend.cmake` | `gfx906` added to `_strata_hip_unvalidated` (configure dies before compiling otherwise) and `STRATA_HIP_WMMA=0` derived for it. |
| `CMakeLists.txt`, `src/core/glm_prefill.cu`, `src/kernels/cpu/native_expert.cpp`, `src/program/generate.cpp`, `tools/iq_pack.py` | gfx906 build gate, prefill diagnostics, native expert path, generate loop, packer geometry. |

Kernel parity on gfx906 (no WMMA port needed): `glm_hc_parity`, `glm_dsa_parity`, `glm_kda_parity` —
`--selftest` PASS ×3.

## Building the image

```sh
git clone https://github.com/xxDoman/strata-gfx906
cd strata-gfx906
docker build -f Dockerfile.maya -t xxdoman/maya-gfx906:0.1 .
```

The engine is compiled inside the image from upstream source plus the patch. A binary built on the host
does not travel: Ubuntu 26.04 links against glibc 2.43, and the ROCm 24.04 base image has 2.39 —
`/app/strata: version 'GLIBC_2.43' not found` at exec.

**This Dockerfile is not self-contained, on purpose.** It builds `FROM xxdoman/strata-mi50:0.2.9`, and
that base is the part which cannot be recreated from a stock ROCm image: official ROCm ships rocBLAS
kernels only from `gfx1010`, so on `gfx906` there is no GEMM code at all until the host's gfx906
rocBLAS libraries and the tuned solution table are packed in. Pull the base from the Hub, or build it
from https://github.com/xxDoman/strata-gfx906 first — without it this Dockerfile has nothing to stand
on. Everyone else should simply `docker pull xxdoman/maya-gfx906:0.1`; the Dockerfile is here so the
image can be audited and rebuilt by us, not as a generic recipe.
