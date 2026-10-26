#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo '此脚本需要安装完整 Xcode 的 Mac；Linux 请运行 scripts/check.sh。' >&2
  exit 1
fi
xcodebuild -version
if ! command -v xcodegen >/dev/null; then
  if ! command -v brew >/dev/null; then
    echo '请先从 https://github.com/yonaskolb/XcodeGen 安装 XcodeGen，或安装 Homebrew 后执行 brew install xcodegen。' >&2
    exit 1
  fi
  brew install xcodegen
fi
xcodegen generate --spec project.yml
swift test -j 4
xcodebuild -project WatchMind.xcodeproj -scheme WatchMind \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
printf '\n模拟器构建完成。打开 WatchMind.xcodeproj，在两个 target 中设置你自己的 Team 和唯一 Bundle ID，再安装到配对真机。\n'
