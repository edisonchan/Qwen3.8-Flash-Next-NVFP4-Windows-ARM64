# Build and Porting Rationale Notes (TensorFold v1.1.4 / Windows ARM64)

[English](build-notes.md)

This document explains **why** things are done this way, so that when redoing the migration on a new engine version you can judge which conclusions still hold.

> Upstream versions (v1.1.5+) have already landed the Windows porting layer on the mainline (`zig/src/platform/sys.zig` etc.).
> By then, most items in Chapter 2 may have been absorbed upstream — **check the upstream `docs/WINDOWS.md` first, then decide whether this patch is still needed**.

---

## 1. Why a "merged patch" instead of applying 17 recipe patches in sequence

The recipe's `patches/0001..0017` were generated against TensorFold `db281878`. The current `TF_REF` is `eab85828` (v1.1.4) —
v1.1.4 rewrote the engine ("the Zig engine has been reimplemented on its own Flash Next CUDA engine"),
and both the files and the context have drifted. The measured result of a sequential `git apply`:

- 6 patches apply cleanly (0001/0002/0003/0004/0007/0009);
- 11 require `git apply --3way`, and most of those leave conflict hunks that must be adjudicated by hand.

Manual adjudication is not reproducible — a different machine or a different person yields a different tree. So this skill
freezes the **final correct result** of those 17 patches into a single merged patch (`0001-recipe-0001-0017-on-v1.1.4.patch`), which is the product of a three-way merge
and has been verified byte-for-byte (see `verification.md`).

Costs and trade-offs:

| | Merged patch | Sequential apply + manual conflict resolution |
|---|---|---|
| Reproducible | ✅ Deterministic | ❌ Depends on adjudication |
| Size | ~495 KB | 17 files totaling ~470 KB |
| Traceability | Comes with notes; can be re-checked file by file with `git diff` | Maps directly to upstream patches |
| On an engine upgrade | Needs to be regenerated once | Conflict adjudication must be redone for every version |

Generation method (to reproduce this patch set):

```bash
# 1) Clone cleanly and, on eab85828, apply the 17 patches correctly via three-way merge + manual adjudication (yielding "target tree" A)
# 2) Create a second clean clone (pristine tree B = eab85828)
# 3) Copy all changed files from A over B, git add -A, git diff --cached HEAD > 0001.patch
```

---

## 2. Five Windows/MSVC compatibility points

### 2.1 `__restrict__` and explicit template instantiation (3 .cu files)

On **explicit instantiation** (`template __global__ void f<...>(...)`), MSVC requires the argument types to match
the template definition's parameter types **exactly**, including MSVC-extension qualifiers such as `__restrict__`. GCC/clang treat `__restrict__` as a hint and
ignore it when comparing types, which is why it compiles upstream on Linux.

Template definition (`qmm_prefill.cu`):

```cpp
template <int GS, int BM, int BN, int WM, int WN, int STAGES, bool F32>
__global__ void prefill_kernel(const __nv_bfloat16* __restrict__, const uint32_t* __restrict__, ...);
```

The explicit instantiation was written as:

```cpp
template __global__ void tf_qmm_prefill::prefill_kernel<64, 128, 128, 2, 2, 2, false>(
    const __nv_bfloat16*, const uint32_t*, ...);      // ← missing __restrict__
```

nvcc reports `no instance of function template ... matches the specified type`, pointing at the instantiation line —
the template arguments are **not** wrong; it is the qualifiers that mismatch. Another instantiation in the same file (`<2,4,3>`) happens to carry `__restrict__`,
so it passes while this one cannot — that is the most direct piece of contrasting evidence.

The same pattern appears in:

- `prefill_attention.cu`: `hpattn_kernel<256,8,2,2>`, `hpattn8_kernel<256,8,2,2>`
- `gdn_prefill.cu`: `chain_kernel<bf16,bf16,64,32>`

Fix: add only the qualifiers — do not touch any parameter types, template arguments, or launch configuration. **Zero semantic change**.

> When these three files fail, the build log contains only `error: process exited with code 1` (nvcc's C++ diagnostics go to stdout,
> while zig merely relays the exit code). To see the real error, run nvcc standalone:
>
> ```bat
> nvcc -fatbin --expt-relaxed-constexpr -std=c++20 -Xcompiler=/Zc:preprocessor ^
>      -O3 -gencode=arch=compute_121,code=sm_121 -o out.fatbin <file>.cu
> ```
>
> This must be run inside a `vcvarsall arm64` environment.

### 2.2 `std.posix.MAP` is `void` on Windows

