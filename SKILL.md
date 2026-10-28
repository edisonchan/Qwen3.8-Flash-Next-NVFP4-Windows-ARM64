---
name: tensorfold-windows-arm64-migration
description: Complete migration that reproduces the TensorFold v1.1.4 + Qwen3.8-Flash-Next recipe from a git clone on any Windows 11 ARM64 machine (aarch64-windows, sm_121 / GB10 / RTX Spark N1X): environment preflight, cloning both repos, applying patches, vision venv, CUDA build, and smoke verification, cutting model load from 257 s to 71 s (grouped parallel assembly + pinned double buffering + shard mapping cache). Ships 6 executable .ps1 scripts and 3 patch files; artifacts land only in the repo's build directory; model loading is left to the user. 触发词：TensorFold 迁移、TensorFold Windows ARM 构建、tensorfold-native 编译、aarch64-windows CUDA 构建、Qwen3.8 Flash Next Windows 部署、模型加载慢、加载提速。
agent_created: true
---

# TensorFold v1.1.4 · Windows ARM64 Migration (Reproducible Recipe)

[中文](SKILL.zh-CN.md)

Goal: on a **brand-new Windows 11 ARM64** machine (**NVIDIA RTX Spark**, GB10 / 128 GB unified memory /
`sm_121`), get a runnable `tensorfold-native.exe` using nothing but `git clone` plus this skill's three patches,
and know why it compiles and why loading takes only 71 s (native path 257 s). Every step was measured to pass on
this machine (RTX Spark N1X / GB10, sm_121), and the patches restore the current production tree **byte for byte** (verification record: `references/verification.md`).

> **Machine model**: in the section 0 quick-reference table the recipe repo name contains `Single-DGX-Spark`; that is the **upstream repo name**. Upstream runs on **DGX Spark (Linux / DGX OS)**;
> this skill targets only **the same GB10 running Windows 11 ARM64**, i.e. **RTX Spark**. This workflow is not needed on Linux, and must not be copied there wholesale.

---

## 0. One-Page Quick Reference

| Item | Pinned value |
|---|---|
| Engine upstream | `https://github.com/ashhart/TensorFold` |
| Engine version | tag `v1.1.4` = `eab8582819688325e371907e4706e1c602b8a273` |
| Recipe upstream | `https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold` **pinned at** `fd3f43e11238553685ebb68b6d8ab2b112818e3c` (its `patches/0001..0017` are the source of patch 0001) |
| Engine pinned by the recipe | `scripts/config.sh` → `TF_REF=eab8582819688325e371907e4706e1c602b8a273` (the same commit as the row above) |
| Where engine/recipe refs land | `2-clone.ps1 -TfRef/-RecipeRef`, the same-named parameters of `Invoke-Migration.ps1`, `3-apply-patches.ps1` hard-validates HEAD |
| Version master table | `VERSIONS.md` (why each pin exists + what breaks if it moves + verification commands) |
| zig | 0.17.0 aarch64-windows, `sha256 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8` |
| CUDA | 13.4 toolkit (`nvcc.exe`, `V13.4.92`); the driver must support CUDA 13.x (this machine `621.01` / API `13050` = 13.5) |
| MSVC | VS 2022 Build Tools `14.44.35207` + `MSVC v143 C++ ARM64 build tools` (`Hostarm64\arm64\cl.exe`) |
| GPU target | `sm_121` (`compute_121`, RTX Spark N1X, 48 SMs) |
| Weights | `nvidia/Qwen3.8-Flash-Next-FP4-Local` @ `b9ce18a6887e18c089fdea8509a33e63429a3300` (`modelopt`/`MIXED_PRECISION`, 96 GB) |
| Python | 3.13 arm64 (only needed for `--vision`; the venv is built inside the recipe directory, see section 3) |
| Model load | **71 s / 48 layers** (all three patches applied; the native path is 257 s, see section 8) |
| Install root | **not hardcoded**: `scripts\migration.config.ps1` probes + an interactive menu; the result is saved to `.migration.local.json` |
| Path sources | every script takes its values from the config module; explicit parameters > saved config > probed values |

**The directory layout is a hard constraint**: the recipe's `scripts\config.ps1` computes the engine path as
`<parent directory of the recipe>\TensorFold\build\native\bin\tensorfold-native.exe`. So the two clones must be **siblings**,
and the engine directory must be named **exactly `TensorFold`** (only the root is optional; these two directory names are dictated by the recipe):

```
<Root>\                                             <- menu item 1; defaults to this repo's directory
├─ Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\   <- the recipe (we only add .ps1 files to it)
│  ├─ patches\  scripts\  start.ps1  stop.ps1  venv\
└─ TensorFold\                                       <- the engine (the name must not change)
   └─ build\native\bin\tensorfold-native.exe
```

Otherwise startup reports `tensorfold-native.exe not found at ...` (`NATIVE_BIN` can override it, but that is not recommended).

**One command completes the migration** (answer the paths in the menu; they are never asked again):

```powershell
cd <this skill's directory>
powershell -ExecutionPolicy Bypass -File scripts\Invoke-Migration.ps1
# menu: confirm root/python/zig/cuda/vcvars/model first, then pick engine / recipe / both
# non-interactive: -Only engine -NonInteractive   re-ask paths: -Reset
```

### 0.1 Paths are not hardcoded

All scripts dot-source `scripts\migration.config.ps1`; not a single `D:\llm\latest` appears anywhere in the code:

