import 'package:flutter/material.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'presentation.dart';

/// Per-device choices, as on the iPhone: appearance, hidden amounts, app lock and Don Bigotes.
class AppPreferences extends ChangeNotifier {
  SharedPreferences? _prefs;
  ThemeMode themeMode = ThemeMode.system;
  bool hideAmounts = false;
  bool lockEnabled = false;
  bool companionEnabled = true;
  Set<String> dismissedNotes = {};

  Future<void> load() async {
    final prefs = _prefs = await SharedPreferences.getInstance();
    themeMode = ThemeMode.values.elementAtOrNull(prefs.getInt('themeMode') ?? 0) ?? ThemeMode.system;
    hideAmounts = prefs.getBool('hideAmounts') ?? false;
    lockEnabled = prefs.getBool('lockEnabled') ?? false;
    companionEnabled = prefs.getBool('companionEnabled') ?? true;
    dismissedNotes = (prefs.getStringList('dismissedNotes') ?? const []).toSet();
    amountsHidden = hideAmounts;
    notifyListeners();
  }

  Future<void> setThemeMode(ThemeMode value) async {
    themeMode = value;
    await _prefs?.setInt('themeMode', value.index);
    notifyListeners();
  }

  Future<void> setHideAmounts(bool value) async {
    hideAmounts = amountsHidden = value;
    await _prefs?.setBool('hideAmounts', value);
    notifyListeners();
  }

  /// Turning the lock on asks to unlock once, so nobody is locked out by a device without a lock.
  Future<bool> setLockEnabled(bool value) async {
    if (value && !await authenticate('Confirma que quieres proteger Doblón con el bloqueo de tu móvil.')) return false;
    lockEnabled = value;
    await _prefs?.setBool('lockEnabled', value);
    notifyListeners();
    return true;
  }

  Future<void> setCompanionEnabled(bool value) async {
    companionEnabled = value;
    await _prefs?.setBool('companionEnabled', value);
    notifyListeners();
  }

  Future<void> dismissNote(String id) async {
    dismissedNotes = {...dismissedNotes, id};
    await _prefs?.setStringList('dismissedNotes', dismissedNotes.toList());
    notifyListeners();
  }

  Future<void> resetNotes() async {
    dismissedNotes = {};
    await _prefs?.remove('dismissedNotes');
    notifyListeners();
  }
}

/// Fingerprint, face or the phone's own PIN or pattern. False when it fails or the device has no lock.
Future<bool> authenticate(String reason) async {
  try {
    final auth = LocalAuthentication();
    if (!await auth.isDeviceSupported()) return false;
    return await auth.authenticate(localizedReason: reason, persistAcrossBackgrounding: true);
  } catch (_) {
    return false;
  }
}
