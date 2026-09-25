# Finamp Performance Benchmark

This benchmark measures Finamp performance on a physical iOS device using a PROFILE build.

It can run the full benchmark suite or targeted download diagnostics.

## Requirements

- macOS with Xcode
- Flutter development environment
- CocoaPods
- a physical iOS device connected to the Mac
- a configured Finamp/Jellyfin test environment

The device must be unlocked and trusted by the Mac.

## Run the benchmark

From the repository root:

```bash
bash tool/bootstrap_performance_benchmark_macos.sh
```

The bootstrap performs the required preflight checks, builds the PROFILE app, installs it on the physical device and collects benchmark output from the app container.

## Targeted download benchmarks

For the 100-track workload:

```bash
FINAMP_BENCH_DOWNLOAD_BENCH100_ONLY=true \
bash tool/bootstrap_performance_benchmark_macos.sh
```

For the 1,000-track workload:

```bash
FINAMP_BENCH_DOWNLOAD_BENCH1000_ONLY=true \
bash tool/bootstrap_performance_benchmark_macos.sh
```

The targeted modes are useful when investigating download-graph changes without running the complete benchmark matrix.

## Output

Results are written to `benchmark-results/`.

A completed run produces:

- `finamp-benchmark-<timestamp>.jsonl` — raw benchmark events
- `finamp-benchmark-<timestamp>.log` — host-side run log
- `finamp-benchmark-<timestamp>-summary.json` — machine-readable summary
- `finamp-benchmark-<timestamp>-summary.md` — human-readable summary

The JSONL file is the authoritative raw result. The summaries are generated from it.

## Download benchmark phases

The download benchmark distinguishes between:

1. target validation
2. sync-graph construction
3. first file transfer
4. completion of all requested tracks
5. transfer settlement
6. cleanup

This distinction is important: a slow download may be caused by graph construction rather than file-transfer throughput.

## Important metrics

For graph-performance investigations, start with:

- sync-graph duration
- sync-node timings
- album and metadata request timing
- album view lookup timing
- database/link update timing

For transfer behavior, check:

- transfer duration
- throughput
- network concurrency
- simultaneous file transfers

For correctness, verify:

- expected tracks completed
- no unexpected failures
- no active tracks remain
- cleanup completed successfully

## Comparing runs

Do not compare total lifecycle time alone.

Network latency and file-transfer throughput naturally vary between runs. Prefer the phase directly affected by a change.

For example, a sync-graph optimization should primarily be evaluated using sync-graph duration and the related graph diagnostics, while also checking that concurrency and correctness remain unchanged.

## Large download workload

The larger download workload contains 1,000 playlist tracks referencing 979 albums. Resolving those albums produces 24,512 album child tracks in the offline metadata graph, although only the 1,000 playlist tracks are downloaded.

This makes the workload useful for exposing scaling problems in offline metadata and graph construction independently of raw file-transfer speed.
