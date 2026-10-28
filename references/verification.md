# Verification Record (2026-10-28, local RTX Spark N1X)

[English](verification.md)

This file records the evidence that "these patches really can reproduce a buildable tree from scratch," for future re-auditing.

## 1. Baseline

| Item | Value |
|---|---|
| Host | Windows 11 ARM64 (build 10.0.28000), RTX Spark N1X (48 SMs, sm_121), driver 621.01 / CUDA API 13050 |
| zig | 0.17.0 (`D:\llm\zig-aarch64-windows-0.17.0`) |
| CUDA | 13.4 (`...\CUDA\v13.4`, `V13.4.92`) |
| MSVC | VS2022 BuildTools, cl `14.44.35207`, `Hostarm64\arm64\cl.exe` |
| Engine | `ashhart/TensorFold` @ `eab8582819688325e371907e4706e1c602b8a273` (tag v1.1.4) |
| Recipe | `MiaAI-Lab/Qwen3.8-...-TensorFold` @ `fd3f43e11238553685ebb68b6d8ab2b112818e3c` (pinned commit, not the main cursor) |

> The drive-letter paths for zig / CUDA / MSVC above are **the actual locations measured on this machine at the time**, recorded only for reproduction; the scripts themselves do not depend on them —
> each script dot-sources `scripts\migration.config.ps1` and takes paths from `.migration.local.json` (see SKILL §0.1).

## 2. Patch Consistency (Byte-for-Byte)

Method: create a fresh clean clone → check out `eab85828` → apply `0001` + `0002` → compare sha256 file by file against the production working tree at the time.

```
clean=0
0001 check OK / applied
0002 check OK / applied
resulting change count = 75
compared 75 files; mismatches: 0
```

That is: **the patch product is byte-for-byte identical to the production tree**; there is no "manually edited but never captured in a patch" omission.

`0003` (load pipeline) was cut on a temporary worktree with "0001+0002 already applied", cut as follows:

```
worktree add --detach <tmp> eab85828
git apply 0001; git apply 0002
git commit -a                       # pin the baseline
cp <production-tree>\{nvfp4_slice.zig, cuda_modelopt_experts.zig, cuda_prompt_wt.zig, cuda_prompt.zig} <tmp>
git diff > 0003-load-pipeline.patch # 4 files / 273+ / 35-
```

On the same worktree reset back to bare `eab85828`, apply 0001 → 0002 → 0003 in order via `3-apply-patches.ps1`:

```
0001 sha256 c780c961…  applied
0002 sha256 9e2728ad…  applied
0003 sha256 911b7d75…  applied
tree now: 59 files changed, 3783 insertions(+), 193 deletions(-)   # 78 entries incl. 19 new
port patch spot-check: the explicit instantiations carry __restrict__
load patch spot-check: staged expert fill in place, shard cache widened
```

All four files match the production tree's sha256 exactly; `git status --untracked-files=all` counts 78 entries.

## 3. Build from Scratch

On a separate **brand-new clone** (`scratch`), build directly after applying the two patches (at the time there were only `0001`+`0002`; the post-`0003` load measurement is in section 6):

```
[vcvarsall.bat] Environment initialized for: 'arm64'
BUILD_EXIT=0
build\native\bin\tensorfold-native.exe   36,205,568 B   PE32+ ARM64
build\bin\tf-cuda-test.exe               78,627,840 B
elapsed 5 min 46 s
```

Smoke test:

```
usage: tensorfold-native --version | capabilities --json | models | info MODEL | ...
VERSION: 1.1.4
CHIP: nvidia-sm121
CUDA: driver CUDA 13050, device NVIDIA RTX Spark N1X (6144-core Blackwell RTX GPU), sm_121, 48 SMs, ...
```

## 4. Script Self-Tests

| Script | Result |
|---|---|
| `3-apply-patches.ps1` | Ran through on a third clean clone; the three sha256 values match the documentation; both spot-checks passed |
| `5-build.ps1` | Ran through on the third clone: `BUILD_EXIT=0`, 6.6 minutes, artifacts 34.5 MB / 75 MB |
| `6-smoke.ps1` | Three `[ OK ]` items |

### 4.1 After the Path Menu-ization + engine/recipe Split (2026-10-27 Re-test)

