package com.guiye.reader.notes

import android.content.Context
import com.guiye.reader.library.Book
import java.util.UUID
import org.json.JSONArray
import org.json.JSONObject

data class ReadingNote(val id: String, val bookId: String, val bookTitle: String, val text: String, val locator: String?, val createdAt: Long, val quote: String? = null, val color: String? = null, val tags: List<String> = emptyList())
data class ReadingBookmark(val id: String, val bookId: String, val bookTitle: String, val paragraphIndex: Int, val excerpt: String, val createdAt: Long)

class NoteRepository(context: Context) {
    private val prefs = context.getSharedPreferences("guiye_notes", Context.MODE_PRIVATE)

    fun all(): List<ReadingNote> {
        val array = runCatching { JSONArray(prefs.getString("notes", "[]")) }.getOrDefault(JSONArray())
        return (0 until array.length()).mapNotNull { index ->
            runCatching { array.getJSONObject(index) }.getOrNull()?.let { json ->
                val tagsArray = json.optJSONArray("tags") ?: JSONArray()
                val tags = (0 until tagsArray.length()).mapNotNull { tagsArray.optString(it).ifBlank { null } }
                ReadingNote(json.getString("id"), json.getString("bookId"), json.getString("bookTitle"), json.getString("text"), json.optString("locator").ifBlank { null }, json.getLong("createdAt"), json.optString("quote").ifBlank { null }, json.optString("color").ifBlank { null }, tags)
            }
        }.sortedByDescending { it.createdAt }
    }

    fun add(book: Book, text: String, locator: String?) {
        val cleaned = text.trim(); if (cleaned.isEmpty()) return
        save(listOf(ReadingNote(UUID.randomUUID().toString(), book.id, book.title, cleaned, locator, System.currentTimeMillis())) + all())
    }

    fun addHighlight(book: Book, quote: String, locator: String) {
        val cleaned = quote.trim(); if (cleaned.isEmpty()) return
        save(listOf(ReadingNote(UUID.randomUUID().toString(), book.id, book.title, cleaned, locator, System.currentTimeMillis(), cleaned, "yellow")) + all())
    }

    fun addAnnotation(book: Book, text: String, quote: String, locator: String, tags: List<String> = emptyList()) {
        val cleaned = text.trim(); if (cleaned.isEmpty()) return
        save(listOf(ReadingNote(UUID.randomUUID().toString(), book.id, book.title, cleaned, locator, System.currentTimeMillis(), quote, "annotation", tags)) + all())
    }

    fun setHighlight(book: Book, quote: String, locator: String, color: String?) {
        val values = all().filterNot { it.bookId == book.id && it.locator == locator && it.color != "annotation" && it.quote != null }.toMutableList()
        if (color != null) values.add(0, ReadingNote(UUID.randomUUID().toString(), book.id, book.title, quote, locator, System.currentTimeMillis(), quote, color))
        save(values)
    }

    fun highlight(bookId: String, locator: String): ReadingNote? = all().firstOrNull { it.bookId == bookId && it.locator == locator && it.color != "annotation" && it.quote != null }
    fun highlights(bookId: String): Map<String, ReadingNote> = all().filter { it.bookId == bookId && it.locator != null && it.color != "annotation" && it.quote != null }.associateBy { it.locator!! }

    fun update(id: String, text: String, tags: List<String>) {
        val cleaned = text.trim(); if (cleaned.isEmpty()) return
        save(all().map { if (it.id == id) it.copy(text = cleaned, tags = tags) else it })
    }

    fun remove(id: String) = save(all().filterNot { it.id == id })

    fun markdown(): String = all().joinToString("\n\n---\n\n") {
        "## ${it.bookTitle}\n\n${it.quote?.let { quote -> "> $quote\n\n" } ?: ""}${it.text}${if (it.tags.isEmpty()) "" else "\n\n${it.tags.joinToString(" ") { tag -> "#$tag" }}"}${it.locator?.let { locator -> "\n\n_${locator}_" } ?: ""}"
    }

    private fun save(notes: List<ReadingNote>) {
        val array = JSONArray()
        notes.forEach { note -> array.put(JSONObject().apply {
            put("id", note.id); put("bookId", note.bookId); put("bookTitle", note.bookTitle); put("text", note.text); put("locator", note.locator); put("createdAt", note.createdAt); put("quote", note.quote); put("color", note.color); put("tags", JSONArray(note.tags))
        }) }
        prefs.edit().putString("notes", array.toString()).apply()
    }
}

class BookmarkRepository(context: Context) {
    private val prefs = context.getSharedPreferences("guiye_bookmarks", Context.MODE_PRIVATE)

    fun forBook(bookId: String): List<ReadingBookmark> = all().filter { it.bookId == bookId }.sortedBy { it.paragraphIndex }
    fun isBookmarked(bookId: String, paragraphIndex: Int): Boolean = all().any { it.bookId == bookId && it.paragraphIndex == paragraphIndex }

    fun toggle(book: Book, paragraphIndex: Int, excerpt: String) {
        val values = all().toMutableList()
        val existing = values.indexOfFirst { it.bookId == book.id && it.paragraphIndex == paragraphIndex }
        if (existing >= 0) values.removeAt(existing) else values.add(0, ReadingBookmark(UUID.randomUUID().toString(), book.id, book.title, paragraphIndex, excerpt, System.currentTimeMillis()))
        save(values)
    }

    private fun all(): List<ReadingBookmark> {
        val array = runCatching { JSONArray(prefs.getString("bookmarks", "[]")) }.getOrDefault(JSONArray())
        return (0 until array.length()).mapNotNull { index -> runCatching { array.getJSONObject(index) }.getOrNull()?.let { json ->
            ReadingBookmark(json.getString("id"), json.getString("bookId"), json.getString("bookTitle"), json.getInt("paragraphIndex"), json.getString("excerpt"), json.getLong("createdAt"))
        } }
    }

    private fun save(bookmarks: List<ReadingBookmark>) {
        val array = JSONArray()
        bookmarks.forEach { bookmark -> array.put(JSONObject().apply {
            put("id", bookmark.id); put("bookId", bookmark.bookId); put("bookTitle", bookmark.bookTitle); put("paragraphIndex", bookmark.paragraphIndex); put("excerpt", bookmark.excerpt); put("createdAt", bookmark.createdAt)
        }) }
        prefs.edit().putString("bookmarks", array.toString()).apply()
    }
}

