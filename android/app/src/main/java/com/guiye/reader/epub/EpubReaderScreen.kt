@file:OptIn(org.readium.r2.shared.ExperimentalReadiumApi::class)

package com.guiye.reader.epub

import android.os.Bundle
import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.fragment.app.FragmentActivity
import androidx.fragment.app.FragmentContainerView
import androidx.fragment.app.commitNow
import java.io.File
import kotlinx.coroutines.flow.collectLatest
import org.json.JSONObject
import org.readium.r2.navigator.epub.EpubNavigatorFactory
import org.readium.r2.navigator.epub.EpubNavigatorFragment
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.toUrl
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import com.guiye.reader.library.Book

private class ReadiumServices(activity: FragmentActivity) {
    private val httpClient = DefaultHttpClient()
    val assetRetriever = AssetRetriever(activity.contentResolver, httpClient)
    val publicationOpener = PublicationOpener(
        publicationParser = DefaultPublicationParser(
            activity,
            httpClient = httpClient,
            assetRetriever = assetRetriever,
            pdfFactory = null
        ),
        contentProtections = emptyList()
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EpubReaderScreen(book: Book, onClose: () -> Unit, onProgress: (Book, Float) -> Unit) {
    val activity = LocalContext.current as FragmentActivity
    val services = remember { ReadiumServices(activity) }
    val prefs = remember { activity.getSharedPreferences("guiye_positions", 0) }
    var publication by remember(book.id) { mutableStateOf<Publication?>(null) }
    var navigator by remember(book.id) { mutableStateOf<EpubNavigatorFragment?>(null) }
    var error by remember(book.id) { mutableStateOf<String?>(null) }
    var showsContents by remember { mutableStateOf(false) }

    LaunchedEffect(book.id) {
        val asset = services.assetRetriever.retrieve(File(book.localPath).toUrl(false)).getOrNull()
            ?: run { error = "无法读取 EPUB 文件"; return@LaunchedEffect }
        publication = services.publicationOpener.open(asset, allowUserInteraction = false).getOrNull()
            ?: run { error = "EPUB 解析失败"; return@LaunchedEffect }
    }

    LaunchedEffect(navigator) {
        navigator?.currentLocator?.collectLatest { locator ->
            prefs.edit().putString("epub.${book.id}", locator.toJSON().toString()).apply()
            onProgress(book, (locator.locations.totalProgression ?: 0.0).toFloat())
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(book.title) },
                navigationIcon = { TextButton(onClick = onClose) { Text("‹ 书库") } },
                actions = {
                    Box {
                        Button(onClick = { showsContents = true }, enabled = publication?.tableOfContents?.isNotEmpty() == true) { Text("目录") }
                        DropdownMenu(expanded = showsContents, onDismissRequest = { showsContents = false }) {
                            flatten(publication?.tableOfContents.orEmpty()).forEach { link ->
                                DropdownMenuItem(text = { Text(link.title ?: "未命名章节") }, onClick = {
                                    showsContents = false
                                    navigator?.go(link, animated = true)
                                })
                            }
                        }
                    }
                }
            )
        }
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize(), contentAlignment = Alignment.Center) {
            publication?.let { opened ->
                EpubNavigatorHost(book, opened) { navigator = it }
            } ?: if (error == null) CircularProgressIndicator() else Text(error.orEmpty())
        }
    }
}

@Composable
private fun EpubNavigatorHost(book: Book, publication: Publication, onReady: (EpubNavigatorFragment) -> Unit) {
    val activity = LocalContext.current as FragmentActivity
    val prefs = remember { activity.getSharedPreferences("guiye_positions", 0) }
    var containerId by remember { mutableIntStateOf(View.NO_ID) }
    val tag = remember(book.id) { "epub-navigator-${book.id}" }

    AndroidView(
        factory = { context -> FragmentContainerView(context).apply { id = View.generateViewId(); containerId = id } },
        modifier = Modifier.fillMaxSize()
    )

    LaunchedEffect(containerId, publication) {
        if (containerId == View.NO_ID) return@LaunchedEffect
        withFrameNanos { }
        val saved = prefs.getString("epub.${book.id}", null)
        val locator = saved?.let { runCatching { Locator.fromJSON(JSONObject(it)) }.getOrNull() }
        activity.supportFragmentManager.fragmentFactory = EpubNavigatorFactory(publication)
            .createFragmentFactory(initialLocator = locator)
        activity.supportFragmentManager.commitNow {
            replace(containerId, EpubNavigatorFragment::class.java, Bundle(), tag)
        }
        (activity.supportFragmentManager.findFragmentByTag(tag) as? EpubNavigatorFragment)?.let(onReady)
    }

    DisposableEffect(tag) {
        onDispose {
            activity.supportFragmentManager.findFragmentByTag(tag)?.let { fragment ->
                activity.supportFragmentManager.commitNow(allowStateLoss = true) { remove(fragment) }
            }
        }
    }
}

private fun flatten(links: List<Link>): List<Link> = links.flatMap { listOf(it) + flatten(it.children) }
