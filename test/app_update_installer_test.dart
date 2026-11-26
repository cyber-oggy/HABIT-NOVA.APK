import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:synvero/core/services/app_update_installer.dart';
import 'package:synvero/core/services/app_update_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel('com.example.synvero/app_update');
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  const AppUpdateInfo info = AppUpdateInfo(
    latestVersion: '1.2.0',
    latestBuild: 4,
    currentVersion: '1.1.0',
    currentBuild: 2,
    minSupportedBuild: 1,
    apkUrl: 'https://example.com/habitnova.apk',
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
