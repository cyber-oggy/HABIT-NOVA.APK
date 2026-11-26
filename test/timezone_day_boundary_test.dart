import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/gamification_service.dart';
import 'package:synvero/core/services/habit_daily_service.dart';
import 'package:synvero/core/services/streak_freeze_service.dart';
import 'package:synvero/core/services/streak_risk_service.dart';

/// The day boundary is the device-local calendar date, so a timezone change,
/// DST transition or a manually moved clock must never count one day twice or
/// silently drop a day.
///
/// The rule the app follows: a date the user actually lived through counts at
/// most once, and days the user never lived through (a forward clock jump)
/// never cost a freeze or break a streak.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String uid = 'tz-user';

  String streakKey() => 'user_${uid}_streak_days';
  String lastDateKey() => 'user_${uid}_streak_last_date_v1';
  String lastAtKey() => 'user_${uid}_streak_last_at_v1';
  String countKey() => 'user_${uid}_streak_freezes_v1';
  String weekKey() => 'user_${uid}_streak_freeze_week_v1';
  String frozenKey() => 'user_${uid}_streak_frozen_dates_v1';
  String activeDateKey() => 'user_${uid}_last_habit_date';

  String day(int y, int m, int d) => StreakFreezeService.formatDate(
        DateTime(y, m, d),
      );

  String instant(DateTime moment) => moment.toUtc().toIso8601String();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await GamificationService.loadXP(userId: uid);
  });

  group('device date moves backwards (DST fall-back / travel west)', () {
    test('the streak is kept instead of restarting at 1', () async {
      final DateTime now = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 7,
        // Recorded "tomorrow" because the clock was ahead a moment ago.
        lastDateKey(): day(2026, 11, 27),
        lastAtKey(): instant(now.subtract(const Duration(hours: 1))),
      });

      expect(await StreakFreezeService.recordCompletionDay(userId: uid, now: now), 7);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 7);
      expect(
        prefs.getString(lastDateKey()),
        day(2026, 11, 27),
        reason: 'the stored day must not be rewritten by a backwards clock',
      );
    });

    test('the streak continues once the clock is back on the true date',
        () async {
      final DateTime firstOpen = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 7,
        lastDateKey(): day(2026, 11, 27),
        lastAtKey(): instant(firstOpen.subtract(const Duration(hours: 1))),
      });

      await StreakFreezeService.recordCompletionDay(
        userId: uid,
        now: firstOpen,
      );
      // That day was already lived and counted, so it is not counted twice.
      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 11, 27, 9),
        ),
        7,
      );
      // The next real day grows the streak normally.
      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 11, 28, 9),
        ),
        8,
      );
    });

    test('the midnight rollover is skipped, so no freeze is spent', () async {
      final DateTime now = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 7,
        lastDateKey(): day(2026, 11, 27),
        lastAtKey(): instant(now.subtract(const Duration(hours: 1))),
        countKey(): 2,
        weekKey(): StreakFreezeService.weekKeyFor(now),
        activeDateKey(): day(2026, 11, 27),
      });

      final bool rolledOver =
          await HabitDailyService.verifyAndPerformMidnightReset(uid, now: now);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(rolledOver, isFalse);
      expect(prefs.getInt(streakKey()), 7);
      expect(prefs.getInt(countKey()), 2);
      expect(prefs.getString(activeDateKey()), day(2026, 11, 27));
      expect(prefs.getStringList(frozenKey()), isNull);
    });

    test('no second streak nudge for a day that was already nudged', () async {
      final DateTime now = DateTime(2026, 11, 26, 10);

      expect(
        StreakRiskReminderService.planFor(
          remainingHabits: 2,
          streakDays: 5,
          now: now,
          samples: const <int>[20],
          alreadyRemindedOn: day(2026, 11, 27),
        ),
        isNull,
      );
      expect(
        StreakRiskReminderService.planFor(
          remainingHabits: 2,
          streakDays: 5,
          now: now,
          samples: const <int>[20],
          alreadyRemindedOn: day(2026, 11, 26),
        ),
        isNull,
        reason: 'one nudge per local day',
      );
      expect(
        StreakRiskReminderService.planFor(
          remainingHabits: 2,
          streakDays: 5,
          now: now,
          samples: const <int>[20],
          alreadyRemindedOn: day(2026, 11, 25),
        ),
        isNotNull,
      );
    });
  });

  group('device date jumps forward (timezone travel / manual clock)', () {
    test('a jumped date spends no freeze and does not break the streak',
        () async {
      final DateTime now = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 5,
        lastDateKey(): day(2026, 11, 23),
        // Only ten minutes of real time passed, so 24/25 never happened.
        lastAtKey(): instant(now.subtract(const Duration(minutes: 10))),
        countKey(): 3,
        weekKey(): StreakFreezeService.weekKeyFor(now),
      });

      expect(await StreakFreezeService.missedDays(userId: uid, now: now), 0);
      expect(
        await StreakFreezeService.applyMissedDayFreeze(userId: uid, now: now),
        0,
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), 3);
      expect(prefs.getStringList(frozenKey()), isNull);

      // Today is simply the next day the user lived.
      expect(
        await StreakFreezeService.recordCompletionDay(userId: uid, now: now),
        6,
      );
    });

    test('a real absence longer than the elapsed time still breaks it',
        () async {
      final DateTime now = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 9,
        lastDateKey(): day(2026, 11, 21),
        lastAtKey(): instant(now.subtract(const Duration(days: 5))),
        countKey(): 1,
        weekKey(): StreakFreezeService.weekKeyFor(now),
      });

      expect(await StreakFreezeService.missedDays(userId: uid, now: now), 4);
      expect(
        await StreakFreezeService.applyMissedDayFreeze(userId: uid, now: now),
        0,
        reason: 'one freeze cannot cover four missed days',
      );
      expect(
        await StreakFreezeService.recordCompletionDay(userId: uid, now: now),
        1,
      );
    });

    test('a genuine one-day gap is still covered by a freeze', () async {
      final DateTime now = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 5,
        lastDateKey(): day(2026, 11, 24),
        lastAtKey(): instant(now.subtract(const Duration(days: 2))),
        countKey(): 1,
        weekKey(): StreakFreezeService.weekKeyFor(now),
      });

      expect(await StreakFreezeService.missedDays(userId: uid, now: now), 1);
      expect(
        await StreakFreezeService.applyMissedDayFreeze(userId: uid, now: now),
        1,
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), 0);
      expect(prefs.getStringList(frozenKey()), <String>[day(2026, 11, 25)]);
    });
  });

  group('local day boundary', () {
    test('a date counts once even across a 23-hour DST day', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 3, 8, 0, 30),
        ),
        1,
      );
      // Same local date, 23 hours later (spring-forward day).
      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 3, 8, 23, 30),
        ),
        1,
      );
      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 3, 9, 0, 30),
        ),
        2,
      );
    });

    test('midnight is the only boundary, not 24 hours since the last tick',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});

      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 11, 26, 23, 59),
        ),
        1,
      );
      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 11, 27, 0, 1),
        ),
        2,
        reason: 'two minutes later, but a new local day',
      );
      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 11, 27, 0, 2),
        ),
        2,
      );
    });

    test('the rollover follows the local date, including just after midnight',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 3,
        lastDateKey(): day(2026, 11, 26),
        lastAtKey(): instant(DateTime(2026, 11, 26, 23, 50)),
        activeDateKey(): day(2026, 11, 26),
      });

      final bool rolledOver =
          await HabitDailyService.verifyAndPerformMidnightReset(
        uid,
        now: DateTime(2026, 11, 27, 0, 5),
      );

      expect(rolledOver, isTrue);
      expect(await StreakFreezeService.currentStreak(userId: uid), 3);
    });

    test('a 24h habit lock still spans the real 24 hours, not the day',
        () async {
      // The lock is intentionally time-based, so a timezone change must not
      // shorten it: the rules around XP farming stay exactly as before.
      expect(
        HabitDailyService.completionLockDuration,
        const Duration(hours: 24),
      );
    });
  });
}
