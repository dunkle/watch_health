#!/usr/bin/env bash
# Actual Apple tests. Intentionally fails when Xcode or an iOS simulator is unavailable.
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodebuild >/dev/null || { echo "Native tests require a Mac with full Xcode." >&2; exit 1; }
if [[ -n "${WATCHMIND_SIMULATOR_ID:-}" ]]; then
    destination_id="$WATCHMIND_SIMULATOR_ID"
else
    device_json="$(mktemp /tmp/watchmind-simulators.XXXXXX)"
    trap 'rm -f "$device_json"' EXIT
    xcrun simctl list devices available --json > "$device_json"
    destination_id="$(python3 - "$device_json" <<'PY'
import json, sys
value = json.load(open(sys.argv[1]))
phones = []
for runtime, devices in value.get('devices', {}).items():
    if '.iOS-' not in runtime:
        continue
    for device in devices:
        if device.get('isAvailable') and device.get('name', '').startswith('iPhone'):
            phones.append((device.get('state') == 'Booted', runtime, device['udid']))
if not phones:
    raise SystemExit('No available iPhone simulator. Install an iOS runtime in Xcode Settings > Components.')
print(sorted(phones, reverse=True)[0][2])
PY
)"
fi
xcrun simctl boot "$destination_id" >/dev/null 2>&1 || true
# bootstatus and xcodebuild must succeed; an existing booted device is the only ignored boot error.
xcrun simctl bootstatus "$destination_id" -b
mkdir -p .build-logs
result_path=".build-logs/Native-$(date +%Y%m%d-%H%M%S).xcresult"
xcodebuild -project WatchMind.xcodeproj -scheme WatchMind \
    -destination "platform=iOS Simulator,id=$destination_id" \
    -derivedDataPath DerivedData -resultBundlePath "$result_path" \
    CODE_SIGNING_ALLOWED=NO test
