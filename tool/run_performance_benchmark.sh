#!/usr/bin/env bash
set -euo pipefail

device_id="${1:-}"
variant="${2:-}"
run_id="${3:-}"
[[ -n "$device_id" ]] || { echo "Usage: $0 <ios-device-id> <variant> <run-id>" >&2; exit 2; }
[[ -n "$variant" ]] || { echo "Usage: $0 <ios-device-id> <variant> <run-id>" >&2; exit 2; }
[[ -n "$run_id" ]] || { echo "Usage: $0 <ios-device-id> <variant> <run-id>" >&2; exit 2; }

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
out_dir="${FINAMP_BENCH_OUT:-benchmark-results}"
mkdir -p "$out_dir"

raw_log="$out_dir/finamp-benchmark-$timestamp.log"
jsonl="$out_dir/finamp-benchmark-$timestamp.jsonl"
summary_json="$out_dir/finamp-benchmark-$timestamp-summary.json"
summary_md="$out_dir/finamp-benchmark-$timestamp-summary.md"
app_path="build/ios/iphoneos/Runner.app"
remote_stream="Documents/finamp-benchmark-stream-$variant-$run_id.jsonl"
poll_seconds="${FINAMP_BENCH_POLL_SECONDS:-2}"
timeout_seconds="${FINAMP_BENCH_TIMEOUT_SECONDS:-86400}"

log() {
  printf '%s\n' "$*" | tee -a "$raw_log"
}

printf 'Full log: %s\nBenchmark JSONL: %s\n' "$raw_log" "$jsonl"
: > "$raw_log"
: > "$jsonl"

log ""
log "==> Building PROFILE app with benchmark mode enabled"
flutter build ios \
  --profile \
  --dart-define=FINAMP_PERFORMANCE_BENCHMARK=true \
  --dart-define=FINAMP_BENCH_VARIANT="$variant" \
  --dart-define=FINAMP_BENCH_RUN_ID="$run_id" 2>&1 | tee -a "$raw_log"

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
handled_planned_restarts=0
recovery_restarts=0
max_recovery_restarts="${FINAMP_BENCH_MAX_RECOVERY_RESTARTS:-3}"
heartbeat_stall_seconds="${FINAMP_BENCH_HEARTBEAT_STALL_SECONDS:-600}"
benchmark_started=0
last_stream_change_epoch="$(date +%s)"

while true; do
  now_epoch="$(date +%s)"
  elapsed="$((now_epoch - start_epoch))"
  if (( elapsed >= timeout_seconds )); then
    log "ERROR: Benchmark timed out after ${timeout_seconds}s."
    exit 124
  fi

  pulled_file="$pull_root/finamp-benchmark-stream-$variant-$run_id.jsonl"
  rm -f "$pulled_file"

  set +e
  xcrun devicectl device copy from \
    --device "$device_id" \
    --domain-type appDataContainer \
    --domain-identifier "$bundle_id" \
    --source "$remote_stream" \
    --destination "$pulled_file" \
    >"$pull_root/copy.out" 2>"$pull_root/copy.err"
  copy_status=$?
  set -e

  if [[ "$copy_status" -eq 0 && -f "$pulled_file" ]]; then
    set +e
    merge_output="$(python3 - "$jsonl" "$pulled_file" <<'PY'
import os
import sys

local_path, remote_path = sys.argv[1:3]
with open(local_path, "rb") as handle:
    local = handle.read()
with open(remote_path, "rb") as handle:
    remote = handle.read()

if len(remote) < len(local):
    print(f"shorter:{len(remote)}:{len(local)}")
    raise SystemExit(10)

if not remote.startswith(local):
    print(f"diverged:{len(remote)}:{len(local)}")
    raise SystemExit(11)

suffix = remote[len(local):]
if suffix:
    with open(local_path, "ab") as handle:
        handle.write(suffix)

print(f"ok:{len(remote)}:{len(suffix)}")
PY
)"
    merge_status=$?
    set -e

    if [[ "$merge_status" -eq 10 ]]; then
      log "Ignoring shorter transient benchmark snapshot: $merge_output"
      sleep "$poll_seconds"
      continue
    elif [[ "$merge_status" -eq 11 ]]; then
      log "ERROR: Device benchmark stream diverged from the append-only host copy: $merge_output"
      exit 126
    elif [[ "$merge_status" -ne 0 ]]; then
      log "ERROR: Could not merge benchmark stream: $merge_output"
      exit 127
    fi

    size="$(wc -c < "$jsonl" | tr -d ' ')"
    if [[ "$size" != "$last_size" ]]; then
      log "Pulled benchmark stream: ${size} bytes"
      last_size="$size"
      last_stream_change_epoch="$(date +%s)"
    fi

    if grep -q '"name":"suite-authenticated"' "$jsonl" ||
       grep -q '"name":"startup-baseline-complete"' "$jsonl"; then
      benchmark_started=1
    fi

    planned_restart_count="$(grep -c '"name":"host-restart-requested"' "$jsonl" || true)"
    if (( planned_restart_count > handled_planned_restarts )); then
      handled_planned_restarts="$planned_restart_count"
      log ""
      log "==> Full suite requested planned process restart #$handled_planned_restarts"
      log "Relaunching the installed app with the same auth/settings/container..."
      xcrun devicectl device process launch \
        --device "$device_id" \
        --terminate-existing \
        "$bundle_id" 2>&1 | tee -a "$raw_log"
      benchmark_started=1
      last_stream_change_epoch="$(date +%s)"
      sleep 5
    fi

    if grep -q '"name":"suite-complete"' "$jsonl"; then
      log "==> Benchmark suite completed"
      log "Generating summary..."
      python3 tool/summarize_performance_benchmark.py \
        "$jsonl" \
        --json-out "$summary_json" \
        --md-out "$summary_md"
      log "Summary JSON: $summary_json"
      log "Summary Markdown: $summary_md"
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
  else
    if [[ "$last_size" -lt 0 ]]; then
      copy_error="$(tr '\n' ' ' < "$pull_root/copy.err" | sed 's/[[:space:]]\+/ /g' | cut -c1-500)"
      if [[ -n "$copy_error" ]]; then
        log "Waiting for benchmark stream: $copy_error"
      else
        log "Waiting for benchmark stream: devicectl copy exited with status $copy_status"
      fi
      last_size=-2
    fi
  fi

  if [[ "$benchmark_started" -eq 1 ]]; then
    now_epoch="$(date +%s)"
    silent_seconds="$((now_epoch - last_stream_change_epoch))"
    if (( silent_seconds >= heartbeat_stall_seconds )); then
      if (( recovery_restarts >= max_recovery_restarts )); then
        log "ERROR: Benchmark heartbeat stalled for ${silent_seconds}s and recovery restart limit was reached."
        exit 125
      fi
      recovery_restarts="$((recovery_restarts + 1))"
      log ""
      log "==> Benchmark heartbeat stalled for ${silent_seconds}s"
      log "Recovery relaunch ${recovery_restarts}/${max_recovery_restarts}..."
      xcrun devicectl device process launch \
        --device "$device_id" \
        --terminate-existing \
        "$bundle_id" 2>&1 | tee -a "$raw_log"
      last_stream_change_epoch="$(date +%s)"
      sleep 5
    fi
  fi

  sleep "$poll_seconds"
done
