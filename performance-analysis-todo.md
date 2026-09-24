# Performance analysis TODO

This file is the working register for the performance investigation on
`test/performance-benchmark-harness`.

It deliberately separates:

- **CONFIRMED**: directly established by code and/or the completed benchmark.
- **INTENTIONAL TRADEOFF**: the code/history documents why the current design exists.
- **BENCHMARK GAP**: the current harness cannot yet distinguish the remaining causes.
- **OPEN**: a possible improvement that must not be treated as proven until measured.

The separate maintainer TODO/FIXME register is
[`todolist-maintainer.md`](todolist-maintainer.md). Existing upstream TODOs that
touch a measured hotspot are cross-referenced here rather than silently folded
into benchmark findings.

## Baseline

Completed full benchmark: `finamp-benchmark-20260924T122053Z`.

Relevant branch baseline before optimization work:
`5057f59b8528af706d127a17b1056ee93eef8eb3`.

The benchmark currently shows, among other things:

- normal cold startup about 17 s;
- realistic first startup with automatic playlist metadata work about 33 min;
- `bench-1000` download lifecycle about 51.5 min, dominated by sync-graph planning;
- 10k queue playback startup about 84-87 s;
- album fast-scroller jumps up to about 132 s refreshed and about 91 s warm;
- track API requests have a roughly 2.7 s fixed floor that barely changes with
  25/100/500 items or minimal/default fields.

Do not change several hotspots at once. Extend the benchmark for the hotspot,
make one isolated production change, rerun the affected scenarios, and compare
against this baseline.

---

## P0 - Download / metadata sync graph

### D1 - Sync concurrency is effectively one serial worker by default

**Status: CONFIRMED**

Code:

- `DefaultSettings.downloadWorkers = 1`.
- The UI exposes 1-5 sync workers.
- `DownloadsSyncService._batchSize = 10`.
- `_advanceQueue()` claims up to ten Isar task rows for a worker batch, then
  processes those rows with a serial `for` loop and an awaited
  `_syncDownload(...)` for each row.
- The completed benchmark records `downloadSyncWorkers = 1` while file
  transfers use `downloadMaxConcurrentTransfers = 5`.

This means a default full-speed sync has one active ten-row batch, but the ten
nodes inside that batch are still processed serially. The batch size is task
claiming, not intra-batch parallelism.

**Maintainer rationale visible in code:** synchronous claiming and
`_activeSyncs` are explicitly used to prevent multiple workers from claiming
the same item. Persisted Isar task rows also make interrupted syncs resumable.
The concurrency restriction therefore protects graph correctness/recovery; it
is not safe to replace it with unconstrained `Future.wait`.

**Benchmark extension required before changing production code:**

- record active sync worker/batch count over time;
- record node throughput by node type;
- run an isolated `bench-100` sync with workers 1/2/3/5 while keeping transfer
  concurrency unchanged;
- record failures/retries, duplicate work, Isar transaction time and HTTP
  request count for each worker setting.

### D2 - Opportunistic 250 ms metadata batching interacts badly with serial sync

**Status: CONFIRMED mechanism; contribution size still BENCHMARK GAP**

`JellyfinApiHelper.getItemByIdBatched()` intentionally waits 250 ms to collect
IDs from requests arriving at nearly the same time, then calls `getItems(ids:
...)`.

The top-level sync worker, however, awaits each `_syncDownload()` serially.
For a track whose metadata needs a forced server refresh, the next top-level
track cannot enter the batching window until the current track completes.
Consequently the coalescer can degenerate into a 250 ms wait followed by a
small/single-ID request.

There is real parallel batching inside a node where relation metadata is fetched
with `Future.wait`, so it is not correct to claim that every batch contains one
ID.

**Maintainer rationale:** the helper comment explicitly says it batches item
requests “coming in around the same time”; the delay is a request-coalescing
mechanism, not an arbitrary sleep.

**Benchmark extension:**

- IDs per batch: min/median/p90/max;
- number of batches;
- time spent in the 250 ms coalescing window;
- actual HTTP duration separately;
- caller category: forced parent metadata, relation metadata, other;
- correlation with `downloadWorkers`.

Also verify a correctness issue: the single shared batch future uses the
`fields` argument of the caller that creates the batch. Calls joining the same
batch with a different fields set currently share that first request. Establish
whether different field sets can overlap in production before changing it.

### D3 - `allPlaylistsMetadata` deliberately expands playlist membership

**Status: CONFIRMED + INTENTIONAL TRADEOFF**

`addDefaultPlaylistInfoDownload()` documents its purpose:

