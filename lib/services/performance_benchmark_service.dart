import 'dart:convert';
import 'dart:io';

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

  void mark(String name, {Map<String, Object?> values = const {}}) {
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

  static final PerformanceBenchmarkService instance = PerformanceBenchmarkService._();

  PerformanceBenchmarkService._();

  Box<String>? _box;
  PerformanceBenchmarkRun? _activeRun;
  int _runSequence = 0;

  PerformanceBenchmarkRun? get activeRun => _activeRun;

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

  PerformanceBenchmarkRun startRun({
    required String scenario,
    required String variant,
    required String mode,
    String? targetAlias,
    String? targetType,
  }) {
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
    return run;
  }

  void mark(String name, {Map<String, Object?> values = const {}}) {
    _activeRun?.mark(name, values: values);
  }

  void metric(String name, Object? value) {
    _activeRun?.setMetric(name, value);
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

    final box = await _getBox();
    await box.put("$_runKeyPrefix${run.id}", jsonEncode(run.toJson()));
    _activeRun = null;
    return run;
  }

  void cancelRun() {
    final run = _activeRun;
    if (run == null) return;
    run.stopwatch.stop();
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
      "schemaVersion": 1,
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
