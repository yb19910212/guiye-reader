package com.guiye.reader

import android.app.Application
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.guiye.reader.library.Book
import com.guiye.reader.library.BookFormat
import com.guiye.reader.library.BookRepository
import com.guiye.reader.library.TextChapter
import com.guiye.reader.library.TextParser
import com.guiye.reader.speech.AndroidTtsEngine
import com.guiye.reader.speech.SpeechSegment
import com.guiye.reader.speech.SpeechState
import com.guiye.reader.speech.SpeechVoice
import com.guiye.reader.speech.detectLanguage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import com.guiye.reader.opds.OpdsCatalog
import com.guiye.reader.opds.OpdsEntry
import com.guiye.reader.opds.OpdsPage
import com.guiye.reader.remote.WebDavClient
import com.guiye.reader.remote.WebDavItem
import androidx.documentfile.provider.DocumentFile

data class ImportUiState(
    val current: Int = 0,
    val total: Int = 0,
    val fileName: String = "",
    val duplicateCount: Int = 0
) {
    val isImporting: Boolean get() = total > 0 && current < total
    val progress: Float get() = if (total == 0) 0f else current.toFloat() / total
}

class ReaderViewModel(application: Application) : AndroidViewModel(application) {
    private val sampleParagraphs = listOf(
        "阅读不是把文字从第一页搬到最后一页，而是在阅读过程中不断建立连接。",
        "本地优先意味着书籍、进度和笔记首先保存在用户自己的设备上。即使没有网络，阅读和朗读也应该完整可用。",
        "When a paragraph changes language, the speech queue can select a matching voice automatically without interrupting the reading flow.",
        "真正可靠的阅读器，需要在修改字号、切换设备或重新打开应用后，仍然准确回到上次的位置。",
        "高亮和批注不应该困在应用里。它们需要保留来源、可以搜索，也可以导出到用户选择的知识工具中。"
    )
    private val repository = BookRepository(application)
    private val opdsCatalog = OpdsCatalog(application)
    private val webDavClient = WebDavClient(application)
    private val positionPrefs = application.getSharedPreferences("guiye_positions", android.content.Context.MODE_PRIVATE)
    var books by mutableStateOf(repository.allBooks())
    var currentBook by mutableStateOf<Book?>(null)
    var importError by mutableStateOf<String?>(null)
    var importState by mutableStateOf(ImportUiState())
        private set
    var paragraphs by mutableStateOf(sampleParagraphs)
        private set
    var textChapters by mutableStateOf(TextParser.chapters(sampleParagraphs))
        private set
    private val segments get() = paragraphs.mapIndexed { i, text -> SpeechSegment(i, text, detectLanguage(text)) }

    var currentParagraph by mutableIntStateOf(0)
    var speechState by mutableStateOf(SpeechState.IDLE)
    var rate by mutableFloatStateOf(1f)
    var voices by mutableStateOf<List<SpeechVoice>>(emptyList())
    var selectedVoiceId by mutableStateOf<String?>(null)
    private var textPositionSaveJob: Job? = null

    private val engine: AndroidTtsEngine by lazy {
        AndroidTtsEngine(
            application,
        onSegmentStarted = { selectParagraph(it) },
            onQueueCompleted = { speechState = SpeechState.IDLE },
            onReady = { voices = engineVoices() }
        )
    }

    private fun engineVoices() = engine.voices

    init { engine }

    fun importBooks(uris: List<android.net.Uri>) {
        if (uris.isEmpty() || importState.isImporting) return
        viewModelScope.launch {
            var duplicateCount = 0
            var latestBook: Book? = null
            importError = null
            uris.forEachIndexed { index, uri ->
                importState = ImportUiState(index, uris.size, uri.lastPathSegment.orEmpty(), duplicateCount)
                val before = repository.allBooks().size
                withContext(Dispatchers.IO) { repository.import(uri) }
                    .onSuccess { book ->
                        latestBook = book
                        if (repository.allBooks().size == before) duplicateCount++
                    }
                    .onFailure { importError = it.message ?: "导入失败" }
                importState = ImportUiState(index + 1, uris.size, uri.lastPathSegment.orEmpty(), duplicateCount)
            }
            books = repository.allBooks()
            importState = ImportUiState()
            if (importError == null) {
                importError = if (duplicateCount > 0) "导入完成，已跳过 $duplicateCount 本重复书籍" else "已导入 ${uris.size} 本书"
            }
            latestBook?.let(::openBook)
        }
    }

