package com.guiye.reader.speech

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import com.k2fsa.sherpa.onnx.OfflineTts
import com.k2fsa.sherpa.onnx.OfflineTtsConfig
import com.k2fsa.sherpa.onnx.OfflineTtsKokoroModelConfig
import com.k2fsa.sherpa.onnx.OfflineTtsModelConfig
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.roundToInt

private const val KOKORO_MODEL_DIR = "kokoro-int8-multi-lang-v1_1"

// App-lifetime runtime: no second native model and no release during inference.
private object KokoroRuntime {
    val executor = Executors.newSingleThreadExecutor()
    var model: OfflineTts? = null // Access exclusively on executor.
}

private val kokoroVoices = listOf(
    SpeechVoice("kokoro:3", "甜橙 · 中文女声", "zh-CN", false, 500, "kokoro"),
    SpeechVoice("kokoro:8", "蜜桃 · 中文女声", "zh-CN", false, 500, "kokoro"),
    SpeechVoice("kokoro:20", "月光 · 中文女声", "zh-CN", false, 500, "kokoro"),
    SpeechVoice("kokoro:40", "清泉 · 中文女声", "zh-CN", false, 500, "kokoro"),
    SpeechVoice("kokoro:0", "Maple · 英语女声", "en-US", false, 500, "kokoro"),
    SpeechVoice("kokoro:1", "Sol · 英语女声", "en-US", false, 500, "kokoro")
)

