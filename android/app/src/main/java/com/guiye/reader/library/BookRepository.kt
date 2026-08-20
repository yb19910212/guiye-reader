package com.guiye.reader.library

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

class BookRepository(private val context: Context) {
    private val maximumImportBytes = 2L * 1024 * 1024 * 1024
    private val prefs = context.getSharedPreferences("guiye_library", Context.MODE_PRIVATE)
    private val booksDirectory = File(context.filesDir, "books").apply { mkdirs() }

    fun allBooks(): List<Book> {
        val array = runCatching { JSONArray(prefs.getString("books", "[]")) }.getOrDefault(JSONArray())
        return (0 until array.length()).mapNotNull { runCatching { Book.fromJson(array.getJSONObject(it)) }.getOrNull() }
            .filter { File(it.localPath).exists() }
            .sortedByDescending { it.importedAt }
    }

    fun import(uri: Uri): Result<Book> = runCatching {
        val metadata = queryMetadata(uri)
        require(metadata.second <= 0 || metadata.second <= maximumImportBytes) { "单个文件暂不能超过 2 GB" }
        val format = formatOf(metadata.first)
        val extension = format.name.lowercase()
        val temp = File.createTempFile("import-", ".$extension", booksDirectory)
        context.contentResolver.openInputStream(uri).use { input ->
            requireNotNull(input) { "无法打开所选文件" }
            temp.outputStream().use { output -> input.copyTo(output) }
        }
        require(temp.length() <= maximumImportBytes) { temp.delete(); "单个文件暂不能超过 2 GB" }
        val id = sha256(temp)
        val existing = allBooks().firstOrNull { it.id == id }
        if (existing != null) { temp.delete(); return@runCatching existing }
        val destination = File(booksDirectory, "$id.$extension")
        check(temp.renameTo(destination)) { "无法保存到本地书库" }
        val book = Book(
            id = id, title = metadata.first.substringBeforeLast('.').ifBlank { "未命名书籍" }, author = null,
            format = format, localPath = destination.absolutePath, fileSize = destination.length(), importedAt = System.currentTimeMillis()
        )
        save(allBooks() + book)
        book
    }

    fun import(file: File): Result<Book> = runCatching {
        val format = formatOf(file.name)
        require(file.length() <= maximumImportBytes) { "单个文件暂不能超过 2 GB" }
        val id = sha256(file)
        allBooks().firstOrNull { it.id == id }?.let { return@runCatching it }
        val destination = File(booksDirectory, "$id.${format.name.lowercase()}")
        file.copyTo(destination, overwrite = false)
        val book = Book(id, file.nameWithoutExtension, null, format, destination.absolutePath, destination.length(), System.currentTimeMillis())
        save(allBooks() + book)
        book
    }

    fun readText(book: Book): Result<String> = runCatching {
        require(book.format == BookFormat.TXT) { "当前格式应交给 Readium/PDF 阅读器" }
        val bytes = File(book.localPath).readBytes()
        when {
            bytes.size >= 3 && bytes[0] == 0xEF.toByte() && bytes[1] == 0xBB.toByte() -> bytes.toString(Charsets.UTF_8)
            else -> bytes.toString(Charsets.UTF_8)
        }.trim()
    }

    fun readParagraphs(book: Book): Result<List<String>> = readText(book).map(TextParser::paragraphs)

    fun updateProgress(bookId: String, progress: Float) {
        save(allBooks().map { if (it.id == bookId) it.copy(progress = progress.coerceIn(0f, 1f)) else it })
    }

    fun markOpened(bookId: String) {
        save(allBooks().map { if (it.id == bookId) it.copy(lastOpenedAt = System.currentTimeMillis()) else it })
    }

    fun updateMetadata(bookId: String, title: String, author: String?) {
        val cleanTitle = title.trim(); if (cleanTitle.isEmpty()) return
        save(allBooks().map { if (it.id == bookId) it.copy(title = cleanTitle, author = author?.trim()?.ifBlank { null }) else it })
    }

