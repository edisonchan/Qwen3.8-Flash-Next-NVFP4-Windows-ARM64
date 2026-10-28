# 验证记录（2026-10-28，本机 RTX Spark N1X）

这份文件记录"这套补丁确实能从零复现可构建树"的证据，便于日后复核。

## 1. 基线

| 项 | 值 |
|---|---|
| 主机 | Windows 11 ARM64，RTX Spark N1X（48 SMs，sm_121），驱动 CUDA 13050 |
| zig | 0.17.0 (`D:\llm\zig-aarch64-windows-0.17.0`) |
| CUDA | 13.4 (`...\CUDA\v13.4`) |
| MSVC | VS2022 BuildTools 17.14.42，`Hostarm64\arm64\cl.exe` |
| 引擎 | `ashhart/TensorFold` @ `eab8582819688325e371907e4706e1c602b8a273`（tag v1.1.4） |
| 配方 | `MiaAI-Lab/Qwen3.8-...-TensorFold` @ `fd3f43e`（main） |

## 2. 补丁一致性（逐字节）

做法：新建干净克隆 → 检出 `eab85828` → 应用 `0001` + `0002` → 与当时的生产工作树逐文件比 sha256。

```
clean=0
0001 check OK / applied
0002 check OK / applied
resulting change count = 75
compared 75 files; mismatches: 0
```

即：**补丁产物与生产树逐字节一致**，不存在"手工改过但没进补丁"的遗漏。

`0003`（加载流水线）是在"0001+0002 已应用"的临时 worktree 上切的，切法：

```
worktree add --detach <tmp> eab85828
git apply 0001; git apply 0002
git commit -a                       # 固定基线
cp <生产树>\{nvfp4_slice.zig, cuda_modelopt_experts.zig, cuda_prompt_wt.zig, cuda_prompt.zig} <tmp>
git diff > 0003-load-pipeline.patch # 4 files / 273+ / 35-
```

在复位成裸 `eab85828` 的同一 worktree 上按 0001 → 0002 → 0003 顺序 `3-apply-patches.ps1`：

```
0001 sha256 c780c961…  applied
0002 sha256 9e2728ad…  applied
0003 sha256 911b7d75…  applied
tree now: 59 files changed, 3783 insertions(+), 193 deletions(-)   # 78 entries incl. 19 new
port patch spot-check: the explicit instantiations carry __restrict__
load patch spot-check: staged expert fill in place, shard cache widened
```

四个文件与生产树 sha256 全部一致；`git status --untracked-files=all` 计 78 项。

## 3. 从零构建

在另一份**全新克隆**（`scratch`）上应用两份补丁（当时只有 `0001`+`0002`；`0003` 之后的加载实测见第 6 节）
后直接构建：

```
[vcvarsall.bat] Environment initialized for: 'arm64'
BUILD_EXIT=0
build\native\bin\tensorfold-native.exe   36,205,568 B   PE32+ ARM64
build\bin\tf-cuda-test.exe               78,627,840 B
耗时 5 分 46 秒
```

冒烟：

```
usage: tensorfold-native --version | capabilities --json | models | info MODEL | ...
VERSION: 1.1.4
CHIP: nvidia-sm121
CUDA: driver CUDA 13050, device NVIDIA RTX Spark N1X (6144-core Blackwell RTX GPU), sm_121, 48 SMs, ...
```

## 4. 脚本自测

| 脚本 | 结果 |
|---|---|
| `3-apply-patches.ps1` | 在第三个干净克隆上跑通；三份 sha256 与文档一致；两处 spot-check 通过 |
| `5-build.ps1` | 在第三个克隆上跑通：`BUILD_EXIT=0`，6.6 分钟，产物 34.5 MB / 75 MB |
| `6-smoke.ps1` | 三项 `[ OK ]` |

## 5. 补丁哈希

```
c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad  0001-recipe-0001-0017-on-v1.1.4.patch
9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40  0002-windows-arm64-port.patch
911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64  0003-load-pipeline.patch
```

## 6. 加载实测（`0003` 的效果）

同一台机器、同一 checkpoint（`Qwen3.8-Flash-Next-FP4-Local`，48 层，NVFP4 专家）：

| 项 | 原生 v1.1.4 | `0003` 之后 |
|---|---|---|
| `start.ps1` 报 | — | `server answered after 71s` |
| 引擎自报 | — | `loaded in 67.6s` |
| 整机总耗时 | 257 s | 71 s |

分段（48 层，`TENSORFOLD_LOAD_STATS=1`，取自 `serve-*.err.log`）：

```
layer N took   n=48  sum=53564 ms  mean=1116  median=1130  min=886  max=1275
pack           n=49  sum=34222 ms  mean= 698  median= 706  min=527  max= 793
stage wait     n=49  sum=  871 ms  mean=  17.8 max=   49
```

结论：拷贝已被完全掩盖（占 1.3%），瓶颈转移到 host 侧打包（20 核已用满），剩余 ~14 s 是非专家权重。

正确性抽查（并行装配是否错位）：

```
GET /health          → status=ok, max_batch_size=4, memory.active≈76.2 GiB
POST /v1/chat/completions "Answer with one word: capital of France" → "Paris"
```

服务用 `stop.ps1` 正常关闭（`Stopped; its GPU memory is free again`），8888 端口释放、无残留进程。

## 7. 未覆盖的部分

- 未验证 `--vision` 的真实图片/视频推理（venv 探测通过，但未跑图）。
- 未验证两 rank / `--tp`（本机单卡）。
- 未验证 `PARALLEL=5`（262144 窗口下 fp8 KV 需 23.74 GiB，准入预算 22.81 GiB，加载完成后才报错）。
- 未做"专家预打包 blob"方案（跳过重打包，估算 20 s；属于新功能）。
