package com.guiye.reader.remote

import android.content.Context
import android.util.Xml
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.xmlpull.v1.XmlPullParser
import java.io.File
import java.net.URI
import java.net.URL
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import java.util.concurrent.TimeUnit

data class WebDavItem(val url: String, val name: String, val isDirectory: Boolean) {
    val isBook: Boolean get() = url.substringBefore('?').substringAfterLast('.', "").lowercase() in setOf("epub", "pdf", "txt")
}

class WebDavClient(private val context: Context) {
    private val client = OkHttpClient.Builder().connectTimeout(20, TimeUnit.SECONDS).readTimeout(120, TimeUnit.SECONDS).followRedirects(true).build()

    suspend fun list(address: String, username: String, password: String): Result<List<WebDavItem>> = withContext(Dispatchers.IO) { runCatching {
        require(address.startsWith("https://", ignoreCase = true)) { "请输入 HTTPS WebDAV 地址" }
        val xml = "<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:displayname/><d:resourcetype/></d:prop></d:propfind>"
        val request = requestBuilder(address, username, password).header("Depth", "1")
            .method("PROPFIND", xml.toRequestBody("application/xml; charset=utf-8".toMediaType())).build()
        val response = client.newCall(request).execute()
        check(response.isSuccessful || response.code == 207) { "WebDAV 连接失败（${response.code}）" }
        val base = URI(address)
        val parser = Xml.newPullParser().apply { setInput(requireNotNull(response.body).byteStream(), Charsets.UTF_8.name()) }
        val items = mutableListOf<WebDavItem>()
        var href = ""; var displayName = ""; var collection = false; var text = ""
        while (parser.eventType != XmlPullParser.END_DOCUMENT) {
            val local = parser.name?.substringAfter(':')?.lowercase().orEmpty()
            when (parser.eventType) {
                XmlPullParser.START_TAG -> { text = ""; if (local == "response") { href = ""; displayName = ""; collection = false }; if (local == "collection") collection = true }
                XmlPullParser.TEXT -> text += parser.text.orEmpty()
                XmlPullParser.END_TAG -> when (local) {
                    "href" -> href = text.trim()
                    "displayname" -> displayName = text.trim()
                    "response" -> if (href.isNotBlank()) {
                        val absolute = base.resolve(href).toString()
                        val rawName = URL(absolute).path.trimEnd('/').substringAfterLast('/').ifBlank { "/" }
                        items += WebDavItem(absolute, displayName.ifBlank { java.net.URLDecoder.decode(rawName, Charsets.UTF_8.name()) }, collection)
                    }
                }
            }
            parser.next()
        }
        val current = address.trimEnd('/')
        items.distinctBy { it.url.trimEnd('/') }.filter { it.url.trimEnd('/') != current }.filter { it.isDirectory || it.isBook }
            .sortedWith(compareByDescending<WebDavItem> { it.isDirectory }.thenBy { it.name.lowercase() })
            .also { response.close() }
    } }

    suspend fun download(item: WebDavItem, username: String, password: String): Result<File> = withContext(Dispatchers.IO) { runCatching {
        val response = client.newCall(requestBuilder(item.url, username, password).get().build()).execute()
        check(response.isSuccessful) { "下载失败（${response.code}）" }
        val suffix = ".${item.url.substringBefore('?').substringAfterLast('.').lowercase()}"
        File.createTempFile("webdav-", suffix, context.cacheDir).also { file -> requireNotNull(response.body).byteStream().use { input -> file.outputStream().use { input.copyTo(it) } }; response.close() }
    } }

    private fun requestBuilder(address: String, username: String, password: String) = Request.Builder().url(address).apply {
        if (username.isNotBlank()) header("Authorization", Credentials.basic(username, password))
    }
}
