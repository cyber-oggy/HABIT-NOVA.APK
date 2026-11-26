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

    /** The stored value is unreadable, so do not assume anything. */
    UNKNOWN,
}

/**
 * Decides whether a timezone/clock broadcast is worth booting a Flutter engine.
 *
 * Starting an engine means a cold app process and a Dart isolate, so it must
 * only happen when there is something to re-plan and no engine is already
 * running. Only a positively absent plan skips the work: if the stored value
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
 *  - a native preflight reads the pending plan from shared preferences before
 *    any Flutter class is loaded, so a broadcast with nothing to do returns
 *    immediately and never creates an engine;
 *  - the preflight and the single engine slot are claimed under one lock, so
 *    two broadcasts in a row cannot slip past the checks and stack engines.
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

        /**
         * Maps a stored preference value to a pending state, without Android.
         *
         * The plan is normally a JSON string, but reading it type-by-type would
         * turn a value written as a different type into a ClassCastException —
         * which used to degrade to UNKNOWN and boot an engine on every
         * broadcast. Reading the raw map entry keeps the decision cheap and
         * exact: only a value that positively says "a plan is stored" counts.
         */
        internal fun pendingStateOf(stored: Any?): PendingReminderState = when (stored) {
            null -> PendingReminderState.NONE
            is String -> if (stored.isBlank()) {
                PendingReminderState.NONE
            } else {
                PendingReminderState.PENDING
            }
            is Boolean -> if (stored) {
                PendingReminderState.PENDING
            } else {
                PendingReminderState.NONE
            }
            is Number -> if (stored.toLong() != 0L) {
                PendingReminderState.PENDING
            } else {
                PendingReminderState.NONE
            }
            // A shape we cannot interpret: re-plan rather than drop the nudge.
            else -> PendingReminderState.UNKNOWN
        }

        /**
         * Reads the pending plan from disk without starting Flutter.
         *
         * A missing plan means the next app open rebuilds one, so it is safe —
         * and much cheaper — to skip the engine for this broadcast.
         */
        internal fun pendingReminderState(context: Context): PendingReminderState =
            try {
                val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                pendingStateOf(prefs.all[PENDING_KEY])
            } catch (_: Throwable) {
                // Storage itself is unreadable; do not assume the nudge is gone.
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

        /**
         * Preflight plus slot claim as one step.
         *
         * Checking "is anything pending?" and "is an engine already running?"
         * separately leaves a gap in which a second broadcast can pass both
         * checks. Deciding under the same lock means back-to-back broadcasts
         * produce one engine, and a broadcast with nothing to do touches no
         * Flutter class at all.
         */
        internal fun tryAcquireForBroadcast(context: Context): Boolean {
            val state = pendingReminderState(context)
            return synchronized(stateLock) {
                when {
                    engineBusy -> false
                    state == PendingReminderState.NONE -> false
                    else -> {
                        engineBusy = true
                        true
                    }
                }
            }
        }
    }

    override fun onReceive(context: Context, intent: Intent?) {
        val action = intent?.action ?: return
        if (action != Intent.ACTION_TIMEZONE_CHANGED && action != Intent.ACTION_TIME_SET) {
            return
        }

        val appContext = context.applicationContext

        // Native preflight, before any Flutter class is touched: with no
        // pending nudge there is nothing to re-plan, so no engine is built.
        // The slot is claimed in the same step, so a second broadcast that
        // arrives while the first engine runs is ignored instead of stacking.
        if (!tryAcquireForBroadcast(appContext)) {
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