| Item | Probe source | Overridable via |
|---|---|---|
| root | the directory containing this repo (its siblings are where the two clones live) | menu item 1, `-Root` |
| python | `PATH` → `%LOCALAPPDATA%\Programs\Python` → `%ProgramFiles%` → `C:\` | item 2, `-Python` |
| zig | `PATH` → `zig*` directories under `<parent of root>`/`<root>` | item 3, `-Zig` |
| CUDA | `CUDA_PATH` → all versions under the toolkit install root (accepted only if `bin\nvcc.exe` is present) | item 4, `-Cuda` |
| vcvars | the `vcvarsall.bat` of any VS 2022 (BuildTools/Community/Pro/Enterprise) | item 5, `-Vcvars` |
| model | `MODEL_PATH` → `<parent of root>\model\<name>` → `<root>\model\<name>` | item 6, `-ModelPath` |

The menu validates on acceptance (zig must be 0.17.0, nvcc must be 13.4, python must be 3.11+ and aarch64, weights must be
`modelopt`/`MIXED_PRECISION`); anything fatally wrong requires a second confirmation, so you don't blow up three steps later. After
confirmation it writes `.migration.local.json` (git-ignored); deleting that file is equivalent to "ask again".

### 0.2 Two tracks: engine and recipe

| | What it touches | Scripts | Artifacts |
|---|---|---|---|
| **engine** | TensorFold: three patches + build | `scripts\engine\1-preflight … 6-smoke` | `TensorFold\build\native\bin\tensorfold-native.exe` |
| **recipe** | the MiaAI-Lab clone: **files added only** | `scripts\recipe\1-install-ps1.ps1` | `start.ps1`, `stop.ps1`, `scripts\config.ps1`, `scripts\banner.ps1` (+ `MODEL_PATH` in `.env`) |

The recipe's sources, `patches/0001..0017`, and Dockerfile are never touched. At the end, `1-install-ps1.ps1` verifies
itself: `git -C <recipe> status --porcelain` should show only `??` (added) and never ` M` (modified).

---

## 1. Environment Requirements

### 1.1 Hardware and OS

| Item | Requirement | Measured on this machine |
|---|---|---|
| Machine | **NVIDIA RTX Spark** (GB10 Grace Blackwell, 128 GB unified memory, 20 cores) running Windows 11 ARM64. **Not DGX Spark** — that is the Linux product on the same GB10 | RTX Spark N1X |
| CPU/OS | Windows 11 ARM64 (`Win32_Processor.Architecture = 12`, see section 9 #8) | ✅ |
| GPU | NVIDIA, compute capability 12.1 (GB10, 48 SMs) | RTX Spark N1X, 48 SMs |
| VRAM/unified memory | weights 81 GiB (NVFP4) + ~4.7 GiB KV per stream | GPU pool 98 GiB, ~30 GiB visible to the OS |
| Disk | source + cache ≥ 25 GiB; the **model needs 96 GiB more** | D: 1.5 TB |

> On a unified-memory machine, `MemAvailable` only reflects the system side (~30 GiB); weights and KV are carried by the
> driver's GPU pool. The start script's memory floor is a **read-only warning** and never blocks startup; the engine
> covers itself via `TENSORFOLD_MEMORY_RESERVE_GIB`.

### 1.2 Required components (with self-check commands)

| Component | Version | Self-check | Notes |
|---|---|---|---|
| zig | **0.17.0** (aarch64-windows) | `zig version` | the version must match exactly; 0.16/0.18 fail on API changes such as `std.posix.mmap` and `std.Io.Clock` |
| CUDA Toolkit | **13.4** | `nvcc --version` | must install the toolkit, not just the driver; `cublasLt64_13.dll` is used by vision |
| MSVC | VS2022 Build Tools 17.14+ | `vcvarsall.bat` exists and has `Hostarm64\arm64\cl.exe` | install "Desktop development with C++" + "MSVC v143 C++ ARM64 build tools" |
| git | any recent version | `git --version` | |
| Python | 3.11–3.13 (arm64) | `python -V` | only needed for `--vision` |

zig download: `https://ziglang.org/download/0.17.0/zig-aarch64-windows-0.17.0.zip`; after unpacking, pass the
`zig.exe` path to the scripts (default `D:\llm\zig-aarch64-windows-0.17.0\zig.exe`).
**Strongly recommended: keep every path pure ASCII** (Chinese/space paths collide with cmd's code page 936 and nvcc's C4819 warning).

### 1.3 One-shot preflight

```powershell
powershell -ExecutionPolicy Bypass -File scripts\engine\1-preflight.ps1
# custom paths:
powershell -ExecutionPolicy Bypass -File scripts\engine\1-preflight.ps1 `
  -Zig "E:\tools\zig.exe" -Cuda "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4" `
  -Vcvars "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" `
  -Root "E:\ai"
```

Each item prints `[ OK ]/[WARN]/[FAIL]`; any `FAIL` exits with code 1. **Pass this gate before cloning** — it saves a wasted 6-minute build later.

---

## 2. Recipe and TensorFold Clones

### 2.1 Commands

```powershell
powershell -ExecutionPolicy Bypass -File scripts\engine\2-clone.ps1 -Root "D:\llm\latest"
# pin the recipe commit (optional, recommended for exact reproduction):
powershell -ExecutionPolicy Bypass -File scripts\engine\2-clone.ps1 -Root "D:\llm\latest" -RecipeRef fd3f43e
```

Equivalent manual commands:

```powershell
cd D:\llm\latest
git clone https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
git clone https://github.com/ashhart/TensorFold
cd TensorFold
git checkout --detach eab8582819688325e371907e4706e1c602b8a273
```

### 2.2 Verification

```powershell
git -C D:\llm\latest\TensorFold rev-parse HEAD
# expected: eab8582819688325e371907e4706e1c602b8a273
git -C D:\llm\latest\TensorFold status --porcelain     # must be empty
git -C D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold rev-parse --short HEAD
```

The script writes both repos' commits, the hostname, the architecture, and the remaining disk into
`TensorFold\build\logs\00-migration-manifest.json`.

> **Why `--detach eab85828`**: the recipe's `scripts/config.sh` `TF_REF` pins exactly this release.
> Engine `main` has already moved on (v1.1.5/v1.1.6); the patches were cut against v1.1.4 and will not apply on `main`.

### 2.3 Clone the full history

The patches are merge patches (see section 4); `git apply` only needs the working tree, so `--depth 1` would work; but a full clone is only
~150 MB and makes later `git diff` review easy — **do not use shallow clones**.

---

## 3. venv Setup (Optional, `--vision` only)

The native engine running text needs **no Python**. Only when `--vision` (image/video input) is enabled does the engine spawn
`tensorfold.vision.native_helper`, and then a venv is required.

There are three key points:

1. **The venv lives inside the recipe directory** (`<recipe>\venv`). Not just anywhere — `scripts\config.ps1` computes
   `TENSORFOLD_VISION_PYTHON` as `<recipe>\venv\Scripts\python.exe`, and `start.ps1` checks that it exists before enabling vision.
2. **torch must be installed first, and from NVIDIA's out-of-tree index**. On its own platform the recipe gets torch from the
   `nvcr.io/nvidia/pytorch:26.07-py3` base image; that image does not exist on Windows, so this layer has to be made up inside the venv.
   `--only-binary=:all:` is mandatory: there is no usable source-build path.
3. **Install tensorfold at the v0.6.6 tag**. v1.1.4's `setup.py` **actively refuses to install** ("installs as a native binary …
   the Python engine stays at 0.6.6").

```powershell
powershell -ExecutionPolicy Bypass -File scripts\engine\4-venv.ps1
# args: -Recipe <recipe> -VenvDir <venv> -Python <python.exe> -SkipTorch -Recreate
```

Manual equivalent (do not change the order: torch first, otherwise `tensorfold[vision]` pulls the regular PyPI torch in as a dependency):

```powershell
cd <recipe directory>
python -m venv venv
venv\Scripts\python.exe -m pip install --upgrade pip

# 1) torch: the NVIDIA OOT nightly index
venv\Scripts\python.exe -m pip install --pre --upgrade --only-binary=:all: `
  --extra-index-url https://pypi.nvidia.com/nvtorch_oot_nightly torch torchvision torchaudio

# 2) the vision package (v0.6.6, not the local checkout)
venv\Scripts\python.exe -m pip install "tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6"
```

