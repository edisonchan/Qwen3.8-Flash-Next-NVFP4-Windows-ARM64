# TensorFold v1.1.4 + Qwen3.8-Flash-Next：Windows ARM64 打补丁与移植实录

这份文档记录三件事，按我们实际动手的顺序：

1. **打补丁**：怎么把"配方 17 个补丁 + Windows 兼容修复"压成可复现的三份补丁，每份怎么切、怎么验、怎么回滚。
2. **修掉的问题**：重点是**模型加载 257 s → 71 s**（怎么定位、改了什么、撞了哪些编译坑、怎么证明没改坏），
   以及内存准入、PowerShell 5.1 那两个让 `start.ps1` 永远报"未就绪"的真 bug。
3. **`.sh` → `.ps1` 的改写**：Docker → 原生进程、容器日志 → 两个日志文件、`/proc/meminfo` → Win32、
   bash 习惯 → PowerShell 5.1 等价物，逐条对照。

环境：Windows 11 ARM64 / RTX Spark N1X（GB10，sm_121，20 核，48 SMs）/ CUDA 13.4 / zig 0.17.0 / MSVC v143 ARM64。

---

## 0. 结论速览

| 项 | 值 |
|---|---|
| 引擎 | `ashhart/TensorFold` @ `eab8582819688325e371907e4706e1c602b8a273`（tag v1.1.4） |
| 配方 | `MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold` @ `fd3f43e11238553685ebb68b6d8ab2b112818e3c`（其 `patches/0001..0017`） |
| 权重 | `nvidia/Qwen3.8-Flash-Next-FP4-Local` @ `b9ce18a6887e18c089fdea8509a33e63429a3300`（`modelopt`/`MIXED_PRECISION`，96 GB，**唯一受支持**） |
| 工具链 | zig 0.17.0（aarch64-windows）· CUDA 13.4（`V13.4.92`）· MSVC 14.44.35207 arm64 · Windows 11 ARM64 build 10.0.28000 |
| 补丁 | `0001`（配方 0001–0017 合并）→ `0002`（Windows/MSVC 5 处）→ `0003`（加载流水线），**顺序不能换** |
| 工作树 | 78 项变更 = 59 修改 + 19 新增 |
| 产物 | `TensorFold\build\native\bin\tensorfold-native.exe`（PE32+ ARM64，36 MB）、`tf-cuda-test.exe`（75 MB） |
| 冷构建 | 5–8 分钟（`cmd /c` + `vcvarsall arm64` 内跑 `zig build native install -Dsm=121`） |
| 模型加载 | 原生 257 s → **71 s**（引擎自报 `loaded in 67.6s`） |
| 起服 | `.\start.ps1` → `server answered after 71s` → 冒烟 `OK` |

> 版本只有一个权威来源：[`VERSIONS.md`](../VERSIONS.md)。每处钉住的理由、挪动会坏在哪、核对命令都在那里；
> 本文所有数字都对应上表这一组合。

---

## 1. 全流程一页图

| 阶段 | 动作 | 产物 / 判据 |
|---|---|---|
| ⓪ 路径 | `migration.config.ps1` 探测 + 选单（root/python/zig/cuda/vcvars/model），存 `.migration.local.json` | 六行全绿 |
| ① clone | `git clone` 引擎 + 配方，引擎检出 `eab85828` | `git rev-parse HEAD` |
| ② 打补丁 | `0001` 配方改造 → `0002` Windows 兼容 → `0003` 加载流水线 | `git status` 78 项，两份 spot-check 绿 |
| ③ 构建 | `cmd /c` + `vcvarsall arm64` 内跑 `zig build native install -Dsm=121` | `tensorfold-native.exe` 36 MB、`tf-cuda-test.exe` 75 MB |
| ④ venv（可选） | `--vision` 才需要；torch 从 NVIDIA OOT 索引，再装 `tensorfold[vision]` v0.6.6 | `find_spec('tensorfold.vision.native_helper')` 返回 0 |
| ⑤ 配方侧 | `recipe/1-install-ps1.ps1`：放 4 个 `.ps1`，写 `MODEL_PATH` 进 `.env` | 配方 `git status` 只有 `??`，无 ` M` |
| ⑥ 起服 | `.\start.ps1`（配方目录） | `server answered after 71s` + 冒烟 `OK` |
| ⑦ 收工 | `.\stop.ps1` | `Stopped; its GPU memory is free again` |

`prepare.sh`（拉基础镜像、编 Docker 镜像、下权重）在 Windows 上没有对应物：没有容器这一层，
权重是本地目录，"准备"= ① clone + ② 打补丁 + ③ 构建 + venv（见 §6.7）。

### 1.1 两条线：engine 与 recipe

| | 仓库 | 脚本 | 动什么 |
|---|---|---|---|
| engine | `ashhart/TensorFold` | `scripts/engine/1-preflight … 6-smoke` | 三份补丁 + 构建，产出 `tensorfold-native.exe` |
| recipe | `MiaAI-Lab/Qwen3.8-Flash-Next-…` | `scripts/recipe/1-install-ps1.ps1` | **只加文件**：4 个 `.ps1`，`.env` 里的 `MODEL_PATH` |

