import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
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

/// The downloaded file is not the release the manifest describes.
///
/// Thrown instead of launching the installer, so a truncated download, an
/// HTML error page or a swapped file on the host can never reach Android's
/// package installer.
class UpdateIntegrityException implements Exception {
  const UpdateIntegrityException(this.message);

  final String message;

  @override
  String toString() => 'UpdateIntegrityException: $message';
}

/// Collects the single [Digest] that a chunked hash conversion produces.
class _DigestCollector implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Downloads the published APK inside the app and hands it to the Android
/// package installer, so the user never uninstalls or leaves HabitNova.
///
/// Nothing is installed silently: the system installer still shows its own
/// confirmation sheet, which is the only way Android allows a self-update.
///
/// Before that sheet is opened the file must match `sha256` from the manifest
/// and carry the `versionCode` the manifest advertises, so an interrupted
/// download or a stale release fails here with a readable message.
class AppUpdateInstaller {
  AppUpdateInstaller._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.synvero/app_update',
  );

  /// Drives the overlay UI.
  static final ValueNotifier<UpdateInstallState> state =
      ValueNotifier<UpdateInstallState>(const UpdateInstallState());

  /// How long the installer hand-off may stay "busy" before it is released.
  static const Duration installerGrace = Duration(seconds: 20);

  static Timer? _resetTimer;
  static bool _observingLifecycle = false;

  static Future<void> reset() async {
    _resetTimer?.cancel();
    _resetTimer = null;
    state.value = const UpdateInstallState();
  }

  /// Releases a finished or abandoned installer hand-off so the button works
  /// again.
  ///
  /// The system installer cannot tell us whether the user installed or backed
  /// out, so coming back to the app (or the grace timer expiring) is the signal
  /// that this attempt is over.
  @visibleForTesting
  static void onAppResumed() {
    _resetTimer?.cancel();
    _resetTimer = null;
    if (_isFinishedAttempt(state.value.stage)) {
      state.value = const UpdateInstallState();
    }
  }

  static bool _isFinishedAttempt(UpdateInstallStage stage) =>
      stage == UpdateInstallStage.launching ||
      stage == UpdateInstallStage.needsPermission;

  static void _watchLifecycle() {
    if (_observingLifecycle) return;
    _observingLifecycle = true;
    WidgetsBinding.instance.addObserver(_UpdateLifecycleObserver());
  }

  static void _armResetTimer() {
    _resetTimer?.cancel();
    _resetTimer = Timer(installerGrace, () {
      _resetTimer = null;
      if (_isFinishedAttempt(state.value.stage)) {
        state.value = const UpdateInstallState();
      }
    });
  }

  /// Runs the whole flow: permission check, download, verify, then launch the
  /// installer.
  ///
  /// [client] exists for tests; production always uses a fresh HTTP client.
  static Future<void> start(AppUpdateInfo info, {http.Client? client}) async {
    if (state.value.isBusy) return;
    _watchLifecycle();
    if (!AppUpdateService.isSupportedPlatform) {
      state.value = const UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message: 'In-app updates are only available on Android.',
      );
      return;
    }

    if (info.sha256 == null) {
      state.value = const UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message:
            'This update cannot be verified inside the app. Download it in your browser instead.',
      );
      return;
    }

    if (!info.isPackageNewer) {
      state.value = UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message:
            'The published package (build ${info.versionCode}) is not newer than this app. Please try again later.',
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
        _armResetTimer();
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
      final http.Client httpClient = client ?? http.Client();
      try {
        await _download(info, apk, httpClient);
      } catch (_) {
        // Never leave a partial or unverified package behind.
        try {
          if (apk.existsSync()) apk.deleteSync();
        } catch (_) {}
        rethrow;
      } finally {
        if (client == null) httpClient.close();
      }

      state.value = state.value.copyWith(
        stage: UpdateInstallStage.launching,
        progress: 1,
        message: 'Opening the installer…',
      );

      final bool? opened = await _channel.invokeMethod<bool>('installApk', {
        'path': apk.path,
        'expectedVersionCode': info.versionCode,
      });
      if (opened != true) {
        throw const FileSystemException('Installer did not open');
      }
      state.value = state.value.copyWith(
        message: 'Confirm the install in the system prompt.',
      );
      // If the user cancels in the system sheet, nothing else tells us the
      // attempt ended; release the busy state after a grace period.
      _armResetTimer();
    } on PlatformException catch (e) {
      state.value = UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message: e.message ?? 'Could not open the installer.',
      );
    } on UpdateIntegrityException {
      state.value = const UpdateInstallState(
        stage: UpdateInstallStage.failed,
        message:
            'The download did not match the published release. Please try again.',
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

  static Future<void> _download(
    AppUpdateInfo info,
    File target,
    http.Client client,
  ) async {
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

    // Hash while writing: an 80 MB APK never has to be read back into memory
    // or from disk just to be checked.
    final _DigestCollector digest = _DigestCollector();
    final hasher = sha256.startChunkedConversion(digest);

    final int total = response.contentLength ?? 0;
    final IOSink sink = target.openWrite();
    int received = 0;
    try {
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        hasher.add(chunk);
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
    hasher.close();

    if (received == 0) {
      throw const HttpException('Empty download');
    }

    final String actual = digest.value?.toString() ?? '';
    if (actual != info.sha256) {
      throw UpdateIntegrityException(
        'sha256 mismatch: expected ${info.sha256}, downloaded $actual',
      );
    }
  }
}

/// Resets an abandoned update attempt when the user comes back to the app.
class _UpdateLifecycleObserver extends WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      AppUpdateInstaller.onAppResumed();
    }
  }
}
