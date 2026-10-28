---
name: tensorfold-windows-arm64-migration
description: 在任意 Windows 11 ARM64（aarch64-windows，sm_121 / GB10 / RTX Spark N1X）上，从 git clone 开始复现 TensorFold v1.1.4 + Qwen3.8-Flash-Next 配方的完整迁移：环境预检、两仓库克隆、补丁应用、vision venv、CUDA 构建、冒烟验证，并把模型加载从 257 s 压到 71 s（分组并行装配 + pinned 双缓冲 + 分片映射缓存）。含 6 个可执行 .ps1 与 3 个补丁文件，产物只落在仓库 build 目录，模型加载交用户。触发词：TensorFold 迁移、TensorFold Windows ARM 构建、tensorfold-native 编译、aarch64-windows CUDA 构建、Qwen3.8 Flash Next Windows 部署、模型加载慢、加载提速。
agent_created: true
---

# TensorFold v1.1.4 · Windows ARM64 迁移（可复现配方）

目标：在一台**全新的 Windows 11 ARM64** 上，只靠 `git clone` + 本 skill 的三个补丁，得到可运行的
`tensorfold-native.exe`，并知道它为什么能编过、为什么加载只要 71 s（原生路径 257 s）。
所有步骤都在本机（RTX Spark N1X / GB10，sm_121）实测通过，
补丁可**逐字节**还原当前生产树（验证记录见 `references/verification.md`）。

---

## 0. 一页速查

| 项 | 钉死值 |
|---|---|
| 引擎上游 | `https://github.com/ashhart/TensorFold` |
| 引擎版本 | tag `v1.1.4` = `eab8582819688325e371907e4706e1c602b8a273` |
| 配方上游 | `https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold` @ `main`（验证于 `fd3f43e`） |
| 配方 pin 的引擎 | `scripts/config.sh` → `TF_REF=eab8582819688325e371907e4706e1c602b8a273` |
| zig | 0.17.0 aarch64-windows，`sha256 9e8d11661d4ae3bd57702a3832781e23ad151dde5798e16a5ccd503f65234ff8` |
| CUDA | 13.4 toolkit（`nvcc.exe`），驱动需支持 CUDA 13.x（本机 `13050` = 13.5） |
| MSVC | VS 2022 Build Tools + `MSVC v143 C++ ARM64 build tools`（`Hostarm64\arm64\cl.exe`） |
| GPU 目标 | `sm_121`（`compute_121`，RTX Spark N1X，48 SMs） |
| Python | 3.13 arm64（仅 `--vision` 需要） |
| 模型加载 | **71 s / 48 层**（打全三份补丁；原生路径 257 s，见第 8 章） |
| 落地根 | 默认 `D:\llm\latest` |

**目录布局是硬约束**：配方 `scripts\config.ps1` 把引擎路径算成
`<配方的父目录>\TensorFold\build\native\bin\tensorfold-native.exe`。所以两个克隆必须**同级**，
引擎目录必须**正好叫 `TensorFold`**：

```
<Root>\
├─ Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold\   ← 配方
│  ├─ patches\  scripts\  start.ps1  stop.ps1  venv\
└─ TensorFold\                                       ← 引擎（名字不能改）
   └─ build\native\bin\tensorfold-native.exe
```

否则启动时报 `tensorfold-native.exe not found at ...`（可用 `NATIVE_BIN` 覆盖，但不推荐）。

**三条命令完成迁移**（详见各章）：

```powershell
cd <本 skill 目录>
powershell -ExecutionPolicy Bypass -File scripts\Invoke-Migration.ps1 -Root "D:\llm\latest"
# 或分步：1-preflight → 2-clone → 3-apply-patches → 4-venv → 5-build → 6-smoke
```

---

## 1. 环境要求

### 1.1 硬件与系统

| 项 | 要求 | 本机实测 |
|---|---|---|
| CPU/OS | Windows 11 ARM64（`OSArchitecture = Arm64`） | ✅ |
| GPU | NVIDIA，计算能力 12.1（GB10 / RTX Spark N1X） | RTX Spark N1X，48 SMs |
| 显存/统一内存 | 权重 81 GiB（NVFP4）+ 每流 KV ~4.7 GiB | GPU pool 98 GiB，系统可见 ~30 GiB |
| 磁盘 | 源码+缓存 ≥ 25 GiB；**模型另需 96 GiB** | D: 1.5 TB |

> 统一内存机型上，`MemAvailable` 只反映系统侧（约 30 GiB），权重和 KV 由驱动的 GPU pool 承担。
> 启动脚本的内存门槛是**只读告警**，不会阻断启动；引擎自己按 `TENSORFOLD_MEMORY_RESERVE_GIB` 兜底。

### 1.2 必装组件（含自检命令）

