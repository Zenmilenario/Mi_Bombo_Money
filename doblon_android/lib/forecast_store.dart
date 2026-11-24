import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'forecast.dart';

/// The forecast assumptions and the saved simulations, on this device and per person, apart from the finances: they
/// never travel in the cloud document, never become movements and never reach the learning.
class ForecastStore extends ChangeNotifier {
  ForecastStore._(this._file);
  final File _file;
  ForecastSettings settings = const ForecastSettings();
  List<Scenario> scenarios = [];
  Future<void> _writes = Future.value();

  static File fileFor(Directory directory, String user) => File('${directory.path}${Platform.pathSeparator}forecast-$user.json');

  static Future<ForecastStore> open(Directory directory, String user) async {
    final store = ForecastStore._(fileFor(directory, user));
    try {
      final json = Map<String, dynamic>.from(jsonDecode(await store._file.readAsString()) as Map);
      store.settings = ForecastSettings.fromJson(Map<String, dynamic>.from((json['settings'] as Map?) ?? const {}));
      store.scenarios = [
        for (final raw in (json['scenarios'] as List?) ?? const [])
          if (raw is Map) Scenario.fromJson(Map<String, dynamic>.from(raw))
      ].whereType<Scenario>().toList();
    } catch (_) {/* Nothing saved yet, or unreadable: the defaults. */}
    return store;
  }

  Future<void> saveSettings(ForecastSettings value) {
    settings = value;
    return _save();
  }

  Future<void> saveScenario(Scenario scenario) {
    final index = scenarios.indexWhere((s) => s.id == scenario.id);
    scenarios = [...scenarios];
    if (index < 0) {
      scenarios.add(scenario);
    } else {
      scenarios[index] = scenario;
    }
    return _save();
  }

  Future<void> deleteScenario(String id) {
    scenarios = [for (final s in scenarios) if (s.id != id) s];
    return _save();
  }

  /// Written to a temporary file and renamed, one write at a time.
  Future<void> _save() {
    notifyListeners();
    final text = jsonEncode({'settings': settings.toJson(), 'scenarios': [for (final s in scenarios) s.toJson()]});
    final task = _writes.then((_) async {
      final temporary = File('${_file.path}.tmp');
      await temporary.writeAsString(text, flush: true);
      await temporary.rename(_file.path);
    });
    _writes = task.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return task;
  }
}
