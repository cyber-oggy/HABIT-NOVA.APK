import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:synvero/core/services/app_update_installer.dart';
import 'package:synvero/core/services/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.example.synvero/app_update');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const String publishedSha =
      'c2ddbe6b1f84cab09dd87945631e7fe275f6f4cc35a784d86097243330791e80';

  const AppUpdateInfo info = AppUpdateInfo(
    latestVersion: '1.2.0',
    latestBuild: 4,
    currentVersion: '1.1.0',
    currentBuild: 2,
    minSupportedBuild: 1,
    apkUrl: 'https://example.com/habitnova.apk',
    versionCode: 4,
    sha256: publishedSha,
  );

  setUp(() async {
    await AppUpdateInstaller.reset();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('asks Android for install permission before downloading anything',
      () async {
    final List<String> calls = <String>[];
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      calls.add(call.method);
      if (call.method == 'canInstallPackages') return false;
      if (call.method == 'openInstallSettings') return true;
      return null;
    });

    await AppUpdateInstaller.start(info);

    expect(calls, <String>['canInstallPackages', 'openInstallSettings']);
    expect(AppUpdateInstaller.state.value.stage,
        UpdateInstallStage.needsPermission);
    expect(AppUpdateInstaller.state.value.isBusy, isFalse);
  });

  test('reports a friendly failure when the update folder is unavailable',
      () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'canInstallPackages') return true;
      if (call.method == 'getUpdateDir') return null;
      return null;
    });

    await AppUpdateInstaller.start(info);

    expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.failed);
    expect(AppUpdateInstaller.state.value.message, isNotEmpty);
  });

  group('abandoned installer hand-off', () {
    test('coming back to the app releases a pending install', () {
      AppUpdateInstaller.state.value = const UpdateInstallState(
        stage: UpdateInstallStage.launching,
      );

      AppUpdateInstaller.onAppResumed();

      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.idle);
      expect(AppUpdateInstaller.state.value.isBusy, isFalse);
    });

    test('coming back after granting permission clears the stale message', () {
      AppUpdateInstaller.state.value = const UpdateInstallState(
        stage: UpdateInstallStage.needsPermission,
        message: 'Allow installs',
      );

      AppUpdateInstaller.onAppResumed();

      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.idle);
      expect(AppUpdateInstaller.state.value.message, isEmpty);
    });

    test('a download in progress is left running', () {
      AppUpdateInstaller.state.value = const UpdateInstallState(
        stage: UpdateInstallStage.downloading,
        progress: 0.4,
      );

      AppUpdateInstaller.onAppResumed();

      expect(AppUpdateInstaller.state.value.stage,
          UpdateInstallStage.downloading);
      expect(AppUpdateInstaller.state.value.progress, 0.4);
    });
  });

  group('verifies the package before opening the installer', () {
    late Directory tempDir;
    late http.Client client;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('habitnova_update_test');
    });

    tearDown(() {
      if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
    });

    AppUpdateInfo infoWith({
      String? sha256 = publishedSha,
      int versionCode = 4,
    }) {
      return AppUpdateInfo(
        latestVersion: info.latestVersion,
        latestBuild: info.latestBuild,
        currentVersion: info.currentVersion,
        currentBuild: info.currentBuild,
        minSupportedBuild: info.minSupportedBuild,
        apkUrl: info.apkUrl,
        versionCode: versionCode,
        sha256: sha256,
      );
    }

    /// Serves [bytes] as the APK and records every channel call.
    List<MethodCall> serveApk(
      List<int> bytes, {
      int statusCode = 200,
      PlatformException? installFailure,
    }) {
      final List<MethodCall> calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls.add(call);
        switch (call.method) {
          case 'canInstallPackages':
            return true;
          case 'getUpdateDir':
            return tempDir.path;
          case 'installApk':
            if (installFailure != null) throw installFailure;
            return true;
        }
        return null;
      });
      client = MockClient(
        (http.Request request) async =>
            http.Response.bytes(bytes, statusCode),
      );
      return calls;
    }

    test('a matching hash opens the installer for the published build',
        () async {
      final List<int> bytes = utf8.encode('a real looking apk payload');
      final List<MethodCall> calls = serveApk(bytes);

      await AppUpdateInstaller.start(
        infoWith(sha256: sha256.convert(bytes).toString()),
        client: client,
      );

      final MethodCall install = calls.singleWhere(
        (MethodCall call) => call.method == 'installApk',
      );
      final Map<Object?, Object?> args =
          install.arguments as Map<Object?, Object?>;
      expect(args['path'], endsWith('habitnova-4.apk'));
      expect(args['expectedVersionCode'], 4);
      expect(AppUpdateInstaller.state.value.stage,
          UpdateInstallStage.launching);
      expect(File(args['path'] as String).existsSync(), isTrue);
    });

    test('a truncated or swapped package never reaches the installer',
        () async {
      final List<int> bytes = utf8.encode('only half of the apk arrived');
      final List<MethodCall> calls = serveApk(bytes);

      await AppUpdateInstaller.start(infoWith(), client: client);

      expect(
        calls.where((MethodCall call) => call.method == 'installApk'),
        isEmpty,
      );
      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.failed);
      expect(
        AppUpdateInstaller.state.value.message,
        contains('did not match the published release'),
      );
      expect(File('${tempDir.path}/habitnova-4.apk').existsSync(), isFalse,
          reason: 'an unverified package must be deleted');
    });

    test('an html error page disguised as an apk is rejected', () async {
      final List<int> bytes = utf8.encode('<html>404 not found</html>');
      final List<MethodCall> calls = serveApk(bytes);

      await AppUpdateInstaller.start(
        infoWith(sha256: publishedSha),
        client: client,
      );

      expect(
        calls.where((MethodCall call) => call.method == 'installApk'),
        isEmpty,
      );
      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.failed);
    });

    test('a manifest without a hash refuses the in-app install', () async {
      final List<MethodCall> calls = serveApk(<int>[1, 2, 3]);

      await AppUpdateInstaller.start(infoWith(sha256: null), client: client);

      expect(calls, isEmpty);
      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.failed);
      expect(AppUpdateInstaller.state.value.message, contains('browser'));
    });

    test('a package that is not newer than this build is not downloaded',
        () async {
      final List<MethodCall> calls = serveApk(<int>[1, 2, 3]);

      await AppUpdateInstaller.start(
        infoWith(versionCode: 2),
        client: client,
      );

      expect(calls, isEmpty);
      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.failed);
      expect(AppUpdateInstaller.state.value.message, contains('not newer'));
    });

    test('reports the archive version Android refuses to install', () async {
      serveApk(
        utf8.encode('matching payload'),
        installFailure: PlatformException(
          code: 'VERSION_MISMATCH',
          message: 'This update file is build 1, but build 4 was published.',
        ),
      );

      await AppUpdateInstaller.start(
        infoWith(sha256: sha256.convert(utf8.encode('matching payload')).toString()),
        client: client,
      );

      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.failed);
      expect(
        AppUpdateInstaller.state.value.message,
        contains('build 1'),
      );
    });

    test('an empty response is not treated as a valid package', () async {
      final List<MethodCall> calls = serveApk(<int>[]);

      await AppUpdateInstaller.start(
        infoWith(sha256: sha256.convert(<int>[]).toString()),
        client: client,
      );

      expect(
        calls.where((MethodCall call) => call.method == 'installApk'),
        isEmpty,
      );
      expect(AppUpdateInstaller.state.value.stage, UpdateInstallStage.failed);
    });
  });

  test('does not start twice while a download is in flight', () async {
    int permissionChecks = 0;
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'canInstallPackages') {
        permissionChecks++;
        return false;
      }
      return true;
    });

    AppUpdateInstaller.state.value = const UpdateInstallState(
      stage: UpdateInstallStage.downloading,
    );
    await AppUpdateInstaller.start(info);

    expect(permissionChecks, 0);
  });
}
