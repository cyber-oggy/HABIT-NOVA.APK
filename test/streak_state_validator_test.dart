import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/streak_freeze_service.dart';
import 'package:synvero/core/services/streak_state_validator.dart';

/// The validator runs on every launch, before the dashboard reads streak,
/// freeze or XP state. It must repair only impossible combinations and must
/// never throw away progress or touch the freeze economy.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String uid = 'validator-user';

  String streakKey() => 'user_${uid}_streak_days';
  String dayKey() => 'user_${uid}_streak_last_date_v1';
  String instantKey() => 'user_${uid}_streak_last_at_v1';
  String legacyDayKey() => 'user_${uid}_last_habit_date';
  String freezeKey() => 'user_${uid}_streak_freezes_v1';
  String frozenKey() => 'user_${uid}_streak_frozen_dates_v1';
  String xpKey() => 'user_${uid}_gamification_xp_v1';

  final DateTime now = DateTime(2026, 11, 26, 10);
  String day(int y, int m, int d) =>
      StreakFreezeService.formatDate(DateTime(y, m, d));

  Future<StreakStateReport> run() =>
      StreakStateValidator.validateAndRepair(userId: uid, now: now);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('clean state is left untouched', () {
    test('no writes and no repairs', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 4,
        dayKey(): day(2026, 11, 26),
        instantKey(): DateTime(2026, 11, 26, 9).toUtc().toIso8601String(),
        freezeKey(): 2,
        frozenKey(): <String>[day(2026, 11, 24)],
        'app_streak_days': 4,
        xpKey(): 2730,
      });

      final StreakStateReport report = await run();

      expect(report.changed, isFalse);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 4);
      expect(prefs.getString(dayKey()), day(2026, 11, 26));
      expect(prefs.getInt(freezeKey()), 2);
      expect(prefs.getInt(xpKey()), 2730);
    });

    test('running twice is idempotent', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 5,
        freezeKey(): 9,
        'app_streak_days': 1,
      });

      final StreakStateReport first = await run();
      final StreakStateReport second = await run();

      expect(first.changed, isTrue);
      expect(second.changed, isFalse);
    });
  });

  group('streak repairs keep progress', () {
    test('a negative streak is reset to zero', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): -3,
        'app_streak_days': -3,
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 0);
      expect(prefs.getInt('app_streak_days'), 0);
      expect(report.repairs, contains(StreakStateRepair.negativeStreak));
    });

    test('a streak with no day is dated yesterday, not today', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 5,
        'app_streak_days': 5,
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 5, reason: 'never discard the streak');
      expect(prefs.getString(dayKey()), day(2026, 11, 25));
      expect(report.repairs, contains(StreakStateRepair.seededMissingDay));

      // And the streak can still grow today.
      expect(
        await StreakFreezeService.recordCompletionDay(userId: uid, now: now),
        6,
      );
    });

    test('the legacy habit date is adopted before inventing one', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 7,
        legacyDayKey(): day(2026, 11, 20),
        'app_streak_days': 7,
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(dayKey()), day(2026, 11, 20));
      expect(
        report.repairs,
        contains(StreakStateRepair.seededDayFromLegacy),
      );
      expect(prefs.getInt(streakKey()), 7);
    });

    test('a day far in the future is clamped but a one-day jump is kept',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 3,
        dayKey(): day(2026, 11, 30),
        'app_streak_days': 3,
      });

      expect(
        (await run()).repairs,
        contains(StreakStateRepair.clampedFutureDay),
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(dayKey()), day(2026, 11, 26));
      expect(prefs.getInt(streakKey()), 3);

      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 3,
        dayKey(): day(2026, 11, 27),
        'app_streak_days': 3,
      });
      final StreakStateReport travel = await run();
      expect(travel.changed, isFalse);
      final SharedPreferences travelPrefs = await SharedPreferences.getInstance();
      expect(
        travelPrefs.getString(dayKey()),
        day(2026, 11, 27),
        reason: 'a timezone jump can legitimately put the day one ahead',
      );
    });

    test('junk in the day slot is cleared when there is no streak', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        dayKey(): 'not-a-date',
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(dayKey()), isNull);
      expect(report.repairs, contains(StreakStateRepair.clearedInvalidDay));
    });
  });

  group('completion instant repairs', () {
    test('a future instant is pulled back to now', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 2,
        dayKey(): day(2026, 11, 26),
        instantKey(): DateTime(2026, 12, 5).toUtc().toIso8601String(),
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString(instantKey()),
        now.toUtc().toIso8601String(),
      );
      expect(report.repairs, contains(StreakStateRepair.resetFutureInstant));
    });

    test('an unparseable instant is removed', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 1,
        dayKey(): day(2026, 11, 26),
        instantKey(): 'yesterday-ish',
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(instantKey()), isNull);
      expect(
        report.repairs,
        contains(StreakStateRepair.clearedInvalidInstant),
      );
    });
  });

  group('freeze bank repairs', () {
    test('a bank above the cap is clamped without granting anything', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        freezeKey(): 7,
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(freezeKey()), StreakFreezeService.maxFreezes);
      expect(
        report.repairs,
        contains(StreakStateRepair.clampedFreezeCount),
      );
    });

    test('a negative bank becomes zero', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        freezeKey(): -2,
      });

      await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(freezeKey()), 0);
    });

    test('an over-long frozen history is trimmed to the newest entries',
        () async {
      final List<String> frozen = List<String>.generate(
        75,
        (int i) => '2026-09-${(i % 28 + 1).toString().padLeft(2, '0')}',
      );
      SharedPreferences.setMockInitialValues(<String, Object>{
        frozenKey(): frozen,
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final List<String> trimmed = prefs.getStringList(frozenKey())!;
      expect(trimmed, hasLength(StreakStateValidator.maxFrozenHistory));
      expect(trimmed.last, frozen.last);
      expect(
        report.repairs,
        contains(StreakStateRepair.trimmedFrozenHistory),
      );
    });

    test('the validator never changes XP', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        xpKey(): 1800,
        streakKey(): 4,
        freezeKey(): 99,
      });

      await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(xpKey()), 1800);
    });
  });

  group('global streak mirror', () {
    test('is resynced from this account and back-filled when missing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 4,
        'app_streak_days': 9,
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('app_streak_days'), 4);
      expect(report.repairs, contains(StreakStateRepair.syncedGlobalStreak));

      await prefs.remove('app_streak_days');
      final StreakStateReport backfilled = await run();
      expect(prefs.getInt('app_streak_days'), 4);
      expect(
        backfilled.repairs,
        contains(StreakStateRepair.syncedGlobalStreak),
      );
    });

    test('a global-only value is never claimed by an account', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'app_streak_days': 5,
      });

      final StreakStateReport report = await run();

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('app_streak_days'), 5);
      expect(prefs.getInt(streakKey()), isNull);
      expect(report.changed, isFalse);
    });
  });

  test('state written by the freeze service needs no repairs', () async {
    await StreakFreezeService.availableFreezes(
      userId: uid,
      now: now,
    );
    await StreakFreezeService.recordCompletionDay(userId: uid, now: now);

    final StreakStateReport report = await run();

    expect(report.changed, isFalse);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(streakKey()), 1);
    expect(prefs.getString(dayKey()), day(2026, 11, 26));
    expect(prefs.getInt(freezeKey()), 1);
  });
}
