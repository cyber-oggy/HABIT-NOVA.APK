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

/** What the stored preferences say about a pending streak nudge. */
internal enum class PendingReminderState {
    /** A plan is stored and must be re-planned for the new timezone. */
    PENDING,

    /** No plan is stored, so the broadcast has nothing to do. */
    NONE,

    /** Preferences are unreadable or empty, so do not assume anything. */
    UNKNOWN,
}

/**
 * Decides whether a timezone/clock broadcast is worth booting a Flutter engine.
 *
 * Starting an engine means a cold app process and a Dart isolate, so it must
 * only happen when there is something to re-plan and no engine is already
 * running. Only a positively empty store skips the work: if the stored state
 * cannot be read, the reminder is re-planned rather than silently dropped.
 *
 * Kept as a pure object so it can be unit tested on the JVM.
 */
internal object TimezoneRescheduleGate {
    fun shouldStart(hasPendingReminder: Boolean, engineBusy: Boolean): Boolean =
        hasPendingReminder && !engineBusy

    fun shouldStart(state: PendingReminderState, engineBusy: Boolean): Boolean =
        shouldStart(state != PendingReminderState.NONE, engineBusy)
}

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
 * Two guards keep that cheap:
 *  - a native preflight reads the pending plan from shared preferences, so a
 *    broadcast with nothing to do never creates an engine;
 *  - a single slot allows one engine at a time, so two broadcasts in a row
 *    cannot stack engines.
 *
 * Failure is deliberately silent: the next app open re-plans anyway, so a
 * background broadcast must never crash or block anything.
 */
class TimezoneRescheduleReceiver : BroadcastReceiver() {

    companion object {
        /** Preferences file written by the shared_preferences Android backend. */
        private const val PREFS_NAME = "FlutterSharedPreferences"

        /** Key written by StreakRiskReminderService (`pendingKey`), with the
         *  backend's `flutter.` prefix. */
        private const val PENDING_KEY = "flutter.streak_risk_pending_v1"

        /** How long the planning isolate may run before it is released. */
        private const val ENGINE_LIFETIME_MS = 20000L

        private val stateLock = Any()
        private var engineBusy = false

        /** Reads the pending plan without starting Flutter. */
        internal fun pendingReminderState(context: Context): PendingReminderState =
            try {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                if (!prefs.getString(PENDING_KEY, null).isNullOrBlank()) {
                    return PendingReminderState.PENDING
                }
                // An empty store means the backend may write somewhere else;
                // don't let a renamed preferences file disable the feature.
                if (prefs.all.keys.none { it.startsWith("flutter.") }) {
                    return PendingReminderState.UNKNOWN
                }
                PendingReminderState.NONE
            } catch (_: Throwable) {
                PendingReminderState.UNKNOWN
            }

        internal fun isEngineBusy(): Boolean = synchronized(stateLock) { engineBusy }

        /** Claims the single engine slot; false when one is already running. */
        internal fun claimEngineSlot(): Boolean = synchronized(stateLock) {
            if (engineBusy) {
                false
            } else {
                engineBusy = true
                true
            }
        }

        internal fun releaseEngineSlot() {
            synchronized(stateLock) { engineBusy = false }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_TIMEZONE_CHANGED && action != Intent.ACTION_TIME_SET) {
            return
        }

        val appContext = context.applicationContext

        // Native preflight: no pending nudge means nothing to re-plan, so the
        // app process is never started for this broadcast.
        if (!TimezoneRescheduleGate.shouldStart(
                pendingReminderState(appContext),
                isEngineBusy()
            )
        ) {
            return
        }
        if (!claimEngineSlot()) {
            return
        }

        var created: FlutterEngine? = null
        try {
            val loader: FlutterLoader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(appContext)
            loader.ensureInitializationComplete(appContext, null)

            val engine = FlutterEngine(appContext)
            created = engine
            @Suppress("DEPRECATION")
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint(
                    loader.findAppBundlePath(),
                    "habitNovaTimezoneReschedule"
                )
            )

            Handler(Looper.getMainLooper()).postDelayed({
                try {
                    engine.destroy()
                } catch (_: Throwable) {
                }
                releaseEngineSlot()
            }, ENGINE_LIFETIME_MS)
        } catch (_: Throwable) {
            try {
                created?.destroy()
            } catch (_: Throwable) {
            }
            releaseEngineSlot()
        }
    }
}
