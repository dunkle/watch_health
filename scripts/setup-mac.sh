#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo '此脚本需要完整 Xcode 的 Mac。Linux 请运行 scripts/check.sh。 / A Mac with full Xcode is required.' >&2
  exit 1
fi
BUILD_STARTED_AT=$(date +%s)
HEARTBEAT_PID=''
cleanup() {
  if [[ -n "$HEARTBEAT_PID" ]]; then
    kill "$HEARTBEAT_PID" 2>/dev/null || true
    wait "$HEARTBEAT_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
progress() {
  local done_count="$1" bar='' i
  for ((i=0; i<5; i++)); do
    if ((i < done_count)); then bar+='#'; else bar+='-'; fi
  done
  printf '\n[%s] %s/5 阶段完成 / stages complete · %ss\n' "$bar" "$done_count" "$(($(date +%s)-BUILD_STARTED_AT))"
}
heartbeat() {
  local label="$1" started_at="$2" sleeper=''
  trap 'if [[ -n "$sleeper" ]]; then kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; fi; exit 0' TERM INT
  while true; do
    sleep 15 & sleeper=$!
    wait "$sleeper" || return
    sleeper=''
    printf '\n… %s · 仍在运行 / still running · %ss\n' "$label" "$(($(date +%s)-started_at))"
  done
}
run_stage() {
  local number="$1" label="$2" started_at status
  shift 2
  progress "$((number-1))"
  printf '▶ [%s/5] %s\n' "$number" "$label"
  started_at=$(date +%s)
  heartbeat "$label" "$started_at" & HEARTBEAT_PID=$!
  if "$@"; then status=0; else status=$?; fi
  cleanup; HEARTBEAT_PID=''
  if ((status != 0)); then
    printf '\n✗ [%s/5] %s 失败 / failed (exit %s). 查看上方第一处 error。\n' "$number" "$label" "$status" >&2
    return "$status"
  fi
  printf '✓ %s · %ss\n' "$label" "$(($(date +%s)-started_at))"
  progress "$number"
}
ensure_xcodegen() {
  if ! command -v xcodegen >/dev/null; then
    if ! command -v brew >/dev/null; then
      echo '请安装 Homebrew 或 XcodeGen。 / Install Homebrew or XcodeGen: https://github.com/yonaskolb/XcodeGen' >&2
      return 1
    fi
    brew install xcodegen || return $?
  fi
  xcodegen --version
}
printf 'WatchMind · 安装与构建 / Setup & Build\n进度条表示阶段数，不是 Xcode 编译百分比。 / Progress counts stages, not compiler completion.\n'
run_stage 1 '检查 Xcode / Check Xcode' xcodebuild -version
run_stage 2 '准备 XcodeGen / Prepare XcodeGen (Homebrew may update)' ensure_xcodegen
run_stage 3 '生成工程 / Generate project' xcodegen generate --spec project.yml
run_stage 4 '运行核心测试 / Run core tests' swift test -j 4
run_stage 5 '编译手机与手表 / Build iPhone + Watch' xcodebuild \
  -project WatchMind.xcodeproj -scheme WatchMind \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
printf '\n✓ 构建完成 / Build complete · %ss\n打开 / Open WatchMind.xcodeproj，设置两个 target 的 Team 和唯一且匹配的 Bundle ID，再安装到真机。\n' "$(($(date +%s)-BUILD_STARTED_AT))"
