@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.guiye.reader

import android.os.Bundle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.fragment.app.FragmentActivity
import com.guiye.reader.epub.EpubReaderScreen
import com.guiye.reader.library.Book
import com.guiye.reader.library.BookFormat
import com.guiye.reader.pdf.PdfPageView
import com.guiye.reader.notes.NoteRepository
import com.guiye.reader.speech.SpeechState
import com.guiye.reader.opds.OpdsPage

private enum class ReaderTheme(val title: String) {
    PAPER("纸张"), SEPIA("暖棕"), FOREST("森林"), NIGHT("夜间");

    val colors: ColorScheme get() = when (this) {
        PAPER -> lightColorScheme(primary = Color(0xFF315F49), background = Color(0xFFF6F3EA), surface = Color(0xFFF6F3EA), surfaceVariant = Color(0xFFE9E5D8), onBackground = Color(0xFF1E2B24), onSurface = Color(0xFF1E2B24), secondaryContainer = Color(0xFFE3ECDD))
        SEPIA -> lightColorScheme(primary = Color(0xFF8C4D1F), background = Color(0xFFE8D6B3), surface = Color(0xFFF8EACC), surfaceVariant = Color(0xFFDFC59A), onBackground = Color(0xFF3D2617), onSurface = Color(0xFF3D2617), secondaryContainer = Color(0xFFD4B076))
        FOREST -> lightColorScheme(primary = Color(0xFF1A5738), background = Color(0xFFD4E0CC), surface = Color(0xFFE8EFDF), surfaceVariant = Color(0xFFC2D3BC), onBackground = Color(0xFF142D1E), onSurface = Color(0xFF142D1E), secondaryContainer = Color(0xFFA9C7A6))
        NIGHT -> darkColorScheme(primary = Color(0xFFDB9E33), background = Color(0xFF0E1310), surface = Color(0xFF19201B), surfaceVariant = Color(0xFF29332B), onBackground = Color(0xFFE1E6D7), onSurface = Color(0xFFE1E6D7), secondaryContainer = Color(0xFF334736))
    }
}

class MainActivity : FragmentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            val prefs = remember { getSharedPreferences("guiye_appearance", android.content.Context.MODE_PRIVATE) }
            var selectedTheme by remember { mutableStateOf(runCatching { ReaderTheme.valueOf(prefs.getString("theme", "PAPER") ?: "PAPER") }.getOrDefault(ReaderTheme.PAPER)) }
            MaterialTheme(colorScheme = selectedTheme.colors) {
                GuiyeApp(selectedTheme) { theme -> selectedTheme = theme; prefs.edit().putString("theme", theme.name).apply() }
            }
        }
    }
}

@Composable
private fun GuiyeApp(theme: ReaderTheme, onThemeChange: (ReaderTheme) -> Unit, vm: ReaderViewModel = viewModel()) {
    when (vm.currentBook?.format) {
        null -> LibraryScreen(vm, theme, onThemeChange)
        BookFormat.PDF -> PdfReaderScreen(vm, vm.currentBook!!)
        BookFormat.EPUB -> EpubReaderScreen(vm.currentBook!!, vm::closeBook) { book, progress -> vm.saveEpubProgress(book, progress) }
        else -> ReaderScreen(vm)
    }
}

@Composable
private fun PdfReaderScreen(vm: ReaderViewModel, book: Book) {
    var page by remember(book.id) { mutableIntStateOf(vm.pdfPage(book)) }
    var pageCount by remember(book.id) { mutableIntStateOf(1) }
    var fitWidth by remember(book.id) { mutableStateOf(false) }
    LaunchedEffect(page, pageCount) { vm.savePdfPage(book, page, pageCount) }
    Scaffold(
        topBar = { TopAppBar(title = { Text(book.title) }, navigationIcon = { TextButton(onClick = vm::closeBook) { Text("‹ 书库") } }) },
        bottomBar = {
            Surface(tonalElevation = 4.dp) {
                Row(Modifier.navigationBarsPadding().fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.SpaceBetween) {
                    TextButton(onClick = { page = (page - 1).coerceAtLeast(0) }, enabled = page > 0) { Text("上一页") }
                    Text("${page + 1} / $pageCount")
                    TextButton(onClick = { page = (page + 1).coerceAtMost(pageCount - 1) }, enabled = page + 1 < pageCount) { Text("下一页") }
                    TextButton(onClick = { fitWidth = !fitWidth }) { Text(if (fitWidth) "整页" else "适宽") }
                }
            }
        }
    ) { padding ->
        AndroidView(
            factory = { context -> PdfPageView(context, java.io.File(book.localPath)).also { pageCount = it.pageCount; page = page.coerceIn(0, (pageCount - 1).coerceAtLeast(0)); it.showPage(page) } },
            update = { it.setFitWidth(fitWidth); it.showPage(page) },
            modifier = Modifier.padding(padding).fillMaxSize()
        )
    }
}

