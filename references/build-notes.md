# 构建与移植原理记录（TensorFold v1.1.4 / Windows ARM64）

这份文档解释 **为什么** 要这么做，便于在新的引擎版本上重做迁移时判断哪些结论仍然成立。

> 上游更新的版本（v1.1.5+）已经在主干加入 Windows 移植层（`zig/src/platform/sys.zig` 等），
> 到那时第 2 章的多数条目可能已被上游吸收，**先查上游 `docs/WINDOWS.md`，再决定是否还需要本补丁**。

---

## 1. 为什么是"合并补丁"，而不是顺序打 17 个配方补丁

配方 `patches/0001..0017` 是按 TensorFold `db281878` 生成的。当前 `TF_REF` 是 `eab85828`（v1.1.4）——
v1.1.4 把引擎重写了一遍（"the Zig engine has been reimplemented on its own Flash Next CUDA engine"），
文件与上下文都漂移了。实测顺序 `git apply` 的结果：

- 6 个补丁能干净打上（0001/0002/0003/0004/0007/0009）；
- 11 个需要 `git apply --3way`，其中多数会留下冲突块，必须人工裁决。

人工裁决不可复现，换台机器换个人就得到不同的树。所以本 skill 把这 17 个补丁的**最终正确结果**
固化成一份合并补丁（`0001-recipe-0001-0017-on-v1.1.4.patch`），是一次三方合并的产物，
逐字节比对过（见 `verification.md`）。

代价与权衡：

| | 合并补丁 | 顺序 apply + 人工解冲突 |
|---|---|---|
| 可复现 | ✅ 确定性 | ❌ 依赖裁决 |
| 体积 | ~495 KB | 17 个文件共约 470 KB |
| 溯源 | 附带说明，可逐文件 `git diff` 复核 | 直接对应上游补丁 |
| 引擎升级时 | 需重新生成一次 | 每版都要重做冲突裁决 |

生成方法（复现这套补丁）：

```bash
# 1) 干净克隆并在 eab85828 上把 17 个补丁以三方合并 + 人工裁决的方式打对（得到"目标树" A）
# 2) 另建干净克隆（原始树 B = eab85828）
# 3) 把 A 中所有变更文件覆盖到 B，git add -A，git diff --cached HEAD > 0001.patch
```

---

## 2. 五处 Windows/MSVC 兼容点

### 2.1 `__restrict__` 与显式模板实例化（3 个 .cu）

MSVC 在**显式实例化**（`template __global__ void f<...>(...)`）时，要求实参类型与模板定义的形参类型
**完全一致**，包括 `__restrict__` 这类 MSVC 扩展限定符。GCC/clang 把 `__restrict__` 当提示，比较类型时
忽略它，所以上游在 Linux 上编得过。

模板定义（`qmm_prefill.cu`）：

```cpp
template <int GS, int BM, int BN, int WM, int WN, int STAGES, bool F32>
__global__ void prefill_kernel(const __nv_bfloat16* __restrict__, const uint32_t* __restrict__, ...);
```

显式实例化写成了：

```cpp
template __global__ void tf_qmm_prefill::prefill_kernel<64, 128, 128, 2, 2, 2, false>(
    const __nv_bfloat16*, const uint32_t*, ...);      // ← 少了 __restrict__
```

nvcc 报的是 `no instance of function template ... matches the specified type`，指向实例化那一行——
**不是** 模板参数写错了，而是限定符不匹配。同文件里另一个实例化（`<2,4,3>`）恰好带着 `__restrict__`，
所以它能过、这个不能，这就是最直接的对照证据。

同样的形态出现在：

- `prefill_attention.cu`：`hpattn_kernel<256,8,2,2>`、`hpattn8_kernel<256,8,2,2>`
- `gdn_prefill.cu`：`chain_kernel<bf16,bf16,64,32>`

修法：只补限定符，不动任何参数类型、模板实参、launch 配置。**零语义变更**。

> 这三个文件失败时，构建日志里只有 `error: process exited with code 1`（nvcc 的 C++ 诊断进了 stdout，
> 而 zig 只转述退出码）。要看到真正的报错，单独跑 nvcc：
>
> ```bat
> nvcc -fatbin --expt-relaxed-constexpr -std=c++20 -Xcompiler=/Zc:preprocessor ^
>      -O3 -gencode=arch=compute_121,code=sm_121 -o out.fatbin <file>.cu
> ```
>
> 必须在 `vcvarsall arm64` 环境内跑。

### 2.2 `std.posix.MAP` 在 Windows 上是 `void`

`cuda_ple_reader.zig`（补丁 0013 引入）用匿名 mmap 分配 n-gram 行缓存：

