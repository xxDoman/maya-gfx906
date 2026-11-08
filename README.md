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

Both cards arrive through `/dev/dri`, but **neither the config nor the environment alone is enough** — this
was measured the hard way on a two-card host (X99, 2× MI50 32 GB, 128 GB DDR3):

| `-e ROCR_VISIBLE_DEVICES=0,1 -e HIP_VISIBLE_DEVICES=0,1` | `"gpu": "0,1"` + `"layer_split": "auto"` | result |
| --- | --- | --- |
| yes | yes | 19.5 tok/s, 89% of routed experts in VRAM, 0.00 disk reads/token |
| **no** | yes | **16.0 tok/s, 60% hit rate**, RAM >90 GB — loaded CUDA0 only |

Without the environment variables the engine prints `layer split across GPUs [0, 1] (auto)` and then loads
one card anyway, which is the worst possible failure: it looks right. So set both.

```json
"gpu": "0,1",
"layer_split": "auto"
```

`serve/server.py` turns that into `--gpu 0,1` and appends `--layer-split auto` to the engine's own
arguments. The engine announces what it decided:

```
glm split auto: layers [0, 21) on CUDA0, [21, 43) on CUDA1 - a token 19.8 ms predicted
(CUDA0 9.2 ms, 139 slots a layer | CUDA1 10.2 ms, 129 slots a layer), 89% of the routed experts in VRAM
```

A ready config for 2× MI50 32 GB ships in the image as `/opt/maya/defaults/strata-dsv4-2x.json`:

```sh
docker run -d --name maya \
  --device /dev/kfd --device /dev/dri --group-add video --group-add render \
  --ulimit memlock=-1 -p 8092:8092 \
  -e ROCR_VISIBLE_DEVICES=0,1 -e HIP_VISIBLE_DEVICES=0,1 \
  -e DEFAULT_CONFIG=strata-dsv4-2x.json \
  -v /path/to/models:/models -v maya-data:/data \
  xxdoman/maya-gfx906:0.2-mxfp4
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
tail -f /data/maya/logs/abyss-server.log   # inside the container: the engine's own log, NOT docker logs
```

**`docker logs maya` is the wrong stream for engine lines.** `serve/server.py` starts the engine with
`stderr` pointed at the log file (`/data/maya/logs/abyss-server.log`) and `stdout` on a pipe it reads, so
everything the engine says — `glm pack:`, `glm split`, `glm stat:`, `dspark:`, errors — lands in that file
and never in the container's stdout. To read it from outside:

```sh
docker exec maya grep -i dspark /data/maya/logs/abyss-server.log    # or
docker run --rm -v maya-data:/data --entrypoint cat xxdoman/maya-gfx906:0.2-mxfp4.1 /data/maya/logs/abyss-server.log
```

Engine knobs travel the same way as the engine's log: `docker run -e STRATA_ANYTHING=value` is copied into
the config's `env` block on start (every `STRATA_*` name, not a fixed list) and the entrypoint prints the
resulting set, so you can see what the engine actually got:

```
[maya] env silnika w configu: STRATA_DS4_DSPARK=/models/gguf/DSpark-...gguf STRATA_DS4_DSPARK_EXPERTS=64
STRATA_GLM_RAM_GB=32 STRATA_GLM_TIMING=1
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

`patches/002-mxfp4-decode.patch` (3 files, 180 insertions) adds the engine's missing MXFP4 decode path — see
below.

## MXFP4 (ggml type 39)

The model's original checkpoint is quantised MXFP4, and bartowski ships only that format, so the engine
had to learn one more block type to read those files at all. Type 39 used to fall through
`iq_row_bytes()`'s `default: return 0`, which means an MXFP4 expert blob could not even be addressed.

What went in:

| file | change |
| --- | --- |
| `src/kernels/cuda/iq_kernels.cu` | `vec_dot_mxfp4_q8_1` (port of ggml-cuda's, 20 lines: the codebook is stored doubled, hence the `0.5f`, and the scale is one e8m0 byte read with `2^(e-127)` instead of an fp16 `d`); `get_int_b1`; `dq_mxfp4`; `Fmt<39>` (qk 32, ipb 2, step 2 — same block geometry as IQ4_NL); `iq_row_bytes(39)`; `is_iq(39)`; the `iq_mmvq` launch |
| `src/kernels/cuda/native_mmvq.cu` | `native_mmvq_supported(39)`, 32 values / 17 bytes in `native_mmvq_weight_bytes`, and dispatch to `iq_mmvq` |
| `src/kernels/iq_mxfp4_parity.cpp` | the test: random blocks generated in the program, decoded on the host, compared against the kernels |

**Verified on one MI50**, `iq_mxfp4_parity` (parity, not a model run):

```
iq_supported(39)                                           ok
iq_row_bytes(39, 2048) == 64 * 17                          ok
iq_dequant_f32(39) relative error: 0.000e+00
dequant matches the block layout decoded on the host       ok
iq_mmvq(39) dot: got -25230.642578 want -25160.014481  relative error 2.807e-03
mmvq dot matches the float dot to activation rounding      ok
iq_mxfp4_parity: PASS
```

To rebuild the test (no fixture files, no model):

```sh
hipcc -x hip --offload-arch=gfx906 -O2 -std=c++17 \
  -I include -I include/strata/hip_compat -I third_party/ggml \
  src/kernels/iq_mxfp4_parity.cpp src/kernels/cuda/iq_kernels.cu -o iq_mxfp4_parity
