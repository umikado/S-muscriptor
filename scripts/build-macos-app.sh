#!/bin/bash
set -euo pipefail

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "请在运行 MuScriptor 的 Mac 上执行此脚本。" >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app_destination="${1:-$HOME/Applications/MuScriptor Control.app}"
bundle_id="org.umikado.muscriptor.control"

if [[ "$app_destination" != /*.app ]]; then
    echo "应用目标必须是以 .app 结尾的绝对路径。" >&2
    exit 1
fi
if ! xcrun --find swiftc >/dev/null 2>&1; then
    echo "找不到 Swift 编译器，请先执行 xcode-select --install，安装完成后重试。" >&2
    exit 1
fi
if [[ ! -x "$repo_root/.venv/bin/python" ]]; then
    echo "请先在项目目录执行 uv sync --frozen。" >&2
    exit 1
fi
if [[ ! -f "$repo_root/muscriptor/web_dist/index.html" ]]; then
    echo "请先在 web 目录完成前端构建（pnpm run build）。" >&2
    exit 1
fi
if [[ -e "$app_destination" ]]; then
    existing_id="$(plutil -extract CFBundleIdentifier raw -o - "$app_destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$existing_id" != "$bundle_id" ]]; then
        echo "目标位置已有其他文件或应用，请选择不同的 .app 路径。" >&2
        exit 1
    fi
fi

build_root="$(mktemp -d "${TMPDIR:-/tmp}/muscriptor-control.XXXXXX")"
trap 'rm -rf "$build_root"' EXIT
app_bundle="$build_root/MuScriptor Control.app"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources"

xcrun swiftc -swift-version 5 -parse-as-library -O \
    -target "$(uname -m)-apple-macosx13.0" \
    -framework AppKit \
    "$repo_root/macos/MuScriptorControl.swift" \
    -o "$app_bundle/Contents/MacOS/MuScriptorControl"

info="$app_bundle/Contents/Info.plist"
plutil -create xml1 "$info"
plutil -insert CFBundleIdentifier -string "$bundle_id" "$info"
plutil -insert CFBundleExecutable -string MuScriptorControl "$info"
plutil -insert CFBundleName -string "MuScriptor Control" "$info"
plutil -insert CFBundleDisplayName -string "MuScriptor Control" "$info"
plutil -insert CFBundlePackageType -string APPL "$info"
plutil -insert CFBundleShortVersionString -string 0.1.0 "$info"
plutil -insert CFBundleVersion -string 1 "$info"
plutil -insert LSMinimumSystemVersion -string 13.0 "$info"
plutil -insert LSMultipleInstancesProhibited -bool YES "$info"
plutil -insert NSHighResolutionCapable -bool YES "$info"
plutil -insert NSPrincipalClass -string NSApplication "$info"

config="$app_bundle/Contents/Resources/Configuration.plist"
plutil -create xml1 "$config"
plutil -insert RepositoryPath -string "$repo_root" "$config"
plutil -insert HFHubCachePath -string "${HF_HUB_CACHE:-}" "$config"
cp "$repo_root/macos/service_controller.py" "$app_bundle/Contents/Resources/"
codesign --force --sign - "$app_bundle"
mkdir -p "$(dirname "$app_destination")"
ditto "$app_bundle" "$app_destination"

echo "已生成：$app_destination"
echo "在 Finder 中双击应用即可；也可以执行："
printf 'open %q\n' "$app_destination"