| 组件 | 版本 | 自检 | 备注 |
|---|---|---|---|
| zig | **0.17.0**（aarch64-windows） | `zig version` | 版本必须一致；0.16/0.18 会因 `std.posix.mmap`、`std.Io.Clock` 等 API 变动失败 |
| CUDA Toolkit | **13.4** | `nvcc --version` | 必须装 toolkit，不是只装驱动；`cublasLt64_13.dll` 供 vision 用 |
| MSVC | VS2022 Build Tools 17.14+ | `vcvarsall.bat` 存在且有 `Hostarm64\arm64\cl.exe` | 装 “使用 C++ 的桌面开发” + “MSVC v143 C++ ARM64 生成工具” |
| git | 任意近版 | `git --version` | |
| Python | 3.11–3.13（arm64） | `python -V` | 只有 `--vision` 需要 |

zig 下载：`https://ziglang.org/download/0.17.0/zig-aarch64-windows-0.17.0.zip`，解压后把
`zig.exe` 路径传给脚本（默认 `D:\llm\zig-aarch64-windows-0.17.0\zig.exe`）。
**强烈建议所有路径纯 ASCII**（中文/空格路径会撞 cmd 的代码页 936 与 nvcc 的 C4819 警告）。

### 1.3 一键预检

```powershell
powershell -ExecutionPolicy Bypass -File scripts\1-preflight.ps1
# 自定义路径：
powershell -ExecutionPolicy Bypass -File scripts\1-preflight.ps1 `
  -Zig "E:\tools\zig.exe" -Cuda "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4" `
  -Vcvars "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat" `
  -Root "E:\ai"
```

输出每项 `[ OK ]/[WARN]/[FAIL]`，有 `FAIL` 时退出码 1。**先过这一关再克隆**，能省掉后面 6 分钟的无效构建。

---

## 2. 配方与 TensorFold 克隆

### 2.1 命令

```powershell
powershell -ExecutionPolicy Bypass -File scripts\2-clone.ps1 -Root "D:\llm\latest"
# 钉住配方 commit（可选，推荐用于完全复现）：
powershell -ExecutionPolicy Bypass -File scripts\2-clone.ps1 -Root "D:\llm\latest" -RecipeRef fd3f43e
```

等价的手工命令：

```powershell
cd D:\llm\latest
git clone https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
git clone https://github.com/ashhart/TensorFold
cd TensorFold
git checkout --detach eab8582819688325e371907e4706e1c602b8a273
```

### 2.2 校验

```powershell
git -C D:\llm\latest\TensorFold rev-parse HEAD
# 期望：eab8582819688325e371907e4706e1c602b8a273
git -C D:\llm\latest\TensorFold status --porcelain     # 必须为空
git -C D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold rev-parse --short HEAD
```

脚本会把两仓库 commit、主机名、架构、剩余磁盘写进
`TensorFold\build\logs\00-migration-manifest.json`。

> **为什么要 `--detach eab85828`**：配方 `scripts/config.sh` 的 `TF_REF` 钉的就是这个 release。
> 引擎 `main` 已经往前走了（v1.1.5/v1.1.6），补丁是按 v1.1.4 切的，`main` 上打不上。

### 2.3 克隆必须是完整历史

补丁是合并补丁（见第 4 章），`git apply` 只需要工作树，`--depth 1` 也能用；但完整克隆体积只有
~150 MB，还便于事后 `git diff` 复核，**不要用浅克隆**。

---

## 3. venv 环境搭建（可选，仅 `--vision`）

原生引擎跑文本**不需要 Python**。只有开启 `--vision`（图片/视频输入）时，引擎才会启动
`tensorfold.vision.native_helper`，此时必须有 venv。

关键点：v1.1.4 的仓库自带 `setup.py` 会**主动拒绝安装**（“installs as a native binary … the Python
engine stays at 0.6.6”）。所以 venv 装的是 **v0.6.6 标签**，不是本地 checkout。

```powershell
powershell -ExecutionPolicy Bypass -File scripts\4-venv.ps1 `
  -Recipe "D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold"
```

手工等价：

```powershell
cd D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
python -m venv venv
venv\Scripts\python.exe -m pip install --upgrade pip
venv\Scripts\python.exe -m pip install "tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6"
```

### 3.1 校验（与引擎 step 1 的探测完全一致）

```powershell
venv\Scripts\python.exe -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
echo $LASTEXITCODE   # 0 = 通过
```

### 3.2 本机实测版本对照（供排查）

| 包 | 版本 | 说明 |
|---|---|---|
| Python | 3.13.16 (arm64) | `C:\Users\<user>\AppData\Local\Programs\Python\Python313-arm64` |
| tensorfold | 0.6.5（本机）/ v0.6.6（推荐） | 两者都能提供 `native_helper` |
| transformers | 5.20.2 | vision extra |
| pillow / av | 13.0.0 / 19.0.2 | vision extra |
| numpy / safetensors / huggingface_hub | 2.5.4 / 0.8.0 / 2.3.0 | 核心依赖 |
| torch / torchvision | 2.14.0+cu134 / 0.29.0+cu134 | **不是必需**：`native_helper` 只 import 标准库 + PIL，本机这份是历史遗留 |

> 磁盘预算：venv 约 0.4–1.5 GB（装不装 torch 差别很大）。网络需可达 github.com 与 PyPI。

---

## 4. 迁移步骤与补丁位置

### 4.1 三个补丁是什么