class AndroidTtsEngine(
    context: Context,
    private val onSegmentStarted: (Int) -> Unit,
    private val onQueueCompleted: () -> Unit,
    private val onReady: () -> Unit,
    private val onError: (String) -> Unit
) : SpeechEngine, TextToSpeech.OnInitListener {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val tts = TextToSpeech(appContext, this)
    private var initialized = false
    private var paused = false
    private var queue: List<SpeechSegment> = emptyList()
    private var currentIndex = 0
    private var selectedVoiceId: String? = null
    private var selectedRate = 1f
    private var player: MediaPlayer? = null
    private var playerPrepared = false
    private var playingSegmentId: Int? = null
    private var audioFile: File? = null
    private var session = AtomicBoolean(false)
    private var closed = false
    private var activeUtteranceId: String? = null
    private var utteranceSequence = 0L
    private var cursor: SpeechChunkCursor? = null
    private var window = SpeechPrefetchWindow()
    private val ready = mutableMapOf<Int, Pair<SpeechSegment, File>>()
    private var sourceEnded = false

    override val voices: List<SpeechVoice>
        get() = kokoroVoices + if (!initialized) emptyList() else tts.voices.orEmpty()
            .sortedWith(compareByDescending<android.speech.tts.Voice> { it.quality }
                .thenBy { if (it.locale.language in setOf("zh", "en", "ja", "ko")) 0 else 1 }
                .thenBy { it.locale.displayLanguage }.thenBy { it.name })
            .map { SpeechVoice(it.name, it.locale.displayName, it.locale.toLanguageTag(), it.isNetworkConnectionRequired, it.quality) }

    override fun onInit(status: Int) {
        mainHandler.post { finishInitialization(status) }
    }

    private fun finishInitialization(status: Int) {
        if (closed) return
        initialized = status == TextToSpeech.SUCCESS
        if (initialized) {
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) { mainHandler.post {
                    if (!closed && !paused && utteranceId != null && utteranceId == activeUtteranceId) {
                        queue.getOrNull(currentIndex)?.let { onSegmentStarted(it.id) }
                    }
                } }
                override fun onDone(utteranceId: String?) { mainHandler.post {
                    if (!closed && !paused && utteranceId != null && utteranceId == activeUtteranceId) {
                        activeUtteranceId = null
                        playNext()
                    }
                } }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) { mainHandler.post {
                    if (!closed && utteranceId != null && utteranceId == activeUtteranceId) fail("系统语音播放失败，请重试")
                } }
            })
        }
        onReady()
    }

    override fun speak(segments: List<SpeechSegment>, startIndex: Int, voiceId: String?, rate: Float) {
        if (closed) return
        stop()
        if (segments.isEmpty()) { onQueueCompleted(); return }
        if (!initialized && voiceId?.startsWith("kokoro:") != true) { onError("系统语音尚未就绪，请稍后重试"); return }
        queue = segments
        currentIndex = startIndex.coerceIn(0, segments.lastIndex)
        selectedVoiceId = voiceId
        selectedRate = rate
        paused = false
        if (voiceId?.startsWith("kokoro:") == true) cursor = SpeechChunkCursor(segments, currentIndex)
        playCurrent()
    }

    private fun playCurrent() {
        val segment = queue.getOrNull(currentIndex) ?: run { onQueueCompleted(); return }
        if (selectedVoiceId?.startsWith("kokoro:") == true) {
            pumpOffline()
            return
        }
        val explicit = tts.voices.orEmpty().firstOrNull { it.name == selectedVoiceId }
        tts.language = Locale.forLanguageTag(segment.languageTag)
        (explicit ?: tts.voices.orEmpty().firstOrNull { it.locale.toLanguageTag().startsWith(segment.languageTag.substringBefore('-')) })?.let { tts.voice = it }
        tts.setSpeechRate(selectedRate)
        val id = "guiye-${++utteranceSequence}"
        activeUtteranceId = id
        if (tts.speak(segment.text, TextToSpeech.QUEUE_FLUSH, Bundle(), id) == TextToSpeech.ERROR) fail("系统语音无法朗读这段内容")
    }

    private fun pumpOffline() {
        if (closed || session.get() || paused) return
        while (window.canRequest && !sourceEnded) {
            val segment = cursor?.next()
            if (segment == null) { sourceEnded = true; break }
            val part = window.reserve() ?: break
            synthesizeOffline(segment, part)
        }
        startReadyAudio()
    }

    private fun synthesizeOffline(segment: SpeechSegment, part: Int) {
        val token = session
        val sid = selectedVoiceId.orEmpty().removePrefix("kokoro:").toIntOrNull() ?: 3
        val speed = selectedRate.coerceIn(0.6f, 1.6f)
        KokoroRuntime.executor.execute {
            if (token.get()) return@execute
            runCatching {
                val engine = KokoroRuntime.model ?: createOfflineTts().also { KokoroRuntime.model = it }
                if (token.get()) return@execute
                require(sid in 0 until engine.numSpeakers()) { "音色编号不受当前模型支持" }
                val audio = engine.generateWithCallback(segment.text, sid, speed) { if (token.get()) 0 else 1 }
                if (token.get()) return@execute
                require(audio.samples.isNotEmpty() && audio.samples.all { it.isFinite() }) { "模型没有生成有效音频" }
                File.createTempFile("kokoro-", ".wav", appContext.cacheDir).apply {
                    try { writeBytes(wavData(audio.samples, audio.sampleRate)) }
                    catch (error: Exception) { delete(); throw error }
                }
            }.onSuccess { file ->
                mainHandler.post {
                    if (closed || session !== token || token.get()) { file.delete(); return@post }
                    ready[part] = segment to file
                    startReadyAudio()
                }
            }.onFailure { error ->
                mainHandler.post { if (!closed && session === token && !token.get()) fail("离线语音生成失败：${error.localizedMessage}") }
            }
        }
    }

    private fun startReadyAudio() {
        if (closed || session.get() || paused || player != null) return
        val item = ready.remove(window.played)
        if (item == null) {
            if (sourceEnded && window.played == window.requested) { stop(); onQueueCompleted() }
            return
        }
        val (segment, file) = item
        val token = session
        audioFile = file
        playingSegmentId = segment.id
        try {
            val next = MediaPlayer()
            player = next
            next.setAudioAttributes(AudioAttributes.Builder().setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).setUsage(AudioAttributes.USAGE_MEDIA).build())
            next.setDataSource(file.absolutePath)
            next.setOnPreparedListener { prepared ->
                if (player === prepared && session === token && !token.get()) {
                    playerPrepared = true
                    if (!paused) {
                        runCatching { prepared.start(); onSegmentStarted(segment.id) }
                            .onFailure { fail("离线语音播放失败：${it.localizedMessage}") }
                    }
                }
            }
            next.setOnCompletionListener { completed ->
                if (player === completed && session === token && !token.get()) {
                    releaseOfflineAudio()
                    window.advance()
                    pumpOffline()
                }
            }
            next.setOnErrorListener { failed, _, _ ->
                if (player === failed && session === token && !token.get()) fail("离线语音播放失败")
                true
            }
            next.prepareAsync()
        } catch (error: Exception) { fail("离线语音播放失败：${error.localizedMessage}") }
    }

    private fun createOfflineTts(): OfflineTts {
        val base = KOKORO_MODEL_DIR
        val kokoro = OfflineTtsKokoroModelConfig(
            model = "$base/model.int8.onnx",
            voices = "$base/voices.bin",
            tokens = "$base/tokens.txt",
            dataDir = "$base/espeak-ng-data",
            lexicon = "$base/lexicon-us-en.txt,$base/lexicon-zh.txt"
        )
        val config = OfflineTtsConfig(
            model = OfflineTtsModelConfig(kokoro = kokoro, numThreads = 4, debug = false),
            ruleFsts = "$base/date-zh.fst,$base/phone-zh.fst,$base/number-zh.fst",
            maxNumSentences = 1
        )
        return OfflineTts(appContext.assets, config)
    }

    private fun wavData(samples: FloatArray, sampleRate: Int): ByteArray {
        val dataSize = samples.size * 2
        return ByteBuffer.allocate(44 + dataSize).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray()); putInt(36 + dataSize); put("WAVE".toByteArray())
            put("fmt ".toByteArray()); putInt(16); putShort(1.toShort()); putShort(1.toShort())
            putInt(sampleRate); putInt(sampleRate * 2); putShort(2.toShort()); putShort(16.toShort())
            put("data".toByteArray()); putInt(dataSize)
            samples.forEach { putShort((it.coerceIn(-1f, 1f) * 32767f).roundToInt().toShort()) }
        }.array()
    }

    private fun playNext() {
        currentIndex++
        if (currentIndex <= queue.lastIndex) playCurrent() else { stop(); onQueueCompleted() }
    }

    private fun fail(message: String) { stop(); onError(message) }

    private fun releaseOfflineAudio() {
        player?.runCatching {
            setOnPreparedListener(null); setOnCompletionListener(null); setOnErrorListener(null)
            release()
        }
        player = null
        playerPrepared = false
        playingSegmentId = null
        audioFile?.delete()
        audioFile = null
    }

    override fun pause() {
        paused = true
        if (selectedVoiceId?.startsWith("kokoro:") == true) {
            if (playerPrepared) player?.runCatching { pause() }
        } else { activeUtteranceId = null; tts.stop() }
    }

    override fun resume() {
        if (!paused) return
        paused = false
        val existing = player
        if (selectedVoiceId?.startsWith("kokoro:") == true) {
            if (existing != null && playerPrepared) {
                runCatching { existing.start(); playingSegmentId?.let(onSegmentStarted) }.onFailure { fail("恢复播放失败，请重试") }
            }
            pumpOffline()
        } else playCurrent()
    }

    override fun stop() {
        session.set(true)
        session = AtomicBoolean(false)
        paused = false
        activeUtteranceId = null
        releaseOfflineAudio()
        ready.values.forEach { it.second.delete() }
        ready.clear()
        cursor = null
        window = SpeechPrefetchWindow()
        sourceEnded = false
        queue = emptyList()
        tts.stop()
    }

    override fun selectBestVoice(languageTag: String): SpeechVoice? = voices.firstOrNull {
        it.provider == "system" && it.languageTag.startsWith(languageTag.substringBefore('-')) && !it.isNetworkRequired
    } ?: voices.firstOrNull { it.provider == "system" && it.languageTag.startsWith(languageTag.substringBefore('-')) }

    fun shutdown() {
        stop()
        closed = true
        session.set(true)
        // The shared runtime outlives views. Releasing here races native inference.
        tts.shutdown()
    }
}
