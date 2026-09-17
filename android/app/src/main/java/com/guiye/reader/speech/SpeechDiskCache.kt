package com.guiye.reader.speech

import java.io.File
import java.security.MessageDigest

/** Called on the single speech worker, never on the UI thread. */
class SpeechDiskCache(private val directory: File) {
    fun file(identity: String): File {
        check(directory.isDirectory || directory.mkdirs()) { "无法创建语音缓存" }
        val name = MessageDigest.getInstance("SHA-256").digest(identity.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it.toInt() and 255) }
        return File(directory, "$name.wav")
    }
    fun read(file: File): Double? {
        if (!file.isFile) return null
        val duration = runCatching { check(file.length() <= 8*1024*1024); SpeechWAV.duration(file.readBytes()) }.getOrNull()
        if (duration == null) file.delete()
        return duration
    }
    fun save(data: ByteArray, file: File): Double {
        val duration = SpeechWAV.duration(data)
        val used = directory.listFiles().orEmpty().sumOf { it.length() }
        check(used + data.size <= 200L * 1024 * 1024) { "语音缓存已达 200 MB，请清理缓存后重试" }
        val temp = File.createTempFile("pending-", ".tmp", directory)
        try { temp.writeBytes(data); check(temp.renameTo(file)) { "保存缓存失败" } } finally { temp.delete() }
        return duration
    }
    fun clear(): Boolean = !directory.exists() || directory.deleteRecursively()
}
