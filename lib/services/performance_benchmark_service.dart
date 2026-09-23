import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:hive_ce/hive.dart';
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
  static const _boxName = "PerformanceBenchmark";
  static const _targetKeyPrefix = "target:";
  static const _runKeyPrefix = "run:";
  static const _activeRunKey = "active-run";
  static const _cleanupRequiredKey = "cleanup-required";

  static final PerformanceBenchmarkService instance = PerformanceBenchmarkService._();

  PerformanceBenchmarkService._();

  Box<String>? _box;
  PerformanceBenchmarkRun? _activeRun;
  int _runSequence = 0;

  PerformanceBenchmarkRun? get activeRun => _activeRun;
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

    recovered["finished"] = true;
    recovered["result"] = PerformanceBenchmarkResult.unexpectedExit.name;
    recovered["recoveredAt"] = DateTime.now().toUtc().toIso8601String();
    recovered["failure"] = {
      "type": "unexpected-exit",
      "message": "Previous benchmark process ended without completing the active run.",
      "lastStep": recovered["lastStep"],
    };

    final id = recovered["id"] as String;
    await box.put("$_runKeyPrefix$id", jsonEncode(recovered));
    await box.delete(_activeRunKey);
    return recovered;
  }

  Future<PerformanceBenchmarkRun> startRun({
    required String scenario,
    required String variant,
    required String mode,
    String? targetAlias,
    String? targetType,
  }) async {
    if (_activeRun != null) {
      throw StateError("A benchmark run is already active");
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
    return run;
  }

  void mark(String name, {Map<String, Object?> values = const {}}) {
    final run = _activeRun;
    if (run == null) return;
    run.mark(name, values: values);
    unawaited(_persistActiveRun());
  }

  void metric(String name, Object? value) {
    final run = _activeRun;
    if (run == null) return;
    run.setMetric(name, value);
    unawaited(_persistActiveRun());
  }

  Future<void> _persistActiveRun() async {
    final run = _activeRun;
    if (run == null) return;
    final box = await _getBox();
    await box.put(_activeRunKey, jsonEncode(run.toJson()));
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

    run.failure = {
      "type": "dart-error",
      "source": source,
      "errorType": error.runtimeType.toString(),
      "message": _sanitizeError(error.toString()),
      "stackTrace": _sanitizeStack(stackTrace.toString()),
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
    run.failure = {
      "type": result.name,
      "errorType": error.runtimeType.toString(),
      "message": _sanitizeError(error.toString()),
      "stackTrace": _sanitizeStack(stackTrace.toString()),
      "lastStep": step ?? run.lastStep,
    };
    run.mark("run-failed", values: {"result": result.name});
    run.stopwatch.stop();
    run.finished = true;

    final box = await _getBox();
    await box.put("$_runKeyPrefix${run.id}", jsonEncode(run.toJson()));
    await box.delete(_activeRunKey);
    _activeRun = null;
  }

  String _sanitizeError(String value) {
    final oneLine = value.replaceAll(RegExp(r'[\r\n]+'), ' ');
    return oneLine.length <= 1000 ? oneLine : oneLine.substring(0, 1000);
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
    run.result = PerformanceBenchmarkResult.success;

    final box = await _getBox();
    await box.put("$_runKeyPrefix${run.id}", jsonEncode(run.toJson()));
    await box.delete(_activeRunKey);
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
