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
import kotlin.math.roundToInt

private const val KOKORO_MODEL_DIR = "kokoro-int8-multi-lang-v1_1"

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
    private val tts = TextToSpeech(appContext, this)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val synthesisExecutor = Executors.newSingleThreadExecutor()
    private var offlineTts: OfflineTts? = null
    private var initialized = false
    private var paused = false
    private var queue: List<SpeechSegment> = emptyList()
    private var currentIndex = 0
    private var selectedVoiceId: String? = null
    private var selectedRate = 1f
    private var player: MediaPlayer? = null
    private var playerPrepared = false
    private var audioFile: File? = null
    private var generation = 0

    override val voices: List<SpeechVoice>
        get() = kokoroVoices + if (!initialized) emptyList() else tts.voices.orEmpty()
            .sortedWith(compareByDescending<android.speech.tts.Voice> { it.quality }
                .thenBy { if (it.locale.language in setOf("zh", "en", "ja", "ko")) 0 else 1 }
                .thenBy { it.locale.displayLanguage }.thenBy { it.name })
            .map { SpeechVoice(it.name, it.locale.displayName, it.locale.toLanguageTag(), it.isNetworkConnectionRequired, it.quality) }

    override fun onInit(status: Int) {
        initialized = status == TextToSpeech.SUCCESS
        if (initialized) {
            tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
                override fun onStart(utteranceId: String?) { utteranceId?.toIntOrNull()?.let(onSegmentStarted) }
                override fun onDone(utteranceId: String?) { if (!paused) mainHandler.post(::playNext) }
                @Deprecated("Deprecated in Java")
                override fun onError(utteranceId: String?) { mainHandler.post(::playNext) }
            })
        }
        onReady()
    }

    override fun speak(segments: List<SpeechSegment>, startIndex: Int, voiceId: String?, rate: Float) {
        if (segments.isEmpty() || (!initialized && voiceId?.startsWith("kokoro:") != true)) return
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
        if (selectedVoiceId?.startsWith("kokoro:") == true) {
            synthesizeOffline(segment)
            return
        }
        val explicit = tts.voices.orEmpty().firstOrNull { it.name == selectedVoiceId }
        tts.voice = explicit ?: tts.voices.orEmpty().firstOrNull { it.locale.toLanguageTag().startsWith(segment.languageTag.substringBefore('-')) }
        tts.language = Locale.forLanguageTag(segment.languageTag)
        tts.setSpeechRate(selectedRate)
        tts.speak(segment.text, TextToSpeech.QUEUE_FLUSH, Bundle(), segment.id.toString())
    }

    private fun synthesizeOffline(segment: SpeechSegment) {
        val requestGeneration = generation
        val sid = selectedVoiceId.orEmpty().removePrefix("kokoro:").toIntOrNull() ?: 3
        val speed = selectedRate.coerceIn(0.6f, 1.6f)
        synthesisExecutor.execute {
            runCatching {
                val engine = offlineTts ?: createOfflineTts().also { offlineTts = it }
                val audio = engine.generate(segment.text, sid, speed)
                require(audio.samples.isNotEmpty()) { "模型没有生成音频" }
                File.createTempFile("kokoro-", ".wav", appContext.cacheDir).apply {
                    writeBytes(wavData(audio.samples, audio.sampleRate))
                }
            }.onSuccess { file ->
                mainHandler.post {
                    if (requestGeneration != generation || paused) { file.delete(); return@post }
                    audioFile = file
                    player = MediaPlayer().apply {
                        setAudioAttributes(AudioAttributes.Builder().setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).setUsage(AudioAttributes.USAGE_MEDIA).build())
                        setDataSource(file.absolutePath)
                        setOnPreparedListener {
                            playerPrepared = true
                            if (!paused) { onSegmentStarted(segment.id); it.start() }
                        }
                        setOnCompletionListener { releaseOfflineAudio(); playNext() }
                        setOnErrorListener { _, _, _ -> fail("离线语音播放失败"); true }
                        prepareAsync()
                    }
                }
            }.onFailure { error ->
                mainHandler.post { if (requestGeneration == generation && !paused) fail("离线语音初始化失败：${error.localizedMessage}") }
            }
        }
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
        if (currentIndex <= queue.lastIndex) playCurrent() else onQueueCompleted()
    }

    private fun fail(message: String) { releaseOfflineAudio(); onError(message) }

    private fun releaseOfflineAudio() {
        player?.runCatching { release() }
        player = null
        playerPrepared = false
        audioFile?.delete()
        audioFile = null
    }

    override fun pause() {
        paused = true
        if (selectedVoiceId?.startsWith("kokoro:") == true) {
            if (player == null) generation++ else if (playerPrepared) player?.pause()
        } else if (tts.isSpeaking) tts.stop()
    }

    override fun resume() {
        if (!paused) return
        paused = false
        val existing = player
        if (existing != null) {
            if (playerPrepared) existing.start()
        } else playCurrent()
    }

    override fun stop() {
        generation++
        paused = false
        releaseOfflineAudio()
        tts.stop()
    }

    override fun selectBestVoice(languageTag: String): SpeechVoice? = voices.firstOrNull {
        it.provider == "system" && it.languageTag.startsWith(languageTag.substringBefore('-')) && !it.isNetworkRequired
    } ?: voices.firstOrNull { it.provider == "system" && it.languageTag.startsWith(languageTag.substringBefore('-')) }

    fun shutdown() {
        stop()
        synthesisExecutor.shutdownNow()
        offlineTts?.release()
        offlineTts = null
        tts.shutdown()
    }
}
