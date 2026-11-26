import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:synvero/core/config/app_update_config.dart';
import 'package:synvero/core/services/app_update_service.dart';

/// Where the in-app update flow currently stands.
enum UpdateInstallStage {
  /// Nothing started yet.
  idle,

  /// APK is being fetched into the app cache.
  downloading,

  /// The OS installer was launched.
  launching,

  /// Android needs "install unknown apps" allowed for HabitNova first.
  needsPermission,

  /// Something went wrong; [UpdateInstallState.message] explains it.
  failed,
}

/// Observable progress for the in-app update.
@immutable
class UpdateInstallState {
  const UpdateInstallState({
    this.stage = UpdateInstallStage.idle,
    this.progress = 0,
    this.message = '',
  });

  final UpdateInstallStage stage;

  /// 0..1 while downloading, 0 when the total size is unknown.
  final double progress;
  final String message;

  bool get isBusy =>
      stage == UpdateInstallStage.downloading ||
      stage == UpdateInstallStage.launching;

  UpdateInstallState copyWith({
    UpdateInstallStage? stage,
    double? progress,
    String? message,
  }) {
    return UpdateInstallState(
      stage: stage ?? this.stage,
      progress: progress ?? this.progress,
      message: message ?? this.message,
    );
  }
}

/// Downloads the published APK inside the app and hands it to the Android
/// package installer, so the user never uninstalls or leaves HabitNova.
///
/// Nothing is installed silently: the system installer still shows its own
/// confirmation sheet, which is the only way Android allows a self-update.
class AppUpdateInstaller {
  AppUpdateInstaller._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.synvero/app_update',
  );

  /// Drives the overlay UI.
  static final ValueNotifier<UpdateInstallState> state =
      ValueNotifier<UpdateInstallState>(const UpdateInstallState());

  static Future<void> reset() async {
    state.value = const UpdateInstallState();
  }

  /// Runs the whole flow: permission check, download, then launch the installer.
  static Future<void> start(AppUpdateInfo info) async {
    if (state.value.isBusy) return;
    if (!AppUpdateService.isSupportedPlatform) {
      state.value = const UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message: 'In-app updates are only available on Android.',
      );
      return;
    }

    try {
      final bool allowed =
          await _channel.invokeMethod<bool>('canInstallPackages') ?? false;
      if (!allowed) {
        state.value = const UpdateInstallState(
          stage: UpdateInstallStage.needsPermission,
          message:
              'Allow "Install unknown apps" for HabitNova, then tap update again.',
        );
        await _channel.invokeMethod<bool>('openInstallSettings');
        return;
      }

      final String? dirPath = await _channel.invokeMethod<String>(
        'getUpdateDir',
      );
      if (dirPath == null || dirPath.isEmpty) {
        throw const FileSystemException('Update folder unavailable');
      }

      final Directory dir = Directory(dirPath);
      if (!dir.existsSync()) dir.createSync(recursive: true);

      // Drop leftovers from earlier attempts so storage never creeps up.
      for (final FileSystemEntity entity in dir.listSync()) {
        if (entity is File && entity.path.endsWith('.apk')) {
          try {
            entity.deleteSync();
          } catch (_) {}
        }
      }

      final File apk = File('${dir.path}/habitnova-${info.latestBuild}.apk');
      await _download(info, apk);

      state.value = state.value.copyWith(
        stage: UpdateInstallStage.launching,
        progress: 1,
        message: 'Opening the installer…',
      );

      final bool? opened = await _channel.invokeMethod<bool>('installApk', {
        'path': apk.path,
      });
      if (opened != true) {
        throw const FileSystemException('Installer did not open');
      }
      state.value = state.value.copyWith(
        message: 'Confirm the install in the system prompt.',
      );
    } on PlatformException catch (e) {
      state.value = UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message: e.message ?? 'Could not open the installer.',
      );
    } on TimeoutException {
      state.value = const UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message: 'The download timed out. Check your connection and retry.',
      );
    } catch (e) {
      debugPrint('AppUpdateInstaller.start failed: $e');
      state.value = const UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message: 'Update failed. Please try again.',
      );
    }
  }

  static Future<void> _download(AppUpdateInfo info, File target) async {
    final http.Client client = http.Client();
    try {
      state.value = const UpdateInstallState(
        stage: UpdateInstallStage.downloading,
        message: 'Downloading update…',
      );

      final http.Request request = http.Request('GET', Uri.parse(info.apkUrl));
      final http.StreamedResponse response = await client
          .send(request)
          .timeout(AppUpdateConfig.downloadTimeout);

      if (response.statusCode != 200) {
        throw HttpException('HTTP ${response.statusCode}');
      }

      final int total = response.contentLength ?? 0;
      final IOSink sink = target.openWrite();
      int received = 0;
      try {
        await for (final List<int> chunk in response.stream) {
          sink.add(chunk);
          received += chunk.length;
          state.value = state.value.copyWith(
            progress: total > 0 ? (received / total).clamp(0.0, 1.0) : 0,
            message: total > 0
                ? 'Downloading update… ${((received / total) * 100).round()}%'
                : 'Downloading update…',
          );
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (received == 0) {
        throw const HttpException('Empty download');
      }
    } finally {
      client.close();
    }
  }
}
