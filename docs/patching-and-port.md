# TensorFold v1.1.4 + Qwen3.8-Flash-Next: A Field Record of Patching and Porting on Windows ARM64

[English](patching-and-port.md)

This document records three things, in the order we actually did them:

1. **Patching**: how the "17 recipe patches + Windows compatibility fixes" were compressed into three reproducible patches — how each was cut, verified, and rolled back.
2. **Problems fixed**: the headline is **model load 257 s → 71 s** (how it was localized, what changed, which compile pitfalls we hit, and how we proved nothing broke),
   plus memory admission and the two real bugs that made `start.ps1` forever report "not ready" under PowerShell 5.1.
3. **The `.sh` → `.ps1` rewrite**: Docker → native process, container logs → two log files, `/proc/meminfo` → Win32,
   bash habits → PowerShell 5.1 equivalents, item by item.

Environment: Windows 11 ARM64 / RTX Spark N1X (GB10, sm_121, 20 cores, 48 SMs) / CUDA 13.4 / zig 0.17.0 / MSVC v143 ARM64.

---

## 0. Results at a glance

| Item | Value |
|---|---|
| Engine | `ashhart/TensorFold` @ `eab8582819688325e371907e4706e1c602b8a273` (tag v1.1.4) |
| Recipe | `MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold` @ `fd3f43e11238553685ebb68b6d8ab2b112818e3c` (its `patches/0001..0017`) |
| Weights | `nvidia/Qwen3.8-Flash-Next-FP4-Local` @ `b9ce18a6887e18c089fdea8509a33e63429a3300` (`modelopt`/`MIXED_PRECISION`, 96 GB, **the only supported option**) |
| Toolchain | zig 0.17.0 (aarch64-windows) · CUDA 13.4 (`V13.4.92`) · MSVC 14.44.35207 arm64 · Windows 11 ARM64 build 10.0.28000 |
| Patches | `0001` (recipe 0001–0017 merged) → `0002` (Windows/MSVC, 5 spots) → `0003` (load pipeline), **the order cannot be changed** |
| Working tree | 78 changes = 59 modified + 19 new |
| Artifacts | `TensorFold\build\native\bin\tensorfold-native.exe` (PE32+ ARM64, 36 MB), `tf-cuda-test.exe` (75 MB) |
| Cold build | 5–8 minutes (`zig build native install -Dsm=121` run inside `cmd /c` + `vcvarsall arm64`) |
| Model load | native 257 s → **71 s** (engine self-reports `loaded in 67.6s`) |
| Server start | `.\start.ps1` → `server answered after 71s` → smoke test `OK` |

> There is exactly one authoritative source for versions: [`VERSIONS.md`](../VERSIONS.md). Why each version is pinned, what breaks if it moves, and the commands to verify it are all there;
> every number in this document corresponds to that one combination from the table above.

---

## 1. The whole pipeline on one page

| Phase | Action | Artifact / pass criterion |
|---|---|---|
| ⓪ Paths | `migration.config.ps1` probe + menu (root/python/zig/cuda/vcvars/model), saved to `.migration.local.json` | all six lines green |
| ① Clone | `git clone` engine + recipe, engine checked out at `eab85828` | `git rev-parse HEAD` |
| ② Patch | `0001` recipe changes → `0002` Windows compatibility → `0003` load pipeline | `git status` 78 items, both spot-checks green |
| ③ Build | `zig build native install -Dsm=121` inside `cmd /c` + `vcvarsall arm64` | `tensorfold-native.exe` 36 MB, `tf-cuda-test.exe` 75 MB |
| ④ venv (optional) | needed only with `--vision`; torch from the NVIDIA OOT index, then `tensorfold[vision]` v0.6.6 | `find_spec('tensorfold.vision.native_helper')` returns 0 |
| ⑤ Recipe side | `recipe/1-install-ps1.ps1`: drop in the 4 `.ps1` files, write `MODEL_PATH` into `.env` | recipe `git status` shows only `??`, no ` M` |
| ⑥ Start server | `.\start.ps1` (in the recipe directory) | `server answered after 71s` + smoke test `OK` |
| ⑦ Wrap up | `.\stop.ps1` | `Stopped; its GPU memory is free again` |

`prepare.sh` (pulling the base image, building the Docker image, downloading the weights) has no counterpart on Windows: there is no container layer,
the weights are a local directory, and "prepare" = ① clone + ② patch + ③ build + venv (see §6.7).

### 1.1 Two tracks: engine and recipe

| | Repository | Scripts | What it touches |
|---|---|---|---|
| engine | `ashhart/TensorFold` | `scripts/engine/1-preflight … 6-smoke` | the three patches + the build, producing `tensorfold-native.exe` |
| recipe | `MiaAI-Lab/Qwen3.8-Flash-Next-…` | `scripts/recipe/1-install-ps1.ps1` | **adds files only**: 4 `.ps1` files, `MODEL_PATH` in `.env` |

Not a single source line of the recipe is changed — this is deliberate. Before `1-install-ps1.ps1` finishes it verifies itself: `git -C <recipe> status --porcelain`
should show only `??` (new files), no ` M` (modified). `start.ps1`/`stop.ps1` land at the recipe root, `config.ps1`/`banner.ps1`
land in `scripts\`, side by side with the `.sh` originals; the `.ps1` files can be deleted at any time to fall back to the shell version.

### 1.2 No hard-coded paths

At first the docs and scripts were full of `D:\llm\latest` — move to another machine or another drive and everything broke. Now paths come from a single source:
`scripts/migration.config.ps1`.

- **Probe**: root is taken as the directory containing this repository (the two clones live alongside it); python from `PATH` → `%LOCALAPPDATA%\Programs\Python`
  → `%ProgramFiles%`; zig from `PATH` → `zig*` directories under root and its parent; CUDA from `CUDA_PATH` → the toolkit install root (must contain
  `bin\nvcc.exe`); vcvars from any VS 2022 installation; weights from `MODEL_PATH` → `<root's parent>\model\<name>`.
