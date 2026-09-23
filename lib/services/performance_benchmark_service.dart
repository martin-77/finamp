import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:finamp/services/censored_log.dart';
import 'package:hive_ce/hive.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as path_helper;
import 'package:path_provider/path_provider.dart';

class PerformanceBenchmarkTarget {
  const PerformanceBenchmarkTarget({
    required this.alias,
    required this.itemType,
    required this.itemId,
  });

  final String alias;
  final String itemType;

  /// Device-local only. Never emitted in benchmark exports.
  final String itemId;

  Map<String, dynamic> toLocalJson() => {
    "alias": alias,
    "itemType": itemType,
    "itemId": itemId,
  };

  factory PerformanceBenchmarkTarget.fromLocalJson(Map<String, dynamic> json) {
    return PerformanceBenchmarkTarget(
      alias: json["alias"] as String,
      itemType: json["itemType"] as String,
      itemId: json["itemId"] as String,
    );
  }
}

class PerformanceBenchmarkJumpCommand {
  PerformanceBenchmarkJumpCommand({
    required this.contentType,
    required this.letter,
  });

  final String contentType;
  final String letter;
  final Completer<void> _completer = Completer<void>();

  Future<void> get completed => _completer.future;

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

class PerformanceBenchmarkTabCommand {
  PerformanceBenchmarkTabCommand({
    required this.contentType,
    required this.refresh,
  });

  final String contentType;
  final bool refresh;
  final Completer<void> _completer = Completer<void>();
  bool selected = false;
  String? selectedContentType;

  Future<void> get completed => _completer.future;

  void markSelected(String contentType) {
    selected = true;
    selectedContentType = contentType;
  }

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

class PerformanceBenchmarkDetailCommand {
  PerformanceBenchmarkDetailCommand({
    required this.targetAlias,
    required this.targetType,
    required this.itemId,
    required this.refresh,
  });

  final String targetAlias;
  final String targetType;
  final String itemId;
  final bool refresh;
  final Completer<void> _completer = Completer<void>();

  Future<void> get completed => _completer.future;

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

class PerformanceBenchmarkPageCommand {
  PerformanceBenchmarkPageCommand({required this.contentType});

  final String contentType;
  final Completer<void> _completer = Completer<void>();

  Future<void> get completed => _completer.future;

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

class PerformanceBenchmarkSearchCommand {
  PerformanceBenchmarkSearchCommand({
    required this.contentType,
    required this.queryAlias,
    required this.query,
  });

  final String contentType;
  final String queryAlias;

  /// Device-local benchmark input. Never emit this string.
  final String query;

  String? selectedContentType;
  final Completer<void> _completer = Completer<void>();

  Future<void> get completed => _completer.future;

  void markSelected(String contentType) {
    selectedContentType = contentType;
  }

  void complete() {
    if (!_completer.isCompleted) _completer.complete();
  }

  void completeError(Object error, StackTrace stackTrace) {
    if (!_completer.isCompleted) _completer.completeError(error, stackTrace);
  }
}

class PerformanceBenchmarkEvent {
  const PerformanceBenchmarkEvent({
    required this.name,
    required this.elapsedMicros,
    this.values = const {},
  });

  final String name;
  final int elapsedMicros;
  final Map<String, Object?> values;

  Map<String, dynamic> toJson() => {
    "name": name,
    "elapsedMicros": elapsedMicros,
    if (values.isNotEmpty) "values": values,
  };
}

enum PerformanceBenchmarkResult {
  running,
  success,
  failed,
  timeout,
  unexpectedExit,
  cancelled,
}

class PerformanceBenchmarkRun {
  PerformanceBenchmarkRun({
    required this.id,
    required this.scenario,
    required this.variant,
    required this.mode,
    required this.stopwatch,
    required this.startedAt,
    this.targetAlias,
    this.targetType,
  });

