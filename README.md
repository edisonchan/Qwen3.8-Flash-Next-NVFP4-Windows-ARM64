# Qwen3.8-Flash-Next NVFP4 on Windows 11 ARM64

An **unofficial** port of [MiaAI-Lab's recipe](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)
to Windows 11 on ARM64 (GB10, `sm_121`). Same NVFP4 checkpoint, same [TensorFold](https://github.com/ashhart/TensorFold)
engine, **no Docker**: a native `tensorfold-native.exe` built with MSVC for ARM64, PowerShell scripts that replace the
recipe's shell scripts, and a fix that takes model loading from **257 s to 71 s**.

[中文说明](README.zh-CN.md)

```
upstream recipe (MiaAI-Lab, MIT)          this repository
  start.sh / stop.sh / config.sh   ──▶    recipe/*.ps1        (PowerShell counterparts)
  patches/0001..0017               ──▶    patches/0001       (merged into one diff)
  (Docker, amd64 images)           ──▶    scripts/*.ps1      (native MSVC build instead)
                                          patches/0002       (5 platform fixes)
                                          patches/0003       (load pipeline, 257 s → 71 s)
```

## What is in here

| Path | What it is |
|---|---|
| `patches/0001-recipe-0001-0017-on-v1.1.4.patch` | MiaAI-Lab's 17 recipe patches, merged into one diff against TensorFold v1.1.4 (`eab85828`), 74 files |
| `patches/0002-windows-arm64-port.patch` | 5 MSVC/Windows compatibility fixes. In the three `.cu` files the only change is `__restrict__` on explicit instantiation argument lists; no kernel arithmetic is touched |
| `patches/0003-load-pipeline.patch` | 4 host-side loader files: staged parallel expert packing, pinned double buffering, a wider shard-mapping cache, whole-row copies |
| `scripts/1-preflight.ps1` … `6-smoke.ps1`, `Invoke-Migration.ps1` | The migration itself, one step per script |
| `recipe/start.ps1`, `stop.ps1`, `config.ps1`, `banner.ps1` | The recipe's shell scripts as PowerShell, including two PowerShell 5.1 bug fixes (`$null` becomes `''` in a `[string]` default; 5.1's `Invoke-RestMethod` defaults to POST) |
| `SKILL.md`, `references/` | The same procedure in agent-facing form (WorkBuddy/Claude skill layout), plus build notes and the verification record |
| `docs/patching-and-port.md` | Long form: how each patch was cut, what broke, and the `.sh` → `.ps1` decisions one by one |
| `NOTICE`, `LICENSES/`, `CREDITS.md` | License chain. Read `NOTICE` before redistributing anything |

## Quick start

```powershell
git clone https://github.com/<you>/Qwen3.8-Flash-Next-NVFP4-Windows-ARM64
cd Qwen3.8-Flash-Next-NVFP4-Windows-ARM64

# preflight -> clone both repos -> 3 patches -> vision venv -> build -> smoke
.\scripts\Invoke-Migration.ps1 -Root D:\llm\latest
```

Step by step, if you want to see each stage:

```powershell
.\scripts\1-preflight.ps1
.\scripts\2-clone.ps1
.\scripts\3-apply-patches.ps1 -TensorFold D:\llm\latest\TensorFold   # expect 78 entries, 3 patches, 2 spot-checks
.\scripts\4-venv.ps1
.\scripts\5-build.ps1  -TensorFold D:\llm\latest\TensorFold          # BUILD_EXIT=0, ~5 min
.\scripts\6-smoke.ps1  -TensorFold D:\llm\latest\TensorFold          # version 1.1.4 / nvidia-sm121 / OK
```

Serving. The recipe clone carries the `.sh` files; copy the PowerShell ones in beside them:

```powershell
$Q = 'D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'
Copy-Item .\recipe\start.ps1, .\recipe\stop.ps1            $Q
Copy-Item .\recipe\config.ps1, .\recipe\banner.ps1  "$Q\scripts"

# 30.5 GB of host memory on this class of machine: 5 streams need 23.74 GiB of KV and the
# admission budget is 22.81 GiB, so 4 is what fits. Failed only after all 48 layers loaded.
Add-Content "$Q\.env" @('TENSORFOLD_LOAD_STATS=1', 'PARALLEL=4')

& "$Q\start.ps1"    # [start.ps1] server answered after 71s
& "$Q\stop.ps1"
```

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

Windows 11 ARM64 · GB10 (128 GB unified, 20 cores) · CUDA 13.4 · Zig 0.17.0 (aarch64-windows) ·
MSVC 2022 Build Tools with the ARM64 host · PowerShell 5.1 · Python 3.13 arm64 for `--vision` only.

## License

MIT for this repository's own work, Apache-2.0 (plus pre-0.6.0 MIT) for the TensorFold code the patches
modify, MIT for the recipe patches this ports. `NOTICE` spells out which file falls under which, and
`LICENSES/` carries every full text. No weights, no binaries, nothing to relicense by accident.

Not affiliated with, sponsored by, or endorsed by MiaAI-Lab, the TensorFold authors, NVIDIA or the Qwen team.