### 3.1 Verification (identical to engine step 1's probe)

```powershell
venv\Scripts\python.exe -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
echo $LASTEXITCODE   # 0 = pass

# does torch carry CUDA (the script prints it too; False means vision falls back to CPU or fails outright)
venv\Scripts\python.exe -c "import torch; print(torch.__version__, torch.version.cuda, torch.cuda.is_available())"
```

### 3.2 Measured package versions on this machine (for troubleshooting)

| Package | Version | Notes |
|---|---|---|
| Python | 3.13.16 (arm64) | `%LOCALAPPDATA%\Programs\Python\Python313-arm64`; must be aarch64, x64 wheels will not install |
| tensorfold | 0.6.5 (this machine) / v0.6.6 (recommended) | both provide `native_helper` |
| torch / torchvision | 2.14.0+cu134 / 0.29.0+cu134 | from `nvtorch_oot_nightly`; `--pre` installs exactly the nightly |
| transformers | 5.20.2 | vision extra |
| pillow / av | 13.0.0 / 19.0.2 | vision extra |
| numpy / safetensors / huggingface_hub | 2.5.4 / 0.8.0 / 2.3.0 | core dependencies |

> Disk budget: the venv is about 3–6 GB (torch alone is over 2 GB; under 1 GB if torch is skipped). The network must reach
> `pypi.nvidia.com`, `github.com` and PyPI. torch nightly rolls forward — when some nightly breaks, skip it with
> `-SkipTorch`, or manually install a known-good version inside that venv.

---

## 4. Migration Steps and Patch Placement

### 4.1 What the three patches are