- **Menu**: six numbered lines, Enter accepts, a number edits that line, `?` opens a folder picker, `d` re-probes. Before accepting, each entry is validated
  (zig must be 0.17.0, nvcc must be 13.4, python must be 3.11+ and aarch64, weights must be `modelopt`/`MIXED_PRECISION`);
  a hard failure requires a second confirmation — otherwise the failure gets pushed to three steps later.
- **Freeze**: the accepted result is written to `.migration.local.json` (git-ignored); from then on every script reads it with `Get-MigConfig -Quiet`,
  and nobody is ever asked twice. Deleting it is the same as "re-probe". Explicit parameters (`-Zig`, `-TensorFold`, …) always take priority.

The engine directory and the recipe directory are not selectable: the recipe's own `config.ps1` locates the sibling engine exactly this way (`<recipe's parent>\TensorFold\build\...`),
so root is the only option.

---

## 2. Patching procedure

### 2.1 Why the recipe's 17 patches cannot simply be applied

The recipe's `TF_REF` pins v1.1.4 at `eab85828`, but `patches/0001..0017` were generated against the earlier `db281878`.
Between the two, `cuda_prompt*.zig`, `cuda_mtp*.zig`, `cuda_ple*.zig` and others were all changed upstream, so a straight sequential apply hits
**11 conflicts** and requires manual three-way merge adjudication — **the adjudication results cannot be expressed in text, and therefore cannot be reproduced**.

The approach: on a clean clone, apply all 17 patches with `git apply --3way`, adjudicate the conflicts by hand, and get the "**target tree A**";
then open a second clean clone (**original tree B** = `eab85828`), copy every changed file from A over to B, `git add -A`,
`git diff --cached HEAD > 0001-...patch`. This merged patch is "the final correct result of that manual adjudication";
`git apply` runs once, deterministically, byte-for-byte reproducible.

> The cost: a 495 KB / 9380-line patch. The payoff: from a fresh clone to a buildable tree takes one command, with no conflict adjudication left to do.

### 2.2 0001: recipe changes (74 files / 9380 lines)

```powershell
git -C TensorFold checkout --detach eab8582819688325e371907e4706e1c602b8a273
git -C TensorFold apply --check <skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch
git -C TensorFold apply       <skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch
```

What it brings in is the recipe's **performance rework** of the engine (the fp4 engine, system-memory cache, dual rank, serving, prompt-expert-tile,
fair-prefill, vision python, and so on). These are not the focus of this document, but they **must all be present**, or even the load path would differ
(for example, 0014's prompt-expert-tile changes how experts are used during the prompt phase).

### 2.3 0002: Windows/MSVC compatibility (5 files / 158 lines)

Solves only "won't compile"; **not a single line changes kernel arithmetic**.

| # | File | Symptom | Change | Why |
|---|---|---|---|---|
| 1 | `zig/kernels/cuda/qmm_prefill.cu` | `no instance of function template "prefill_kernel" matches the specified type` | add `__restrict__` to the formal parameters of the two explicit instantiations | MSVC requires the parameter types of an explicit instantiation to match the template definition **verbatim** (qualifiers included); GCC/clang ignore `__restrict__`, which is why upstream compiles on Linux |
| 2 | `prefill_attention.cu` | same as above (hpattn / hpattn8) | same as above | same as above |
| 3 | `gdn_prefill.cu` | same as above (chain_kernel) | same as above | same as above |
| 4 | `cuda_ple_reader.zig` | `type 'void' does not support struct initialization syntax` | the anonymous `mmap` in the Windows branch is switched to `page_allocator.alignedAlloc`; the Linux path is untouched | on Windows targets `std.posix.MAP` is `void` and anonymous mappings do not exist; `PageAllocator` is `VirtualAlloc` underneath — equally anonymous/zero-filled/demand-committed |
| 5 | `cuda_ple.zig` | `parameter of type 'void' not allowed in function with calling convention 'aarch64_aapcs_win'` | `Stat.now()` switched to `std.Io.Clock.awake.now(io)`; `Ngram` gains an `io` field | this zig version removed `std.posix.clock_gettime`; on Windows `std.c.CLOCK` is `void`; `Io.Clock` is implemented by the stdlib on Windows with QPC |

`qmm_prefill.cu` is not among 0001's 74 files: the upstream v1.1.4 original never had `__restrict__`, and the recipe patches never touched it either,
so this is a **pure MSVC compatibility problem**, unrelated to the recipe.

### 2.4 0003: load pipeline (4 files / 441 lines)

This patch was not cut against v1.1.4 but against the tree with "**0001+0002 already applied**" — `cuda_prompt.zig` and
`cuda_prompt_wt.zig` were already modified by 0001, so cutting directly against v1.1.4 would fold 0001's changes in.

Cutting procedure (safe to copy verbatim):

```bash
# 1) Build a "after 0001+0002" baseline and pin it down
git -C TensorFold worktree add --detach <tmp> eab8582819688325e371907e4706e1c602b8a273
git -C <tmp> apply <skill>/patches/0001-...patch
git -C <tmp> apply <skill>/patches/0002-...patch
git -C <tmp> commit -a -m 'baseline: 0001+0002'

# 2) Copy the load changes to keep over the top; the diff is exactly the minimal increment
cp <production tree>/{nvfp4_slice.zig,cuda_modelopt_experts.zig,cuda_prompt_wt.zig,cuda_prompt.zig} <tmp>/<corresponding paths>
git -C <tmp> diff > 0003-load-pipeline.patch      # 4 files, +273 -35

# 3) Verify on the same tree: reset to bare eab85828, then apply 0001→0002→0003 again
```

Verification result (`git status --untracked-files=all` = 78 items, the 4 files match the production tree's sha256 exactly):

```
0001 sha256 c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad  applied
0002 sha256 9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40  applied
0003 sha256 911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64  applied
tree now: 59 files changed, 3783 insertions(+), 193 deletions(-)
```

### 2.5 Apply order and rollback

```powershell
# Apply (the script sorts by file name, which is naturally 0001 → 0002 → 0003)
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\3-apply-patches.ps1 -TensorFold <root>\TensorFold

