import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:synvero/core/services/notification_service.dart';
import 'package:synvero/core/services/streak_risk_service.dart';

/// Entry point started by `TimezoneRescheduleReceiver` (Android).
///
/// Android delivers `ACTION_TIMEZONE_CHANGED` / `ACTION_TIME_SET` to a native
/// receiver, which boots a short-lived background isolate into this function.
/// It re-plans the pending streak nudge in the new local timezone, so the user
/// is nudged at their own evening instead of the old absolute instant, without
/// having to open the app first.
///
/// Keep this cheap: no UI, no alarms, no network. It only reads preferences and
/// hands one schedule call to the OS.
@pragma('vm:entry-point')
Future<void> habitNovaTimezoneReschedule() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  await NotificationService.initializeForBackground();
  await StreakRiskReminderService.rescheduleAfterTimezoneChange();
}
