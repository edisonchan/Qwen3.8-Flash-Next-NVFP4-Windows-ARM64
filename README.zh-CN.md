# Qwen3.8-Flash-Next NVFP4 · Windows 11 ARM64

把 [MiaAI-Lab 的配方](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)移植到 Windows 11
ARM64（GB10 / `sm_121`）的**非官方**版本。同一个 NVFP4 权重、同一个 [TensorFold](https://github.com/ashhart/TensorFold)
引擎，**不用 Docker**：用 MSVC 为 ARM64 原生编出 `tensorfold-native.exe`，把配方的 shell 脚本换成 PowerShell，
并把模型加载从 **257 秒压到 71 秒**。

[English](README.md)

## 版本钉死

这套移植只在**一个**版本组合上验证过。脚本里已经把它钉住，所以今天 clone 下来构建出的树，与实测的那棵树一致；
每一处钉住的理由、以及挪动它会坏在哪，见 [`VERSIONS.md`](VERSIONS.md)。

| 组件 | 钉到 |
|---|---|
| TensorFold 引擎 | tag **`v1.1.4`** = `eab8582819688325e371907e4706e1c602b8a273`（与配方自己的 `TF_REF` 同一个提交） |
| MiaAI-Lab 配方 | commit **`fd3f43e11238553685ebb68b6d8ab2b112818e3c`**，其 `patches/0001..0017` 即补丁 0001 的来源 |
| 模型权重 | `nvidia/Qwen3.8-Flash-Next-FP4-Local` @ **`b9ce18a6887e18c089fdea8509a33e63429a3300`**（NVFP4，`modelopt` / `MIXED_PRECISION`，96 GB） |
| 工具链 | zig **0.17.0** aarch64-windows · CUDA toolkit **13.4**（`V13.4.92`）· MSVC **v143 14.44.35207** arm64 |
| 补丁序列 | `0001` + `0002` + `0003`，三份哈希见 [`VERSIONS.md` §2](VERSIONS.md) |

## 里面有什么

| 路径 | 是什么 |
|---|---|
| `patches/0001-recipe-0001-0017-on-v1.1.4.patch` | MiaAI-Lab 的 17 个配方补丁，合并成一份、对齐 TensorFold v1.1.4（`eab85828`），74 个文件 |
| `patches/0002-windows-arm64-port.patch` | 5 处 MSVC/Windows 兼容修复。三个 `.cu` 文件里只给模板显式实例化的参数表补 `__restrict__`，不动任何 kernel 算术 |
| `patches/0003-load-pipeline.patch` | 4 个 host 侧加载文件：分组并行装配、pinned 双缓冲、更大的分片映射缓存、整块拷贝 |
| `scripts/migration.config.ps1` | 路径的唯一来源：探测 root、python、zig、CUDA、`vcvarsall`、权重目录；交互选单；结果存到 `.migration.local.json` |
| `scripts/engine/1-preflight.ps1` … `6-smoke.ps1` | **引擎侧**（TensorFold）：预检、克隆、3 份补丁、vision venv、构建、冒烟 |
| `scripts/recipe/1-install-ps1.ps1` | **配方侧**，也是唯一往 MiaAI-Lab 克隆里写东西的脚本：放 4 个 `.ps1`、把 `MODEL_PATH` 写进 `.env`，别的都不动 |
| `scripts/Invoke-Migration.ps1` | 一键总控：先问路径，再选跑引擎侧、配方侧还是两边 |
| `recipe/start.ps1`、`stop.ps1`、`config.ps1`、`banner.ps1` | 配方 shell 脚本的 PowerShell 版，含两个 PowerShell 5.1 的真 bug 修复（`[string]` 默认值把 `$null` 变成空串；5.1 的 `Invoke-RestMethod` 默认动词是 POST） |
| `SKILL.md`、`references/` | 同一套流程的 agent 可执行形态（WorkBuddy / Claude skill 布局），外加构建笔记与验证记录 |
| `docs/patching-and-port.md` | 长文：每份补丁怎么切出来的、踩了什么、`.sh → .ps1` 的取舍逐条 |
| `NOTICE`、`LICENSES/`、`CREDITS.md` | 许可链。二次分发前先读 `NOTICE` |
| `VERSIONS.md` | 钉死的引擎 / 配方 / 权重 / 工具链版本、补丁哈希，以及挪动任一版本会坏在哪 |

## 快速开始

```powershell
git clone https://github.com/edisonchan/Qwen3.8-Flash-Next-NVFP4-Windows-ARM64
cd Qwen3.8-Flash-Next-NVFP4-Windows-ARM64

.\scripts\Invoke-Migration.ps1
```

它先列出它认为的各个位置（root、python、zig、CUDA、`vcvarsall`、权重目录），每一行都可以改；然后问你跑
哪一半。没有任何路径写死，换盘、换目录都能用。

想逐步看每一段，就分开跑：

```powershell
.\scripts\engine\1-preflight.ps1
.\scripts\engine\2-clone.ps1
.\scripts\engine\3-apply-patches.ps1          # 期望 78 项、3 份补丁、2 处 spot-check 全绿
.\scripts\engine\4-venv.ps1                   # 先从 NVIDIA 索引装 torch，再装 tensorfold[vision]
.\scripts\engine\5-build.ps1                  # BUILD_EXIT=0，约 5 分钟
.\scripts\engine\6-smoke.ps1                  # version 1.1.4 / nvidia-sm121 / OK
.\scripts\recipe\1-install-ps1.ps1            # 4 个 .ps1 放进配方克隆
```

每一步都读已保存的路径，所以都不用传参数。真要覆盖就直接传（`-TensorFold E:\ai\TensorFold` 这种），
`-Reset` 会重新问一遍路径。

### 路径

`scripts\migration.config.ps1` 是唯一决定"东西放哪"的地方。它先探测候选：root 取本仓库所在的目录，
python / zig 取 `PATH` 与常见安装目录，CUDA 取 `CUDA_PATH` 与 toolkit 安装根，`vcvarsall` 取任意 VS 2022
安装，权重取 `MODEL_PATH` 与 `<root 的上级>\model`；然后选单让你确认或修改。确认后的结果写进
`.migration.local.json`（已 git 忽略），下次一键复用，所有脚本看到的是同一组值。

参考机上的样子（你的机器探测到什么就显示什么）：

```
 [1] root     D:\llm\latest
 [2] python   C:\Users\you\AppData\Local\Programs\Python\Python313-arm64\python.exe
 [3] zig      D:\llm\zig-aarch64-windows-0.17.0\zig.exe
 [4] cuda     C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.4
 [5] vcvars   C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvarsall.bat
 [6] model    D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

引擎与配方目录由 `root` 推导（`<root>\TensorFold`、`<root>\Qwen3.8-Flash-Next-…`），因为配方自己的
`config.ps1` 就是这么找同级引擎的；可选的只有 `root`。

### 两半、两个仓库

| | 动到什么 | 脚本 |
|---|---|---|
| **引擎** | TensorFold：打 3 份补丁，然后构建 | `scripts\engine\` |
| **配方** | MiaAI-Lab 的克隆：加 4 个 `.ps1`，`.env` 写入 `MODEL_PATH`——他们的代码一行不改 | `scripts\recipe\` |

`recipe\1-install-ps1.ps1` 自己会验这句话：结束时跑 `git -C <配方> status --porcelain`，期望只有新增文件、
没有修改。

两个克隆都是**钉版本**，不是跟分支：引擎钉 `v1.1.4`，配方钉在补丁 `0001` 所对应的那个提交（见
[`VERSIONS.md`](VERSIONS.md)）。若配方的 `main` 已经走过该提交，`2-clone.ps1` 会给出告警；
只有你确实想跟随时才传 `-RecipeRef ''`。

起服务。克隆下来的配方里是 `.sh`，安装脚本把 PowerShell 那四个放到旁边：

```powershell
.\scripts\recipe\1-install-ps1.ps1      # start.ps1、stop.ps1、scripts\config.ps1、scripts\banner.ps1

# 路径不用手打：读回选单接受的那一份
$root = (Get-Content .migration.local.json -Raw | ConvertFrom-Json).root
$Q    = Join-Path $root 'Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'
# 这类机器整机只有 30.5 GB host 内存：5 流要 23.74 GiB 的 KV，准入预算 22.81 GiB，放不下；
# 而且它是 48 层全加载完之后才报错，很容易误判成"加载慢"。4 流可以正常起服。
Add-Content "$Q\.env" @('TENSORFOLD_LOAD_STATS=1', 'PARALLEL=4')

& "$Q\start.ps1"    # [start.ps1] server answered after 71s
& "$Q\stop.ps1"
```

### Python 与 torch

`engine\4-venv.ps1` 在**配方目录里**建 venv（`<配方>\venv`），因为 `start.ps1` 就在那儿找
`Scripts\python.exe`。它按这个顺序装：

```powershell
# 1. torch 来自 NVIDIA 的 out-of-tree nightly 索引——配方在自家平台上是靠 nvcr.io/nvidia/pytorch
#    基础镜像拿到这些包的，而 Windows 上没有那个镜像
python -m pip install --pre --upgrade --only-binary=:all: `
  --extra-index-url https://pypi.nvidia.com/nvtorch_oot_nightly torch torchvision torchaudio

# 2. vision 包；v1.1.4 的 setup.py 拒绝以 Python 包安装，所以用 v0.6.6
python -m pip install "tensorfold[vision] @ git+https://github.com/ashhart/TensorFold.git@v0.6.6"

# 3. start.ps1 开 vision 之前跑的那条探测
python -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('tensorfold.vision.native_helper') else 1)"
```

顺序有意义：先装 `tensorfold[vision]` 的话，pip 会把 PyPI 上的普通 torch 当依赖拉进来。纯文本服务
（`VISION=0`）可以整段跳过；已经有可信 torch 的话加 `-SkipTorch`。

### 权重

不在本仓库。两个源是同一份导出，占盘约 96 GiB：

```powershell
# Hugging Face
hf download nvidia/Qwen3.8-Flash-Next-FP4-Local --revision b9ce18a6887e18c089fdea8509a33e63429a3300 --local-dir D:\llm\model\Qwen3.8-Flash-Next-FP4-Local

# ModelScope 镜像（国内通常更快；需先 pip install modelscope）
modelscope download --model nv-community/Qwen3.8-Flash-Next-FP4-Local --local_dir D:\llm\model\Qwen3.8-Flash-Next-FP4-Local
```

`recipe/config.ps1` 的 `MODEL_PATH` 默认就是这个目录；换目录在 `.env` 里改 `MODEL_PATH`。

镜像只是换了托管方，不是换了模型——所以下完先确认是这台引擎能吃的那份导出：`config.json` 里必须是
`quant_method: modelopt`、`quant_algo: MIXED_PRECISION`。GPTQ 的二次上传会在加载时报
`UnsupportedCheckpoint`。无论从哪个源下载，许可条款都跟着权重走：FP4 导出适用 NVIDIA Open Model Agreement，
底座模型适用 Qwen Community License 1.0。

## 加载：257 秒 → 71 秒

48 层、每层 512 个路由专家，从每层 14 个 checkpoint 分片现场装配。

| | 改之前 | 改之后 |
|---|---|---|
| 整机加载 | 257 s | **71 s** |
| 每层 | 约 5.0 s | **1.12 s** |
| 专家打包（CPU） | 串行，一个一个来 | 698 ms，20 线程 |
| 每层 HtoD 等待 | 3 次全同步 | **18 ms**（`stage wait`，占 1.6%） |

四处改动全在 host 侧，**没有动任何 `.cu`，也没有改 kernel 启动配置**：分组并行装配（32 组 × 16 专家，
用满全部核心）、pinned 双缓冲 + 独立 stream 上的 `cuMemcpyHtoDAsync` + 事件回压、分片映射缓存从 2 槽扩到
48 槽（一层的 14 个分片一次 hold 住，不再每层重开并重解析文件头）、全宽张量改整块 `memcpy`。

判断「双缓冲够不够」只看 `stage wait` 一个指标：67.6 秒里它只占 0.87 秒。哪天它涨到几个百分点，
先调 `TENSORFOLD_LOAD_GROUP`，不要去碰 CUDA。

## 环境要求

Windows 11 ARM64 · GB10（128 GB 统一内存、20 核）· CUDA 13.4 · Zig 0.17.0（aarch64-windows）·
MSVC 2022 Build Tools（含 ARM64 host）· PowerShell 5.1 · 仅 `--vision` 需要 Python 3.13 arm64。

没有任何路径是写死的：`scripts\migration.config.ps1` 负责找，`.migration.local.json` 记住你确认过的值。
`1-preflight.ps1` 对 zig ≠ 0.17.0 直接判失败，对 nvcc 不是 13.4 给告警。

## 许可

本仓库自己的代码 MIT；补丁所修改的 TensorFold 代码是 Apache-2.0（0.6.0 之前的代码另有 MIT 声明）；
被移植的配方补丁是 MiaAI-Lab 的 MIT。`LICENSE` 是纯 MIT 正文、两个版权人都在里面（这样 GitHub 能识别为 MIT）；
哪个文件归哪条，`NOTICE` 里写清楚了，全文都在 `LICENSES/`。不含权重、不含二进制——不会误授权。

与 MiaAI-Lab、TensorFold 作者、NVIDIA、通义千问团队**无隶属关系**，也未经其背书。

## 致谢

本仓库只是一层薄脚本，真正让它跑起来的东西几乎都是别人做的。逐条（精确到每个补丁）的完整记录在
[`CREDITS.md`](CREDITS.md)，每个文件归哪条许可在 [`NOTICE`](NOTICE)。

**模型。** [Qwen3.8 Flash Next](https://huggingface.co/Qwen/Qwen3.8-Flash-Next)，作者是阿里巴巴
[通义千问团队](https://huggingface.co/Qwen)：模型设计、训练、对话模板与 MTP 头，许可为
[Qwen Community License 1.0](https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE)。

**权重。** [`nvidia/Qwen3.8-Flash-Next-FP4-Local`](https://huggingface.co/nvidia/Qwen3.8-Flash-Next-FP4-Local)
由 **NVIDIA** 出品：以 bf16 模型为教师做量化感知蒸馏（QAD）、用 NVIDIA Model Optimizer 导出——NVFP4 路由专家
配 CSF 压缩缩放因子、MXFP8 的注意力 / DeltaNet / 共享专家、NVFP4 n-gram 表、量化后的 MTP 与视觉塔。适用
[NVIDIA Open Model Agreement](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-open-model-agreement/)，
同时继承 Qwen 许可。可选的 `CHECKPOINT=int4` 预设是 **azampatti** 的
[`azampatti/Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound`](https://huggingface.co/azampatti/Qwen3.8-Flash-Next-125B-A5B-INT4-AutoRound)
（top-5 专家裁剪、共享专家修复、打包），基于 **Intel** 的
[AutoRound W4A16](https://huggingface.co/Intel/Qwen3.8-Flash-Next-W4A16-AutoRound) 与 **Saren-Arterius** 的混合
checkpoint；更早的 MLX 4-bit 路线来自
[`Vontra/Qwen3.8-Flash-Next-MLX-4bit-MTP`](https://huggingface.co/Vontra/Qwen3.8-Flash-Next-MLX-4bit-MTP)。

**引擎。** [TensorFold](https://github.com/ashhart/TensorFold)，作者 **Ash Hart**
（[ashhart](https://github.com/ashhart)）与 TensorFold 贡献者：Zig 引擎 `tensorfold-native`、CUDA 运行时与
kernel、带精确校验的 MTP 草稿、OpenAI 兼容服务端（v0.6.0 起 Apache 2.0，之前是 MIT）。Zig 侧的 CUDA 服务
路径与 CUDA family registry 是 **Jürgen Schmied**（[jschmied](https://github.com/jschmied)）在
[PR #443](https://github.com/ashhart/TensorFold/pull/443) 里的工作。用 **[Zig](https://ziglang.org)** 0.17.0
（Zig 软件基金会，MIT）与 CUDA 13.4 构建。

**配方与补丁。** [MiaAI-Lab 的配方](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)
（commit `fd3f43e`）、它在 TensorFold v1.1.4 上的 17 个补丁、`start.sh` / `stop.sh` / `scripts/`、`tools/` 里的
检查脚本，以及更早的 db281878 系列，都是 **MiaAI-Lab** 的成果。其中被继承的贡献者还有：
[tempeste](https://github.com/tempeste)（drain 后释放、准入回收、prompt cache 里的图像 prompt）、
[BadAd84](https://github.com/BadAd84)（分片填充，PR #53）、
[MovieMaker93](https://github.com/MovieMaker93)（prefill 行，TensorFold #40）、
[jvr0x](https://github.com/jvr0x)（多语言草稿词表）、
[321sssrt-bit](https://github.com/321sssrt-bit)（整窗准入、`tools/context_boundary.py`）。
本文件里的性能数字是用 [sparkDash](https://github.com/MiaAI-Lab/sparkDash) 测的。

**运行时。** CUDA / NCCL 来自 NVIDIA；[transformers](https://github.com/huggingface/transformers)、
[Hugging Face Hub](https://huggingface.co/)、[safetensors](https://github.com/huggingface/safetensors)；
[Triton](https://github.com/triton-lang/triton)（引擎回放它编译出的 cubin）；
[PyAV](https://github.com/PyAV-Org/PyAV) + [FFmpeg](https://ffmpeg.org/)（视频）、
[Pillow](https://python-pillow.org/)（图像）；Windows 上的 torch / torchvision 来自 NVIDIA 的
`pypi.nvidia.com/nvtorch_oot_nightly` 索引。Linux 上这些都由 `nvcr.io/nvidia/pytorch:26.07-py3` 镜像提供，
Windows 上那个镜像不存在，由 venv 顶上（见上面《Python 与 torch》）。

**硬件。** 这里的每个数字都测于一
[NVIDIA DGX Spark](https://www.nvidia.com/en-us/products/workstations/dgx-spark/)（GB10 Grace Blackwell，
128 GB 统一内存，20 核，48 SMs，`sm_121`）。

如果你觉得上面漏了人或写错了，请开 issue。
