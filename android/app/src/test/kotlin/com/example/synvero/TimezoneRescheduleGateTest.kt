package com.example.synvero

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for the pure part of [TimezoneRescheduleReceiver]: whether a
 * broadcast is worth starting an engine for, and the single-engine slot.
 *
 * Run where the Android SDK is available:
 *   cd android && ./gradlew :app:testDebugUnitTest
 */
class TimezoneRescheduleGateTest {

    @After
    fun releaseSlot() {
        // The slot is process-wide; never leak it between tests.
        TimezoneRescheduleReceiver.releaseEngineSlot()
    }

    @Test
    fun `a pending reminder with no engine running starts the isolate`() {
        assertTrue(TimezoneRescheduleGate.shouldStart(hasPendingReminder = true, engineBusy = false))
    }

    @Test
    fun `nothing pending never starts an engine`() {
        assertFalse(TimezoneRescheduleGate.shouldStart(hasPendingReminder = false, engineBusy = false))
        assertFalse(TimezoneRescheduleGate.shouldStart(hasPendingReminder = false, engineBusy = true))
    }

    @Test
    fun `a second broadcast while an engine runs is ignored`() {
        assertFalse(TimezoneRescheduleGate.shouldStart(hasPendingReminder = true, engineBusy = true))
        assertFalse(
            TimezoneRescheduleGate.shouldStart(PendingReminderState.PENDING, engineBusy = true)
        )
    }

    @Test
    fun `only a known-empty store skips the engine`() {
        assertFalse(
            TimezoneRescheduleGate.shouldStart(PendingReminderState.NONE, engineBusy = false)
        )
        assertTrue(
            TimezoneRescheduleGate.shouldStart(PendingReminderState.PENDING, engineBusy = false)
        )
        assertTrue(
            TimezoneRescheduleGate.shouldStart(PendingReminderState.UNKNOWN, engineBusy = false)
        )
    }

    @Test
    fun `a missing or blank stored plan is not pending`() {
        assertEquals(
            PendingReminderState.NONE,
            TimezoneRescheduleReceiver.pendingStateOf(null)
        )
        assertEquals(
            PendingReminderState.NONE,
            TimezoneRescheduleReceiver.pendingStateOf("")
        )
        assertEquals(
            PendingReminderState.NONE,
            TimezoneRescheduleReceiver.pendingStateOf("   ")
        )
        assertEquals(
            PendingReminderState.NONE,
            TimezoneRescheduleReceiver.pendingStateOf(false)
        )
        assertEquals(
            PendingReminderState.NONE,
            TimezoneRescheduleReceiver.pendingStateOf(0)
        )
    }

    @Test
    fun `a stored plan is pending whatever type it was written as`() {
        assertEquals(
            PendingReminderState.PENDING,
            TimezoneRescheduleReceiver.pendingStateOf(
                """{"scheduledAt":"2026-11-26T20:00:00+05:30"}"""
            )
        )
        assertEquals(
            PendingReminderState.PENDING,
            TimezoneRescheduleReceiver.pendingStateOf(true)
        )
        assertEquals(
            PendingReminderState.PENDING,
            TimezoneRescheduleReceiver.pendingStateOf(1)
        )
    }

    @Test
    fun `an unreadable shape stays unknown so the nudge is not dropped`() {
        assertEquals(
            PendingReminderState.UNKNOWN,
            TimezoneRescheduleReceiver.pendingStateOf(listOf("unexpected"))
        )
    }

    @Test
    fun `only one engine slot can be claimed at a time`() {
        assertTrue(TimezoneRescheduleReceiver.claimEngineSlot())
        assertFalse(TimezoneRescheduleReceiver.claimEngineSlot())
        assertTrue(TimezoneRescheduleReceiver.isEngineBusy())

        TimezoneRescheduleReceiver.releaseEngineSlot()

        assertFalse(TimezoneRescheduleReceiver.isEngineBusy())
        assertTrue(TimezoneRescheduleReceiver.claimEngineSlot())
    }
}
