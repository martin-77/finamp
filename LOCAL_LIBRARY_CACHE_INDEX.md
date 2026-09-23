# Local Library Cache and Index

## Goal

Make Finamp responsive with very large Jellyfin music libraries by separating:

1. fast warm-start page caching for existing paged online views; and
2. a persistent local metadata index for search, browse and sorting without
   re-fetching large server result sets.

The download database remains a separate concern. The local index is metadata,
not an offline-playback guarantee.

## Phase 1: persistent page cache

Implemented on this branch.

The existing paged MusicScreen requests remain the source of truth. Successful
online responses are persisted by effective query:

- server id
- user id
- library id
- content type
- sort field/order
- filters
- start index
- page size

Cached pages are returned immediately. Stale pages are revalidated in the
background and provider state is invalidated when the refreshed page has been
stored.

Randomly sorted pages are intentionally excluded from persistence.

This layer is deliberately small and reversible. It improves startup and
navigation without changing Jellyfin query semantics.

## Phase 2: local library index

Use a dedicated Isar collection rather than extending DownloadItem.

Proposed record:

```dart
@collection
class LibraryIndexItem {
  Id isarId;

  @Index(composite: [CompositeIndex("userId"), CompositeIndex("itemId")], unique: true)
  late String serverId;
  late String userId;
  late String itemId;

  @Index()
  late String itemType;

  @Index()
  String? libraryId;

  @Index(caseSensitive: false)
  String? sortName;

  @Index(caseSensitive: false)
  String? name;

  @Index()
  String? albumId;

  List<String> artistIds = [];
  List<String> albumArtistIds = [];
  List<String> genreIds = [];

  bool isFavorite = false;
  int? playCount;
  DateTime? lastPlayedDate;
  DateTime? dateCreated;
  int? productionYear;

  /// Full BaseItemDto payload. This avoids having to duplicate every Jellyfin
  /// metadata field in the indexed schema.
  late String itemJson;

  /// Server-side freshness marker where available.
  String? etag;

  late DateTime indexedAt;
}
```

Exact Isar annotations should be generated and reviewed with the repository's
normal build_runner workflow before this schema is committed.

## Why a dedicated collection

Do not reuse DownloadItem:

- indexed online metadata must exist even when nothing is downloaded;
- deleting downloads must never remove online browse metadata;
- download state has different lifecycle and consistency rules;
- very large library items need indexes chosen for browsing/search, not file state.

## Initial population

The index must never block application startup.

After login:

1. show cached MusicScreen pages immediately;
2. start index sync as low-priority work;
3. enumerate each music library in bounded pages;
4. upsert each page in one Isar write transaction;
5. checkpoint progress per server/user/library;
6. resume from the checkpoint after interruption.

Suggested first-pass page size: 500. This is a benchmark parameter, not a
hard-coded architectural limit.

Do not deserialize or retain the full library in memory.

## Incremental refresh

A full very large crawl on every launch is unacceptable.

Preferred hierarchy:

1. use Jellyfin change/update information if a reliable endpoint is available;
2. otherwise query by DateModified/DateCreated where semantics are sufficient;
3. periodically reconcile full IDs in pages as a slow background maintenance
   operation;
4. remove stale local records only after a complete successful reconciliation,
   never because one request returned an unexpectedly short or empty page.

The last rule is important because the download sync has historically treated
incomplete getItems results as complete state.

## Read strategy

### MusicScreen browse

Short term:
- page cache first;
- Jellyfin page request as revalidation/source of truth.

Once index coverage for a library/type is complete:
- use Isar for name/sort browsing that the local schema can reproduce exactly;
- use Jellyfin for unsupported or server-specific sorts/filters;
- continue revalidation in background.

### Search

Search should prefer the local index once sufficiently populated.

Initial local search fields:
- track/album/artist/playlist name
- sort name
- album name
- artist names

Avoid a single linear scan over 400k JSON blobs. Searchable fields must be
stored separately and indexed.

### Detail pages

Use the stored BaseItemDto JSON for immediate rendering, then refresh the
specific item from Jellyfin when appropriate.

## Mutation handling

Server mutations performed by Finamp should update/invalidate local data
immediately:

- favorite/unfavorite
- playlist edits
- item deletion
- metadata edits where supported

This prevents the cache from temporarily undoing optimistic UI state.

## Cache/index ownership

Every entry is scoped by both server id and user id.

Changing URL for the same server must not invalidate the index.
Logging into another server must never expose cached metadata from the previous
server.

## Failure behavior

- network error: retain cached/indexed data;
- partial page: never infer deletions;
- authentication/server change: isolate by scope;
- malformed cache record: discard only that record;
- interrupted index build: resume from checkpoint.

## Performance instrumentation

Before and after each phase record:

- process start -> Isar/Hive ready
- process start -> runApp
- process start -> first frame
- first frame -> first MusicScreen page visible
- cold vs warm launch
- API requests in first 10 s / 30 s
- bytes received in first 10 s / 30 s
- JSON decode time
- page-cache read/decode time
- Isar query time
- index upsert time per 500 items
- memory high-water mark while indexing

Primary large-library target for development: a high-cardinality music library.

## PR decomposition

Keep reviewable changes separate:

1. persistent paged library cache;
2. startup/performance instrumentation;
3. Isar local-index schema and service;
4. incremental index builder/checkpointing;
5. local search backed by index;
6. selected browse/sort paths backed by index;
7. mutation-driven cache/index invalidation.

Do not combine download-sync pagination (#1774) with the local-index work.