| 文件（`patches\`） | 内容 | 规模 | sha256 |
|---|---|---|---|
| `0001-recipe-0001-0017-on-v1.1.4.patch` | 配方 `patches/0001..0017` 的**合并结果**，平铺到 `eab85828` | 74 文件 / 9380 行 | `c780c9610f8550407e61ec48797e8c85d5602d984818dbd555300a61ecca80ad` |
| `0002-windows-arm64-port.patch` | Windows/MSVC 兼容修复（**不碰 kernel 算术**） | 5 文件 / 158 行 | `9e2728adb391d6610293224d75f53ab8f21b6b7b9fb689b5b943f85229d20a40` |
| `0003-load-pipeline.patch` | 模型加载流水线：分组并行装配 + pinned 双缓冲异步拷贝 + 分片映射缓存 + 整块 memcpy（**全在 host 侧，不碰 .cu / kernel 启动参数**；原理与取舍见第 8 章） | 4 文件 / 441 行 | `911b7d75a0b0f30b7db502255b3f1f5be6263ed7160f9557534c398e48ec5d64` |

三份合起来影响 **78 个文件**（59 个修改 + 19 个新增）。**顺序不可打乱**：`0003` 是在"`0001`+`0002` 已应用"的
树上切出来的，其中两个文件（`cuda_prompt.zig`、`cuda_prompt_wt.zig`）在 `0001` 里已经改过。
`3-apply-patches.ps1` 按文件名排序 apply，天然满足；手工应用时也必须 0001 → 0002 → 0003。

注意：`0002` 里的 `qmm_prefill.cu` **不在** `0001`
的 74 个文件里——该文件上游 v1.1.4 原文就没有 `__restrict__`，配方补丁没碰过它，所以这是纯粹的
MSVC 兼容问题，与配方无关。

为什么用合并补丁而不是逐个 `git apply` 配方原始补丁：那 17 个补丁是按更早的 `db281878` 生成的，
直接打到 `eab85828` 会有 11 个冲突、需要人工三方合并——**不可复现**。上表的第一份补丁是那次三方
合并的**最终正确结果**，逐字节比对已验证（75/75 文件哈希一致），且从零 clone 后构建通过。

代价：补丁体积大（约 495 KB），但 `git apply` 是一次性的、确定性的。

### 4.2 应用

```powershell
powershell -ExecutionPolicy Bypass -File scripts\3-apply-patches.ps1
```

脚本会做四件事：校验 HEAD == `TF_REF`、校验工作树干净、对每份补丁先 `git apply --check` 再 `git apply`、
把补丁名与 sha256 写进 `TensorFold\build\logs\01-patches.log`。

手工等价：

```powershell
cd D:\llm\latest\TensorFold
git checkout --detach eab8582819688325e371907e4706e1c602b8a273
git apply --check "<skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch"
git apply         "<skill>\patches\0001-recipe-0001-0017-on-v1.1.4.patch"
git apply --check "<skill>\patches\0002-windows-arm64-port.patch"
git apply         "<skill>\patches\0002-windows-arm64-port.patch"
git apply --check "<skill>\patches\0003-load-pipeline.patch"
git apply         "<skill>\patches\0003-load-pipeline.patch"
git status --porcelain --untracked-files=all | Measure-Object | Select-Object -Expand Count   # 期望 78
```

### 4.3 `0002` 逐条说明（5 处，全部是平台兼容）

| # | 文件 | 症状（不修的后果） | 改动 | 为什么 |
|---|---|---|---|---|
| 1 | `zig/kernels/cuda/qmm_prefill.cu` | `error: no instance of function template "prefill_kernel" matches the specified type` | 两个显式实例化的形参加 `__restrict__` | MSVC 要求显式实例化的参数类型与模板定义**逐字匹配**（含限定符）；GCC/clang 忽略 `__restrict__`，所以上游 Linux 能编 |
| 2 | `zig/kernels/cuda/prefill_attention.cu` | 同上（hpattn / hpattn8） | 同上 | 同上 |
| 3 | `zig/kernels/cuda/gdn_prefill.cu` | 同上（chain_kernel） | 同上 | 同上 |
| 4 | `zig/src/families/flashnext/cuda_ple_reader.zig` | `error: type 'void' does not support struct initialization syntax` | 匿名 `mmap` 在 Windows 分支改走 `page_allocator.alignedAlloc`；Linux 路径一字不改 | Windows 目标下 `std.posix.MAP` 是 `void`，匿名映射不存在；`PageAllocator` 底层就是 `VirtualAlloc`，同样匿名/清零/按需提交 |
| 5 | `zig/src/families/flashnext/cuda_ple.zig` | `error: parameter of type 'void' not allowed in function with calling convention 'aarch64_aapcs_win'` | `Stat.now()` 改用 `std.Io.Clock.awake.now(io)`；`Ngram` 增加 `io` 字段 | 该 zig 版本已删除 `std.posix.clock_gettime`，Windows 上 `std.c.CLOCK` 是 `void`；`Io.Clock` 由 std 在 Windows 上用 QPC 实现 |

> 这 5 处**只影响编译可行性**：没有改任何 kernel 的参数、launch 配置、精度或算术路径，也没有改补丁带来的性能开关。

### 4.4 回滚

```powershell
cd D:\llm\latest\TensorFold
git reset --hard eab8582819688325e371907e4706e1c602b8a273
git clean -fd            # 删除补丁新增的 19 个未跟踪文件
git status --porcelain   # 应为空
```

### 4.5 补丁文件位置

```
<本 skill>\patches\
├─ 0001-recipe-0001-0017-on-v1.1.4.patch
├─ 0002-windows-arm64-port.patch
└─ 0003-load-pipeline.patch
```

**不要**用配方仓库里 `patches/0001..0017` 直接顺序 apply（会冲突）；配方仓库里的那 17 份是上游原件，留作溯源。

---

## 5. 构建

```powershell
powershell -ExecutionPolicy Bypass -File scripts\5-build.ps1
# 自定义：
powershell -ExecutionPolicy Bypass -File scripts\5-build.ps1 -TensorFold "E:\ai\TensorFold" -Sm 121
```

### 5.1 它到底跑的是什么

脚本生成 `TensorFold\build\build_now.bat`，内容等价于：

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

然后 `cmd.exe /c build_now.bat`。

**为什么必须走 cmd + vcvarsall**：nvcc 通过 `vcvarsall arm64` 设置的 `PATH/INCLUDE/LIB` 找 arm64 版
`cl.exe`。在 PowerShell 里 `call` 一个 .bat 只影响子 cmd，**改不了 PowerShell 自身环境**；漏了这步，
所有 `.cu` 只会报 `error: process exited with code 1`，看不出真正原因。

### 5.2 产物与日志

| 产物 | 路径 | 体积（实测） |
|---|---|---|
| 引擎 | `TensorFold\build\native\bin\tensorfold-native.exe` | 36 MB，`PE32+ ARM64` |
| CUDA 自检工具 | `TensorFold\build\bin\tf-cuda-test.exe` | 78 MB |
| 构建日志 | `TensorFold\build\logs\05-build.log` | ANSI/GBK 编码 |

耗时：冷构建 5–8 分钟（首次要编全部 fatbin），增量一般 < 1 分钟。

日志编码要注意：`Get-Content -Encoding Default` 读（GBK），或用 Python `decode('gbk')`；
直接 UTF-8 读会得到乱码，nvcc 的中文 C4819 警告尤其容易干扰判读。

---

## 6. 冒烟（不加载模型）

```powershell
powershell -ExecutionPolicy Bypass -File scripts\6-smoke.ps1
```

三项与期望输出：

| 检查 | 期望 |
|---|---|
| `tensorfold-native.exe --help` | 打印 `usage: tensorfold-native --version \| capabilities --json \| ...` |
| `... capabilities --json` | `"version":"1.1.4"`、`"chip":"nvidia-sm121"`、`"backends":["cuda"]` |
| `tf-cuda-test.exe info` | `RESULT driver CUDA 13050, device NVIDIA RTX Spark N1X ..., sm_121, 48 SMs, ..., kernels embedded true` |

`kernels embedded true` 很关键：说明 fatbin 已编进 exe，**不需要** Triton AOT 核集。若为 `false`，
必须用 `tools/zig/flashnext_aot.py` 为**这个 exe** 生成 `build\kernels\sm121`。

> `tf-cuda-test` 把结果写在 stderr，PowerShell 会显示成 `NativeCommandError`（红字）——这是显示层的
> 误报，不代表失败，看 `RESULT` 行的内容即可。

---

## 7. 模型位置

### 7.1 两个预设（`scripts\config.ps1`）

| `CHECKPOINT` | 默认 `MODEL_PATH` | 权重 GiB | v1.1.4 CUDA 引擎可用？ |
|---|---|---|---|
| `nvfp4`（默认） | `D:\llm\model\Qwen3.8-Flash-Next-FP4-Local` | 81 | ✅ **唯一可用** |
| `int4` | `D:\llm\model\Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound` | 66 | ❌ GPTQ 布局，加载即 `UnsupportedCheckpoint` |

覆盖：`$env:MODEL_PATH='E:\models\xxx'; .\start.ps1`，或写进配方根目录 `.env`：

```ini
MODEL_PATH=D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

