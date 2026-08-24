package com.guiye.reader.reminder

import java.util.Calendar
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ReadingReminderSchedulerTest {
    @Test
    fun nextTriggerUsesTodayWhenTimeIsStillAhead() {
        val now = localTime(2026, Calendar.JANUARY, 15, 10, 0)

        val trigger = ReadingReminderScheduler.nextTriggerMillis(20, 30, now)
        val result = Calendar.getInstance().apply { timeInMillis = trigger }

        assertEquals(2026, result.get(Calendar.YEAR))
        assertEquals(Calendar.JANUARY, result.get(Calendar.MONTH))
        assertEquals(15, result.get(Calendar.DAY_OF_MONTH))
        assertEquals(20, result.get(Calendar.HOUR_OF_DAY))
        assertEquals(30, result.get(Calendar.MINUTE))
        assertTrue(trigger > now)
    }

    @Test
    fun nextTriggerMovesToTomorrowWhenTimeHasPassed() {
        val now = localTime(2026, Calendar.JANUARY, 15, 21, 0)

        val trigger = ReadingReminderScheduler.nextTriggerMillis(20, 30, now)
        val result = Calendar.getInstance().apply { timeInMillis = trigger }

        assertEquals(16, result.get(Calendar.DAY_OF_MONTH))
        assertEquals(20, result.get(Calendar.HOUR_OF_DAY))
        assertEquals(30, result.get(Calendar.MINUTE))
        assertTrue(trigger > now)
    }

    private fun localTime(year: Int, month: Int, day: Int, hour: Int, minute: Int): Long =
        Calendar.getInstance().apply {
            set(year, month, day, hour, minute, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
}
