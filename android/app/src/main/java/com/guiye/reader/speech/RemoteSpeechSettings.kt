package com.guiye.reader.speech

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class RemoteSpeechSettings(context: Context) {
    private val prefs = context.getSharedPreferences("remote_speech", Context.MODE_PRIVATE)
    var address: String
        get() = prefs.getString("address", null) ?: "https://sy.360427.xyz:16666"
        private set(value) { prefs.edit().putString("address", value).apply() }
    private fun secret(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey("guiye-tts", null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder("guiye-tts", KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE).build())
        }.generateKey()
    }
    val key: String get() = runCatching {
        val encoded = prefs.getString("key", null) ?: return@runCatching ""
        val iv = Base64.decode(prefs.getString("iv", ""), Base64.NO_WRAP)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secret(), GCMParameterSpec(128, iv))
        String(cipher.doFinal(Base64.decode(encoded, Base64.NO_WRAP)), Charsets.UTF_8)
    }.getOrDefault("")
    fun save(value: String, key: String) {
        endpoint(value)
        require(key.isNotBlank()) { "请填写 API 密钥" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, secret())
        val encrypted = cipher.doFinal(key.trim().toByteArray(Charsets.UTF_8))
        check(prefs.edit().putString("address", value.trim())
            .putString("key", Base64.encodeToString(encrypted, Base64.NO_WRAP))
            .putString("iv", Base64.encodeToString(cipher.iv, Base64.NO_WRAP)).commit()) { "保存失败" }
    }
    companion object {
        fun endpoint(value: String): String {
            val url = value.trim().toHttpUrlOrNull()
            require(url != null && url.isHttps && url.username.isEmpty() && url.password.isEmpty()
                && url.query == null && url.fragment == null) { "请输入有效 HTTPS 地址，不含密钥或查询参数" }
            val base = url.toString().trimEnd('/')
            return if (base.endsWith("/v1/audio/speech")) base else "$base/v1/audio/speech"
        }
    }
}
