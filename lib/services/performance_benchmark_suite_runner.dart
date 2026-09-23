import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/models/music_models.dart';
import 'package:finamp/screens/album_screen.dart';
import 'package:finamp/screens/artist_screen.dart';
import 'package:finamp/services/item_by_id_provider.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/queue_service.dart';
import 'package:finamp/services/music_providers.dart';
import 'package:finamp/services/performance_benchmark_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:get_it/get_it.dart';

/// Automated entry point for the test-only performance benchmark branch.
///
/// This first phase intentionally uses deterministic API-backed operations so a
/// benchmark run starts automatically after authentication. UI navigation,
/// playback and download phases are layered on top of the same recorder.
class PerformanceBenchmarkSuiteRunner {
  static final PerformanceBenchmarkSuiteRunner instance =
      PerformanceBenchmarkSuiteRunner._();

  PerformanceBenchmarkSuiteRunner._();

  static const _benchmarkTargets = <String, int>{
    "bench-10": 10,
    "bench-100": 100,
    "bench-1000": 1000,
    "bench-10000": 10000,
  };

  bool _armed = false;
  bool _running = false;

  void arm() {
    if (!PerformanceBenchmarkService.enabled || _armed) return;
    _armed = true;

    final recorder = PerformanceBenchmarkService.instance;
    unawaited(recorder.resetHostStream());
    recorder.diagnostic(
      "suite-armed",
      values: {"variant": PerformanceBenchmarkService.variant},
    );

    GetIt.instance<FinampUserHelper>().runUserHook(() {
      unawaited(_runAfterAuthentication());
    });

    if (GetIt.instance<FinampUserHelper>().currentUser == null) {
      recorder.diagnostic("suite-waiting-for-login");
    }
  }

  Future<void> _runAfterAuthentication() async {
    if (_running) return;
    _running = true;

    final recorder = PerformanceBenchmarkService.instance;
    try {
      // Keep benchmark work out of the authentication transition itself,
      // then wait for Finamp's known asynchronous startup jobs to finish.
      await WidgetsBinding.instance.endOfFrame;
      recorder.diagnostic("suite-authenticated");
      await recorder.waitForStartupQuiescence(
        quietPeriod: const Duration(seconds: 3),
        timeout: const Duration(minutes: 3),
      );
      await recorder.waitForNetworkQuiescence(
        quietPeriod: const Duration(seconds: 3),
        timeout: const Duration(minutes: 3),
      );
      recorder.diagnostic("startup-baseline-complete");

      final targetsReady = await _discoverAndValidateTargets();
      if (!targetsReady) {
        recorder.diagnostic(
          "suite-blocked",
          values: {"reason": "benchmark-target-validation"},
        );
        return;
      }

      await _runCollectionFirstPageBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "authenticated-api-baseline"},
      );