配方的源码一行不改——这是刻意的。`1-install-ps1.ps1` 结束前自己验一遍：`git -C <配方> status --porcelain`
应当只有 `??`（新增），没有 ` M`（修改）。`start.ps1`/`stop.ps1` 落在配方根，`config.ps1`/`banner.ps1`
落在 `scripts\`，与 `.sh` 原件并排，随时可以删掉 `.ps1` 退回 shell 版。

### 1.2 路径不写死

起初文档和脚本里到处是 `D:\llm\latest`——换台机器、换个盘就全崩。现在路径只有一个来源：
`scripts/migration.config.ps1`。

- **探测**：root 取本仓库所在目录（同级就是两个克隆的位置）；python 取 `PATH` → `%LOCALAPPDATA%\Programs\Python`
  → `%ProgramFiles%`；zig 取 `PATH` → root 及其上级的 `zig*` 目录；CUDA 取 `CUDA_PATH` → toolkit 安装根（要求有
  `bin\nvcc.exe`）；vcvars 取任意 VS 2022 安装；权重取 `MODEL_PATH` → `<root 的上级>\model\<name>`。
- **选单**：六行编号，回车接受，数字改那一行，`?` 弹目录选择框，`d` 重新探测。接受前逐项校验
  （zig 必须 0.17.0、nvcc 必须 13.4、python 必须 3.11+ 且 aarch64、权重必须 `modelopt`/`MIXED_PRECISION`），
  有硬伤要求二次确认——否则失败会推迟到三步之后。
- **固化**：确认结果写 `.migration.local.json`（git 忽略），此后每个脚本 `Get-MigConfig -Quiet` 读它，
  再没人问第二遍。删掉它就等于"重新探测"。显式参数（`-Zig`、`-TensorFold`…）永远优先。

引擎目录与配方目录不可选：配方自己的 `config.ps1` 就是这么找同级引擎的（`<配方父目录>\TensorFold\build\...`），
所以只有 root 是一个选项。

---

## 2. 打补丁步骤

### 2.1 为什么不能直接 apply 配方那 17 个补丁

配方 `TF_REF` 钉的是 v1.1.4 的 `eab85828`，但 `patches/0001..0017` 是按更早的 `db281878` 生成的。
两者之间 `cuda_prompt*.zig`、`cuda_mtp*.zig`、`cuda_ple*.zig` 等都被上游改过，直接顺序 apply
会**有 11 处冲突**，需要人工三方裁决——**裁决结果没法用文本表达，也就没法复现**。

做法：在一份干净克隆上把 17 个补丁 `git apply --3way` 打完、人工裁决冲突，得到"**目标树 A**"；
再开一份干净克隆（**原始树 B** = `eab85828`），把 A 里所有变更文件覆盖到 B，`git add -A`，
`git diff --cached HEAD > 0001-...patch`。这份合并补丁就是"那次人工裁决的最终正确结果"，
`git apply` 一次、确定性、可逐字节复现。

> 代价：补丁 495 KB / 9380 行。收益：从零 clone 到可构建树只需要一条命令，不需要再裁决任何冲突。

### 2.2 0001：配方改造（74 文件 / 9380 行）

```powershell
git -C TensorFold checkout --detach eab8582819688325e371907e4706e1c602b8a273
git -C TensorFold apply --check <skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch
git -C TensorFold apply       <skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch
```

它带进来的是配方对引擎的**性能改造**（fp4 引擎、系统内存缓存、双 rank、serving、prompt-expert-tile、
fair-prefill、vision python 等），这些不是本文档的重点，但**必须全在**，否则加载路径都会不一样
（例如 0014 的 prompt-expert-tile 会改变专家在 prompt 阶段的用法）。

### 2.3 0002：Windows/MSVC 兼容（5 文件 / 158 行）

只解决"编不过"，**没有一处改 kernel 算术**。

| # | 文件 | 症状 | 改动 | 为什么 |
|---|---|---|---|---|
| 1 | `zig/kernels/cuda/qmm_prefill.cu` | `no instance of function template "prefill_kernel" matches the specified type` | 两个显式实例化的形参加 `__restrict__` | MSVC 要求显式实例化的参数类型与模板定义**逐字匹配**（含限定符）；GCC/clang 忽略 `__restrict__`，所以上游 Linux 能编 |
| 2 | `prefill_attention.cu` | 同上（hpattn / hpattn8） | 同上 | 同上 |
| 3 | `gdn_prefill.cu` | 同上（chain_kernel） | 同上 | 同上 |
| 4 | `cuda_ple_reader.zig` | `type 'void' does not support struct initialization syntax` | 匿名 `mmap` 在 Windows 分支改走 `page_allocator.alignedAlloc`；Linux 路径一字不改 | Windows 目标下 `std.posix.MAP` 是 `void`，匿名映射不存在；`PageAllocator` 底层就是 `VirtualAlloc`，同样匿名/清零/按需提交 |
| 5 | `cuda_ple.zig` | `parameter of type 'void' not allowed in function with calling convention 'aarch64_aapcs_win'` | `Stat.now()` 改用 `std.Io.Clock.awake.now(io)`；`Ngram` 增加 `io` 字段 | 该 zig 版本已删 `std.posix.clock_gettime`；Windows 上 `std.c.CLOCK` 是 `void`；`Io.Clock` 由 std 在 Windows 上用 QPC 实现 |

`qmm_prefill.cu` 不在 0001 的 74 个文件里：上游 v1.1.4 原文就没写 `__restrict__`，配方补丁也没碰它，
所以这是**纯粹的 MSVC 兼容问题**，与配方无关。

### 2.4 0003：加载流水线（4 文件 / 441 行）

这份补丁不是相对 v1.1.4 切的，而是相对"**0001+0002 已应用**"的树切的——其中 `cuda_prompt.zig`、
`cuda_prompt_wt.zig` 在 0001 里已经改过，直接对 v1.1.4 切会把 0001 的改动算进来。

切法（可照抄）：

```bash
# 1) 造一个"0001+0002 之后"的基线，并固定住
git -C TensorFold worktree add --detach <tmp> eab8582819688325e371907e4706e1c602b8a273
git -C <tmp> apply <skill>/patches/0001-...patch
git -C <tmp> apply <skill>/patches/0002-...patch
git -C <tmp> commit -a -m 'baseline: 0001+0002'

# 2) 把要保留的加载改动覆盖进去，diff 出来即最小增量
cp <生产树>/{nvfp4_slice.zig,cuda_modelopt_experts.zig,cuda_prompt_wt.zig,cuda_prompt.zig} <tmp>/<对应路径>
git -C <tmp> diff > 0003-load-pipeline.patch      # 4 files, +273 -35