  final String id;
  final String scenario;
  final String variant;
  final String mode;
  final String? targetAlias;
  final String? targetType;
  final Stopwatch stopwatch;
  final DateTime startedAt;
  final List<PerformanceBenchmarkEvent> events = [];
  final Map<String, Object?> metrics = {};
  bool finished = false;
  PerformanceBenchmarkResult result = PerformanceBenchmarkResult.running;
  String? lastStep;
  Map<String, Object?>? failure;

  void mark(String name, {Map<String, Object?> values = const {}}) {
    lastStep = name;
    events.add(
      PerformanceBenchmarkEvent(
        name: name,
        elapsedMicros: stopwatch.elapsedMicroseconds,
        values: values,
      ),
    );
  }

  void setMetric(String name, Object? value) {
    metrics[name] = value;
  }

  Map<String, dynamic> toJson() => {
    "id": id,
    "scenario": scenario,
    "variant": variant,
    "mode": mode,
    if (targetAlias != null) "targetAlias": targetAlias,
    if (targetType != null) "targetType": targetType,
    "startedAt": startedAt.toUtc().toIso8601String(),
    "durationMicros": stopwatch.elapsedMicroseconds,
    "events": events.map((event) => event.toJson()).toList(),
    "metrics": metrics,
    "finished": finished,
    "result": result.name,
    if (lastStep != null) "lastStep": lastStep,
    if (failure != null) "failure": failure,
  };
}

/// Test-only performance recorder.
///
/// Timings use one monotonic [Stopwatch] per run. Target IDs are stored only in
/// a device-local Hive box and are deliberately excluded from exported data.
class PerformanceBenchmarkService {
  static const bool enabled = bool.fromEnvironment(
    "FINAMP_PERFORMANCE_BENCHMARK",
    defaultValue: false,
  );
  static const String variant = String.fromEnvironment(
    "FINAMP_BENCH_VARIANT",
    defaultValue: "unknown",
  );

  static final _logger = Logger("PerformanceBenchmark");
  static const _boxName = "PerformanceBenchmark";
  static const _targetKeyPrefix = "target:";
  static const _runKeyPrefix = "run:";
  static const _activeRunKey = "active-run";
  static const _cleanupRequiredKey = "cleanup-required";
  static String get _hostStreamFileName => "finamp-benchmark-stream-$variant.jsonl";

  static final PerformanceBenchmarkService instance = PerformanceBenchmarkService._();

  PerformanceBenchmarkService._();

  Box<String>? _box;
  File? _hostStreamFile;
  Future<void> _hostWriteChain = Future<void>.value();
  PerformanceBenchmarkRun? _activeRun;
  PerformanceBenchmarkTabCommand? _activeTabCommand;
  PerformanceBenchmarkDetailCommand? _activeDetailCommand;
  PerformanceBenchmarkSearchCommand? _activeSearchCommand;
  int _runSequence = 0;
  int _startupPendingTasks = 0;
  int _startupGeneration = 0;
  final StreamController<int> _startupTaskController =
      StreamController<int>.broadcast();
  final StreamController<PerformanceBenchmarkJumpCommand> _jumpController =
      StreamController<PerformanceBenchmarkJumpCommand>.broadcast();
  final StreamController<PerformanceBenchmarkTabCommand> _tabController =
      StreamController<PerformanceBenchmarkTabCommand>.broadcast();
  final StreamController<String> _eventNameController =
      StreamController<String>.broadcast();
  final StreamController<PerformanceBenchmarkPageCommand> _pageController =
      StreamController<PerformanceBenchmarkPageCommand>.broadcast();
  final StreamController<PerformanceBenchmarkSearchCommand> _searchController =
      StreamController<PerformanceBenchmarkSearchCommand>.broadcast();

  Stream<PerformanceBenchmarkJumpCommand> get jumpCommands =>
      _jumpController.stream;
  Stream<PerformanceBenchmarkTabCommand> get tabCommands =>
      _tabController.stream;
  Stream<PerformanceBenchmarkPageCommand> get pageCommands =>
      _pageController.stream;
  Stream<PerformanceBenchmarkSearchCommand> get searchCommands =>
      _searchController.stream;