./iq_mxfp4_parity
```

**What is not there yet: the MMQ prefill path.** `moe_mmq.cu` still has no MXFP4 case, so a prompt on an
MXFP4 pack has no quantised-matmul path — decode is served, prefill is not. Nobody has run a full MXFP4
model on this build, and it cannot be finished on the host this was written on: MXFP4 is 4.25 bits per
parameter, i.e. **156 GB** for this model, against 93 GB of VRAM + RAM here (32 GB on the card, 61 GB of
DDR4). It streams from NVMe at that point — the engine does read experts from disk — but at ~2-3 tok/s,
which is why the format belongs to 2× 32 GB cards + 128 GB hosts.

## Running an MXFP4 pack (image `0.2-mxfp4`, experimental)

`xxdoman/maya-gfx906:0.2-mxfp4` is `0.1` plus both patches (`gfx906-deepseek4.patch`,
`002-mxfp4-decode.patch`) — the only published image that can read MXFP4 expert blobs. Normal packs run on
it exactly as on `0.1` (13.1/14.1 tok/s against 12.3/13.9 on the same two prompts), so it is a superset, not
a fork. What it has never done is carry a real MXFP4 model: nobody has run one, because a 156 GB pack does
not fit on the host this was built on. Treat it as a test build and expect to send back a log.

Step by step, from an empty `/models`:

```sh
# 1. the shards (bartowski, MXFP4, 156.38 GB in four files)
mkdir -p /models/abyss/mxfp4 && cd /models/abyss/mxfp4
for i in 00001 00002 00003 00004; do
  curl -LO "https://huggingface.co/bartowski/DeepSeek-V4-Flash-0731-GGUF/resolve/main/\
DeepSeek-V4-Flash-0731-MXFP4/DeepSeek-V4-Flash-0731-MXFP4-$i-of-00004.gguf"
done

# 2. the pack (dense.bin, index.txt, native_experts.txt, tokenizer/) from those shards
python3 tools/abyss_setup.py --model v4 --quant /models/abyss/mxfp4 --pack /models/abyss/0731-mxfp4
```

Step 2 is the part nobody has run against MXFP4 — the pack builder is the same one that produced the IQ2_XXS
pack, and an MXFP4 expert blob is a different type in `native_experts.txt` than it expected. If it refuses,
the message is the useful part.

```sh
# 3. smoke test: the engine straight up, no Maya, one prompt
docker run --rm -it \
  --device /dev/kfd --device /dev/dri --group-add video --group-add render \
  --ulimit memlock=-1 \
  -e STRATA_GLM_RAM_GB=96 -v /models:/models \
  --entrypoint /opt/strata/engine/strata xxdoman/maya-gfx906:0.2-mxfp4 \
  --glm-pack /models/abyss/0731-mxfp4 \
  --ple-gguf /models/abyss/mxfp4/DeepSeek-V4-Flash-0731-MXFP4-00004-of-00004.gguf \
  --tokens 671,6102,294,8760,344 --max-new 32 --max-context 1024