@Composable
private fun LibraryScreen(vm: ReaderViewModel, theme: ReaderTheme, onThemeChange: (ReaderTheme) -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val notes = remember { NoteRepository(context) }
    var showsNotes by remember { mutableStateOf(false) }
    var showsAISettings by remember { mutableStateOf(false) }
    var showsOpds by remember { mutableStateOf(false) }
    var showsThemes by remember { mutableStateOf(false) }
    var searchText by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf("all") }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        vm.importBooks(uris)
    }
    Scaffold(
        topBar = { TopAppBar(title = { Text("归页") }, actions = {
            TextButton(onClick = {
                val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply { type = "application/json"; putExtra(android.content.Intent.EXTRA_TEXT, vm.backupJson()) }
                context.startActivity(android.content.Intent.createChooser(intent, "导出归页备份"))
            }) { Text("备份") }
            TextButton(onClick = { showsAISettings = true }) { Text("AI") }
            TextButton(onClick = { showsThemes = true }) { Text("主题") }
            TextButton(onClick = { showsOpds = true }) { Text("OPDS") }
            TextButton(onClick = { showsNotes = true }) { Text("笔记") }
            TextButton(onClick = { importer.launch(arrayOf("text/plain", "application/epub+zip", "application/pdf")) }) { Text("导入") }
        }) },
        floatingActionButton = { FloatingActionButton(onClick = { importer.launch(arrayOf("text/plain", "application/epub+zip", "application/pdf")) }) { Text("＋") } }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().background(MaterialTheme.colorScheme.background).padding(horizontal = 20.dp)) {
            Text("我的书库", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 18.dp))
            Text("书籍保存在本机 · EPUB / PDF / TXT", color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 5.dp, bottom = 20.dp))
            OutlinedTextField(value = searchText, onValueChange = { searchText = it }, label = { Text("搜索书名或作者") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(Modifier.fillMaxWidth().padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("all" to "全部", "reading" to "在读", "unread" to "未读", "finished" to "读完").forEach { (value, label) ->
                    FilterChip(selected = filter == value, onClick = { filter = value }, label = { Text(label) })
                }
            }
            vm.importError?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(bottom = 12.dp)) }
            if (vm.importState.isImporting) {
                LinearProgressIndicator(progress = { vm.importState.progress }, modifier = Modifier.fillMaxWidth())
                Text("正在导入 ${vm.importState.current + 1}/${vm.importState.total} · ${vm.importState.fileName}", modifier = Modifier.padding(vertical = 8.dp))
            }
            if (vm.books.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("还没有书", style = MaterialTheme.typography.titleLarge)
                        Text("从系统文件选择器导入第一本电子书", color = Color.Gray, modifier = Modifier.padding(top = 8.dp))
                    }
                }
            } else {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    vm.books.filter { book ->
                        val queryMatches = searchText.isBlank() || book.title.contains(searchText, true) || book.author?.contains(searchText, true) == true
                        val stateMatches = when (filter) { "reading" -> book.progress > 0f && book.progress < .98f; "unread" -> book.progress == 0f; "finished" -> book.progress >= .98f; else -> true }
                        queryMatches && stateMatches
                    }.forEach { BookRow(it, vm::openBook) }
                    Spacer(Modifier.height(90.dp))
                }
            }
        }
    }
    if (showsNotes) {
        AlertDialog(
            onDismissRequest = { showsNotes = false },
            title = { Text("阅读笔记") },
            text = { Column(Modifier.heightIn(max = 420.dp).verticalScroll(rememberScrollState())) {
                if (notes.all().isEmpty()) Text("还没有笔记")
                notes.all().forEach { note -> Text(note.bookTitle, style = MaterialTheme.typography.titleSmall); Text(note.text); HorizontalDivider(Modifier.padding(vertical = 8.dp)) }
            } },
            confirmButton = { TextButton(onClick = {
                val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply { type = "text/markdown"; putExtra(android.content.Intent.EXTRA_TEXT, notes.markdown()) }
                context.startActivity(android.content.Intent.createChooser(intent, "导出阅读笔记"))
            }) { Text("导出 Markdown") } },
            dismissButton = { TextButton(onClick = { showsNotes = false }) { Text("关闭") } }
        )
    }
    if (showsAISettings) {
        val aiPrefs = remember { context.getSharedPreferences("guiye_ai", android.content.Context.MODE_PRIVATE) }
        var enabled by remember { mutableStateOf(aiPrefs.getBoolean("enabled", false)) }
        var currentOnly by remember { mutableStateOf(aiPrefs.getBoolean("currentOnly", true)) }
        var noSpoilers by remember { mutableStateOf(aiPrefs.getBoolean("noSpoilers", true)) }
        var model by remember { mutableStateOf(aiPrefs.getString("model", "gpt-5.6-sol") ?: "gpt-5.6-sol") }
        AlertDialog(onDismissRequest = { showsAISettings = false }, title = { Text("AI 阅读助手") }, text = {
            Column {
                Row(verticalAlignment = Alignment.CenterVertically) { Text("启用 AI", Modifier.weight(1f)); Switch(enabled, { enabled = it }) }
                OutlinedTextField(model, { model = it }, label = { Text("模型") })
                Row(verticalAlignment = Alignment.CenterVertically) { Text("仅允许当前书籍", Modifier.weight(1f)); Switch(currentOnly, { currentOnly = it }) }
                Row(verticalAlignment = Alignment.CenterVertically) { Text("小说禁止剧透", Modifier.weight(1f)); Switch(noSpoilers, { noSpoilers = it }) }
                Text("默认关闭。应用不会内置云服务密钥；关闭后不影响本地阅读与笔记。", style = MaterialTheme.typography.bodySmall)
            }
        }, confirmButton = { Button(onClick = {
            aiPrefs.edit().putBoolean("enabled", enabled).putBoolean("currentOnly", currentOnly).putBoolean("noSpoilers", noSpoilers).putString("model", model).apply(); showsAISettings = false
        }) { Text("保存") } }, dismissButton = { TextButton(onClick = { showsAISettings = false }) { Text("取消") } })
    }
    if (showsOpds) {
        OpdsDialog(vm) { showsOpds = false }
    }
    if (showsThemes) {
        AlertDialog(onDismissRequest = { showsThemes = false }, title = { Text("外观主题") }, text = {
            Column { ReaderTheme.entries.forEach { option ->
                Row(Modifier.fillMaxWidth().clickable { onThemeChange(option) }.padding(vertical = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    RadioButton(selected = theme == option, onClick = { onThemeChange(option) })
                    Text(option.title, Modifier.padding(start = 10.dp))
                }
            } }
        }, confirmButton = { TextButton(onClick = { showsThemes = false }) { Text("完成") } })
    }
}