  PerformanceBenchmarkRun? get activeRun => _activeRun;
  PerformanceBenchmarkTabCommand? get activeTabCommand => _activeTabCommand;
  PerformanceBenchmarkDetailCommand? get activeDetailCommand =>
      _activeDetailCommand;
  PerformanceBenchmarkSearchCommand? get activeSearchCommand =>
      _activeSearchCommand;
  bool get hasActiveRun => _activeRun != null;

  Future<Box<String>> _getBox() async {
    final existing = _box;
    if (existing != null && existing.isOpen) return existing;

    final directory = (Platform.isAndroid || Platform.isIOS)
        ? await getApplicationDocumentsDirectory()
        : await getApplicationSupportDirectory();

    return _box = await Hive.openBox<String>(_boxName, path: directory.path);
  }

  Future<void> saveTarget({
    required String alias,
    required String itemType,
    required String itemId,
  }) async {
    final box = await _getBox();
    final target = PerformanceBenchmarkTarget(
      alias: alias,
      itemType: itemType,
      itemId: itemId,
    );
    await box.put("$_targetKeyPrefix$alias", jsonEncode(target.toLocalJson()));
  }

  Future<PerformanceBenchmarkTarget?> getTarget(String alias) async {
    final box = await _getBox();
    final encoded = box.get("$_targetKeyPrefix$alias");
    if (encoded == null) return null;

    return PerformanceBenchmarkTarget.fromLocalJson(
      jsonDecode(encoded) as Map<String, dynamic>,
    );
  }

  Future<List<PerformanceBenchmarkTarget>> getTargets() async {
    final box = await _getBox();
    return box.keys
        .whereType<String>()
        .where((key) => key.startsWith(_targetKeyPrefix))
        .map(box.get)
        .whereType<String>()
        .map((encoded) => PerformanceBenchmarkTarget.fromLocalJson(
              jsonDecode(encoded) as Map<String, dynamic>,
            ))
        .toList();
  }

  Future<Map<String, dynamic>?> recoverInterruptedRun() async {
    final box = await _getBox();
    final encoded = box.get(_activeRunKey);
    if (encoded == null) return null;

    final recovered = jsonDecode(encoded) as Map<String, dynamic>;
    if (recovered["finished"] == true) {
      await box.delete(_activeRunKey);
      return null;
    }

    final capturedFailure = recovered["failure"];
    recovered["finished"] = true;
    recovered["result"] = PerformanceBenchmarkResult.unexpectedExit.name;
    recovered["recoveredAt"] = DateTime.now().toUtc().toIso8601String();
    recovered["failure"] = {
      "type": "unexpected-exit",
      "message": "Previous benchmark process ended without completing the active run.",
      "lastStep": recovered["lastStep"],
      if (capturedFailure != null) "capturedFailure": capturedFailure,
    };

    final id = recovered["id"] as String;
    await box.put("$_runKeyPrefix$id", jsonEncode(recovered));
    await box.delete(_activeRunKey);
    _emitHostRecord("run-recovered", {"run": recovered});
    _logger.warning(
      "BENCH RUN $id recovered as unexpected-exit "
      "lastStep=${recovered["lastStep"]}",
    );
    return recovered;
  }

  Future<PerformanceBenchmarkRun> startRun({
    required String scenario,
    required String variant,
    required String mode,
    String? targetAlias,
    String? targetType,
    bool allowPendingDownloadCleanup = false,
  }) async {
    if (_activeRun != null) {
      throw StateError("A benchmark run is already active");
    }
    if (!allowPendingDownloadCleanup &&
        await getDownloadCleanupRequirement() != null) {
      throw StateError(
        "A benchmark download still requires cleanup before another run can start",
      );
    }

    final now = DateTime.now();
    final stopwatch = Stopwatch()..start();
    final run = PerformanceBenchmarkRun(
      id: "${now.toUtc().millisecondsSinceEpoch}-${++_runSequence}",
      scenario: scenario,
      variant: variant,
      mode: mode,
      targetAlias: targetAlias,
      targetType: targetType,
      stopwatch: stopwatch,
      startedAt: now,
    );
    run.mark("run-start");
    _activeRun = run;
    await _persistActiveRun();
    _logger.info(
      "BENCH RUN ${run.id} scenario=${run.scenario} "
      "variant=${run.variant} mode=${run.mode}",
    );
    _emitHostRecord("run-start", {
      "run": run.toJson(),
    });
    return run;
  }

