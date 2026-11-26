import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/config/streak_rules.dart';
import 'package:synvero/core/services/gamification_service.dart';

/// Result of trying to buy a streak freeze with XP.
enum FreezePurchaseResult { success, insufficientXP, atCapacity, error }

/// Owns the "Streak Freeze" inventory for a user.
///
/// Rules:
///  - One freeze is granted free every calendar week (Monday based).
///  - At most [maxFreezes] freezes can be stored at a time.
///  - Extra freezes can be bought for [freezeCostXP] XP. Buying only ever
///    *spends* XP, so it can never be used to farm points.
///  - A freeze is consumed automatically for every whole day that was missed,
///    which keeps the streak alive. A gap is only covered when enough freezes
///    exist for the whole gap, so a single freeze is never silently wasted.
///
/// The service is intentionally independent from [HabitDailyService] (which
/// depends on it) to keep the import graph acyclic.
class StreakFreezeService {
  StreakFreezeService._();

  /// Free freezes granted at the start of each week.
  static const int weeklyFreeFreezes = StreakRules.weeklyFreeFreezes;

  /// How many freezes can be banked at once.
  static const int maxFreezes = StreakRules.maxFreezes;

  /// XP price of one purchased freeze.
  static const int freezeCostXP = StreakRules.freezeCostXP;

  /// Frozen dates kept for history (older entries are trimmed).
  static const int _maxFrozenHistory = StreakRules.maxFrozenHistory;

  static String _countKey(String userId) => 'user_${userId}_streak_freezes_v1';
  static String _weekKey(String userId) =>
      'user_${userId}_streak_freeze_week_v1';
  static String _frozenDatesKey(String userId) =>
      'user_${userId}_streak_frozen_dates_v1';
  static String _streakLastDateKey(String userId) =>
      'user_${userId}_streak_last_date_v1';
  static String _lastAtKey(String userId) => 'user_${userId}_streak_last_at_v1';
  static String _streakKey(String userId) => 'user_${userId}_streak_days';