# 3) 用同一棵树验：复位成裸 eab85828，再按 0001→0002→0003 打一遍
```

验证结果（`git status --untracked-files=all` = 78 项，4 个文件与生产树 sha256 全一致）：

```
0001 sha256 c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad  applied
0002 sha256 9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40  applied
0003 sha256 911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64  applied
tree now: 59 files changed, 3783 insertions(+), 193 deletions(-)
```

### 2.5 应用顺序、回滚

```powershell
# 应用（脚本按文件名排序，天然是 0001 → 0002 → 0003）
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\3-apply-patches.ps1 -TensorFold <root>\TensorFold

# 回滚
git -C <root>\TensorFold reset --hard eab8582819688325e371907e4706e1c602b8a273
git -C <root>\TensorFold clean -fd   # 0001 新增的 19 个未跟踪文件
git -C <root>\TensorFold status --porcelain # 应为空
```

**顺序不可换**：0003 的上下文里有 0001 改过的行。手工 apply 时反了会直接 `--check` 失败（好事，不会半残）。

---

## 3. 修掉的问题之一：模型加载 257 s → 71 s

这是最值得写清楚的一节。**四分钟里没有一秒钟花在 CUDA 上**，全部在 host 侧。

### 3.1 先排除三个"合理怀疑"

| 怀疑 | 实测 | 结论 |
|---|---|---|
| 磁盘慢（81 GiB 权重） | 顺序读 5.0 GB/s | 不是 IO |
| PCIe / 拷贝带宽不够 | 单次 HtoD 20+ GB/s | 不是 DMA |
| CUDA kernel 有问题 | 加载期 GPU 利用率很高，但**全是拷贝**、没有 kernel 在跑 | 不是 kernel |

三条都能用一条命令否掉，先做这一步很划算——否则会去翻 fatbin 和 `-gencode`，那是死路。

### 3.2 真正的根因：v1.1.4 的加载路径是"现场装配"

v1.1.4 的 Flash Next CUDA 路径**没有预量化缓存**：每层都从原始 safetensors 读 NVFP4 专家，
现场重排成引擎要的布局再上传。旧实现（`cuda_modelopt_experts.zig` 的 `loadShape`）是：

```zig
for (0..512) |i| {                                            // 一层 512 个专家
    var gate   = try readPart(a, store, "…gate_proj", ...);   // 小拷贝 1
    var value  = try readPart(a, store, "…up_proj",   ...);   // 小拷贝 2
    var output = try readPart(a, store, "…down_proj", ...);   // 小拷贝 3
    ex.packGateUp(...); ex.packOne(...);                      // 单线程重打包
    try up.upload(); try down.upload();                       // 每次 upload 后 stream.synchronize()
}
```

一层 = 512 × 3 = 1536 次小拷贝 + 512 次同步；48 层 = 24576 个专家。但真正把时间放大到 4 分钟的是三个隐含成本：

| 放大器 | 具体 | 代价 |
|---|---|---|
| **串行** | 一次只有一个核在打包；CPU 打包与 DMA 完全互斥 | 20 核只用 1 核 |
| **映射缓存只有 2 槽** | `Store.released: [2]Held`，而**一层专家散在 14 个 shard 里** | 每层反复 close/reopen 分片、重新解析头部（全模型头 50.6 MB，单文件最大 9.3 MB） |
| **逐行 memcpy** | `core/nvfp4_slice.zig` 的 `slice()` 一行一次 `@memcpy` | 一层几千行，占读耗时约 1/3 |

Windows 上第二个放大器更贵：`cuda_ple_reader.zig` 的 Windows 分支用 `PageAllocator`（`VirtualAlloc`）
而不是 `mmap`，分片元数据每次重开都要重新解码一遍，没有 page cache 兜底。

### 3.3 解决步骤（按实际动手顺序）

**第 1 步：先埋点，别先改。** 没有分段数据就只能靠猜。在 `fill()`（原来逐专家循环所在处）加三个累计计数器：
`pack`（打包墙钟）、`stage wait`（等 stage 可用）、每层总耗时：

```zig
const threads = @max(1, @min(envNumber("TENSORFOLD_LOAD_THREADS") orelse (std.Thread.getCpuCount() catch 4), max_threads));
const group   = @min(@max(envNumber("TENSORFOLD_LOAD_GROUP") orelse stage_default, 1), count);
if (stats) std.log.info("flashnext: {d} experts in {d} groups of {d} on {d} threads: pack {d} ms, stage wait {d} ms, {d} MiB",
    .{ count, g, group, threads, packed_ns / 1_000_000, waited_ns / 1_000_000, (up_bytes + down_bytes) * count >> 20 });
```

> **坑**：变量名必须是 `TENSORFOLD_` 前缀。`scripts\config.ps1` 只把 `.env` 里出现的 key 导进进程环境，
> 写 `TF_LOAD_STATS` 会静默失效（我第一版就是这么白跑一轮的）。日志落在 `build\logs\serve-*.err.log`
> （`info:` 行，stderr），不是 `.out.log`，且含 NUL 字节，要 `grep -a` 或 `Get-Content -Encoding Default`。

**第 2 步：把映射缓存从 2 槽扩到 48 槽，并让它线程安全。** 一层跨 14 个分片，48 槽够放三层，
整层加载期间不再 close/reopen。并行读之后 `Store` 会被多线程同时借用，三处必须处理：

```zig
pub const cached_shards: usize = 48;
mtx: std.Io.Mutex = .init,          // zig 0.17 已删 std.Thread.Mutex

// 1) 借用簿记串行化，但 IO 在锁外（锁只护几十字节的指针记录）
self.mtx.lockUncancelable(self.io);
defer self.mtx.unlock(self.io);

// 2) 槽满时把"已归还"的映射扫进缓存，绝不 close 正在借出的映射
if (self.nheld == self.held.len) self.releaseLocked();

