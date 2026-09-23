import 'dart:async';

import 'package:finamp/components/global_snackbar.dart';
import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/music_player_background_task.dart';
import 'package:finamp/services/finamp_settings_helper.dart';
import 'package:finamp/services/downloads_service.dart';
import 'package:finamp/services/album_image_provider.dart';
import 'package:finamp/models/finamp_models.dart';
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
    unawaited(_armAsync());
  }

  Future<void> _armAsync() async {
    final recorder = PerformanceBenchmarkService.instance;
    recorder.startHeartbeat();
    final stage = await recorder.getSuiteStage();

    recorder.diagnostic(
      "suite-armed",
      values: {
        "variant": PerformanceBenchmarkService.variant,
        "suiteRunId": PerformanceBenchmarkService.suiteRunId,
        "stage": stage ?? "fresh",
      },
    );

    if (stage == null) {
      GetIt.instance<FinampUserHelper>().runUserHook(() {
        unawaited(_prepareColdProcessRun());
      });
      if (GetIt.instance<FinampUserHelper>().currentUser == null) {
        recorder.diagnostic("suite-waiting-for-login");
      }
      return;
    }

    if (stage == "cold-start-prepared") {
      await recorder.setSuiteStage("main-running");
      GetIt.instance<FinampUserHelper>().runUserHook(() {
        unawaited(_runAfterAuthentication());
      });
      return;
    }

    if (stage == "awaiting-host-restart") {
      await recorder.setSuiteStage("post-restart-running");
      GetIt.instance<FinampUserHelper>().runUserHook(() {
        unawaited(_runPostRestartPhase());
      });
      return;
    }

    if (stage == "complete") {
      recorder.diagnostic("suite-already-complete");
      recorder.stopHeartbeat();
      return;
    }

    // main-running/post-restart-running means the previous process ended
    // unexpectedly. Recovery records the interrupted active run in main().
    if (stage == "post-restart-running") {
      GetIt.instance<FinampUserHelper>().runUserHook(() {
        unawaited(_runPostRestartPhase());
      });
    } else {
      await recorder.setSuiteStage("main-running");
      GetIt.instance<FinampUserHelper>().runUserHook(() {
        unawaited(_runAfterAuthentication());
      });
    }
  }

  Future<void> _prepareColdProcessRun() async {
    if (_running) return;
    _running = true;

    final recorder = PerformanceBenchmarkService.instance;
    try {
      await WidgetsBinding.instance.endOfFrame;
      await _recoverPendingDownloadCleanup();
      await recorder.waitForStartupQuiescence(
        quietPeriod: const Duration(seconds: 3),
        timeout: const Duration(minutes: 3),
      );
      await recorder.waitForNetworkQuiescence(
        quietPeriod: const Duration(seconds: 3),
        timeout: const Duration(minutes: 3),
      );

      // Prepare a reproducible cold image-cache process while preserving auth,
      // settings and download configuration in the isolated benchmark app.
      await clearPerformanceBenchmarkImageCache();

      // The preparation process is not part of the baseline. Start the host
      // stream fresh so the next process contains only measured startup work.
      await recorder.resetHostStream();
      await recorder.setSuiteStage("cold-start-prepared");
      recorder.diagnostic(
        "host-restart-requested",
        values: {
          "reason": "cold-process-prepared",
          "nextStage": "main-running",
        },
      );
      await recorder.flushHostStream();
    } catch (error) {
      recorder.diagnostic(
        "suite-error",
        values: {
          "phase": "cold-process-preparation",
          "errorType": error.runtimeType.toString(),
        },
      );
      recorder.stopHeartbeat();
      await recorder.flushHostStream();
    } finally {
      _running = false;
    }
  }

  Future<void> _runPostRestartPhase() async {
    if (_running) return;
    _running = true;

    final recorder = PerformanceBenchmarkService.instance;
    try {
      await WidgetsBinding.instance.endOfFrame;
      await _recoverPendingDownloadCleanup();
      recorder.diagnostic("post-restart-phase-start");

      await recorder.waitForStartupQuiescence(
        quietPeriod: const Duration(seconds: 3),
        timeout: const Duration(minutes: 3),
      );
      await recorder.waitForNetworkQuiescence(
        quietPeriod: const Duration(seconds: 3),
        timeout: const Duration(minutes: 3),
      );
      recorder.diagnostic("post-restart-startup-quiescent");

      await _runCollectionFirstPageBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "post-restart-api-cache"},
      );

      for (final tab in const <String>[
        "albums",
        "artists",
        "playlists",
        "tracks",
        "genres",
      ]) {
        await _runUiTabBaseline(
          tab,
          mode: "post-restart-refreshed",
          round: 1,
        );
        await Future<void>.delayed(const Duration(seconds: 3));
        await _runUiTabBaseline(
          tab,
          mode: "post-restart-warm",
          round: 1,
        );
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "post-restart-ui-cache"},
      );

      for (final alias in const <String>[
        "detail-album",
        "detail-artist",
        "bench-100",
      ]) {
        final detailType = alias == "detail-album"
            ? "album"
            : alias == "detail-artist"
            ? "artist"
            : "playlist";
        await _runDetailBaseline(
          targetAlias: alias,
          detailType: detailType,
          mode: "post-restart-refreshed",
          refresh: true,
        );
        await Future<void>.delayed(const Duration(seconds: 2));
        await _runDetailBaseline(
          targetAlias: alias,
          detailType: detailType,
          mode: "post-restart-warm",
          refresh: false,
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "post-restart-detail-cache"},
      );

      await recorder.setSuiteStage("complete");
      recorder.diagnostic(
        "suite-complete",
        values: {"phase": "full-baseline"},
      );
      recorder.stopHeartbeat();
      await recorder.flushHostStream();
    } catch (error) {
      recorder.diagnostic(
        "suite-error",
        values: {
          "phase": "post-restart",
          "errorType": error.runtimeType.toString(),
        },
      );
      recorder.stopHeartbeat();
      await recorder.flushHostStream();
    } finally {
      _running = false;
    }
  }

  Future<void> _runAfterAuthentication() async {
    if (_running) return;
    _running = true;

    final recorder = PerformanceBenchmarkService.instance;
    try {
      await _recoverPendingDownloadCleanup();

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

      await _runDefaultPlaylistMetadataBaseline();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "default-playlist-metadata-sync"},
      );

      await _runDownloadAndOfflineBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "download-offline"},
      );

      await _runImageCacheBaselines();
      recorder.diagnostic(
        "suite-phase-complete",
        values: {"phase": "image-cache"},
      );

      await recorder.setSuiteStage("awaiting-host-restart");
      recorder.diagnostic(
        "host-restart-requested",
        values: {"nextStage": "post-restart-cache"},
      );
      await recorder.flushHostStream();
    } catch (error) {
      recorder.diagnostic(
        "suite-error",
        values: {"errorType": error.runtimeType.toString()},
      );
      recorder.stopHeartbeat();
      await recorder.flushHostStream();
    } finally {
      _running = false;
    }
  }

  Future<void> _recoverPendingDownloadCleanup() async {
    final recorder = PerformanceBenchmarkService.instance;
    final requirement = await recorder.getDownloadCleanupRequirement();
    if (requirement == null) return;

    final alias = requirement["targetAlias"] as String?;
    if (alias == null || alias.isEmpty) {
      await recorder.setDownloadCleanupRequired(
        targetAlias: "",
        required: false,
      );
      return;
    }

    recorder.diagnostic(
      "download-cleanup-recovery-start",
      values: {"targetAlias": alias},
    );

    // Cleanup must be online so queued deletes can finish.
    FinampSetters.setIsOffline(false);
    await Future<void>.delayed(const Duration(seconds: 1));

    final target = await recorder.getTarget(alias);
    if (target == null) {
      recorder.diagnostic(
        "download-cleanup-recovery-target-missing",
        values: {"targetAlias": alias},
      );
      await recorder.setDownloadCleanupRequired(
        targetAlias: alias,
        required: false,
      );
      return;
    }

    final container = GetIt.instance<ProviderContainer>();
    final item = await container.read(
      itemByIdProvider(BaseItemId(target.itemId)).future,
    );
    if (item == null) {
      recorder.diagnostic(
        "download-cleanup-recovery-item-missing",
        values: {"targetAlias": alias},
      );
      await recorder.setDownloadCleanupRequired(
        targetAlias: alias,
        required: false,
      );
      return;
    }

    final downloads = GetIt.instance<DownloadsService>();
    final stub = DownloadStub.fromItem(
      type: DownloadItemType.collection,
      item: item,
    );
    await downloads.deleteDownload(stub: stub);
    await _waitForDownloadRemoved(downloads, stub);
    await recorder.setDownloadCleanupRequired(
      targetAlias: alias,
      required: false,
    );

    recorder.diagnostic(
      "download-cleanup-recovery-complete",
      values: {"targetAlias": alias},
    );
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
    await recorder.waitForImageQuiescence(
      quietPeriod: const Duration(milliseconds: 500),
      timeout: const Duration(minutes: 2),
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
    bool allowPendingDownloadCleanup = false,
  }) async {
    final recorder = PerformanceBenchmarkService.instance;

    await recorder.startRun(
      scenario: "ui-tab-first-rendered-content-$tab",
      variant: PerformanceBenchmarkService.variant,
      mode: mode,
      targetType: tab,
      allowPendingDownloadCleanup: allowPendingDownloadCleanup,
    );
    recorder.metric("round", round);

    try {
      await recorder.runStep(
        name: "ui-tab-open",
        timeout: const Duration(seconds: 120),
        operation: () => recorder.requestUiTab(
          contentType: tab,
          refresh: mode.contains("refreshed"),
          timeout: const Duration(seconds: 115),
        ),
      );
      await recorder.runStep(
        name: "wait-images-quiescent",
        timeout: const Duration(minutes: 2),
        operation: recorder.waitForImageQuiescence,
      );
      await recorder.finishRun();
    } catch (_) {
      // runStep persists the failed/timeout run before rethrowing.
    }
  }

  Future<void> _runSearchBaselines() async {
    final recorder = PerformanceBenchmarkService.instance;
    final api = GetIt.instance<JellyfinApiHelper>();

    const queries = <(String, String, bool)>[
      ("iron-maiden", "Iron Maiden", true),
      ("metallica", "Metallica", true),
      ("kettcar", "Kettcar", true),
      ("broad-m", "m", false),
    ];
    const tabs = <String>["artists", "albums", "tracks"];

    for (final queryEntry in queries) {
      final (queryAlias, query, deriveTargetChain) = queryEntry;

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

      if (deriveTargetChain && artistMatches.length == 1) {
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
          artistType: ArtistType.albumArtist,
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
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
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
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
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
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
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

  Future<void> _runImageCacheBaselines() async {
    final recorder = PerformanceBenchmarkService.instance;

    await clearPerformanceBenchmarkImageCache();
    await Future<void>.delayed(const Duration(seconds: 2));

    await _runUiTabBaseline(
      "albums",
      mode: "image-cache-cold-refreshed",
      round: 1,
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    await _runUiTabBaseline(
      "albums",
      mode: "image-cache-warm-view",
      round: 1,
    );
    await Future<void>.delayed(const Duration(seconds: 3));

    await _runDetailBaseline(
      targetAlias: "detail-album",
      detailType: "album",
      mode: "image-cache-cold-detail",
      refresh: true,
    );
    await Future<void>.delayed(const Duration(seconds: 3));
    await _runDetailBaseline(
      targetAlias: "detail-album",
      detailType: "album",
      mode: "image-cache-warm-detail",
      refresh: false,
    );

    recorder.diagnostic("image-cache-baseline-complete");
    await recorder.waitForNetworkQuiescence(
      quietPeriod: const Duration(seconds: 3),
      timeout: const Duration(minutes: 3),
    );
  }

  Future<void> _runDefaultPlaylistMetadataBaseline() async {
    final recorder = PerformanceBenchmarkService.instance;
    final downloads = GetIt.instance<DownloadsService>();
    final collection = FinampCollection(
      type: FinampCollectionType.allPlaylistsMetadata,
    );
    final stub = DownloadStub.fromFinampCollection(collection);

    await recorder.saveTarget(
      alias: "all-playlists-metadata",
      itemType: "finampCollection",
      itemId: stub.id,
    );

    if (downloads.getStatus(stub, null).isDownloaded) {
      await downloads.deleteDownload(stub: stub);
      await downloads.waitForPerformanceBenchmarkCleanup(stub: stub);
    }

    final locationId =
        FinampSettingsHelper.finampSettings.defaultDownloadLocation ??
        FinampSettingsHelper.finampSettings.internalTrackDir.id;
    final profile = DownloadProfile(
      transcodeCodec: FinampTranscodingCodec.original,
      downloadLocationId: locationId,
    );

    await recorder.startRun(
      scenario: "default-playlist-metadata-sync",
      variant: PerformanceBenchmarkService.variant,
      mode: "isolated-first-run-work",
      targetAlias: "all-playlists-metadata",
      targetType: "finampCollection",
    );

    try {
      await recorder.runStep(
        name: "metadata-sync-plan-and-enqueue",
        timeout: const Duration(minutes: 30),
        operation: () => downloads.addDownload(
          stub: stub,
          transcodeProfile: profile,
        ),
      );

      await recorder.runStep(
        name: "wait-metadata-engine-quiescent",
        timeout: const Duration(hours: 2),
        operation: () => _waitForDownloadEngineQuiescence(downloads),
      );
      await recorder.runStep(
        name: "wait-network-quiescent",
        timeout: const Duration(minutes: 5),
        operation: () => recorder.waitForNetworkQuiescence(
          quietPeriod: const Duration(seconds: 3),
          timeout: const Duration(minutes: 5),
        ),
      );

      await recorder.finishRun();
    } catch (_) {
      rethrow;
    }

    await recorder.startRun(
      scenario: "default-playlist-metadata-cleanup",
      variant: PerformanceBenchmarkService.variant,
      mode: "cleanup",
      targetAlias: "all-playlists-metadata",
      targetType: "finampCollection",
      allowPendingDownloadCleanup: true,
    );
    try {
      await recorder.runStep(
        name: "delete-metadata-sync",
        timeout: const Duration(minutes: 30),
        operation: () => downloads.deleteDownload(stub: stub),
      );
      await recorder.runStep(
        name: "wait-metadata-cleanup",
        timeout: const Duration(minutes: 30),
        operation: () => downloads.waitForPerformanceBenchmarkCleanup(
          stub: stub,
          timeout: const Duration(minutes: 30),
        ),
      );
      await recorder.runStep(
        name: "wait-download-engine-quiescent",
        timeout: const Duration(minutes: 30),
        operation: () => _waitForDownloadEngineQuiescence(downloads),
      );
      await recorder.setDownloadCleanupRequired(
        targetAlias: "all-playlists-metadata",
        required: false,
      );
      await recorder.finishRun();
    } catch (_) {
      rethrow;
    }
  }

  Future<void> _waitForDownloadEngineQuiescence(
    DownloadsService downloads,
  ) async {
    final recorder = PerformanceBenchmarkService.instance;
    var stableSince = Stopwatch()..start();

    while (true) {
      final state = downloads.getPerformanceBenchmarkQueueState();
      final failed = (state["failed"] ?? 0) + (state["syncFailed"] ?? 0);
      if (failed > 0) {
        throw StateError("Benchmark download engine reported failures");
      }

      final active =
          (state["enqueued"] ?? 0) +
          (state["downloading"] ?? 0) +
          (state["pendingSyncTasks"] ?? 0);

      if (active == 0) {
        if (stableSince.elapsed >= const Duration(seconds: 3)) {
          recorder.mark(
            "download-engine-quiescent",
            values: {"quietPeriodMs": stableSince.elapsedMilliseconds},
          );
          return;
        }
      } else {
        stableSince = Stopwatch()..start();
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _runDownloadAndOfflineBaselines() async {
    final recorder = PerformanceBenchmarkService.instance;
    for (final entry in const <(String, int)>[
      ("bench-10", 10),
      ("bench-100", 100),
      ("bench-1000", 1000),
    ]) {
      try {
        await _runDownloadLifecycle(entry.$1, entry.$2);
      } catch (error) {
        recorder.diagnostic(
          "download-target-phase-error",
          values: {
            "targetAlias": entry.$1,
            "errorType": error.runtimeType.toString(),
          },
        );
        // Preserve the rest of the comprehensive baseline whenever cleanup is
        // possible. Cleanup failure itself remains fatal.
        await _recoverPendingDownloadCleanup();
      }
      await Future<void>.delayed(const Duration(seconds: 5));
    }
  }

  Future<void> _runDownloadLifecycle(
    String targetAlias,
    int expectedTracks,
  ) async {
    final recorder = PerformanceBenchmarkService.instance;
    final downloads = GetIt.instance<DownloadsService>();
    final container = GetIt.instance<ProviderContainer>();
    final target = await recorder.getTarget(targetAlias);
    if (target == null) {
      recorder.diagnostic(
        "download-target-missing",
        values: {"targetAlias": targetAlias},
      );
      return;
    }

    final item = await container.read(
      itemByIdProvider(BaseItemId(target.itemId)).future,
    );
    if (item == null) {
      recorder.diagnostic(
        "download-target-unresolvable",
        values: {"targetAlias": targetAlias},
      );
      return;
    }

    final stub = DownloadStub.fromItem(
      type: DownloadItemType.collection,
      item: item,
    );

    // The benchmark owns these three downloads in its isolated app bundle.
    // Always start from a verified clean state.
    final existingStatus = downloads.getStatus(stub, expectedTracks);
    if (existingStatus.isDownloaded) {
      await downloads.deleteDownload(stub: stub);
      await _waitForDownloadRemoved(downloads, stub);
    }

    final internalLocation =
        FinampSettingsHelper.finampSettings.internalTrackDir;
    final profile = DownloadProfile(
      transcodeCodec: FinampTranscodingCodec.original,
      downloadLocationId: internalLocation.id,
    );

    await recorder.startRun(
      scenario: "download-lifecycle",
      variant: PerformanceBenchmarkService.variant,
      mode: "online-download",
      targetAlias: targetAlias,
      targetType: "playlist",
    );

    try {
      recorder.metric("expectedTrackCount", expectedTracks);
      final firstTransfer = recorder.waitForEvent(
        "download-first-transfer-start",
        timeout: const Duration(minutes: 5),
      );
      final firstTrack = recorder.waitForEvent(
        "download-first-track-complete",
        timeout: const Duration(minutes: 10),
      );
      unawaited(firstTransfer.catchError((_) {}));
      unawaited(firstTrack.catchError((_) {}));

      await recorder.runStep(
        name: "download-plan-and-enqueue",
        timeout: const Duration(minutes: 10),
        operation: () => downloads.addDownload(
          stub: stub,
          transcodeProfile: profile,
        ),
      );

      await recorder.runStep(
        name: "wait-first-transfer",
        timeout: const Duration(minutes: 5),
        operation: () => firstTransfer,
      );
      await recorder.runStep(
        name: "wait-first-track-complete",
        timeout: const Duration(minutes: 10),
        operation: () => firstTrack,
      );
      await recorder.runStep(
        name: "wait-full-download",
        timeout: const Duration(hours: 2),
        operation: () => _waitForDownloadComplete(
          downloads,
          stub,
          expectedTracks,
          targetAlias,
        ),
      );

      final bytes = await recorder.runStep(
        name: "measure-downloaded-bytes",
        timeout: const Duration(minutes: 5),
        operation: () => downloads.getFileSize(stub),
      );
      recorder.metric("downloadedBytes", bytes);
      recorder.metric("resolvedTrackCount", expectedTracks);
      await recorder.finishRun();
    } catch (_) {
      rethrow;
    }

    final onlineTracks = await GetIt.instance<JellyfinApiHelper>().getItems(
      parentItem: item,
      includeItemTypes: "Audio",
      recursive: true,
      limit: 1,
    );
    final privateOfflineSearchQuery =
        (onlineTracks?.isNotEmpty ?? false) ? onlineTracks!.first.name : null;

    final previousOffline = FinampSettingsHelper.finampSettings.isOffline;
    try {
      FinampSetters.setIsOffline(true);
      recorder.diagnostic(
        "offline-mode-forced",
        values: {"targetAlias": targetAlias},
      );
      await Future<void>.delayed(const Duration(seconds: 2));

      await _runUiTabBaseline(
        "tracks",
        mode: "local-downloaded-refreshed",
        round: 1,
        allowPendingDownloadCleanup: true,
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      await _runUiTabBaseline(
        "tracks",
        mode: "local-downloaded-warm",
        round: 1,
        allowPendingDownloadCleanup: true,
      );
      await Future<void>.delayed(const Duration(seconds: 2));

      final offlineTracksTab = await recorder.requestUiTab(
        contentType: "tracks",
        refresh: true,
        timeout: const Duration(seconds: 120),
      );
      for (var page = 2; page <= 4; page++) {
        await recorder.startRun(
          scenario: "offline-next-page-tracks",
          variant: PerformanceBenchmarkService.variant,
          mode: "local-downloaded",
          targetAlias: targetAlias,
          targetType: offlineTracksTab,
          allowPendingDownloadCleanup: true,
        );
        recorder.metric("requestedPageOrdinal", page);
        try {
          await recorder.runStep(
            name: "next-page",
            timeout: const Duration(seconds: 120),
            operation: () => recorder.requestNextPage(
              contentType: offlineTracksTab,
              timeout: const Duration(seconds: 115),
            ),
          );
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep persists failures/timeouts.
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }

      if (privateOfflineSearchQuery != null &&
          privateOfflineSearchQuery.trim().isNotEmpty) {
        await recorder.startRun(
          scenario: "offline-search-tracks",
          variant: PerformanceBenchmarkService.variant,
          mode: "local-downloaded-first",
          targetAlias: targetAlias,
          targetType: "tracks",
          allowPendingDownloadCleanup: true,
        );
        try {
          recorder.metric(
            "queryLength",
            privateOfflineSearchQuery.length,
          );
          await recorder.runStep(
            name: "search",
            timeout: const Duration(seconds: 120),
            operation: () => recorder.requestSearch(
              contentType: "tracks",
              queryAlias: "download-target-track",
              query: privateOfflineSearchQuery,
              timeout: const Duration(seconds: 115),
            ),
          );
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep persists failures/timeouts.
        }

        await Future<void>.delayed(const Duration(seconds: 2));
        await recorder.startRun(
          scenario: "offline-search-tracks",
          variant: PerformanceBenchmarkService.variant,
          mode: "local-downloaded-warm",
          targetAlias: targetAlias,
          targetType: "tracks",
          allowPendingDownloadCleanup: true,
        );
        try {
          recorder.metric(
            "queryLength",
            privateOfflineSearchQuery.length,
          );
          await recorder.runStep(
            name: "search",
            timeout: const Duration(seconds: 60),
            operation: () => recorder.requestSearch(
              contentType: "tracks",
              queryAlias: "download-target-track",
              query: privateOfflineSearchQuery,
              timeout: const Duration(seconds: 55),
            ),
          );
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
          );
          await recorder.finishRun();
        } catch (_) {
          // runStep persists failures/timeouts.
        }

        await recorder.requestSearch(
          contentType: "tracks",
          queryAlias: "clear",
          query: "",
          timeout: const Duration(seconds: 120),
        );
        await Future<void>.delayed(const Duration(seconds: 2));
      }

      await _runDetailBaseline(
        targetAlias: targetAlias,
        detailType: "playlist",
        mode: "local-downloaded-refreshed",
        refresh: true,
        allowPendingDownloadCleanup: true,
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      await _runDetailBaseline(
        targetAlias: targetAlias,
        detailType: "playlist",
        mode: "local-downloaded-warm",
        refresh: false,
        allowPendingDownloadCleanup: true,
      );
      await Future<void>.delayed(const Duration(seconds: 2));

      await _runPlaybackBaseline(
        targetAlias: targetAlias,
        playableType: "playlist",
        mode: "local-downloaded-first",
        allowPendingDownloadCleanup: true,
      );
      await GetIt.instance<MusicPlayerBackgroundTask>().pause(
        disableFade: true,
      );
      await Future<void>.delayed(const Duration(seconds: 2));
      await _runPlaybackBaseline(
        targetAlias: targetAlias,
        playableType: "playlist",
        mode: "local-downloaded-warm",
        allowPendingDownloadCleanup: true,
      );
      await GetIt.instance<MusicPlayerBackgroundTask>().pause(
        disableFade: true,
      );
    } finally {
      FinampSetters.setIsOffline(previousOffline);
      recorder.diagnostic(
        "offline-mode-restored",
        values: {
          "targetAlias": targetAlias,
          "restoredOffline": previousOffline,
        },
      );
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    await recorder.startRun(
      scenario: "download-cleanup",
      variant: PerformanceBenchmarkService.variant,
      mode: "cleanup",
      targetAlias: targetAlias,
      targetType: "playlist",
      allowPendingDownloadCleanup: true,
    );
    try {
      await recorder.runStep(
        name: "delete-download",
        timeout: const Duration(minutes: 30),
        operation: () => downloads.deleteDownload(stub: stub),
      );
      await recorder.runStep(
        name: "verify-download-removed",
        timeout: const Duration(minutes: 10),
        operation: () => _waitForDownloadRemoved(downloads, stub),
      );
      final remainingBytes = await downloads.getFileSize(stub);
      recorder.metric("remainingDownloadedBytes", remainingBytes);
      if (remainingBytes != 0) {
        throw StateError("Benchmark download cleanup left local bytes");
      }
      await recorder.setDownloadCleanupRequired(
        targetAlias: targetAlias,
        required: false,
      );
      await recorder.finishRun();
    } catch (_) {
      rethrow;
    }
  }

  Future<void> _waitForDownloadComplete(
    DownloadsService downloads,
    DownloadStub stub,
    int expectedTracks,
    String targetAlias,
  ) async {
    final recorder = PerformanceBenchmarkService.instance;
    var lastComplete = -1;
    var lastTotal = -1;

    while (true) {
      final progress =
          downloads.getPerformanceBenchmarkCollectionProgress(stub);
      final total = progress["totalTracks"] ?? 0;
      final complete = progress["completeTracks"] ?? 0;
      final active = progress["activeTracks"] ?? 0;
      final failed = progress["failedTracks"] ?? 0;

      if (complete != lastComplete || total != lastTotal) {
        recorder.diagnostic(
          "download-progress",
          values: {
            "targetAlias": targetAlias,
            "expectedTracks": expectedTracks,
            "totalTracks": total,
            "completeTracks": complete,
            "activeTracks": active,
            "failedTracks": failed,
          },
        );
        lastComplete = complete;
        lastTotal = total;
      }

      if (failed > 0) {
        throw StateError("Benchmark download contains failed tracks");
      }
      if (total == expectedTracks && complete == expectedTracks) {
        return;
      }

      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _waitForDownloadRemoved(
    DownloadsService downloads,
    DownloadStub stub,
  ) async {
    while (true) {
      final info = await downloads.getCollectionInfo(
        id: BaseItemId(stub.id),
      );
      final status = downloads.getStatus(stub, null);
      if (info == null || !status.isDownloaded) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
  }

  Future<void> _runPlaybackBaselines() async {
    const targets = <(String, String)>[
      ("detail-track", "track"),
      ("detail-album", "album"),
      ("detail-artist", "artist"),
      ("search-track-iron-maiden", "track"),
      ("search-album-iron-maiden", "album"),
      ("search-artist-iron-maiden", "artist"),
      ("search-track-metallica", "track"),
      ("search-album-metallica", "album"),
      ("search-artist-metallica", "artist"),
      ("search-track-kettcar", "track"),
      ("search-album-kettcar", "album"),
      ("search-artist-kettcar", "artist"),
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
      await GetIt.instance<MusicPlayerBackgroundTask>().pause(
        disableFade: true,
      );
      await Future<void>.delayed(const Duration(seconds: 4));
      await _runPlaybackBaseline(
        targetAlias: alias,
        playableType: type,
        mode: "online-warm",
      );
      await GetIt.instance<MusicPlayerBackgroundTask>().pause(
        disableFade: true,
      );
      await Future<void>.delayed(const Duration(seconds: 4));
    }
  }

  Future<void> _runPlaybackBaseline({
    required String targetAlias,
    required String playableType,
    required String mode,
    bool allowPendingDownloadCleanup = false,
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
      allowPendingDownloadCleanup: allowPendingDownloadCleanup,
    );

    try {
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

      // Subscribe immediately before the action that can emit these events.
      // Attach a secondary error consumer so an earlier queue failure does not
      // leave an unobserved timeout behind.
      final playingFuture = recorder.waitForEvent(
        "player-playing",
        timeout: const Duration(minutes: 3),
      );
      final firstPositionFuture = recorder.waitForEvent(
        "player-first-position-advance",
        timeout: const Duration(minutes: 3),
      );
      unawaited(playingFuture.catchError((_) {}));
      unawaited(firstPositionFuture.catchError((_) {}));

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
      await recorder.runStep(
        name: "wait-images-quiescent",
        timeout: const Duration(minutes: 2),
        operation: recorder.waitForImageQuiescence,
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
      ("search-artist-iron-maiden", "artist"),
      ("search-album-iron-maiden", "album"),
      ("search-artist-metallica", "artist"),
      ("search-album-metallica", "album"),
      ("search-artist-kettcar", "artist"),
      ("search-album-kettcar", "album"),
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
    bool allowPendingDownloadCleanup = false,
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
      allowPendingDownloadCleanup: allowPendingDownloadCleanup,
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
            if (detailType == "artist") {
              navigator.push(
                MaterialPageRoute<ArtistScreen>(
                  builder: (_) => ArtistScreen(widgetArtist: item),
                ),
              );
            } else if (detailType == "album" || detailType == "playlist") {
              navigator.push(
                MaterialPageRoute<AlbumScreen>(
                  builder: (_) => AlbumScreen(parent: item),
                ),
              );
            } else {
              throw UnsupportedError(
                "Unsupported benchmark detail type",
              );
            }
          },
        ),
      );
      await recorder.runStep(
        name: "wait-images-quiescent",
        timeout: const Duration(minutes: 2),
        operation: recorder.waitForImageQuiescence,
      );
      await recorder.finishRun();

      if (navigator.canPop()) {
        navigator.pop();
        await WidgetsBinding.instance.endOfFrame;
      }
    } catch (error, stackTrace) {
      if (PerformanceBenchmarkService.instance.activeRun != null) {
        await recorder.failActiveRun(
          result: PerformanceBenchmarkResult.failed,
          error: error,
          stackTrace: stackTrace,
          step: "detail-open",
        );
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
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
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
          await recorder.runStep(
            name: "wait-images-quiescent",
            timeout: const Duration(minutes: 2),
            operation: recorder.waitForImageQuiescence,
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

      for (final request in const <(int, String)>[
        (25, "size-25"),
        (100, "size-100-first"),
        (100, "size-100-warm"),
        (500, "size-500"),
      ]) {
        final (limit, mode) = request;
        await recorder.startRun(
          scenario: "collection-page-$scenarioName",
          variant: PerformanceBenchmarkService.variant,
          mode: mode,
          targetType: itemType,
        );

        try {
          recorder.metric("requestedPageSize", limit);
          final result = await recorder.runStep(
            name: "request",
            timeout: const Duration(minutes: 3),
            operation: () => api.getItemsWithTotalRecordCount(
              includeItemTypes: itemType,
              recursive: true,
              startIndex: 0,
              limit: limit,
            ),
          );

          recorder.metric("pageSize", result.items?.length ?? 0);
          // Never export totalRecordCount: it would reveal private library
          // cardinality. Page-size scaling is sufficient for this baseline.
          await recorder.finishRun();
        } catch (_) {
          // runStep already finalized the failed/timeout run.
        }

        await Future<void>.delayed(const Duration(seconds: 1));
      }
    }
  }
}
