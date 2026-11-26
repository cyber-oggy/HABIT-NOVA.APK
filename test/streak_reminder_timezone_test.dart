import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/streak_risk_service.dart';

/// Android alarms keep the instant they were armed with, so after a timezone
/// change the pending "streak at risk" nudge would land at the old local hour.
/// `rescheduleAfterTimezoneChange` rebuilds the plan in the device's current
/// timezone; these tests drive that decision with an injected scheduler.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String uid = 'nudge-user';

  String samplesKey() => 'user_${uid}_streak_risk_hours_v1';
  String lastRemindedKey() => 'user_${uid}_streak_risk_last_reminded_v1';

  String day(int y, int m, int d) => StreakRiskReminderService.formatDate(
        DateTime(y, m, d),
      );

  Map<String, Object> withPending({
    int remaining = 2,
    int streak = 5,
    required String reminded,
    bool withSamples = true,
  }) =>
      <String, Object>{
        StreakRiskReminderService.pendingKey: jsonEncode(<String, Object>{
          'uid': uid,
          'remaining': remaining,
          'streak': streak,
          'reminded': reminded,
        }),
        if (withSamples) samplesKey(): <String>['2026-11-20:20'],
      };

  List<_Scheduled> scheduled = <_Scheduled>[];

  Future<void> fakeScheduler({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    scheduled.add(
      _Scheduled(id: id, title: title, body: body, at: scheduledDate),
    );
  }

  setUp(() {
    scheduled = <_Scheduled>[];
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('timezone change re-plans the pending nudge', () {
    test('moves it to the learned local hour of the new timezone', () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 26)),
      );

      final StreakRiskPlan? plan =
          await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(plan, isNotNull);
      expect(scheduled, hasLength(1));
      expect(scheduled.single.id, StreakRiskReminderService.notificationId);
      expect(scheduled.single.at, DateTime(2026, 11, 26, 20));
      expect(scheduled.single.title, isNotEmpty);
      expect(scheduled.single.body, contains('5'));

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(lastRemindedKey()), day(2026, 11, 26));
      final Map<String, dynamic> pending = jsonDecode(
        prefs.getString(StreakRiskReminderService.pendingKey)!,
      ) as Map<String, dynamic>;
      expect(pending['reminded'], day(2026, 11, 26));
      expect(pending['remaining'], 2);
    });

    test('the past hour becomes a short grace nudge instead of nothing',
        () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 26)),
      );
      final DateTime now = DateTime(2026, 11, 26, 21);

      await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: now,
        scheduler: fakeScheduler,
      );

      expect(scheduled, hasLength(1));
      expect(
        scheduled.single.at,
        now.add(StreakRiskReminderService.lateGrace),
      );
    });

    test('a late-evening change schedules nothing and clears the plan',
        () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 26)),
      );

      final StreakRiskPlan? plan =
          await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 23, 30),
        scheduler: fakeScheduler,
      );

      expect(plan, isNull);
      expect(scheduled, isEmpty);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StreakRiskReminderService.pendingKey), isNull);
    });

    test("yesterday's plan is still valid today", () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 25)),
      );

      await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(scheduled.single.at, DateTime(2026, 11, 26, 20));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(lastRemindedKey()), day(2026, 11, 26));
    });

    test('a default hour is used before any routine is learned', () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 26), withSamples: false),
      );

      await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(
        scheduled.single.at.hour,
        StreakRiskReminderService.defaultHour,
      );
    });
  });

  group('the re-plan never duplicates or resurrects a nudge', () {
    test('a date that moved backwards does not nudge again', () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 27)),
      );

      final StreakRiskPlan? plan =
          await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(plan, isNull);
      expect(scheduled, isEmpty);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StreakRiskReminderService.pendingKey), isNull);
    });

    test('an old plan is dropped instead of nudging with stale numbers',
        () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 20)),
      );

      await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(scheduled, isEmpty);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StreakRiskReminderService.pendingKey), isNull);
    });

    test('nothing pending means no scheduling at all', () async {
      final StreakRiskPlan? plan =
          await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(plan, isNull);
      expect(scheduled, isEmpty);
    });

    test('a completed day has nothing left to protect', () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 26), remaining: 0),
      );

      await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(scheduled, isEmpty);
    });

    test('a broken payload is ignored, not crashed on', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        StreakRiskReminderService.pendingKey: 'not-json',
      });

      final StreakRiskPlan? plan =
          await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );

      expect(plan, isNull);
      expect(scheduled, isEmpty);
    });

    test('two timezone changes replace one nudge, never add a second',
        () async {
      SharedPreferences.setMockInitialValues(
        withPending(reminded: day(2026, 11, 26)),
      );

      await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 10),
        scheduler: fakeScheduler,
      );
      await StreakRiskReminderService.rescheduleAfterTimezoneChange(
        now: DateTime(2026, 11, 26, 11),
        scheduler: fakeScheduler,
      );

      expect(scheduled, hasLength(2));
      expect(
        scheduled.every(
          (_Scheduled s) => s.id == StreakRiskReminderService.notificationId,
        ),
        isTrue,
        reason: 'the same notification id is replaced, not duplicated',
      );
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StreakRiskReminderService.pendingKey), isNotNull);
    });
  });
}

class _Scheduled {
  const _Scheduled({
    required this.id,
    required this.title,
    required this.body,
    required this.at,
  });

  final int id;
  final String title;
  final String body;
  final DateTime at;
}
