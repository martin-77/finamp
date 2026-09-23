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
remote_stream="Documents/finamp-benchmark-stream.jsonl"
poll_seconds="${FINAMP_BENCH_POLL_SECONDS:-2}"
timeout_seconds="${FINAMP_BENCH_TIMEOUT_SECONDS:-1800}"

log() {
  printf '%s\n' "$*" | tee -a "$raw_log"
}

printf 'Full log: %s\nBenchmark JSONL: %s\n' "$raw_log" "$jsonl"
: > "$raw_log"
: > "$jsonl"

log ""
log "==> Building PROFILE app with benchmark mode enabled"
flutter build ios   --profile   --dart-define=FINAMP_PERFORMANCE_BENCHMARK=true   --dart-define=FINAMP_BENCH_VARIANT="$variant" 2>&1 | tee -a "$raw_log"

[[ -d "$app_path" ]] || {
  log "ERROR: Built app not found at $app_path"
  exit 1
}

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Info.plist")"
[[ -n "$bundle_id" ]] || {
  log "ERROR: Could not determine CFBundleIdentifier from built app"
  exit 1
}

log ""
log "==> Installing $bundle_id on device $device_id"
xcrun devicectl device install app   --device "$device_id"   "$app_path" 2>&1 | tee -a "$raw_log"

log ""
log "==> Launching app without console attachment"
xcrun devicectl device process launch   --device "$device_id"   --terminate-existing   "$bundle_id" 2>&1 | tee -a "$raw_log"

log ""
log "==> Polling benchmark JSONL from app container"
log "No Flutter mDNS, Dart VM service or devicectl --console attachment is used."
log "The app may remain open while the Mac copies benchmark checkpoints every ${poll_seconds}s."
log "Timeout: ${timeout_seconds}s"

pull_root="$(mktemp -d)"
trap 'rm -rf "$pull_root"' EXIT INT TERM

start_epoch="$(date +%s)"
last_size=-1

while true; do
  now_epoch="$(date +%s)"
  elapsed="$((now_epoch - start_epoch))"
  if (( elapsed >= timeout_seconds )); then
    log "ERROR: Benchmark timed out after ${timeout_seconds}s."
    exit 124
  fi

  rm -rf "$pull_root/current"
  mkdir -p "$pull_root/current"

  set +e
  xcrun devicectl device copy from     --device "$device_id"     --domain-type appDataContainer     --domain-identifier "$bundle_id"     --source "$remote_stream"     --destination "$pull_root/current"     >"$pull_root/copy.out" 2>"$pull_root/copy.err"
  copy_status=$?
  set -e

  if [[ "$copy_status" -eq 0 ]]; then
    pulled_file="$(find "$pull_root/current" -type f -name 'finamp-benchmark-stream.jsonl' -print -quit)"
    if [[ -z "$pulled_file" && -f "$pull_root/current" ]]; then
      pulled_file="$pull_root/current"
    fi

    if [[ -n "$pulled_file" && -f "$pulled_file" ]]; then
      cp "$pulled_file" "$jsonl"
      size="$(wc -c < "$jsonl" | tr -d ' ')"
      if [[ "$size" != "$last_size" ]]; then
        log "Pulled benchmark stream: ${size} bytes"
        last_size="$size"
      fi

      if grep -q '"name":"suite-complete"' "$jsonl"; then
        log "==> Benchmark suite completed"
        exit 0
      fi
      if grep -q '"name":"suite-blocked"' "$jsonl"; then
        log "ERROR: Benchmark suite blocked; inspect $jsonl"
        exit 3
      fi
      if grep -q '"name":"suite-error"' "$jsonl"; then
        log "ERROR: Benchmark suite reported an error; inspect $jsonl"
        exit 4
      fi
    fi
  fi

  sleep "$poll_seconds"
done
