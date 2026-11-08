# Maya + Strata on gfx906: DeepSeek-V4-Flash-0731 at 13.3 tok/s on one MI50

**This niche is not empty — check the neighbours first.**

- [mixa3607/ML-gfx906](https://github.com/mixa3607/ML-gfx906) (376 stars) publishes gfx906 builds of
  llama.cpp, ComfyUI, PyTorch, Strata and [Project Maya](https://github.com/mw00/project-maya) as
  `mixa3607/maya-gfx906` / `mixa3607/strata-gfx906`. That Maya is a different project with its own
  engines (`maya`, `maya-ds4`), `pack_gguf.py` packs, multi-GPU tensor parallel and vision — its
  `RUNNING.md` documents DeepSeek-V4.1-Flash-1017 on 4× MI50 with a 192 GB RAM budget. If you are aiming
  at 1017 with several cards, start there, not here.
- `mxxm/llama-cpp-gfx906` — plain llama.cpp for these cards, 205k pulls. It runs this model too, at
  3.75 tok/s (measured below).

What this image adds is narrower and specific: the Strata engine's **deepseek4 pack path fixed for the
0731 pack**, sized for one card, with a second config and a measured setup for two.

Two configs ship in `/opt/maya/defaults/`: `strata-dsv4.json` (one card, IQ2_XXS, 8k — the setup measured
below) and `strata-dsv4-2x.json` (2× 32 GB, IQ3_S, 128k — the setup measured in
[issue #3](https://github.com/xxDoman/strata-gfx906/issues/3)).

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
edits survive container restarts and image updates. Which default is seeded is up to you:
`-e DEFAULT_CONFIG=strata-dsv4-2x.json` starts from the two-card one.

## Where the model has to sit

The config names absolute container paths, so this layout is not a suggestion — no Dockerfile can find a
pack mounted somewhere else. `the model's tokenizer is missing` at start is always this one thing:

```
/models/abyss/0731/        the pack directory — it carries tokenizer/ inside it
/models/abyss/*.gguf       the model shards, named as the config's --ple-gguf expects
```

`tokenizer` in the JSON is `/models/abyss/0731/tokenizer`, a path *inside* the pack, and `--glm-pack` is
the pack directory itself. Two ways to get there:

```sh
# 1. the whole models tree under /models (what the one-line docker run above does)
-v /path/to/models:/models          # /path/to/models/abyss/0731/ and /path/to/models/abyss/*.gguf

# 2. the pack somewhere else: mount each piece onto the name the config asks for
-v /data/gguf/UD-IQ3_S/pack-dsv4:/models/abyss/0731
-v /data/gguf/UD-IQ3_S/…-00001-of-00004.gguf:/models/abyss/…-00001-of-00004.gguf
…
```

A symlink to a host path does not work — inside the container that path does not exist. Mount the target
onto the expected name instead.

**`--ple-gguf` must name a shard that exists.** Layer 1's PLE lives in it, and the engine says so in
capitals: `WITHOUT IT LAYER 1's PLE IS SILENTLY SKIPPED, which changes every number downstream`. A stale
filename from another quant starts fine and is quietly not the same model — change the shard name when
you change quant, and nothing else in that line.

## Two cards

Nothing extra on the `docker run` line: both cards arrive through `/dev/dri` anyway. The **config** decides
whether the second one is used:

```json
"gpu": "0,1",
"layer_split": "auto"
```

`serve/server.py` turns that into `--gpu 0,1` and appends `--layer-split auto` to the engine's own
arguments. `ROCR_VISIBLE_DEVICES=0,1` alone is *not* enough: it makes both cards visible and asks for no
split, which is how a two-card host ends up running on one card while looking correct. The engine
announces what it decided:

```
glm split auto: layers [0, 21) on CUDA0, [21, 43) on CUDA1 - a token 19.8 ms predicted
(CUDA0 9.2 ms, 139 slots a layer | CUDA1 10.2 ms, 129 slots a layer), 89% of the routed experts in VRAM
```

A ready config for 2× MI50 32 GB ships in the image as `/opt/maya/defaults/strata-dsv4-2x.json`:

```sh
docker run -d --name maya \
  --device /dev/kfd --device /dev/dri --group-add video --group-add render \
  --ulimit memlock=-1 -p 8092:8092 \
  -e DEFAULT_CONFIG=strata-dsv4-2x.json \
  -v /path/to/models:/models -v maya-data:/data \
  xxdoman/maya-gfx906:0.1
```

`DEFAULT_CONFIG` matters only on the first start — an existing `/data/maya/strata-dsv4.json` is never
overwritten. Extra arguments after the image name reach the server too (`… xxdoman/maya-gfx906:0.1
--gpu 0,1`), which is what the entrypoint's passthrough is for.

### Measured on 2× MI50 32 GB + 128 GB DDR3 (X99), IQ3_S, 128k context

Reproduced by [@glennhanks](https://github.com/glennhanks) in
[issue #3](https://github.com/xxDoman/strata-gfx906/issues/3) — a different box from the host tabulated
below, so the two sets of numbers are not directly comparable.

| | |
| --- | --- |
| model | `unsloth/DeepSeek-V4-Flash-0731-UD-IQ3_S`, 116.07 GB, 4 shards |
| pack | built with **Abyss's own tooling**, not `tools/iq_pack.py` — the engine loads both |
| context | 131072, with `--kv-resident 20480` and `STRATA_GLM_RAM_GB=100` |
| decode | 19.53 tok/s (51.19 ms/token): `vram hit 89.23%`, `ram fetches 1.52/tok`, `disk 0.00 reads/tok` |
| prefill | ~150–200 tok/s (1275 tokens in 4.1 s, 3987 in 21.9 s) |
| split | `[0, 21)` on CUDA0, `[21, 43)` on CUDA1, 139 / 129 slots per layer |
| drafting | `--spec 1` (n-gram), reported ~80% acceptance |

Two things worth knowing before tuning on a high-RAM host:

- **`--kv-resident 20480` is what makes 128k fit.** It keeps the KV of 20480 cells of each QSA layer in
  pinned RAM and spends the freed VRAM on expert slots; without it the same config OOMs. The engine
  accepts nothing below 20480, and the help says `not with --kv k8v4` — do not combine them.
- **The RAM tier is what stops the SSD thrashing.** At the default 32 GB with a 116 GB model, experts come
  off the disk every token; at 100 GB the log reads `disk 0.00 reads/tok`. `--glm-ram-resident` is the
  stricter variant of the same idea — it refuses to start unless the tier holds every expert the VRAM
  does not (see `strata --help`).

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

**Changing the config** (context, RAM tier, sampling, model paths, GPU count): the JSON is the only source
of truth, and it lives in the `maya-data` volume.

```sh
docker exec -it maya sh -c 'vi /data/maya/strata-dsv4.json'   # or edit the file in the volume
docker restart maya
```

Engine settings reach the process from two places — the container's environment and the config's own
`"env"` block — and **the config wins**: `serve/server.py` builds the engine's environment from its own,
then applies `"env"` over it. That is why, in the `:0.1` image on the Hub, `-e STRATA_GLM_RAM_GB=96` does
nothing at all while the key sits in the JSON (and in the shipped default it does). Two honest routes:

```sh
# a. the entrypoint in this repo writes -e into the config and says so:
docker run ... -e STRATA_GLM_RAM_GB=96 ...        # -> [maya] env.STRATA_GLM_RAM_GB -> 96 in /data/...

# b. on a published image, edit the JSON — this is the only reliable way there:
docker run --rm -v maya-data:/data --entrypoint python3 xxdoman/maya-gfx906:0.1 -c \
  'import json,sys; p="/data/maya/strata-dsv4.json"; c=json.load(open(p)); \
   c["env"]["STRATA_GLM_RAM_GB"]="96"; json.dump(c,open(p,"w"),indent=2)'
docker restart maya
```

`--max-context`, `--kv-resident`, `--prefill`, the model paths and `--ple-gguf` are engine arguments and
live in the `args` array, not in `env`.

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

- **No MTP for this model — measured, not inferred.** `--mtp DIR` is accepted and then silently ignored on
  this pack: with `--spec 4 --mtp …` pointing at the real pack directory the engine starts, reports
  `mtp=0 … drafter=none` in its INFO line and drafts from n-grams only. The reason is structural: the MTP
  runtime (`src/core/mtp.cpp`) is written for the QSA architecture — 0 references to MLA, a hardcoded
  `mtp: the 512 experts do not fit in VRAM`, and the load path sits inside the branch that owns
  `n_qsa_layers()`. The 0731 draft layer is MLA (`wq_a`, `wq_b`, `wkv`, `wo_a`, `wo_b`, `attn_sink`) with
  256 experts and a `tid2eid` map, so it is a different layer, not a different file.
- **The draft weights exist and are MXFP4.** The original checkpoint carries 4705 `mtp.0.*` tensors in
  shards 46–48, 10.86 GB in total — 2329 `F8_E8M0` scales, 2304 `I8` packed nibbles, 25 `F8_E4M3`,
  20 BF16, 27 F32. That is the same block MXFP4 the model uses for its experts everywhere else, and it is
  exactly what `dspark-DeepSeek-V4-Flash-0731-MXFP4.gguf` (10.90 GB) in bartowski's repo contains. So MTP
  here needs two things at once, in this order: MXFP4 kernels, then a draft runner for this architecture.
- **What is available today: n-gram/suffix drafting, and it pays.** `--spec N` needs no draft model. On one
  MI50 with this pack, a deliberately repetitive 17-token prompt gave `3 of 4 drafts accepted (75%)` and
  16.49 tok/s (60.65 ms/token) against the 13.3 tok/s tabulated above; a repetitive prompt flatters
  acceptance, so treat that as an upper bound and not as the number for real chat.
- **`--dspark` does not exist in this build.** The binary's options are `--spec`, `--spec-min-p`,
  `--spec-split`, `--spec-oracle`, `--mtp`, `--mtp-max-t`, `--mtp-window`; `--dspark` is llama.cpp's own
  drafter and this engine never read it.
- **Images and MCP** are off in the config (`images: false`, `mcp` disabled).
- **Prefill is disk-bound on a single card** with a 3-shard IQ2_XXS pack: 190–210 tok/s is a 6899-token
  prompt in 38 s, and it does not improve with more slots — the experts for a prompt are streamed, not
  cached. With two cards and a RAM tier large enough for the model, the same prefill comes from RAM
  (`disk 0.00 reads/tok`) and the number is no longer about the disk.

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
docker build -f Dockerfile -t xxdoman/maya-gfx906:0.1 .
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
