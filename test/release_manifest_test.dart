import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synvero/core/services/app_update_service.dart';

/// Collects the single digest a chunked hash conversion produces.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

Future<String> _sha256OfFile(File file) async {
  final _DigestSink sink = _DigestSink();
  final hasher = sha256.startChunkedConversion(sink);
  await for (final List<int> chunk in file.openRead()) {
    hasher.add(chunk);
  }
  hasher.close();
  return sink.value!.toString();
}

/// Guards the release contract between the app and the update manifest.
///
/// `version.json` is fetched by the installed app and compared against its own
/// build number. If the manifest and `pubspec.yaml` drift apart, users are
/// either never offered an update (manifest too old) or offered an update that
/// downloads the previous APK (manifest newer than the published binary), so
/// the mismatch must fail here instead of shipping.
void main() {
  late Directory root;
  late String versionName;
  late int buildNumber;
  late Map<String, dynamic> manifest;

  Directory findPackageRoot() {
    Directory dir = Directory.current;
    for (var i = 0; i < 5; i++) {
      if (File('${dir.path}/pubspec.yaml').existsSync()) return dir;
      dir = dir.parent;
    }
    fail('Could not find pubspec.yaml from ${Directory.current.path}');
  }

  setUpAll(() {
    root = findPackageRoot();
    manifest = jsonDecode(
      File('${root.path}/version.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    final String pubspec = File('${root.path}/pubspec.yaml').readAsStringSync();
    final RegExpMatch? match = RegExp(
      r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(
      match,
      isNotNull,
      reason: 'pubspec.yaml needs a `version: X.Y.Z+build` line',
    );
    versionName = match!.group(1)!;
    buildNumber = int.parse(match.group(2)!);
  });

  group('version.json is a valid release manifest', () {
    test('has the fields the app reads', () {
      expect(manifest['latest_version'], isA<String>());
      expect(
        (manifest['latest_version'] as String).trim(),
        isNotEmpty,
        reason: 'latest_version must not be blank',
      );
      expect(manifest['latest_build'], isA<num>());
      expect(manifest['min_supported_build'], isA<num>());
      expect(manifest['apk_url'], isA<String>());
      expect(manifest['notes'], isA<List<dynamic>>());
      expect(manifest['released_at'], isA<String>());
    });

    test('points at an absolute https APK', () {
      final Uri? url = Uri.tryParse((manifest['apk_url'] as String).trim());

      expect(url, isNotNull);
      expect(url!.hasScheme, isTrue);
      expect(url.scheme, 'https');
      expect(url.hasAuthority, isTrue);
      expect(url.path, endsWith('.apk'));
    });

    test('notes are usable in the update card', () {
      final List<dynamic> notes = manifest['notes'] as List<dynamic>;

      expect(notes, isNotEmpty);
      for (final Object? note in notes) {
        expect(note, isA<String>());
        expect(
          (note as String).trim(),
          isNotEmpty,
          reason: 'blank notes leave an empty row in the prompt',
        );
      }
    });
  });

  group('version.json pins the published APK', () {
    const String apkPath = 'apk/habit-nova-release.apk';

    test('apk_url serves the APK committed in this repository', () {
      final Uri url = Uri.parse((manifest['apk_url'] as String).trim());

      expect(
        url.path.endsWith(apkPath),
        isTrue,
        reason: 'apk_url must point at $apkPath, got ${url.path}',
      );
    });

    test('sha256 is a lower-case 64 character digest', () {
      final Object? raw = manifest['sha256'];

      expect(raw, isA<String>());
      expect(
        raw as String,
        matches(RegExp(r'^[a-f0-9]{64}$')),
        reason: 'the app only accepts a plain lower-case hex sha256',
      );
    });

    test('sha256 is the hash of the APK users download', () async {
      final File apk = File('${root.path}/$apkPath');

      expect(apk.existsSync(), isTrue, reason: 'missing $apkPath');
      expect(
        await _sha256OfFile(apk),
        manifest['sha256'],
        reason:
            'version.json pins a different APK than the one served; every '
            'in-app install would fail its integrity check. Regenerate the '
            'manifest after replacing the APK.',
      );
    });

    test('version_code describes an installable package', () {
      final Object? raw = manifest['version_code'];

      expect(raw, isA<num>());
      final int versionCode = (raw as num).toInt();
      expect(versionCode, greaterThan(0));
      expect(
        versionCode,
        lessThanOrEqualTo(buildNumber),
        reason:
            'version.json says build $buildNumber; the served package is '
            'versionCode $versionCode',
      );
    });
  });

  group('version.json matches pubspec.yaml', () {
    test('latest_version is the pubspec version name', () {
      expect(
        (manifest['latest_version'] as String).trim(),
        versionName,
        reason:
            'pubspec says $versionName; version.json says '
            '${manifest['latest_version']}',
      );
    });

    test('latest_build is the pubspec build number', () {
      expect(
        (manifest['latest_build'] as num).toInt(),
        buildNumber,
        reason:
            'pubspec build is +$buildNumber; version.json says '
            '${manifest['latest_build']}',
      );
    });

    test('min_supported_build never exceeds the published build', () {
      final int minSupported = (manifest['min_supported_build'] as num).toInt();

      expect(minSupported, greaterThanOrEqualTo(0));
      expect(
        minSupported,
        lessThanOrEqualTo(buildNumber),
        reason: 'a minimum above the newest build would lock everyone out',
      );
    });

    test('a client on the previous build is actually offered the update', () {
      // Stand-in for the APK that is currently installed on devices. The app
      // shows the prompt only when latest_build is strictly newer, so this
      // also catches a manifest that was never bumped for the new release.
      final int installedBuild = buildNumber - 1;
      final AppUpdateInfo? info = AppUpdateInfo.fromManifest(
        manifest,
        currentBuild: installedBuild,
        currentVersion: versionName,
      );

      expect(info, isNotNull, reason: 'the manifest must parse in the app');
      expect(info!.latestBuild, greaterThan(installedBuild));
      expect(info.latestVersion, versionName);
      expect(info.notes, isNotEmpty);
    });

    test('the current build sees no update prompt after installing', () {
      final AppUpdateInfo? info = AppUpdateInfo.fromManifest(
        manifest,
        currentBuild: buildNumber,
        currentVersion: versionName,
      );

      expect(info, isNotNull);
      expect(
        info!.latestBuild,
        lessThanOrEqualTo(buildNumber),
        reason: 'users already on the newest build must not be prompted',
      );
    });
  });
}
