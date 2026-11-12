# MuScriptor 本地运行方案：Apple Silicon Mac

## 目标和当前进展

项目目标是提供既能在本地电脑、也能在云端运行的 Audio → MIDI 工具。
当前优先在 Mac Studio（M4 Max、128 GB 统一内存、macOS 26.7.2）上使用现有 MuScriptor 网页界面。

已经完成仓库功能梳理、模型选择调研，以及本地安装和外置磁盘缓存方案的整理。
目标 Mac 已完成原生 arm64 环境安装、MPS 可用性检查、medium 下载和首次网页转录试运行。
medium 的初步效果已得到使用者认可；尚未记录准确率、耗时、峰值内存或 large 对比数据。
仓库当前版本为 0.4.0，已经包含 Python 推理、CLI、FastAPI、React 网页和 Docker 部署配置。

## 运行方式和模型选择

在 macOS 上使用原生 Python 环境和 PyTorch MPS 加速。浏览器访问本机服务，实际推理在 Mac 上进行。
当前源码在 MPS 上默认使用 float16 Transformer 权重，音频条件处理保留 float32。

先用 `medium` 验证完整流程，作为日常默认；再用 `large` 对相同素材进行质量和耗时对比。
128 GB 统一内存适合评估 `large`，但尚无这台机器的实测耗时或峰值内存数据。

| 模型 | 参数量（仓库说明） | 单个权重文件的近似磁盘大小 | 建议用途 |
| --- | ---: | ---: | --- |
| small | 103M | 412 MB | CPU 或资源较少的设备 |
| medium | 307M | 1.2 GB | 首次验证和日常使用 |
| large | 1.4B | 5.5 GB | 对质量要求更高的素材 |

大小对应 Hugging Face 上的 `model.safetensors`，不包含 Python、PyTorch、节拍检测模型、试听音源或缓存副本。
三个权重合计约 7 GB，只会按需下载选中的模型。