### 7.2 引擎的硬校验（`zig/src/families/flashnext/cuda_config.zig`）

引擎在读 `config.json` 时强制要求 **全部满足**，任一不符即 `UnsupportedCheckpoint` 并指出字段名：

- `architectures = ["Qwen4ExpForConditionalGeneration"]`，`model_type = "qwen4_exp"`
- `quantization_config.quant_method = "modelopt"`
- `quantization_config.quant_algo = "MIXED_PRECISION"`
- 不存在 `quantization_config.kv_cache_quant_algo`
- `quantized_layers`：逐层 NVFP4（routed experts，block 16）+ MXFP8（shared_expert / attention 投影，block 32）
- `tie_word_embeddings = false`

INT4-AutoRound 的 `quant_method = "gptq"` 直接落在第一条之外——**这不是配置问题，是格式不支持**。

### 7.3 目录布局（注意 `tensors\` 子目录）

实测的 FP4 checkpoint 是 **21 个分片放在 `tensors\` 子目录**、由 `model.safetensors.index.json` 的
`weight_map` 用相对路径引用（`tensors/model-00001-of-00021.safetensors`）：

```
Qwen3.8-Flash-Next-FP4-Local\        ≈ 96 GiB
├─ config.json                       ← 必须；引擎从这里读架构与量化布局
├─ model.safetensors.index.json      ← 必须；weight_map 指向 tensors\ 下分片
├─ tensors\
│  ├─ model-00001-of-00021.safetensors
│  └─ ... (共 21 片，metadata.total_size ≈ 102.1 GB)
├─ tokenizer.json / tokenizer_config.json / vocab.json / merges.txt
├─ generation_config.json
├─ preprocessor_config.json / video_preprocessor_config.json   ← vision
├─ chat_template.jinja
└─ configuration.json
```

不要把分片从 `tensors\` 挪到根目录——`index.json` 里的路径是相对的，挪了会找不到。

### 7.4 下载

```powershell
hf download nvidia/Qwen3.8-Flash-Next-FP4-Local `
  --revision b9ce18a6887e18c089fdea8509a33e63429a3300 `
  --local-dir D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

