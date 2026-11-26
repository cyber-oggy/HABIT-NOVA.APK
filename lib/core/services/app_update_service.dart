import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/config/app_update_config.dart';
import 'package:url_launcher/url_launcher.dart';

/// Describes a newer build published for the app.
@immutable
class AppUpdateInfo {
  const AppUpdateInfo({
    required this.latestVersion,
    required this.latestBuild,
    required this.currentVersion,
    required this.currentBuild,
    required this.minSupportedBuild,
    required this.apkUrl,
    this.versionCode = 0,
    this.sha256,
    this.notes = const <String>[],
  });

  final String latestVersion;
  final int latestBuild;
  final String currentVersion;
  final int currentBuild;

  /// Builds older than this must update before the app keeps working.
  final int minSupportedBuild;
  final String apkUrl;

  /// Android `versionCode` of the file at [apkUrl].
  ///
  /// The manifest advertises the release, but the bytes behind the URL are what
  /// Android actually installs, so the APK is checked against this before the
  /// installer is opened. Zero when the manifest does not declare it.
  final int versionCode;

  /// Lower-case SHA-256 of the file at [apkUrl].
  ///
  /// Null when the manifest does not pin a usable hash; the in-app installer
  /// refuses to run without one and offers the browser download instead.
  final String? sha256;

  final List<String> notes;

  bool get isMandatory => currentBuild < minSupportedBuild;

  /// True when the published package really is a newer build than this one.
  ///
  /// A package that is the same build (or older) cannot be installed over this
  /// one: Android either rejects it as a downgrade or silently reinstalls what
  /// is already there, which is why that is caught before downloading.
  bool get isPackageNewer => versionCode == 0 || versionCode > currentBuild;

  /// True when the in-app flow can verify what it downloaded.
  bool get canInstallInApp => sha256 != null && isPackageNewer;

  static final RegExp _sha256Pattern = RegExp(r'^[a-f0-9]{64}$');

  /// Returns null when the manifest is unusable, so a typo never bricks startup.
  static AppUpdateInfo? fromManifest(
    Map<String, dynamic> json, {
    required int currentBuild,
    required String currentVersion,
  }) {
    final Object? rawUrl = json['apk_url'];
    final Object? rawBuild = json['latest_build'];
    if (rawUrl is! String || rawUrl.trim().isEmpty) return null;
    if (rawBuild is! num) return null;

    final Uri? parsed = Uri.tryParse(rawUrl.trim());
    if (parsed == null || !parsed.hasScheme) return null;

    final List<String> notes = <String>[];
    final Object? rawNotes = json['notes'];
    if (rawNotes is List) {
      for (final Object? note in rawNotes) {
        if (note is String && note.trim().isNotEmpty) notes.add(note.trim());
      }
    }

    // A hash that is not 64 hex characters cannot verify anything, so it is
    // dropped instead of failing the whole manifest: users still get the
    // prompt, they just fall back to the browser download.
    final Object? rawSha = json['sha256'];
    String? sha256;
    if (rawSha is String) {
      final String normalized = rawSha.trim().toLowerCase();
      if (_sha256Pattern.hasMatch(normalized)) sha256 = normalized;
    }

    return AppUpdateInfo(
      latestVersion: (json['latest_version'] as String?)?.trim() ?? '$rawBuild',
      latestBuild: rawBuild.toInt(),
      currentVersion: currentVersion,
      currentBuild: currentBuild,
      minSupportedBuild: (json['min_supported_build'] as num?)?.toInt() ?? 0,
      apkUrl: parsed.toString(),
      versionCode: (json['version_code'] as num?)?.toInt() ?? rawBuild.toInt(),
      sha256: sha256,
      notes: notes,
    );
  }
}

/// Checks a hosted manifest for a newer build and exposes it to the UI.
///
/// Fails silently: no network, a bad manifest or an unsupported platform must
/// never block the app from starting.
class AppUpdateService {
  AppUpdateService._();

  /// The pending update, if any. `AppUpdateOverlay` listens to this.
  static final ValueNotifier<AppUpdateInfo?> availableUpdate =
      ValueNotifier<AppUpdateInfo?>(null);

