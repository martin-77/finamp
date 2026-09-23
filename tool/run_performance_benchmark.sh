#!/usr/bin/env bash
set -euo pipefail

device_id="${1:-}"
variant="${2:-}"
[[ -n "$device_id" ]] || { echo "Usage: $0 <ios-device-id> <variant>" >&2; exit 2; }
[[ -n "$variant" ]] || { echo "Usage: $0 <ios-device-id> <variant>" >&2; exit 2; }

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
out_dir="${FINAMP_BENCH_OUT:-benchmark-results}"
mkdir -p "$out_dir"

raw_log="$out_dir/finamp-benchmark-$timestamp.log"
jsonl="$out_dir/finamp-benchmark-$timestamp.jsonl"
app_path="build/ios/iphoneos/Runner.app"

printf 'Full log: %s\nBenchmark JSONL: %s\n' "$raw_log" "$jsonl"

printf '\n==> Building PROFILE app with benchmark mode enabled\n'
flutter build ios   --profile   --dart-define=FINAMP_PERFORMANCE_BENCHMARK=true   --dart-define=FINAMP_BENCH_VARIANT="$variant"

[[ -d "$app_path" ]] || {
  echo "ERROR: Built app not found at $app_path" >&2
  exit 1
}

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
[[ -n "$bundle_id" ]] || {
  echo "ERROR: Could not determine CFBundleIdentifier from built app" >&2
  exit 1
}

printf '\n==> Installing %s on device %s\n' "$bundle_id" "$device_id"
xcrun devicectl device install app   --device "$device_id"   "$app_path"

printf '\n==> Launching app and attaching device console\n'
printf 'This path does not use Flutter mDNS or the Dart VM service.\n'
printf 'Keep this terminal open for the whole benchmark. Ctrl-C stops collection.\n\n'

# devicectl streams the launched process' stdout/stderr directly from the
# physical device. This avoids Flutter's mDNS VM-service discovery, which is
# unreliable on some macOS/iOS combinations even when Local Network permission
# is enabled.
xcrun devicectl device process launch   --device "$device_id"   --terminate-existing   --console   "$bundle_id" 2>&1 |
  tee "$raw_log" |
  awk -v jsonl="$jsonl" '
    {
      print
      fflush()
      marker = index($0, "BENCH_JSON ")
      if (marker > 0) {
        print substr($0, marker + length("BENCH_JSON ")) >> jsonl
        fflush(jsonl)
      }
    }
  '
