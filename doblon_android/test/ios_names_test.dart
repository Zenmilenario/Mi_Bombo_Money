// Installing the unsigned IPA with a free Apple account (iLoader, AltStore…) registers an App ID named after the app,
// and Apple only accepts ASCII letters, digits and spaces: «Doblón» failed with "invalid value for appIdName".
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the names the iPhone app is registered with have no accents or symbols', () {
    final plist = File('ios/Runner/Info.plist').readAsStringSync();
    for (final key in ['CFBundleDisplayName', 'CFBundleName']) {
      final value = RegExp('<key>$key</key>\\s*<string>([^<]*)</string>').firstMatch(plist)?.group(1);
      expect(value, isNotNull, reason: key);
      expect(RegExp(r'^[A-Za-z0-9 ]+$').hasMatch(value!), isTrue, reason: '$key = $value');
    }
  });
}
