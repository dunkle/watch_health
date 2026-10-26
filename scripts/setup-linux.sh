#!/usr/bin/env bash
# Cloud-only Swift core checks. This does not install Apple SDKs or launch the native app.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo '此脚本针对 Linux x86_64；Mac 请用 scripts/setup-mac.sh。' >&2
  exit 1
fi
TOOLCHAIN_ROOT=/workspace/toolchains
SWIFT_RELEASE=swift-6.0.3-RELEASE-ubuntu22.04
SWIFT_EXECUTABLE="$TOOLCHAIN_ROOT/$SWIFT_RELEASE/usr/bin/swift"
if [[ ! -x "$SWIFT_EXECUTABLE" ]]; then
  SETUP_TMP="$(mktemp -d /tmp/watchmind-swift.XXXXXX)"
  trap 'rm -rf "$SETUP_TMP"' EXIT
  SWIFT_URL="https://download.swift.org/swift-6.0.3-release/ubuntu2204/swift-6.0.3-RELEASE/$SWIFT_RELEASE.tar.gz"
  curl --fail --location --silent --show-error "$SWIFT_URL" -o "$SETUP_TMP/swift.tar.gz"
  curl --fail --location --silent --show-error "$SWIFT_URL.sig" -o "$SETUP_TMP/swift.tar.gz.sig"
  curl --fail --location --silent --show-error \
    https://raw.githubusercontent.com/swiftlang/swift-org-website/main/keys/all-keys.asc -o "$SETUP_TMP/keys.asc"
  mkdir -m 700 "$SETUP_TMP/gnupg"
  gpg --homedir "$SETUP_TMP/gnupg" --import "$SETUP_TMP/keys.asc"
  gpg --homedir "$SETUP_TMP/gnupg" --status-fd 1 --verify \
    "$SETUP_TMP/swift.tar.gz.sig" "$SETUP_TMP/swift.tar.gz" > "$SETUP_TMP/status"
  grep -Fq '[GNUPG:] VALIDSIG 52BB7E3DE28A71BE22EC05FFEF80A866B47A981F ' "$SETUP_TMP/status"
  mkdir -p "$TOOLCHAIN_ROOT"
  tar -xzf "$SETUP_TMP/swift.tar.gz" -C "$TOOLCHAIN_ROOT"
fi
"$SWIFT_EXECUTABLE" --version
SWIFT_BIN="$SWIFT_EXECUTABLE" ./scripts/check.sh