# Roll back
git -C <root>\TensorFold reset --hard eab8582819688325e371907e4706e1c602b8a273
git -C <root>\TensorFold clean -fd   # the 19 untracked files added by 0001
git -C <root>\TensorFold status --porcelain # should be empty
```

**The order cannot be swapped**: 0003's context contains lines changed by 0001. Applying by hand in reverse fails `--check` outright (a good thing — nothing gets left half-applied).

---

## 3. Problem fixed #1: model load 257 s → 71 s

This is the section most worth writing out clearly. **Not a single second of those four minutes was spent on CUDA**; it was all on the host side.

### 3.1 First, rule out three "reasonable suspects"

| Suspicion | Measured | Conclusion |
|---|---|---|
| Slow disk (81 GiB of weights) | sequential read 5.0 GB/s | not IO |
| Insufficient PCIe / copy bandwidth | single HtoD 20+ GB/s | not DMA |
| CUDA kernel problem | GPU utilization is high during loading, but it is **all copies**, no kernel running | not the kernel |

All three can be ruled out with one command each, and doing this step first pays off — otherwise you end up poking at fatbins and `-gencode`, which is a dead end.

### 3.2 The real root cause: v1.1.4's load path assembles on the fly

v1.1.4's Flash Next CUDA path has **no pre-quantized cache**: every layer reads the NVFP4 experts from the raw safetensors,
re-packs them on the fly into the layout the engine wants, then uploads. The old implementation (`loadShape` in `cuda_modelopt_experts.zig`) was:

```zig
for (0..512) |i| {                                            // 512 experts per layer
    var gate   = try readPart(a, store, "…gate_proj", ...);   // small copy 1
    var value  = try readPart(a, store, "…up_proj",   ...);   // small copy 2
    var output = try readPart(a, store, "…down_proj", ...);   // small copy 3
    ex.packGateUp(...); ex.packOne(...);                      // single-threaded repacking
    try up.upload(); try down.upload();                       // stream.synchronize() after every upload
}
```

One layer = 512 × 3 = 1536 small copies + 512 synchronizations; 48 layers = 24,576 experts. But what actually blew the time up to four minutes were three implicit costs:

| Amplifier | Detail | Cost |
|---|---|---|
| **Serial** | only one core packs at a time; CPU packing and DMA are fully mutually exclusive | 1 of 20 cores used |
| **Mapping cache has only 2 slots** | `Store.released: [2]Held`, yet **one layer's experts are scattered across 14 shards** | every layer repeatedly closes/reopens shards and re-parses headers (50.6 MB of headers model-wide, up to 9.3 MB in a single file) |
| **Line-by-line memcpy** | `slice()` in `core/nvfp4_slice.zig` does one `@memcpy` per row | thousands of rows per layer, about 1/3 of read time |

On Windows the second amplifier is even more expensive: the Windows branch of `cuda_ple_reader.zig` uses `PageAllocator` (`VirtualAlloc`)
instead of `mmap`, so shard metadata is fully re-decoded on every reopen, with no page cache as a backstop.

### 3.3 Fix steps (in the order actually done)

**Step 1: instrument first, don't change anything yet.** Without per-segment data you can only guess. Add three cumulative counters in `fill()` (where the per-expert loop used to be):
`pack` (packing wall-clock), `stage wait` (waiting for a stage to become available), and per-layer total time:

```zig
const threads = @max(1, @min(envNumber("TENSORFOLD_LOAD_THREADS") orelse (std.Thread.getCpuCount() catch 4), max_threads));
const group   = @min(@max(envNumber("TENSORFOLD_LOAD_GROUP") orelse stage_default, 1), count);
if (stats) std.log.info("flashnext: {d} experts in {d} groups of {d} on {d} threads: pack {d} ms, stage wait {d} ms, {d} MiB",
    .{ count, g, group, threads, packed_ns / 1_000_000, waited_ns / 1_000_000, (up_bytes + down_bytes) * count >> 20 });
```

> **Pitfall**: the variable names must carry the `TENSORFOLD_` prefix. `scripts\config.ps1` only exports keys that appear in `.env` into the process environment,
> so writing `TF_LOAD_STATS` silently does nothing (my first version wasted a whole run this way). The logs land in `build\logs\serve-*.err.log`
> (the `info:` lines, stderr), not `.out.log`, and they contain NUL bytes, so use `grep -a` or `Get-Content -Encoding Default`.

**Step 2: grow the mapping cache from 2 slots to 48 and make it thread-safe.** One layer spans 14 shards, and 48 slots can hold three layers,
so there is no more close/reopen during a layer load. Once reads run in parallel, `Store` gets borrowed by multiple threads at once, so three things must be handled:

```zig
pub const cached_shards: usize = 48;
mtx: std.Io.Mutex = .init,          // zig 0.17 removed std.Thread.Mutex

// 1) Serialize the borrowing bookkeeping, but keep IO outside the lock (the lock guards only tens of bytes of pointer records)
self.mtx.lockUncancelable(self.io);
defer self.mtx.unlock(self.io);

// 2) When slots are full, sweep "returned" mappings into the cache; never close a mapping that is currently borrowed
if (self.nheld == self.held.len) self.releaseLocked();