@Composable
private fun OpdsDialog(vm: ReaderViewModel, dismiss: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    val prefs = remember { context.getSharedPreferences("guiye_opds", android.content.Context.MODE_PRIVATE) }
    var address by remember { mutableStateOf(prefs.getString("last_url", "https://standardebooks.org/opds/all") ?: "") }
    var currentUrl by remember { mutableStateOf<String?>(null) }
    var loadRequest by remember { mutableIntStateOf(0) }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var query by remember { mutableStateOf("") }
    var page by remember { mutableStateOf<OpdsPage?>(null) }
    var loading by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(currentUrl, loadRequest) {
        val url = currentUrl ?: return@LaunchedEffect
        loading = true; message = null
        vm.loadOpds(url, username, password).onSuccess { page = it }.onFailure { message = it.message }
        loading = false
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text(page?.title ?: "OPDS 书库") },
        text = {
            Column(Modifier.fillMaxWidth().heightIn(max = 560.dp)) {
                OutlinedTextField(address, { address = it }, label = { Text("OPDS 目录地址") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    OutlinedTextField(username, { username = it }, label = { Text("用户名（可选）") }, singleLine = true, modifier = Modifier.weight(1f))
                    OutlinedTextField(password, { password = it }, label = { Text("密码") }, singleLine = true, visualTransformation = androidx.compose.ui.text.input.PasswordVisualTransformation(), modifier = Modifier.weight(1f))
                }
                Button(onClick = { prefs.edit().putString("last_url", address.trim()).apply(); currentUrl = address.trim(); loadRequest++ }, enabled = !loading && address.isNotBlank(), modifier = Modifier.padding(vertical = 8.dp)) { Text("打开目录") }
                if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
                message?.let { Text(it, color = MaterialTheme.colorScheme.error) }
                if (page != null) OutlinedTextField(query, { query = it }, label = { Text("筛选书名或作者") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                Column(Modifier.verticalScroll(rememberScrollState())) {
                    page?.navigation?.forEach { item -> TextButton(onClick = { address = item.url; currentUrl = item.url; loadRequest++ }, modifier = Modifier.fillMaxWidth()) { Text("› ${item.title}", Modifier.fillMaxWidth()) } }
                    page?.entries?.filter { query.isBlank() || it.title.contains(query, true) || it.author?.contains(query, true) == true }?.forEach { entry ->
                        Row(Modifier.fillMaxWidth().padding(vertical = 7.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f)) { Text(entry.title); entry.author?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = Color.Gray) } }
                            Button(onClick = { message = "正在下载《${entry.title}》"; vm.importOpds(entry, username, password) { result -> message = result.fold({ "已导入《${it.title}》" }, { it.message ?: "导入失败" }) } }, enabled = entry.downloadUrl != null) { Text(if (entry.downloadUrl == null) "不可下载" else "导入") }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = dismiss) { Text("完成") } }
    )
}

@Composable
private fun BookRow(book: Book, open: (Book) -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth().clickable { open(book) },
        shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .72f)
    ) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(width = 54.dp, height = 72.dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(5.dp)), contentAlignment = Alignment.Center) {
                Text(book.format.name, color = Color.White, style = MaterialTheme.typography.labelMedium)
            }
            Column(Modifier.padding(start = 14.dp).weight(1f)) {
                Text(book.title, style = MaterialTheme.typography.titleMedium)
                Text("${book.format.name} · ${formatBytes(book.fileSize)}", color = Color.Gray, modifier = Modifier.padding(top = 5.dp))
                LinearProgressIndicator(progress = { book.progress }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
            }
        }
    }
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024 * 1024 -> "%.1f MB".format(bytes / 1024f / 1024f)
    bytes >= 1024 -> "%.1f KB".format(bytes / 1024f)
    else -> "$bytes B"
}

