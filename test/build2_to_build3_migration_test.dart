import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/gamification_service.dart';
import 'package:synvero/core/services/habit_daily_service.dart';
import 'package:synvero/core/services/streak_freeze_service.dart';

/// Build 3 added streak freeze, so the streak moved to new keys
/// (`user_<uid>_streak_last_date_v1`, freeze counters) while build 2 only ever
/// wrote `user_<uid>_last_habit_date` and `user_<uid>_streak_days`.
///
/// These tests boot build 3 on a raw build-2 SharedPreferences snapshot and
/// prove that nothing the user earned is lost during the in-app upgrade.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String uid = 'legacy-42';

  String streakKey() => 'user_${uid}_streak_days';
  String lastActiveKey() => 'user_${uid}_last_habit_date';
  String lastStreakKey() => 'user_${uid}_streak_last_date_v1';
  String countKey() => 'user_${uid}_streak_freezes_v1';
  String weekKey() => 'user_${uid}_streak_freeze_week_v1';
  String frozenKey() => 'user_${uid}_streak_frozen_dates_v1';
  String xpKey() => 'user_${uid}_gamification_xp_v1';

  String date(DateTime d) => StreakFreezeService.formatDate(d);
  String today() => date(DateTime.now());
  String daysAgo(int days) =>
      date(DateTime.now().subtract(Duration(days: days)));

  /// Everything build 2 could have written, and nothing build 3 knows about.
  Map<String, Object> build2Snapshot({
    required String lastActive,
    int streak = 12,
    int xp = 2740,
  }) =>
      <String, Object>{
        streakKey(): streak,
        'app_streak_days': streak,
        lastActiveKey(): lastActive,
        xpKey(): xp,
        'user_${uid}_unlocked_badges_v1': <String>[
          'first_step',
          'streak_warrior_7',
        ],
        'user_${uid}_timer_completed_sessions': 4,
        'user_${uid}_focus_duration_mins': 25,
        // Today's habit was ticked on build 2.
        'user_${uid}_habit_def-1_completed_${today()}': true,
        'user_${uid}_habit_def-1_completed_at':
            DateTime.now().toIso8601String(),
        'user_${uid}_habit_def-1_completed': true,
        'user_${uid}_xp_claimed_habit_def-1_${today()}': true,
      };

  setUp(() async {
    await GamificationService.loadXP(userId: uid);
  });

  group('build 2 data survives the build 3 upgrade', () {
    test('XP, badges, habits and anti-farming claims are untouched', () async {
      SharedPreferences.setMockInitialValues(
        build2Snapshot(lastActive: daysAgo(1)),
      );

      expect(await GamificationService.loadXP(userId: uid), 2740);
      expect(GamificationService.totalXPNotifier.value, 2740);

      final Set<String> badges = await GamificationService.getUnlockedBadgeIds(
        userId: uid,
      );
      expect(badges, containsAll(<String>['first_step', 'streak_warrior_7']));

      expect(await HabitDailyService.isHabitCompletedToday(uid, 'def-1'), isTrue);

      // Build 2 already paid XP for this habit today. The upgrade must keep
      // that claim, otherwise the same habit could be farmed once more.
      await HabitDailyService.verifyAndPerformMidnightReset(uid);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(xpKey()), 2740);
      expect(
        prefs.getBool('user_${uid}_xp_claimed_habit_def-1_${today()}'),
        isTrue,
      );
      expect(
        prefs.getBool('user_guest_xp_claimed_habit_def-1_${today()}'),
        isNot(isTrue),
        reason: 'the claim must stay attached to the account that earned it',
      );
    });

    test('the streak is not reset on the first launch after upgrading',
        () async {
      SharedPreferences.setMockInitialValues(
        build2Snapshot(lastActive: daysAgo(1)),
      );

      final bool rolledOver =
          await HabitDailyService.verifyAndPerformMidnightReset(uid);

      expect(rolledOver, isTrue);
      expect(await StreakFreezeService.currentStreak(userId: uid), 12);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 12);
      expect(prefs.getInt('app_streak_days'), 12);
    });

    test('a migrated streak keeps growing and never double counts a day',
        () async {
      SharedPreferences.setMockInitialValues(
        build2Snapshot(lastActive: daysAgo(1)),
      );

      await HabitDailyService.verifyAndPerformMidnightReset(uid);

      expect(await StreakFreezeService.recordCompletionDay(userId: uid), 13);
      // A second habit completed on the same day must not add another day.
      expect(await StreakFreezeService.recordCompletionDay(userId: uid), 13);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 13);
      expect(prefs.getString(lastStreakKey()), today());
    });

    test('a legacy streak survives a gap that one weekly freeze covers',
        () async {
      SharedPreferences.setMockInitialValues(
        build2Snapshot(lastActive: daysAgo(2), streak: 9),
      );

      await HabitDailyService.verifyAndPerformMidnightReset(uid);

      expect(await StreakFreezeService.currentStreak(userId: uid), 9);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      // One freeze granted for the new week, immediately spent on the gap.
      expect(prefs.getInt(countKey()), 0);
      expect(prefs.getStringList(frozenKey()), <String>[daysAgo(1)]);
      expect(await StreakFreezeService.recordCompletionDay(userId: uid), 10);
    });

    test('a long absence still breaks the streak honestly', () async {
      SharedPreferences.setMockInitialValues(
        build2Snapshot(lastActive: daysAgo(5), streak: 9),
      );

      await HabitDailyService.verifyAndPerformMidnightReset(uid);

      expect(await StreakFreezeService.currentStreak(userId: uid), 0);
    });

    test('a freeze bank from a later build is never cleared by the upgrade',
        () async {
      final Map<String, Object> snapshot = build2Snapshot(
        lastActive: daysAgo(1),
      );
      snapshot[countKey()] = 2;
      snapshot[weekKey()] = StreakFreezeService.weekKeyFor(DateTime.now());
      SharedPreferences.setMockInitialValues(snapshot);

      expect(await StreakFreezeService.availableFreezes(userId: uid), 2);

      await HabitDailyService.verifyAndPerformMidnightReset(uid);
      // Yesterday was completed, so no freeze is spent.
      expect(await StreakFreezeService.availableFreezes(userId: uid), 2);
    });

    test('a user who upgraded and already ticked today stays consistent',
        () async {
      // Build 2 was last active today: the rollover is a no-op, and the
      // day must not be counted twice once the habit is ticked on build 3.
      SharedPreferences.setMockInitialValues(
        build2Snapshot(lastActive: today(), streak: 6),
      );

      expect(await HabitDailyService.verifyAndPerformMidnightReset(uid),
          isFalse);
      expect(await StreakFreezeService.currentStreak(userId: uid), 6);
      expect(await StreakFreezeService.recordCompletionDay(userId: uid), 6);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(lastStreakKey()), today());
    });
  });
}
