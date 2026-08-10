package com.guiye.reader.speech

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

class AndroidTtsEngine(
    context: Context,
    private val onSegmentStarted: (Int) -> Unit,
    private val onQueueCompleted: () -> Unit,
    private val onReady: () -> Unit
) : SpeechEngine, TextToSpeech.OnInitListener {
    private val tts = TextToSpeech(context.applicationContext, this)
    private var initialized = false
    private var paused = false
    private var queue: List<SpeechSegment> = emptyList()
    private var currentIndex = 0
    private var selectedVoiceId: String? = null
    private var selectedRate = 1f

    override val voices: List<SpeechVoice>
        get() = if (!initialized) emptyList() else tts.voices.orEmpty()
            .sortedWith(compareByDescending<android.speech.tts.Voice> { it.quality }
                .thenBy { if (it.locale.language in setOf("zh", "en", "ja", "ko")) 0 else 1 }
                .thenBy { it.locale.displayLanguage }.thenBy { it.name })
            .map { SpeechVoice(it.name, it.locale.displayName, it.locale.toLanguageTag(), it.isNetworkConnectionRequired, it.quality) }

    override fun onInit(status: Int) {
        initialized = status == TextToSpeech.SUCCESS
        if (initialized) {
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) {
                    utteranceId?.toIntOrNull()?.let(onSegmentStarted)
                }
                override fun onDone(utteranceId: String?) {
                    if (!paused) playNext()
                }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) = playNext()
            })
            onReady()
        }
    }

    override fun speak(segments: List<SpeechSegment>, startIndex: Int, voiceId: String?, rate: Float) {
        if (!initialized || segments.isEmpty()) return
        stop()
        queue = segments
        currentIndex = startIndex.coerceIn(0, segments.lastIndex)
        selectedVoiceId = voiceId
        selectedRate = rate
        paused = false
        playCurrent()
    }

    private fun playCurrent() {
        val segment = queue.getOrNull(currentIndex) ?: run { onQueueCompleted(); return }
        val explicit = tts.voices.orEmpty().firstOrNull { it.name == selectedVoiceId }
        tts.voice = explicit ?: tts.voices.orEmpty().firstOrNull { it.locale.toLanguageTag().startsWith(segment.languageTag.substringBefore('-')) }
        tts.language = Locale.forLanguageTag(segment.languageTag)
        tts.setSpeechRate(selectedRate)
        tts.speak(segment.text, TextToSpeech.QUEUE_FLUSH, Bundle(), segment.id.toString())
    }

    private fun playNext() {
        currentIndex++
        if (currentIndex <= queue.lastIndex) playCurrent() else onQueueCompleted()
    }

    override fun pause() { if (tts.isSpeaking) { paused = true; tts.stop() } }
    override fun resume() { if (paused) { paused = false; playCurrent() } }
    override fun stop() { paused = false; tts.stop() }
    override fun selectBestVoice(languageTag: String): SpeechVoice? = voices.firstOrNull { it.languageTag.startsWith(languageTag.substringBefore('-')) && !it.isNetworkRequired }
        ?: voices.firstOrNull { it.languageTag.startsWith(languageTag.substringBefore('-')) }
    fun shutdown() = tts.shutdown()
}