`cuda_ple_reader.zig` (introduced by patch 0013) uses an anonymous mmap to allocate the n-gram row cache:

```zig
const mem = try std.posix.mmap(null, n, .{ .READ = true, .WRITE = true },
                              .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
```

In zig 0.17.0, `std.posix.MAP = system.MAP`, and on Windows targets `system` has no enum for anonymous mappings,
so `MAP` resolves to `void` → the compiler reports `type 'void' does not support struct initialization syntax`.

Fix (affects only the Windows branch):

```zig
const mem: []align(std.heap.page_size_min) u8 = if (builtin.os.tag == .windows)
    try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), slot_bytes)
else
    try std.posix.mmap(null, slot_bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
```

`std.heap.PageAllocator` is `mmap(MAP_ANONYMOUS|MAP_PRIVATE)` on POSIX and
`VirtualAlloc(MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)` on Windows: both satisfy the three properties this code depends on —
page alignment, zero-initialization, and demand-committed pages (untouched pages consume no physical memory). So the cache behavior matches Linux.

The release side forks correspondingly (`VirtualFree(MEM_RELEASE)` / `munmap`), with the Linux path left completely unchanged.

### 2.3 `clock_gettime` is no longer a posix API in this zig

The timing statistics in `cuda_ple.zig` used:

```zig
_ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &t);
```

- `std.posix` in this zig version no longer has `clock_gettime`;
- the declaration in `std.c` resolves `clockid_t` to `void` on Windows, yielding
  `parameter of type 'void' not allowed in function with calling convention 'aarch64_aapcs_win'`.