    fun importFolder(treeUri: android.net.Uri) {
        val root = DocumentFile.fromTreeUri(getApplication(), treeUri)
        if (root == null) { importError = "无法打开所选网络文件夹"; return }
        viewModelScope.launch(Dispatchers.IO) {
            val uris = mutableListOf<android.net.Uri>()
            fun visit(node: DocumentFile) {
                if (uris.size >= 1_000) return
                if (node.isDirectory) node.listFiles().forEach(::visit)
                else if (node.name?.substringAfterLast('.', "")?.lowercase() in setOf("epub", "pdf", "txt")) uris += node.uri
            }
            visit(root)
            withContext(Dispatchers.Main) {
                if (uris.isEmpty()) importError = "文件夹中没有 EPUB、PDF 或 TXT" else importBooks(uris)
            }
        }
    }

    suspend fun loadWebDav(url: String, username: String, password: String): Result<List<WebDavItem>> = webDavClient.list(url, username, password)

    fun importWebDav(items: List<WebDavItem>, username: String, password: String, completed: (String) -> Unit) {
        viewModelScope.launch {
            var imported = 0
            val failures = mutableListOf<String>()
            items.forEach { item ->
                webDavClient.download(item, username, password).fold(
                    onSuccess = { file ->
                        withContext(Dispatchers.IO) { repository.import(file) }.onSuccess { imported++; books = repository.allBooks() }.onFailure { failures += "${item.name}：${it.message}" }
                        file.delete()
                    },
                    onFailure = { failures += "${item.name}：${it.message}" }
                )
            }
            completed(if (failures.isEmpty()) "已导入 $imported 本书" else "导入 $imported 本，失败 ${failures.size} 本\n${failures.joinToString("\n")}")
        }
    }

    fun openBook(book: Book) {
        stopSpeech()
        repository.markOpened(book.id)
        books = repository.allBooks()
        currentBook = books.firstOrNull { it.id == book.id } ?: book
        if (book.format == BookFormat.TXT) {
            paragraphs = listOf("正在载入正文…")
            textChapters = emptyList()
            currentParagraph = 0
            viewModelScope.launch {
                val loaded = withContext(Dispatchers.IO) { repository.readParagraphs(book).getOrElse { listOf("无法读取文件：${it.message}") } }
                if (currentBook?.id == book.id) {
                    paragraphs = loaded
                    textChapters = TextParser.chapters(loaded)
                    currentParagraph = positionPrefs.getInt("text.${book.id}", 0).coerceIn(0, paragraphs.lastIndex.coerceAtLeast(0))
                }
            }
        } else {
            paragraphs = listOf(if (book.format == BookFormat.EPUB) "EPUB 已安全导入本地书库。Readium 导航器正在接入。" else "PDF 已安全导入本地书库。PDF 导航器正在接入。")
            currentParagraph = positionPrefs.getInt("text.${book.id}", 0).coerceIn(0, paragraphs.lastIndex.coerceAtLeast(0))
        }
    }

    fun updateBookMetadata(bookId: String, title: String, author: String?) {
        repository.updateMetadata(bookId, title, author); books = repository.allBooks()
    }

    fun deleteBooks(ids: Set<String>) {
        if (currentBook?.id?.let { it in ids } == true) closeBook()
        repository.deleteBooks(ids); books = repository.allBooks()
    }

    fun closeBook() { flushTextPosition(); stopSpeech(); currentBook = null; paragraphs = sampleParagraphs; textChapters = TextParser.chapters(sampleParagraphs) }
    private fun stopSpeech() { engine.stop(); speechState = SpeechState.IDLE }

    fun selectParagraph(index: Int) {
        currentParagraph = index.coerceIn(0, paragraphs.lastIndex.coerceAtLeast(0))
        scheduleTextPositionSave()
    }

    fun recordTextScrollPosition(index: Int) {
        if (currentBook?.format != BookFormat.TXT || paragraphs.firstOrNull() == "正在载入正文…") return
        currentParagraph = index.coerceIn(0, paragraphs.lastIndex.coerceAtLeast(0))
        scheduleTextPositionSave()
    }