// 3) 48 层读完后一次性释放（回收约 0.6 GB 解析过的头部）
pub fn dropShards(self: *Store) void { ... releaseLocked(); closeFileLocked(); closeReleasedLocked(); }
```

**第 3 步：分组并行 + pinned 双缓冲 + 事件回压。** 这是提速主力。512 个专家切成 32 组 × 16 个，
两组 stage（A/B）交替：一组在打包，另一组正在被 DMA 读，谁都不用等谁。

```
时间轴 ─────────────────────────────────────────────────────────────▶
打包(20线程)  [组1 ][组2 ][组3 ][组4 ] ...   每组约 22 ms
异步DMA           [1]  [2]  [3]  [4]  ...    每组约 2 ms，整个落在下一组的打包窗口里
```

要点四条，缺一条收益就掉：

- **按"组"切，不按"专家一线程"**：DMA 投递有固定开销，一次 42 MiB 的拷贝远优于 16 次 2.6 MiB；
  逐专家投递会产生 1536 次 ioctl/层，开销比数据本身还大。
- **原子取号，不做静态分片**：512/20 不整除，静态分片会出现 26 : 22 的长尾；取号让跑得快的线程多干。
- **pinned 是硬要求**：`cuMemHostAlloc`（`cuda.HostBuffer`）拿 page-locked 内存。普通可分页内存调
  `cuMemcpyHtoDAsync`，驱动会退回"临时固定缓冲 + 同步拷贝"，双缓冲白做。
- **event 回压不能省**：每个 stage 一个 `cuda.Event`，复用前 `synchronize()`。少了它，下一组会覆写
  正在被 DMA 读的 stage；只用一次 `sync` 又会让 20 个线程集体卡住。

```zig
const Job = struct {
    next: std.atomic.Value(usize) = .init(0),   // 抢号
    stop: std.atomic.Value(bool)  = .init(false),  // 一个失败，全部收手
    fn pack(self: *Job, i: usize, a: std.mem.Allocator) !void { ... }
};