（`revision` 就是配方 `config.sh` 里 pin 的那一个。）

### 7.5 30 秒校验

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

或纯 PowerShell：

```powershell
$c = Get-Content "D:\llm\model\Qwen3.8-Flash-Next-FP4-Local\config.json" -Raw | ConvertFrom-Json
$c.architectures; $c.quantization_config.quant_method; $c.quantization_config.quant_algo
```

### 7.6 启动

```powershell
cd D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold
.\start.ps1                 # 首启加载 ~81 GiB：打全补丁约 71 s，原生路径约 257 s
.\start.ps1 restart         # 重启
.\stop.ps1                  # 停止
$env:DRY_RUN='1'; .\start.ps1   # 只打印 serve 命令行，不启动（排参神器）
```

---

## 8. 模型加载流水线（257 s → 71 s）

v1.1.4 的原生加载路径**不做**预量化缓存，每层都从原始 safetensors 现场装配 NVFP4 专家。这条路径在
Linux 上被配方补丁 0014（prompt-expert-tile）掩盖了成本问题，但在 Windows ARM64 上裸跑是 **257 s**。
`0003-load-pipeline.patch` 把它压到 **71 s**（引擎自报 `loaded in 67.6s`），且**不碰任何 `.cu`、kernel
参数、launch 配置与精度路径** —— 全部改动在 host 侧。

### 8.1 症状与根因（先排除的三个怀疑）

| 怀疑 | 实测 | 结论 |
|---|---|---|
| 磁盘慢 | 顺序读 5.0 GB/s | 不是 IO |
| 拷贝带宽不够 | 单次 HtoD 20+ GB/s | 不是 DMA |
| CUDA kernel 问题 | 加载期 GPU 利用率很高，但全是拷贝 | 不是 kernel |

真正的原因在 `zig/src/families/flashnext/cuda_modelopt_experts.zig` 的 `loadShape`：旧实现是

```zig
for (0..512) |i| {                          // 一层 512 个专家
    var gate  = try readPart(a, store, "…gate_proj", ...);   // 小拷贝 1
    var value = try readPart(a, store, "…up_proj",   ...);   // 小拷贝 2
    var output= try readPart(a, store, "…down_proj", ...);   // 小拷贝 3
    ex.packGateUp(...); ex.packOne(...);                     // 单线程重打包
    try up.upload(); try down.upload();                      // 每次 upload 后 stream.synchronize()
}
```

两个放大器让 1536 次小拷贝变成 257 s：

1. **一层专家散在 14 个 shard 里**，而 `cuda_prompt_wt.zig` 的 `Store` 映射环形缓存只有 **2 槽** →
   每层都要反复 close/reopen 分片并重新解析头部（全模型头部 50.6 MB，单文件最大 9.3 MB）。
   Windows 上 `mmap` 走的是 `VirtualAlloc` + 显式读，重解析没有 page cache 兜底。
2. `zig/src/core/nvfp4_slice.zig` 的 `slice()` **逐行** `@memcpy`，一层几千行，占读耗时约 1/3。

### 8.2 四项改动

| # | 文件 | 改动 | 单独贡献 |
|---|---|---|---|
| 1 | `cuda_modelopt_experts.zig` | 专家装配改为**分组并行**：512 专家切成 `32 组 × 16`，N 个 host 线程（默认 CPU 数，上限 32）用 `std.atomic.Value(usize)` 抢号，每线程只写自己那一格 stage（无锁、无 false sharing） | 主力，层耗时 5.0 s → 1.1 s |
| 2 | 同上 | **pinned 双缓冲 + CUDA 异步拷贝**：`cuda.HostBuffer`（`cuMemHostAlloc`）拿 page-locked 内存，`cuMemcpyHtoDAsync_v2` 投到非阻塞 copy stream；两组 stage 交替，`cuda.Event` 回压保证"被覆写前 DMA 已读完" | 拷贝等待 3 次全同步/层 → 18 ms/层 |
| 3 | `cuda_prompt_wt.zig` | 映射缓存 **2 → 48 槽**（`cached_shards`）；借用簿记加 `std.Io.Mutex`（**只在锁内记录指针，绝不在锁内做 IO**）；槽满时把已归还映射扫进缓存而不是关闭；新增 `dropShards()` 在 48 层读完后一次性释放（回收约 0.6 GB 头内存） | 消掉每层 14 次 reopen |
| 4 | `core/nvfp4_slice.zig` | 全宽张量（`from == 0 and to == k`）走**单次整块** `@memcpy`，保留逐行分支给切片 | 读耗时 −1/3 |

