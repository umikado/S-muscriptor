# MuScriptor Control：macOS 控制应用

这是一个小型原生 macOS 应用，用来启动本地 MuScriptor、打开网页和停止服务。
应用复用当前仓库的 `.venv` 和已经下载的模型，无需一直打开终端。

## 首次生成应用

需要 macOS 13+、已完成的 MuScriptor 本地安装和网页构建，以及 Apple Command Line Tools。
在 Mac 的终端执行：

```bash
cd "/Users/Umikado/Documents/GitHub/S-muscriptor"
git pull --ff-only origin work
bash scripts/build-macos-app.sh
```

脚本会使用 Mac 自带开发工具中的 Swift 编译器生成并本地签名应用，安装到：

```text
~/Applications/MuScriptor Control.app
```

如果提示找不到 Swift 编译器，先执行 `xcode-select --install`，完成安装后重试构建。
如果之前的 MuScriptor 环境已经正常运行，不需要重新下载模型或重建 Python 环境。

打开应用：

```bash
open "$HOME/Applications/MuScriptor Control.app"
```

也可以在 Finder 中按 `Command+Shift+G`，输入 `~/Applications` 后双击应用，或将它拖到 Dock。

## 日常使用

1. 选择 Medium、Large 或 Small。默认使用 Medium。
2. 点击“启动服务”。首次使用某个模型时，仍需已经接受其 Hugging Face 许可并登录。
3. 状态变成“运行中”后，点击“打开页面”。页面地址是 <http://127.0.0.1:8222>。
4. 使用完毕点击“停止服务”。加载模型期间也可以停止。

关闭应用窗口或使用 `Command+Q` 退出时，会自动停止它启动的服务。
停止时先发送与终端 `Control+C` 相同的中断信号；服务无响应时，再结束其专用进程组。
模型缓存不会因此删除。

如果 8222 端口上已有从终端或其他应用启动的服务，应用会提示端口占用。
检测到它是 MuScriptor 时仍可打开网页；要改用应用管理，先回原终端按 `Control+C`，再点击“启动服务”。
应用不会按端口或进程名终止其他程序。

## 模型缓存和项目位置

默认继续使用 Hugging Face 的默认缓存，因此可以直接复用之前下载的 medium。
生成应用时，如果终端设置了 `HF_HUB_CACHE`，脚本会把该缓存路径记录到应用配置中。

以后需要使用外置 SSD 时：

1. 先停止服务。
2. 从顶部“MuScriptor Control”菜单选择“选择模型缓存文件夹…”。
3. 选择 Hub 缓存根目录，也就是包含 `models--MuScriptor--muscriptor-medium` 等目录的那一层。
4. 再启动服务。该设置会被记住；选择文件夹不会自动迁移旧模型。

菜单中的“使用默认模型缓存”可以恢复默认位置。外置盘未挂载时会给出提示。
Finder 启动的应用不会读取终端的 `~/.zshrc`，后续缓存变更请使用应用菜单。

仓库移动后，可从同一菜单选择“选择项目文件夹…”。所选项目必须已经有 `.venv` 和构建好的网页。
应用启动的服务使用该项目的 Python，不依赖 Finder 的 PATH 中是否能找到 uv。

## 日志和升级

点击“查看日志”可查看下载、加载、转录进度和错误。日志位置为：

```text
~/Library/Logs/MuScriptor Control/server.log
~/Library/Logs/MuScriptor Control/controller.log
```

项目更新后，Python 服务会使用更新后的源码；如果控制应用本身有更新，请先退出应用，再重新执行构建脚本。
控制应用升级会保留模型选择、项目路径和缓存位置设置。

## 验证范围

进程控制测试使用轻量 HTTP 服务，覆盖启动与重启、健康检查、端口占用、加载中取消、停止超时、缓存路径，以及控制程序退出后的服务清理：

```bash
python3 -m unittest tests.test_macos_controller -v
```

原生窗口、Swift 编译、真实 MPS 转录和 macOS 上的退出行为还需要在目标 Mac 上验收。