  /// `yyyy-MM-dd` for the local calendar day of [date].
  static String formatDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }

  /// Monday of the week containing [now], used as the weekly grant key.
  static String weekKeyFor(DateTime now) {
    final day = DateTime(now.year, now.month, now.day);
    return formatDate(
      DateTime(day.year, day.month, day.day - (day.weekday - 1)),
    );
  }

  static DateTime? _parseDate(String? raw) {
    if (raw == null) return null;
    final parsed = DateTime.tryParse(raw);
    if (parsed == null) return null;
    return DateTime(parsed.year, parsed.month, parsed.day);
  }

  static DateTime? _parseInstant(String? raw) {
    if (raw == null) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }

  /// Whole 24-hour periods that really elapsed between [lastAt] and [now].
  ///
  /// A local calendar can gain or lose days without any real time passing when
  /// the device timezone changes, the clock is set manually, or DST shifts it.
  /// You cannot miss a day you never lived through, so a gap is capped by this
  /// number: a jumped clock must not spend freezes or break a streak.
  static int elapsedWholeDays(DateTime lastAt, DateTime now) {
    final difference = now.toUtc().difference(lastAt.toUtc());
    if (difference.isNegative) return 0;
    return difference.inHours ~/ 24;
  }

  /// Caps a date-based gap by the real time that elapsed, when known.
  static int _capGapToElapsed(
    SharedPreferences prefs,
    String uid,
    int missedDays,
    DateTime reference,
  ) {
    if (missedDays <= 0) return 0;
    final lastAt = _parseInstant(prefs.getString(_lastAtKey(uid)));
    // Accounts upgraded from an older build have no instant to compare with.
    if (lastAt == null) return missedDays;
    final lived = elapsedWholeDays(lastAt, reference);
    return missedDays > lived ? lived : missedDays;
  }

  /// Grants this week's free freeze once. Safe to call on every app open.
  ///
  /// Returns true only when a freeze was actually added.
  static Future<bool> grantWeeklyFreezeIfDue({
    String? userId,
    DateTime? now,
  }) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final weekKey = weekKeyFor(now ?? DateTime.now());
      if (prefs.getString(_weekKey(uid)) == weekKey) return false;

      // Mark the week as handled even at capacity, so the user doesn't get a
      // second grant later in the same week after spending a freeze.
      await prefs.setString(_weekKey(uid), weekKey);

      final current = prefs.getInt(_countKey(uid)) ?? 0;
      if (current >= maxFreezes) return false;

      final next = (current + weeklyFreeFreezes).clamp(0, maxFreezes);
      await prefs.setInt(_countKey(uid), next);
      return next > current;
    } catch (e) {
      debugPrint('StreakFreezeService.grantWeeklyFreezeIfDue error: $e');
      return false;
    }
  }

  /// Number of freezes available right now (grants the weekly freeze first).
  static Future<int> availableFreezes({String? userId, DateTime? now}) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      await grantWeeklyFreezeIfDue(userId: uid, now: now);
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_countKey(uid)) ?? 0;
    } catch (e) {
      debugPrint('StreakFreezeService.availableFreezes error: $e');
      return 0;
    }
  }

  /// Buys one freeze for [freezeCostXP] XP.
  static Future<FreezePurchaseResult> purchaseFreeze({String? userId}) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final current = prefs.getInt(_countKey(uid)) ?? 0;
      if (current >= maxFreezes) return FreezePurchaseResult.atCapacity;

      final spent = await GamificationService.spendXP(
        freezeCostXP,
        userId: uid,
        reason: 'Bought a Streak Freeze',
      );
      if (!spent) return FreezePurchaseResult.insufficientXP;

      await prefs.setInt(_countKey(uid), current + 1);
      return FreezePurchaseResult.success;
    } catch (e) {
      debugPrint('StreakFreezeService.purchaseFreeze error: $e');
      return FreezePurchaseResult.error;
    }
  }

  /// Copies the pre-freeze `last_habit_date` into the dedicated streak key.
  ///
  /// Builds before streak freeze only wrote `user_<uid>_last_habit_date`, and
  /// the midnight rollover rewrites that key with *today* on every launch.
  /// Without this one-time copy a migrated user looks like they already
  /// completed today, so their streak would never grow again.
  static Future<String?> _migrateLegacyLastDate(
    SharedPreferences prefs,
    String uid,
  ) async {
    final String? existing = prefs.getString(_streakLastDateKey(uid));
    if (existing != null) return existing;

    final String? legacy = prefs.getString('user_${uid}_last_habit_date');
    if (_parseDate(legacy) == null) return legacy;

    await prefs.setString(_streakLastDateKey(uid), legacy!);
    return legacy;
  }

  /// One-time migration for accounts that predate streak freeze.
  ///
  /// Safe to call on every launch: it only writes when the new key is missing.
  /// Must run before the midnight rollover overwrites `last_habit_date`, so the
  /// real last completed day is captured rather than today.
  static Future<void> migrateLegacyStreakState({String? userId}) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await _migrateLegacyLastDate(prefs, uid);
    } catch (e) {
      debugPrint('StreakFreezeService.migrateLegacyStreakState error: $e');
    }
  }

  /// Number of whole days missed since the last completed day.
  ///
  /// Returns 0 when the streak is 0, the last date is unknown, or nothing was
  /// missed. Used by the midnight rollover to decide whether a freeze is
  /// needed and whether an uncovered gap must break the streak.
  static Future<int> missedDays({String? userId, DateTime? now}) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final streak = prefs.getInt(_streakKey(uid)) ?? 0;
      if (streak <= 0) return 0;

      final lastStr = await _migrateLegacyLastDate(prefs, uid);
      final last = _parseDate(lastStr);
      if (last == null) return 0;

      final reference = now ?? DateTime.now();
      final today = DateTime(reference.year, reference.month, reference.day);
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      if (!last.isBefore(yesterday)) return 0;

      // A device clock that jumped forward can create calendar gaps that never
      // happened; only gaps the user actually lived through count.
      return _capGapToElapsed(
        prefs,
        uid,
        yesterday.difference(last).inDays,
        reference,
      );
    } catch (e) {
      debugPrint('StreakFreezeService.missedDays error: $e');
      return 0;
    }
  }

  /// Consumes freezes for every whole day missed since the last completed day.
  ///
  /// Returns the number of days covered (0 when nothing was missed or when the
  /// bank doesn't hold enough freezes for the whole gap). On success the streak
  /// is preserved and the last completed day is moved to yesterday, so the same
  /// gap can never be charged twice.
  static Future<int> applyMissedDayFreeze({
    String? userId,
    DateTime? now,
  }) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final streak = prefs.getInt(_streakKey(uid)) ?? 0;
      if (streak <= 0) return 0;

      // Users who built a streak before this feature existed only have the
      // legacy last habit date; it is copied over once and reused afterwards.
      final lastStr = await _migrateLegacyLastDate(prefs, uid);
      final last = _parseDate(lastStr);
      if (last == null) return 0;

      final reference = now ?? DateTime.now();
      final today = DateTime(
        reference.year,
        reference.month,
        reference.day,
      );
      final yesterday = DateTime(today.year, today.month, today.day - 1);
      if (!last.isBefore(yesterday)) return 0;

      final missed = _capGapToElapsed(
        prefs,
        uid,
        yesterday.difference(last).inDays,
        reference,
      );
      if (missed <= 0) return 0;

      final available = prefs.getInt(_countKey(uid)) ?? 0;
      if (available < missed) return 0;

      final frozen = prefs.getStringList(_frozenDatesKey(uid)) ?? <String>[];
      for (var i = 1; i <= missed; i++) {
        frozen.add(formatDate(DateTime(last.year, last.month, last.day + i)));
      }
      if (frozen.length > _maxFrozenHistory) {
        frozen.removeRange(0, frozen.length - _maxFrozenHistory);
      }

      await prefs.setStringList(_frozenDatesKey(uid), frozen);
      await prefs.setInt(_countKey(uid), available - missed);
      await prefs.setString(_streakLastDateKey(uid), formatDate(yesterday));
      // The covered days count as the new baseline for clock-change checks.
      await _writeLastAt(prefs, uid, reference);
      return missed;
    } catch (e) {
      debugPrint('StreakFreezeService.applyMissedDayFreeze error: $e');
      return 0;
    }
  }

  /// Records that today had at least one completed habit.
  ///
  /// Called once per completed habit; extra calls on the same day are no-ops,
  /// so unticking and re-ticking can never inflate the streak. Returns the
  /// resulting streak length.
  static Future<int> recordCompletionDay({
    String? userId,
    DateTime? now,
  }) async {
          final uid = userId ?? GamificationService.currentUserId;
      try {
        final prefs = await SharedPreferences.getInstance();
        final moment = now ?? DateTime.now();
        final today = DateTime(moment.year, moment.month, moment.day);
        final todayStr = formatDate(today);
        final yesterdayStr = formatDate(
          DateTime(today.year, today.month, today.day - 1),
        );

        final streak = prefs.getInt(_streakKey(uid)) ?? 0;
        var lastStr = await _migrateLegacyLastDate(prefs, uid);

        if (lastStr == todayStr) {
          // Already counted today. Repair a missing/inconsistent value only.
          if (streak > 0) return streak;
          await prefs.setString(_streakLastDateKey(uid), todayStr);
          await _writeLastAt(prefs, uid, moment);
          await _writeStreak(prefs, uid, 1);
          return 1;
        }

        // The stored day is ahead of today: the device date moved backwards
        // (timezone travel, DST or a manual change). Today was already lived
        // and counted, so keep the streak instead of restarting it at 1.
        if (lastStr != null && lastStr.compareTo(todayStr) > 0) {
          if (streak > 0) return streak;
          await prefs.setString(_streakLastDateKey(uid), todayStr);
          await _writeLastAt(prefs, uid, moment);
          await _writeStreak(prefs, uid, 1);
          return 1;
        }

        // A calendar gap wider than the real time that elapsed can only come
        // from the device clock or timezone jumping forward. The user did
        // nothing wrong, so today counts as the next lived day instead of a
        // broken streak.
        if (lastStr != yesterdayStr) {
          final last = _parseDate(lastStr);
          final lastAt = _parseInstant(prefs.getString(_lastAtKey(uid)));
          if (last != null && lastAt != null) {
            final gap = today.difference(last).inDays;
            if (gap > elapsedWholeDays(lastAt, moment) + 1) {
              lastStr = yesterdayStr;
            }
          }
        }

        int nextStreak;
        if (lastStr == yesterdayStr) {
          nextStreak = streak > 0 ? streak + 1 : 1;
        } else if (lastStr == null) {
          // Legacy user: keep the stored streak instead of resetting it.
          nextStreak = streak > 0 ? streak : 1;
        } else {
          nextStreak = 1;
        }

        await prefs.setString(_streakLastDateKey(uid), todayStr);
        await _writeLastAt(prefs, uid, moment);
        await _writeStreak(prefs, uid, nextStreak);
        return nextStreak;
    } catch (e) {
      debugPrint('StreakFreezeService.recordCompletionDay error: $e');
      return 0;
    }
  }

  static Future<void> _writeStreak(
    SharedPreferences prefs,
    String uid,
    int streak,
  ) async {
    await prefs.setInt(_streakKey(uid), streak);
    // Kept in sync for the leaderboard / widget readers.
    await prefs.setInt('app_streak_days', streak);
  }

  /// Records the real UTC instant behind the stored completion day.
  static Future<void> _writeLastAt(
    SharedPreferences prefs,
    String uid,
    DateTime moment,
  ) async {
    await prefs.setString(_lastAtKey(uid), moment.toUtc().toIso8601String());
  }

  static Future<int> currentStreak({String? userId}) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getInt(_streakKey(uid)) ?? 0;
    } catch (_) {
      return 0;
    }
  }

  /// Dates whose missed day was covered by a freeze, oldest first.
  static Future<List<String>> frozenDates({String? userId}) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(_frozenDatesKey(uid)) ?? <String>[];
    } catch (_) {
      return <String>[];
    }
  }
}