四个文件的判读要点：

- **pinned 是硬要求**：普通可分页内存调 `cuMemcpyHtoDAsync`，驱动会退回临时固定缓冲的同步拷贝，双缓冲白做。
- **event 回压不能省**：只做并行不做回压，20 个线程会集体卡在同一次 `sync` 上，收益砍掉一截；反过来
  完全不 sync 会覆写正在被 DMA 读的 stage。
- **对齐**：`packGateUp` 要 `[]u32`，所以 stage 切片必须先 `@alignCast` 到 `[]align(4) u8` 再
  `bytesAsSlice(u32, ...)`，否则编译期就报 `expected type '[]u32', found '[]align(1) u32'`。
- **锁的范围**：`Store` 的 mutex 只护 `held/released` 簿记（几十字节），IO 在锁外；否则并行度归零。

### 8.3 开关与度量

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `TENSORFOLD_LOAD_THREADS` | CPU 核数（≤32） | 并行装配线程数 |
| `TENSORFOLD_LOAD_GROUP` | 16 | 每组专家数 = 双缓冲粒度；越大越省同步，越吃 host 内存 |
| `TENSORFOLD_LOAD_SERIAL` | 0 | 置 1 退回逐专家路径（怀疑并行有问题时的对照） |
| `TENSORFOLD_LOAD_STATS` | 0 | 置 1 打分段计时 |

> **必须用 `TENSORFOLD_` 前缀**：配方 `scripts\config.ps1` 会逐行读 `.env` 并导出**每一个** key，
> 所以写 `TENSORFOLD_LOAD_STATS=1` 才会进到引擎进程。写成 `TF_LOAD_STATS` 会静默失效（我踩过）。

写进配方根目录 `.env` 后，`start.ps1` 的加载期就能看到：

```
info: flashnext: 512 experts in 32 groups of 16 on 20 threads: pack 698 ms, stage wait 18 ms, 1350 MiB
info: flashnext: rank 1/1 loaded layer 48/48
info: flashnext: layer 47 took 1170 ms
```

判读方法（本机 48 层实测）：

| 指标 | 实测 | 含义 |
|---|---|---|
| `layer N took` | mean 1116 ms，sum 53.6 s | 占 71 s 的 79% |
| `pack` | mean 698 ms，sum 34.2 s | **当前瓶颈**：单专家 3 投影 ≈ 27 CPU-ms |
| `stage wait` | sum 0.87 s | 拷贝已被完全掩盖，**双缓冲无余量可挖** |
| 差值 | 约 14 s | embedding / lm_head / FP8 n-gram 表 / attention 共享权重 |

> **分段日志在 stderr**：`build\logs\serve-*.err.log`（`info:` 行），不在 `.out.log`。用
> `grep -a` 或 `Get-Content -Encoding Default`，日志含 NUL 字节。

### 8.4 配方侧两个 PowerShell 5.1 bug（不修就测不到秒数）

加载本身变快之后，`start.ps1` 仍会报 `the server exited before it was ready`——因为 `scripts\config.ps1`
的健康探测在 PS 5.1 下抛异常，`while` 循环永远等不到 `$ready`，最后超时把自己判死。两处真 bug：

| 症状 | 根因 | 修法 |
|---|---|---|
| `无法发送具有此谓词类型的内容正文` | `param([string]$Body = $null)` 里 `$null` 变空串 → `$null -ne $Body` 恒真 → 空 body 走 GET；而 **PS 5.1 的 `Invoke-RestMethod` 默认动词是 POST**（6.0+ 才是 GET） | 改用 `[string]::IsNullOrEmpty($Body)`，并且**每个分支都显式传 `-Method`** |
| `找不到与参数名称"NoProxy"匹配的参数` | `-NoProxy` 是 PowerShell 6.0+ 才有的开关 | 5.1 分支改用 `[System.Net.WebRequest]::DefaultWebProxy = $null` 包 `try/finally` |

修好后 `start.ps1` 会输出 `server answered after 71s`（这个数字是**实测**的，不是估算）。

另一个容易误判的点：`config.ps1` 把 `ApiUrl` 映射到 `127.0.0.1`，所以 `BIND_HOST=0.0.0.0` 没问题；
**不要把 `0.0.0.0` 直接当 HTTP 目标**去请求。

### 8.5 边界与下一步

