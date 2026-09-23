#!/usr/bin/env bash
set -euo pipefail

timestamp="$(date -u +"%Y%m%dT%H%M%SZ")"
out_dir="${FINAMP_BENCH_OUT:-benchmark-results}"
mkdir -p "$out_dir"

raw_log="$out_dir/finamp-benchmark-$timestamp.log"
jsonl="$out_dir/finamp-benchmark-$timestamp.jsonl"

printf 'Full log: %s\nBenchmark JSONL: %s\n' "$raw_log" "$jsonl"

# Pass any flutter run arguments through, e.g.:
#   tool/run_performance_benchmark.sh -d <iphone-device-id> --profile
#
# The app emits one machine-readable line per benchmark event prefixed with
# BENCH_JSON. The full Flutter/device log is retained separately.
flutter run "$@" 2>&1 |
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