fn enqueue(d: *const cuda.Driver, dst: u64, src: []const u8, stream: cuda.abi.Stream) !void {
    if (src.len == 0) return;
    try d.check(d.api.cuMemcpyHtoDAsync_v2(dst, @ptrCast(@constCast(src.ptr)), src.len, stream), "cuMemcpyHtoDAsync");
}
```

**第 4 步：整块 memcpy。** `slice()` 里加一个整宽判定，几千次 `@memcpy` 变一次：

```zig
const whole = inputs.from == 0 and inputs.to == d.k;
if (whole) {
    @memcpy(codes[0 .. n * (d.k / 2)], source.weight.bytes[rows.from * (d.k / 2) ..][0 .. n * (d.k / 2)]);
} else for (0..n) |row| { ...逐行... };
```

**第 5 步：加载完把映射全部放掉**（`dropShards()`），否则 0.6 GB 头内存一直挂着。

### 3.4 顺手撞到的 4 个 zig 0.17 编译坑

| 报错 | 原因 | 改法 |
|---|---|---|
| `root source file struct 'Thread' has no member named 'Mutex'` | 0.17 删了 `std.Thread.Mutex` | 用 `std.Io.Mutex = .init`，`lockUncancelable(io)` / `unlock(io)` |
| `expected type 'u64', found 'i96'` | `Clock.Timestamp.toNanoseconds()` 返回 **i96** | `@intCast(u64)`；外层再 `@as(u64, @intCast(...))` |
| `expected type '[]u32', found '[]align(1) u32'` | `bytesAsSlice(u32, []u8)` 得到 1 字节对齐 | 先 `const w: []align(4) u8 = @alignCast(slot);` 再 `bytesAsSlice(u32, w)` |
| `expected type 'mem.Allocator', found '*const driver.Driver'` | 我把 `loadShape(store: anytype)` 强转成 `*wt.Store`，破坏了测试用的内存 mock | 每专家逻辑收进 `packExpert(store: anytype)`；并行只在 `@TypeOf(store) == *wt.Store` 时启用，mock 走串行 |

### 3.5 怎么证明"快得没把权重装错"

并行 + 复用缓冲最容易出的错是**静默错位**：模型照样起得来、`/health` 照样 ok、输出是胡话。所以做了三层：

1. **回归护栏**：`loadShape` 只在 `@TypeOf(store) == *wt.Store` 时走并行，单元测试的内存 mock 仍走原串行路径；
   `fill()` 里任何分配失败都打 warn 自动退回 `serial()`，不会让加载整体失败。
2. **确定性问答**：`capital of France` → `Paris`。比只看 `/health` 有效得多。
3. **指标判读**：`stage wait` 是"双缓冲够不够"的唯一直接指标，实测合计 0.87 s / 67.6 s；哪天它涨到 5%，
   先怀疑组太小（调 `TENSORFOLD_LOAD_GROUP`），而不是去改 CUDA。

### 3.6 结果

| 项 | 原生 v1.1.4 | 打 0003 之后 |
|---|---|---|
| 整机加载 | 257 s | **71 s**（引擎自报 67.6 s） |
| 每层 | 约 5.0 s | **1.12 s** |
| 拷贝等待 | 每层 3 次全同步 | **18 ms/层**（合计 0.87 s，占 1.3%） |

48 层分段（`TENSORFOLD_LOAD_STATS=1`）：

```
layer N took   n=48  sum=53564 ms  mean=1116  median=1130  min=886  max=1275
pack           n=49  sum=34222 ms  mean= 698  median= 706  min=527  max= 793
stage wait     n=49  sum=  871 ms  mean=  17.8 max=   49
```

- `pack` 占 34.2 s = **新的瓶颈**：单专家 3 投影约 27 CPU-ms（698 ms × 20 线程 ÷ 512），20 核已全用满。
- 48 层合计 53.6 s，占总加载 79%；剩下 ~14 s 是 embedding / lm_head / FP8 n-gram 表 / attention 共享权重。
- `pack` 是 49 行不是 48：层循环之后还有一次同样规模的装配（紧跟 prompt-expert tile 初始化），它不计入层耗时。

**还能不能再快**：只有一条路——**跳过重打包**，写一次性工具把 checkpoint 预处理成引擎原生专家 blob
（首次约 10 分钟 + 约 80 GB 磁盘），之后加载退化为纯读 + DMA，估算 20 s。这属于新功能（新增产物、
新增缓存失效逻辑），不要顺手塞进补丁。

---

## 4. 修掉的问题之二：内存准入与 `PARALLEL`

现象：48 层全部加载完之后，进程报错退出，日志最后一行是

```
--parallel 5 needs 23.74 GiB (5 streams at a 262,144-token window); 22.81 GiB left after a 4.0 GiB reserve
```

这不是加载问题，是**准入预算**：整机统一内存只有 30.5 GB（加载前 host 可用 16 GiB），权重 81 GiB 和 KV
都从驱动的 98 GiB GPU pool 里出，引擎再自己留 `TENSORFOLD_MEMORY_RESERVE_GIB`。fp8 KV 每流 4.75 GiB：

| 流数 | KV 需求 | 4 GiB 预留后的预算 | 结果 |
|---|---|---|---|
| 5 | 23.74 GiB | 22.81 GiB | 差 0.93 GiB，加载完才报错退出 |
| 4 | 18.96 GiB | 22.81 GiB | 正常起服 |

处置：`.env` 里固定 `PARALLEL=4`。要 5 流有两条路——把 `CONTEXT` 降到 131072，或者移植旧补丁 0010 的
indexer-key 环形缓存（每流省 ~0.88 GiB）。**注意这个错误只在加载完成后才出现**，看日志时别以为又是加载慢。

---

## 5. 修掉的问题之三：PowerShell 5.1 让 `start.ps1` 永远报"未就绪"

加载变快之后仍报 `the server exited before it was ready`，但日志显示服务明明起来了、手动请求 `/health`
也正常。根因是 `config.ps1` 的健康探测在 PS 5.1 下**每轮都抛异常**，`while` 循环永远等不到 `$ready`。

两个真 bug：

| 症状 | 根因 | 修法 |
|---|---|---|
| `无法发送具有此谓词类型的内容正文` | `param([string]$Body = $null)` 里 `$null` 会变空串，`$null -ne $Body` **恒真**；空 body 走 GET，而 **PS 5.1 的 `Invoke-RestMethod` 默认动词是 POST**（6.0+ 才是 GET），空 body 的 POST 直接被拒 | 用 `[string]::IsNullOrEmpty($Body)` 判空，并且**每个分支都显式传 `-Method`** |
| `找不到与参数名称"NoProxy"匹配的参数` | `-NoProxy` 是 PowerShell 6.0+ 才有的开关 | 5.1 分支改用 `[System.Net.WebRequest]::DefaultWebProxy = $null` 包 `try/finally` |

修好的版本（`scripts\config.ps1`）：

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

顺带两个同源坑：`config.ps1` 已把 `ApiUrl` 映射到 `127.0.0.1`，所以 `HOST=0.0.0.0` 没问题，但
**`0.0.0.0` 不能直接当 HTTP 目标**；另外进程里同时存在 `HTTPS_PROXY` 和 `https_proxy` 时，
`Get-ChildItem Env:` 会抛"已添加了具有相同键的项"，连带 `Start-Process` 失败——启动前把两套名字都清掉：

```powershell
foreach ($n in 'HTTPS_PROXY','https_proxy','HTTP_PROXY','http_proxy','ALL_PROXY','all_proxy') {
    [Environment]::SetEnvironmentVariable($n, $null, 'Process')
}
```

---

## 6. `.sh` → `.ps1` 的改写

### 6.1 文件对照

这四份是**唯一进入配方仓库**的文件，由 `scripts\recipe\1-install-ps1.ps1` 拷贝：

| Linux（配方原版） | Windows（本机） | 说明 |
|---|---|---|
| `start.sh`（259 行） | `start.ps1`（308 行） | 5 步流程一一对应，启动方式从 Docker 换成本机进程 |
| `stop.sh`（24 行） | `stop.ps1`（19 行） | `docker stop/rm` → 按 pid 文件杀进程（含孤儿兜底） |
| `scripts/config.sh`（201 行） | `scripts/config.ps1`（246 行） | 默认值、`.env`、内存/KV 计算、探测辅助函数 |
| `scripts/banner.sh`（28 KB 终端画） | `scripts/banner.ps1`（1.4 KB） | **不复制**画面，运行时用正则从 `banner.sh` 抽 |

剩下这些**留在 skill 目录**，只在需要时被调用一次，不进配方（配方仓库因此保持 `0 modified`）：

| Linux（配方原版） | Windows（本机） | 说明 |
|---|---|---|
| `scripts/prepare.sh`（14.6 KB） | `scripts\engine\` 下 1–6 | 它做的是「拉镜像 + 装依赖 + 下 zig + 打补丁 + 编译 + 下权重 + `docker build`」，Windows 上拆成六个可单独重跑的步骤，见 §1 的流程表 |
| `Dockerfile` 里 `ARG BASE_IMAGE=nvcr.io/nvidia/pytorch:26.07-py3` | `scripts\engine\4-venv.ps1` | **容器自带 torch，本机没有** → 在配方目录里建 `venv` 并装 torch（vision 才需要，见下节） |
| `pip install tensorfold[vision]`（在镜像里做） | 同上，`4-venv.ps1` 第二步 | 先 torch 后 `tensorfold[vision] @ v0.6.6`，顺序不能反 |

### 6.1.1 torch 与 venv：容器里白拿的东西，本机得自己装

Linux 那条路根本没"装 torch"这一步——`nvcr.io/nvidia/pytorch:26.07-py3` 里已经有一份和
CUDA 13.4 对得上的 build。Windows 上没有任何轮子能直接用，所以要在**配方目录**里建 venv：

```
<root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\venv\
```

之所以必须在配方目录，是因为 `recipe\config.ps1` 自己就是这么找的：

```powershell
$VenvDir      = Get-Setting 'VENV_DIR'      (Join-Path $RecipeDir 'venv')
$VisionPython = Get-Setting 'TENSORFOLD_VISION_PYTHON' (Join-Path $VenvDir 'Scripts\python.exe')
```

`start.ps1` 里那一段（`--vision` 时才走）：

```powershell
if (-not (Test-Path $VisionPython)) { Die "vision is on but the venv python is missing: $VisionPython (set VENV_DIR or VISION=0)" }
& $VisionPython -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
Set-EnvVar 'TENSORFOLD_VISION_PYTHON' $VisionPython
```

所以 `venv` 默认落在配方目录；真要搬走，`.env` 里给 `VENV_DIR` 就行（`start.ps1` 会跟着改
`TENSORFOLD_VISION_PYTHON`），但 `4-venv.ps1` 的默认值也是这个位置，两边别改岔了。

两条命令，**顺序不能换**：

```powershell
# 1) torch 必须走 NVIDIA 的 nightly 索引，PyPI 上的 arm64 wheel 对不上 CUDA 13.4
python -m pip install --pre --upgrade --only-binary=:all: `
  --extra-index-url 'https://pypi.nvidia.com/nvtorch_oot_nightly' torch torchvision torchaudio

# 2) 再装带 vision 的 tensorfold（0.6.6 才带 native_helper）
python -m pip install "tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6"
```