```zig
const mem = try std.posix.mmap(null, n, .{ .READ = true, .WRITE = true },
                              .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
```

zig 0.17.0 里 `std.posix.MAP = system.MAP`，而 `system` 在 Windows 目标下没有匿名映射的枚举，
`MAP` 解析为 `void` → 编译器报 `type 'void' does not support struct initialization syntax`。

修法（只影响 Windows 分支）：

```zig
const mem: []align(std.heap.page_size_min) u8 = if (builtin.os.tag == .windows)
    try std.heap.page_allocator.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), slot_bytes)
else
    try std.posix.mmap(null, slot_bytes, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
```

`std.heap.PageAllocator` 在 POSIX 上就是 `mmap(MAP_ANONYMOUS|MAP_PRIVATE)`，在 Windows 上是
`VirtualAlloc(MEM_COMMIT|MEM_RESERVE, PAGE_READWRITE)`：两者都满足这段代码依赖的三个性质——
页对齐、零初始化、按需提交（未触碰的页不占物理内存）。所以缓存行为与 Linux 一致。

释放端对应地分叉（`VirtualFree(MEM_RELEASE)` / `munmap`），Linux 路径保持原文一字不改。

### 2.3 `clock_gettime` 在这个 zig 里已经不是 posix API

`cuda_ple.zig` 的计时统计用了：

```zig
_ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &t);
```

- 该 zig 版本的 `std.posix` 已没有 `clock_gettime`；
- `std.c` 里的声明在 Windows 上把 `clockid_t` 解析成 `void`，于是
  `parameter of type 'void' not allowed in function with calling convention 'aarch64_aapcs_win'`。

修法：用仓库自己的惯用法 `std.Io.Clock.awake.now(io)`（CLI 里大量使用），并把 `std.Io` 存进
`Ngram` 结构体（`init` 已经接收 `io` 参数，只是原先没保存）。`std.Io` 在 Windows 上用
`QueryPerformanceCounter` 实现，POSIX 上用 `CLOCK_MONOTONIC`——正是原代码想要的单调时钟。

调用点只有 6 处（`Split.part` 里 2 处、`rowsMany` 里 4 处），且都在 `Stat.on` 打开时才执行，
不影响热路径。

### 2.4 一个曾经误导过我的假象

第一次修的时候，我把 `qmm_prefill.cu` 的报错理解成"zig 生成了 `prefill_kernel<...,1,2,2,...>` 的调用
但没有实例化"，于是补了一个 WM=1 的实例化。**这是错的**：引擎里 `qmm_prefill` 的符号只有

```
_ZN14tf_qmm_prefill14prefill_kernelILi64ELi128ELi128ELi2ELi4ELi3ELb0EE
_ZN14tf_qmm_prefill14prefill_kernelILi64ELi128ELi128ELi2ELi2ELi2ELb0EE
```

（`zig/src/cuda/qlinear.zig` 的 `prefill` / `prefill22`），没有任何 WM=1 的引用。真正的病因自始至终
只是 `__restrict__`。教训：**先看符号表，再改代码**；显式实例化的报错优先怀疑限定符，而不是模板实参。

---

## 3. 构建环境的三条硬约束

### 3.1 nvcc 必须能看见 arm64 版 `cl.exe`

`vcvarsall.bat arm64` 设置 `PATH` / `INCLUDE` / `LIB`，nvcc 靠它们找到 `Hostarm64\arm64\cl.exe` 和
Windows SDK。**PowerShell 里 `call` 批处理不会改变父进程环境**，所以必须：

```
cmd /c build_now.bat        # .bat 内部 call vcvarsall arm64 && zig build ...
```

漏掉这一步的表现非常有欺骗性：**所有** `.cu` 都 `error: process exited with code 1`，
日志里只有 C4819（代码页警告），看不到任何 C++ 错误。

### 3.2 缓存与临时目录全部重定向进 `build\`

```
ZIG_LOCAL_CACHE_DIR  = <TF>\build\.zig-cache
ZIG_GLOBAL_CACHE_DIR = <TF>\build\zig-cache-global
TMP / TEMP           = <TF>\build\tmp
```

好处：不污染用户目录；清理即 `rm -rf build`；换机时不会误命中另一台机器的缓存。

### 3.3 目标三元组与架构

`zig build native install -Dsm=121 --prefix build`。`-Dsm=121` 决定 nvcc 的
`-gencode=arch=compute_121,code=sm_121`，并选择 `native/cuda.zig` 里 `share\tensorfold\cuda\sm121`
这套核集路径。

---

