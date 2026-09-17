package com.guiye.reader.speech

import android.content.Context
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.io.File
import java.util.Locale
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.MediaType.Companion.toMediaType
import org.json.JSONObject
import java.util.concurrent.TimeUnit


// App-lifetime runtime: no second native model and no release during inference.
private object RemoteRuntime {
    val executor = Executors.newSingleThreadExecutor()
}

private val remoteVoices = listOf(
    SpeechVoice("api:1", "温柔自然 · 1号", "zh-CN", true, 500, "api"),
    SpeechVoice("api:4", "温柔微嗲 · 4号", "zh-CN", true, 500, "api")
)

class AndroidTtsEngine(
    context: Context,
    private val onSegmentStarted: (Int) -> Unit,
    private val onQueueCompleted: () -> Unit,
    private val onReady: () -> Unit,
    private val onError: (String) -> Unit,
    private val onStatus: (String?) -> Unit = {}
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
    @Volatile private var activeCall: okhttp3.Call? = null
    private val client = OkHttpClient.Builder().followRedirects(false).followSslRedirects(false)
        .connectTimeout(15, TimeUnit.SECONDS).readTimeout(300, TimeUnit.SECONDS).callTimeout(330, TimeUnit.SECONDS).build()

    override val voices: List<SpeechVoice>
        get() = remoteVoices + if (!initialized) emptyList() else tts.voices.orEmpty()
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
        if (!initialized && voiceId?.startsWith("api:") != true) { onError("系统语音尚未就绪，请稍后重试"); return }
        queue = segments
        currentIndex = startIndex.coerceIn(0, segments.lastIndex)
        selectedVoiceId = voiceId
        selectedRate = rate
        paused = false
        if (voiceId?.startsWith("api:") == true) cursor = SpeechChunkCursor(segments, currentIndex)
        playCurrent()
    }

    private fun playCurrent() {
        val segment = queue.getOrNull(currentIndex) ?: run { onQueueCompleted(); return }
        if (selectedVoiceId?.startsWith("api:") == true) {
            pumpOffline()
            return
        }
        val explicit = tts.voices.orEmpty().firstOrNull { it.name == selectedVoiceId }
        val language = detectLanguage(segment.text)
        tts.language = Locale.forLanguageTag(language)
        (explicit ?: tts.voices.orEmpty().firstOrNull { it.locale.toLanguageTag().startsWith(language.substringBefore('-')) })?.let { tts.voice = it }
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
        val voice = if (selectedVoiceId == "api:4") "4" else "1"
        val settings = RemoteSpeechSettings(appContext)
        val address = settings.address
        val key = settings.key
        onStatus("正在准备远程语音，可继续阅读；NAS 生成可能需要几十秒")
        RemoteRuntime.executor.execute {
            if (token.get()) return@execute
            runCatching {
                require(key.isNotBlank()) { "请先保存服务器地址和 API 密钥" }
                val url = RemoteSpeechSettings.endpoint(address)
                val body = JSONObject().put("model", "qwen3-tts-0.6b").put("input", segment.text)
                    .put("voice", voice).put("response_format", "wav").put("speed", 1)
                var payload: ByteArray? = null
                for (attempt in 0 until 16) {
                    if (token.get()) return@execute
                    val request = Request.Builder().url(url).header("Authorization", "Bearer $key")
                        .post(body.toString().toRequestBody("application/json".toMediaType())).build()
                    val call = client.newCall(request)
                    activeCall = call
                    if (token.get()) { call.cancel(); return@execute }
                    call.execute().use { response ->
                        if (response.code == 429 && attempt < 15) {
                            // bounded cancellable retry; the NAS admits only one generator
                        } else {
                            check(response.code == 200) {
                                if (response.code == 401) "API 密钥无效" else "语音服务器返回 HTTP ${response.code}"
                            }
                            val stream = response.body?.byteStream() ?: error("音频为空")
                            val output = java.io.ByteArrayOutputStream()
                            val buffer = ByteArray(8192)
                            while (true) {
                                if (token.get()) return@execute
                                val count = stream.read(buffer)
                                if (count < 0) break
                                check(output.size() + count <= 8 * 1024 * 1024) { "音频超出大小限制" }
                                output.write(buffer, 0, count)
                            }
                            payload = output.toByteArray()
                        }
                    }
                    activeCall = null
                    if (payload != null) break
                    repeat(20) { if (token.get()) return@execute; Thread.sleep(100) }
                }
                val data = payload ?: error("服务器繁忙，请稍后重试")
                check(data.size > 44 && String(data, 0, 4, Charsets.US_ASCII) == "RIFF") { "服务器未返回有效 WAV 音频" }
                if (token.get()) return@execute
                File.createTempFile("remote-tts-", ".wav", appContext.cacheDir).apply {
                    try { writeBytes(data) } catch (error: Exception) { delete(); throw error }
                }
            }.onSuccess { file ->
                mainHandler.post {
                    if (closed || session !== token || token.get()) { file.delete(); return@post }
                    ready[part] = segment to file
                    startReadyAudio()
                }
            }.onFailure { error ->
                mainHandler.post { if (!closed && session === token && !token.get()) fail("远程语音生成失败：${error.localizedMessage}") }
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
                        runCatching { prepared.playbackParams = prepared.playbackParams.setSpeed(selectedRate.coerceIn(0.6f, 1.6f)); prepared.start(); onStatus(null); onSegmentStarted(segment.id) }
                            .onFailure { fail("远程语音播放失败：${it.localizedMessage}") }
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
                if (player === failed && session === token && !token.get()) fail("远程语音播放失败")
                true
            }
            next.prepareAsync()
        } catch (error: Exception) { fail("远程语音播放失败：${error.localizedMessage}") }
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
        if (selectedVoiceId?.startsWith("api:") == true) {
            if (playerPrepared) player?.runCatching { pause() }
        } else { activeUtteranceId = null; tts.stop() }
    }

    override fun resume() {
        if (!paused) return
        paused = false
        val existing = player
        if (selectedVoiceId?.startsWith("api:") == true) {
            if (existing != null && playerPrepared) {
                runCatching { existing.start(); playingSegmentId?.let(onSegmentStarted) }.onFailure { fail("恢复播放失败，请重试") }
            }
            pumpOffline()
        } else playCurrent()
    }

    override fun stop() {
        session.set(true)
        activeCall?.cancel(); activeCall = null
        onStatus(null)
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
