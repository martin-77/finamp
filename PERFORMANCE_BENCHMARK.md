# Full performance benchmark harness

This branch is test-only. It must not change normal Finamp behaviour.

## Goals

Measure the same real user flows before and after isolated performance changes.
Keep benchmark target identities private: device-local targets are exported only
as aliases.

## Benchmark targets

No manual item-slot setup is required.

The runner validates the fixed benchmark playlists `bench-10 [Smart]`,
`bench-100 [Smart]`, `bench-1000 [Smart]` and `bench-10000 [Smart]`.
It derives device-local album, artist, genre and track targets automatically.
Search uses the fixed public query labels Iron Maiden, Metallica and Kettcar and
derives a private artist -> album -> track chain for each.

The benchmark export must not contain Jellyfin IDs, server URLs, user IDs,
API keys, private item names, private artist/album names, local file paths or
total library size.

Per-target measurements may include:

- target alias
- item type
- resolved track count
- expected/actual transferred bytes
- queue length
- result count

## Automated full baseline contract

The benchmark is intentionally long-running. A baseline is only considered
complete when the entire matrix below has executed successfully, or a scenario
has produced an explicit failed/timeout/unexpectedExit result.

The suite must not silently skip a phase because a previous phase warmed a
cache. Every result records its execution class.

### Stable benchmark targets

The Jellyfin server contains these fixed benchmark playlists:

- `bench-10 [Smart]` -> alias `bench-10`
- `bench-100 [Smart]` -> alias `bench-100`
- `bench-1000 [Smart]` -> alias `bench-1000`
- `bench-10000 [Smart]` -> alias `bench-10000`

The runner validates the exact track count before doing destructive or
target-specific work. It derives deterministic album/artist/track detail
targets locally from these playlists and stores only private local ids. Names
and ids are never exported.

### Full execution matrix

1. **Process/startup**
   - realistic first process including Finamp's normal automatic playlist-metadata background work
   - controlled cold process after benchmark-owned first-process metadata state is cleaned up
   - cold process / warm persistent cache
   - warm process / cold view
   - warm view
   - storage, providers, audio service, `runApp`, first frame, selected MusicScreen content usable
   - startup network request count/bytes/duration and queue-restore cost

2. **Direct API reference layer**
   - Artists / Albums / Tracks / Playlists / Genres first page
   - repeated warm request
   - page-size scaling
   - request count / bytes / decode-provider timing where instrumented

3. **Real MusicScreen UI**
   - Home / Artists / Albums / Tracks / Playlists / Genres
   - refreshed-view and warm-view
   - three rotated deterministic orders
   - tab selected -> data ready -> first rendered content
   - repeated page loads

4. **Real alphabet fast-scroller**
   - Tracks / Artists / Albums
   - exact sequence `# -> A -> G -> M -> Z`
   - pages added, loaded item count and elapsed time per jump
   - run once from a refreshed first page and once from warm loaded state
   - do not synthesize a direct server query

5. **Search**
   - real MusicScreen search path
   - broad one-character query
   - deterministic private target-derived query
   - repeated warm query
   - result count, requests, bytes and first rendered result

6. **Detail screens**
   - deterministic album
   - deterministic artist
   - deterministic genre
   - search-derived artist/album chains for Iron Maiden, Metallica and Kettcar
   - `bench-10`, `bench-100`, `bench-1000`, `bench-10000` playlist detail
   - navigation action -> shell rendered -> metadata/children ready -> first full content frame
   - refreshed/cold-provider and warm-provider repeats
   - child count and provider/API work

7. **Queue and playback**
   - one track
   - deterministic album
   - deterministic artist
   - deterministic genre
   - search-derived track/album/artist chains for Iron Maiden, Metallica and Kettcar
   - all four benchmark playlists
   - slice resolution, queue construction, queue length
   - player ready, playing, first position advance, useful buffering where available
   - repeat warm playback
   - playlist scaling 10/100/1000/10000

8. **Downloads**
   - `bench-10`, `bench-100`, `bench-1000`
   - clean-state validation
   - planning graph / enqueue
   - first transfer / first completed track / full completion
   - failures, real downloaded bytes, duration and throughput
   - no `bench-10000` download

9. **Downloaded/offline lifecycle**
   - verify downloaded target and actual local bytes
   - save prior offline setting
   - force Finamp offline
   - local-downloaded-cold detail/queue/playback
   - local-downloaded-warm repeat
   - relevant paging/search paths against local metadata
   - restore exact prior offline setting
   - cleanup
   - verify no benchmark download state remains

10. **Cache/systemic diagnostics**
    - first-use vs repeated provider work
    - image/cache warm-up effects
    - persistent metadata/cache effects across process restart
    - isolate first-run work from steady-state work
    - report cache hits/misses where available
    - keep unmeasured stabilization boundaries separate from benchmark duration

11. **Host restart orchestration**
    - the macOS runner relaunches the already installed build for true
      cold-process and warm-persistent-cache phases
    - phase/checkpoint state persists in the app container
    - crashes, Jetsam and manual termination resume at the earliest safe phase
    - download cleanup has priority over resuming benchmark work