- 本机 20 核（GB10）**已全用满**，加线程没有空间；`pack` 34.2 s 是纯 host 计算，改不动。
- 再往下只有一条路：**跳过重打包** —— 写一次性工具把 checkpoint 预处理成引擎原生专家 blob（首次约 10
  分钟 + 约 80 GB 磁盘），之后加载退化为纯读 + DMA，估算 20 s。这属于新功能（新增产物、新增缓存失效
  逻辑），不要顺手做进补丁。
- 想验证"快得没把权重装错"：跑一次确定性问答（`capital of France` → `Paris`），比只看 `/health` 有效。
- 回归护栏：`loadShape` 只在 `@TypeOf(store) == *wt.Store` 时走并行，测试用的内存 mock 仍走串行；
  运行期分配失败会打 warn 自动退回逐专家路径。

---

## 9. `.ps1` 编写注意点（全部来自本次踩坑）

1. **`vcvarsall` 不能用 PowerShell `call`**。批处理只改子进程环境。必须生成 `.bat` 再用 `cmd /c` 跑，
   或把整条命令塞进 `cmd /c "..."`。这是“所有 fatbin 全挂”的唯一原因。
2. **没有 `&&`、`||`、三元 `?:`、`??`**（Windows PowerShell 5.1）。用 `; if ($?) { }` 分步判断。
3. **`$Host` 是自动变量**，不能当自定义变量。配方里用 `$BindHost` 就是这个原因。
4. **`2>&1` 打原生程序会污染 `$?`**：即使退出码 0，`$?` 也可能变 false。判断退出码请用 `$LASTEXITCODE`。
5. **`"$var:"` 会被解析成驱动器引用**（`$cand:` → 报“变量引用无效”）。用 `${var}:`。
6. **原生程序的 stderr 在 PowerShell 里显示成 `NativeCommandError`**。`tf-cuda-test info`、
   `nvcc --version` 都会这样；这是显示层误报，读输出内容而不是看红字。
7. **脚本首行加 `#Requires -Version 5.1`**，并把 `Set-Location $PSScriptRoot` 放在开头（双击运行时
   工作目录是 `C:\Windows\System32`）。
8. **判断架构别用 `$env:PROCESSOR_ARCHITECTURE`**（WOW64 下报 x86）。用
   `[System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture`。
9. **路径含空格**：`& "C:\Program Files\...\x.exe"` 或 `Start-Process -FilePath`；拼进 `.bat` 时加引号。
10. **代码页**：`.bat` 头部 `chcp 65001 >nul`，`.bat` 用无 BOM UTF-8 写；nvcc/日志是 GBK，
    `Get-Content -Encoding Default` 读。C4819 警告是“文件含当前代码页无法表示的字符”，**不是错误**。
11. **进程环境会跨次运行残留**：`[Environment]::SetEnvironmentVariable(..., 'Process')` 的值在本
    shell 里一直有效。所以脚本必须对“上次写进去的值”做校验，而不是假设它是干净的。
12. **`SetEnvironmentVariable($name, $null)` 不一定真的删掉变量**：.NET Framework 下可能留下空串。
    子进程若把“存在但为空”当非法值（TensorFold 的 `TENSORFOLD_CUDA_KERNELS` 就是），就会静默失败。
    **能显式给值就别删变量**（本例给 `native`）。
13. **`Start-Process -WindowStyle Hidden -RedirectStandardOutput/Err`** 启动后台服务，PID 落盘到
    `build\state`，`stop.ps1` 据此 kill——不要用 `Start-Job`（随 shell 退出而消失）。
14. **`$LASTEXITCODE` 在 `Start-Process` 后无效**，要用 `-PassThru` 拿进程对象再查。
15. **`$ErrorActionPreference='Stop'` + 原生程序 stderr = 脚本直接中断**。PowerShell 5.1 会把原生程序写到
    stderr 的普通信息（git 的进度、`tf-cuda-test info` 的结果行、nvcc 的部分输出）当成
    `NativeCommandError`，在 `Stop` 下变成终止错误。本 skill 的脚本一律用 `'Continue'`，靠
    `$LASTEXITCODE` 与文本判断——**这条坑我自己踩了一次**（冒烟脚本第一次跑就中断在这里）。
16. **`param([string]$Body = $null)` 里的 `$null` 会变成空串**，于是 `$null -ne $Body` **恒为真**，
    健康探测会带着空 body 发请求。判空要用 `[string]::IsNullOrEmpty($Body)`。
17. **PS 5.1 的 `Invoke-RestMethod` 默认动词是 POST**（6.0+ 才改成 GET）。空 body 的 POST 会抛
    `无法发送具有此谓词类型的内容正文`，所以**每个分支都显式传 `-Method`**。`-NoProxy` 也是 6.0+ 参数，
    5.1 上要用 `[System.Net.WebRequest]::DefaultWebProxy = $null` 包 `try/finally`。
18. **同一环境变量的不同大小写会撞车**：进程里同时存在 `HTTPS_PROXY` 与 `https_proxy` 时，
    `Get-ChildItem Env:` 抛“已添加了具有相同键的项”，连带 `Start-Process` 失败。启动前用
    `[Environment]::SetEnvironmentVariable($n, $null, 'Process')` 把两套名字都清掉。

---

## 10. 故障排查（按症状索引）

