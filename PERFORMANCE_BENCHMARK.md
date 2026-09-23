# Full performance benchmark harness

This branch is test-only. It must not change normal Finamp behaviour.

## Goals

Measure the same real user flows before and after isolated performance changes.
Keep benchmark target identities private: device-local targets are exported only
as aliases.

## Target slots

Configure these locally on the device:

- playlist-A
- album-A
- artist-A
- track-A

The benchmark export must not contain Jellyfin IDs, server URLs, user IDs,
API keys, item names, artist names, album names, or total library size.

Per-target measurements may include:

- target alias
- item type
- resolved track count
- expected/actual transferred bytes
- queue length
- result count

## Benchmark scenarios

### Startup

- process start -> storage ready
- process start -> providers ready
- process start -> audio service ready
- process start -> runApp
- process start -> first frame
- process start -> MusicScreen usable

Run separately with cold and warm persistent caches.

### Library browsing

For Artists, Albums, Tracks, Playlists and Genres:

- user action -> provider/request start
- request start -> response received
- response -> parsed/processed data
- data ready -> first rendered frame
- total action -> first rendered content
- next-page latency
- request count and transferred bytes

### Search

- query changed -> request/index lookup start
- lookup -> result data ready
- result data ready -> first rendered frame
- total search latency
- result count
- request count / bytes

### Alphabet navigation

- jump action -> target data available
- target data available -> target rendered
- pages fetched while jumping
- requests / bytes

### Detail screens

For configured album-A and artist-A:

- tap/open -> first metadata rendered
- tap/open -> child content rendered
- API requests / bytes
- child item count

### Playback startup

For playlist-A, album-A, artist-A and track-A:

- action -> playable slice resolution start
- slice resolution duration
- resolved track count
- action -> queue replacement start
- queue construction duration
- queue length
- action -> player processing state ready
- action -> player playing=true
- action -> first position advance
- action -> useful buffered audio
- requests / bytes before playback begins
- playback source category (local/public/offline), never the URL

This distinguishes collection resolution, queue construction and actual player
startup.

### Download

For playlist-A and album-A, and optionally artist-A:

- user action -> sync planning start
- collection resolution duration
- resolved track count
- sync/planning complete -> first transfer starts
- time to first completed track
- total transfer time
- completed/failed track count
- expected byte size if known
- actual downloaded byte size
- average throughput
- download concurrency setting
- transcoding mode/profile category without private paths or URLs

Download tests must start from a defined state. The report records whether the
target was already partially downloaded; comparisons should use a clean target
state.

### Download sync / repair

- sync requested -> sync queue starts
- collection enumeration duration
- total discovered children
- changed/unchanged/missing child counts
- sync duration
- new transfers triggered
- failures

This is also useful for issue #1774.

### Queue restore

- restore start -> metadata resolved
- metadata resolution -> audio sources built
- restored track count / dropped track count
- restore -> queue ready
- restore -> playback ready if autoplay is enabled

### Network transition playback

Diagnostic benchmark, not a performance score:

- Wi-Fi/local -> mobile/public
- mobile/public -> Wi-Fi/local
- target URL reevaluation duration
- queue reload/prompt behaviour
- buffer ahead at transition
- interruption duration
- player error/recovery outcome

## Metrics

Every run uses a monotonic Stopwatch and a unique local run id.

Store:

- scenario
- variant label entered by tester
- cold/warm state
- elapsed event timestamps
- durations derived from event pairs
- request count
- response bytes
- cache hits/misses
- item/page counts
- queue length
- expected/actual download bytes
- download duration / throughput
- failures

Do not store personally identifying media metadata.

## Comparison methodology

Use the exact same harness on baseline and each isolated change.

Recommended initial run count:

- 5 runs for large effects
- 10 runs when differences are small or noisy

Compare median and p90, not a single run.

Performance changes should be evaluated both by user-visible latency and by
amount of work performed. A faster first frame that leaves the same expensive
work running in the background is useful but must be described separately from
a structural reduction in work.


