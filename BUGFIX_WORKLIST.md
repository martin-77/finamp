# Bugfix worklist

This file tracks concrete defects found while analysing Finamp performance and
download/playback lifecycle behaviour. It is intentionally separate from
`performance-analysis-todo.md`: entries here require a code-level correctness
problem, not merely a slow path or an unproven optimization idea.

Status values:

- **CONFIRMED** — current code directly demonstrates the broken invariant.
- **VERIFY** — strong code evidence, but reproduce/test before changing behavior.
- **DISCUSS UPSTREAM** — behavior/design question; do not silently change it in
  the performance branch.
- **DONE** — fix implemented and locally verified.

## Fix order

### B1 — Download queue can strand tasks after native enqueue/connection failure

**Status: CONFIRMED — FIRST FIX**

Files:

- `lib/services/downloads_service_backend.dart`
- `lib/services/downloads_service.dart`

There are two related recovery holes around `background_downloader`.

#### B1a — `FileDownloader().enqueue(...)` returning false leaves the task active

`IsarTaskQueue._advanceQueue()` adds the item's Isar id to
`_activeDownloads` before calling the native downloader.

If `FileDownloader().enqueue(downloadTask)` returns `false`, the current code
only logs:

> We currently have no way to recover here. The user must re-sync to clear the
> stuck download.

The id is not removed from `_activeDownloads`, and no state transition or queue
restart is triggered. Future queue scans exclude that id, so the item can remain
stranded.

**Required invariant:** a failed native enqueue must leave Finamp in a state from
which the item can be attempted again without requiring user repair/resync.

#### B1b — final connection failure requeues Isar state without guaranteed queue restart

The `FileDownloader().updates` listener maps a `TaskConnectionException` back
to `DownloadItemState.enqueued`.

That is sensible, but the status callback does not explicitly restart
`IsarTaskQueue`. `restartDownloads()` is currently tied to lifecycle/settings
entry points such as app resume and offline -> online transitions.

Because `executeDownloads()` is an enqueueing pass rather than a lifetime
supervisor for already-submitted native tasks, a task that fails after the pass
has returned can become `enqueued` without a guaranteed immediate resubmission.

This is especially relevant after transient connectivity changes.

**Required invariant:** whenever a native transfer becomes retryable Finamp state,
there must be a deterministic path that eventually resubmits it while downloads
are allowed, without requiring an unrelated UI/lifecycle event.

#### Fix constraints

- preserve `requireWifiForDownloads`; native Wi-Fi gating remains authoritative;
- preserve offline-mode gating;
- do not create a hot retry loop for an unreachable server;
- do not duplicate native tasks for the same Isar item;
- keep `_activeDownloads` consistent with actual native downloader ownership;
- connection backoff/error accounting must continue to work;
- add focused regression coverage before changing behavior.

---

### B2 — Network target change vs already-submitted download task

**Status: VERIFY / DISCUSS SEPARATELY**

A `DownloadTask` receives an absolute URL when it is submitted to
`background_downloader`. A task already owned by the native downloader can
therefore retain the old local/public target after Finamp changes
`FinampUser.baseURL`.

This is related to B1 because a stale task may fail and rely on the requeue path,
but the correct endpoint-refresh policy is a separate design decision.

Do not fold a URL-rewrite mechanism into B1. First make queue recovery correct;
then verify how native retry/resume behaves across a real network-target change.

---

### B3 — `FinampUser.update()` starts persistence asynchronously

**Status: VERIFY**

`FinampUser.update()` mutates the current object synchronously but calls
`FinampUserHelper.saveUser(this)` without awaiting it.

Most callers immediately see the new in-memory value, so this is not by itself a
confirmed product bug. However, persistence, provider invalidation and
source-change listeners are asynchronous relative to the caller.

Before changing this API, verify whether any production caller relies on
`changeTargetUrl()` returning only after the Isar/provider transition has
completed.

Note: the benchmark-only previous/new network-target diagnostic is also suspect
because `saveUser()` reads `previous = currentUser` after the same mutable
object has already been changed. Keep benchmark instrumentation fixes separate
from product semantics.

