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
            var count = 0
            var limit = offset
            while (limit < segment.text.length && count < 80) {
                limit += Character.charCount(segment.text.codePointAt(limit))
                count++
            }
            var end = limit
            if (limit < segment.text.length) {
                val sentence = (offset until limit).lastOrNull { segment.text[it] in "。！？!?；;" }
                    ?: (offset until limit).lastOrNull { segment.text[it] == '.' && it + 1 < segment.text.length && segment.text[it + 1].isWhitespace() }
                val clause = (offset until limit).lastOrNull { segment.text[it] in "，,：: " }
                val boundary = sentence ?: clause
                if (boundary != null) {
                    end = boundary + 1
                    while (end < limit && segment.text[end] in "”’」』\"") end++
                }
            }
            val text = segment.text.substring(offset, end)
            offset = end
            if (text.isNotBlank()) return segment.copy(text = text)
        }
        return null
    }
}

data class SpeechProgress(
    val phase: String = "准备中", val completed: Int = 0, val total: Int = 0,
    val cached: Int = 0, val played: Int = 0, val characters: Int = 0,
    val audioSeconds: Double = 0.0, val startedAt: Long = System.currentTimeMillis(), val measuredAt: Long = System.currentTimeMillis(),
    val requestStartedAt: Long? = null, val preparingChapter: Boolean = false
) { val fraction get() = if (total == 0) 0f else completed.toFloat() / total }

object SpeechWAV {
    fun duration(data: ByteArray): Double {
        fun number(offset: Int, count: Int): Long = (0 until count).fold(0L) { acc, i ->
            acc or ((data[offset + i].toLong() and 255) shl (i * 8))
        }
        require(data.size in 44..8*1024*1024 && String(data, 0, 4, Charsets.US_ASCII) == "RIFF"
            && String(data, 8, 4, Charsets.US_ASCII) == "WAVE"
            && String(data, 12, 4, Charsets.US_ASCII) == "fmt "
            && number(16, 4) == 16L && number(20, 2) == 1L && number(22, 2) == 1L && number(34, 2) == 16L
            && String(data, 36, 4, Charsets.US_ASCII) == "data"
            && number(4, 4) + 8 == data.size.toLong() && number(40, 4) + 44 == data.size.toLong()
            && number(40, 4) > 0 && number(40, 4) % 2 == 0L
            && number(24, 4) > 0 && number(28, 4) == number(24, 4) * 2) { "音频不完整或格式不支持，请重试" }
        return number(40, 4).toDouble() / number(28, 4)
    }
}