Fix: use the repo's own idiom `std.Io.Clock.awake.now(io)` (widely used in the CLI), and store `std.Io` in
the `Ngram` struct (`init` already receives an `io` parameter; it simply wasn't saved before). On Windows, `std.Io` is
implemented with `QueryPerformanceCounter`, and on POSIX with `CLOCK_MONOTONIC` — exactly the monotonic clock the original code wanted.

There are only 6 call sites (2 in `Split.part`, 4 in `rowsMany`), and all of them execute only when `Stat.on` is enabled,
so the hot path is unaffected.

### 2.4 A false lead that once misled me

On my first fix, I interpreted the `qmm_prefill.cu` error as "zig generated a call to `prefill_kernel<...,1,2,2,...>`
but never instantiated it", so I added a WM=1 instantiation. **This was wrong**: the only `qmm_prefill` symbols in the engine are

```
_ZN14tf_qmm_prefill14prefill_kernelILi64ELi128ELi128ELi2ELi4ELi3ELb0EE
_ZN14tf_qmm_prefill14prefill_kernelILi64ELi128ELi128ELi2ELi2ELi2ELb0EE
```

(`prefill` / `prefill22` in `zig/src/cuda/qlinear.zig`), with no reference to any WM=1 variant. The real root cause was `__restrict__` alone, from start to
finish. Lesson: **check the symbol table first, then change code**; for explicit-instantiation errors, suspect qualifiers before template arguments.

---

## 3. Three hard constraints on the build environment

### 3.1 nvcc must be able to see the arm64 `cl.exe`

`vcvarsall.bat arm64` sets `PATH` / `INCLUDE` / `LIB`, which nvcc relies on to find `Hostarm64\arm64\cl.exe` and the
Windows SDK. **In PowerShell, `call`ing a batch file does not change the parent process's environment**, so you must:

```
cmd /c build_now.bat        # inside the .bat: call vcvarsall arm64 && zig build ...
```

The symptom of skipping this step is very deceptive: **every** `.cu` fails with `error: process exited with code 1`,
and the log shows only C4819 (codepage warnings), with no C++ errors visible at all.

### 3.2 Redirect all caches and temp directories into `build\`

```
ZIG_LOCAL_CACHE_DIR  = <TF>\build\.zig-cache
ZIG_GLOBAL_CACHE_DIR = <TF>\build\zig-cache-global
TMP / TEMP           = <TF>\build\tmp
```

Benefits: no pollution of the user profile; cleanup is just `rm -rf build`; when switching machines you won't accidentally hit another machine's cache.

### 3.3 Target triple and architecture

`zig build native install -Dsm=121 --prefix build`. `-Dsm=121` determines nvcc's
`-gencode=arch=compute_121,code=sm_121` and selects the kernel-set path `share\tensorfold\cuda\sm121`
in `native/cuda.zig`.

---

## 4. Runtime-related (unrelated to building, but you will inevitably hit these during migration)

| Item | Conclusion |
|---|---|
| `--kv-dtype` → `--kv-cache` | Renamed in v1.1.4. `start.sh` (Linux) already uses the new name; the Windows `start.ps1` once used the old name, with the symptom `argument --kv-dtype: invalid choice: 'fp8'` |
| AOT kernel set (`TENSORFOLD_CUDA_KERNELS`) | The engine prefers it, then falls back to `share\tensorfold\cuda\sm<cap>` next to the executable, and only then to the embedded fatbin. A kernel set left behind by an older engine lacks fp8 KV support and reports `Fp8KvUnsupported` |
| Variable "exists but is empty" | As long as the variable is non-null, `aot.pick()` takes the "treat as directory" branch; an empty string is neither `native` nor contains an `aot.json` → `TENSORFOLD_CUDA_KERNELS= holds no aot.json`. For the embedded kernel set, give the literal `native` |
| Checkpoint format | v1.1.4's Flash Next CUDA path accepts only `quant_method=modelopt` + `quant_algo=MIXED_PRECISION`; GPTQ's INT4-AutoRound is rejected with `UnsupportedCheckpoint` — the engine has removed that quantization path, so this repo supports only `nvidia/Qwen3.8-Flash-Next-FP4-Local` |
| `kernels embedded true` | In the smoke test, this field of `tf-cuda-test info` means no external kernel set is needed; only when it is `false` do you need `tools/zig/flashnext_aot.py` |
| Memory | The 81 GiB of weights go through the GPU pool; the system side needs only a few GiB of buffers; the memory check in `start.ps1` warns but does not block |
| Slow load (257 s) | The native path **assembles experts on the fly** layer by layer, single-threaded with a 2-slot mapped cache; patch `0003` fixes this — see Chapter 5 |

---

## 5. The model loading pipeline (257 s → 71 s)

Chapter 4 was about "getting it to run"; this chapter is about "not waiting four minutes once it runs". All changes are host-side, **not a single line
of `.cu`, and no kernel parameters or launch configurations were changed**.

### 5.1 What one layer's experts are doing

In v1.1.4's `cuda_prompt_load.zig`, MoE layers are not read from a pre-quantized cache but **assembled on the fly from raw safetensors**:

```
NVFP4 experts in safetensors  ──readPart──▶  codes + scales (e4m3 scales, one block per 16)
                              ──packGateUp / packOne──▶  the layout the engine wants (gate and up interleaved, down separate)
                              ──upload──▶  the up / down tensors on the GPU
```

A layer has 512 experts, each expert has 3 projections (gate / up / down), and after packing each layer is about **1350 MiB** (≈2.64 MiB/expert).
48 layers means 24576 experts and roughly 63 GiB of assembly work. **This computation cannot be avoided** (the checkpoint does not contain the layout the engine wants);
what can be done is to parallelize it and let DMA overlap with it.

### 5.2 The three amplifiers of the old path

| Amplifier | Details | Cost |
|---|---|---|
| Single-threaded, expert by expert | `for (0..512)`: read → pack → `up.upload()` → `down.upload()` → `stream.synchronize()` | Only one core used at a time; per layer, 1536 small copies + 512 synchronizations |
| 2-slot mapped cache | `Store.released: [2]Held`, while one layer's experts are spread across **14 shards** | Within each layer's loop, mappings are repeatedly closed/reopened and shard headers re-parsed (50.6 MB of headers model-wide, up to 9.3 MB for a single file) |
| Row-by-row memcpy | `slice()` in `core/nvfp4_slice.zig` does one `@memcpy` per row | Accounts for about 1/3 of read time; pure waste for full-width tensors |

Note that "header re-parsing" is more expensive on Windows than on Linux: the Windows branch of `cuda_ple_reader.zig` uses
`PageAllocator` (`VirtualAlloc`) instead of `mmap`, so shard metadata must be re-decoded on every layer.

### 5.3 The current pipeline

```
   ┌────────── group i+1 ───────────┐        ┌──── group i+2 ────┐
   │ 20 threads pack 16 experts in  │        │                   │
   │ parallel into stage B's slices │        │                   │
   └───────────────┬────────────────┘        └───────────────────┘
                   │ cuMemcpyHtoDAsync(stage B → GPU)
   ┌───────────────┴────────────────┐
   │ Meanwhile: stage A's DMA is    │   ← the previous group's copy is hidden by this group's packing
   └────────────────────────────────┘
```

Key numbers (measured on this machine, for one layer):

| Quantity | Value | Source |
|---|---|---|
| Experts per group | 16 (`TENSORFOLD_LOAD_GROUP`) | `stage_default` |
| Size per stage | 16 × 2.64 MiB ≈ 42 MiB | `Stage.init(d, group, up_bytes, down_bytes)` |
| Double buffering total | ≈ 84 MiB | Only 0.5% of the 16 GiB of available host memory |
| One group's pack | ≈ 22 ms (20 threads) | 698 ms / 32 groups |
| One group's DMA | ≈ 2 ms | 42 MiB @ 20 GB/s |
| Wait per group | ≈ 0.5 ms | `stage wait` 18 ms / 32 groups |

### 5.4 Three design trade-offs

1. **Slice by "group", not "one thread per expert"**: DMA submission has a fixed overhead — a 2.6 MiB copy costs far more per byte than a 42 MiB one;
   and submitting per expert would produce 1536 ioctls per layer, with overhead larger than the data itself. Only by batching up a full group
   before submitting does the asynchronous copy become worthwhile.
2. **Atomic ticket-taking, no static partitioning**: 512 / 20 does not divide evenly, so static partitioning yields "thread 0 does 26, thread 19 does 22",
   leaving a long tail; ticket-taking lets faster threads naturally do more work.
3. **Double buffering + event back-pressure — not "the more buffers, the better"**: two stages already hide the copy 100% inside the packing
   (`stage wait` 0.87 s / 67.6 s). Adding more buffers only increases host memory and first-startup latency, with zero benefit.

### 5.5 Concurrency correctness

Reading checkpoints in parallel breaks every assumption that the code was "used sequentially by a single thread"; three places must be handled:

| Risk | Handling |
|---|---|
| Multiple threads leasing/returning mappings at the same time, bookkeeping stepping on each other | `Store.mtx: std.Io.Mutex` (zig 0.17 removed `std.Thread.Mutex`); **record pointers inside the lock only, do IO outside it** |
| Closing a mapping someone else is reading when the slot pool is full | When slots are full, sweep the "returned" mappings into the cache (`releaseLocked`); **never close a mapping that is currently leased out** |
| The next group overwrites a stage while the DMA is still reading it | One `cuda.Event` per stage, `synchronize()` before reuse (`Stage.reuse`) |
| 20 threads all still running when an error occurs | `Job.stop` atomic flag: one failure, the rest stop immediately, and the error is thrown back to the caller |

Two additional generic constraints: the test mock for `loadShape(store: anytype)` is not a `*wt.Store`, so the parallel path is enabled only when
`@TypeOf(store) == *wt.Store` — **unit tests still run the original serial implementation**; any allocation failure in `fill` logs a warning
and falls back to `serial()`, never failing the load as a whole.

### 5.6 Measurement conventions

`TENSORFOLD_LOAD_STATS=1` prints two lines per layer (to stderr):

```
info: flashnext: 512 experts in 32 groups of 16 on 20 threads: pack 698 ms, stage wait 18 ms, 1350 MiB
info: flashnext: layer 47 took 1170 ms
```

- `pack` = cumulative CPU packing time across all groups (including parallelism, so it is a wall-clock accumulation)
- `stage wait` = the sum of all `Stage.reuse()` waits → **this is the direct indicator of whether double buffering suffices**; above 5%, suspect the group is too small
- `layer N took` = the whole layer (including non-expert weights, norms, and shared experts)
- The trailing `1350 MiB` = `(up_bytes + down_bytes) * count >> 20`, i.e. the layer's total packed bytes

After all 48 layers are read, `cuda_prompt.zig` calls `store.dropShards()`, releasing the mappings and the parsed headers together (about 0.6 GB).

---

## 6. How to redo all this on a version upgrade

1. Read the recipe's `CHANGELOG.md` to determine the new `TF_REF` (`scripts/config.sh`).
2. Clone the engine cleanly and check out that commit.
3. Apply the recipe patches in order with `git apply --3way`, adjudicate conflicts by hand, and obtain the "target tree".
4. Use the method from Chapter 1 to compress the target tree into a single merged patch.
5. Re-run the build and categorize each newly appearing Windows error:
   - `no instance of function template` → add `__restrict__` (new files may be involved)
   - `void`-related → missing platform API (check `std.posix` availability in that zig version)
   - Anything else → judge case by case; **change only the platform branch**, never the algorithm
6. Update this skill's three patches and the pinned-value table in `SKILL.md`. `0003` was cut "after 0001+0002"; on an upgrade, re-cut it on
   the already-patched target tree: reproduce the loading changes you want to keep onto that tree, and the `git diff` out of it is the minimal increment.
7. Re-measure the load time and update the numbers in Chapter 5 (`TENSORFOLD_LOAD_STATS=1` + `build\logs\serve-*.err.log`).
