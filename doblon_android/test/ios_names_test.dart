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

  test('the iPhone app has the identifier of the Swift app, so installing it replaces that app', () {
    final workflow = File('../.github/workflows/build-ios-ipa.yml').readAsStringSync();
    final swift = RegExp(r"inputs\.bundle_identifier \|\| '([^']+)'").firstMatch(workflow)!.group(1);
    final project = File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();
    final flutter = RegExp(r'PRODUCT_BUNDLE_IDENTIFIER = ([^;]+);').allMatches(project).map((m) => m.group(1)).toSet();
    expect(flutter, {swift, '$swift.RunnerTests'});
  });

  test('the iPhone app shows the dog icon, as the Swift app', () {
    final icon = File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Doge.png');
    expect(icon.existsSync(), isTrue);
    expect(icon.readAsBytesSync(), File('../MiPatrimonio/Resources/Assets.xcassets/AppIcon.appiconset/Doge.png').readAsBytesSync());
    expect(File('ios/Runner/Assets.xcassets/AppIcon.appiconset/Contents.json').readAsStringSync(), contains('Doge.png'));
  });
}
