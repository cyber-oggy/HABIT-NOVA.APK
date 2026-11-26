import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/gamification_service.dart';
import 'package:synvero/core/services/streak_freeze_service.dart';

/// One repair the validator applied to the stored streak state.
enum StreakStateRepair {
  /// A negative streak counter was reset to 0.
  negativeStreak,

  /// The dedicated completion day was missing but the legacy habit date existed.
  seededDayFromLegacy,

  /// A streak existed with no completion day at all.
  seededMissingDay,

  /// The stored completion day was more than a day ahead of today.
  clampedFutureDay,

  /// The stored completion instant was in the future.
  resetFutureInstant,

  /// The stored completion instant was not a parseable date.
  clearedInvalidInstant,

  /// The stored completion day was not a parseable date and no streak needed it.
  clearedInvalidDay,

  /// The freeze bank held fewer than 0 or more than the allowed maximum.
  clampedFreezeCount,

  /// The frozen-day history grew past the retention limit.
  trimmedFrozenHistory,

  /// `app_streak_days` disagreed with this account's own streak.
  syncedGlobalStreak,
}

/// Outcome of one [StreakStateValidator.validateAndRepair] run.
@immutable
class StreakStateReport {
  const StreakStateReport(this.repairs);

  const StreakStateReport.clean() : repairs = const <StreakStateRepair>[];

  final List<StreakStateRepair> repairs;

  bool get changed => repairs.isNotEmpty;

  @override
  String toString() =>
      'StreakStateReport(${repairs.map((r) => r.name).join(', ')})';
}

/// Checks the stored streak, freeze and XP bookkeeping on launch and repairs
/// only the states that cannot be true.
///
/// The app has grown several rules over time (streak freeze, cloud restore,
/// timezone-safe day boundary, migration from older builds), so a device can
/// end up holding combinations no current code path would write: a streak with
/// no day, a day in the future, a freeze bank over the cap, or a global streak
/// that disagrees with the account's own. This validator fixes those quietly
/// before the dashboard reads them.
///
/// Rules:
///  - It never spends or grants freezes, and never touches XP balances.
///  - It keeps the streak counter whenever a streak is plausible instead of
///    throwing the user's progress away.
///  - It tolerates a day that is one day ahead, because a timezone change can
///    legitimately push the local date forward; only a wider jump is clamped.
class StreakStateValidator {
  StreakStateValidator._();

  /// Must match [StreakFreezeService]'s frozen history retention.
  static const int maxFrozenHistory = 60;

  static String _streakKey(String uid) => 'user_${uid}_streak_days';
  static String _dayKey(String uid) => 'user_${uid}_streak_last_date_v1';
  static String _instantKey(String uid) => 'user_${uid}_streak_last_at_v1';
  static String _legacyDayKey(String uid) => 'user_${uid}_last_habit_date';
  static String _freezeKey(String uid) => 'user_${uid}_streak_freezes_v1';
  static String _frozenDatesKey(String uid) =>
      'user_${uid}_streak_frozen_dates_v1';

  static DateTime? _parseDay(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final parsed = DateTime.tryParse(raw.trim());
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  /// Validates the state for [userId] and repairs impossible combinations.
  ///
  /// Safe to call on every launch: a clean state produces no writes and an
  /// empty report.
  static Future<StreakStateReport> validateAndRepair({
    String? userId,
    DateTime? now,
  }) async {
    final uid = userId ?? GamificationService.currentUserId;
    final repairs = <StreakStateRepair>[];
    final prefs = await SharedPreferences.getInstance();
    final moment = now ?? DateTime.now();
    final today = DateTime(moment.year, moment.month, moment.day);
    final yesterday = DateTime(today.year, today.month, today.day - 1);

    // --- streak counter -----------------------------------------------------
    final int? rawStreak = prefs.getInt(_streakKey(uid));
    var streak = rawStreak ?? 0;
    if (streak < 0) {
      streak = 0;
      await prefs.setInt(_streakKey(uid), 0);
      repairs.add(StreakStateRepair.negativeStreak);
    }

    // --- completion day -----------------------------------------------------
    final String? storedDayRaw = prefs.getString(_dayKey(uid));
    final DateTime? day = _parseDay(storedDayRaw);

    if (day == null) {
      final DateTime? legacy = _parseDay(prefs.getString(_legacyDayKey(uid)));
      if (legacy != null) {
        // Older builds only kept this date; adopt it before inventing one.
        await prefs.setString(
          _dayKey(uid),
          StreakFreezeService.formatDate(legacy),
        );
        repairs.add(StreakStateRepair.seededDayFromLegacy);
      } else if (streak > 0) {
        // Nothing dates the streak. Yesterday is the only day that keeps it
        // alive without claiming today is done or charging a freeze.
        await prefs.setString(
          _dayKey(uid),
          StreakFreezeService.formatDate(yesterday),
        );
        repairs.add(StreakStateRepair.seededMissingDay);
      } else if (storedDayRaw != null) {
        // Junk in the day slot with no streak behind it.
        await prefs.remove(_dayKey(uid));
        repairs.add(StreakStateRepair.clearedInvalidDay);
      }
    } else if (day.isAfter(DateTime(today.year, today.month, today.day + 1))) {
      // One day ahead is a plausible timezone jump: leave it alone so the
      // travel protection in the day-boundary logic still works.
      await prefs.setString(
        _dayKey(uid),
        StreakFreezeService.formatDate(today),
      );
      repairs.add(StreakStateRepair.clampedFutureDay);
    }

    // --- completion instant -------------------------------------------------
    final String? storedInstantRaw = prefs.getString(_instantKey(uid));
    if (storedInstantRaw != null) {
      final DateTime? instant = DateTime.tryParse(storedInstantRaw);
      if (instant == null) {
        await prefs.remove(_instantKey(uid));
        repairs.add(StreakStateRepair.clearedInvalidInstant);
      } else if (instant.toUtc().isAfter(moment.toUtc().add(const Duration(hours: 1)))) {
        // A future instant would cap every gap to "no days lived".
        await prefs.setString(
          _instantKey(uid),
          moment.toUtc().toIso8601String(),
        );
        repairs.add(StreakStateRepair.resetFutureInstant);
      }
    }

    // --- freeze bank --------------------------------------------------------
    final int? freezeCount = prefs.getInt(_freezeKey(uid));
    if (freezeCount != null) {
      final int clamped = freezeCount.clamp(0, StreakFreezeService.maxFreezes);
      if (clamped != freezeCount) {
        await prefs.setInt(_freezeKey(uid), clamped);
        repairs.add(StreakStateRepair.clampedFreezeCount);
      }
    }

    final List<String>? frozen = prefs.getStringList(_frozenDatesKey(uid));
    if (frozen != null && frozen.length > maxFrozenHistory) {
      await prefs.setStringList(
        _frozenDatesKey(uid),
        frozen.sublist(frozen.length - maxFrozenHistory),
      );
      repairs.add(StreakStateRepair.trimmedFrozenHistory);
    }

    // --- global mirror ------------------------------------------------------
    // Only this account's own key is authoritative. Without it the global value
    // cannot be attributed to anyone, so it is left untouched.
    if (rawStreak != null) {
      final int? globalStreak = prefs.getInt('app_streak_days');
      if (globalStreak != streak) {
        await prefs.setInt('app_streak_days', streak);
        repairs.add(StreakStateRepair.syncedGlobalStreak);
      }
    }

    final report = StreakStateReport(List<StreakStateRepair>.unmodifiable(repairs));
    if (report.changed) {
      debugPrint('StreakStateValidator repaired: $report');
    }
    return report;
  }
}
