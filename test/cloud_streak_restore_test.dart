import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:synvero/core/services/gamification_service.dart';
import 'package:synvero/core/services/leaderboard_service.dart';
import 'package:synvero/core/services/streak_freeze_service.dart';

/// The dashboard calls `restoreFromCloud` on every launch, before the midnight
/// rollover. The cloud leaderboard document is a backup snapshot, so restoring
/// it must never lower progress made on this device and must never rewrite the
/// local completion day that freeze and streak maths depend on.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const String uid = 'restore-user';

  String xpKey() => 'user_${uid}_gamification_xp_v1';
  String streakKey() => 'user_${uid}_streak_days';
  String lastDateKey() => 'user_${uid}_streak_last_date_v1';
  String lastAtKey() => 'user_${uid}_streak_last_at_v1';
  String countKey() => 'user_${uid}_streak_freezes_v1';
  String frozenKey() => 'user_${uid}_streak_frozen_dates_v1';

  String day(int y, int m, int d) => StreakFreezeService.formatDate(
        DateTime(y, m, d),
      );

  /// Firestore-shaped document used by the leaderboard sync.
  String firestoreDoc({
    required int xp,
    required int streak,
    int? freezes,
  }) =>
      jsonEncode(
        <String, dynamic>{
          'fields': <String, dynamic>{
            'xp': <String, String>{'integerValue': '$xp'},
            'streakDays': <String, String>{'integerValue': '$streak'},
            if (freezes != null)
              'streakFreezes': <String, String>{'integerValue': '$freezes'},
          },
        },
      );

  http.Client serving(String body, {int status = 200}) =>
      MockClient((http.Request request) async {
        expect(request.url.host, 'firestore.googleapis.com');
        return http.Response(body, status);
      });

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await GamificationService.loadXP(userId: uid);
  });

  group('an older cloud record cannot lower local progress', () {
    test('a lower cloud streak loses to the local streak', () async {
      final DateTime now = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 12,
        'app_streak_days': 12,
        xpKey(): 2740,
        lastDateKey(): day(2026, 11, 26),
        lastAtKey(): now.toUtc().toIso8601String(),
        countKey(): 2,
      });

      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 300, streak: 3)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 12);
      expect(prefs.getInt('app_streak_days'), 12);
      expect(prefs.getInt(xpKey()), 2740);
      expect(prefs.getInt(countKey()), 2, reason: 'no freeze may be spent');
    });

    test('a stale document with zero streak changes nothing', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 4,
        xpKey(): 800,
      });

      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 0, streak: 0)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 4);
      expect(prefs.getInt(xpKey()), 800);
    });

    test('a failed request leaves local state untouched', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 4,
        xpKey(): 800,
        lastDateKey(): day(2026, 11, 26),
      });

      await GamificationService.restoreFromCloud(
        uid,
        client: serving('server exploded', status: 500),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 4);
      expect(prefs.getInt(xpKey()), 800);
      expect(prefs.getString(lastDateKey()), day(2026, 11, 26));
    });
  });

  group('a higher cloud record restores progress without corrupting days', () {
    test('adopts the cloud streak but keeps the local completion day',
        () async {
      final DateTime now = DateTime(2026, 11, 26, 10);
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 2,
        lastDateKey(): day(2026, 11, 26),
        lastAtKey(): now.toUtc().toIso8601String(),
      });

      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 1200, streak: 9)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 9);
      expect(prefs.getInt('app_streak_days'), 9);
      expect(
        prefs.getString(lastDateKey()),
        day(2026, 11, 26),
        reason: 'the cloud record has no completion day to copy',
      );
      expect(prefs.getString(lastAtKey()), now.toUtc().toIso8601String());

      // The restored streak keeps counting from the real local day.
      expect(
        await StreakFreezeService.recordCompletionDay(
          userId: uid,
          now: DateTime(2026, 11, 27, 9),
        ),
        10,
      );
    });

    test('a fresh device adopts XP and streak from the cloud', () async {
      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 400, streak: 7)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(xpKey()), 400);
      expect(prefs.getInt(streakKey()), 7);
      expect(prefs.getInt('app_streak_days'), 7);
      expect(
        prefs.getString(lastDateKey()),
        isNull,
        reason: 'a restore must not invent a completion day',
      );
      expect(
        prefs.getString(lastAtKey()),
        isNull,
        reason: 'a restore must not invent a completion instant',
      );
      expect(await StreakFreezeService.missedDays(userId: uid), 0);
    });

    test('restoring twice is idempotent', () async {
      final http.Client client = serving(firestoreDoc(xp: 400, streak: 7));

      await GamificationService.restoreFromCloud(uid, client: client);
      await GamificationService.restoreFromCloud(uid, client: client);

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(xpKey()), 400);
      expect(prefs.getInt(streakKey()), 7);
      expect(prefs.getString(lastDateKey()), isNull);
    });
  });

  group('freeze inventory travels with the cloud record', () {
    test('a restored streak also restores the freeze bank', () async {
      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 900, streak: 9, freezes: 2)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(streakKey()), 9);
      expect(prefs.getInt(countKey()), 2);
      // A cloud snapshot carries no frozen-day history, so none is invented.
      expect(prefs.getStringList(frozenKey()), isNull);
    });

    test('a bigger local bank is never lowered by the cloud', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        streakKey(): 3,
        countKey(): 2,
        frozenKey(): <String>[day(2026, 11, 24)],
      });

      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 900, streak: 9, freezes: 1)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), 2);
      expect(prefs.getStringList(frozenKey()), <String>[day(2026, 11, 24)]);
    });

    test('a bad record cannot inflate the bank past the cap', () async {
      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 0, streak: 0, freezes: 99)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), StreakFreezeService.maxFreezes);
    });

    test('a zero or negative cloud bank changes nothing', () async {
      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 0, streak: 0, freezes: 0)),
      );
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), isNull);

      SharedPreferences.setMockInitialValues(<String, Object>{countKey(): 1});
      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 0, streak: 0, freezes: -4)),
      );
      prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), 1);
    });

    test('a record without the field leaves the local bank alone', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{countKey(): 2});

      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 400, streak: 4)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), 2);
    });

    test('the merge never spends a freeze either', () async {
      await GamificationService.applyCloudProgress(
        userId: uid,
        cloudXP: 0,
        cloudStreak: 0,
        cloudFreezes: 2,
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(countKey()), 2);
      expect(prefs.getString('user_${uid}_streak_freeze_week_v1'), isNull);
    });
  });

  group('the leaderboard record carries the freeze bank', () {
    late Uri capturedUrl;
    late Map<String, dynamic> capturedFields;

    http.Client capturing() => MockClient((http.Request request) async {
          capturedUrl = request.url;
          capturedFields = (jsonDecode(request.body) as Map<String, dynamic>)
              ['fields'] as Map<String, dynamic>;
          return http.Response('{}', 200);
        });

    test('sync writes the clamped freeze count next to xp and streak',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'user_guest_streak_freezes_v1': 2,
        'user_name': 'Tester',
      });

      await LeaderboardService.syncUserToCloud(
        id: 'tester',
        username: 'Tester',
        avatarPath: 'assets/images/avatar_m1.png',
        xp: 500,
        streakDays: 5,
        badgeTitle: 'Novice 🌱',
        client: capturing(),
      );

      expect(capturedUrl.path, contains('community_leaderboard'));
      expect(capturedFields['streakFreezes']['integerValue'], '2');
      expect(capturedFields['streakDays']['integerValue'], '5');
      expect(capturedFields['xp']['integerValue'], '500');
    });

    test('an over-full local bank is written as the cap', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'user_guest_streak_freezes_v1': 9,
        'user_name': 'Tester',
      });

      await LeaderboardService.syncUserToCloud(
        id: 'tester',
        username: 'Tester',
        avatarPath: 'assets/images/avatar_m1.png',
        xp: 0,
        streakDays: 0,
        badgeTitle: 'Novice 🌱',
        client: capturing(),
      );

      expect(
        capturedFields['streakFreezes']['integerValue'],
        '${StreakFreezeService.maxFreezes}',
      );
    });

    test('a missing bank is written as zero', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'user_name': 'Tester',
      });

      await LeaderboardService.syncUserToCloud(
        id: 'tester',
        username: 'Tester',
        avatarPath: 'assets/images/avatar_m1.png',
        xp: 0,
        streakDays: 0,
        badgeTitle: 'Novice 🌱',
        client: capturing(),
      );

      expect(capturedFields['streakFreezes']['integerValue'], '0');
    });

    test('freezeCountForCloud clamps both ends', () {
      expect(LeaderboardService.freezeCountForCloud(null), 0);
      expect(LeaderboardService.freezeCountForCloud(-3), 0);
      expect(LeaderboardService.freezeCountForCloud(2), 2);
      expect(
        LeaderboardService.freezeCountForCloud(99),
        StreakFreezeService.maxFreezes,
      );
    });
  });

  group('XP merge', () {
    test('a restore never drops a new account below the starter balance',
        () async {
      await GamificationService.restoreFromCloud(
        uid,
        client: serving(firestoreDoc(xp: 100, streak: 0)),
      );

      final SharedPreferences prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt(xpKey()), isNull, reason: 'nothing to write');
      expect(await GamificationService.loadXP(userId: uid), 150);
    });

    test('local XP wins over a smaller cloud value', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{xpKey(): 500});

      await GamificationService.applyCloudProgress(
        userId: uid,
        cloudXP: 200,
        cloudStreak: 0,
      );

      expect(await GamificationService.loadXP(userId: uid), 500);
    });
  });
}