反过来的话，第 2 步会把 PyPI 的普通 `torch` 当依赖拉进来，装完 `cuda.is_available()` 是 `False`，
而且不会报错——只有真跑 `--vision` 时才炸。`4-venv.ps1` 就是按这个顺序写的，并且装完会回读
`torch.__version__` / `torch.version.cuda` / `cuda.is_available()` 和
`find_spec('tensorfold.vision.native_helper')`，不绿就不算完成。

### 6.2 结构性差异（六处，决定了后面所有改写）

| 维度 | Linux 原版 | Windows 版 |
|---|---|---|
| 运行载体 | `docker run -d --gpus all --ipc=host --network host` | `Start-Process tensorfold-native.exe`，直接跑在宿主 |
| 模型路径 | HF cache 快照挂到 `/root/.cache/huggingface`，用 `/root/...` 路径传参 | 本地目录（选单第 6 项），`MODEL_PATH` 直接传，由 `1-install-ps1.ps1` 写进配方 `.env` |
| 日志 | `docker logs -f`（一个流） | 两个文件 `serve-*.out.log` / `serve-*.err.log`，用 `StreamReader` 轮询 |
| 单实例保护 | `flock -n 8` 独占锁文件 | pid 文件 + 端口监听探测（`flock` 在 Windows 无等价物） |
| 停止 | `docker stop -t N` 再 `docker rm -f` | `Stop-Process -Force` + 轮询到期；再按 exe 路径 / LISTEN socket 找孤儿 |
| 预检"参数合法吗" | `docker run --rm ... serve /nonexistent` 跑一次引擎 | 直接 `& $env:ComSpec /c "exe serve /nonexistent ..."` 跑一次 |

### 6.3 逐项改写对照

| Bash | PowerShell 5.1 |
|---|---|
| `set -euo pipefail` | `$ErrorActionPreference = 'Stop'`（**注意**：原生程序 stderr 会被当成错误，见 §6.6） |
| `cd "$(dirname "$(readlink -f "$0")")"` | `Set-Location $PSScriptRoot` |
| `source ./scripts/config.sh` | `. (Join-Path $PSScriptRoot 'scripts\config.ps1')` + `$script:SelfName = 'start.ps1'` |
| `usage() { awk 'NR>1 && /^#/...' "$0"; }` | 读自身 `<# ... #>` 注释块后 `-replace '^# ?',''` |
| `(( 1 <= 12 ))` 算术判断 | `[int]` 转换 + `-lt/-gt/-eq/-in` |
| `"${!name}"` 间接取值 | `[Environment]::GetEnvironmentVariable($name, 'Process')` |
| `export FOO=1`（给子进程） | `[Environment]::SetEnvironmentVariable('FOO','1','Process')` |
| `env \| grep -E '^(TENSORFOLD\|TF_FLASHNEXT)_'` 收集 `-e` 参数 | 不需要：进程环境天然被子进程继承（`Set-EnvVar` 就是导出） |
| `docker run -d` | `Start-Process -PassThru -WindowStyle Hidden -RedirectStandardOutput/Error` |
| `docker logs -f` 后台 + `kill $LOGS_PID` | 两个 `[System.IO.StreamReader]` 轮询 + `try/finally { Dispose() }` |
| `trap './stop.sh' INT TERM` | `try { ... } finally { ... }`（无信号可拦，只能保证退出路径） |
| `docker inspect -f '{{.State.Running}}'` | `Get-ServerPid`（pid 文件 + `Get-Process -Id` 存活判断） |
| `ss -ltn "sport = :$PORT"` | `Get-NetTCPConnection -LocalPort $Port -State Listen`，异常时 `TcpClient` 兜底 |
| `awk '/^MemAvailable:/' /proc/meminfo` | `Get-CimInstance Win32_OperatingSystem` 的 `FreePhysicalMemory`（KB） |
| `nvidia-smi --query-compute-apps=pid,used_memory` | `--query-gpu=memory.used,memory.free`（WDDM 下 per-process 恒为 `[N/A]`） |
| `hostname -I \| awk '{print $1}'` | `Get-NetIPConfiguration` → `IPv4Addresses[0]` |
| `curl -s --max-time N URL` | `Invoke-RestMethod`（统一走 `Invoke-LocalRest`，见 §5） |
| `python3 -c 'json.load(...)'` 取字段 | `ConvertFrom-Json` 后直接 `.data[0].id` |
| `mkdir -p` | `New-Item -ItemType Directory -Force` |
| `SECONDS` | `[System.Diagnostics.Stopwatch]::StartNew()` → `.Elapsed.TotalSeconds` |
| `$'\033[1;35m'` ANSI | `Write-Host -ForegroundColor Magenta` |
| `date +%Y%m%d-%H%M%S` | `Get-Date -Format 'yyyyMMdd-HHmmss'` |
| `$(cmd)` 命令替换 | `& $exe args` / `$(& $exe args)`；文本拼接用 `-f` 或 `@''@` here-string |