官方的规模实验中，large 相对 medium 的各项 F1 提升约为 0.5–0.8 分。
这组实验仅使用真实音频训练，不能直接代表经过完整预训练和后训练的发布权重之间的差距。
两档的最终效果需要使用相同音频、相同乐器条件和导出设置进行对比。
参考[官方评测说明](https://huggingface.co/MuScriptor/muscriptor-medium#evaluation)。

## 安装步骤

以下命令在目标 Mac 的终端执行。如果已经有本地仓库，进入现有仓库目录后跳过克隆步骤。

### 1. 工具和 Python 环境

需要 Git、[uv](https://docs.astral.sh/uv/getting-started/installation/) 和 Node.js 22.12 或更新版本。
已安装 Homebrew 时可以使用：

```bash
brew install git uv node
git clone https://github.com/umikado/S-muscriptor.git
cd S-muscriptor
uv sync --frozen
```

uv 按仓库的 `.python-version` 管理 Python 3.13，并在项目中创建虚拟环境。

### 2. 模型授权和登录

在 Hugging Face 接受准备使用的模型许可：

- [medium](https://huggingface.co/MuScriptor/muscriptor-medium)
- [large](https://huggingface.co/MuScriptor/muscriptor-large)

模型权重采用 CC BY-NC 4.0 非商业许可，仓库代码采用 MIT 许可。然后在终端登录：

```bash
uvx hf auth login
```

登录凭证由本机 Hugging Face 工具管理，不要写进代码或提交到仓库。

### 3. 检查 Apple GPU 加速

```bash
uv run python -c "import torch; print(torch.__version__); print('MPS:', torch.backends.mps.is_available())"
```

预期输出包含 `MPS: True`。若为 `False`，先检查终端及 Python 是否以原生 arm64 运行，以及 PyTorch 安装情况。

### 4. 构建网页

使用 `web/package.json` 指定的 pnpm 10.20.0：

```bash
cd web
npx --yes pnpm@10.20.0 install --frozen-lockfile
npx --yes pnpm@10.20.0 run build
cd ..
```

前端产物写入 `muscriptor/web_dist/`，由 Python 服务提供。日常启动不需要单独运行 Vite；修改前端后需重新构建。

## 模型缓存和外置 SSD

默认的 Hugging Face Hub 缓存目录是 `~/.cache/huggingface/hub/`。
例如 large 的缓存位于其中的 `models--MuScriptor--muscriptor-large/` 目录。

可以将缓存放到外置 SSD。推荐 APFS 格式；先确认磁盘已挂载，并将示例中的 `AudioSSD` 替换成实际盘名：

```bash
export HF_HUB_CACHE="/Volumes/AudioSSD/AI/huggingface/hub"
```

在启动 MuScriptor 的同一终端设置该变量。需要在新终端自动生效时，将这行配置加入 `~/.zshrc`。
MuScriptor 权重、配置和通过 Hugging Face 下载的试听音源会使用该缓存。
Python 环境、uv 缓存及节拍检测组件的缓存仍按各自配置存放。

该设置不会自动搬迁已经下载的文件；可以先停止服务，再迁移完整 Hub 缓存，或在新位置重新下载。
模型加载后主要在统一内存中工作，磁盘速度主要影响启动加载和下载。

## 启动和使用

从仓库根目录启动。如果使用外置盘，先在同一终端设置上面的 `HF_HUB_CACHE`。

```bash
uv run muscriptor serve --model medium --device mps --host 127.0.0.1 --port 8222
```

打开 <http://127.0.0.1:8222>，上传音频或选择内置示例，完成转录、试听和 MIDI 下载。
首次使用需要联网下载相应资源。终端保持运行；按 `Control+C` 停止服务。

切换到 large 前先停止当前服务，再运行：

```bash
uv run muscriptor serve --model large --device mps --host 127.0.0.1 --port 8222
```

也可以直接使用 CLI 转录仓库自带的短音频：

```bash
uv run muscriptor transcribe web/public/headache_by_lost_deposit_10s.mp3 --model medium --device mps --output demo.mid
```

## 可选功能

| 功能 | 额外要求 |
| --- | --- |
| MIDI 导出、网页内试听 | 上述安装和自动下载的试听音源 |
| 合成 WAV、原音与合成音对比 WAV 导出 | FluidSynth，可通过 `brew install fluid-synth` 安装 |
| MusicXML、总谱和分谱 PDF 导出 | [MuseScore 4 或更新版本](https://musescore.org/en/download) |

## 验收和后续使用

- 已确认原生 arm64、MPS 可用、medium 能加载，并完成首次网页转录试运行。
- 继续检查内置示例及一段约 30 秒的自有音频的进度、钢琴卷帘图、试听和 MIDI 下载。
- 将 MIDI 导入 DAW，检查音高、漏音和多余音符、音符长度、乐器分轨及节奏对齐。
- 用相同素材和设置对比 medium 与 large，记录模型加载时间、转录耗时、峰值内存和修谱工作量。
- 验证一首完整歌曲，以及重启服务后的缓存复用。
- 如需离线使用，提前缓存转录模型、节拍检测模型和音源，并在断网后分别验证转录和试听。

日常启动、打开页面和停止服务可使用[原生 macOS 控制应用](macos-control-app.md)。首次生成应用后即可双击使用。

## 后续音频分轨方向

当前 MuScriptor 输出多乐器 MIDI，不包含原音频的 stem 分离功能。
此前讨论过 UVR5 及通过 [python-audio-separator](https://github.com/nomadkaraoke/python-audio-separator) 接入其模型的路线，尚未集成或实测。
具体分离粒度取决于所选模型；常见四轨或六轨模型无法保证把所有乐器独立还原。
更多乐器的自动发现和分离仍需单独评估，也需验证分离后是否改善 MIDI 转录质量。
