import 'dart:async';

import 'package:finamp/models/jellyfin_models.dart';
import 'package:finamp/services/finamp_user_helper.dart';
import 'package:finamp/services/jellyfin_api_helper.dart';
import 'package:finamp/services/performance_benchmark_service.dart';
import 'package:flutter/widgets.dart';
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
      // Keep benchmark work out of the authentication transition itself.
      await WidgetsBinding.instance.endOfFrame;
      await Future<void>.delayed(const Duration(seconds: 2));

      recorder.diagnostic("suite-authenticated");
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
      recorder.diagnostic(
        "suite-complete",
        values: {"phase": "authenticated-api-baseline"},
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