// 3) Release everything once all 48 layers are read (reclaims about 0.6 GB of parsed headers)
pub fn dropShards(self: *Store) void { ... releaseLocked(); closeFileLocked(); closeReleasedLocked(); }
```

**Step 3: grouped parallelism + pinned double buffering + event backpressure.** This is the main speedup. The 512 experts are cut into 32 groups × 16,
with two stage buffers (A/B) alternating: one group is being packed while the other is being read by DMA, so neither waits on the other.

```
Timeline ────────────────────────────────────────────────────────────▶
Packing (20 threads)  [gr1 ][gr2 ][gr3 ][gr4 ] ...   about 22 ms per group
Async DMA                 [1]  [2]  [3]  [4]  ...    about 2 ms per group, entirely inside the next group's packing window
```

Four essentials; drop even one and the gains shrink:

- **Cut by "groups", not "one thread per expert"**: DMA submission has fixed overhead; one 42 MiB copy is far better than 16 copies of 2.6 MiB;
  per-expert submission would produce 1536 ioctls per layer, with overhead larger than the data itself.
- **Atomic ticket-taking, no static partitioning**: 512/20 does not divide evenly, and static partitioning produces a 26 : 22 long tail; ticket-taking lets faster threads do more.
- **Pinned memory is a hard requirement**: `cuMemHostAlloc` (`cuda.HostBuffer`) gets page-locked memory. Calling
  `cuMemcpyHtoDAsync` on ordinary pageable memory makes the driver fall back to "temporary staging buffer + synchronized copy", making the double buffering pointless.
- **Event backpressure must not be skipped**: one `cuda.Event` per stage, `synchronize()` before reuse. Without it, the next group overwrites
  the stage currently being read by DMA; using just one `sync` instead would leave all 20 threads stalled together.

```zig
const Job = struct {
    next: std.atomic.Value(usize) = .init(0),   // take a ticket
    stop: std.atomic.Value(bool)  = .init(false),  // one failure, everyone backs off
    fn pack(self: *Job, i: usize, a: std.mem.Allocator) !void { ... }
};