    fun deleteBooks(ids: Set<String>) {
        if (ids.isEmpty()) return
        allBooks().filter { it.id in ids }.forEach { runCatching { File(it.localPath).delete() } }
        save(allBooks().filterNot { it.id in ids })
    }

    fun backupJson(): String = JSONObject().apply {
        put("version", 2)
        put("exportedAt", System.currentTimeMillis())
        put("books", JSONArray().apply { allBooks().forEach { put(it.toJson()) } })
        put("notes", JSONArray(context.getSharedPreferences("guiye_notes", Context.MODE_PRIVATE).getString("notes", "[]")))
        put("bookmarks", JSONArray(context.getSharedPreferences("guiye_bookmarks", Context.MODE_PRIVATE).getString("bookmarks", "[]")))
        put("positions", JSONObject().apply {
            context.getSharedPreferences("guiye_positions", Context.MODE_PRIVATE).all.forEach { (key, value) -> put(key, value) }
        })
    }.toString(2)

    fun restoreBackup(text: String): Result<String> = runCatching {
        val root = JSONObject(text)
        require(root.optInt("version", 1) <= 2) { "备份来自更高版本的归页，请先更新 App" }
        val importedBooks = root.optJSONArray("books") ?: JSONArray()
        val metadata = (0 until importedBooks.length()).mapNotNull { runCatching { Book.fromJson(importedBooks.getJSONObject(it)) }.getOrNull() }.associateBy { it.id }
        var matched = 0
        save(allBooks().map { current ->
            metadata[current.id]?.let { imported ->
                matched++
                current.copy(title = imported.title, author = imported.author, progress = maxOf(current.progress, imported.progress), lastOpenedAt = maxOf(current.lastOpenedAt ?: 0L, imported.lastOpenedAt ?: 0L).takeIf { it > 0 })
            } ?: current
        })
        val noteCount = mergeArrayPreference("guiye_notes", "notes", root.optJSONArray("notes") ?: JSONArray())
        val bookmarkCount = mergeArrayPreference("guiye_bookmarks", "bookmarks", root.optJSONArray("bookmarks") ?: JSONArray())
        root.optJSONObject("positions")?.let { positions ->
            val editor = context.getSharedPreferences("guiye_positions", Context.MODE_PRIVATE).edit()
            positions.keys().forEach { key -> editor.putInt(key, positions.optInt(key, 0)) }
            editor.apply()
        }
        "已合并 $matched 本书的进度、$noteCount 条笔记和 $bookmarkCount 个书签"
    }

    private fun mergeArrayPreference(preferenceName: String, key: String, imported: JSONArray): Int {
        val target = context.getSharedPreferences(preferenceName, Context.MODE_PRIVATE)
        val current = runCatching { JSONArray(target.getString(key, "[]")) }.getOrDefault(JSONArray())
        val ids = (0 until current.length()).mapNotNull { current.optJSONObject(it)?.optString("id") }.toMutableSet()
        var added = 0
        for (index in 0 until imported.length()) {
            val value = imported.optJSONObject(index) ?: continue
            if (ids.add(value.optString("id"))) { current.put(value); added++ }
        }
        target.edit().putString(key, current.toString()).apply()
        return added
    }

    private fun save(books: List<Book>) {
        val array = JSONArray(); books.distinctBy { it.id }.forEach { array.put(it.toJson()) }
        prefs.edit().putString("books", array.toString()).apply()
    }

    private fun queryMetadata(uri: Uri): Pair<String, Long> {
        var name = uri.lastPathSegment ?: "document"
        var size = 0L
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                name = cursor.getString(0) ?: name
                size = if (cursor.isNull(1)) 0 else cursor.getLong(1)
            }
        }
        return name to size
    }

    private fun formatOf(name: String): BookFormat = when (name.substringAfterLast('.', "").lowercase()) {
        "txt" -> BookFormat.TXT
        "epub" -> BookFormat.EPUB
        "pdf" -> BookFormat.PDF
        else -> error("首版仅支持 EPUB、PDF 和 TXT")
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) { val count = input.read(buffer); if (count <= 0) break; digest.update(buffer, 0, count) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

