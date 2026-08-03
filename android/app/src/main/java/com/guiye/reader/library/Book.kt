package com.guiye.reader.library

import org.json.JSONObject

enum class BookFormat { TXT, EPUB, PDF }

data class Book(
    val id: String,
    val title: String,
    val author: String?,
    val format: BookFormat,
    val localPath: String,
    val fileSize: Long,
    val importedAt: Long,
    val progress: Float = 0f
) {
    fun toJson() = JSONObject().apply {
        put("id", id); put("title", title); put("author", author)
        put("format", format.name); put("localPath", localPath)
        put("fileSize", fileSize); put("importedAt", importedAt); put("progress", progress.toDouble())
    }

    companion object {
        fun fromJson(json: JSONObject) = Book(
            id = json.getString("id"), title = json.getString("title"),
            author = json.optString("author").ifBlank { null },
            format = BookFormat.valueOf(json.getString("format")),
            localPath = json.getString("localPath"), fileSize = json.getLong("fileSize"),
            importedAt = json.getLong("importedAt"), progress = json.optDouble("progress", 0.0).toFloat()
        )
    }
}