fn enqueue(d: *const cuda.Driver, dst: u64, src: []const u8, stream: cuda.abi.Stream) !void {
    if (src.len == 0) return;
    try d.check(d.api.cuMemcpyHtoDAsync_v2(dst, @ptrCast(@constCast(src.ptr)), src.len, stream), "cuMemcpyHtoDAsync");
}
```

**Step 4: one whole-block memcpy.** Add a whole-width check in `slice()`, turning thousands of `@memcpy` calls into one:

```zig
const whole = inputs.from == 0 and inputs.to == d.k;
if (whole) {
    @memcpy(codes[0 .. n * (d.k / 2)], source.weight.bytes[rows.from * (d.k / 2) ..][0 .. n * (d.k / 2)]);
} else for (0..n) |row| { ...line by line... };
```

**Step 5: release all mappings once loading finishes** (`dropShards()`), otherwise 0.6 GB of header memory stays resident.

### 3.4 Four zig 0.17 compile pitfalls hit along the way

| Error | Cause | Fix |
|---|---|---|
| `root source file struct 'Thread' has no member named 'Mutex'` | 0.17 removed `std.Thread.Mutex` | use `std.Io.Mutex = .init`, `lockUncancelable(io)` / `unlock(io)` |
| `expected type 'u64', found 'i96'` | `Clock.Timestamp.toNanoseconds()` returns **i96** | `@intCast(u64)`; wrap the outer layer too with `@as(u64, @intCast(...))` |
| `expected type '[]u32', found '[]align(1) u32'` | `bytesAsSlice(u32, []u8)` yields 1-byte alignment | first `const w: []align(4) u8 = @alignCast(slot);`, then `bytesAsSlice(u32, w)` |
| `expected type 'mem.Allocator', found '*const driver.Driver'` | I force-cast `loadShape(store: anytype)` to `*wt.Store`, breaking the in-memory mock used by tests | the per-expert logic was moved into `packExpert(store: anytype)`; parallelism is enabled only when `@TypeOf(store) == *wt.Store`, so mocks stay on the serial path |

### 3.5 Proving "it got faster without loading the weights wrong"

The easiest mistake with parallelism + buffer reuse is **silent misalignment**: the model still starts, `/health` is still ok, and the output is gibberish. So three layers were put in place:

1. **Regression guardrail**: `loadShape` takes the parallel path only when `@TypeOf(store) == *wt.Store`; the unit tests' in-memory mock still
   takes the original serial path; any allocation failure in `fill()` logs a warn and automatically falls back to `serial()` without failing the whole load.
2. **Deterministic Q&A**: `capital of France` → `Paris`. Far more effective than just watching `/health`.
3. **Metric reading**: `stage wait` is the only direct indicator of whether the double buffering is sufficient; measured total 0.87 s / 67.6 s; if it ever
   climbs to 5%, first suspect the group is too small (tune `TENSORFOLD_LOAD_GROUP`) rather than touching CUDA.

### 3.6 Results

| Item | native v1.1.4 | after 0003 |
|---|---|---|
| Whole-machine load | 257 s | **71 s** (engine self-reports 67.6 s) |
| Per layer | about 5.0 s | **1.12 s** |
| Copy wait | 3 full syncs per layer | **18 ms/layer** (0.87 s total, 1.3%) |

Per-layer breakdown over the 48 layers (`TENSORFOLD_LOAD_STATS=1`):

```
layer N took   n=48  sum=53564 ms  mean=1116  median=1130  min=886  max=1275
pack           n=49  sum=34222 ms  mean= 698  median= 706  min=527  max= 793
stage wait     n=49  sum=  871 ms  mean=  17.8 max=   49
```

- `pack` accounts for 34.2 s = **the new bottleneck**: about 27 CPU-ms per expert for the 3 projections (698 ms × 20 threads ÷ 512); all 20 cores are already fully used.
- The 48 layers total 53.6 s, 79% of the whole load; the remaining ~14 s are embedding / lm_head / the FP8 n-gram table / attention shared weights.
- `pack` has 49 lines, not 48: after the layer loop there is one more assembly of the same size (right after prompt-expert tile initialization), and it is not counted in the layer timings.

**Can it get any faster**: there is exactly one way — **skip the repacking**, write a one-off tool to preprocess the checkpoint into engine-native expert blobs
(about 10 minutes the first time + about 80 GB of disk), after which loading degenerates into pure read + DMA, estimated at 20 s. That is new functionality (a new artifact,
new cache-invalidation logic); do not slip it into the patch.

---

## 4. Problem fixed #2: memory admission and `PARALLEL`

Symptom: after all 48 layers finished loading, the process exited with an error, and the last log line was

```
--parallel 5 needs 23.74 GiB (5 streams at a 262,144-token window); 22.81 GiB left after a 4.0 GiB reserve
```

This is not a loading problem; it is the **admission budget**: the machine has only 30.5 GB of unified memory (16 GiB of host memory available before loading), the 81 GiB of weights and the KV
both come out of the driver's 98 GiB GPU pool, and the engine additionally keeps its own `TENSORFOLD_MEMORY_RESERVE_GIB`. fp8 KV costs 4.75 GiB per stream:

| Streams | KV demand | Budget after the 4 GiB reserve | Result |
|---|---|---|---|
| 5 | 23.74 GiB | 22.81 GiB | short by 0.93 GiB; exits with an error only after loading completes |
| 4 | 18.96 GiB | 22.81 GiB | server starts normally |

Resolution: pin `PARALLEL=4` in `.env`. There are two ways to get 5 streams — drop `CONTEXT` to 131072, or port the
indexer-key ring buffer from old patch 0010 (saves about 0.88 GiB per stream). **Note that this error only appears after loading completes**; when reading logs, don't assume loading is slow again.

---

## 5. Problem fixed #3: PowerShell 5.1 made `start.ps1` forever report "not ready"

Even after loading got faster it still reported `the server exited before it was ready`, yet the logs clearly showed the server had started and manual requests to `/health`
worked fine. The root cause: `config.ps1`'s health probe **threw an exception every single round** under PS 5.1, so the `while` loop never reached `$ready`.

Two real bugs:

| Symptom | Root cause | Fix |
|---|---|---|
| `无法发送具有此谓词类型的内容正文` (cannot send a content body with this verb type) | in `param([string]$Body = $null)`, `$null` becomes an empty string, so `$null -ne $Body` is **always true**; an empty body goes down the GET path, but **PS 5.1's `Invoke-RestMethod` defaults to the POST verb** (only 6.0+ defaults to GET), and a body-less POST is rejected outright | test emptiness with `[string]::IsNullOrEmpty($Body)`, and **pass `-Method` explicitly on every branch** |
| `找不到与参数名称"NoProxy"匹配的参数` (no parameter matches the parameter name "NoProxy") | `-NoProxy` is a switch that only exists in PowerShell 6.0+ | on the 5.1 branch use `[System.Net.WebRequest]::DefaultWebProxy = $null` wrapped in `try/finally` |

The fixed version (`scripts\config.ps1`):

```powershell
function Invoke-LocalRest {
    param([string]$Uri, [int]$TimeoutSec = 5, [string]$Method = 'Get', [string]$Body = $null)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if (-not [string]::IsNullOrEmpty($Body)) { return Invoke-RestMethod -Uri $Uri -Method $Method -ContentType 'application/json' -Body $Body -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop }
        return Invoke-RestMethod -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec -NoProxy -ErrorAction Stop
    }
    $old = [System.Net.WebRequest]::DefaultWebProxy
    [System.Net.WebRequest]::DefaultWebProxy = $null
    try {
        # PS 5.1 defaults to POST and then rejects a body-less POST: pass -Method every time.
        if (-not [string]::IsNullOrEmpty($Body)) { return Invoke-RestMethod -Uri $Uri -Method $Method -ContentType 'application/json' -Body $Body -TimeoutSec $TimeoutSec -ErrorAction Stop }
        return Invoke-RestMethod -Uri $Uri -Method $Method -TimeoutSec $TimeoutSec -ErrorAction Stop
    } finally { [System.Net.WebRequest]::DefaultWebProxy = $old }
}
```

Two pitfalls from the same root along the way: `config.ps1` already maps `ApiUrl` to `127.0.0.1`, so `HOST=0.0.0.0` is fine, but
**`0.0.0.0` cannot be used directly as an HTTP target**; also, when both `HTTPS_PROXY` and `https_proxy` exist in the process environment,
`Get-ChildItem Env:` throws "Item has already been added. Key in dictionary" (已添加了具有相同键的项), taking `Start-Process` down with it — clear both spellings before launching:

```powershell
foreach ($n in 'HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy','ALL_PROXY','all_proxy') {
    [Environment]::SetEnvironmentVariable($n, $null, 'Process')
}
```

---

## 6. The `.sh` → `.ps1` rewrite

### 6.1 File mapping

These four files are the **only ones that enter the recipe repository**, copied there by `scripts\recipe\1-install-ps1.ps1`:

| Linux (recipe original) | Windows (this machine) | Notes |
|---|---|---|
| `start.sh` (259 lines) | `start.ps1` (308 lines) | the 5-step flow maps one to one; launch changed from Docker to a native process |
| `stop.sh` (24 lines) | `stop.ps1` (19 lines) | `docker stop/rm` → kill the process by pid file (with an orphan backstop) |
| `scripts/config.sh` (201 lines) | `scripts/config.ps1` (246 lines) | defaults, `.env`, memory/KV computation, probe helper functions |
| `scripts/banner.sh` (28 KB terminal art) | `scripts/banner.ps1` (1.4 KB) | **does not copy** the artwork; extracts it from `banner.sh` at runtime via regex |

The rest stay **in the skill directory**, invoked once only when needed, and never enter the recipe (which is why the recipe repository stays at `0 modified`):

| Linux (recipe original) | Windows (this machine) | Notes |
|---|---|---|
| `scripts/prepare.sh` (14.6 KB) | steps 1–6 under `scripts\engine\` | it does "pull image + install deps + download zig + patch + compile + download weights + `docker build`"; on Windows this splits into six individually re-runnable steps, see the pipeline table in §1 |
| `Dockerfile`'s `ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:26.07-py3` | `scripts\engine\4-venv.ps1` | **the container ships torch; this machine has none** → create a `venv` in the recipe directory and install torch (only needed for vision, see the next section) |
| `pip install tensorfold[vision]` (done inside the image) | same as above, second step of `4-venv.ps1` | torch first, then `tensorfold[vision] @ v0.6.6`; the order cannot be reversed |

### 6.1.1 torch and the venv: what the container gave you for free, this machine must install itself

The Linux path has no "install torch" step at all — `nvcr.io/nvidia/pytorch:26.07-py3` already ships a build
that matches CUDA 13.4. On Windows no wheel works out of the box, so a venv must be created in the **recipe directory**:

```
<root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\venv\
```

The reason it must live in the recipe directory is that `recipe\config.ps1` looks for it exactly this way:

```powershell
$VenvDir      = Get-Setting 'VENV_DIR'      (Join-Path $RecipeDir 'venv')
$VisionPython = Get-Setting 'TENSORFOLD_VISION_PYTHON' (Join-Path $VenvDir 'Scripts\python.exe')
```

The corresponding part in `start.ps1` (taken only with `--vision`):

```powershell
if (-not (Test-Path $VisionPython)) { Die "vision is on but the venv python is missing: $VisionPython (set VENV_DIR or VISION=0)" }
& $VisionPython -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
Set-EnvVar 'TENSORFOLD_VISION_PYTHON' $VisionPython
```

So `venv` defaults to the recipe directory; to really move it, set `VENV_DIR` in `.env` (`start.ps1` will follow by updating
`TENSORFOLD_VISION_PYTHON`), but `4-venv.ps1`'s default is the same location — don't change one side and not the other.

Two commands, **the order cannot be swapped**:

```powershell
# 1) torch must come from NVIDIA's nightly index; the arm64 wheels on PyPI do not match CUDA 13.4
python -m pip install --pre --upgrade --only-binary=:all: `
  --extra-index-url 'https://pypi.nvidia.com/nvtorch_oot_nightly' torch torchvision torchaudio

# 2) then install tensorfold with vision (only 0.6.6 ships native_helper)
python -m pip install "tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6"
```