# 4. or the whole server, with the config in this repo
docker run --rm -d --name maya \
  --device /dev/kfd --device /dev/dri --group-add video --group-add render \
  --ulimit memlock=-1 -p 8092:8092 \
  -e DEFAULT_CONFIG=strata-dsv4-mxfp4.json \
  -v /models:/models -v maya-data:/data \
  -v "$PWD/maya/config/strata-dsv4-mxfp4.json:/opt/maya/defaults/strata-dsv4-mxfp4.json:ro" \
  xxdoman/maya-gfx906:0.2-mxfp4
```

Two details that cost an afternoon if you miss them. `--ple-gguf` wants the **dense** shard, the one with the
embeddings and the tokenizer — for bartowski's layout that is `-00004-of-00004.gguf` (1220 tensors), while
`-00001` through `-00003` are pure expert blobs (35 tensors each, all type 39). And the pack directory must
contain a `tokenizer/` folder, because Maya reads it from the pack path, not from the shards.

Known gaps in this build: **prefill has no quantised matmul for MXFP4** (`moe_mmq.cu` has no case 39), so a
long prompt goes through whatever fallback the router picks — decode was the part that was ported first,
because decode is what decides tokens per second. `--kv-resident` and `--spec` behave as on any other pack.

If it falls over, these are the lines worth quoting back: `error:`/`glm pack:` at load, `glm router: prompt
layer N invalid expert ID` at prefill, and the `glm stat:` line (vram hit, disk reads/token) at decode.

## Speculative decoding: DSpark, and why it loses on one card

The engine ships a drafter for 0731 that nobody was turning on, because it is not a CLI flag: `--dspark`
does not exist and `--mtp` never reaches a pack (`generate.cpp` leaves through `glm_pack_generate()` before
the session code, which is why every pack run logs `drafter=none`). DSpark is a **separate distilled
drafter**, `src/core/dspark.cu`, 1025 lines, 3 stages over target layers 40-42, 256 experts a stage, 5
drafts a step, and it is enabled by environment:

```sh
-e STRATA_DS4_DSPARK=/models/gguf/DSpark-drafter-Q2K-Q8-MarkovQ8-0731.gguf   # 6.94 GB
-e STRATA_DS4_DSPARK_EXPERTS=64      # optional: shrink the drafter's expert cache (256 = 5.91 GB)
args: "--spec", "5"
```

The file must be the **MarkovQ8** variant from `bleysg/DeepSeek-V4-Flash-DSpark-drafter-GGUF`:
`dspark.cu:395` wants `dspark.markov_w2.weight` as Q8_0, and the plain `Q2K-Q8-0731` file fails to load with
`markov_w2.weight has another type or shape`. It loads on gfx906 with no port — `3 stages over target
layers 40-42, 5 drafts a step; 6.48 GB on CUDA0`.

Measured here, server mode (so the real tokenizer), three natural prompts — Polish technical prose, a Polish
letter, English prose — 160 tokens each, temperature 0, 8192 context, one MI50, IQ2_XXS. Mean decode:

| arm | decode | acceptance | tokens/step | expert slots | disk reads/tok |
| --- | --- | --- | --- | --- | --- |
| `--spec 4`, no drafter | **13.7 tok/s** | 0-100% of 1-3 windows | — | 3354 | 4.3-10.6 |
| DSpark, 256 experts a stage | 9.6 tok/s | 48 / 64 / 69% | 2.0-2.2 | 2451 | 8.9-20.7 |
| DSpark, 64 experts a stage | 10.7 tok/s | 52 / 60 / 71% | 1.9-2.4 | 3053 | 5.8-12.5 |

DSpark loses, by 22-30%, and the reason is visible in the same table: a verify window costs ~210-240 ms and
returns ~2.1 tokens, i.e. ~100-115 ms per token, against ~70 ms for a plain single-token step. The drafter
also evicts 500-900 expert slots, so the main model streams more from disk while drafting. Shrinking the
drafter's expert cache to 64 a stage recovers most of those slots and 1.1 tok/s, but not the deficit.

The +44% this drafter showed on a deliberately repetitive prompt (98% acceptance, all windows) is an
artifact of that prompt — on natural text acceptance is 48-71%. And on natural text n-gram drafting barely
fires at all (1-3 windows per 160 tokens), so `--spec 4` is nearly free and nearly useless for chat.

Conclusion for this box: leave DSpark off by default. Where the 6.48 GB is 10% of VRAM instead of 20% — a
2× 32 GB host with 128 GB of RAM — the trade is a different one, and that is worth measuring there before
saying anything about it.

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
