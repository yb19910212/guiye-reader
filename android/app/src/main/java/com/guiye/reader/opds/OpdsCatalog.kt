package com.guiye.reader.opds

import android.content.Context
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.readium.r2.opds.OPDS1Parser
import org.readium.r2.opds.OPDS2Parser
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.AbsoluteUrl
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.http.HttpRequest
import java.io.File
import java.net.HttpURLConnection
import java.net.URL

data class OpdsEntry(val title: String, val author: String?, val downloadUrl: String?, val mediaType: String?)
data class OpdsNavigation(val title: String, val url: String)
data class OpdsPage(val title: String, val entries: List<OpdsEntry>, val navigation: List<OpdsNavigation>)

class OpdsCatalog(private val context: Context) {
    private val client = DefaultHttpClient()

    suspend fun load(url: String): Result<OpdsPage> = withContext(Dispatchers.IO) { runCatching {
        val absolute = requireNotNull(AbsoluteUrl(url)) { "OPDS 地址无效" }
        val request = HttpRequest(absolute)
        val data = OPDS2Parser.parseRequest(request, client).getOrNull()
            ?: OPDS1Parser.parseRequest(request, client).getOrNull()
            ?: error("无法解析 OPDS 目录")
        val feed = data.feed ?: error("该地址不是 OPDS 目录")
        val publications = feed.publications + feed.groups.flatMap { it.publications }
        val links = feed.navigation + feed.groups.flatMap { it.navigation }
        OpdsPage(
            feed.metadata.title,
            publications.distinctBy { it.metadata.identifier ?: it.metadata.title }.map(::entry),
            links.distinctBy { it.href.toString() }.map { OpdsNavigation(it.title ?: it.href.toString(), it.href.toString()) }
        )
    } }

    suspend fun download(entry: OpdsEntry): Result<File> = withContext(Dispatchers.IO) { runCatching {
        val source = URL(requireNotNull(entry.downloadUrl))
        val extension = when {
            entry.mediaType?.contains("epub", true) == true -> "epub"
            entry.mediaType?.contains("pdf", true) == true -> "pdf"
            entry.mediaType?.contains("text/plain", true) == true -> "txt"
            else -> source.path.substringAfterLast('.', "").lowercase().takeIf { it in setOf("epub", "pdf", "txt") }
        } ?: error("此出版物不是可导入的 EPUB、PDF 或 TXT")
        val target = File.createTempFile("opds-", ".$extension", context.cacheDir)
        val connection = source.openConnection() as HttpURLConnection
        connection.connectTimeout = 15_000; connection.readTimeout = 60_000
        connection.instanceFollowRedirects = true
        try {
            require(connection.responseCode in 200..299) { "下载失败（HTTP ${connection.responseCode}）" }
            connection.inputStream.use { input -> target.outputStream().use { input.copyTo(it) } }
        } finally { connection.disconnect() }
        target
    } }

    private fun entry(publication: Publication): OpdsEntry {
        val link = publication.links.firstOrNull { candidate ->
            candidate.rels.any { it == "http://opds-spec.org/acquisition" } &&
                (candidate.mediaType?.toString()?.let { it.contains("epub", true) || it.contains("pdf", true) || it.contains("text/plain", true) } == true ||
                    candidate.href.toString().substringAfterLast('.', "").lowercase() in setOf("epub", "pdf", "txt"))
        }
        val author = publication.metadata.authors.joinToString(", ") { it.name }.takeIf { it.isNotBlank() }
        return OpdsEntry(publication.metadata.title ?: "未命名出版物", author, link?.href?.toString(), link?.mediaType?.toString())
    }
}