In reverse, step 2 would pull in the plain PyPI `torch` as a dependency; after installing, `cuda.is_available()` is `False`,
and nothing errors — it only blows up when you actually run `--vision`. `4-venv.ps1` is written in exactly this order, and after installing it reads back
`torch.__version__` / `torch.version.cuda` / `cuda.is_available()` and
`find_spec('tensorfold.vision.native_helper')`; it doesn't count as done until everything is green.

### 6.2 Structural differences (six of them, which dictate every rewrite that follows)

| Dimension | Linux original | Windows version |
|---|---|---|
| Runtime carrier | `docker run -d --gpus all --ipc=host --network host` | `Start-Process tensorfold-native.exe`, running directly on the host |
| Model path | HF cache snapshot mounted at `/root/.cache/huggingface`, passed as a `/root/...` path | a local directory (menu item 6), `MODEL_PATH` passed directly, written into the recipe's `.env` by `1-install-ps1.ps1` |
| Logs | `docker logs -f` (one stream) | two files `serve-*.out.log` / `serve-*.err.log`, polled with `StreamReader` |
| Single-instance protection | `flock -n 8` exclusive lock file | pid file + port-listening probe (`flock` has no Windows equivalent) |
| Stop | `docker stop -t N` then `docker rm -f` | `Stop-Process -Force` + poll until deadline; then hunt orphans by exe path / LISTEN socket |
| Pre-check "are the arguments valid" | `docker run --rm ... serve /nonexistent`, running the engine once | run it once directly via `& $env:ComSpec /c "exe serve /nonexistent ..."` |

### 6.3 Item-by-item rewrite mapping

| Bash | PowerShell 5.1 |
|---|---|
| `set -euo pipefail` | `$ErrorActionPreference = 'Stop'` (**note**: native-program stderr is treated as an error, see §6.6) |
| `cd "$(dirname "$(readlink -f "$0")")"` | `Set-Location $PSScriptRoot` |
| `source ./scripts/config.sh` | `. (Join-Path $PSScriptRoot 'scripts\config.ps1')` + `$script:SelfName = 'start.ps1'` |
| `usage() { awk 'NR>1 && /^#/...' "$0"; }` | read the script's own `<# ... #>` comment block, then `-replace '^# ?',''` |
| `(( 1 <= 12 ))` arithmetic test | `[int]` conversion + `-lt/-gt/-eq/-in` |
| `"${!name}"` indirect expansion | `[Environment]::GetEnvironmentVariable($name, 'Process')` |
| `export FOO=1` (for child processes) | `[Environment]::SetEnvironmentVariable('FOO','1','Process')` |
| `env \| grep -E '^(TENSORFOLD\|TF_FLASHNEXT)_'` to collect `-e` arguments | not needed: the process environment is inherited by child processes anyway (`Set-EnvVar` is the export) |
| `docker run -d` | `Start-Process -PassThru -WindowStyle Hidden -RedirectStandardOutput/Error` |
| `docker logs -f` in the background + `kill $LOGS_PID` | two `[System.IO.StreamReader]` polling loops + `try/finally { Dispose() }` |
| `trap './stop.sh' INT TERM` | `try { ... } finally { ... }` (no signals to trap; only the exit path can be guaranteed) |
| `docker inspect -f '{{.State.Running}}'` | `Get-ServerPid` (pid file + liveness check via `Get-Process -Id`) |
| `ss -ltn "sport = :$PORT"` | `Get-NetTCPConnection -LocalPort $Port -State Listen`, with a `TcpClient` fallback on exception |
| `awk '/^MemAvailable:/' /proc/meminfo` | `FreePhysicalMemory` (KB) from `Get-CimInstance Win32_OperatingSystem` |
| `nvidia-smi --query-compute-apps=pid,used_memory` | `--query-gpu=memory.used,memory.free` (per-process is always `[N/A]` under WDDM) |
| `hostname -I \| awk '{print $1}'` | `Get-NetIPConfiguration` → `IPv4Addresses[0]` |
| `curl -s --max-time N URL` | `Invoke-RestMethod` (routed uniformly through `Invoke-LocalRest`, see §5) |
| `python3 -c 'json.load(...)'` to pull a field | `ConvertFrom-Json`, then `.data[0].id` directly |
| `mkdir -p` | `New-Item -ItemType Directory -Force` |
| `SECONDS` | `[System.Diagnostics.Stopwatch]::StartNew()` → `.Elapsed.TotalSeconds` |
| `$'\033[1;35m'` ANSI | `Write-Host -ForegroundColor Magenta` |
| `date +%Y%m%d-%H%M%S` | `Get-Date -Format 'yyyyMMdd-HHmmss'` |
| `$(cmd)` command substitution | `& $exe args` / `$(& $exe args)`; for text assembly use `-f` or an `@''@` here-string |