## 4. 运行时相关（与构建无关，但迁移时必然撞上）

| 事项 | 结论 |
|---|---|
| `--kv-dtype` → `--kv-cache` | v1.1.4 改名。`start.sh`（Linux）已用新名，Windows 版 `start.ps1` 曾是旧名，症状是 `argument --kv-dtype: invalid choice: 'fp8'` |
| AOT 核集（`TENSORFOLD_CUDA_KERNELS`） | 引擎优先用它，其次用可执行文件旁的 `share\tensorfold\cuda\sm<cap>`，最后才用内嵌 fatbin。旧引擎留下的核集缺 fp8 KV 支持，报 `Fp8KvUnsupported` |
| 变量"存在但为空" | `aot.pick()` 只要变量非 null 就走"当作目录"分支，空串既不是 `native` 也没有 `aot.json` → `TENSORFOLD_CUDA_KERNELS= holds no aot.json`。要内嵌核集就给字面量 `native` |
| checkpoint 格式 | v1.1.4 的 Flash Next CUDA 路径只接受 `quant_method=modelopt` + `quant_algo=MIXED_PRECISION`；GPTQ 的 INT4-AutoRound 会被 `UnsupportedCheckpoint` 拒绝 |
| `kernels embedded true` | 冒烟里 `tf-cuda-test info` 的这一项说明不需要外部核集；为 `false` 时才需要 `tools/zig/flashnext_aot.py` |
| 内存 | 权重 81 GiB 走 GPU pool，系统侧只需几 GiB 缓冲；`start.ps1` 的内存判断是告警不阻断 |
| 加载慢（257 s） | 原生路径每层**现场装配**专家，单线程 + 2 槽映射缓存；`0003` 补丁修掉，见第 5 章 |

---

## 5. 模型加载流水线（257 s → 71 s）

第 4 章是"能跑起来"；这一章是"跑起来别等四分钟"。全部改动在 host 侧，**没有一行 `.cu`、没有改 kernel
参数或 launch 配置**。

### 5.1 一层专家在做什么

v1.1.4 的 `cuda_prompt_load.zig` 里，MoE 层不是从预量化缓存读，而是从**原始 safetensors 现场装配**：

```
safetensors 里的 NVFP4 专家  ──readPart──▶  codes + scales（按 16 一块的 e4m3 缩放）
                              ──packGateUp / packOne──▶  引擎要的排布（gate 与 up 交织、down 单独）
                              ──upload──▶  GPU 的 up / down 张量
```

一层 512 个专家，每个专家 3 个投影（gate / up / down），打包后每层约 **1350 MiB**（≈2.64 MiB/专家）。
48 层就是 24576 个专家、约 63 GiB 的装配量。**这部分计算无法避免**（checkpoint 里没有引擎要的排布），
能做的是让它并行、并且让 DMA 与其重叠。

### 5.2 旧路径的三个放大器

| 放大器 | 具体 | 代价 |
|---|---|---|
| 单线程逐专家 | `for (0..512)`：读 → 打包 → `up.upload()` → `down.upload()` → `stream.synchronize()` | 一次只用一个核；每层 1536 次小拷贝 + 512 次同步 |
| 2 槽映射缓存 | `Store.released: [2]Held`，而一层专家散在 **14 个 shard** | 每层循环里反复 close/reopen 并重新解析分片头（全模型头部 50.6 MB，单文件最大 9.3 MB） |
| 逐行 memcpy | `core/nvfp4_slice.zig` 的 `slice()` 一行一次 `@memcpy` | 占读耗时约 1/3；对整宽张量完全是浪费 |

注意"头部重解析"在 Windows 上比 Linux 更贵：`cuda_ple_reader.zig` 的 Windows 分支用的是
`PageAllocator`（`VirtualAlloc`）而不是 `mmap`，分片元数据每层都要重新解码一遍。

### 5.3 现在的流水线

```
   ┌─────────── 组 i+1 ───────────┐        ┌──── 组 i+2 ────┐
   │ 20 线程并行 pack 16 个专家   │        │                 │
   │ 各自写进 stage B 的独立切片  │        │                 │
   └──────────────┬───────────────┘        └─────────────────┘
                  │ cuMemcpyHtoDAsync(stage B → GPU)
   ┌──────────────┴───────────────┐
   │ 同时：stage A 的 DMA 还在飞  │   ← 上一组的拷贝被这一组的打包掩盖
   └──────────────────────────────┘
```

关键数值（本机实测，一层）：

