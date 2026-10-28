# Pinned versions

This repository only works against **one** combination of engine, recipe, checkpoint and toolchain.
Everything below is that combination, with the exact identifiers, where each one is enforced, and what
breaks when it moves. If you change a version, change it here first — then in the scripts listed in
"enforced in", then re-cut the patches.

Verified end to end on **2026-10-28** on the machine described in section 5.

## 1. The four pins

| # | Component | Exact value | Enforced in |
|---|---|---|---|
| 1 | **TensorFold engine** | tag `v1.1.4` = commit `eab8582819688325e371907e4706e1c602b8a273`<br>`build.zig.zon`: `.version = "1.1.4"`, `.minimum_zig_version = "0.17.0"` | `scripts/2-clone.ps1 -TfRef` (default), `scripts/3-apply-patches.ps1 -TfRef` (**hard fail if `HEAD` differs**), `scripts/Invoke-Migration.ps1 -TfRef` |
| 2 | **MiaAI-Lab recipe** | commit `fd3f43e11238553685ebb68b6d8ab2b112818e3c` (`main` as of 2026-10-28), carrying `patches/0001..0017` | `scripts/2-clone.ps1 -RecipeRef` (default), `scripts/Invoke-Migration.ps1 -RecipeRef` |
| 3 | **Model checkpoint** | `nvidia/Qwen3.8-Flash-Next-FP4-Local` @ `b9ce18a6887e18c089fdea8509a33e63429a3300`<br>96 GB, `quant_method: modelopt`, `quant_algo: MIXED_PRECISION` (NVFP4), `model_type: qwen4_exp`<br>**the only checkpoint this port supports** | `recipe/config.ps1` (one preset, `CHECKPOINT` other than `nvfp4` stops `start.ps1` before load) + the download command in `README.md`; the engine itself refuses anything else with `UnsupportedCheckpoint` |
| 4 | **Toolchain** | zig **0.17.0** aarch64-windows (`sha256 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8`)<br>CUDA toolkit **13.4** (`nvcc` release 13.4, `V13.4.92`)<br>MSVC **v143 / 14.44.35207**, `Hostarm64\arm64\cl.exe`<br>Windows 11 ARM64, build **10.0.28000** | `scripts/1-preflight.ps1` (**hard fail** on zig ≠ 0.17.0, warn on nvcc ≠ 13.4) |

Note that pins 1 and 2 are not independent: the recipe's own `scripts/config.sh` hard-codes
`TF_REF="${TF_REF:-eab8582819688325e371907e4706e1c602b8a273}"`, i.e. **the recipe pins the engine to the
same v1.1.4 release this repository pins**. If those two ever disagree, the recipe is the one that is wrong
for a Windows build — its Dockerfile would fetch a different engine than the patches expect.

## 2. The patch series (this repository's own version)

The three patches are the artifact whose bytes matter, so they carry hashes rather than a version number:

| Patch | Cut against | Files | `+`/`−` | sha256 |
|---|---|---|---|---|
| `0001-recipe-0001-0017-on-v1.1.4.patch` | `eab85828` bare release | 74 | +7081 / −152 | `c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad` |
| `0002-windows-arm64-port.patch` | after `0001` | 5 | +34 / −21 | `9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40` |
| `0003-load-pipeline.patch` | after `0001` + `0002` | 4 | +273 / −35 | `911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64` |

Order is fixed (`3-apply-patches.ps1` applies them by name). `0001` and `0003` both touch
`zig/src/families/flashnext/cuda_prompt.zig` and `cuda_prompt_wt.zig`, so `0003` cannot be applied to a
bare `eab85828` tree.

After all three, `git status --porcelain --untracked-files=all` on the engine tree reports **78 entries**
(59 modified + 19 new).

## 3. Why these pins and not newer

| Pin | If you move it | Why |
|---|---|---|
| Engine `v1.1.4` | `0001` stops applying. The recipe's 17 patches were generated against `db281878`; replayed on `eab85828` they need **11 three-way conflicts** resolved by hand, which is exactly why `0001` exists as a merged diff. On `main` (v1.1.5+) the same conflicts, plus new code the recipe never saw. | The recipe's `TF_REF` is `eab85828`; the patches and the Docker build describe the same tree. |
| Recipe `fd3f43e` | `0001` describes patches `0001..0017` **as they are at that commit**. A recipe `main` that adds patch `0018` or edits `0017` makes `0001` an incomplete or wrong description of "the recipe". | `0001` is a snapshot of that repo's `patches/` directory at that commit, nothing more. |
| Checkpoint `b9ce18a6…` | This is the only checkpoint the port supports, and `recipe/config.ps1` now carries a single preset for it. The engine accepts only `quant_method: modelopt` + `quant_algo: MIXED_PRECISION`; the AutoRound INT4 conversions (`Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound`, GPTQ) are a quantization path TensorFold removed, so they fail at load — after all 48 layers are read, which looks like a hang. A GPTQ re-upload of the same model fails the same way. | `resources`/`layers.*.mlp` in this export are NVFP4 with FP8 scales; the loader packs them as such. |
| zig `0.17.0` | Compile errors, not subtle ones: 0.17 removed `std.Thread.Mutex` (the shard cache uses `std.Io.Mutex`), and `Clock.Timestamp.toNanoseconds()` returns `i96` here but `u64` in older trees. | `build.zig.zon` pins `.minimum_zig_version = "0.17.0"`, and `0003` is written against 0.17's `std.Io`. |
| CUDA `13.4` | `sm_121` support and the `cublasLt64_13.dll` sonames come with the 13.x line. An older toolkit has no `sm_121` target; a newer one compiles but has not been tested here. Driver side: this machine reports CUDA driver API `13050` (13.5), which runs 13.4 binaries. | Only 13.4 was built and measured. |
| MSVC `v143` arm64 | `Hostarm64\arm64\cl.exe` is the compiler nvcc drives for an `aarch64-windows` target. An x64-only toolchain cannot produce the ARM64 host binary, and the `ARM64 build tools` component is not installed by default. | `0002` exists because MSVC is stricter than clang about `__restrict__` on explicit instantiations. |