  void mark(String name, {Map<String, Object?> values = const {}}) {
    final run = _activeRun;
    if (run == null) return;
    run.mark(name, values: values);
    _eventNameController.add(name);
    _emitHostRecord("event", {
      "runId": run.id,
      "scenario": run.scenario,
      "variant": run.variant,
      "mode": run.mode,
      "event": run.events.last.toJson(),
    });
    unawaited(_persistActiveRun());
  }

  void metric(String name, Object? value) {
    final run = _activeRun;
    if (run == null) return;
    run.setMetric(name, value);
    _emitHostRecord("metric", {
      "runId": run.id,
      "scenario": run.scenario,
      "variant": run.variant,
      "mode": run.mode,
      "name": name,
      "value": value,
    });
    unawaited(_persistActiveRun());
  }

  void incrementMetric(String name, [int amount = 1]) {
    final run = _activeRun;
    if (run == null) return;
    final current = run.metrics[name];
    final value = (current is int ? current : 0) + amount;
    run.setMetric(name, value);
    _emitHostRecord("metric", {
      "runId": run.id,
      "scenario": run.scenario,
      "variant": run.variant,
      "mode": run.mode,
      "name": name,
      "value": value,
    });
    unawaited(_persistActiveRun());
  }

  Future<T> runStartupTask<T>(
    String taskName,
    Future<T> Function() operation,
  ) async {
    if (!enabled) return operation();

    _startupPendingTasks++;
    _startupGeneration++;
    _startupTaskController.add(_startupPendingTasks);
    diagnostic(
      "startup-task-start",
      values: {
        "task": taskName,
        "pendingTasks": _startupPendingTasks,
      },
    );

    final stopwatch = Stopwatch()..start();
    try {
      return await operation();
    } finally {
      stopwatch.stop();
      _startupPendingTasks--;
      _startupGeneration++;
      _startupTaskController.add(_startupPendingTasks);
      diagnostic(
        "startup-task-complete",
        values: {
          "task": taskName,
          "pendingTasks": _startupPendingTasks,
          "durationMs": stopwatch.elapsedMicroseconds / 1000.0,
        },
      );
    }
  }

  Future<void> waitForStartupQuiescence({
    Duration quietPeriod = const Duration(seconds: 3),
    Duration timeout = const Duration(minutes: 3),
  }) async {
    if (!enabled) return;

    final overall = Stopwatch()..start();
    diagnostic(
      "startup-quiescence-wait-start",
      values: {
        "pendingTasks": _startupPendingTasks,
        "quietPeriodMs": quietPeriod.inMilliseconds,
      },
    );

    while (overall.elapsed < timeout) {
      if (_startupPendingTasks != 0) {
        await _startupTaskController.stream
            .firstWhere((pending) => pending == 0)
            .timeout(timeout - overall.elapsed);
      }

      final generationAtZero = _startupGeneration;
      await Future<void>.delayed(quietPeriod);

      if (_startupPendingTasks == 0 &&
          _startupGeneration == generationAtZero) {
        overall.stop();
        diagnostic(
          "startup-quiescent",
          values: {
            "waitDurationMs": overall.elapsedMicroseconds / 1000.0,
          },
        );
        return;
      }
    }

    throw TimeoutException(
      "Startup tasks did not become quiescent",
      timeout,
    );
  }

