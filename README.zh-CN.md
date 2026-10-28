# Qwen3.8-Flash-Next NVFP4 · Windows 11 ARM64

把 [MiaAI-Lab 的配方](https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold)移植到 Windows 11
ARM64（GB10 / `sm_121`）的**非官方**版本。同一个 NVFP4 权重、同一个 [TensorFold](https://github.com/ashhart/TensorFold)
引擎，**不用 Docker**：用 MSVC 为 ARM64 原生编出 `tensorfold-native.exe`，把配方的 shell 脚本换成 PowerShell，
并把模型加载从 **257 秒压到 71 秒**。

[English](README.md)

## 里面有什么

| 路径 | 是什么 |
|---|---|
| `patches/0001-recipe-0001-0017-on-v1.1.4.patch` | MiaAI-Lab 的 17 个配方补丁，合并成一份、对齐 TensorFold v1.1.4（`eab85828`），74 个文件 |
| `patches/0002-windows-arm64-port.patch` | 5 处 MSVC/Windows 兼容修复。三个 `.cu` 文件里只给模板显式实例化的参数表补 `__restrict__`，不动任何 kernel 算术 |
| `patches/0003-load-pipeline.patch` | 4 个 host 侧加载文件：分组并行装配、pinned 双缓冲、更大的分片映射缓存、整块拷贝 |
| `scripts/1-preflight.ps1` … `6-smoke.ps1`、`Invoke-Migration.ps1` | 迁移流程本身，一个脚本一步 |
| `recipe/start.ps1`、`stop.ps1`、`config.ps1`、`banner.ps1` | 配方 shell 脚本的 PowerShell 版，含两个 PowerShell 5.1 的真 bug 修复（`[string]` 默认值把 `$null` 变成空串；5.1 的 `Invoke-RestMethod` 默认动词是 POST） |
| `SKILL.md`、`references/` | 同一套流程的 agent 可执行形态（WorkBuddy / Claude skill 布局），外加构建笔记与验证记录 |
| `docs/patching-and-port.md` | 长文：每份补丁怎么切出来的、踩了什么、`.sh → .ps1` 的取舍逐条 |
| `NOTICE`、`LICENSES/`、`CREDITS.md` | 许可链。二次分发前先读 `NOTICE` |

## 快速开始

```powershell
git clone https://github.com/edisonchan/Qwen3.8-Flash-Next-NVFP4-Windows-ARM64
cd Qwen3.8-Flash-Next-NVFP4-Windows-ARM64

# 预检 -> 克隆两个仓库 -> 打 3 份补丁 -> vision venv -> 构建 -> 冒烟
.\scripts\Invoke-Migration.ps1 -Root D:\llm\latest
```

想逐步看每一段，就分开跑：

```powershell
.\scripts\1-preflight.ps1
.\scripts\2-clone.ps1
.\scripts\3-apply-patches.ps1 -TensorFold D:\llm\latest\TensorFold   # 期望 78 项、3 份补丁、2 处 spot-check 全绿
.\scripts\4-venv.ps1
.\scripts\5-build.ps1  -TensorFold D:\llm\latest\TensorFold          # BUILD_EXIT=0，约 5 分钟
.\scripts\6-smoke.ps1  -TensorFold D:\llm\latest\TensorFold          # version 1.1.4 / nvidia-sm121 / OK
```

起服务。克隆下来的配方里是 `.sh`，把 PowerShell 那四个拷进去：

```powershell
$Q = 'D:\llm\latest\Qwen3.8-Flash-Next-Single-DGX-Spark-TensorFold'
Copy-Item .\recipe\start.ps1, .\recipe\stop.ps1            $Q
Copy-Item .\recipe\config.ps1, .\recipe\banner.ps1  "$Q\scripts"

# 这类机器整机只有 30.5 GB host 内存：5 流要 23.74 GiB 的 KV，准入预算 22.81 GiB，放不下；
# 而且它是 48 层全加载完之后才报错，很容易误判成"加载慢"。4 流可以正常起服。
Add-Content "$Q\.env" @('TENSORFOLD_LOAD_STATS=1', 'PARALLEL=4')

& "$Q\start.ps1"    # [start.ps1] server answered after 71s
& "$Q\stop.ps1"
```

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

## 许可

本仓库自己的代码 MIT；补丁所修改的 TensorFold 代码是 Apache-2.0（0.6.0 之前的代码另有 MIT 声明）；
被移植的配方补丁是 MiaAI-Lab 的 MIT。`LICENSE` 是纯 MIT 正文、两个版权人都在里面（这样 GitHub 能识别为 MIT）；
哪个文件归哪条，`NOTICE` 里写清楚了，全文都在 `LICENSES/`。不含权重、不含二进制——不会误授权。

与 MiaAI-Lab、TensorFold 作者、NVIDIA、通义千问团队**无隶属关系**，也未经其背书。