| 症状 | 根因 | 处置 |
|---|---|---|
| 所有 `.cu` 报 `error: process exited with code 1`，无其他信息 | 没进 `vcvarsall arm64` 环境 | 用 `5-build.ps1`（内部 `cmd /c` + vcvarsall） |
| `no instance of function template ... matches the specified type` | 显式实例化缺 `__restrict__` | 打 `0002` 补丁（第 4.3 节 #1–3） |
| `type 'void' does not support struct initialization syntax` | Windows 下 `std.posix.MAP` 是 `void` | 打 `0002`（#4） |
| `parameter of type 'void' not allowed ... aarch64_aapcs_win` | `clock_gettime` / `CLOCK` 在 Windows 无效 | 打 `0002`（#5） |
| `argument --kv-dtype: invalid choice: 'fp8'` | v1.1.4 把旗标改成 `--kv-cache` | `start.ps1` 用 `--kv-cache`（本 skill 的配方版本已含此修正） |
| `... with ...\build\kernels\sm121 glue kernels (Fp8KvUnsupported)` | 用了**旧引擎**留下的 AOT 核集 | 把该目录改名；`start.ps1` 会忽略 mtime 早于 exe 的核集 |
| `TENSORFOLD_CUDA_KERNELS= holds no aot.json` | 变量存在但为空 | 给 `native`（本 skill 的 `start.ps1` 已自动纠正） |
| `config.json's quantization_config.quant_method differs ...` / `UnsupportedCheckpoint` | 用了 GPTQ INT4 checkpoint | 改用 `nvfp4`（第 7 章） |
| 构建成功但 `start.ps1` 说 `tensorfold-native.exe not found` | 目录布局不对/名字不是 `TensorFold` | 按第 0 章摆好，或设 `NATIVE_BIN` |
| `vision is on but the venv python is missing` | 没建 venv | 第 3 章，或 `VISION=0` |
| 日志全是乱码 | GBK/UTF-16 编码 | `Get-Content -Encoding Default`、`iconv -f gbk` |
| `the server exited before it was ready` 且日志停在加载 | 模型不完整/格式不支持/内存不足 | 先查 `RESULT`/`UnsupportedCheckpoint`，再看 `build\logs\serve-*.err.log` |
| 加载要 4 分钟以上 | 没打 `0003` 补丁（走的是原生逐专家路径） | `3-apply-patches.ps1` 的输出里应能看到 `0003-load-pipeline.patch`；见第 8 章 |
| `start.ps1` 一直轮询到超时，但手动请求 `/health` 正常 | 配方 `config.ps1` 的健康探测在 PS 5.1 下抛异常（空 body + 默认 POST；`-NoProxy` 是 6.0+ 参数） | 按 8.4 修 `Invoke-LocalRest` |
| 设了 `TENSORFOLD_LOAD_STATS=1` 却没有分段计时 | 变量名没进引擎（必须 `TENSORFOLD_` 前缀且在 `.env` 里），或看错了日志 | 分段行在 `serve-*.err.log`，`info:` 开头 |
| `only 2 GiB host memory left while loading (MEM_FLOOR_GIB 4)` | staging 缓冲的正常占用，统一内存机型常见 | 只告警不阻断；要压下去就调小 `TENSORFOLD_LOAD_GROUP` |
| `--parallel 5 needs 23.74 GiB … leaves 22.81 GiB` | 5 流的 fp8 KV 超出内存准入（加载完成后才报） | `.env` 里固定 `PARALLEL=4`，或降 `CONTEXT` |

---

## 11. 交付验收清单

- [ ] `1-preflight.ps1` 全绿（0 FAIL）
- [ ] `git -C TensorFold rev-parse HEAD` == `eab8582819688325e371907e4706e1c602b8a273`
- [ ] `git -C TensorFold status --porcelain --untracked-files=all` 有 **78** 项（59 修改 + 19 新增），无冲突标记（`git diff | Select-String '<<<<<<<'` 为空）
- [ ] `3-apply-patches.ps1` 输出的三份 sha256 与第 4.1 节一致
- [ ] `5-build.ps1` 退出码 0，两个产物存在且 `file` 报 `PE32+ ARM64`
- [ ] `6-smoke.ps1` 三项 `[ OK ]`，且 `kernels embedded true`
- [ ] 模型 `config.json` 的 `quant_method=modelopt`、`quant_algo=MIXED_PRECISION`
- [ ] `DRY_RUN=1 .\start.ps1` 打印的命令行含 `--kv-cache fp8`（不是 `--kv-dtype`）
- [ ] `.env` 里没有指向旧核集/旧模型的残留项
- [ ] `.env` 里 `TENSORFOLD_LOAD_STATS=1`（可选 `PARALLEL=4`），且 `.\start.ps1` 报 **`server answered after ~71s`**（≤120 s 为准）
- [ ] `grep -a "layer .* took" build\logs\serve-*.err.log` 有 48 行，`stage wait` 合计 < 2 s（证明双缓冲生效）
- [ ] 加载后做一次确定性问答（如 `capital of France` → `Paris`），确认并行装配没有错位

深入原理见 `references/build-notes.md`；本次实测证据见 `references/verification.md`。