12. **One-time playlist metadata/image sync**
    - the real automatic workload is included once in the fresh startup process
    - after that first process its benchmark-owned metadata state is cleaned before controlled cold/warm comparisons
    - the same workload is measured again in isolation after normal and post-restart cache comparisons
    - reproduces Finamp's automatic first-run playlist metadata workload
    - waits for the entire downloader to become idle, not only for the root node
    - exports duration/request work but no playlist names, image counts or ids
    - automatically deletes the benchmark-owned metadata download afterwards

13. **Summary**
    - raw runs remain in JSONL
    - per-scenario median / p90 / failure count
    - no total private library cardinality
    - benchmark target track counts and downloaded bytes are allowed

The suite-complete marker must refer to this entire matrix. Intermediate
sub-suites emit phase-complete markers but must not emit suite-complete.

## Implementation status

| Area | Status | Notes |
|---|---|---|
| realistic first startup | automated | includes normal playlist-metadata background work, per-process network/frame/RSS summary, then cleans benchmark-owned state |
| controlled cold process | automated | host restart with preserved auth/settings and cleared image cache |
| persistent-cache restart | automated | same installed build/container, explicit stage checkpoints |
| API page-size reference | automated | 25/100/100-warm/500 for major collections |
| Home + main tabs | automated | rotated refreshed/warm rounds with first-rendered + quiescent timing |
| deep paging | automated | repeated real UI next-page actions |
| Search | automated | Iron Maiden, Metallica, Kettcar + broad query + search paging |
| Artist → Album → Track | automated | deterministic private chain per named artist, cumulative drill-down and playback |
| alphabet fast-scroller | automated | real `# → A → G → M → Z` path for Tracks/Artists/Albums, refreshed and warm-loaded |
| details | automated | album, artist, genre and 10/100/1000/10000 playlist details |
| queue/playback | automated | track/album/artist/genre/playlists through player-playing, useful buffer and first position |
| large queue restore | automated | normal autoload observed; explicit 1000-track restore if startup autoload did not run |
| downloads | automated | 10/100/1000 original-file downloads, real bytes, throughput and cleanup |
| download resync/repair | automated | force-resync + full repair on isolated bench-100 download graph |
| offline/local | automated | cold-process for 1000, warm/local UI, paging, search, alphabet and playback |
| image cache | automated | cleared persistent image cache vs warm view/detail |
| network target transition | opportunistic diagnostic | real target changes/pings are recorded; iOS radios are not artificially toggled |
| crash/hang recovery | automated | active-run recovery + phase checkpoints + bounded host relaunches |
| summary | automated | median/p90, milestones, HTTP, RSS, frames, startup timeline, failures and recoveries |

A `suite-complete` record means all mandatory automated rows above reached
their terminal phase. Opportunistic network-transition diagnostics are not a
completion prerequisite.

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

For Home, Artists, Albums, Tracks, Playlists and Genres where applicable:

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

For derived album, artist and genre targets, the three search-derived artist/
album chains, and benchmark playlist details:

- tap/open -> first metadata rendered
- tap/open -> child content rendered
- API requests / bytes
- child item count

### Playback startup

For derived track/album/artist/genre targets, all benchmark playlists and the
three search-derived track/album/artist chains:

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

For `bench-10`, `bench-100` and `bench-1000`:

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
- sequential local filesystem read throughput as a separate diagnostic reference
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

Diagnostic only, not a blocking performance score.

The app cannot reliably or appropriately toggle iOS Wi-Fi/cellular radios
itself, so the unattended suite does not fake this transition. If a real
network/target reevaluation occurs while the benchmark build is running, the
harness records privacy-safe target-state changes and local/public/active ping
durations without exporting URLs or addresses.

Useful observations include:

- Wi-Fi/local -> mobile/public when it really occurs
- mobile/public -> Wi-Fi/local when it really occurs
- target-state change
- local/public/active reachability duration and outcome
- queue/player errors or recovery events already captured by the playback hooks

A dedicated manual network-transition experiment can reuse these diagnostics
later without changing the core performance suite.

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

Uncaught Flutter and Dart errors are attached to the active run using only
the error type, source and last benchmark step. Exception messages and stack
traces remain in normal local Finamp logs and are deliberately excluded from
benchmark JSON because they can contain media names, ids, server URLs, tokens
or local paths.

Long-running benchmark operations should use the benchmark step timeout helper.
Timed out steps are stored as `timeout` with the last step and error type,
without exporting exception text or stack traces.

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

On macOS, normally start the complete preflight/build/device workflow with:

`bash tool/bootstrap_performance_benchmark_macos.sh`

If more than one physical iOS device is connected, pass the intended Flutter
device id as the only argument. The bootstrap resolves dependencies, runs the
static preflight, installs CocoaPods, builds a profile app and then delegates
to the lower-level collector.

The collector writes the raw stream plus generated summaries under
`benchmark-results/`:

- `finamp-benchmark-<timestamp>.log`: complete Flutter/device output
- `finamp-benchmark-<timestamp>.jsonl`: benchmark records only
- `finamp-benchmark-<timestamp>-summary.json`: aggregated machine-readable results
- `finamp-benchmark-<timestamp>-summary.md`: human-readable hotspot summary

JSONL is copied repeatedly while the run is executing, and the device-side
stream is append-only. Completed records therefore remain recoverable after
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
