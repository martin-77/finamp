# Maintainer TODO / FIXME register

This file records **existing maintainer TODO/FIXME comments** encountered while
reviewing the performance-relevant code paths. It is intentionally separate from
[`performance-analysis-todo.md`](performance-analysis-todo.md), which contains
our benchmark findings and new investigation tasks.

This is an initial performance-adjacent inventory, not a claim that every TODO in
the entire repository has already been catalogued. Add entries as additional
subsystems are reviewed. Do not convert an upstream TODO into a benchmark
finding without evidence.

## Downloads

| Location | Existing maintainer note | Relevance |
|---|---|---|
| `lib/services/downloads_service.dart:480` | `TODO use download groups to send notification when item fully downloaded?` | Download completion/notification architecture; not currently identified as a performance cause. |
| `lib/services/downloads_service_backend.dart:750` | `TODO show a confirmation snackbar once all downloads are complete` | UX only; keep separate from sync throughput. |
| `lib/services/downloads_service_backend.dart:991` | `TODO alert user if image deduplication is broken.` | Important correctness invariant when changing metadata/image graph traversal. |

### Design context without TODO marker

`DOWNLOADS_PLAN.md` explains that the Isar rewrite was primarily motivated by
correct relational modeling, reliable add/remove behavior, recovery and offline
support. This context matters when optimizing graph traversal: the dependency
graph is not accidental bookkeeping that can simply be removed.

## Queue / playback

| Location | Existing maintainer note | Relevance |
|---|---|---|
| `lib/services/queue_service.dart:851` | `TODO cut more/all usages of this over to startSlicePlayback` | Indicates an intended convergence toward the newer slice-based playback path. Relevant before redesigning large queue initialization. |
| `lib/services/queue_service.dart:918` | `TODO also do pre-cache work in other queue add methods?` | Related to queue preparation strategy and potentially startup/append behavior. |
| `lib/services/queue_service.dart:962` | `TODO verify we haven't made other queue changes?` | Explicit correctness concern around asynchronous follow-up queue insertion. Important if queue loading becomes chunked/lazy. |
| `lib/services/music_player_background_task.dart:968` | `TODO Finamp should probably use its own event system that is able to convey the necessary information` | Playback event/state architecture; potentially relevant to robust completion/state tracking. |
| `lib/services/music_player_background_task.dart:1360` | `TODO eventually we probably want separate settings for this, and not store them as individual booleans in Hive` | Settings architecture; unrelated to current queue performance. |

### Historical design context

Commit `d80a632...` changed playback to keep one AudioSource-backed queue and
derive the UI queue from it specifically to fix queue modification/index
synchronization bugs. Large-queue optimizations must preserve that correctness
or explicitly replace it with a tested logical/native queue mapping.

## Jellyfin API helper

| Location | Existing maintainer note | Relevance |
|---|---|---|
| `lib/services/jellyfin_api_helper.dart:413` | `FIXME this check will break for mixed item types` | API helper correctness debt. |
| `lib/services/jellyfin_api_helper.dart:1442` | `TODO apply this directly here in the API helper once it has been refactored to work with finamp_models.ContentType and SortAndFilterConfiguration instead of raw strings` | Confirms known API-helper abstraction debt around sort/filter semantics. Relevant to direct alphabet seeking and track-query experiments. |

## Music screen provider

| Location | Existing maintainer note | Relevance |
|---|---|---|
| `lib/services/music_screen_provider.dart:222` | `TODO wait for current active loads to complete. Do error response?` | Directly relevant to concurrent paging/queue slice loads. |
| `lib/services/music_screen_provider.dart:243` | `TODO break request up into pages?` | Directly relevant to large queue/slice requests and request-size behavior. |
| `lib/services/music_screen_provider.dart:298` | `TODO refactor so we only need to provide the id?` | Provider/API structure; not yet a measured hotspot. |
| `lib/services/music_screen_provider.dart:333` | `TODO properly handle the "NameStartsWith" filter in the API helper` | Directly relevant to replacing sequential alphabet paging with server-side seeking. |
| `lib/services/music_screen_provider.dart:383` | `FIXME this seems to also return metadata-only albums which don't have any downloaded children` | Offline metadata correctness; important when changing playlist metadata graph semantics. |
| `lib/services/music_screen_provider.dart:407` | `FIXME support allowing multiple types` | Filtering/API capability limitation. |
| `lib/services/music_screen_provider.dart:408` | `TODO use the filter config for this instead of global(several places)?` | Known duplication/inconsistent filtering concern. |
| `lib/services/music_screen_provider.dart:557` | Legacy artist-track sorting TODO/note | Sorting compatibility debt; relevant when validating fast-scroller ordering. |
| `lib/services/music_screen_provider.dart:743` | `TODO I don't think the downloads system can actually handle collections?` | Offline/download capability uncertainty that must be checked before broad graph changes. |
| `lib/services/music_screen_provider.dart:747` | `TODO collections are cross-library - should we really filter by library here?` | Cross-library semantics; relevant to direct filtering and offline queries. |
| `lib/services/music_screen_provider.dart:769` | second `TODO properly handle the "NameStartsWith" filter in the API helper` | Same direct alphabet-seek blocker in another provider path. |
| `lib/services/music_screen_provider.dart:779` | `TODO allow filtering collection child types?` | API/filter capability debt. |

## Music screen / fast scroller

| Location | Existing maintainer note | Relevance |
|---|---|---|
| `lib/components/MusicScreen/music_screen_tab_view.dart:40` | Question whether the tab view is too generic and could be simplified | Architectural context: the same component handles several list/grid/displayable cases, which partly explains generic scrolling logic. |
| `lib/components/MusicScreen/music_screen_tab_view.dart:521` | `TODO use binary search to improve performance for already loaded pages` | Real optimization debt, but current benchmark shows local scan is not the dominant warm album-jump cost. |
| `lib/components/MusicScreen/music_screen_tab_view.dart:536` | `TODO how does jellyfin sort handle this? Do we match?` | Critical correctness question before direct alphabet seeking or binary search. |
| `lib/components/MusicScreen/music_screen_tab_view.dart:548` | `TODO: Handle this case.` | Unsupported displayable case in alphabet scanning. |
| `lib/components/MusicScreen/music_screen_tab_view.dart:703` | `TODO this has ref.watch, does it explode?` | Riverpod lifecycle concern around refresh. |
| `lib/components/MusicScreen/music_screen_tab_view.dart:706` | `TODO test error cases?` | Explicit missing error-path coverage. |

### Historical design context

The fast scroller evolved through several correctness/UX commits in October
2023:

- `2cac3bbe...`: initial “Jump to Letter” implementation;
- `ad467...`: pagination support;
- `47e1dcb...`: continue scrolling/loading until an element is found;
- `5a768e...`: nearest available-letter behavior;
- `5ec65b...`: performance refactor.

This history explains why current navigation sequentially extends the loaded
prefix and why a generic scroll controller is used. It does not prove that the
current algorithm is optimal; it documents the compatibility behaviors that a
replacement must preserve.

## Maintenance rule for this file

When a reviewed file contains a TODO/FIXME:

1. copy the intent here with file/line;
2. classify whether it intersects a measured benchmark hotspot;
3. keep the original source comment in place;
4. only move it into `performance-analysis-todo.md` as an actionable
   performance task when benchmark/code evidence supports the connection.