  Future<void> waitForEvent(
    String name, {
    Duration timeout = const Duration(seconds: 60),
  }) {
    return _eventNameController.stream
        .firstWhere((eventName) => eventName == name)
        .timeout(timeout);
  }

  Future<String> requestUiTab({
    required String contentType,
    required bool refresh,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    if (_activeTabCommand != null) {
      throw StateError("Another benchmark UI tab command is already active");
    }
    final command = PerformanceBenchmarkTabCommand(
      contentType: contentType,
      refresh: refresh,
    );
    _activeTabCommand = command;
    mark(
      "ui-tab-requested",
      values: {
        "contentType": contentType,
        "refresh": refresh,
      },
    );
    _tabController.add(command);
    try {
      await command.completed.timeout(timeout);
      final selectedContentType = command.selectedContentType;
      if (selectedContentType == null) {
        throw StateError("Benchmark tab completed without selected content type");
      }
      return selectedContentType;
    } finally {
      if (identical(_activeTabCommand, command)) {
        _activeTabCommand = null;
      }
    }
  }

  Future<void> requestDetail({
    required String targetAlias,
    required String targetType,
    required String itemId,
    required bool refresh,
    required void Function() open,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (_activeDetailCommand != null) {
      throw StateError("Another benchmark detail command is already active");
    }
    final command = PerformanceBenchmarkDetailCommand(
      targetAlias: targetAlias,
      targetType: targetType,
      itemId: itemId,
      refresh: refresh,
    );
    _activeDetailCommand = command;
    mark(
      "detail-open-requested",
      values: {
        "targetAlias": targetAlias,
        "targetType": targetType,
        "refresh": refresh,
      },
    );
    open();
    try {
      await command.completed.timeout(timeout);
    } finally {
      if (identical(_activeDetailCommand, command)) {
        _activeDetailCommand = null;
      }
    }
  }

  Future<String> requestSearch({
    required String contentType,
    required String queryAlias,
    required String query,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    if (_activeSearchCommand != null) {
      throw StateError("Another benchmark search command is already active");
    }

    final command = PerformanceBenchmarkSearchCommand(
      contentType: contentType,
      queryAlias: queryAlias,
      query: query,
    );
    _activeSearchCommand = command;
    mark(
      "search-requested",
      values: {
        "contentType": contentType,
        "queryAlias": queryAlias,
        "queryLength": query.length,
      },
    );
    _searchController.add(command);

    try {
      await command.completed.timeout(timeout);
      final selected = command.selectedContentType;
      if (selected == null) {
        throw StateError("Search completed without selected content type");
      }
      return selected;
    } finally {
      if (identical(_activeSearchCommand, command)) {
        _activeSearchCommand = null;
      }
    }
  }

  Future<void> requestNextPage({
    required String contentType,
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final command = PerformanceBenchmarkPageCommand(contentType: contentType);
    mark(
      "page-requested",
      values: {"contentType": contentType},
    );
    _pageController.add(command);
    await command.completed.timeout(timeout);
  }

  Future<void> requestAlphabetJump({
    required String contentType,
    required String letter,
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final command = PerformanceBenchmarkJumpCommand(
      contentType: contentType,
      letter: letter,
    );
    mark(
      "alphabet-jump-requested",
      values: {"contentType": contentType, "letter": letter},
    );
    _jumpController.add(command);
    await command.completed.timeout(timeout);
  }

  Future<void> _persistActiveRun() async {
    final run = _activeRun;
    if (run == null) return;
    final box = await _getBox();
    await box.put(_activeRunKey, jsonEncode(run.toJson()));
  }

  void diagnostic(
    String name, {
    Map<String, Object?> values = const {},
  }) {
    if (!enabled) return;
    _emitHostRecord("diagnostic", {
      "name": name,
      if (values.isNotEmpty) "values": values,
    });
  }

  void _emitHostRecord(
    String type,
    Map<String, Object?> payload,
  ) {
    final record = <String, Object?>{
      "type": type,
      "emittedAt": DateTime.now().toUtc().toIso8601String(),
      ...payload,
    };
    final encoded = jsonEncode(record);
    // Intentionally machine-readable for the macOS host-side benchmark collector.
    // Do not include media names, item ids, URLs, tokens or user identifiers.
    // ignore: avoid_print
    print("BENCH_JSON $encoded");
    if (enabled) {
      _hostWriteChain = _hostWriteChain.then((_) => _appendHostRecord(encoded));
    }
  }

  Future<void> _appendHostRecord(String encoded) async {
    final file = _hostStreamFile ??= File(
      path_helper.join(
        (await getApplicationDocumentsDirectory()).path,
        _hostStreamFileName,
      ),
    );
    await file.writeAsString(
      "$encoded\n",
      mode: FileMode.append,
      flush: true,
    );
  }

  Future<void> resetHostStream() async {
    if (!enabled) return;
    _hostWriteChain = _hostWriteChain.then((_) async {
      final file = _hostStreamFile ??= File(
        path_helper.join(
          (await getApplicationDocumentsDirectory()).path,
          _hostStreamFileName,
        ),
      );
      if (await file.exists()) {
        await file.delete();
      }
    });
    await _hostWriteChain;
  }

  Future<void> flushHostStream() async {
    await _hostWriteChain;
  }

  Future<T> runStep<T>({
    required String name,
    required Future<T> Function() operation,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    mark("$name-start");
    try {
      final result = await operation().timeout(timeout);
      mark("$name-end");
      return result;
    } on TimeoutException catch (error, stackTrace) {
      await failActiveRun(
        result: PerformanceBenchmarkResult.timeout,
        error: error,
        stackTrace: stackTrace,
        step: name,
      );
      rethrow;
    } catch (error, stackTrace) {
      await failActiveRun(
        result: PerformanceBenchmarkResult.failed,
        error: error,
        stackTrace: stackTrace,
        step: name,
      );
      rethrow;
    }
  }

  Future<void> recordCrash(
    Object error,
    StackTrace stackTrace, {
    required String source,
  }) async {
    final run = _activeRun;
    if (run == null) return;

    final censored = LogRecord(
      Level.SEVERE,
      error.toString(),
      "PerformanceBenchmark",
      error,
      stackTrace,
    ).censoredMessage;
    run.failure = {
      "type": "dart-error",
      "source": source,
      "errorType": error.runtimeType.toString(),
      "diagnostic": _sanitizeStack(censored),
      "lastStep": run.lastStep,
    };
    run.mark("uncaught-error", values: {"source": source});
    await _persistActiveRun();
  }

  Future<void> failActiveRun({
    required PerformanceBenchmarkResult result,
    required Object error,
    required StackTrace stackTrace,
    String? step,
  }) async {
    final run = _activeRun;
    if (run == null) return;

    run.result = result;
    final censored = LogRecord(
      Level.SEVERE,
      error.toString(),
      "PerformanceBenchmark",
      error,
      stackTrace,
    ).censoredMessage;
    run.failure = {
      "type": result.name,
      "errorType": error.runtimeType.toString(),
      "diagnostic": _sanitizeStack(censored),
      "lastStep": step ?? run.lastStep,
    };
    run.mark("run-failed", values: {"result": result.name});
    run.stopwatch.stop();
    run.finished = true;

    final box = await _getBox();
    await box.put("$_runKeyPrefix${run.id}", jsonEncode(run.toJson()));
    await box.delete(_activeRunKey);
    _emitHostRecord("run-end", {"run": run.toJson()});
    _activeRun = null;
  }

  String _sanitizeStack(String value) {
    return value.length <= 12000 ? value : value.substring(0, 12000);
  }

  Future<void> setDownloadCleanupRequired({
    required String targetAlias,
    bool required = true,
  }) async {
    final box = await _getBox();
    if (required) {
      await box.put(
        _cleanupRequiredKey,
        jsonEncode({
          "targetAlias": targetAlias,
          "createdAt": DateTime.now().toUtc().toIso8601String(),
        }),
      );
    } else {
      await box.delete(_cleanupRequiredKey);
    }
  }

  Future<Map<String, dynamic>?> getDownloadCleanupRequirement() async {
    final box = await _getBox();
    final encoded = box.get(_cleanupRequiredKey);
    return encoded == null
        ? null
        : jsonDecode(encoded) as Map<String, dynamic>;
  }

  Future<bool> isDownloadCleanupTarget(String itemId) async {
    final requirement = await getDownloadCleanupRequirement();
    if (requirement == null) return false;
    final alias = requirement["targetAlias"] as String?;
    if (alias == null) return false;
    final target = await getTarget(alias);
    return target?.itemId == itemId;
  }

  Future<void> markDownloadCleanupStarted() async {
    mark("download-cleanup-start");
    await _persistActiveRun();
  }

  Future<void> markDownloadCleanupCompleted() async {
    mark("download-cleanup-complete");
    await setDownloadCleanupRequired(targetAlias: "", required: false);
    await _persistActiveRun();
  }

  Future<PerformanceBenchmarkRun> finishRun({
    Map<String, Object?> metrics = const {},
  }) async {
    final run = _activeRun;
    if (run == null) {
      throw StateError("No benchmark run is active");
    }

    for (final entry in metrics.entries) {
      run.setMetric(entry.key, entry.value);
    }
    run.mark("run-end");
    run.stopwatch.stop();
    run.finished = true;
    run.result = run.failure == null
        ? PerformanceBenchmarkResult.success
        : PerformanceBenchmarkResult.failed;

    final box = await _getBox();
    await box.put("$_runKeyPrefix${run.id}", jsonEncode(run.toJson()));
    await box.delete(_activeRunKey);
    _emitHostRecord("run-end", {"run": run.toJson()});
    _activeRun = null;
    return run;
  }

  Future<void> cancelRun() async {
    final run = _activeRun;
    if (run == null) return;
    run.mark("run-cancelled");
    run.stopwatch.stop();
    run.finished = true;
    run.result = PerformanceBenchmarkResult.cancelled;
    final box = await _getBox();
    await box.put("$_runKeyPrefix${run.id}", jsonEncode(run.toJson()));
    await box.delete(_activeRunKey);
    _activeRun = null;
  }

  Future<List<Map<String, dynamic>>> getRuns() async {
    final box = await _getBox();
    final runs = box.keys
        .whereType<String>()
        .where((key) => key.startsWith(_runKeyPrefix))
        .map(box.get)
        .whereType<String>()
        .map((encoded) => jsonDecode(encoded) as Map<String, dynamic>)
        .toList();

    runs.sort(
      (a, b) => (a["startedAt"] as String).compareTo(b["startedAt"] as String),
    );
    return runs;
  }

  Future<void> clearRuns() async {
    final box = await _getBox();
    await box.deleteAll(
      box.keys
          .whereType<String>()
          .where((key) => key.startsWith(_runKeyPrefix)),
    );
  }

  Future<void> clearTargets() async {
    final box = await _getBox();
    await box.deleteAll(
      box.keys
          .whereType<String>()
          .where((key) => key.startsWith(_targetKeyPrefix)),
    );
  }

  Future<Uint8List> exportBytes() async {
    final runs = await getRuns();
    final export = {
      "schemaVersion": 2,
      "generatedAt": DateTime.now().toUtc().toIso8601String(),
      "runs": runs,
    };
    return Uint8List.fromList(
      utf8.encode(const JsonEncoder.withIndent("  ").convert(export)),
    );
  }

  Future<void> export() async {
    final fileName =
        "finamp-performance-benchmark-${DateTime.now().toIso8601String().replaceAll(RegExp(r'[/?<>:*|.\\"]'), "-")}.json";

    await FilePicker.saveFile(
      fileName: fileName,
      initialDirectory:
          (await getApplicationDocumentsDirectory()).path +
          path_helper.separator,
      bytes: await exportBytes(),
    );
  }
}