> automatically download playlist metadata to enhance playlist actions and
> offline mode.

The graph is deliberately metadata-only at the playlist collection boundary:
`allPlaylistsMetadata` links playlists as `infoChildren`, not required
children.

However, an info-only playlist still calls `_getCollectionChildren()`, and
albums/playlists always add their ordered tracks as info children. This stores
playlist membership/order offline. `syncItemState()` also contains a special
`allPlaylistsMetadata` case so info-linked collections need not themselves be
downloaded.

Therefore “stop traversing playlist tracks” is **not** a safe optimization; it
would remove information that current offline playlist behavior uses.

A track processed as info can still contribute image/relation graph work. The
question is not whether recursion exists—it does—but which descendants are
actually required for the stated offline feature.

**Benchmark extension:**

For the isolated automatic playlist-metadata sync, count and time by node type:

- finamp collection;
- playlist;
- track;
- image;
- album;
- artist;
- genre.

Also record:

- required vs info traversal count;
- cache hit/miss for child enumeration;
- forced BaseItem metadata refreshes;
- graph nodes inserted vs already existing;
- file/image downloads triggered by this metadata-only job.

This will tell us which part of the deliberate offline metadata graph accounts
for the ~33 min cost.

### D4 - Album-to-library lookup repeatedly scans cached library album lists

**Status: CONFIRMED local algorithm; previous HTTP concern corrected**

`_getAlbumViewID()` loops all known views, calls `_getCollectionChildren()`,
materializes child stubs/IDs and performs a linear `contains(albumId)`.

Within one sync run `_childCache` prevents the library child request from being
sent to Jellyfin again after it is cached. This is therefore **not** a
per-track-per-library HTTP request problem.

It is still repeated local work for tracks/albums whose `viewId` is missing.
A one-time `albumId -> viewId` map would turn repeated list reconstruction and
linear membership searches into direct lookup, but the size of this cost is not
yet measured.

**Benchmark extension:**

- `_getAlbumViewID` call count;
- total/median/p90 duration;
- views examined;
- album IDs scanned;
- cold child-cache vs cached-child-list calls.

### D5 - Per-node Isar graph mutation is heavy but not yet proven dominant

**Status: CONFIRMED mechanism; impact BENCHMARK GAP**

Each node can execute a synchronous write transaction containing
`_updateChildren()`, which performs link enumeration, set diffs, `getAllSync`,
`anyOf(...).findAllSync`, `putAllSync`, link updates and state propagation.

One concrete local inefficiency is that `childIdsToLink` is kept as a
`List<int>` and repeatedly queried with `contains()` while iterating children.
A set would make membership checks constant-time.

Do not call this a primary cause until measured.

**Benchmark extension:**

- aggregate wall time in Isar transaction portion of `_syncDownload`;
- `_updateChildren` duration by parent/node type;
- number of existing/inserted/linked/unlinked children;
- state-propagation duration;
- download-setting propagation duration.

---

## P0 - Queue / player construction

### Q1 - Current benchmark combines AudioSource creation and native player install

**Status: CONFIRMED BENCHMARK GAP**

`QueueService._replaceWholeQueue()` already shows MediaItem/FinampQueueItem
construction is cheap. It then calls `MusicPlayerBackgroundTask.setQueueItems()`.

That function:

1. serially converts every `FinampQueueItem` to an `AudioSource`;
2. passes the complete list to `AudioPlayer.setAudioSources(...)`.

Our current `queueAudioSourcesInstallMicros` surrounds both operations. We
therefore cannot yet attribute the measured ~57-63 s to Dart AudioSource
construction versus the just_audio/native playlist installation.

**Maintainer rationale/history:** commit `d80a632...` deliberately moved to one
AudioSource-backed queue and built the UI queue from it to fix queue
modification/index synchronization bugs. Any lazy/windowed native queue design
would have to restore explicit logical/native queue-index mapping and preserve
shuffle, skip, reordering and platform-control behavior.

**Benchmark extension before redesign:**

- `queueAudioSourceBuildMicros`;
- `queuePlayerSetAudioSourcesMicros`;
- source count;
- downloaded-file vs server-source count;
- diagnostic `preload=true` vs `preload=false` on an isolated 1k/10k
  benchmark;
- player/native ready milestone after `setAudioSources`.

Only after this split decide whether to optimize source construction, just_audio
installation, or queue architecture.

---

## P0 - Alphabet fast scroller

### F1 - Refreshed late-letter jumps sequentially load 100-item pages

**Status: CONFIRMED**

`musicScreenPageSize = 100`.