## Crash, hang and cleanup recovery

Every active run is checkpointed persistently after benchmark events and metric
updates. If the next app start finds an unfinished run, it is finalized as
`unexpectedExit` with the last completed benchmark step.

Uncaught Flutter and Dart errors are attached to the active run using Finamp's
existing log censorship before they are persisted. This preserves diagnostic
context without exporting server URLs, access tokens or user identifiers.

Long-running benchmark operations should use the benchmark step timeout helper.
Timed out steps are stored as `timeout`, including the last step and censored
diagnostic information.

Native process termination such as iOS Jetsam cannot be read directly from the
application sandbox. It is represented by the persistent `unexpectedExit`
record and benchmark run id. The same run id is emitted to Finamp logs so a
device crash/Jetsam report can be correlated afterwards.

Benchmark downloads set a persistent cleanup-required marker before modifying
download state. A new benchmark run is refused while that marker remains.
Deleting the benchmark download clears it only after cleanup finishes.

The benchmark runner must perform pending cleanup before resuming a suite after
an interrupted download.

## Exact alphabet jump path

Alphabet jump benchmarks use the real MusicScreen fast-scroller path rather
than a synthetic server query. The benchmark records each page requested while
searching for the target letter, the number of loaded items at each request,
and the point where the target becomes visible.

This is intended to expose scaling behaviour where jumping to a later letter
requires sequential page loading.


## Post-download local/offline benchmark phase

For bench-10, bench-100 and bench-1000, a successful download is followed by a
local/offline benchmark phase before cleanup.

Sequence:

1. complete and verify the benchmark download
2. record downloaded track count and actual local bytes
3. switch Finamp to offline mode so server streaming cannot satisfy playback
4. rerun the matching collection/detail/queue/playback scenarios
5. run the same relevant alphabet/paging tests against the downloaded metadata
6. repeat local playback once to distinguish first-use from warm local access
7. restore the previous offline-mode setting
8. delete the benchmark download
9. verify cleanup before continuing

The local phase uses a distinct run mode such as `local-downloaded-cold` and
`local-downloaded-warm`. It must never be mixed with online measurements.

Primary local measurements:

- collection resolution duration
- local metadata query duration
- queue construction duration
- action -> player playing
- action -> first position advance
- local file count
- actual local bytes
- player errors
- first-use vs repeated local playback

An optional filesystem reference benchmark may sequentially read the already
downloaded track files and report total bytes, duration and read throughput.
This is diagnostic only: it helps distinguish storage I/O from Finamp metadata,
queue and player overhead and is not a replacement for the real offline
playback benchmark.

## Host-side result capture

Every benchmark event and metric is emitted immediately on stdout as one
machine-readable line prefixed with `BENCH_JSON `.

When the app is launched from macOS, use:

`tool/run_performance_benchmark.sh -d <device-id> --profile`

The collector writes two files under `benchmark-results/`:

- `finamp-benchmark-<timestamp>.log`: complete Flutter/device output
- `finamp-benchmark-<timestamp>.jsonl`: benchmark records only

JSONL is append-only while the run is executing, so completed events remain on
the Mac even if the app crashes or is terminated by iOS. Device-local
checkpointing remains enabled as a second recovery source.


### Required post-download execution order

For each of bench-10, bench-100 and bench-1000 the automated runner must use
this exact lifecycle:

```
online baseline for target
-> download target
-> verify complete + record local byte size
-> force Finamp offline mode
-> local-downloaded-cold scenarios
-> local-downloaded-warm scenarios
-> restore previous offline setting
-> cleanup downloaded target
-> verify target is no longer downloaded
```

Cleanup is deliberately delayed until both local phases have completed.

Local scenarios include, where supported by the target:

- collection/detail resolution
- queue construction
- playback startup
- first position advance
- repeated playback startup
- paging
- alphabet jump through the real fast-scroller path

The runner records the previous offline setting before changing it and restores
that exact value afterwards, including after a handled benchmark failure.