## 4. How to check a checkout

```powershell
# 1) engine: tag, commit, and what the binary says about itself
git -C D:\llm\latest\TensorFold describe --tags        # v1.1.4
git -C D:\llm\latest\TensorFold rev-parse HEAD         # eab8582819688325e371907e4706e1c602b8a273
D:\llm\latest\TensorFold\build\native\bin\tensorfold-native.exe --version   # tensorfold-native 1.1.4
D:\llm\latest\TensorFold\build\native\bin\tensorfold-native.exe capabilities --json
#    -> "version":"1.1.4"  "chip":"nvidia-sm121"  "backends":["cuda"]
#       and families.qwen4_exp = ["mlx-q4g32","modelopt-mixed"]  = pin 3's format

# 2) recipe
git -C D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold rev-parse HEAD   # fd3f43e112385...
(Get-ChildItem D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\patches\*.patch).Count   # 17

# 3) toolchain
D:\llm\zig-aarch64-windows-0.17.0\zig.exe version      # 0.17.0
nvcc --version                                         # release 13.4, V13.4.92
# MSVC: the arm64 cross compiler's file version (cl needs vcvars, the file does not)
$cl = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC" -Directory |
      Sort-Object Name -Descending | Select-Object -First 1
$cl.Name                                                             # 14.44.35207
(Get-Item "$($cl.FullName)\bin\Hostarm64\arm64\cl.exe").VersionInfo.FileVersion   # 19.44.35229.0

# 4) patches: the bytes, not the names
Get-FileHash .\patches\*.patch -Algorithm SHA256 | Format-Table Hash, Path
#    -> C780C961… / 9E2728AD… / 911B7D75…   (Get-FileHash prints upper case; 12 hex chars are enough)
```

The `families` line in step 1 is the cheapest way to check pin 3 before loading anything: the checkpoint's
`model_type: qwen4_exp` plus `quant_algo: MIXED_PRECISION` has to map to a format this binary lists, and
`modelopt-mixed` is that format. If a future checkpoint names a family or format that is not in this JSON,
the load fails with `UnsupportedCheckpoint` after reading all 48 layers.

`D:\llm\latest` and the zig path are the defaults the scripts use; pass `-Root` / `-Zig` if yours differ.

## 5. What was actually run (provenance)

| Item | Value |
|---|---|
| Date | 2026-10-28 |
| OS | Windows 11 Pro for Workstations, build 10.0.28000, ARM64 |
| SoC / GPU | NVIDIA RTX Spark N1X (GB10): 20 cores, 6144-core Blackwell GPU, `sm_121`, 48 SMs |
| GPU memory | 98 304 MiB visible to CUDA (unified); ~30.5 GB host-visible |
| Driver | 621.01 (CUDA driver API 13050 = 13.5) |
| Host memory during load | 16 GiB available — the reason the staging buffer is 16 experts/group, not more |
| Build | `BUILD_EXIT=0`, ~4.7 min, `tensorfold-native.exe` 34.5 MB, `tf-cuda-test.exe` 75 MB |
| Smoke | `--version` 1.1.4 · `capabilities` `nvidia-sm121` · `tf-cuda-test info` `SMOKE OK`, kernels embedded |
| Model load | **67.6 s** engine-reported, **71 s** wall, 48 layers (`TENSORFOLD_LOAD_STATS=1`) |
| Serving | `max_batch_size=4`, `memory.active` ≈ 76.2 GiB, `PARALLEL=4` (5 streams need 23.74 GiB of KV against a 22.81 GiB budget) |
| Correctness | `capital of France` → `Paris` (deterministic question, checked after the 20-thread pack change) |

The verification record with the measurements behind these numbers is in `references/verification.md`;
the load-pipeline analysis is SKILL.md section 8 and `docs/patching-and-port.md` section 3.

## 6. Moving to a newer version

1. Pick the new engine commit and/or recipe commit.
2. Re-cut `0001`: new throwaway worktree at the new engine commit → apply the recipe's `patches/*.patch`
   with `git apply --3way` → resolve → `git diff > 0001-…patch`.
3. Re-check `0002`: if MSVC errors reappear on the new tree, extend it; if they are gone upstream, drop the
   corresponding hunk.
4. Re-apply `0003` on top of the new `0001`+`0002` tree; it usually applies unchanged, but the loader files
   moved between 1.1.4 and `main`.
5. Update, in this order: this file → the `-TfRef` / `-RecipeRef` defaults in `scripts/2-clone.ps1` and
   `scripts/Invoke-Migration.ps1` → the patch table in `README.md` / `README.zh-CN.md` / `SKILL.md` §4.1 →
   the hashes in `NOTICE` section 3.
6. Re-run `Invoke-Migration.ps1` from a clean tree and record the new numbers in section 5.
