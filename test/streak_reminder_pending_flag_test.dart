import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/gamification_service.dart';
import 'package:synvero/core/services/streak_risk_service.dart';

/// `TimezoneRescheduleReceiver` decides natively whether to start a Flutter
/// engine by looking for the pending plan in shared preferences. These tests
/// pin the Dart half of that contract: a planned nudge leaves the flag behind,
/// and every path that removes the nudge also removes the flag.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String uid = 'flag-user';

  String samplesKey() => 'user_${uid}_streak_risk_hours_v1';

  String day(int y, int m, int d) =>
      StreakRiskReminderService.formatDate(DateTime(y, m, d));

  Future<Map<String, dynamic>?> pending() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw =
        prefs.getString(StreakRiskReminderService.pendingKey);
    if (raw == null) return null;
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      samplesKey(): <String>['2026-11-20:20'],
    });
  });

  test('the flag key is the one the native receiver reads', () {
    // Native: "flutter." + this key inside FlutterSharedPreferences.
    expect(StreakRiskReminderService.pendingKey, 'streak_risk_pending_v1');
  });

  group('planning a nudge arms the native preflight', () {
    test('a pending habit writes the flag', () async {
      await StreakRiskReminderService.refreshForToday(
        userId: uid,
        remainingHabits: 2,
        streakDays: 5,
        now: DateTime(2026, 11, 26, 10),
      );

      final Map<String, dynamic>? flag = await pending();
      expect(flag, isNotNull, reason: 'native must see a pending reminder');
      expect(flag!['uid'], uid);
      expect(flag['remaining'], 2);
      expect(flag['streak'], 5);
      expect(flag['reminded'], day(2026, 11, 26));
    });

    test('everything completed leaves the flag empty', () async {
      await StreakRiskReminderService.refreshForToday(
        userId: uid,
        remainingHabits: 0,
        streakDays: 5,
        now: DateTime(2026, 11, 26, 10),
      );

      expect(await pending(), isNull);
    });

    test('no streak means nothing to protect and no flag', () async {
      await StreakRiskReminderService.refreshForToday(
        userId: uid,
        remainingHabits: 3,
        streakDays: 0,
        now: DateTime(2026, 11, 26, 10),
      );

      expect(await pending(), isNull);
    });

    test('re-planning replaces the single flag instead of adding one', () async {
      await StreakRiskReminderService.refreshForToday(
        userId: uid,
        remainingHabits: 3,
        streakDays: 4,
        now: DateTime(2026, 11, 26, 10),
      );
      // A new local day is allowed to nudge again and must replace the flag.
      await StreakRiskReminderService.refreshForToday(
        userId: uid,
        remainingHabits: 1,
        streakDays: 4,
        now: DateTime(2026, 11, 27, 11),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, dynamic> flag = await pending() ?? <String, dynamic>{};
      expect(flag['remaining'], 1);
      expect(flag['reminded'], day(2026, 11, 27));
      expect(
        prefs
            .getKeys()
            .where((String k) => k == StreakRiskReminderService.pendingKey)
            .length,
        1,
      );
    });
  });

  group('clearing the nudge clears the preflight', () {
    test('cancel removes the flag so no engine is started later', () async {
      await StreakRiskReminderService.refreshForToday(
        userId: uid,
        remainingHabits: 2,
        streakDays: 5,
        now: DateTime(2026, 11, 26, 10),
      );
      expect(await pending(), isNotNull);

      await StreakRiskReminderService.cancel();

      expect(await pending(), isNull);
      expect(
        StreakRiskReminderService.rescheduleAfterTimezoneChange(
          now: DateTime(2026, 11, 26, 12),
          scheduler: ({
            required int id,
            required String title,
            required String body,
            required DateTime scheduledDate,
          }) async {},
        ),
        completion(isNull),
      );
    });

    test('a timezone change with no flag never creates one', () async {
      await GamificationService.loadXP(userId: uid);

      final plan =
          await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 12),
        scheduler: ({
          required int id,
          required String title,
          required String body,
          required DateTime scheduledDate,
        }) async {},
      );

      expect(plan, isNull);
      expect(await pending(), isNull);
    });
  });
}
