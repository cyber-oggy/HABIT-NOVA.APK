package com.example.synvero

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * JVM tests for the pure part of [TimezoneRescheduleReceiver]: whether a
 * timezone/clock broadcast is worth starting an engine for, and the single
 * engine slot behind it.
 *
 * Run where the Android SDK is available:
 *   cd android && ./gradlew :app:testDebugUnitTest
 */
class TimezoneRescheduleReceiverTest {

    @After
    fun releaseSlot() {
        // The slot is process-wide; never leak it between tests.
        TimezoneRescheduleReceiver.releaseEngineSlot()
    }

    @Test
    fun `nothing pending never takes the slot`() {
        assertFalse(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.NONE)
        )
    }

    @Test
    fun `a pending reminder takes the slot`() {
        assertTrue(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.PENDING)
        )
    }

    @Test
    fun `an unreadable store still re-plans rather than dropping the nudge`() {
        assertTrue(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.UNKNOWN)
        )
    }

    @Test
    fun `a second broadcast while an engine runs is ignored`() {
        assertTrue(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.PENDING)
        )
        assertFalse(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.PENDING)
        )
        assertFalse(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.UNKNOWN)
        )
        assertFalse(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.NONE)
        )
    }

    @Test
    fun `releasing the slot allows the next broadcast through`() {
        assertTrue(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.PENDING)
        )
        TimezoneRescheduleReceiver.releaseEngineSlot()
        assertTrue(
            TimezoneRescheduleReceiver.tryAcquireForBroadcast(PendingReminderState.PENDING)
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
}