### 6.4 内存与 GPU 指标：口径必须改

`/proc/meminfo` 的 `MemAvailable` 在这台统一内存机器上**没有对应物**：
`Win32_OperatingSystem.FreePhysicalMemory` 只反映系统侧 ~30 GiB，而权重与 KV 来自驱动的 98 GiB GPU pool。
照搬 Linux 的门槛（`WEIGHTS + KV + slack + floor + 2`）会得到"内存不足、拒绝启动"的假警报。

改写后的三处口径：

1. **启动门槛只算 host 侧**：`need - WEIGHTS - KV - floor`，且**只告警不阻断**。
2. **加载中的地板线只告警不杀进程**：Linux 版 `a < MEM_FLOOR_GIB` 就 `docker stop` 并失败；Windows 版
   首次低于就 warn 一次（`$floorWarned`），因为引擎自己按 `TENSORFOLD_MEMORY_RESERVE_GIB` 兜底，
   而系统侧那个数字在加载期本来就会掉到 2 GiB（正常现象，实测 `only 2 GiB host memory left while loading`）。
3. **心跳改用 GPU 总量**：`Get-GpuMemSummary` 用 `nvidia-smi --query-gpu=memory.used,memory.free` 汇总，
   因为 WDDM 下 `--query-compute-apps` 的 `used_memory` 是 `[N/A]`，逐进程统计拿不到数。

```powershell
function Get-MemAvailableGiB {
    $os = Get-CimInstance Win32_OperatingSystem
    return [int][Math]::Floor($os.FreePhysicalMemory / 1MB)   # KB → GiB
}
```

### 6.5 `.env` 与变量导出的差异（很重要）

两边都读配方根目录 `.env`（`KEY=value`、`#` 注释、可选引号，**只读不执行**），但 PS 版有一处刻意的加强：

```powershell
# config.ps1：.env 里的键"直接覆盖"，而不是"仅当环境里没有时才设"
Set-EnvVar $key $val
```

原因：dot-source 的 `config.ps1` 会把上一轮 `Set-EnvVar` 的值留在**同一个 shell** 里，
Linux 那套"环境优先、`.env` 只补空缺"的语义会让旧默认值反过来压住文件。另外因为 `.env` 里**每一个 key**
都会被导出，所以引擎侧的开关（`TENSORFOLD_LOAD_STATS`、`TENSORFOLD_MEMORY_RESERVE_GIB` 等）
只要写进 `.env` 就能进到子进程——这也是 §3.3 那个坑的由来。

另一个差异，**曾经是错的，2026-10-28 修**：`config.sh` 导出 25 个引擎变量，而 `config.ps1` 当时只显式导出
11 个，漏了 17 个 `TF_FLASHNEXT_*`。当初的判断是"其余走引擎默认值，两边默认值本来就是同一套"——
**这句是错的**。引擎对未设置的变量一律当 **off**（或出厂规则），而配方导出的全是 `1`：

| 变量 | 引擎未设置时 | 配方 |
|---|---|---|
| `GATHER_EARLY` / `SAMPLE_CAND` / `SHARED_SIDE` / `GDN_LANES` / `KEEP_LATE` | `false` / `.off` | `1` |
| `PROMPT_HC2` / `PROMPT_SHARED_DIRECT` / `PROMPT_GEMM2` / `DRAFT_AHEAD` / `WARM_AHEAD` | `false` | `1` |
| `HEAD_PIECE` | `256` | `1536` |
| `PREFILL_TAIL` | `0` | `512` |
| `CONFIDENCE` | `0.6`（每 draft 地板） | `-0.4`（连乘 ≥ 0.4） |
| `SAMPLED_HEADS` | `false` | `1` |
| `HOST_DRAW_THREADS` | `0`（自动） | `7` |
| `GATHER_READ` | 映射页错误 | `pread` |

后果不是"行为略有差别"，而是**跑的根本不是同一台引擎**：未设置的开关让引擎走 fallback 路径
（`GATHER_READ` 未设时退回映射页、`CONFIDENCE` 用 0.6 的每 draft 地板、`PROMPT_*` 整族关掉），
所以补齐属于**正确性**，不是调优。现在的 `config.ps1` 导出 21 个 `TF_FLASHNEXT_*`，与 `config.sh`
一一对应，每项都仍可被 `.env` 覆盖。

补齐之后记一句就够：**配方 README 里那些 +14% / 15–25% 是它自己 Linux 镜像上的数字**，在 WDDM
上不能当作预期；本页的性能数字全部来自 sparkDash 实测（见 README 与 `docs/bench/`）。

**验收办法**（新机器上必做一次）：

```powershell
# 两边取出来做差集，剩下的应该只有"有意为之"的项
grep -oE "^export (TF_FLASHNEXT|TENSORFOLD)_[A-Z0-9_]+" scripts/config.sh | sed 's/^export //' | sort > sh.txt
grep -oE "Set-EnvVar '[A-Z0-9_]+'" scripts/config.ps1 | sed "s/Set-EnvVar '//;s/'//" | sort > ps.txt
diff sh.txt ps.txt
```

顺带记一个反例：`TF_FLASHNEXT_DEPTH` 在引擎里**不存在**（只有 `TF_FLASHNEXT_DEPTH_LOG`），写错的变量名
不会报任何错，只是静默不生效——控制 draft 长度的是 `TF_FLASHNEXT_DRAFTS`。

### 6.6 PowerShell 5.1 的语法地雷（写脚本时必踩）

