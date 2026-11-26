import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/gamification_service.dart';
import 'package:synvero/core/services/language_service.dart';
import 'package:synvero/core/services/notification_service.dart';

/// A concrete decision to nudge the user before their streak breaks.
class StreakRiskPlan {
  const StreakRiskPlan({
    required this.fireAt,
    required this.remainingHabits,
    required this.streakDays,
  });

  /// Moment the reminder should fire.
  final DateTime fireAt;

  /// Habits still pending when the plan was made.
  final int remainingHabits;

  /// Streak length being protected.
  final int streakDays;
}

/// Schedules at most one "your streak is at risk" nudge per day, timed from the
/// hour at which the user usually finishes their habits.
///
/// The service only *reads* completion state: it never marks a habit done, never
/// grants XP and never touches the 24h lock, so it can't interfere with the
/// anti-farming rules.
class StreakRiskReminderService {
  StreakRiskReminderService._();

  /// Fixed notification id so a re-plan replaces the previous nudge.
  static const int notificationId = 9200;

  /// How many learned completion days are kept.
  static const int maxSamples = 30;

  /// Used until enough history exists.
  static const int defaultHour = 20;

  /// Reminders stay inside waking hours.
  static const int earliestHour = 9;
  static const int latestHour = 22;

  /// If the usual time already passed, nudge this long from now instead.
  static const Duration lateGrace = Duration(minutes: 45);

  static String _samplesKey(String userId) =>
      'user_${userId}_streak_risk_hours_v1';
  static String _lastRemindedKey(String userId) =>
      'user_${userId}_streak_risk_last_reminded_v1';

  /// Last planned nudge (owner, remaining habits, streak, planned day).
  ///
  /// A background isolate can start when the phone's timezone changes, so the
  /// plan has to be re-creatable without the dashboard being open.
  static const String pendingKey = 'streak_risk_pending_v1';