  static bool _checking = false;

  /// The in-app update flow installs APK files, so it is Android-only.
  static bool get isSupportedPlatform =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  /// Fetch the manifest and publish a newer build to [availableUpdate].
  ///
  /// [force] skips the throttle/snooze window (used by "check again" actions).
  static Future<void> checkForUpdate({bool force = false}) async {
    if (!isSupportedPlatform || _checking) return;
    _checking = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int now = DateTime.now().millisecondsSinceEpoch;

      final int lastCheck = prefs.getInt(AppUpdateConfig.lastCheckKey) ?? 0;
      if (!force &&
          now - lastCheck < AppUpdateConfig.checkInterval.inMilliseconds) {
        return;
      }

      // The snooze window only silences the prompt, so it is applied after the
      // manifest is known: a build below `min_supported_build` must never be
      // hidden by a snooze that was given when the update was optional.
      final String? fetched = await _fetchManifest();
      if (fetched != null) {
        await prefs.setInt(AppUpdateConfig.lastCheckKey, now);
        await prefs.setString(AppUpdateConfig.lastManifestKey, fetched);
      }

      // Offline (or a broken response) must not quietly drop a required
      // update: fall back to the last manifest that parsed.
      final bool fromCache = fetched == null;
      final String? body =
          fetched ?? prefs.getString(AppUpdateConfig.lastManifestKey);
      final Map<String, dynamic>? manifest = _decodeManifest(body);
      if (manifest == null) return;

      final PackageInfo packageInfo = await PackageInfo.fromPlatform();
      final int currentBuild = int.tryParse(packageInfo.buildNumber) ?? 0;

      final AppUpdateInfo? info = AppUpdateInfo.fromManifest(
        manifest,
        currentBuild: currentBuild,
        currentVersion: packageInfo.version,
      );
      if (info == null) return;

      // The cached answer is only kept for a required update; a stale optional
      // prompt should not pop up when the network is down.
      if (fromCache && !info.isMandatory) return;

      if (info.latestBuild <= currentBuild && !info.isMandatory) {
        availableUpdate.value = null;
        return;
      }

      final int snoozedUntil = prefs.getInt(AppUpdateConfig.snoozeKey) ?? 0;
      if (!force && now < snoozedUntil && !info.isMandatory) return;

      availableUpdate.value = info;
    } catch (e) {
      debugPrint('AppUpdateService.checkForUpdate skipped: $e');
    } finally {
      _checking = false;
    }
  }

  /// Fetch the manifest, or null when the network or the server failed.
  static Future<String?> _fetchManifest() async {
    try {
      final http.Response response = await http
          .get(
            Uri.parse(AppUpdateConfig.manifestUrl),
            headers: const <String, String>{'Cache-Control': 'no-cache'},
          )
          .timeout(AppUpdateConfig.requestTimeout);
      if (response.statusCode != 200) return null;
      return response.body;
    } catch (e) {
      debugPrint('AppUpdateService manifest fetch failed: $e');
      return null;
    }
  }

  static Map<String, dynamic>? _decodeManifest(String? body) {
    if (body == null || body.trim().isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(body);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  /// Hide the prompt for [AppUpdateConfig.snoozeDuration].
  ///
  /// A required update ignores the snooze, so it is refused here too instead of
  /// arming a window that [checkForUpdate] would only skip over.
  static Future<void> snooze() async {
    final AppUpdateInfo? info = availableUpdate.value;
    if (info != null && info.isMandatory) return;
    availableUpdate.value = null;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setInt(
        AppUpdateConfig.snoozeKey,
        DateTime.now()
            .add(AppUpdateConfig.snoozeDuration)
            .millisecondsSinceEpoch,
      );
    } catch (_) {}
  }

  /// Open the download page for the new APK in the device browser.
  static Future<bool> openDownload(AppUpdateInfo info) async {
    try {
      return await launchUrl(
        Uri.parse(info.apkUrl),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      debugPrint('AppUpdateService.openDownload failed: $e');
      return false;
    }
  }
}
