package com.guiye.reader.plans

import android.content.Context
import com.guiye.reader.library.Book
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar
import java.util.UUID

data class ReadingPlan(val id: String, val bookId: String, val bookTitle: String, val createdAt: Long, val deadline: Long)

class ReadingPlanRepository(context: Context) {
    private val prefs = context.getSharedPreferences("guiye_reading_plans", Context.MODE_PRIVATE)
    fun all(): List<ReadingPlan> {
        val array = runCatching { JSONArray(prefs.getString("plans", "[]")) }.getOrDefault(JSONArray())
        return (0 until array.length()).mapNotNull { index -> array.optJSONObject(index)?.let { json ->
            ReadingPlan(json.optString("id"), json.optString("bookId"), json.optString("bookTitle"), json.optLong("createdAt"), json.optLong("deadline"))
        } }.sortedBy { it.deadline }
    }
    fun set(book: Book, days: Int) {
        val calendar = Calendar.getInstance(); calendar.add(Calendar.DAY_OF_YEAR, days.coerceAtLeast(1))
        val values = all().filterNot { it.bookId == book.id } + ReadingPlan(UUID.randomUUID().toString(), book.id, book.title, System.currentTimeMillis(), calendar.timeInMillis)
        save(values)
    }
    fun remove(bookId: String) = save(all().filterNot { it.bookId == bookId })
    private fun save(values: List<ReadingPlan>) {
        val array = JSONArray(); values.forEach { plan -> array.put(JSONObject().apply {
            put("id", plan.id); put("bookId", plan.bookId); put("bookTitle", plan.bookTitle); put("createdAt", plan.createdAt); put("deadline", plan.deadline)
        }) }
        prefs.edit().putString("plans", array.toString()).apply()
    }
}

