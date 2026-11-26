package com.example.synvero

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.embedding.engine.loader.FlutterLoader

/**
 * Re-plans the pending "streak at risk" reminder when the device timezone or
 * clock changes.
 *
 * Android alarms keep the absolute instant they were armed with, and the
 * notifications plugin re-arms them using the timezone name saved when they were
 * scheduled — so after travel or a DST shift the nudge lands at the wrong local
 * hour. This receiver starts a short-lived background Flutter isolate that
 * rebuilds the plan in the current timezone.
 *
 * Failure is deliberately silent: the next app open re-plans anyway, so a
 * background broadcast must never crash or block anything.
 */
class TimezoneRescheduleReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_TIMEZONE_CHANGED && action != Intent.ACTION_TIME_SET) {
            return
        }

        val appContext = context.applicationContext
        try {
            val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(appContext)
            loader.ensureInitializationComplete(appContext, null)

            val engine = FlutterEngine(appContext)
            @Suppress("DEPRECATION")
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "habitNovaTimezoneReschedule"
                )
            )

            // Scheduling takes a few hundred milliseconds; release the engine
            // afterwards so a timezone change never leaves one running.
            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    engine.destroy()
                } catch (_: Throwable) {
                }
            }, 20000L)
        } catch (_: Throwable) {
            // Next app launch re-plans the nudge.
        }
    }
}