### 6.4 Memory and GPU metrics: the semantics must change

`/proc/meminfo`'s `MemAvailable` has **no counterpart** on this unified-memory machine:
`Win32_OperatingSystem.FreePhysicalMemory` reflects only the roughly 30 GiB on the system side, while the weights and KV come from the driver's 98 GiB GPU pool.
Copying the Linux threshold (`WEIGHTS + KV + slack + floor + 2`) yields a false alarm of "out of memory, refuse to start".

The three reworked metrics:

1. **The startup threshold counts only the host side**: `need - WEIGHTS - KV - floor`, and it **warns without blocking**.
2. **The floor line during loading warns but never kills the process**: the Linux version ran `docker stop` and failed when
   `a < MEM_FLOOR_GIB`; the Windows version warns once the first time it drops below (`$floorWarned`), because the engine keeps its own backstop via
   `TENSORFOLD_MEMORY_RESERVE_GIB`, and the system-side number naturally drops to 2 GiB during loading (normal; observed `only 2 GiB host memory left while loading`).
3. **The heartbeat switches to total GPU memory**: `Get-GpuMemSummary` aggregates `nvidia-smi --query-gpu=memory.used,memory.free`,
   because under WDDM `used_memory` from `--query-compute-apps` is `[N/A]` and per-process accounting yields no numbers.

```powershell
function Get-MemAvailableGiB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [int][Math]::Floor($os.FreePhysicalMemory / 1MB)   # KB → GiB
}
```

### 6.5 `.env` and variable-export differences (important)

Both sides read the recipe root's `.env` (`KEY=value`, `#` comments, optional quotes, **read only, never executed**), but the PS version has one deliberate hardening:

```powershell
# config.ps1: keys from .env "override directly", instead of "set only if absent from the environment"
Set-EnvVar $key $val
```

Reason: the dot-sourced `config.ps1` leaves the previous run's `Set-EnvVar` values in the **same shell**, so the Linux
"environment first, `.env` only fills gaps" semantics would let stale defaults end up overriding the file. Also, because **every key**
in `.env` gets exported, engine-side switches (`TENSORFOLD_LOAD_STATS`, `TENSORFOLD_MEMORY_RESERVE_GIB`, etc.)
reach the child process simply by being written into `.env` — this is where the §3.3 pitfall came from.

One more difference that **used to be wrong; fixed 2026-10-28**: `config.sh` exports 25 engine variables, but `config.ps1` at the time explicitly exported
only 11, missing 17 `TF_FLASHNEXT_*`. The original judgment was "the rest fall back to engine defaults, and both sides' defaults are the same set anyway" —
**that was wrong**. The engine treats any unset variable as **off** (or its factory rule), while the recipe exports all `1`s:

| Variable | Engine, when unset | Recipe |
|---|---|---|
| `GATHER_EARLY` / `SAMPLE_CAND` / `SHARED_SIDE` / `GDN_LANES` / `KEEP_LATE` | `false` / `.off` | `1` |
| `PROMPT_HC2` / `PROMPT_SHARED_DIRECT` / `PROMPT_GEMM2` / `DRAFT_AHEAD` / `WARM_AHEAD` | `false` | `1` |
| `HEAD_PIECE` | `256` | `1536` |
| `PREFILL_TAIL` | `0` | `512` |
| `CONFIDENCE` | `0.6` (per-draft floor) | `-0.4` (cumulative product ≥ 0.4) |
| `SAMPLED_HEADS` | `false` | `1` |
| `HOST_DRAW_THREADS` | `0` (auto) | `7` |
| `GATHER_READ` | mapped page faults | `pread` |

The consequence is not "slightly different behavior" but **a fundamentally different engine running**: unset switches send the engine down fallback paths
(`GATHER_READ` unset falls back to mapped pages, `CONFIDENCE` uses the 0.6 per-draft floor, the whole `PROMPT_*` family is off),
so completing the exports is a matter of **correctness**, not tuning. The current `config.ps1` exports 21 `TF_FLASHNEXT_*`
variables, in one-to-one correspondence with `config.sh`, each still overridable by `.env`.

After completing them, one note suffices: **the +14% / 15–25% figures in the recipe README are numbers from its own Linux image**, which cannot be taken as expectations under WDDM;
every performance number on this page comes from sparkDash measurements (see the README and `docs/bench/`).

**Acceptance procedure** (do it once on every new machine):

```powershell
# Extract from both sides and diff; what remains should only be items that are intentional
grep -oE "^export (TF_FLASHNEXT|TENSORFOLD)_[A-Z0-9_]+" scripts/config.sh | sed 's/^export //' | sort > sh.txt
grep -oE "Set-EnvVar '[A-Z0-9_]+'" scripts/config.ps1 | sed "s/Set-EnvVar '//;s/'//" | sort > ps.txt
diff sh.txt ps.txt
```

A cautionary counterexample to record along the way: `TF_FLASHNEXT_DEPTH` **does not exist** in the engine (only `TF_FLASHNEXT_DEPTH_LOG`); a mistyped variable name
produces no error at all and simply does nothing silently — what controls draft length is `TF_FLASHNEXT_DRAFTS`.

### 6.6 PowerShell 5.1 syntax landmines (guaranteed to be stepped on when writing scripts)

