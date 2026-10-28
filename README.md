# Qwen3.8-Flash-Next NVFP4 on Windows 11 ARM64

An **unofficial** port of [MiaAI-Lab's recipe](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)
to Windows 11 on ARM64 — an **NVIDIA RTX Spark** (GB10, 128 GB unified, `sm_121`). Same NVFP4 checkpoint, same
[TensorFold](https://github.com/ashhart/TensorFold) engine, **no Docker**: a native `tensorfold-native.exe` built
with MSVC for ARM64, PowerShell scripts that replace the recipe's shell scripts, and a fix that takes model loading
from **257 s to 71 s**.

> **Hardware, precisely.** The upstream recipe targets **DGX Spark**, which ships NVIDIA's Linux-based DGX OS.
> This port targets the same GB10 Grace Blackwell module running **Windows 11 ARM64**, where it is sold and
> identified as **RTX Spark** (128 GB unified memory, 20 cores, 48 SMs at `sm_121`). Everything here is specific to
> that combination: MSVC/ARM64 instead of gcc, PowerShell instead of bash, WDDM instead of the Linux driver, and no
> container. The recipe's own directory name still says `Single-DGX-Spark` because it is the name of the upstream
> repository, not of the machine this runs on.

[中文说明](README.zh-CN.md)

```
upstream recipe (MiaAI-Lab, MIT)          this repository
  start.sh / stop.sh / config.sh   ──▶    recipe/*.ps1        (PowerShell counterparts)
  patches/0001..0017               ──▶    patches/0001       (merged into one diff)
  (Docker, amd64 images)           ──▶    scripts/*.ps1      (native MSVC build instead)
                                          patches/0002       (5 platform fixes)
                                          patches/0003       (load pipeline, 257 s → 71 s)
```

## Pinned versions

This port is verified against exactly one combination. It is pinned in the scripts, so a clone today builds
the same tree that was measured; [`VERSIONS.md`](VERSIONS.md) explains each pin and what breaks if it moves.

| Component | Pinned to |
|---|---|
| TensorFold engine | tag **`v1.1.4`** = `eab8582819688325e371907e4706e1c602b8a273` (the recipe's own `TF_REF`) |
| MiaAI-Lab recipe | commit **`fd3f43e11238553685ebb68b6d8ab2b112818e3c`**, carrying `patches/0001..0017` |
| Model checkpoint | `nvidia/Qwen3.8-Flash-Next-FP4-Local` @ **`b9ce18a6887e18c089fdea8509a33e63429a3300`** (NVFP4, `modelopt` / `MIXED_PRECISION`, 96 GB) |
| Toolchain | zig **0.17.0** aarch64-windows · CUDA toolkit **13.4** (`V13.4.92`) · MSVC **v143 14.44.35207** arm64 |
| Patch series | `0001` + `0002` + `0003`, hashes in [`VERSIONS.md` §2](VERSIONS.md) |

## What is in here

| Path | What it is |
|---|---|
| `patches/0001-recipe-0001-0017-on-v1.1.4.patch` | MiaAI-Lab's 17 recipe patches, merged into one diff against TensorFold v1.1.4 (`eab85828`), 74 files |
| `patches/0002-windows-arm64-port.patch` | 5 MSVC/Windows compatibility fixes. In the three `.cu` files the only change is `__restrict__` on explicit instantiation argument lists; no kernel arithmetic is touched |
| `patches/0003-load-pipeline.patch` | 4 host-side loader files: staged parallel expert packing, pinned double buffering, a wider shard-mapping cache, whole-row copies |
| `scripts/migration.config.ps1` | Where everything lives: detects root, python, zig, CUDA, `vcvarsall`, checkpoint; the interactive menu; saves the answers to `.migration.local.json` |
| `scripts/engine/1-preflight.ps1` … `6-smoke.ps1` | The **engine** half (TensorFold): preflight, clone, 3 patches, vision venv, build, smoke |
| `scripts/recipe/1-install-ps1.ps1` | The **recipe** half, and the only script that writes into the MiaAI-Lab clone: copies four `.ps1` in, sets `MODEL_PATH` in `.env`, changes nothing else |
| `scripts/Invoke-Migration.ps1` | One-shot runner: asks for paths, then runs the engine half, the recipe half, or both |
| `recipe/start.ps1`, `stop.ps1`, `config.ps1`, `banner.ps1` | The recipe's shell scripts as PowerShell, including two PowerShell 5.1 bug fixes (`$null` becomes `''` in a `[string]` default; 5.1's `Invoke-RestMethod` defaults to POST) |
| `SKILL.md`, `references/` | The same procedure in agent-facing form (WorkBuddy/Claude skill layout), plus build notes and the verification record |
| `docs/patching-and-port.md` | Long form: how each patch was cut, what broke, and the `.sh` → `.ps1` decisions one by one |
| `NOTICE`, `LICENSES/`, `CREDITS.md` | License chain. Read `NOTICE` before redistributing anything |
| `VERSIONS.md` | The pinned engine / recipe / checkpoint / toolchain, the patch hashes, and what breaks if a pin moves |

## Quick start

```powershell
git clone https://github.com/edisonchan/Qwen3.8-Flash-Next-NVFP4-Windows-ARM64
cd Qwen3.8-Flash-Next-NVFP4-Windows-ARM64

.\scripts\Invoke-Migration.ps1
```

It first shows where it thinks everything is (root, python, zig, CUDA, `vcvarsall`, checkpoint) and lets you
change any row — then asks which half to run. Nothing is hard-coded, so this works from any disk or folder.

Step by step, if you want to see each stage:

```powershell
.\scripts\engine\1-preflight.ps1
.\scripts\engine\2-clone.ps1
.\scripts\engine\3-apply-patches.ps1          # expect 78 entries, 3 patches, 2 spot-checks
.\scripts\engine\4-venv.ps1                   # torch from NVIDIA's index, then tensorfold[vision]
.\scripts\engine\5-build.ps1                  # BUILD_EXIT=0, ~5 min
.\scripts\engine\6-smoke.ps1                  # version 1.1.4 / nvidia-sm121 / OK
.\scripts\recipe\1-install-ps1.ps1            # the four .ps1 into the recipe clone
```

Every step reads the saved paths, so none of them needs an argument. A parameter you pass still wins
(`-TensorFold E:\ai\TensorFold`), and `-Reset` re-opens the path questions.

### Paths

`scripts\migration.config.ps1` is the single place that decides where things are. It detects candidates —
root from where this repository sits, python/zig from `PATH` and the usual install folders, CUDA from
`CUDA_PATH` and the toolkit's install root, `vcvarsall` from any VS 2022 install, the checkpoint from
`MODEL_PATH` and `<parent of root>\model` — then the menu lets you accept or change each row. The accepted
set goes to `.migration.local.json` (git-ignored), so a re-run is one keystroke and every script sees the
same values.

Sample run (values on the reference machine — yours will be whatever it detects):

```
 [1] root     D:\llm\latest
 [2] python   C:\Users\you\AppData\Local\Programs\Python\Python313-arm64\python.exe
 [3] zig      D:\llm\zig-aarch64-windows-0.17.0\zig.exe
 [4] cuda     C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4
 [5] vcvars   C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat
 [6] model    D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

The engine and recipe folders are derived from `root` (`<root>\TensorFold`, `<root>\Qwen3.8-Flash-Next-…`)
because the recipe's own `config.ps1` looks for its sibling that way; only `root` is a choice.

### Two halves, two repositories

| | what is touched | scripts |
|---|---|---|
| **engine** | TensorFold: 3 patches applied, then built | `scripts\engine\` |
| **recipe** | MiaAI-Lab's clone: four `.ps1` added, `.env` gets `MODEL_PATH` — no line of their code changes | `scripts\recipe\` |

`recipe\1-install-ps1.ps1` checks that claim itself: at the end it runs `git -C <recipe> status --porcelain`
and expects new files only, no modifications.

Both clones are **pinned**, not followed: the engine to `v1.1.4` and the recipe to the commit patch `0001` was
cut from (see [`VERSIONS.md`](VERSIONS.md)). `2-clone.ps1` warns if the recipe's `main` has moved past that
point; pass `-RecipeRef ''` only if you intend to follow it.

Serving. The recipe clone carries the `.sh` files; the installer puts the PowerShell ones beside them:

```powershell
.\scripts\recipe\1-install-ps1.ps1      # start.ps1, stop.ps1, scripts\config.ps1, scripts\banner.ps1

# no path is typed by hand: read back what the menu accepted
$root = (Get-Content .migration.local.json -Raw | ConvertFrom-Json).root
$Q    = Join-Path $root 'Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'
# 30.5 GB of host memory on this class of machine: 5 streams need 23.74 GiB of KV and the
# admission budget is 22.81 GiB, so 4 is what fits. Failed only after all 48 layers loaded.
Add-Content "$Q\.env" @('TENSORFOLD_LOAD_STATS=1', 'PARALLEL=4')

& "$Q\start.ps1"    # [start.ps1] server answered after 71s
& "$Q\stop.ps1"
```

### Python and torch

`engine\4-venv.ps1` builds the venv **inside the recipe folder** (`<recipe>\venv`), because that is where
`start.ps1` looks for `Scripts\python.exe`. It installs, in this order:

```powershell
# 1. torch from NVIDIA's out-of-tree nightly index -- the recipe's own platform gets these
#    from the nvcr.io/nvidia/pytorch base image, which does not exist on Windows
python -m pip install --pre --upgrade --only-binary=:all: `
  --extra-index-url https://pypi.nvidia.com/nvtorch_oot_nightly torch torchvision torchaudio

# 2. the vision package; v1.1.4's setup.py refuses to install as a Python package, so v0.6.6
python -m pip install "tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6"

# 3. the probe start.ps1 runs before it enables vision
python -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
```

Order matters: installing `tensorfold[vision]` first would pull a plain PyPI torch in as a dependency. Skip the
whole step for text-only serving (`VISION=0`); add `-SkipTorch` if you already have a torch build you trust.

### Weights

Not in this repository. Either host serves the same export, ~96 GiB of it:

```powershell
# Hugging Face
hf download nvidia/Qwen3.8-Flash-Next-FP4-Local --revision b9ce18a6887e18c089fdea8509a33e63429a3300 --local-dir D:\llm\model\Qwen3.8-Flash-Next-FP4-Local

# ModelScope mirror (faster from the mainland; needs pip install modelscope)
modelscope download --model nv-community/Qwen3.8-Flash-Next-FP4-Local --local_dir D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

`recipe/config.ps1` defaults `MODEL_PATH` to that directory; set `MODEL_PATH` in `.env` to point elsewhere.

A mirror is a different host, not a different model — so check the download is the export this engine takes:
`config.json` must carry `quant_method: modelopt` and `quant_algo: MIXED_PRECISION`. A GPTQ re-upload loads with
`UnsupportedCheckpoint`. The terms travel with the weights from either host: NVIDIA's Open Model Agreement for the
FP4 export, the Qwen Community License 1.0 for the base model.

## Model load: 257 s → 71 s

48 layers, 512 routed experts each, assembled on the host from 14 checkpoint shards per layer.

| | before | after |
|---|---|---|
| whole load | 257 s | **71 s** |
| per layer | ~5.0 s | **1.12 s** |
| expert packing (CPU) | serial, one at a time | 698 ms × 20 threads |
| HtoD wait per layer | 3 full synchronises | **18 ms** (`stage wait`, 1.6 %) |

Four changes, all on the host side — no `.cu` file and no kernel launch configuration was modified:
grouped parallel packing (32 groups × 16 experts over every core), pinned double buffering with
`cuMemcpyHtoDAsync` on its own stream and event back-pressure, a shard-mapping cache widened from 2 slots
to 48 (a layer's 14 shards stay held, instead of being reopened and re-parsed per layer), and whole-row
`memcpy` instead of one per row.

`stage wait` is the metric that tells you whether the double buffer is big enough: 0.87 s of 67.6 s. If it
climbs past a few percent, raise `TENSORFOLD_LOAD_GROUP` before touching anything in CUDA.

## Requirements

**Windows 11 ARM64** on an **NVIDIA RTX Spark** (GB10 Grace Blackwell, 128 GB unified memory, 20 cores, 48 SMs at
`sm_121`) · CUDA 13.4 · Zig 0.17.0 (aarch64-windows) · MSVC 2022 Build Tools with the ARM64 host · PowerShell 5.1 ·
Python 3.13 arm64 for `--vision` only.

Not DGX Spark: that is the same GB10 module under NVIDIA's Linux DGX OS. Nothing here runs on Linux, and the
recipe's Linux path (Docker image, bash, `/proc`) is exactly what this port replaces.

No path is fixed: `scripts\migration.config.ps1` finds these, and `.migration.local.json` remembers what you
accepted. `1-preflight.ps1` hard-fails on zig ≠ 0.17.0 and warns when nvcc is not 13.4.

## License

MIT for this repository's own work, Apache-2.0 (plus pre-0.6.0 MIT) for the TensorFold code the patches
modify, MIT for the recipe patches this ports. `LICENSE` is the plain MIT text, with both copyright holders in
it so GitHub detects it as MIT; `NOTICE` says which files each holder covers, and `LICENSES/` carries every
full text. No weights, no binaries, nothing to relicense by accident.

Not affiliated with, sponsored by, or endorsed by MiaAI-Lab, the TensorFold authors, NVIDIA or the Qwen team.

## Credits

This repository is a thin layer of scripts. Almost everything that makes it work was built by others; the
full, patch-by-patch record is in [`CREDITS.md`](CREDITS.md), and [`NOTICE`](NOTICE) says which files each
license holder covers.

**Model.** [Qwen3.8 Flash Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next) by the
[Qwen team](https://huggingface.co/Qwen) at Alibaba — design, training, chat template and MTP head, under the
[Qwen Community License 1.0](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE).

**Checkpoint.** [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local)
by **NVIDIA** — Qwen3.8 Flash Next quantized with quantization-aware distillation against the bf16 teacher,
using NVIDIA Model Optimizer: NVFP4 routed experts with CSF-compressed scales, MXFP8 attention / DeltaNet /
shared experts, an NVFP4 n-gram table, quantized MTP and vision towers. Under the
[NVIDIA Open Model Agreement](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-agreement/);
the Qwen license applies as well. The optional `CHECKPOINT=int4` preset is
[`azampatti/Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound`](https://huggingface.co/azampatti/Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound)
by **azampatti** (expert cut, shared-expert healing, packaging), built on **Intel**'s
[AutoRound W4A16](https://huggingface.co/Intel/Qwen3.8-Flash-Next-W4A16-AutoRound) and on the hybrid checkpoint
of **Saren-Arterius**; the earlier MLX-4bit path was
[`Vontra/Qwen3.8-Flash-Next-MLX-4bit-MTP`](https://huggingface.co/Vontra/Qwen3.8-Flash-Next-MLX-4bit-MTP).

**Engine.** [TensorFold](https://github.com/ashhart/TensorFold) by **Ash Hart** ([ashhart](https://github.com/ashhart))
and the TensorFold contributors — the Zig engine `tensorfold-native`, its CUDA runtime and kernels, MTP drafting
with exact verification and the OpenAI-compatible server (Apache 2.0 from v0.6.0, MIT before). The Zig CUDA
serving path and the CUDA family registry are **Jürgen Schmied**'s
([jschmied](https://github.com/jschmied)) work in [PR #443](https://github.com/ashhart/TensorFold/pull/443).
Built with **[Zig](https://ziglang.org)** 0.17.0 (Zig Software Foundation, MIT) and CUDA 13.4.

**Recipe and patches.** The [MiaAI-Lab recipe](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)
(commit `fd3f43e`), its 17 patches on TensorFold v1.1.4, `start.sh` / `stop.sh` / `scripts/`, the checks in
`tools/`, and the earlier db281878 series are **MiaAI-Lab**'s work. Contributors carried forward there:
[tempeste](https://github.com/tempeste) (free-after-drain and admission reclaim, image prompts in the prompt
cache), [BadAd84](https://github.com/BadAd84) (sliced fills, PR #53),
[MovieMaker93](https://github.com/MovieMaker93) (prefill rows, TensorFold #40),
[jvr0x](https://github.com/jvr0x) (language draft vocabularies) and
[321sssrt-bit](https://github.com/321sssrt-bit) (full-window admission, `tools/context_boundary.py`). The
benchmarks behind the performance numbers are [sparkDash](https://github.com/MiaAI-Lab/sparkDash).

**Runtime stack.** CUDA / NCCL from NVIDIA; [transformers](https://github.com/huggingface/transformers),
[Hugging Face Hub](https://huggingface.co/) and [safetensors](https://github.com/huggingface/safetensors);
[Triton](https://github.com/triton-lang/triton) (the engine replays its compiled cubins);
[PyAV](https://github.com/PyAV-Org/PyAV) + [FFmpeg](https://ffmpeg.org/) for video and
[Pillow](https://python-pillow.org/) for images; torch and torchvision from NVIDIA's
`pypi.nvidia.com/nvtorch_oot_nightly` index. On Linux the recipe takes all of this from
`nvcr.io/nvidia/pytorch:26.07-py3`; on Windows the venv replaces that image (see *Python and torch* above).

**Hardware.** Every number here was measured on an **NVIDIA RTX Spark** — the GB10 Grace Blackwell module
(128 GB unified memory, 20 cores, 48 SMs at `sm_121`) running **Windows 11 ARM64**. Its Linux sibling is
[DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/), which is what upstream's numbers were
taken on; the silicon is the same, the OS and driver stack are not.

If you believe something above is missing or credited wrongly, please open an issue.
