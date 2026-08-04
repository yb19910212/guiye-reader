@file:OptIn(org.readium.r2.shared.ExperimentalReadiumApi::class)

package com.guiye.reader.epub

import android.os.Bundle
import android.view.View
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Scaffold
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.Slider
import androidx.compose.material3.Switch
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
import org.readium.r2.navigator.epub.EpubPreferences
import org.readium.r2.navigator.preferences.Theme
import org.readium.r2.shared.publication.Link
import org.readium.r2.shared.publication.Locator
import org.readium.r2.shared.publication.Publication
import org.readium.r2.shared.util.asset.AssetRetriever
import org.readium.r2.shared.util.http.DefaultHttpClient
import org.readium.r2.shared.util.toUrl
import org.readium.r2.streamer.PublicationOpener
import org.readium.r2.streamer.parser.DefaultPublicationParser
import com.guiye.reader.library.Book
import com.guiye.reader.notes.NoteRepository

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
    val notes = remember { NoteRepository(activity) }
    var publication by remember(book.id) { mutableStateOf<Publication?>(null) }
    var navigator by remember(book.id) { mutableStateOf<EpubNavigatorFragment?>(null) }
    var error by remember(book.id) { mutableStateOf<String?>(null) }
    var showsContents by remember { mutableStateOf(false) }
    var showsAppearance by remember { mutableStateOf(false) }
    var fontSize by remember { mutableStateOf(prefs.getFloat("reader.fontSize", 1f)) }
    var lineHeight by remember { mutableStateOf(prefs.getFloat("reader.lineHeight", 1.5f)) }
    var pageMargins by remember { mutableStateOf(prefs.getFloat("reader.pageMargins", 1f)) }
    var scroll by remember { mutableStateOf(prefs.getBoolean("reader.scroll", false)) }
    var theme by remember { mutableStateOf(prefs.getString("reader.theme", "light") ?: "light") }
    var currentLocator by remember { mutableStateOf<String?>(null) }
    var showsNoteEditor by remember { mutableStateOf(false) }
    var noteDraft by remember { mutableStateOf("") }

    LaunchedEffect(book.id) {
        val asset = services.assetRetriever.retrieve(File(book.localPath).toUrl(false)).getOrNull()
            ?: run { error = "无法读取 EPUB 文件"; return@LaunchedEffect }
        publication = services.publicationOpener.open(asset, allowUserInteraction = false).getOrNull()
            ?: run { error = "EPUB 解析失败"; return@LaunchedEffect }
    }

    LaunchedEffect(navigator) {
        navigator?.currentLocator?.collectLatest { locator ->
            prefs.edit().putString("epub.${book.id}", locator.toJSON().toString()).apply()
            currentLocator = locator.toJSON().toString()
            onProgress(book, (locator.locations.totalProgression ?: 0.0).toFloat())
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text(book.title) },
                navigationIcon = { TextButton(onClick = onClose) { Text("‹ 书库") } },
                actions = {
                    TextButton(onClick = { showsNoteEditor = true }) { Text("笔记") }
                    TextButton(onClick = { showsAppearance = true }) { Text("Aa") }
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
                EpubNavigatorHost(book, opened, EpubPreferences(
                    fontSize = fontSize.toDouble(), lineHeight = lineHeight.toDouble(), pageMargins = pageMargins.toDouble(),
                    publisherStyles = false, scroll = scroll,
                    theme = when (theme) { "dark" -> Theme.DARK; "sepia" -> Theme.SEPIA; else -> Theme.LIGHT }
                )) { navigator = it }
            } ?: if (error == null) CircularProgressIndicator() else Text(error.orEmpty())
        }
    }

    if (showsAppearance) {
        androidx.compose.material3.AlertDialog(
            onDismissRequest = { showsAppearance = false },
            title = { Text("阅读设置") },
            text = {
                androidx.compose.foundation.layout.Column {
                    Text("字号 ${"%.1f".format(fontSize)}×"); Slider(fontSize, { fontSize = it }, valueRange = .7f..2f)
                    Text("行距 ${"%.1f".format(lineHeight)}"); Slider(lineHeight, { lineHeight = it }, valueRange = 1f..2.2f)
                    Text("页边距 ${"%.1f".format(pageMargins)}"); Slider(pageMargins, { pageMargins = it }, valueRange = .5f..2f)
                    androidx.compose.foundation.layout.Row(verticalAlignment = Alignment.CenterVertically) { Text("上下滚动", modifier = Modifier.weight(1f)); Switch(scroll, { scroll = it }) }
                    androidx.compose.foundation.layout.Row {
                        listOf("light" to "日间", "sepia" to "纸张", "dark" to "夜间").forEach { (value, label) ->
                            TextButton(onClick = { theme = value }) { Text(if (theme == value) "● $label" else label) }
                        }
                    }
                }
            },
            confirmButton = { Button(onClick = {
                prefs.edit().putFloat("reader.fontSize", fontSize).putFloat("reader.lineHeight", lineHeight)
                    .putFloat("reader.pageMargins", pageMargins).putBoolean("reader.scroll", scroll).putString("reader.theme", theme).apply()
                showsAppearance = false
            }) { Text("完成") } }
        )
    }
    if (showsNoteEditor) {
        AlertDialog(
            onDismissRequest = { showsNoteEditor = false }, title = { Text("添加读书笔记") },
            text = { OutlinedTextField(noteDraft, { noteDraft = it }, label = { Text("记录想法") }, minLines = 5) },
            confirmButton = { Button(onClick = { notes.add(book, noteDraft, currentLocator); noteDraft = ""; showsNoteEditor = false }) { Text("保存") } },
            dismissButton = { TextButton(onClick = { showsNoteEditor = false }) { Text("取消") } }
        )
    }
}

@Composable
private fun EpubNavigatorHost(book: Book, publication: Publication, preferences: EpubPreferences, onReady: (EpubNavigatorFragment) -> Unit) {
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
            .createFragmentFactory(initialLocator = locator, initialPreferences = preferences)
        activity.supportFragmentManager.commitNow {
            replace(containerId, EpubNavigatorFragment::class.java, Bundle(), tag)
        }
        (activity.supportFragmentManager.findFragmentByTag(tag) as? EpubNavigatorFragment)?.let(onReady)
    }

    LaunchedEffect(preferences) { (activity.supportFragmentManager.findFragmentByTag(tag) as? EpubNavigatorFragment)?.submitPreferences(preferences) }

    DisposableEffect(tag) {
        onDispose {
            activity.supportFragmentManager.findFragmentByTag(tag)?.let { fragment ->
                activity.supportFragmentManager.commitNow(allowStateLoss = true) { remove(fragment) }
            }
        }
    }
}

private fun flatten(links: List<Link>): List<Link> = links.flatMap { listOf(it) + flatten(it.children) }