---

### B4 — Fast-scroller refreshed late-letter path performs sequential paging

**Status: CONFIRMED PERFORMANCE DEFECT, NOT YET A CORRECTNESS FIX**

Measured refreshed album jumps to late letters can take tens to over one hundred
seconds and issue hundreds of requests. Current logic progressively loads
100-item pages until the target letter is available.

The code/history shows this evolved to preserve absent-letter and nearest-letter
correctness. Treat the excessive work as a performance defect, but do not replace
it until direct `NameStartsWithOrGreater` behavior is verified for all sort and
missing-letter cases.

Tracked in detail in `performance-analysis-todo.md`.

---

### B5 — Fast-scroller warm-list jump can spend tens of seconds in scrolling

**Status: CONFIRMED PERFORMANCE DEFECT**

When data is already loaded, network paging is no longer the cause. The slow path
is dominated by the target scroll / `scrollToIndex` behavior. Measured warm
album jumps can still take roughly 70–90 seconds.

Instrument/fix independently from B4 so refreshed paging and local geometry are
not conflated.

---

### B6 — 10k queue construction scales pathologically

**Status: CONFIRMED PERFORMANCE DEFECT; ROOT SUBPHASE STILL OPEN**

10k playback queue construction takes roughly 80+ seconds, while media-item
construction itself is small. Existing `queueAudioSourcesInstallMicros` still
combines FinampQueueItem -> AudioSource conversion with
`_player.setAudioSources()`.

Split those phases first. Preserve the single AudioSource-backed queue invariants
introduced to keep queue/index/shuffle edits correct.

---

### B7 — Download sync graph performs excessive serialized work

**Status: CONFIRMED PERFORMANCE DEFECT; CAUSE DECOMPOSITION OPEN**

The download graph is the largest measured cost: bench100 is minutes and
bench1000 is tens of minutes before/around transfer completion.

Known mechanisms include:

- default one sync worker, deliberately conservative for responsiveness;
- serial processing within claimed sync batches;
- 250 ms metadata request coalescing;
- all-playlists metadata expansion;
- repeated local graph/Isar work.

Do not increase global concurrency first. Instrument D1–D5 from
`performance-analysis-todo.md`, then remove unnecessary work while preserving
the maintainers' low-end-device and correctness constraints.

---

### B8 — Fixed 10-second download queue startup delay

**Status: VERIFY / INTENTIONAL TRADEOFF**

`DownloadsService.startQueues()` waits ten seconds before executing stored
sync/delete/download work so startup/library loading is not slowed down.

This contributes materially to the normal startup timeline, but the source
comment documents the intent. Treat it as a tradeoff to measure, not a bug to
delete.

---

## Explicitly not in this bugfix queue

### Playback local/public AudioSource policy

The current queue materializes the active server URL into long-lived
`AudioSource` objects. We intend to discuss upstream whether playback should
simply use the configured public URL as its stable/canonical URI, with seamless
Wi-Fi/mobile behavior by default and an optional LAN + buffered-only mode.

This is a design discussion, not a silent local bugfix.

Relevant upstream context includes issues #485, #804, #1222 and #239.

### Already-fixed benchmark/harness defects

The earlier benchmark deadlocks, useful-buffer race, summary shadowing,
persistent offline-transition handling and interrupted bench1000 recovery are
already fixed on this branch. Do not reopen them unless regression evidence
appears.

---

## Execution order

1. **B1: download queue self-recovery** — implement focused regression tests and
   fix both native-enqueue failure and retryable connection-failure resubmission.
2. **B7: download sync instrumentation D1–D5** — because we are already in the
   download subsystem and it is the largest performance hotspot.
3. Apply the first measured download-sync optimization and run the targeted
   bench100 diagnostic.
4. **B6: queue 10k phase split**, then optimize the proven subphase.
5. **B4/B5: fast-scroller**, refreshed and warm paths independently.
6. Revisit **B3/B8** only with evidence from the preceding work.
7. Run the full multi-hour benchmark only after targeted fixes are stable, as a
   regression gate rather than an iteration loop.