1. No `&&`, `||`, ternary `?:`, or `??`. Use `; if ($?) { }` or `if/else`.
2. `$Host` is an automatic variable and cannot be used as a custom variable (the recipe uses `$BindHost` for exactly this reason).
3. `2>&1` against a native program pollutes `$?`; check exit codes with `$LASTEXITCODE`.
4. `"$var:"` is parsed as a drive reference (`$cand:` errors with "invalid variable reference"); use `${var}:`.
5. A native program writing to stderr is treated as a `NativeCommandError`, and under `$ErrorActionPreference='Stop'` it **aborts the script outright**.
   `tf-cuda-test info`, `git`, and `nvcc` all behave this way — judge by text and `$LASTEXITCODE`, not `$?`.
6. `SetEnvironmentVariable($n, $null)` does not necessarily really delete; it may leave an empty string; and the engine treats "present but empty" as an invalid value
   (`TENSORFOLD_CUDA_KERNELS= holds no aot.json`), so **give an explicit value instead of deleting the variable whenever possible** (give `native`).
7. Don't detect the architecture with `$env:PROCESSOR_ARCHITECTURE` (reports x86 under WOW64); use
   `[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture`.

### 6.7 Why `prepare.sh` has no counterpart

What `prepare.sh` does: pull the base image → download zig → patch → compile zig/CUDA → install two image-decoding libraries → download the weights →
`docker build` with a tag (the tag embeds the patch hashes, used to decide "is the image stale").

On Windows there is no container layer, so "prepare" degenerates into a few independent things, which are the six steps in the skill's `scripts\engine\`
(on the recipe side there is only `scripts\recipe\1-install-ps1.ps1`, a single job: drop in the `.ps1` files):

| What the original `prepare.sh` did | How it's done on Windows |
|---|---|
| Pull image / `docker build` | not needed; compile the native exe directly |
| Download zig + verify sha256 | install zig 0.17.0 by hand (the skill's `1-preflight.ps1` checks the version) |
| `git clone` + apply 17 patches | `2-clone.ps1` + `3-apply-patches.ps1` (the three merged patches) |
| Compile CUDA / zig | `5-build.ps1` (runs `zig build` inside `cmd /c` + `vcvarsall arm64`) |
| Install libjpeg-turbo / libwebp | not needed: `turbojpeg.dll` / `libwebpdecoder.so.3` already sit next to the exe |
| Download the weights (HF snapshot) | `hf download nvidia/Qwen3.8-Flash-Next-FP4-Local --revision b9ce18a6… --local-dir <model dir>`; in China the ModelScope mirror works too: `modelscope download --model nv-community/Qwen3.8-Flash-Next-FP4-Local --local_dir <model dir>` (the `<model dir>` is menu item 6, and it is written into the recipe `.env`'s `MODEL_PATH`) |
| Install torch (free inside the image) | `4-venv.ps1`: create a `venv` in the **recipe directory**, torch first then `tensorfold[vision]`, see §6.1.1 |
| Image tag as the "staleness criterion" | there are no images anymore → replaced by `3-apply-patches.ps1`'s 78 items and the exe timestamp |

---

## 7. Acceptance checklist (command level)

```powershell
# 0) Pin the paths down first (once only; afterwards all scripts read the same .migration.local.json)
powershell -ExecutionPolicy Bypass -File <skill>\scripts\Invoke-Migration.ps1 -Reset
#    → six numbered lines: root / python / zig / cuda / vcvars / model; d re-probes, ? browses, Enter accepts
#    Below, the chosen root is written as <root> (shaped like D:\llm\latest); the engine directory is fixed at <root>\TensorFold

# 1) Are all patches applied (should list three, both spot-checks green). Below, <skill> = the skill directory
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\3-apply-patches.ps1 -TensorFold <root>\TensorFold
git -C <root>\TensorFold status --porcelain --untracked-files=all | Measure-Object | % Count   # expect 78

# 2) Did it build
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\5-build.ps1 -TensorFold <root>\TensorFold   # BUILD_EXIT=0
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\6-smoke.ps1                                # three OKs

# 3) Is the venv in place (only needed for vision; skippable if you don't run --vision)
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\4-venv.ps1     # should end with cuda True
Test-Path <root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\venv\Scripts\python.exe   # True

# 4) Are the recipe side's four .ps1 files installed (this is the only step that writes to the recipe directory)
powershell -ExecutionPolicy Bypass -File <skill>\scripts\recipe\1-install-ps1.ps1
git -C <root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold status --porcelain   # only ??, no " M"

# 5) Is loading fast now (run in the recipe directory)
cd <root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
$env:TENSORFOLD_LOAD_STATS='1'; .\start.ps1       # expect server answered after ~71s

$err = Get-ChildItem build\logs\serve-*.err.log | Sort-Object LastWriteTime | Select-Object -Last 1
(Get-Content $err -Encoding Default | Select-String 'layer \d+ took').Count        # 48
Get-Content $err -Encoding Default | Select-String 'stage wait' | Select-Object -Last 3   # 0-50 ms per group
# Equivalent in Git Bash: grep -a "layer .* took" build/logs/serve-*.err.log | wc -l

# 6) Were the weights loaded correctly
#    POST /v1/chat/completions "Answer with one word: capital of France" → Paris

# 7) Wrap up
.\stop.ps1                                   # Stopped; its GPU memory is free again
```

---

## 8. Appendix: the three patches and their hashes

```
c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad  0001-recipe-0001-0017-on-v1.1.4.patch   74 files / 9380 lines / 495 KB
9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40  0002-windows-arm64-port.patch           5 files /  158 lines / 9 KB
911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64  0003-load-pipeline.patch                4 files /  441 lines / 21 KB
```

Companion material: the `tensorfold-windows-arm64-migration` skill (`SKILL.md` chapter 4 = patching, chapter 8 = load pipeline,
`references/build-notes.md` chapter 5 = design trade-offs, `references/verification.md` section 6 = measured evidence).
