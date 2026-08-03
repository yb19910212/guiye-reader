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
import com.guiye.reader.speech.AndroidTtsEngine
import com.guiye.reader.speech.SpeechSegment
import com.guiye.reader.speech.SpeechState
import com.guiye.reader.speech.SpeechVoice
import com.guiye.reader.speech.detectLanguage
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

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
    private val positionPrefs = application.getSharedPreferences("guiye_positions", android.content.Context.MODE_PRIVATE)
    var books by mutableStateOf(repository.allBooks())
    var currentBook by mutableStateOf<Book?>(null)
    var importError by mutableStateOf<String?>(null)
    var importState by mutableStateOf(ImportUiState())
        private set
    var paragraphs by mutableStateOf(sampleParagraphs)
        private set
    private val segments get() = paragraphs.mapIndexed { i, text -> SpeechSegment(i, text, detectLanguage(text)) }

    var currentParagraph by mutableIntStateOf(0)
    var speechState by mutableStateOf(SpeechState.IDLE)
    var rate by mutableFloatStateOf(1f)
    var voices by mutableStateOf<List<SpeechVoice>>(emptyList())
    var selectedVoiceId by mutableStateOf<String?>(null)

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

    fun openBook(book: Book) {
        currentBook = book
        paragraphs = if (book.format == BookFormat.TXT) {
            repository.readText(book).getOrNull()?.split(Regex("\\n\\s*\\n|(?<=[。！？.!?])\\s+"))?.map { it.trim() }?.filter { it.isNotBlank() } ?: listOf("文件内容为空")
        } else {
            listOf(if (book.format == BookFormat.EPUB) "EPUB 已安全导入本地书库。Readium 导航器正在接入。" else "PDF 已安全导入本地书库。PDF 导航器正在接入。")
        }
        currentParagraph = positionPrefs.getInt("text.${book.id}", 0).coerceIn(0, paragraphs.lastIndex.coerceAtLeast(0))
        stopSpeech()
    }

    fun closeBook() { stopSpeech(); currentBook = null; paragraphs = sampleParagraphs }
    private fun stopSpeech() { engine.stop(); speechState = SpeechState.IDLE }

    fun selectParagraph(index: Int) {
        currentParagraph = index.coerceIn(0, paragraphs.lastIndex.coerceAtLeast(0))
        currentBook?.let { book ->
            positionPrefs.edit().putInt("text.${book.id}", currentParagraph).apply()
            val progress = if (paragraphs.size <= 1) 0f else currentParagraph.toFloat() / (paragraphs.size - 1)
            repository.updateProgress(book.id, progress); books = repository.allBooks()
        }
    }

    fun pdfPage(book: Book): Int = positionPrefs.getInt("pdf.${book.id}", 0)
    fun savePdfPage(book: Book, page: Int, pageCount: Int) {
        positionPrefs.edit().putInt("pdf.${book.id}", page).apply()
        repository.updateProgress(book.id, if (pageCount <= 1) 0f else page.toFloat() / (pageCount - 1)); books = repository.allBooks()
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
    fun updateRate(value: Float) { rate = value; restartIfActive() }
    private fun restartIfActive() {
        if (speechState != SpeechState.IDLE) { engine.speak(segments, currentParagraph, selectedVoiceId, rate); speechState = SpeechState.PLAYING }
    }
    override fun onCleared() { engine.shutdown() }
}