The scripts moved from `scripts\*.ps1` to `scripts\engine\`, `scripts\recipe\` was added, and paths are now supplied via a menu, so each item was re-verified:

| Script | Result |
|---|---|
| `migration.config.ps1` (menu) | All six probes hit this machine's actual locations; deliberately pointing zig at `C:\nope` reported a hard problem and required `y/N` confirmation; after declining it can be changed back; wrote out `.migration.local.json` with six keys |
| `engine\1-preflight.ps1` | `PREFLIGHT OK: 0 blocking problems`; python `3.13.16 ARM64`, zig `0.17.0`, nvcc `13.4`, cuBLASLt, MSVC arm64 `cl`, GPU `RTX Spark N1X`, `free space on D: 1,005.4 GiB` |
| `engine\3-apply-patches.ps1` | Re-applied the three patches on a temporary worktree: all sha256 values correct, `59 files changed, 3783 insertions(+), 193 deletions(-)`, `entries=78`, both spot-checks green; 4 files match the production tree's sha256; after `git worktree remove` the production tree still has 78 entries |
| `engine\6-smoke.ps1` | `SMOKE OK`; and after switching to .NET `Process` to read the raw streams, the entire line `device: ... 113136 MiB total, 105721 MiB free, kernels embedded true` is no longer swallowed by line wrapping |
| `recipe\1-install-ps1.ps1` | First install: all 4 `added`; after modifying `config.ps1`, re-running with `-Force` reported `1 replaced, 3 unchanged`; re-running again reported `0 added, 0 replaced, 4 unchanged`. All three runs showed the recipe's `git status` as `6 untracked entries, 0 modified` (conclusion line: `the recipe itself is unmodified: only new files were added`) |
| Nine `.ps1` files | All pass `[Parser]::ParseFile` syntax validation |

**Two items not run on real hardware** (to be covered on the real machine):

- `engine\4-venv.ps1` — pulls several GB of torch from the NVIDIA nightly index; only syntax validation and parameter validation were done;
  the logical order (torch first, then `tensorfold[vision]`) and the `$VenvDir` path in `recipe\config.ps1` have been aligned.
- The interactive menu of `Invoke-Migration.ps1` — only syntax validation was done; the menu itself (`Read-MigMenu`) was separately tested with scripted responses.

## 5. Patch Hashes

```
c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad  0001-recipe-0001-0017-on-v1.1.4.patch
9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40  0002-windows-arm64-port.patch
911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64  0003-load-pipeline.patch
```

## 6. Load Measurement (Effect of `0003`)

Same machine, same checkpoint (`Qwen3.8-Flash-Next-FP4-Local`, 48 layers, NVFP4 experts):

| Item | Native v1.1.4 | After `0003` |
|---|---|---|
| Reported by `start.ps1` | — | `server answered after 71s` |
| Engine self-report | — | `loaded in 67.6s` |
| End-to-end total | 257 s | 71 s |

Breakdown (48 layers, `TENSORFOLD_LOAD_STATS=1`, taken from `serve-*.err.log`):

```
layer N took   n=48  sum=53564 ms  mean=1116  median=1130  min=886  max=1275
pack           n=49  sum=34222 ms  mean= 698  median= 706  min=527  max= 793
stage wait     n=49  sum=  871 ms  mean=  17.8 max=   49
```

Conclusion: the copy is fully hidden (accounting for 1.3%); the bottleneck has shifted to host-side packing (all 20 cores saturated), and the remaining ~14 s is non-expert weights.

Correctness spot-check (whether parallel assembly misaligns anything):

```
GET /health          → status=ok, max_batch_size=4, memory.active≈76.2 GiB
POST /v1/chat/completions "Answer with one word: capital of France" → "Paris"
```

The service was shut down cleanly with `stop.ps1` (`Stopped; its GPU memory is free again`); port 8888 was released with no leftover processes.

## 7. Not Covered

- Real image/video inference with `--vision` was not verified (the venv probe passed, but no images were run).
- Two ranks / `--tp` were not verified (this machine has a single GPU).
- `PARALLEL=5` was not verified (at the 262144 context window, fp8 KV needs 23.74 GiB versus an admission budget of 22.81 GiB; the error only appears after loading completes).
- The "pre-packed expert blob" scheme was not attempted (skipping repacking, estimated 20 s; it would be a new feature).

