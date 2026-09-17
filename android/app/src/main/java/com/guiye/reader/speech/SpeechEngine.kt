package com.guiye.reader.speech

import java.util.Locale

data class SpeechVoice(
    val id: String,
    val name: String,
    val languageTag: String,
    val isNetworkRequired: Boolean,
    val quality: Int,
    val provider: String = "system"
) {
    val qualityLabel: String get() = when {
        quality >= 500 -> "顶级"
        quality >= 400 -> "高品质"
        quality >= 300 -> "标准"
        else -> "基础"
    }
}

val SpeechVoice.isOpenSource: Boolean get() = provider == "kokoro"

data class SpeechSegment(val id: Int, val text: String, val languageTag: String)

enum class SpeechState { IDLE, PLAYING, PAUSED }

interface SpeechEngine {
    val voices: List<SpeechVoice>
    fun speak(segments: List<SpeechSegment>, startIndex: Int, voiceId: String?, rate: Float)
    fun pause()
    fun resume()
    fun stop()
    fun selectBestVoice(languageTag: String): SpeechVoice?
}

fun detectLanguage(text: String): String {
    val cjk = text.count { it.code in 0x4E00..0x9FFF }
    val latin = text.count { it.isLetter() && it.code < 0x0250 }
    return when {
        cjk > latin / 3 -> "zh-CN"
        latin > 0 -> "en-US"
        else -> Locale.getDefault().toLanguageTag()
    }
}

/** Main-thread scheduling; at most current + two future chunks are outstanding. */
class SpeechPrefetchWindow(val capacity: Int = 3) {
    init { require(capacity > 0) }
    var requested = 0; private set
    var played = 0; private set
    val canRequest get() = requested - played < capacity
    fun reserve(): Int? = if (canRequest) requested++ else null
    fun advance() { if (played < requested) played++ }
}

class SpeechChunkCursor(private val segments: List<SpeechSegment>, from: Int) {
    private var paragraph = from.coerceIn(0, segments.size)
    private var offset = 0
    fun next(): SpeechSegment? {
        while (paragraph < segments.size) {
            val segment = segments[paragraph]
            if (offset >= segment.text.length) { paragraph++; offset = 0; continue }
            val count = segment.text.codePointCount(offset, segment.text.length).coerceAtMost(48)
            val limit = segment.text.offsetByCodePoints(offset, count)
            var end = limit
            if (limit < segment.text.length) {
                val lower = segment.text.offsetByCodePoints(offset, count.coerceAtMost(16))
                val boundary = (lower until limit).lastOrNull { segment.text[it] in "。！？；，.!?;, \n" }
                if (boundary != null) end = boundary + 1
            }
            val text = segment.text.substring(offset, end)
            offset = end
            if (text.isNotBlank()) return segment.copy(text = text)
        }
        return null
    }
}
