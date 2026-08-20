package com.guiye.reader.stats

import android.content.Context
import android.os.SystemClock
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Calendar
import java.util.Date
import java.util.Locale

data class ReadingDay(val date: Date, val seconds: Long)

class ReadingStatsRepository(context: Context) {
    private val prefs = context.getSharedPreferences("guiye_reading_stats", Context.MODE_PRIVATE)
    private var sessionStartedAt: Long? = null
    private val formatter = SimpleDateFormat("yyyy-MM-dd", Locale.ROOT)

    fun startSession() { if (sessionStartedAt == null) sessionStartedAt = SystemClock.elapsedRealtime() }
    fun stopSession() {
        val started = sessionStartedAt ?: return
        sessionStartedAt = null
        val elapsed = ((SystemClock.elapsedRealtime() - started) / 1000).coerceAtLeast(0)
        if (elapsed < 1) return
        val daily = daily()
        val key = formatter.format(Date())
        daily[key] = (daily[key] ?: 0) + elapsed
        save(daily)
    }

    fun goalMinutes(): Int = prefs.getInt("goalMinutes", 30).coerceAtLeast(5)
    fun setGoalMinutes(value: Int) { prefs.edit().putInt("goalMinutes", value.coerceIn(5, 180)).apply() }
    fun todaySeconds(): Long = daily()[formatter.format(Date())] ?: 0
    fun streak(): Int {
        val daily = daily(); val calendar = Calendar.getInstance()
        if ((daily[formatter.format(calendar.time)] ?: 0) < 1) calendar.add(Calendar.DAY_OF_YEAR, -1)
        var count = 0
        while ((daily[formatter.format(calendar.time)] ?: 0) >= 1) { count++; calendar.add(Calendar.DAY_OF_YEAR, -1) }
        return count
    }
    fun lastSevenDays(): List<ReadingDay> {
        val daily = daily(); val calendar = Calendar.getInstance(); calendar.add(Calendar.DAY_OF_YEAR, -6)
        return (0 until 7).map { ReadingDay(calendar.time, daily[formatter.format(calendar.time)] ?: 0).also { calendar.add(Calendar.DAY_OF_YEAR, 1) } }
    }

    private fun daily(): MutableMap<String, Long> {
        val json = runCatching { JSONObject(prefs.getString("daily", "{}")) }.getOrDefault(JSONObject())
        return json.keys().asSequence().associateWith { json.optLong(it, 0) }.toMutableMap()
    }
    private fun save(values: Map<String, Long>) {
        prefs.edit().putString("daily", JSONObject().apply { values.forEach { (key, value) -> put(key, value) } }.toString()).apply()
    }
}

