package com.guiye.reader.speech

import java.util.Locale

data class SpeechVoice(
    val id: String,
    val name: String,
    val languageTag: String,
    val isNetworkRequired: Boolean,
    val quality: Int
) {
    val qualityLabel: String get() = when {
        quality >= 500 -> "顶级"
        quality >= 400 -> "高品质"
        quality >= 300 -> "标准"
        else -> "基础"
    }
}

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