1. 没有 `&&`、`||`、三元 `?:`、`??`。用 `; if ($?) { }` 或 `if/else`。
2. `$Host` 是自动变量，不能当自定义变量（配方里用 `$BindHost` 就是这个原因）。
3. `2>&1` 打原生程序会污染 `$?`；判退出码用 `$LASTEXITCODE`。
4. `"$var:"` 会被解析成驱动器引用（`$cand:` 报"变量引用无效"），用 `${var}:`。
5. 原生程序写 stderr 会被当成 `NativeCommandError`，在 `$ErrorActionPreference='Stop'` 下**直接中断脚本**。
   `tf-cuda-test info`、`git`、`nvcc` 都会这样——靠文本和 `$LASTEXITCODE` 判断，别靠 `$?`。
6. `SetEnvironmentVariable($n, $null)` 不一定真删，可能留下空串；而引擎把"存在但为空"当非法值
   （`TENSORFOLD_CUDA_KERNELS= holds no aot.json`），所以**能显式给值就别删变量**（给 `native`）。
7. 判断架构别用 `$env:PROCESSOR_ARCHITECTURE`（WOW64 下报 x86），用
   `[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture`。

### 6.7 `prepare.sh` 为什么没有对应物

`prepare.sh` 干的是：拉基础镜像 → 下 zig → 打补丁 → 编 zig/CUDA → 装两个图像解码库 → 下权重 →
`docker build` 打标签（标签里带补丁哈希，用来判"镜像是否过期"）。

Windows 上没有容器这一层，"准备"退化成几件独立的事，也就是 skill 的 `scripts\engine\` 里那六步
（配方侧只有 `scripts\recipe\1-install-ps1.ps1` 一件事：放 `.ps1`）：

| 原 `prepare.sh` 的活 | Windows 上怎么做 |
|---|---|
| 拉镜像 / `docker build` | 不需要；直接编译本机 exe |
| 下 zig + 校验 sha256 | 手工装 zig 0.17.0（skill 的 `1-preflight.ps1` 检查版本） |
| `git clone` + 打 17 个补丁 | `2-clone.ps1` + `3-apply-patches.ps1`（三份合并补丁） |
| 编 CUDA / zig | `5-build.ps1`（`cmd /c` + `vcvarsall arm64` 内跑 `zig build`） |
| 装 libjpeg-turbo / libwebp | 不需要：exe 旁边已有 `turbojpeg.dll` / `libwebpdecoder.so.3` |
| 下权重（HF snapshot） | `hf download nvidia/Qwen3.8-Flash-Next-FP4-Local --revision b9ce18a6… --local-dir <模型目录>`；国内可用 ModelScope 镜像 `modelscope download --model nv-community/Qwen3.8-Flash-Next-FP4-Local --local_dir <模型目录>`（`<模型目录>` 就是选单第 6 项，会写进配方 `.env` 的 `MODEL_PATH`） |
| 装 torch（镜像里白拿） | `4-venv.ps1`：在**配方目录**建 `venv`，先 torch 后 `tensorfold[vision]`，见 §6.1.1 |
| 镜像标签当"过期判据" | 没有镜像了 → 由 `3-apply-patches.ps1` 的 78 项与 exe 时间戳替代 |

---

## 7. 验收清单（命令级）

```powershell
# 0) 路径先定下来（只做一次；之后所有脚本读同一个 .migration.local.json）
powershell -ExecutionPolicy Bypass -File <skill>\scripts\Invoke-Migration.ps1 -Reset
#    → 六行编号：root / python / zig / cuda / vcvars / model，d 重探、? 浏览、回车接受
#    下面把选定的 root 记作 <root>（形如 D:\llm\latest），引擎目录固定是 <root>\TensorFold

# 1) 补丁打全了吗（应列出三份，两处 spot-check 绿）。下面 <skill> = skill 目录
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\3-apply-patches.ps1 -TensorFold <root>\TensorFold
git -C <root>\TensorFold status --porcelain --untracked-files=all | Measure-Object | % Count   # 期望 78

# 2) 编出来了吗
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\5-build.ps1 -TensorFold <root>\TensorFold   # BUILD_EXIT=0
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\6-smoke.ps1                                # 三项 OK

# 3) venv 就位了吗（vision 才需要；不跑 --vision 可跳过）
powershell -ExecutionPolicy Bypass -File <skill>\scripts\engine\4-venv.ps1     # 结尾应报 cuda True
Test-Path <root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\venv\Scripts\python.exe   # True

# 4) 配方侧的四个 .ps1 装好了吗（这一步是唯一会写配方目录的）
powershell -ExecutionPolicy Bypass -File <skill>\scripts\recipe\1-install-ps1.ps1
git -C <root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold status --porcelain   # 只有 ?? 没有 " M"

# 5) 加载快了吗（在配方目录里跑）
cd <root>\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
$env:TENSORFOLD_LOAD_STATS='1'; .\start.ps1       # 期望 server answered after ~71s

$err = Get-ChildItem build\logs\serve-*.err.log | Sort-Object LastWriteTime | Select-Object -Last 1
(Get-Content $err -Encoding Default | Select-String 'layer \d+ took').Count        # 48
Get-Content $err -Encoding Default | Select-String 'stage wait' | Select-Object -Last 3   # 每组 0-50 ms
# Git Bash 里等价：grep -a "layer .* took" build/logs/serve-*.err.log | wc -l

# 6) 权重没装错吗
#    POST /v1/chat/completions "Answer with one word: capital of France" → Paris

# 7) 收工
.\stop.ps1                                   # Stopped; its GPU memory is free again
```

---

## 8. 附：三份补丁与哈希

```
c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad  0001-recipe-0001-0017-on-v1.1.4.patch   74 files / 9380 lines / 495 KB
9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40  0002-windows-arm64-port.patch           5 files /  158 lines / 9 KB
911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64  0003-load-pipeline.patch                4 files /  441 lines / 21 KB
```

配套材料：`tensorfold-windows-arm64-migration` skill（`SKILL.md` 第 4 章=补丁、第 8 章=加载流水线、
`references/build-notes.md` 第 5 章=设计取舍、`references/verification.md` 第 6 节=实测证据）。