`scrollToLetter()` scans currently loaded items. If the target is not present
and `hasNextPage` is true, it calls `pageControl.notifier.newPage()`. A later
build invokes `scrollToLetter(letterToSearch)` again. Therefore a refreshed
jump to a late letter walks page 1, page 2, ... until the target enters the
loaded prefix.

This exactly matches the hundreds of requests observed for refreshed album
`Z`.

**Maintainer rationale/history:** the feature was added incrementally in 2023:
initial direct jump, then paginated “scroll until an element is found”, then
nearest available-letter behavior and a performance refactor. The algorithm was
built to remain correct when the requested letter is not in the currently
loaded remote page, not to provide direct server-side alphabet seeking.

Relevant upstream TODOs are tracked in
[`todolist-maintainer.md`](todolist-maintainer.md), especially the unresolved
`NameStartsWith` API-helper handling.

**Benchmark extension:**

- server-side direct-seek diagnostic using `NameStartsWithOrGreater` where the
  Jellyfin endpoint supports it;
- result correctness against the existing sequential algorithm for #/A/G/M/Z;
- requests, first-target latency and sort consistency;
- ascending and descending order;
- missing-letter/nearest-letter behavior.

### F2 - Warm large-list jump cost is inside target scrolling, not local scan

**Status: CONFIRMED; exact scroll_to_index internal cause BENCHMARK GAP**

Local scan is already measured and is tiny in the problematic warm album runs.
The expensive call is `AutoScrollController.scrollToIndex()`.

Finamp itself requests a distance-scaled animation:

`abs(medianRenderedIndex - targetIndex) / 50 * 300 ms`, clamped to
200..7500 ms.

That requested duration alone cannot explain measured 70-90 s. We therefore
know the excess occurs during the full `scrollToIndex` operation, but we have
not yet instrumented whether it comes from repeated Finamp invocations,
scroll_to_index target discovery/layout, or both.

**Benchmark extension:**

- target index;
- median rendered index;
- requested animation duration;
- number of `scrollToLetter()` invocations for one command;
- number of `scrollToIndex()` calls;
- grid/list mode;
- target row / grid geometry;
- diagnostic direct-offset jump using `MusicScreenGridLayout` geometry, without
  changing production behavior.

The existing upstream binary-search TODO is not the priority: benchmark data
already shows local scan is not the large warm-jump cost.

---

## P1 - Track API fixed-cost investigation

### A1 - Client-side result parsing/fields are not the main 2.7 s cost

**Status: CONFIRMED**

Normal track list requests are one `api.getItems()` request followed by parsing
in the API worker isolate. There is no client-side per-track HTTP loop.

The baseline shows very similar latency for 25/100/500 tracks and for default
versus minimal fields, with very small non-HTTP time.

**BENCHMARK GAP:** determine which Jellyfin query dimensions produce the fixed
server cost.

Add controlled reference variants, preserving semantics where possible:

- current library `ParentId` vs no parent;
- `Recursive=true` vs false;
- current sort vs no sort;
- total-record-count option if confirmed supported by the target Jellyfin API
  version.

Do not change the production track query until those variants are measured.

---

## P1 - Benchmark integrity / instrumentation backlog

These are benchmark problems or missing discriminators found while interpreting
the baseline. Keep them even if the current production hotspot is addressed:

- [ ] D1: worker-count sensitivity matrix on a smaller clean download graph.
- [ ] D2: metadata batch size/coalescing-delay histogram.
- [ ] D3: graph traversal counters by node type and required/info role.
- [ ] D4: album-view lookup call/cache/scan timings.
- [ ] D5: Isar graph mutation timing and cardinality.
- [ ] Q1: split AudioSource construction from `setAudioSources`.
- [ ] F1: direct alphabet-server-seek diagnostic.
- [ ] F2: record target index, requested duration and invocation counts.
- [ ] A1: track API query-shape reference matrix.
- [ ] Add regression assertions that benchmark optimizations do not expose
      private item/library cardinalities through exported metrics.
- [ ] Keep long-operation timeouts as failure guards only; successful completion
      remains event/state-driven.

---

## Optimization order

Do not implement all of these together.

1. Extend download-sync instrumentation D1-D5.
2. Re-run a targeted, smaller download/metadata benchmark.
3. Fix the largest measured download-sync contributor.
4. Split Q1 and then address 10k queue.
5. Extend/fix F1 and F2 separately.
6. Run A1 query variants before touching normal track API behavior.

Every optimization commit should state which baseline metric it is intended to
change and which behavior/correctness invariant must remain unchanged.