| 量 | 值 | 来源 |
|---|---|---|
| 每组专家数 | 16（`TENSORFOLD_LOAD_GROUP`） | `stage_default` |
| 每 stage 体积 | 16 × 2.64 MiB ≈ 42 MiB | `Stage.init(d, group, up_bytes, down_bytes)` |
| 双缓冲合计 | ≈ 84 MiB | 只占 host 可用 16 GiB 的 0.5% |
| 一组 pack | ≈ 22 ms（20 线程） | 698 ms / 32 组 |
| 一组 DMA | ≈ 2 ms | 42 MiB @ 20 GB/s |
| 每组等待 | ≈ 0.5 ms | `stage wait` 18 ms / 32 组 |

### 5.4 三个设计取舍

1. **按"组"切，不按"专家一线程"**：DMA 投递有固定开销，一次 2.6 MiB 的拷贝比一次 42 MiB 的拷贝
   每字节贵得多；而且逐专家投递会产生 1536 次 ioctl/层，开销比数据本身还大。攒够一组再投，才让
   异步拷贝有意义。
2. **原子取号，不做静态分片**：512 / 20 不能整除，静态分片会出现"线程 0 做 26 个、线程 19 做 22 个"，
   尾部长；取号让跑得快的线程自然多干。
3. **双缓冲 + 事件回压，不是"多缓冲越多越好"**：两个 stage 已经让拷贝 100% 藏在打包里
   （`stage wait` 0.87 s / 67.6 s）。再加缓冲只增加 host 内存与首次启动延迟，收益为零。

### 5.5 并发正确性

并行读 checkpoint 会把原来"单线程顺序使用"的假设全部打破，有三处必须处理：

| 风险 | 处理 |
|---|---|
| 多个线程同时借还映射，簿记互相踩 | `Store.mtx: std.Io.Mutex`（zig 0.17 已删除 `std.Thread.Mutex`）；**只在锁内记录指针，IO 在锁外** |
| 槽满时把别人正在读的映射关掉 | 满槽时把"已归还"的映射扫进缓存（`releaseLocked`），**绝不 close 正在借出的映射** |
| DMA 还在读 stage 就被下一组覆写 | 每个 stage 一个 `cuda.Event`，复用前 `synchronize()`（`Stage.reuse`） |
| 出错时 20 个线程都在跑 | `Job.stop` 原子标志：一个失败，其余立刻收手，错误抛回调用者 |

另外两条泛型约束：`loadShape(store: anytype)` 的测试 mock 不是 `*wt.Store`，并行路径只在
`@TypeOf(store) == *wt.Store` 时启用，**单测仍走原来的串行实现**；`fill` 里任何分配失败都会打 warn
退回 `serial()`，不会让加载整体失败。

### 5.6 度量口径

`TENSORFOLD_LOAD_STATS=1` 会打两行/层（stderr）：

```
info: flashnext: 512 experts in 32 groups of 16 on 20 threads: pack 698 ms, stage wait 18 ms, 1350 MiB
info: flashnext: layer 47 took 1170 ms
```

- `pack` = 全部组的 CPU 打包累计（含并行，所以是墙钟累计）
- `stage wait` = 所有 `Stage.reuse()` 等待之和 → **这是双缓冲是否够用的直接指标**，>5% 就该怀疑组太小
- `layer N took` = 整层（含非专家权重、norm、共享专家）
- 末尾的 `1350 MiB` = `(up_bytes + down_bytes) * count >> 20`，即该层打包后总字节

`cuda_prompt.zig` 在 48 层读完后调 `store.dropShards()`，把映射与解析过的头部一起释放（约 0.6 GB）。

---

## 6. 版本升级时怎么重做

1. 读配方 `CHANGELOG.md`，确定新的 `TF_REF`（`scripts/config.sh`）。
2. 干净克隆引擎，检出该 commit。
3. 按顺序 `git apply --3way` 打配方补丁，人工裁决冲突，得到"目标树"。
4. 用第 1 章的方法把目标树压成一份合并补丁。
5. 重新跑构建，把新出现的 Windows 报错逐条归类：
   - `no instance of function template` → 补 `__restrict__`（可能新增文件）
   - `void` 相关 → 平台 API 缺失（查 `std.posix` 在该 zig 版本里的可用性）
   - 其它 → 单独判断，**只改平台分支**，不改算法
6. 更新本 skill 的三份补丁与 `SKILL.md` 的钉死值表。`0003` 是"在 0001+0002 之后"切的，升级时要在
   已经打好的目标树上重新切一次：把要保留的加载改动复现到该树，`git diff` 出来即是最小增量。
7. 重测加载耗时并更新第 5 章的数字（`TENSORFOLD_LOAD_STATS=1` + `build\logs\serve-*.err.log`）。