    fun flushTextPosition() {
        val book = currentBook?.takeIf { it.format == BookFormat.TXT } ?: return
        textPositionSaveJob?.cancel()
        positionPrefs.edit().putInt("text.${book.id}", currentParagraph).commit()
        val progress = if (paragraphs.size <= 1) 0f else currentParagraph.toFloat() / (paragraphs.size - 1)
        repository.updateProgress(book.id, progress)
        books = repository.allBooks()
    }

    private fun scheduleTextPositionSave() {
        val book = currentBook?.takeIf { it.format == BookFormat.TXT } ?: return
        positionPrefs.edit().putInt("text.${book.id}", currentParagraph).apply()
        textPositionSaveJob?.cancel()
        textPositionSaveJob = viewModelScope.launch {
            delay(350)
            val progress = if (paragraphs.size <= 1) 0f else currentParagraph.toFloat() / (paragraphs.size - 1)
            repository.updateProgress(book.id, progress)
            books = repository.allBooks()
        }
    }

    fun pdfPage(book: Book): Int = positionPrefs.getInt("pdf.${book.id}", 0)
    fun savePdfPage(book: Book, page: Int, pageCount: Int) {
        positionPrefs.edit().putInt("pdf.${book.id}", page).commit()
        repository.updateProgress(book.id, if (pageCount <= 1) 0f else page.toFloat() / (pageCount - 1)); books = repository.allBooks()
    }

    fun saveEpubProgress(book: Book, progress: Float) {
        repository.updateProgress(book.id, progress)
        books = repository.allBooks()
    }

    fun backupJson(): String = repository.backupJson()

    fun restoreBackup(uri: android.net.Uri) {
        viewModelScope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching { getApplication<Application>().contentResolver.openInputStream(uri)?.bufferedReader()?.use { it.readText() } ?: error("无法读取备份文件") }
                    .fold(onSuccess = repository::restoreBackup, onFailure = { Result.failure(it) })
            }
            result.onSuccess { books = repository.allBooks(); importError = it }.onFailure { importError = "恢复失败：${it.message}" }
        }
    }

    suspend fun loadOpds(url: String, username: String = "", password: String = ""): Result<OpdsPage> = opdsCatalog.load(url, username, password)

    fun importOpds(entry: OpdsEntry, username: String = "", password: String = "", completed: (Result<Book>) -> Unit) {
        viewModelScope.launch {
            val result = opdsCatalog.download(entry, username, password).fold(
                onSuccess = { file -> withContext(Dispatchers.IO) { repository.import(file) }.also { file.delete() } },
                onFailure = { Result.failure(it) }
            )
            result.onSuccess { books = repository.allBooks() }
            completed(result)
        }
    }

    fun playOrPause() {
        when (speechState) {
            SpeechState.IDLE -> { engine.speak(segments, currentParagraph, selectedVoiceId, rate); speechState = SpeechState.PLAYING }
            SpeechState.PLAYING -> { engine.pause(); speechState = SpeechState.PAUSED }
            SpeechState.PAUSED -> { engine.resume(); speechState = SpeechState.PLAYING }
        }
    }

    fun previous() { selectParagraph((currentParagraph - 1).coerceAtLeast(0)); restartIfActive() }
    fun next() { selectParagraph((currentParagraph + 1).coerceAtMost(paragraphs.lastIndex)); restartIfActive() }
    fun chooseVoice(id: String?) { selectedVoiceId = id; restartIfActive() }
    fun previewVoice(voice: SpeechVoice) {
        selectedVoiceId = voice.id
        val sample = when {
            voice.languageTag.startsWith("zh") -> "你好，我是归页。愿这段声音陪你读完每一本好书。"
            voice.languageTag.startsWith("ja") -> "こんにちは。心地よい声で読書を楽しみましょう。"
            voice.languageTag.startsWith("ko") -> "안녕하세요. 편안한 목소리로 책을 읽어 드릴게요."
            else -> "Hello, this is Guiye Reader. Enjoy a natural and comfortable reading voice."
        }
        engine.speak(listOf(SpeechSegment(currentParagraph, sample, voice.languageTag)), 0, voice.id, rate)
        speechState = SpeechState.PLAYING
    }
    fun updateRate(value: Float) { rate = value; restartIfActive() }
    private fun restartIfActive() {
        if (speechState != SpeechState.IDLE) { engine.speak(segments, currentParagraph, selectedVoiceId, rate); speechState = SpeechState.PLAYING }
    }
    override fun onCleared() { flushTextPosition(); engine.shutdown() }
}