@Composable
private fun ReaderScreen(vm: ReaderViewModel) {
    var voiceMenu by remember { mutableStateOf(false) }
    Scaffold(
        topBar = { TopAppBar(title = { Text(vm.currentBook?.title ?: "阅读") }, navigationIcon = { TextButton(onClick = vm::closeBook) { Text("‹ 书库") } }, actions = { Text("Aa", modifier = Modifier.padding(16.dp)) }) },
        bottomBar = {
            Surface(tonalElevation = 4.dp) {
                Column(Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = vm::previous) { Text("上一段") }
                        Button(onClick = vm::playOrPause, modifier = Modifier.weight(1f)) { Text(if (vm.speechState == SpeechState.PLAYING) "暂停朗读" else "开始朗读") }
                        TextButton(onClick = vm::next) { Text("下一段") }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Box {
                            TextButton(onClick = { voiceMenu = true }) { Text(vm.voices.firstOrNull { it.id == vm.selectedVoiceId }?.name ?: "自动音色") }
                            DropdownMenu(expanded = voiceMenu, onDismissRequest = { voiceMenu = false }) {
                                DropdownMenuItem(text = { Text("自动匹配段落语言") }, onClick = { vm.chooseVoice(null); voiceMenu = false })
                                vm.voices.take(30).forEach { voice -> DropdownMenuItem(text = { Text("${voice.name} · ${voice.languageTag}") }, onClick = { vm.chooseVoice(voice.id); voiceMenu = false }) }
                            }
                        }
                        Text("${"%.1f".format(vm.rate)}×")
                        Slider(value = vm.rate, onValueChange = vm::updateRate, valueRange = .6f..1.6f, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().background(MaterialTheme.colorScheme.background).verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 24.dp)) {
            Text(vm.currentBook?.title ?: "阅读", style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onBackground)
            Text("${vm.currentBook?.format?.name} · 本地文件", color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp, bottom = 22.dp))
            vm.paragraphs.forEachIndexed { index, paragraph ->
                Text(paragraph, style = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Serif), modifier = Modifier.fillMaxWidth().background(if (index == vm.currentParagraph && vm.speechState != SpeechState.IDLE) MaterialTheme.colorScheme.secondaryContainer else Color.Transparent, RoundedCornerShape(8.dp)).clickable { vm.selectParagraph(index) }.padding(10.dp), color = MaterialTheme.colorScheme.onBackground)
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}
