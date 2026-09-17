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
    private val onStatus: (String?) -> Unit = {},
    private val onProgress: (SpeechProgress?) -> Unit = {}
) : SpeechEngine, TextToSpeech.OnInitListener {
    private val appContext = context.applicationContext
    private val mainHandler = Handler(Looper.getMainLooper())
    private val tts = TextToSpeech(appContext, this)
    private var initialized = false
    @Volatile private var paused = false
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
    private var preparing = false
    private var progress = SpeechProgress()
    private val cacheDirectory = File(appContext.cacheDir, "speech-v2")
    val playbackTime: String get() = if (playerPrepared) runCatching { "播放 ${player!!.currentPosition / 1000} / ${player!!.duration / 1000} 秒" }.getOrDefault("") else ""
    fun setRate(value: Float) {
        selectedRate = value
        if (playerPrepared) runCatching { player?.let { it.playbackParams = it.playbackParams.setSpeed(value.coerceIn(0.6f, 1.6f)); if (paused) it.pause() } }
    }
    fun clearCache() {
        stop()
        RemoteRuntime.executor.execute { val ok = !cacheDirectory.exists() || cacheDirectory.deleteRecursively()
            mainHandler.post { onStatus(if (ok) "语音缓存已清理" else "缓存清理失败，请重试") } }
    }
    fun prepareChapter(segments: List<SpeechSegment>, voiceId: String?, rate: Float) = start(segments, 0, voiceId, rate, true)
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
        start(segments, startIndex, voiceId, rate, false)
    }
    private fun start(segments: List<SpeechSegment>, startIndex: Int, voiceId: String?, rate: Float, chapter: Boolean) {
        if (closed) return
        stop()
        if (segments.isEmpty()) { onQueueCompleted(); return }
        if (!initialized && voiceId?.startsWith("api:") != true) { onError("系统语音尚未就绪，请稍后重试"); return }
        queue = segments
        currentIndex = startIndex.coerceIn(0, segments.lastIndex)
        selectedVoiceId = voiceId
        selectedRate = rate
        paused = false
        if (voiceId?.startsWith("api:") == true) {
            cursor = SpeechChunkCursor(segments, currentIndex)
            var total = 0
            if (chapter) {
                val counter = SpeechChunkCursor(segments, currentIndex)
                while (counter.next() != null) { total++; if (total > 1000) { fail("本章过长，请选择较短章节或逐段朗读"); return } }
                window = SpeechPrefetchWindow(total + 1)
            }
            preparing = chapter && total > 0
            progress = SpeechProgress(total = total, preparingChapter = chapter)
            onProgress(progress)
        }
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

        RemoteRuntime.executor.execute {
            if (token.get()) return@execute
            var cacheHit = false
            var duration = 0.0
            runCatching {
                while (paused && !token.get()) Thread.sleep(150)
                if (token.get()) return@execute
                mainHandler.post { if (session === token && !token.get()) {
                    progress = progress.copy(phase = "检查缓存 / 等待服务器生成", requestStartedAt = System.currentTimeMillis()); onProgress(progress)
                } }
                require(key.isNotBlank()) { "请先保存服务器地址和 API 密钥" }
                val url = RemoteSpeechSettings.endpoint(address)
                check(cacheDirectory.isDirectory || cacheDirectory.mkdirs()) { "无法创建语音缓存" }
                val identity = org.json.JSONArray(listOf("sentence-v2", url, key, voice, segment.text)).toString()
                val name = java.security.MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it.toInt() and 255) }
                val cachedFile = File(cacheDirectory, "$name.wav")
                if (cachedFile.isFile) {
                    val valid = runCatching { check(cachedFile.length() <= 8*1024*1024); SpeechWAV.duration(cachedFile.readBytes()) }.getOrNull()
                    if (valid != null) { cacheHit = true; duration = valid; return@runCatching cachedFile }
                    cachedFile.delete()
                }
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
                            mainHandler.post { if (session === token && !token.get()) { progress = progress.copy(phase = "服务器繁忙，排队重试"); onProgress(progress) } }
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
                duration = SpeechWAV.duration(data)
                if (token.get()) return@execute
                val used = cacheDirectory.listFiles().orEmpty().sumOf { it.length() }
                check(used + data.size <= 200L * 1024 * 1024) { "语音缓存已达 200 MB，请清理缓存后重试" }
                val temp = File.createTempFile("pending-", ".tmp", cacheDirectory)
                try { temp.writeBytes(data); check(temp.renameTo(cachedFile)) { "保存缓存失败" } } finally { temp.delete() }
                cachedFile
            }.onSuccess { file ->
                mainHandler.post {
                    if (closed || session !== token || token.get()) return@post
                    ready[part] = segment to file
                    progress = progress.copy(completed = progress.completed + 1, cached = progress.cached + if (cacheHit) 1 else 0,
                        characters = progress.characters + segment.text.codePointCount(0, segment.text.length),
                        audioSeconds = progress.audioSeconds + duration, measuredAt = System.currentTimeMillis(), requestStartedAt = null, phase = if (paused) "已暂停" else "缓存已保存")
                    if (preparing && progress.completed == progress.total) preparing = false
                    progress = progress.copy(preparingChapter = preparing)
                    onProgress(progress)
                    startReadyAudio()
                }
            }.onFailure { error ->
                mainHandler.post { if (!closed && session === token && !token.get()) fail("远程语音生成失败：${error.localizedMessage}") }
            }
        }
    }

    private fun startReadyAudio() {
        if (closed || session.get() || preparing || paused || player != null) return
        val item = ready.remove(window.played)
        if (item == null) {
            if (sourceEnded && window.played == window.requested) { stop(); onQueueCompleted() }
            else onStatus("等待下一段语音，可继续阅读或暂停")
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
                        runCatching { prepared.playbackParams = prepared.playbackParams.setSpeed(selectedRate.coerceIn(0.6f, 1.6f)); prepared.start(); progress = progress.copy(phase = "正在播放", played = progress.played + 1); onProgress(progress); onStatus(null); onSegmentStarted(segment.id) }
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

    private fun fail(message: String) {
        val failed = progress.copy(phase = "失败，可重试；已完成缓存保留", requestStartedAt = null, measuredAt = System.currentTimeMillis())
        stop(); onProgress(failed); onError(message)
    }

    private fun releaseOfflineAudio() {
        player?.runCatching {
            setOnPreparedListener(null); setOnCompletionListener(null); setOnErrorListener(null)
            release()
        }
        player = null
        playerPrepared = false
        playingSegmentId = null
        audioFile = null
    }

    override fun pause() {
        paused = true
        progress = progress.copy(phase = "已暂停（当前请求可能仍在完成）"); onProgress(progress)
        if (selectedVoiceId?.startsWith("api:") == true) {
            if (playerPrepared) player?.runCatching { pause() }
        } else { activeUtteranceId = null; tts.stop() }
    }

    override fun resume() {
        if (!paused) return
        paused = false
        progress = progress.copy(phase = if (preparing) "继续缓存本章" else "继续播放"); onProgress(progress)
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
        preparing = false; onProgress(null)
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