  static String formatDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final month = d.month.toString().padLeft(2, '0');
    final day = d.day.toString().padLeft(2, '0');
    return '${d.year}-$month-$day';
  }

  /// Remembers the hour at which the user actually completed a habit.
  ///
  /// One sample per calendar day is enough to learn a routine: completing five
  /// habits in the evening should not outweigh five days of evening finishes.
  static Future<void> recordCompletionMoment({
    String? userId,
    DateTime? now,
  }) async {
    final uid = userId ?? GamificationService.currentUserId;
    final moment = now ?? DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      final dateStr = formatDate(moment);
      final entries = prefs.getStringList(_samplesKey(uid)) ?? <String>[];

      entries.removeWhere((e) => e.startsWith('$dateStr:'));
      entries.add('$dateStr:${moment.hour}');

      if (entries.length > maxSamples) {
        entries.removeRange(0, entries.length - maxSamples);
      }
      await prefs.setStringList(_samplesKey(uid), entries);
    } catch (e) {
      debugPrint('StreakRiskReminderService.recordCompletionMoment error: $e');
    }
  }

  /// Learned completion hours, oldest first.
  static Future<List<int>> completionHours({String? userId}) async {
    final uid = userId ?? GamificationService.currentUserId;
    try {
      final prefs = await SharedPreferences.getInstance();
      final entries = prefs.getStringList(_samplesKey(uid)) ?? <String>[];
      return entries
          .map((e) => int.tryParse(e.split(':').last))
          .whereType<int>()
          .where((h) => h >= 0 && h <= 23)
          .toList();
    } catch (_) {
      return <int>[];
    }
  }

  /// Median completion hour, clamped to a sensible waking window.
  static int typicalCompletionHour(List<int> samples) {
    if (samples.isEmpty) return defaultHour;
    final sorted = List<int>.from(samples)..sort();
    final median = sorted[sorted.length ~/ 2];
    return median.clamp(earliestHour, latestHour);
  }

  /// Decides whether a nudge is worth scheduling.
  ///
  /// Returns null when there is nothing to protect (no streak, everything done,
  /// already nudged today) or when the useful window has closed.
  static StreakRiskPlan? planFor({
    required int remainingHabits,
    required int streakDays,
    required DateTime now,
    required List<int> samples,
    String? alreadyRemindedOn,
  }) {
    if (remainingHabits <= 0) return null;
    if (streakDays <= 0) return null;

    final today = formatDate(now);
    // `>=` also covers a stored day ahead of today, i.e. the device date moved
    // backwards: that local day was already nudged, so never send a second one.
    if (alreadyRemindedOn != null &&
        alreadyRemindedOn.compareTo(today) >= 0) {
      return null;
    }

    final hour = typicalCompletionHour(samples);
    var fireAt = DateTime(now.year, now.month, now.day, hour);

    // Usual time has passed: one short grace nudge instead of nothing.
    if (!fireAt.isAfter(now)) {
      fireAt = now.add(lateGrace);
      final cutoff = DateTime(now.year, now.month, now.day, 23, 15);
      if (fireAt.isAfter(cutoff)) return null;
    }

    return StreakRiskPlan(
      fireAt: fireAt,
      remainingHabits: remainingHabits,
      streakDays: streakDays,
    );
  }

  /// Re-plans today's nudge and hands it to the OS scheduler.
  ///
  /// Safe to call on every app open and after every habit toggle; it always
  /// cancels the previous plan first so only one nudge can ever be pending.
  static Future<void> refreshForToday({
    String? userId,
    required int remainingHabits,
    required int streakDays,
    DateTime? now,
  }) async {
    final uid = userId ?? GamificationService.currentUserId;
    final moment = now ?? DateTime.now();
    try {
      await NotificationService.cancelHabitReminder(notificationId);

      final prefs = await SharedPreferences.getInstance();
      final samples = await completionHours(userId: uid);
      final plan = planFor(
        remainingHabits: remainingHabits,
        streakDays: streakDays,
        now: moment,
        samples: samples,
        alreadyRemindedOn: prefs.getString(_lastRemindedKey(uid)),
      );
      if (plan == null) return;

      final copy = _copyFor(plan, LanguageService.currentLanguageCode);
      await NotificationService.scheduleHabitReminder(
        id: notificationId,
        title: copy.title,
        body: copy.body,
        scheduledDate: plan.fireAt,
      );
      await prefs.setString(_lastRemindedKey(uid), formatDate(moment));
      await prefs.setString(
        pendingKey,
        jsonEncode(<String, Object>{
          'uid': uid,
          'remaining': plan.remainingHabits,
          'streak': plan.streakDays,
          'reminded': formatDate(moment),
        }),
      );
    } catch (e) {
      debugPrint('StreakRiskReminderService.refreshForToday error: $e');
    }
  }

  /// Re-plans the pending nudge in the device's *current* timezone.
  ///
  /// Android fires `ACTION_TIMEZONE_CHANGED` / `ACTION_TIME_SET` and the native
  /// receiver starts a background isolate for this method, so the reminder
  /// moves to the new local wall-clock time without the user opening the app.
  /// Scheduled alarms themselves keep the instant they were armed with, and the
  /// notifications plugin re-arms them using the timezone name saved at
  /// scheduling time, so the plan has to be built again from scratch.
  ///
  /// [scheduler] exists for tests; production uses the notification service.
  static Future<StreakRiskPlan?> rescheduleAfterTimezoneChange({
    DateTime? now,
    StreakReminderScheduler? scheduler,
  }) async {
    final moment = now ?? DateTime.now();
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(pendingKey);
      if (raw == null) return null;

      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;

      final uid = decoded['uid'] as String? ??
          GamificationService.currentUserId;
      final remainingHabits = (decoded['remaining'] as num?)?.toInt() ?? 0;
      final streakDays = (decoded['streak'] as num?)?.toInt() ?? 0;
      final remindedOn = decoded['reminded'] as String?;

      final today = formatDate(moment);
      final remindedDay = DateTime.tryParse(remindedOn ?? '');

      // A plan older than a day no longer describes today's situation; drop it
      // instead of nudging with yesterday's numbers.
      if (remindedDay != null) {
        final age = DateTime(moment.year, moment.month, moment.day)
            .difference(
              DateTime(
                remindedDay.year,
                remindedDay.month,
                remindedDay.day,
              ),
            )
            .inDays;
        if (age > 1 || age < 0) {
          // Ahead of today means the date moved backwards: that local day was
          // already nudged, so never repeat it.
          await NotificationService.cancelHabitReminder(notificationId);
          await prefs.remove(pendingKey);
          return null;
        }
      }

      // Replace whatever was pending: the old instant no longer matches the
      // local time the user expects.
      await NotificationService.cancelHabitReminder(notificationId);

      final plan = planFor(
        remainingHabits: remainingHabits,
        streakDays: streakDays,
        now: moment,
        samples: await completionHours(userId: uid),
        alreadyRemindedOn: null,
      );
      if (plan == null) {
        await prefs.remove(pendingKey);
        return null;
      }

      final copy = _copyFor(plan, LanguageService.currentLanguageCode);
      final schedule = scheduler ?? _scheduleWithNotificationService;
      await schedule(
        id: notificationId,
        title: copy.title,
        body: copy.body,
        scheduledDate: plan.fireAt,
      );

      await prefs.setString(_lastRemindedKey(uid), today);
      await prefs.setString(
        pendingKey,
        jsonEncode(<String, Object>{
          'uid': uid,
          'remaining': plan.remainingHabits,
          'streak': plan.streakDays,
          'reminded': today,
        }),
      );
      return plan;
    } catch (e) {
      debugPrint(
        'StreakRiskReminderService.rescheduleAfterTimezoneChange error: $e',
      );
      return null;
    }
  }

  static Future<void> _scheduleWithNotificationService({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) =>
      NotificationService.scheduleHabitReminder(
        id: id,
        title: title,
        body: body,
        scheduledDate: scheduledDate,
      );

  /// Drops the pending nudge (e.g. after the user completes everything).
  static Future<void> cancel() async {
    try {
      await NotificationService.cancelHabitReminder(notificationId);
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(pendingKey);
    } catch (e) {
      debugPrint('StreakRiskReminderService.cancel error: $e');
    }
  }

  static _ReminderCopy _copyFor(StreakRiskPlan plan, String lang) {
    final days = plan.streakDays;
    final left = plan.remainingHabits;
    if (lang == LanguageService.marathi) {
      return _ReminderCopy(
        title: '🔥 स्ट्रिक धोक्यात आहे!',
        body:
            '$days दिवसांची स्ट्रिक आज तुटू शकते. $left हॅबिट्स शिल्लक — फक्त १ टॅप करा.',
      );
    }
    if (lang == LanguageService.hindi) {
      return _ReminderCopy(
        title: '🔥 स्ट्रीक खतरे में है!',
        body:
            '$days दिन की स्ट्रीक आज टूट सकती है। $left आदतें बाकी हैं — बस 1 टैप करें।',
      );
    }
    return _ReminderCopy(
      title: '🔥 Streak at risk!',
      body:
          'Your $days-day streak ends tonight. $left habit${left == 1 ? '' : 's'} left — one tap keeps it alive.',
    );
  }
}

class _ReminderCopy {
  const _ReminderCopy({required this.title, required this.body});

  final String title;
  final String body;
}

/// Hands a re-planned nudge to the OS scheduler.
///
/// Injected in tests so the timezone logic can be checked without platform
/// channels.
typedef StreakReminderScheduler = Future<void> Function({
  required int id,
  required String title,
  required String body,
  required DateTime scheduledDate,
});