| File (`patches\`) | Content | Size | sha256 |
|---|---|---|---|
| `0001-recipe-0001-0017-on-v1.1.4.patch` | The **merged result** of the recipe's `patches/0001..0017`, flattened onto `eab85828` | 74 files / +7081 −152 | `c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad` |
| `0002-windows-arm64-port.patch` | Windows/MSVC compatibility fixes (**never touches kernel arithmetic**) | 5 files / +34 −21 | `9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40` |
| `0003-load-pipeline.patch` | Model-load pipeline: grouped parallel assembly + pinned double-buffered async copy + shard mapping cache + whole-block memcpy (**all host-side, never touches .cu / kernel launch parameters**; rationale and trade-offs in section 8) | 4 files / +273 −35 | `911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64` |

The three patches with their 74/5/4 split baselines, and every pinned value for engine/recipe/weights/toolchain, have one authoritative table: `VERSIONS.md`.

Together the three touch **78 files** (59 modified + 19 added). **The order cannot be changed**: `0003` was cut on a tree where
"`0001`+`0002` are already applied", and two of its files (`cuda_prompt.zig`, `cuda_prompt_wt.zig`) were already changed by `0001`.
`3-apply-patches.ps1` applies in filename-sorted order, which satisfies this naturally; manual application must also go 0001 → 0002 → 0003.

Note: `qmm_prefill.cu` in `0002` is **not** among `0001`'s
74 files — upstream v1.1.4 never had `__restrict__` in that file, and the recipe patches never touched it, so this is a pure
MSVC compatibility issue, unrelated to the recipe.

Why a merged patch rather than `git apply`-ing the recipe's original patches one by one: those 17 patches were generated against an
earlier `db281878`; applying them directly onto `eab85828` leaves 11 conflicts requiring a manual three-way merge — **not
reproducible**. The first patch in the table above is the **final correct result** of that three-way merge, verified by byte-for-byte
comparison (75/75 file hashes match), and a build from a from-scratch clone passes.

The cost: the patch is large (~495 KB), but `git apply` is one-shot and deterministic.

### 4.2 Applying

```powershell
powershell -ExecutionPolicy Bypass -File scripts\engine\3-apply-patches.ps1
```

The script does four things: checks HEAD == `TF_REF`, checks the working tree is clean, runs `git apply --check` then `git apply` for
each patch, and writes the patch names and sha256 into `TensorFold\build\logs\01-patches.log`.

Manual equivalent:

```powershell
cd D:\llm\latest\TensorFold
git checkout --detach eab8582819688325e371907e4706e1c602b8a273
git apply --check "<skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch"
git apply         "<skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch"
git apply --check "<skill>\patches\0002-windows-arm64-port.patch"
git apply         "<skill>\patches\0002-windows-arm64-port.patch"
git apply --check "<skill>\patches\0003-load-pipeline.patch"
git apply         "<skill>\patches\0003-load-pipeline.patch"
git status --porcelain --untracked-files=all | Measure-Object | Select-Object -Expand Count   # expected 78
```

### 4.3 `0002` item by item (5 changes, all platform compatibility)

| # | File | Symptom (if unfixed) | Change | Why |
|---|---|---|---|---|
| 1 | `zig/kernels/cuda/qmm_prefill.cu` | `error: no instance of function template "prefill_kernel" matches the specified type` | add `__restrict__` to the formal parameters of the two explicit instantiations | MSVC requires the parameter types of an explicit instantiation to match the template definition **verbatim** (qualifiers included); GCC/clang ignore `__restrict__`, so upstream Linux compiles |
| 2 | `zig/kernels/cuda/prefill_attention.cu` | same (hpattn / hpattn8) | same | same |
| 3 | `zig/kernels/cuda/gdn_prefill.cu` | same (chain_kernel) | same | same |
| 4 | `zig/src/families/flashnext/cuda_ple_reader.zig` | `error: type 'void' does not support struct initialization syntax` | the anonymous `mmap` goes through `page_allocator.alignedAlloc` on the Windows branch; the Linux path is unchanged, not one character | on Windows targets `std.posix.MAP` is `void` and anonymous mappings do not exist; `PageAllocator` is backed by `VirtualAlloc`, equally anonymous/zeroed/commit-on-demand |
| 5 | `zig/src/families/flashnext/cuda_ple.zig` | `error: parameter of type 'void' not allowed in function with calling convention 'aarch64_aapcs_win'` | `Stat.now()` switched to `std.Io.Clock.awake.now(io)`; `Ngram` gains an `io` field | this zig version removed `std.posix.clock_gettime`, and on Windows `std.c.CLOCK` is `void`; `Io.Clock` is implemented by std on Windows using QPC |

> These 5 changes **only affect compilability**: they change no kernel parameters, launch configuration, precision or arithmetic
> path, and touch none of the performance switches the patches bring in.

### 4.4 Rollback

```powershell
cd D:\llm\latest\TensorFold
git reset --hard eab8582819688325e371907e4706e1c602b8a273
git clean -fd            # removes the 19 untracked files the patches added
git status --porcelain   # should be empty
```

### 4.5 Patch file locations

```
<this skill>\patches\
├─ 0001-recipe-0001-0017-on-v1.1.4.patch
├─ 0002-windows-arm64-port.patch
└─ 0003-load-pipeline.patch
```

**Do not** apply the recipe repo's `patches/0001..0017` sequentially (they will conflict); those 17 files in the recipe repo are upstream originals, kept for provenance.

---

## 5. Build

```powershell
powershell -ExecutionPolicy Bypass -File scripts\engine\5-build.ps1
# custom:
powershell -ExecutionPolicy Bypass -File scripts\engine\5-build.ps1 -TensorFold "E:\ai\TensorFold" -Sm 121
```

### 5.1 What it actually runs

The script generates `TensorFold\build\build_now.bat`, whose content is equivalent to:

```bat
@echo off
chcp 65001 >nul
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" arm64
set ZIG_LOCAL_CACHE_DIR=<TF>\build\.zig-cache
set ZIG_GLOBAL_CACHE_DIR=<TF>\build\zig-cache-global
set TMP=<TF>\build\tmp
set TEMP=<TF>\build\tmp
cd /d "<TF>"
"<zig>" build native install -Dsm=121 -Dnvcc="<CUDA>\bin\nvcc.exe" --prefix build > "<TF>\build\logs\05-build.log" 2>&1
```

Then it runs `cmd.exe /c build_now.bat`.

**Why it must go through cmd + vcvarsall**: nvcc finds the arm64 `cl.exe` through the `PATH/INCLUDE/LIB` set by
`vcvarsall arm64`. `call`-ing a .bat from PowerShell only affects the child cmd and **cannot change PowerShell's own
environment**; miss this step and every `.cu` just reports `error: process exited with code 1`, with no way to see the real cause.

### 5.2 Artifacts and logs

| Artifact | Path | Size (measured) |
|---|---|---|
| engine | `TensorFold\build\native\bin\tensorfold-native.exe` | 36 MB, `PE32+ ARM64` |
| CUDA self-check tool | `TensorFold\build\bin\tf-cuda-test.exe` | 78 MB |
| build log | `TensorFold\build\logs\05-build.log` | ANSI/GBK encoded |

Time: cold build 5–8 minutes (the first build compiles every fatbin); incremental builds usually < 1 minute.

Mind the log encoding: read with `Get-Content -Encoding Default` (GBK), or decode in Python with `decode('gbk')`;
reading as UTF-8 directly yields mojibake, and nvcc's Chinese C4819 warnings especially interfere with interpretation.

---

## 6. Smoke Test (no model loaded)

```powershell
powershell -ExecutionPolicy Bypass -File scripts\engine\6-smoke.ps1
```

The three checks and expected output:

| Check | Expected |
|---|---|
| `tensorfold-native.exe --help` | prints `usage: tensorfold-native --version \| capabilities --json \| ...` |
| `... capabilities --json` | `"version":"1.1.4"`, `"chip":"nvidia-sm121"`, `"backends":["cuda"]` |
| `tf-cuda-test.exe info` | `RESULT driver CUDA 13050, device NVIDIA RTX Spark N1X ..., sm_121, 48 SMs, ..., kernels embedded true` |

`kernels embedded true` is critical: it means the fatbin is compiled into the exe, so a Triton AOT kernel set is **not**
needed. If it reads `false`, you must generate `build\kernels\sm121` **for this exe** with `tools/zig/flashnext_aot.py`.

> `tf-cuda-test` writes its result to stderr, which PowerShell renders as `NativeCommandError` (red text) — a display-layer
> false alarm, not a failure; just read the content of the `RESULT` line.

---

## 7. Model Location

### 7.1 Only one supported weight set (`scripts\config.ps1`)

This repo applies **only** to `nvidia/Qwen3.8-Flash-Next-FP4-Local` (`modelopt` / `MIXED_PRECISION`, 96 GB).
Setting `CHECKPOINT` to anything else does not degrade and there is no second preset: `start.ps1` calls `Die` right after
the validate block (line 62), before loading and before touching any weights — so you will not wait for 48 layers to be read before seeing `UnsupportedCheckpoint`.

| `CHECKPOINT` | Default `MODEL_PATH` | Weights GiB |
|---|---|---|
| `nvfp4` (the only supported value, and the default) | `D:\llm\model\Qwen3.8-Flash-Next-FP4-Local` | 81 |

For any other value, `config.ps1` only sets `$ModelPath` to empty and marks `$QuantLabel` as `unsupported`; it does **not** `exit` there:
`stop.ps1` also dot-sources this file, and it does not care about the checkpoint at all. The rejection lives in `start.ps1`, because only startup needs weights.

Override: `$env:MODEL_PATH='E:\models\xxx'; .\start.ps1`, or write it into the recipe root's `.env`:

```ini
MODEL_PATH=D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

### 7.2 The engine's hard validation (`zig/src/families/flashnext/cuda_config.zig`)

When reading `config.json` the engine demands **all of the following**; any mismatch raises `UnsupportedCheckpoint` naming the offending field:

- `architectures = ["Qwen4ExpForConditionalGeneration"]`, `model_type = "qwen4_exp"`
- `quantization_config.quant_method = "modelopt"`
- `quantization_config.quant_algo = "MIXED_PRECISION"`
- `quantization_config.kv_cache_quant_algo` must not exist
- `quantized_layers`: per-layer NVFP4 (routed experts, block 16) + MXFP8 (shared_expert / attention projections, block 32)
- `tie_word_embeddings = false`

The AutoRound INT4 version has `quant_method = "gptq"`, failing the first condition — **this is not a configuration issue; the engine has
removed that quantization path**, so this repo provides no preset for it and no download link for it in the docs.

### 7.3 Directory layout (note the `tensors\` subdirectory)

The measured FP4 checkpoint has **21 shards inside the `tensors\` subdirectory**, referenced by relative paths from the
`weight_map` of `model.safetensors.index.json` (`tensors/model-00001-of-00021.safetensors`):

```
Qwen3.8-Flash-Next-FP4-Local\        ≈ 96 GiB
├─ config.json                       <- required; the engine reads architecture and quant layout here
├─ model.safetensors.index.json      <- required; weight_map points at shards under tensors\
├─ tensors\
│  ├─ model-00001-of-00021.safetensors
│  └─ ... (21 shards in total, metadata.total_size ≈ 102.1 GB)
├─ tokenizer.json / tokenizer_config.json / vocab.json / merges.txt
├─ generation_config.json
├─ preprocessor_config.json / video_preprocessor_config.json   ← vision
├─ chat_template.jinja
└─ configuration.json
```

Do not move the shards out of `tensors\` to the root — the paths in `index.json` are relative; moving them makes them unfindable.

### 7.4 Download

```powershell
hf download nvidia/Qwen3.8-Flash-Next-FP4-Local `
  --revision b9ce18a6887e18c089fdea8509a33e63429a3300 `
  --local-dir D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

(The `revision` is exactly the one pinned in the recipe's `config.sh`.)

### 7.5 30-second check

```powershell
python - <<'PY'
import json
p = r'D:\llm\model\Qwen3.8-Flash-Next-FP4-Local\config.json'
c = json.load(open(p))
q = c.get('quantization_config') or {}
print('arch:', c.get('architectures'), '| type:', c.get('model_type'))
print('method:', q.get('quant_method'), '| algo:', q.get('quant_algo'))
print('OK' if q.get('quant_method') == 'modelopt' and q.get('quant_algo') == 'MIXED_PRECISION' else 'NOT LOADABLE')
PY
```

Or pure PowerShell:

```powershell
$c = Get-Content "D:\llm\model\Qwen3.8-Flash-Next-FP4-Local\config.json" -Raw | ConvertFrom-Json
$c.architectures; $c.quantization_config.quant_method; $c.quantization_config.quant_algo
```

### 7.6 Recipe side and startup

The recipe side has one job only: drop in the four `.ps1` files (the recipe's `.sh`, `patches/`, and Dockerfile are not changed by a single line).

```powershell
powershell -ExecutionPolicy Bypass -File scripts\recipe\1-install-ps1.ps1
# self-check at the end: git status should show only ?? additions, never M modifications
# also writes MODEL_PATH into the recipe's .env (-NoEnv skips it, -Force overwrites an existing value)
```

Then start the server (paths come from the config; `<recipe>` is the one under the root defined in `migration.config.ps1`):

```powershell
cd <recipe>
.\start.ps1                 # first load ~81 GiB: ~71 s fully patched, ~257 s on the native path
.\start.ps1 restart         # restart
.\stop.ps1                  # stop
$env:DRY_RUN='1'; .\start.ps1   # prints the serve command line only, starts nothing (troubleshooting staple)
```

---

## 8. Model-Load Pipeline (257 s → 71 s)

v1.1.4's native load path does **not** use a pre-quantized cache; every layer assembles its NVFP4 experts from the raw
safetensors on the fly. On Linux the recipe's patch 0014 (prompt-expert-tile) masked this path's cost, but bare on
Windows ARM64 it takes **257 s**. `0003-load-pipeline.patch` cuts it to **71 s** (the engine self-reports
`loaded in 67.6s`) **without touching any `.cu`, kernel parameter, launch config, or precision path** — all changes are host-side.

### 8.1 Symptoms and root cause (the three suspects ruled out first)

| Suspect | Measured | Conclusion |
|---|---|---|
| Slow disk | sequential read 5.0 GB/s | not IO |
| Insufficient copy bandwidth | single HtoD 20+ GB/s | not DMA |
| CUDA kernel problem | GPU utilization is high during load, but it is all copies | not the kernels |

The real cause is `loadShape` in `zig/src/families/flashnext/cuda_modelopt_experts.zig`; the old implementation was

```zig
for (0..512) |i| {                          // 512 experts a layer
    var gate  = try readPart(a, store, "…gate_proj", ...);   // small copy 1
    var value = try readPart(a, store, "…up_proj",   ...);   // small copy 2
    var output= try readPart(a, store, "…down_proj", ...);   // small copy 3
    ex.packGateUp(...); ex.packOne(...);                     // single-threaded repacking
    try up.upload(); try down.upload();                      // stream.synchronize() after every upload
}
```

Two amplifiers turn 1536 small copies into 257 s:

1. **One layer's experts are scattered across 14 shards**, while the `Store` mapping ring cache in `cuda_prompt_wt.zig` has only
   **2 slots** → every layer repeatedly closes/reopens shards and re-parses headers (50.6 MB of headers model-wide, up to 9.3 MB in a
   single file). On Windows `mmap` goes through `VirtualAlloc` + explicit reads, so re-parsing has no page cache to rescue it.
2. `slice()` in `zig/src/core/nvfp4_slice.zig` does `@memcpy` **row by row**; a layer has thousands of rows, taking about 1/3 of read time.

### 8.2 The four changes

| # | File | Change | Individual contribution |
|---|---|---|---|
| 1 | `cuda_modelopt_experts.zig` | expert assembly becomes **grouped parallel**: 512 experts split into `32 groups × 16`, N host threads (default CPU count, capped at 32) claim work with `std.atomic.Value(usize)`, each thread writing only its own stage slot (lock-free, no false sharing) | the workhorse; per-layer time 5.0 s → 1.1 s |
| 2 | same as above | **pinned double buffering + CUDA async copies**: `cuda.HostBuffer` (`cuMemHostAlloc`) gets page-locked memory, `cuMemcpyHtoDAsync_v2` posts to a non-blocking copy stream; two stage slots alternate, `cuda.Event` back-pressure guarantees "the DMA has finished reading before overwrite" | copy waits from 3 full syncs/layer → 18 ms/layer |
| 3 | `cuda_prompt_wt.zig` | mapping cache **2 → 48 slots** (`cached_shards`); borrow bookkeeping gains a `std.Io.Mutex` (**record pointers inside the lock only, never do IO inside the lock**); when slots fill, returned mappings are swept into the cache instead of being closed; a new `dropShards()` frees everything after all 48 layers are read (reclaims ~0.6 GB of header memory) | eliminates 14 reopens per layer |
| 4 | `core/nvfp4_slice.zig` | full-width tensors (`from == 0 and to == k`) take a **single whole-block** `@memcpy`; the row-by-row branch is kept for slices | read time −1/3 |

Key points for reading the four files:

- **Pinned memory is a hard requirement**: calling `cuMemcpyHtoDAsync` with ordinary pageable memory makes the driver fall back to a
  synchronous copy through a temporary pinned buffer, making the double buffering pointless.
- **Event back-pressure cannot be dropped**: parallelism without back-pressure leaves 20 threads collectively stuck on the same
  `sync`, cutting the gain significantly; conversely, never syncing overwrites stages being read by the DMA.
- **Alignment**: `packGateUp` wants `[]u32`, so stage slices must first `@alignCast` to `[]align(4) u8` and then
  `bytesAsSlice(u32, ...)`, or you get a compile-time `expected type '[]u32', found '[]align(1) u32'`.
- **Lock scope**: `Store`'s mutex guards only the `held/released` bookkeeping (a few dozen bytes); IO happens outside the lock; otherwise parallelism collapses to zero.

### 8.3 Switches and metrics

| Environment variable | Default | Effect |
|---|---|---|
| `TENSORFOLD_LOAD_THREADS` | CPU cores (≤32) | number of parallel-assembly threads |
| `TENSORFOLD_LOAD_GROUP` | 16 | experts per group = double-buffering granularity; larger saves syncs, eats host memory |
| `TENSORFOLD_LOAD_SERIAL` | 0 | set to 1 to fall back to the per-expert path (the control when you suspect the parallel path) |
| `TENSORFOLD_LOAD_STATS` | 0 | set to 1 to print phase timings |

> **The `TENSORFOLD_` prefix is mandatory**: the recipe's `scripts\config.ps1` reads `.env` line by line and exports **every** key,
> so only `TENSORFOLD_LOAD_STATS=1` reaches the engine process. Writing `TF_LOAD_STATS` fails silently (I've been bitten).

After writing them into the recipe root's `.env`, `start.ps1`'s load phase prints:

```
info: flashnext: 512 experts in 32 groups of 16 on 20 threads: pack 698 ms, stage wait 18 ms, 1350 MiB
info: flashnext: rank 1/1 loaded layer 48/48
info: flashnext: layer 47 took 1170 ms
```

How to read it (measured on this machine, 48 layers):

| Metric | Measured | Meaning |
|---|---|---|
| `layer N took` | mean 1116 ms, sum 53.6 s | 79% of the 71 s |
| `pack` | mean 698 ms, sum 34.2 s | **the current bottleneck**: 3 projections per expert ≈ 27 CPU-ms |
| `stage wait` | sum 0.87 s | copies fully hidden, **no headroom left in the double buffering** |
| residual | ~14 s | embedding / lm_head / FP8 n-gram tables / attention shared weights |

> **Phase logs go to stderr**: `build\logs\serve-*.err.log` (the `info:` lines), not `.out.log`. Use
> `grep -a` or `Get-Content -Encoding Default`; the logs contain NUL bytes.

### 8.4 Two PowerShell 5.1 bugs on the recipe side (without fixes you cannot measure the seconds)

Once the load itself got fast, `start.ps1` still reported `the server exited before it was ready` — because the health
probe in `scripts\config.ps1` throws under PS 5.1, the `while` loop never sees `$ready`, and it times out and declares itself dead. Two real bugs:

| Symptom | Root cause | Fix |
|---|---|---|
| `无法发送具有此谓词类型的内容正文` | in `param([string]$Body = $null)` the `$null` becomes an empty string → `$null -ne $Body` is always true → an empty body goes through GET; and **PS 5.1's `Invoke-RestMethod` defaults to the POST verb** (only 6.0+ defaults to GET) | use `[string]::IsNullOrEmpty($Body)`, and **pass `-Method` explicitly in every branch** |
| `找不到与参数名称"NoProxy"匹配的参数` | `-NoProxy` is a switch that only exists in PowerShell 6.0+ | the 5.1 branch uses `[System.Net.WebRequest]::DefaultWebProxy = $null` wrapped in `try/finally` |

After the fix, `start.ps1` prints `server answered after 71s` (this number is **measured**, not an estimate).

Another easy misjudgment: `config.ps1` maps `ApiUrl` to `127.0.0.1`, so `BIND_HOST=0.0.0.0` is fine;
**do not use `0.0.0.0` directly as an HTTP target**.

### 8.5 Boundaries and next steps

- This machine's 20 cores (GB10) are **already fully used**; adding threads leaves no room; `pack`'s 34.2 s is pure host compute, not movable.
- Only one road remains: **skip repacking** — write a one-off tool to preprocess the checkpoint into the engine's native expert
  blobs (~10 minutes first time + ~80 GB disk); afterwards loading degrades to pure read + DMA, estimated 20 s. That is a new
  feature (new artifacts, new cache-invalidation logic); do not slip it into the patch on the side.
- To verify "fast but not wrong": run one deterministic QA pass (`capital of France` → `Paris`); it is more telling than `/health` alone.
- Regression guard: `loadShape` only goes parallel when `@TypeOf(store) == *wt.Store`; the in-memory mock used in tests still
  goes serial; a runtime allocation failure prints a warn and automatically falls back to the per-expert path.

---

## 9. `.ps1` Writing Notes (all from pitfalls hit in this migration)

1. **`vcvarsall` cannot be used via PowerShell `call`**. A batch file only changes the child process's environment. You must generate
   a `.bat` and run it with `cmd /c`, or stuff the whole command line into `cmd /c "..."`. This is the sole cause of "all fatbins blown up".
2. **No `&&`, `||`, ternary `?:`, or `??`** (Windows PowerShell 5.1). Use `; if ($?) { }` to step through.
3. **`$Host` is an automatic variable** and cannot be used as a custom one. The recipe's `$BindHost` exists for this reason.
4. **`2>&1` on native programs pollutes `$?`**: even with exit code 0, `$?` may become false. Use `$LASTEXITCODE` to
   judge exit codes.
5. **`"$var:"` is parsed as a drive reference** (`$cand:` → "invalid variable reference" error). Use `${var}:`.
6. **Native-program stderr shows up as `NativeCommandError` in PowerShell**. `tf-cuda-test info` and
   `nvcc --version` both do; this is a display-layer false alarm — read the output content, not the red text.
7. **Put `#Requires -Version 5.1` on the first line** and `Set-Location $PSScriptRoot` at the top (when double-clicked,
   the working directory is `C:\Windows\System32`).
8. **Do not use `$env:PROCESSOR_ARCHITECTURE` to detect architecture** (it reports x86 under WOW64). Also **do not rely solely on**
   `RuntimeInformation::OSArchitecture` — when the shell itself runs under x64 emulation it reports the **process** view `X64`;
   `Win32_OperatingSystem.OSArchitecture` is a localized string ("ARM 64 位处理器"), so `-match 'ARM64'` misses.
   The only reliable thing is the number: `(Get-CimInstance Win32_Processor).Architecture`, **12 = ARM64**, 9 = x64, 0 = x86
   (`1-preflight.ps1` decides exactly this way, with .NET only as a fallback).
9. **Paths with spaces**: `& "C:\Program Files\...\x.exe"` or `Start-Process -FilePath`; quote them when building them into a `.bat`.
10. **Code pages**: put `chcp 65001 >nul` at the top of `.bat` files, and write `.bat` as BOM-less UTF-8; nvcc/logs are GBK,
    read with `Get-Content -Encoding Default`. The C4819 warning means "the file contains characters that cannot be represented in the current code page" — **not an error**.
11. **Process environment persists across runs**: values set with `[Environment]::SetEnvironmentVariable(..., 'Process')` stay
    live for this shell's whole lifetime. So scripts must validate against "the value written last time" instead of assuming a clean slate.
12. **`SetEnvironmentVariable($name, $null)` does not necessarily delete the variable**: under .NET Framework it may leave an
    empty string behind. If the child process treats "present but empty" as an illegal value (TensorFold's
    `TENSORFOLD_CUDA_KERNELS` does), it fails silently. **When you can set a value explicitly, do not delete the variable** (here, set `native`).
13. **Start background services with `Start-Process -WindowStyle Hidden -RedirectStandardOutput/Err`**, persist the PID to
    `build\state`, and `stop.ps1` kills based on it — do not use `Start-Job` (it dies with the shell).
14. **`$LASTEXITCODE` is meaningless after `Start-Process`**; use `-PassThru` to get the process object and query it.
15. **`$ErrorActionPreference='Stop'` + native-program stderr = the script aborts outright**. PowerShell 5.1 turns ordinary
    native-program stderr output (git's progress, `tf-cuda-test info`'s result line, some nvcc output) into
    `NativeCommandError`, which becomes a terminating error under `Stop`. Every script in this skill uses `'Continue'` and
    relies on `$LASTEXITCODE` plus text checks — **I hit this pit myself** (the smoke script aborted here on its very first run).
16. **The `$null` in `param([string]$Body = $null)` becomes an empty string**, so `$null -ne $Body` is **always true** and
    the health probe sends requests with an empty body. Test emptiness with `[string]::IsNullOrEmpty($Body)`.
17. **PS 5.1's `Invoke-RestMethod` defaults to the POST verb** (changed to GET only in 6.0+). An empty-body POST throws
    `无法发送具有此谓词类型的内容正文`, so **pass `-Method` explicitly in every branch**. `-NoProxy` is also a 6.0+ parameter;
    on 5.1 use `[System.Net.WebRequest]::DefaultWebProxy = $null` wrapped in `try/finally`.
18. **Different casings of the same environment variable collide**: when both `HTTPS_PROXY` and `https_proxy` exist in the process,
    `Get-ChildItem Env:` throws "An item with the same key has already been added", taking down `Start-Process` with it. Before
    starting, clear both names with `[Environment]::SetEnvironmentVariable($n, $null, 'Process')`.
19. **Do not use `2>&1` to read native-program output**: it turns stderr into ErrorRecords, and the formatter **wraps** lines at
    the host width and appends `NativeCommandError` decoration — `tf-cuda-test info`'s 130-character result line was cut into two
    pieces and the regex matched only the first half. To get raw text, use .NET `Process` and read both streams (see `Invoke-MigNative` in this repo's `migration.config.ps1`).
20. **`$Matches` is overwritten by the next `-match`**: after `if ($arch -notmatch 'ARM64')`, a later `$Matches[3]` yields an
    empty string (I printed the python version as `3.13.` because of this). Store the groups in variables immediately after matching.
21. **The `*>` redirection writes UTF-16**: `& powershell -File x.ps1 *> out.txt` yields BOM'd UTF-16; reading it as UTF-8 shows
    a NUL interleaved after every byte and mangled line endings. Either read with `-Encoding Unicode`, or don't treat it as a "clean log".
22. **Never write paths into scripts**: a real problem hit during one migration was "docs say `D:\llm\latest`, code hardcodes it
    too" — everything collapses on another machine. This repo centralizes paths in `migration.config.ps1` (probe + menu +
    `.migration.local.json`); scripts only consume variables; the only absolute paths allowed to appear are **probe candidates**,
    and there is always a "user-overridable" exit.
23. **`$MyInvocation.InvocationName -ne '.'`** is the test for "run directly rather than dot-sourced": the config file uses it
    to show the menu when run standalone and stay silent when imported.
24. **`nvidia-smi --query-gpu` returns more than one row on GB10**: the NPU is also listed as a device, with `memory.total` = `[N/A]`.
    A plain `Out-String` stitches `NVIDIA NPU, [N/A]` into the reported GPU row; filter out `[N/A]` rows or take only the first row.
25. **The blank line from `Write-Host ''` can vanish in some hosts/pipeline captures**, joining two adjacent lines
    (`...GiBPREFLIGHT OK:`). To assert on output, split with `-split "`r?`n"` and inspect lines; don't write regexes against joined-together strings.
26. **Every `TF_FLASHNEXT_*` exported by the recipe's `scripts/config.sh` must be ported into `config.ps1` one by one** — this is
    the easiest thing to miss and the most expensive one. These variables are the recipe's **performance switches**, and the engine
    treats "unset" as **off** or a **factory rule**:
    `GATHER_EARLY` / `SAMPLE_CAND` / `SHARED_SIDE` / `GDN_LANES` / `KEEP_LATE` / `PROMPT_HC2` /
    `PROMPT_GEMM2` unset = off; `HEAD_PIECE` unset = 256 (the recipe uses 1536); `CONFIDENCE` unset = 0.6
    (the recipe uses `-0.4`). The symptom is "**every patch correct, the binary correct too, but you are not running the same
    engine**". So after porting the engine scripts, diff the two sides: the set difference between
    `grep -oE "^export (TF_FLASHNEXT|TENSORFOLD)_[A-Z0-9_]+" scripts/config.sh | sort` and
    `grep -oE "Set-EnvVar '[A-Z0-9_]+'" scripts/config.ps1 | sort` must contain only **intentional** entries.
    This skill's `config.ps1` is a **value-for-value mirror** of `config.sh`: the same export list, the same order, the same values,
    and anything `config.sh` does not export stays unexported — a port stays faithful to the recipe first; performance debates come later.
    **Do not read the recipe README's percentages as expectations on Windows**: that +14% / 15–25% are numbers from its Linux
    image; every performance number in this port comes from sparkDash measurements (the README and `docs/bench/`).
    Incidentally: `TF_FLASHNEXT_DEPTH` is **not** an engine variable (the engine only has `TF_FLASHNEXT_DEPTH_LOG`);
    what actually controls draft length is `TF_FLASHNEXT_DRAFTS` — a wrong variable name raises no error at all, it just silently does nothing.

27. **An `exit` inside a dot-sourced file does not terminate the caller**: it only ends the sourced file, then returns to the
    caller's next line. `config.ps1` originally had `default { …; exit 1 }`, so a wrong `CHECKPOINT` let `start.ps1` keep running
    with only `$ModelPath` left empty. Rejection belongs in the **caller** (the validate block of `start.ps1` uses `Die`, which
    actually `exit`s the whole script); or keep only markers in the config and let the one script that needs weights raise the
    error — `stop.ps1` dot-sources the same file, and it should not refuse to stop the service because of an invalid checkpoint.

---

## 10. Troubleshooting (indexed by symptom)

| Symptom | Root cause | Action |
|---|---|---|
| Preflight reports `zig not found at` / `no bin\nvcc.exe` / `vcvarsall.bat not found` | the probe missed it (not on PATH, installed in an unusual location) | run `scripts\migration.config.ps1` to open the menu and edit that row by number; or pass `-Zig` / `-Cuda` / `-Vcvars` directly |
| The `model` row in the menu is a grayed-out `not set` | weights not downloaded yet, or not under `<parent of root>\model` | does not block the build; after downloading the weights rerun the menu (edit row 6), or use `-ModelPath` |
| Changed a path but the next script still runs with the old one | a `.migration.local.json` is remembering the old value | rerun `scripts\migration.config.ps1` (or `-Reset`) to fix it; deleting that file is equivalent to "re-probe" |
| `3-apply-patches.ps1` reports a bad `patches: ...` path / `does not apply` | the directory is not the engine clone, or HEAD is not `eab85828` | the script hard-validates HEAD first; use `-TensorFold <the correct engine directory>`; the patch directory is derived from the script's own location (`..\..\patches`) |
| `torch install failed (pip exit …)` | cannot reach `pypi.nvidia.com`, or some nightly was pulled | check network/proxy; skip with `-SkipTorch`; or manually `pip install torch==<known-good version>` in the venv |
| `torch.cuda.is_available() is False` | a CPU wheel got installed, or driver/torch versions mismatch | reinstall torch (`-Recreate` to rebuild the venv), confirm `--extra-index-url` points at `nvtorch_oot_nightly` |
| `torch does not import in the venv` | the venv's torch mismatches the Python version/architecture | rebuild with `-Recreate`; confirm Python is aarch64 (`Test-MigPython` blocks x64) |
| `... does not look like the recipe clone (no scripts\config.ps1)` | `-Recipe` points somewhere wrong, or the recipe is not cloned yet | run `2-clone.ps1` first, or point root correctly via menu row 1 |
| `recipe\1-install-ps1.ps1` reports `[WARN] ... exists and differs; kept it` | the recipe has your hand-edited file of the same name | review the difference then overwrite with `-Force` (the repo version is authoritative) |
| Every `.cu` reports `error: process exited with code 1`, nothing else | not inside the `vcvarsall arm64` environment | use `5-build.ps1` (internally `cmd /c` + vcvarsall) |
| `no instance of function template ... matches the specified type` | explicit instantiations missing `__restrict__` | apply patch `0002` (section 4.3 #1–3) |
| `type 'void' does not support struct initialization syntax` | `std.posix.MAP` is `void` on Windows | apply `0002` (#4) |
| `parameter of type 'void' not allowed ... aarch64_aapcs_win` | `clock_gettime` / `CLOCK` are invalid on Windows | apply `0002` (#5) |
| `argument --kv-dtype: invalid choice: 'fp8'` | v1.1.4 renamed the flag to `--kv-cache` | `start.ps1` uses `--kv-cache` (this skill's recipe version already includes the fix) |
| `... with ...\build\kernels\sm121 glue kernels (Fp8KvUnsupported)` | an AOT kernel set left over from an **old engine** | rename that directory; `start.ps1` ignores kernel sets whose mtime predates the exe |
| `TENSORFOLD_CUDA_KERNELS= holds no aot.json` | the variable is present but empty | set it to `native` (this skill's `start.ps1` already auto-corrects) |
| `config.json's quantization_config.quant_method differs ...` / `UnsupportedCheckpoint` | using a GPTQ (AutoRound INT4) checkpoint | not supported by this repo: only `nvidia/Qwen3.8-Flash-Next-FP4-Local` (section 7) |
| `[start.ps1] ERROR: CHECKPOINT=<x> is not supported` | `CHECKPOINT` is not `nvfp4` (switched to another quantized version) | by design: this repo has exactly one supported weight set (section 7) |
| Build succeeds but `start.ps1` says `tensorfold-native.exe not found` | layout wrong / the directory is not named `TensorFold` | arrange it per section 0, or set `NATIVE_BIN` |
| `vision is on but the venv python is missing` | no venv built | section 3, or `VISION=0` |
| The logs are all mojibake | GBK/UTF-16 encoding | `Get-Content -Encoding Default`, `iconv -f gbk` |
| `the server exited before it was ready` and the log stops at loading | model incomplete / unsupported format / out of memory | check `RESULT`/`UnsupportedCheckpoint` first, then `build\logs\serve-*.err.log` |
| Loading takes over 4 minutes | `0003` not applied (running the native per-expert path) | the `3-apply-patches.ps1` output should list `0003-load-pipeline.patch`; see section 8 |
| `start.ps1` polls until timeout, but a manual `/health` request works | the recipe `config.ps1` health probe throws under PS 5.1 (empty body + default POST; `-NoProxy` is a 6.0+ parameter) | fix `Invoke-LocalRest` per section 8.4 |
| Set `TENSORFOLD_LOAD_STATS=1` but no phase timings | the variable name never reached the engine (must be `TENSORFOLD_` prefixed and in `.env`), or you are reading the wrong log | the phase lines are in `serve-*.err.log`, starting with `info:` |
| `only 2 GiB host memory left while loading (MEM_FLOOR_GIB 4)` | normal staging-buffer usage, common on unified-memory machines | warning only, never blocks; to press it down, lower `TENSORFOLD_LOAD_GROUP` |
| `--parallel 5 needs 23.74 GiB … leaves 22.81 GiB` | 5 streams of fp8 KV exceed memory admission (reported only after the load completes) | pin `PARALLEL=4` in `.env`, or lower `CONTEXT` |
| Every patch applied, the binary built from this very tree, but decode is ~20% slower than the page claims | first check whether `config.ps1` fully mirrors `config.sh` (empty set difference) — any missing `TF_FLASHNEXT_*` puts the engine on a fallback path | see section 9 #26; trust the README's sparkDash measurements for expected numbers, not the Linux image's percentages |
| Preflight measured 3× apart on the same machine (714 vs 1,900 tok/s) | another load competing for GPU/memory bandwidth, or a previous job not fully exited | first confirm `/health` shows `live.connections` at 0, then run; even within one job there is spread across its 3 samples |

---

## 11. Delivery Acceptance Checklist

- [ ] all six rows of the `scripts\migration.config.ps1` menu read `[ OK ]` (or the known `model not set`), and `.migration.local.json` has been generated
- [ ] `1-preflight.ps1` all green (0 FAIL)
- [ ] `git -C TensorFold rev-parse HEAD` == `eab8582819688325e371907e4706e1c602b8a273`
- [ ] `git -C TensorFold status --porcelain --untracked-files=all` shows **78** entries (59 modified + 19 added), no conflict markers (`git diff | Select-String '<<<<<<<'` empty)
- [ ] the three sha256 values printed by `3-apply-patches.ps1` match section 4.1
- [ ] `5-build.ps1` exits 0, both artifacts exist and `file` reports `PE32+ ARM64`
- [ ] `6-smoke.ps1` shows three `[ OK ]`, and `kernels embedded true`
- [ ] `recipe\1-install-ps1.ps1` reports `the recipe itself is unmodified`, and `git status` inside the recipe shows only `??`, never ` M`
- [ ] the venv lives at `<recipe>\venv` and `torch.cuda.is_available()` is True (only needed for `--vision`)
- [ ] the model's `config.json` has `quant_method=modelopt`, `quant_algo=MIXED_PRECISION`
- [ ] the command line printed by `DRY_RUN=1 .\start.ps1` contains `--kv-cache fp8` (not `--kv-dtype`)
- [ ] no stale entries in `.env` pointing at old kernel sets / old models
- [ ] `TENSORFOLD_LOAD_STATS=1` in `.env` (optionally `PARALLEL=4`), and `.\start.ps1` reports **`server answered after ~71s`** (≤120 s to pass)
- [ ] `grep -a "layer .* took" build\logs\serve-*.err.log` yields 48 lines, and the `stage wait` sum is < 2 s (proof the double buffering works)
- [ ] after loading, run one deterministic QA pass (e.g. `capital of France` → `Paris`) to confirm the parallel assembly did not misplace weights

For deeper rationale see `references/build-notes.md`; for this machine's measured evidence see `references/verification.md`.