      await _runUiTabBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "ui-tab-baseline"},
      );

      await _runPagingBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "deep-paging"},
      );

      await _runSearchBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "search"},
      );

      await _runAlphabetBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "alphabet-fast-scroller"},
      );

      await _runDetailBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "detail-screens"},
      );

      await _runPlaybackBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "queue-playback"},
      );

      recorder.diagnostic(
        "full-suite-incomplete",
        values: {"nextPhase": "search-paging-download-restart"},
      );
      await recorder.flushHostStream();
    } catch (error) {
      recorder.diagnostic(
        "suite-error",
        values: {"errorType": error.runtimeType.toString()},
      );
      await recorder.flushHostStream();
    } finally {
      _running = false;
    }
  }

  Future<bool> _discoverAndValidateTargets() async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final recorder = PerformanceBenchmarkService.instance;
    var allValid = true;

    for (final targetEntry in _benchmarkTargets.entries) {
      final alias = targetEntry.key;
      final expectedCount = targetEntry.value;

      await recorder.startRun(
        scenario: "benchmark-target-validation",
        variant: PerformanceBenchmarkService.variant,
        mode: "online",
        targetAlias: alias,
        targetType: "Playlist",
      );

      try {
        var pagesFetched = 0;
        var playlistItemsSeen = 0;
        final normalizedAlias = alias.trim().toLowerCase();

        final matches = await recorder.runStep(
          name: "playlist-discovery",
          operation: () async {
            const pageSize = 200;
            var startIndex = 0;
            final matches = <BaseItemDto>[];

            while (true) {
              final page = await api.getItemsWithTotalRecordCount(
                includeItemTypes: "Playlist",
                recursive: true,
                startIndex: startIndex,
                limit: pageSize,
              );
              pagesFetched++;
              final items = page.items ?? const <BaseItemDto>[];
              playlistItemsSeen += items.length;
              matches.addAll(
                items.where((item) {
                  final normalizedName = item.name?.trim().toLowerCase();
                  return normalizedName == normalizedAlias ||
                      normalizedName == "$normalizedAlias [smart]";
                }),
              );

              if (items.length < pageSize) break;
              startIndex += items.length;
            }

            return matches;
          },
        );

        recorder.metric("playlistPagesFetched", pagesFetched);
        recorder.metric("playlistItemsSeen", playlistItemsSeen);
        recorder.metric("matchingPlaylists", matches.length);
        if (matches.length != 1) {
          recorder.metric("valid", false);
          recorder.metric("expectedTrackCount", expectedCount);
          await recorder.finishRun();
          allValid = false;
          continue;
        }

        final playlist = matches.single;
        await recorder.saveTarget(
          alias: alias,
          itemType: "Playlist",
          itemId: playlist.id.raw,
        );

        final children = await recorder.runStep(
          name: "playlist-track-resolution",
          timeout: const Duration(minutes: 5),
          operation: () => api.getItems(
            parentItem: playlist,
            includeItemTypes: "Audio",
            recursive: true,
          ),
        );

        if (alias == "bench-100" && children != null && children.isNotEmpty) {
          final track = children.first;
          await recorder.saveTarget(
            alias: "detail-track",
            itemType: "Audio",
            itemId: track.id.raw,
          );

          BaseItemId? albumId;
          BaseItemId? artistId;
          for (final candidate in children) {
            albumId ??= candidate.albumId;
            if (artistId == null && (candidate.albumArtists?.isNotEmpty ?? false)) {
              artistId = candidate.albumArtists!.first.id;
            }
            if (artistId == null && (candidate.artistItems?.isNotEmpty ?? false)) {
              artistId = candidate.artistItems!.first.id;
            }
            if (albumId != null && artistId != null) break;
          }

          if (albumId != null) {
            await recorder.saveTarget(
              alias: "detail-album",
              itemType: "MusicAlbum",
              itemId: albumId.raw,
            );
          }
          if (artistId != null) {
            await recorder.saveTarget(
              alias: "detail-artist",
              itemType: "MusicArtist",
              itemId: artistId.raw,
            );
          }
        }

        final actualCount = children?.length ?? 0;
        final valid = actualCount == expectedCount;
        recorder.metric("expectedTrackCount", expectedCount);
        recorder.metric("resolvedTrackCount", actualCount);
        recorder.metric("valid", valid);
        await recorder.finishRun();

        if (!valid) allValid = false;
      } catch (_) {
        // runStep persists the failed/timeout run before rethrowing.
        allValid = false;
      }
    }

    return allValid;
  }

  Future<void> _runUiTabBaselines() async {
    final recorder = PerformanceBenchmarkService.instance;

    const rounds = <List<String>>[
      ["albums", "artists", "playlists", "tracks", "genres"],
      ["genres", "tracks", "playlists", "artists", "albums"],
      ["playlists", "albums", "genres", "artists", "tracks"],
    ];

    // Fixed delays are only stabilization boundaries and are deliberately
    // outside measured runs. "refreshed-view" means provider refresh inside
    // one running process; true cold-process measurements require relaunch.
    recorder.diagnostic(
      "ui-stabilization-start",
      values: {"seconds": 3, "afterStartupQuiescence": true},
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    recorder.diagnostic("ui-stabilization-complete");

    for (var round = 0; round < rounds.length; round++) {
      recorder.diagnostic(
        "ui-round-start",
        values: {"round": round + 1},
      );

      for (final tab in rounds[round]) {
        await _runUiTabBaseline(
          tab,
          mode: "refreshed-view",
          round: round + 1,
        );

        await _uiCooldown(recorder, tab);

        await _runUiTabBaseline(
          tab,
          mode: "warm-view",
          round: round + 1,
        );

        await _uiCooldown(recorder, tab);
      }

      recorder.diagnostic(
        "ui-round-complete",
        values: {"round": round + 1},
      );
    }
  }

  Future<void> _uiCooldown(
    PerformanceBenchmarkService recorder,
    String tab,
  ) async {
    recorder.diagnostic(
      "ui-tab-cooldown-start",
      values: {"contentType": tab, "seconds": 5},
    );
    await Future<void>.delayed(const Duration(seconds: 5));
    recorder.diagnostic(
      "ui-tab-cooldown-complete",
      values: {"contentType": tab},
    );
  }

  Future<void> _runUiTabBaseline(
    String tab, {
    required String mode,
    required int round,
  }) async {
    final recorder = PerformanceBenchmarkService.instance;

    await recorder.startRun(
      scenario: "ui-tab-first-rendered-content-$tab",
      variant: PerformanceBenchmarkService.variant,
      mode: mode,
      targetType: tab,
    );
    recorder.metric("round", round);

    try {
      await recorder.runStep(
        name: "ui-tab-open",
        timeout: const Duration(seconds: 120),
        operation: () => recorder.requestUiTab(
          contentType: tab,
          refresh: mode == "refreshed-view",
          timeout: const Duration(seconds: 115),
        ),
      );
      await recorder.finishRun();
    } catch (_) {
      // runStep persists the failed/timeout run before rethrowing.
    }
  }

  Future<void> _runSearchBaselines() async {
    final recorder = PerformanceBenchmarkService.instance;
    final api = GetIt.instance<JellyfinApiHelper>();

    const queries = <String, String>{
      "iron-maiden": "Iron Maiden",
      "metallica": "Metallica",
      "kettcar": "Kettcar",
    };
    const tabs = <String>["artists", "albums", "tracks"];

    for (final queryEntry in queries.entries) {
      final queryAlias = queryEntry.key;
      final query = queryEntry.value;

      // Resolve a deterministic private artist -> album -> track chain once
      // for later detail/playback scenarios. Only aliases are exported.
      final artistResult = await api.getItemsWithTotalRecordCount(
        includeItemTypes: "MusicArtist",
        searchTerm: query,
        recursive: true,
        limit: 25,
      );
      final artistMatches = (artistResult.items ?? const <BaseItemDto>[])
          .where(
            (item) =>
                item.name?.trim().toLowerCase() ==
                query.trim().toLowerCase(),
          )
          .toList();

      recorder.diagnostic(
        "search-target-discovery",
        values: {
          "queryAlias": queryAlias,
          "artistMatches": artistMatches.length,
        },
      );

      if (artistMatches.length == 1) {
        final artist = artistMatches.single;
        await recorder.saveTarget(
          alias: "search-artist-$queryAlias",
          itemType: "MusicArtist",
          itemId: artist.id.raw,
        );

        final albums = await api.getItems(
          parentItem: artist,
          includeItemTypes: "MusicAlbum",
          recursive: true,
        );
        if (albums != null && albums.isNotEmpty) {
          final album = albums.first;
          await recorder.saveTarget(
            alias: "search-album-$queryAlias",
            itemType: "MusicAlbum",
            itemId: album.id.raw,
          );

          final tracks = await api.getItems(
            parentItem: album,
            includeItemTypes: "Audio",
            recursive: true,
          );
          if (tracks != null && tracks.isNotEmpty) {
            await recorder.saveTarget(
              alias: "search-track-$queryAlias",
              itemType: "Audio",
              itemId: tracks.first.id.raw,
            );
          }
        }
      }

      for (final tab in tabs) {
        // Return to the unfiltered list first. This is outside the measured run
        // and prevents the previous query from becoming hidden setup work.
        await recorder.requestSearch(
          contentType: tab,
          queryAlias: "clear",
          query: "",
          timeout: const Duration(seconds: 120),
        );
        await Future<void>.delayed(const Duration(seconds: 2));

        await recorder.startRun(
          scenario: "ui-search-$tab",
          variant: PerformanceBenchmarkService.variant,
          mode: "query-first",
          targetAlias: queryAlias,
          targetType: tab,
        );
        try {
          recorder.metric("queryLength", query.length);
          await recorder.runStep(
            name: "search",
            timeout: const Duration(seconds: 120),
            operation: () => recorder.requestSearch(
              contentType: tab,
              queryAlias: queryAlias,
              query: query,
              timeout: const Duration(seconds: 115),
            ),
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep persists failures/timeouts.
        }

        await Future<void>.delayed(const Duration(seconds: 2));

        await recorder.startRun(
          scenario: "ui-search-$tab",
          variant: PerformanceBenchmarkService.variant,
          mode: "query-warm",
          targetAlias: queryAlias,
          targetType: tab,
        );
        try {
          recorder.metric("queryLength", query.length);
          await recorder.runStep(
            name: "search",
            timeout: const Duration(seconds: 60),
            operation: () => recorder.requestSearch(
              contentType: tab,
              queryAlias: queryAlias,
              query: query,
              timeout: const Duration(seconds: 55),
            ),
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep persists failures/timeouts.
        }

        await Future<void>.delayed(const Duration(seconds: 4));
      }
    }

    // Restore normal browsing before the next phase.
    await recorder.requestSearch(
      contentType: "tracks",
      queryAlias: "clear",
      query: "",
      timeout: const Duration(seconds: 120),
    );
    await Future<void>.delayed(const Duration(seconds: 3));
  }

  Future<void> _runPagingBaselines() async {
    final recorder = PerformanceBenchmarkService.instance;
    const tabs = <String>[
      "artists",
      "albums",
      "tracks",
      "playlists",
      "genres",
    ];

    for (final requestedTab in tabs) {
      final resolvedTab = await recorder.requestUiTab(
        contentType: requestedTab,
        refresh: true,
        timeout: const Duration(seconds: 120),
      );
      await Future<void>.delayed(const Duration(seconds: 3));

      for (var page = 2; page <= 11; page++) {
        await recorder.startRun(
          scenario: "ui-next-page-$requestedTab",
          variant: PerformanceBenchmarkService.variant,
          mode: "online-sequential",
          targetType: resolvedTab,
        );
        recorder.metric("requestedPageOrdinal", page);

        try {
          await recorder.runStep(
            name: "next-page",
            timeout: const Duration(seconds: 120),
            operation: () => recorder.requestNextPage(
              contentType: resolvedTab,
              timeout: const Duration(seconds: 115),
            ),
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep persists failures/timeouts.
        }

        await Future<void>.delayed(const Duration(seconds: 2));
      }

      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _runPlaybackBaselines() async {
    const targets = <(String, String)>[
      ("detail-track", "track"),
      ("detail-album", "album"),
      ("detail-artist", "artist"),
      ("bench-10", "playlist"),
      ("bench-100", "playlist"),
      ("bench-1000", "playlist"),
      ("bench-10000", "playlist"),
    ];

    for (final entry in targets) {
      final (alias, type) = entry;
      await _runPlaybackBaseline(
        targetAlias: alias,
        playableType: type,
        mode: "online-first",
      );
      await Future<void>.delayed(const Duration(seconds: 4));
      await _runPlaybackBaseline(
        targetAlias: alias,
        playableType: type,
        mode: "online-warm",
      );
      await Future<void>.delayed(const Duration(seconds: 4));
    }
  }

  Future<void> _runPlaybackBaseline({
    required String targetAlias,
    required String playableType,
    required String mode,
  }) async {
    final recorder = PerformanceBenchmarkService.instance;
    final target = await recorder.getTarget(targetAlias);
    if (target == null) {
      recorder.diagnostic(
        "playback-target-missing",
        values: {
          "targetAlias": targetAlias,
          "targetType": playableType,
        },
      );
      return;
    }

    final container = GetIt.instance<ProviderContainer>();
    final item = await container.read(
      itemByIdProvider(BaseItemId(target.itemId)).future,
    );
    if (item == null) {
      recorder.diagnostic(
        "playback-target-unresolvable",
        values: {
          "targetAlias": targetAlias,
          "targetType": playableType,
        },
      );
      return;
    }

    final FinampPlayable playable = switch (playableType) {
      "track" => Track.fromItem(item),
      "album" => Album.fromItem(item),
      "artist" => Artist.fromItem(item),
      "playlist" => Playlist.fromItem(item),
      _ => throw UnsupportedError("Unsupported playback type $playableType"),
    };

    await recorder.startRun(
      scenario: "playback-startup-$playableType",
      variant: PerformanceBenchmarkService.variant,
      mode: mode,
      targetAlias: targetAlias,
      targetType: playableType,
    );

    try {
      final playingFuture = recorder.waitForEvent(
        "player-playing",
        timeout: const Duration(minutes: 3),
      );
      final firstPositionFuture = recorder.waitForEvent(
        "player-first-position-advance",
        timeout: const Duration(minutes: 3),
      );

      final slice = await recorder.runStep(
        name: "playable-slice-provider",
        timeout: const Duration(minutes: 5),
        operation: () => container.read(
          getPlayableSliceProvider(
            item: playable,
            startingOffset: 0,
          ).future,
        ),
      );

      await recorder.runStep(
        name: "queue-and-player-start",
        timeout: const Duration(minutes: 10),
        operation: () => GetIt.instance<QueueService>().startSlicePlayback(slice),
      );

      await recorder.runStep(
        name: "wait-player-playing",
        timeout: const Duration(minutes: 3),
        operation: () => playingFuture,
      );
      await recorder.runStep(
        name: "wait-first-position",
        timeout: const Duration(minutes: 3),
        operation: () => firstPositionFuture,
      );

      await recorder.finishRun();
    } catch (_) {
      // runStep persists failures/timeouts.
    }
  }

  Future<void> _runDetailBaselines() async {
    const aliases = <(String, String)>[
      ("detail-album", "album"),
      ("detail-artist", "artist"),
      ("bench-10", "playlist"),
      ("bench-100", "playlist"),
      ("bench-1000", "playlist"),
      ("bench-10000", "playlist"),
    ];

    for (final entry in aliases) {
      final (alias, detailType) = entry;
      await _runDetailBaseline(
        targetAlias: alias,
        detailType: detailType,
        mode: "refreshed-detail",
        refresh: true,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      await _runDetailBaseline(
        targetAlias: alias,
        detailType: detailType,
        mode: "warm-detail",
        refresh: false,
      );
      await Future<void>.delayed(const Duration(seconds: 3));
    }
  }

  Future<void> _runDetailBaseline({
    required String targetAlias,
    required String detailType,
    required String mode,
    required bool refresh,
  }) async {
    final recorder = PerformanceBenchmarkService.instance;
    final target = await recorder.getTarget(targetAlias);
    if (target == null) {
      recorder.diagnostic(
        "detail-target-missing",
        values: {
          "targetAlias": targetAlias,
          "targetType": detailType,
        },
      );
      return;
    }

    final container = GetIt.instance<ProviderContainer>();
    final item = await container.read(
      itemByIdProvider(BaseItemId(target.itemId)).future,
    );
    if (item == null) {
      recorder.diagnostic(
        "detail-target-unresolvable",
        values: {
          "targetAlias": targetAlias,
          "targetType": detailType,
        },
      );
      return;
    }

    await recorder.startRun(
      scenario: "detail-first-rendered-content-$detailType",
      variant: PerformanceBenchmarkService.variant,
      mode: mode,
      targetAlias: targetAlias,
      targetType: detailType,
    );

    try {
      final navigator = GlobalSnackbar.navigatorState;
      if (navigator == null) {
        throw StateError("Navigator is not available for detail benchmark");
      }

      await recorder.runStep(
        name: "detail-open",
        timeout: const Duration(seconds: 180),
        operation: () => recorder.requestDetail(
          targetAlias: targetAlias,
          targetType: detailType,
          itemId: target.itemId,
          refresh: refresh,
          timeout: const Duration(seconds: 175),
          open: () {
            switch (detailType) {
              case "artist":
                navigator.push(
                  MaterialPageRoute<ArtistScreen>(
                    builder: (_) => ArtistScreen(widgetArtist: item),
                  ),
                );
              case "album" || "playlist":
                navigator.push(
                  MaterialPageRoute<AlbumScreen>(
                    builder: (_) => AlbumScreen(parent: item),
                  ),
                );
              default:
                throw UnsupportedError("Unsupported detail type $detailType");
            }
          },
        ),
      );
      await recorder.finishRun();

      if (navigator.canPop()) {
        navigator.pop();
        await WidgetsBinding.instance.endOfFrame;
      }
    } catch (_) {
      if (PerformanceBenchmarkService.instance.activeRun != null) {
        // runStep already persisted failure/timeout where applicable.
      }
      final navigator = GlobalSnackbar.navigatorState;
      if (navigator?.canPop() ?? false) {
        navigator!.pop();
        await WidgetsBinding.instance.endOfFrame;
      }
    }
  }

  Future<void> _runAlphabetBaselines() async {
    final recorder = PerformanceBenchmarkService.instance;

    const tabs = <String>["tracks", "artists", "albums"];
    const letters = <String>["#", "A", "G", "M", "Z"];

    for (final requestedTab in tabs) {
      // Refresh once outside the measured jump runs. The first sequence then
      // exercises the real incremental loading path from a fresh first page.
      final resolvedTab = await recorder.requestUiTab(
        contentType: requestedTab,
        refresh: true,
        timeout: const Duration(seconds: 120),
      );
      await Future<void>.delayed(const Duration(seconds: 3));

      for (final letter in letters) {
        await recorder.startRun(
          scenario: "alphabet-jump-$requestedTab-$letter",
          variant: PerformanceBenchmarkService.variant,
          mode: "refreshed-sequential",
          targetType: resolvedTab,
        );
        try {
          recorder.metric("letter", letter);
          await recorder.runStep(
            name: "alphabet-jump",
            timeout: const Duration(seconds: 120),
            operation: () => recorder.requestAlphabetJump(
              contentType: resolvedTab,
              letter: letter,
              timeout: const Duration(seconds: 115),
            ),
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep finalized the failed run.
        }
        await Future<void>.delayed(const Duration(seconds: 2));
      }

      // At this point jumping towards Z has loaded the expensive path. Repeat
      // the same sequence without a provider refresh to expose pure warm-list
      // scrolling and already-loaded-page behaviour.
      for (final letter in letters) {
        await recorder.startRun(
          scenario: "alphabet-jump-$requestedTab-$letter",
          variant: PerformanceBenchmarkService.variant,
          mode: "warm-loaded",
          targetType: resolvedTab,
        );
        try {
          recorder.metric("letter", letter);
          await recorder.runStep(
            name: "alphabet-jump",
            timeout: const Duration(seconds: 60),
            operation: () => recorder.requestAlphabetJump(
              contentType: resolvedTab,
              letter: letter,
              timeout: const Duration(seconds: 55),
            ),
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep finalized the failed run.
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _runCollectionFirstPageBaselines() async {
    final api = GetIt.instance<JellyfinApiHelper>();
    final recorder = PerformanceBenchmarkService.instance;

    const collections = <(String, String)>[
      ("artists", "MusicArtist"),
      ("albums", "MusicAlbum"),
      ("tracks", "Audio"),
      ("playlists", "Playlist"),
      ("genres", "MusicGenre"),
    ];

    for (final collection in collections) {
      final (scenarioName, itemType) = collection;
      await recorder.startRun(
        scenario: "collection-first-page-$scenarioName",
        variant: PerformanceBenchmarkService.variant,
        mode: "online",
        targetType: itemType,
      );

      try {
        final result = await recorder.runStep(
          name: "request",
          timeout: const Duration(minutes: 2),
          operation: () => api.getItemsWithTotalRecordCount(
            includeItemTypes: itemType,
            recursive: true,
            startIndex: 0,
            limit: 100,
          ),
        );

        recorder.metric("pageSize", result.items?.length ?? 0);
        // Deliberately do not export totalRecordCount: it may reveal private
        // library cardinality. The benchmark only needs first-page work here.
        await recorder.finishRun();
      } catch (_) {
        // runStep already finalized the failed run.
      }
    }
  }
}
