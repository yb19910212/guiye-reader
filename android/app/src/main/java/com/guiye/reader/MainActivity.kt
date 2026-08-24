@file:OptIn(androidx.compose.material3.ExperimentalMaterial3Api::class)

package com.guiye.reader

import android.os.Bundle
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.fragment.app.FragmentActivity
import com.guiye.reader.epub.EpubReaderScreen
import com.guiye.reader.library.Book
import com.guiye.reader.library.BookFormat
import com.guiye.reader.pdf.PdfPageView
import com.guiye.reader.notes.NoteRepository
import com.guiye.reader.notes.BookmarkRepository
import com.guiye.reader.notes.ReadingNote
import com.guiye.reader.speech.SpeechState
import com.guiye.reader.opds.OpdsPage
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.launch
import com.guiye.reader.stats.ReadingStatsRepository
import com.guiye.reader.plans.ReadingPlanRepository
import com.guiye.reader.reminder.ReadingReminderDialog
import com.guiye.reader.reminder.ReadingReminderScheduler

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
        ReadingReminderScheduler.restoreIfEnabled(this)
        enableEdgeToEdge()
        setContent {
            val prefs = remember { getSharedPreferences("guiye_appearance", android.content.Context.MODE_PRIVATE) }
            var selectedTheme by remember { mutableStateOf(runCatching { ReaderTheme.valueOf(prefs.getString("theme", "PAPER") ?: "PAPER") }.getOrDefault(ReaderTheme.PAPER)) }
            MaterialTheme(colorScheme = selectedTheme.colors) {
                GuiyeApp(theme = selectedTheme, onThemeChange = { theme -> selectedTheme = theme; prefs.edit().putString("theme", theme.name).apply() })
            }
        }
    }
}

@Composable
private fun GuiyeApp(theme: ReaderTheme, onThemeChange: (ReaderTheme) -> Unit, vm: ReaderViewModel = viewModel()) {
    val lifecycleOwner = LocalLifecycleOwner.current
    val activeBookId = vm.currentBook?.id
    DisposableEffect(lifecycleOwner, activeBookId) {
        if (activeBookId != null) vm.startReadingSession()
        val observer = LifecycleEventObserver { _, event ->
            if (activeBookId != null && event == Lifecycle.Event.ON_RESUME) vm.startReadingSession()
            if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) vm.stopReadingSession()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer); vm.stopReadingSession() }
    }
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
    val readingStats = remember { ReadingStatsRepository(context) }
    val readingPlans = remember { ReadingPlanRepository(context) }
    var showsNotes by remember { mutableStateOf(false) }
    var noteSearch by remember { mutableStateOf("") }
    var noteVersion by remember { mutableIntStateOf(0) }
    var editingNote by remember { mutableStateOf<ReadingNote?>(null) }
    var noteDraft by remember { mutableStateOf("") }
    var noteTags by remember { mutableStateOf("") }
    val noteSnapshot = remember(noteVersion, showsNotes) { notes.all() }
    var showsAISettings by remember { mutableStateOf(false) }
    var showsOpds by remember { mutableStateOf(false) }
    var showsRemote by remember { mutableStateOf(false) }
    var showsThemes by remember { mutableStateOf(false) }
    var showsHistory by remember { mutableStateOf(false) }
    var showsStats by remember { mutableStateOf(false) }
    var showsPlans by remember { mutableStateOf(false) }
    var showsReminder by remember { mutableStateOf(false) }
    var showsMoreMenu by remember { mutableStateOf(false) }
    var editingBook by remember { mutableStateOf<Book?>(null) }
    var deletingBook by remember { mutableStateOf<Book?>(null) }
    var managing by remember { mutableStateOf(false) }
    var selectedIds by remember { mutableStateOf(setOf<String>()) }
    var searchText by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf("all") }
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        vm.importBooks(uris)
    }
    val backupImporter = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri -> uri?.let(vm::restoreBackup) }
    val folderImporter = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
        uri?.let {
            runCatching { context.contentResolver.takePersistableUriPermission(it, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION) }
            vm.importFolder(it)
        }
    }
    Scaffold(
        topBar = { TopAppBar(title = { Text("归页") }, actions = {
            Box {
                TextButton(onClick = { showsMoreMenu = true }) { Text("更多") }
                DropdownMenu(expanded = showsMoreMenu, onDismissRequest = { showsMoreMenu = false }) {
                    DropdownMenuItem(text = { Text("阅读笔记") }, onClick = { showsMoreMenu = false; showsNotes = true })
                    DropdownMenuItem(text = { Text("阅读历史") }, onClick = { showsMoreMenu = false; showsHistory = true })
                    DropdownMenuItem(text = { Text("阅读统计") }, onClick = { showsMoreMenu = false; showsStats = true })
                    DropdownMenuItem(text = { Text("读完计划") }, onClick = { showsMoreMenu = false; showsPlans = true })
                    DropdownMenuItem(text = { Text("每日提醒") }, onClick = { showsMoreMenu = false; showsReminder = true })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("AI 设置") }, onClick = { showsMoreMenu = false; showsAISettings = true })
                    DropdownMenuItem(text = { Text("外观主题") }, onClick = { showsMoreMenu = false; showsThemes = true })
                    DropdownMenuItem(text = { Text("WebDAV / SMB") }, onClick = { showsMoreMenu = false; showsRemote = true })
                    DropdownMenuItem(text = { Text("OPDS 书库") }, onClick = { showsMoreMenu = false; showsOpds = true })
                    HorizontalDivider()
                    DropdownMenuItem(text = { Text("导出完整备份") }, onClick = {
                        showsMoreMenu = false
                        val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply { type = "application/json"; putExtra(android.content.Intent.EXTRA_TEXT, vm.backupJson()) }
                        context.startActivity(android.content.Intent.createChooser(intent, "导出归页备份"))
                    })
                    DropdownMenuItem(text = { Text("从备份恢复") }, onClick = { showsMoreMenu = false; backupImporter.launch(arrayOf("application/json", "text/json", "text/plain")) })
                }
            }
            TextButton(onClick = { managing = !managing; if (!managing) selectedIds = emptySet() }) { Text(if (managing) "完成" else "管理") }
            TextButton(onClick = { importer.launch(arrayOf("text/plain", "application/epub+zip", "application/pdf")) }) { Text("导入") }
        }) },
        bottomBar = {
            if (managing) Surface(tonalElevation = 4.dp) {
                Row(Modifier.navigationBarsPadding().fillMaxWidth().padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("已选择 ${selectedIds.size} 本", Modifier.weight(1f))
                    Button(onClick = { vm.deleteBooks(selectedIds); selectedIds = emptySet(); managing = false }, enabled = selectedIds.isNotEmpty(), colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("删除") }
                }
            }
        },
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
                    }.forEach { book ->
                        BookRow(
                            book = book,
                            selected = book.id in selectedIds,
                            managing = managing,
                            open = { if (managing) selectedIds = if (book.id in selectedIds) selectedIds - book.id else selectedIds + book.id else vm.openBook(book) },
                            edit = { editingBook = book },
                            delete = { deletingBook = book }
                        )
                    }
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
                OutlinedTextField(noteSearch, { noteSearch = it }, label = { Text("搜索全部笔记") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                val filteredNotes = noteSnapshot.filter { noteSearch.isBlank() || it.bookTitle.contains(noteSearch, true) || it.text.contains(noteSearch, true) || (it.quote?.contains(noteSearch, true) == true) || it.tags.any { tag -> tag.contains(noteSearch, true) } }
                if (filteredNotes.isEmpty()) Text(if (noteSearch.isBlank()) "还没有笔记" else "没有找到相关笔记", modifier = Modifier.padding(vertical = 20.dp))
                filteredNotes.forEach { note ->
                    Text(note.bookTitle, style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(top = 12.dp))
                    note.quote?.let { Text("“$it”", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary, maxLines = 3) }
                    Text(note.text)
                    note.locator?.let { Text(it, style = MaterialTheme.typography.labelSmall) }
                    if (note.tags.isNotEmpty()) Text(note.tags.joinToString(" ") { "#$it" }, color = MaterialTheme.colorScheme.primary, style = MaterialTheme.typography.labelMedium)
                    Row {
                        TextButton(onClick = { editingNote = note; noteDraft = note.text; noteTags = note.tags.joinToString(", ") }) { Text("编辑") }
                        TextButton(onClick = { notes.remove(note.id); noteVersion++ }) { Text("删除", color = MaterialTheme.colorScheme.error) }
                    }
                    HorizontalDivider(Modifier.padding(vertical = 8.dp))
                }
            } },
            confirmButton = { TextButton(onClick = {
                val intent = android.content.Intent(android.content.Intent.ACTION_SEND).apply { type = "text/markdown"; putExtra(android.content.Intent.EXTRA_TEXT, notes.markdown()) }
                context.startActivity(android.content.Intent.createChooser(intent, "导出阅读笔记"))
            }) { Text("导出 Markdown") } },
            dismissButton = { TextButton(onClick = { showsNotes = false }) { Text("关闭") } }
        )
    }
    if (showsStats) ReadingStatsDialog(readingStats) { showsStats = false }
    if (showsPlans) ReadingPlansDialog(readingPlans, vm.books) { showsPlans = false }
    if (showsReminder) ReadingReminderDialog { showsReminder = false }
    editingNote?.let { note ->
        AlertDialog(
            onDismissRequest = { editingNote = null },
            title = { Text("编辑笔记") },
            text = { Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                OutlinedTextField(noteDraft, { noteDraft = it }, label = { Text("笔记") }, minLines = 5, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(noteTags, { noteTags = it }, label = { Text("标签，用逗号分隔") }, modifier = Modifier.fillMaxWidth())
            } },
            confirmButton = { TextButton(onClick = {
                notes.update(note.id, noteDraft, noteTags.split(',').map(String::trim).filter(String::isNotEmpty)); noteVersion++; editingNote = null
            }, enabled = noteDraft.isNotBlank()) { Text("保存") } },
            dismissButton = { TextButton(onClick = { editingNote = null }) { Text("取消") } }
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
    if (showsRemote) {
        RemoteLibraryDialog(vm, openSmbFolder = { folderImporter.launch(null) }) { showsRemote = false }
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
    if (showsHistory) {
        ReadingHistoryDialog(vm.books, open = { book -> showsHistory = false; vm.openBook(book) }) { showsHistory = false }
    }
    editingBook?.let { book ->
        var title by remember(book.id) { mutableStateOf(book.title) }
        var author by remember(book.id) { mutableStateOf(book.author.orEmpty()) }
        AlertDialog(
            onDismissRequest = { editingBook = null }, title = { Text("编辑书籍") },
            text = { Column { OutlinedTextField(title, { title = it }, label = { Text("书名") }, singleLine = true); OutlinedTextField(author, { author = it }, label = { Text("作者") }, singleLine = true) } },
            confirmButton = { Button(onClick = { vm.updateBookMetadata(book.id, title, author); editingBook = null }, enabled = title.isNotBlank()) { Text("保存") } },
            dismissButton = { TextButton(onClick = { editingBook = null }) { Text("取消") } }
        )
    }
    deletingBook?.let { book ->
        AlertDialog(
            onDismissRequest = { deletingBook = null }, title = { Text("删除《${book.title}》？") },
            text = { Text("将同时删除 App 本地书库中的文件，此操作无法撤销。") },
            confirmButton = { Button(onClick = { vm.deleteBooks(setOf(book.id)); deletingBook = null }, colors = ButtonDefaults.buttonColors(containerColor = MaterialTheme.colorScheme.error)) { Text("删除") } },
            dismissButton = { TextButton(onClick = { deletingBook = null }) { Text("取消") } }
        )
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
private fun BookRow(book: Book, selected: Boolean, managing: Boolean, open: () -> Unit, edit: () -> Unit, delete: () -> Unit) {
    var menu by remember { mutableStateOf(false) }
    Surface(
        modifier = Modifier.fillMaxWidth().clickable { open() },
        shape = RoundedCornerShape(14.dp), color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = .72f)
    ) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            if (managing) Checkbox(selected, onCheckedChange = { open() })
            Box(Modifier.size(width = 54.dp, height = 72.dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(5.dp)), contentAlignment = Alignment.Center) {
                Text(book.format.name, color = Color.White, style = MaterialTheme.typography.labelMedium)
            }
            Column(Modifier.padding(start = 14.dp).weight(1f)) {
                Text(book.title, style = MaterialTheme.typography.titleMedium)
                Text("${book.format.name} · ${formatBytes(book.fileSize)}", color = Color.Gray, modifier = Modifier.padding(top = 5.dp))
                LinearProgressIndicator(progress = { book.progress }, modifier = Modifier.fillMaxWidth().padding(top = 10.dp))
            }
            if (!managing) Box {
                TextButton(onClick = { menu = true }) { Text("⋯") }
                DropdownMenu(expanded = menu, onDismissRequest = { menu = false }) {
                    DropdownMenuItem(text = { Text("编辑书籍信息") }, onClick = { menu = false; edit() })
                    DropdownMenuItem(text = { Text("删除") }, onClick = { menu = false; delete() })
                }
            }
        }
    }
}

@Composable
private fun ReadingHistoryDialog(books: List<Book>, open: (Book) -> Unit, dismiss: () -> Unit) {
    val history = books.filter { it.lastOpenedAt != null }.sortedByDescending { it.lastOpenedAt }
    AlertDialog(
        onDismissRequest = dismiss, title = { Text("阅读历史") },
        text = { Column(Modifier.fillMaxWidth().heightIn(max = 520.dp).verticalScroll(rememberScrollState())) {
            if (history.isEmpty()) Text("还没有阅读历史，打开一本书后会自动记录。")
            history.forEach { book ->
                Surface(Modifier.fillMaxWidth().clickable { open(book) }.padding(vertical = 4.dp), color = MaterialTheme.colorScheme.surfaceVariant, shape = RoundedCornerShape(12.dp)) {
                    Column(Modifier.padding(12.dp)) {
                        Row { Text(book.title, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f)); Text("${(book.progress * 100).toInt()}%") }
                        LinearProgressIndicator(progress = { book.progress }, modifier = Modifier.fillMaxWidth().padding(vertical = 7.dp))
                        book.lastOpenedAt?.let { Text("上次阅读：${java.text.DateFormat.getDateTimeInstance().format(java.util.Date(it))}", style = MaterialTheme.typography.bodySmall) }
                    }
                }
            }
        } },
        confirmButton = { TextButton(onClick = dismiss) { Text("完成") } }
    )
}

private fun formatBytes(bytes: Long): String = when {
    bytes >= 1024 * 1024 -> "%.1f MB".format(bytes / 1024f / 1024f)
    bytes >= 1024 -> "%.1f KB".format(bytes / 1024f)
    else -> "$bytes B"
}

@Composable
private fun ReadingStatsDialog(repository: ReadingStatsRepository, dismiss: () -> Unit) {
    var goal by remember { mutableIntStateOf(repository.goalMinutes()) }
    val today = remember { repository.todaySeconds() }
    val streak = remember { repository.streak() }
    val days = remember { repository.lastSevenDays() }
    val weekday = remember { java.text.SimpleDateFormat("E", java.util.Locale.getDefault()) }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("阅读统计") },
        text = { Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text("今日 ${today / 60} 分钟 · 连续 $streak 天", style = MaterialTheme.typography.titleMedium)
            LinearProgressIndicator(progress = { (today.toFloat() / (goal * 60)).coerceIn(0f, 1f) }, modifier = Modifier.fillMaxWidth())
            Text("每日目标：$goal 分钟")
            Slider(value = goal.toFloat(), onValueChange = { goal = (it / 5).toInt() * 5 }, valueRange = 5f..180f, steps = 34)
            Row(Modifier.fillMaxWidth().height(130.dp), horizontalArrangement = Arrangement.spacedBy(7.dp), verticalAlignment = Alignment.Bottom) {
                days.forEach { day ->
                    Column(Modifier.weight(1f), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("${day.seconds / 60}", style = MaterialTheme.typography.labelSmall)
                        Box(Modifier.width(18.dp).height((day.seconds / 60f * 3f).coerceIn(4f, 90f).dp).background(MaterialTheme.colorScheme.primary, RoundedCornerShape(4.dp)))
                        Text(weekday.format(day.date), style = MaterialTheme.typography.labelSmall)
                    }
                }
            }
            Text("仅统计阅读页处于前台的时间。", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        } },
        confirmButton = { Button(onClick = { repository.setGoalMinutes(goal); dismiss() }) { Text("保存") } },
        dismissButton = { TextButton(onClick = dismiss) { Text("关闭") } }
    )
}

@Composable
private fun ReadingPlansDialog(repository: ReadingPlanRepository, books: List<Book>, dismiss: () -> Unit) {
    var selectedIndex by remember { mutableIntStateOf(0) }
    var days by remember { mutableIntStateOf(30) }
    var version by remember { mutableIntStateOf(0) }
    val plans = remember(version) { repository.all() }
    val dateFormat = remember { java.text.DateFormat.getDateInstance(java.text.DateFormat.MEDIUM) }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("读完计划") },
        text = { Column(Modifier.fillMaxWidth().heightIn(max = 580.dp).verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
            if (books.isNotEmpty()) {
                TextButton(onClick = { selectedIndex = (selectedIndex + 1) % books.size }, modifier = Modifier.fillMaxWidth()) {
                    Text("书籍：${books[selectedIndex.coerceIn(0, books.lastIndex)].title}（点击切换）", modifier = Modifier.fillMaxWidth())
                }
                Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    listOf(7, 14, 30, 60).forEach { value -> FilterChip(selected = days == value, onClick = { days = value }, label = { Text("$value 天") }) }
                }
                Button(onClick = { repository.set(books[selectedIndex.coerceIn(0, books.lastIndex)], days); version++ }, modifier = Modifier.fillMaxWidth()) { Text("开始读完计划") }
            }
            HorizontalDivider()
            if (plans.isEmpty()) Text("还没有读完计划", color = MaterialTheme.colorScheme.onSurfaceVariant)
            plans.forEach { plan ->
                val progress = books.firstOrNull { it.id == plan.bookId }?.progress ?: 0f
                val remainingDays = kotlin.math.ceil((plan.deadline - System.currentTimeMillis()) / 86_400_000.0).toInt()
                val daily = (1f - progress).coerceAtLeast(0f) / remainingDays.coerceAtLeast(1) * 100
                Column(Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.surfaceVariant, RoundedCornerShape(12.dp)).padding(12.dp)) {
                    Row { Text(plan.bookTitle, style = MaterialTheme.typography.titleSmall, modifier = Modifier.weight(1f)); Text("${(progress * 100).toInt()}%") }
                    LinearProgressIndicator(progress = { progress }, modifier = Modifier.fillMaxWidth().padding(vertical = 7.dp))
                    Text(when {
                        progress >= .98f -> "已完成计划"
                        remainingDays < 0 -> "已逾期 ${-remainingDays} 天"
                        else -> "截止 ${dateFormat.format(java.util.Date(plan.deadline))} · 每天至少 ${"%.1f".format(daily)}%"
                    }, style = MaterialTheme.typography.bodySmall)
                    TextButton(onClick = { repository.remove(plan.bookId); version++ }) { Text("删除计划", color = MaterialTheme.colorScheme.error) }
                }
            }
        } },
        confirmButton = { TextButton(onClick = dismiss) { Text("完成") } }
    )
}

@Composable
private fun ReaderScreen(vm: ReaderViewModel) {
    var showsVoiceLibrary by remember { mutableStateOf(false) }
    var showsContents by remember { mutableStateOf(false) }
    var showsSearch by remember { mutableStateOf(false) }
    var showsAppearance by remember { mutableStateOf(false) }
    var showsAnnotation by remember { mutableStateOf(false) }
    var showsHighlighter by remember { mutableStateOf(false) }
    var annotationDraft by remember { mutableStateOf("") }
    var annotationTags by remember { mutableStateOf("") }
    var bookmarkVersion by remember { mutableIntStateOf(0) }
    var readerNoteVersion by remember { mutableIntStateOf(0) }
    val context = androidx.compose.ui.platform.LocalContext.current
    val notes = remember { NoteRepository(context) }
    val bookmarks = remember { BookmarkRepository(context) }
    val preferences = remember { context.getSharedPreferences("text_reader_appearance", android.content.Context.MODE_PRIVATE) }
    var fontSize by remember { mutableFloatStateOf(preferences.getFloat("font_size", 20f)) }
    var lineSpacing by remember { mutableFloatStateOf(preferences.getFloat("line_spacing", 9f)) }
    var paragraphSpacing by remember { mutableFloatStateOf(preferences.getFloat("paragraph_spacing", 8f)) }
    var horizontalPadding by remember { mutableFloatStateOf(preferences.getFloat("horizontal_padding", 28f)) }
    val listState = rememberLazyListState()
    val scope = rememberCoroutineScope()
    val lifecycleOwner = LocalLifecycleOwner.current
    val bookId = vm.currentBook?.id
    val currentBookmarks = remember(bookId, bookmarkVersion) { bookId?.let(bookmarks::forBook).orEmpty() }
    val currentHighlights = remember(bookId, readerNoteVersion) { bookId?.let(notes::highlights).orEmpty() }
    val isCurrentBookmarked = currentBookmarks.any { it.paragraphIndex == vm.currentParagraph }

    LaunchedEffect(bookId, vm.paragraphs.size) {
        if (bookId == null || vm.paragraphs.firstOrNull() == "正在载入正文…") return@LaunchedEffect
        vm.startReadingSession()
        listState.scrollToItem((vm.currentParagraph + 1).coerceAtMost(vm.paragraphs.size))
        snapshotFlow { listState.firstVisibleItemIndex }
            .distinctUntilChanged()
            .collectLatest { visibleItem ->
                delay(250)
                vm.recordTextScrollPosition((visibleItem - 1).coerceAtLeast(0))
            }
    }

    DisposableEffect(lifecycleOwner, bookId) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_RESUME) vm.startReadingSession()
            if (event == Lifecycle.Event.ON_PAUSE || event == Lifecycle.Event.ON_STOP) { vm.stopReadingSession(); vm.flushTextPosition() }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            vm.stopReadingSession()
            vm.flushTextPosition()
        }
    }
    Scaffold(
        topBar = { TopAppBar(
            title = { Text(vm.currentBook?.title ?: "阅读") },
            navigationIcon = { TextButton(onClick = vm::closeBook) { Text("‹ 书库") } },
            actions = {
                TextButton(onClick = {
                    vm.currentBook?.let { book -> bookmarks.toggle(book, vm.currentParagraph, vm.paragraphs.getOrElse(vm.currentParagraph) { "" }); bookmarkVersion++ }
                }) { Text(if (isCurrentBookmarked) "已存" else "书签") }
                TextButton(onClick = { annotationDraft = ""; annotationTags = ""; showsAnnotation = true }) { Text("批注") }
                TextButton(onClick = { showsHighlighter = true }) { Text("高亮") }
                TextButton(onClick = { showsSearch = true }) { Text("搜索") }
                TextButton(onClick = { showsContents = true }) { Text("目录") }
                TextButton(onClick = { showsAppearance = true }) { Text("Aa") }
            }
        ) },
        bottomBar = {
            Surface(tonalElevation = 4.dp) {
                Column(Modifier.navigationBarsPadding().padding(horizontal = 16.dp, vertical = 10.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        TextButton(onClick = vm::previous) { Text("上一段") }
                        Button(onClick = vm::playOrPause, modifier = Modifier.weight(1f)) { Text(if (vm.speechState == SpeechState.PLAYING) "暂停朗读" else "开始朗读") }
                        TextButton(onClick = vm::next) { Text("下一段") }
                    }
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        TextButton(onClick = { showsVoiceLibrary = true }) { Text(vm.voices.firstOrNull { it.id == vm.selectedVoiceId }?.name ?: "自动音色") }
                        Text("${"%.1f".format(vm.rate)}×")
                        Slider(value = vm.rate, onValueChange = vm::updateRate, valueRange = .6f..1.6f, modifier = Modifier.weight(1f))
                    }
                }
            }
        }
    ) { padding ->
        LazyColumn(state = listState, modifier = Modifier.padding(padding).fillMaxSize().background(MaterialTheme.colorScheme.background).padding(horizontal = horizontalPadding.dp), contentPadding = PaddingValues(vertical = 24.dp)) {
            item {
                Text(vm.currentBook?.title ?: "阅读", style = MaterialTheme.typography.headlineMedium, color = MaterialTheme.colorScheme.onBackground)
                Text("${vm.currentBook?.format?.name} · 本地文件", color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(top = 8.dp, bottom = 22.dp))
            }
            itemsIndexed(vm.paragraphs, key = { index, _ -> index }) { index, paragraph ->
                val isBookmarked = currentBookmarks.any { it.paragraphIndex == index }
                val paragraphColor = when {
                    index == vm.currentParagraph && vm.speechState != SpeechState.IDLE -> MaterialTheme.colorScheme.secondaryContainer
                    currentHighlights["第 ${index + 1} 段"]?.color == "green" -> Color(0xFFB8E0B8).copy(alpha = 0.48f)
                    currentHighlights["第 ${index + 1} 段"]?.color == "blue" -> Color(0xFFB8D8F0).copy(alpha = 0.48f)
                    currentHighlights["第 ${index + 1} 段"]?.color == "pink" -> Color(0xFFF2BDD0).copy(alpha = 0.48f)
                    currentHighlights.containsKey("第 ${index + 1} 段") -> Color(0xFFFFE58A).copy(alpha = 0.55f)
                    isBookmarked -> MaterialTheme.colorScheme.primary.copy(alpha = 0.12f)
                    else -> Color.Transparent
                }
                Text(paragraph, style = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Serif, fontSize = fontSize.sp, lineHeight = (fontSize + lineSpacing).sp), modifier = Modifier.fillMaxWidth().background(paragraphColor, RoundedCornerShape(8.dp)).clickable { vm.selectParagraph(index) }.padding(10.dp), color = MaterialTheme.colorScheme.onBackground)
                Spacer(Modifier.height(paragraphSpacing.dp))
            }
        }
    }
    if (showsVoiceLibrary) VoiceLibraryDialog(vm) { showsVoiceLibrary = false }
    if (showsContents) AlertDialog(
        onDismissRequest = { showsContents = false },
        title = { Text("章节目录") },
        text = {
            LazyColumn(Modifier.fillMaxWidth().heightIn(max = 560.dp)) {
                item { Text("章节", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(12.dp)) }
                itemsIndexed(vm.textChapters) { _, chapter ->
                    TextButton(onClick = {
                        vm.selectParagraph(chapter.index)
                        scope.launch { listState.animateScrollToItem(chapter.index + 1) }
                        showsContents = false
                    }, modifier = Modifier.fillMaxWidth()) {
                        Text(chapter.title, modifier = Modifier.weight(1f))
                        Text("第 ${chapter.index + 1} 段", style = MaterialTheme.typography.labelSmall)
                    }
                }
                if (currentBookmarks.isNotEmpty()) {
                    item { HorizontalDivider(); Text("书签", style = MaterialTheme.typography.titleSmall, modifier = Modifier.padding(12.dp)) }
                    itemsIndexed(currentBookmarks) { _, bookmark ->
                        TextButton(onClick = {
                            vm.selectParagraph(bookmark.paragraphIndex)
                            scope.launch { listState.animateScrollToItem(bookmark.paragraphIndex + 1) }
                            showsContents = false
                        }, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth()) {
                                Text(bookmark.excerpt, maxLines = 2, color = MaterialTheme.colorScheme.onSurface)
                                Text("第 ${bookmark.paragraphIndex + 1} 段", style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = { showsContents = false }) { Text("完成") } }
    )
    if (showsSearch) TextSearchDialog(vm, onSelect = { index ->
        vm.selectParagraph(index)
        scope.launch { listState.animateScrollToItem(index + 1) }
        showsSearch = false
    }, dismiss = { showsSearch = false })
    if (showsAppearance) AlertDialog(
        onDismissRequest = { showsAppearance = false },
        title = { Text("阅读排版") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                AppearanceSlider("字号", fontSize, 14f..34f) { fontSize = it; preferences.edit().putFloat("font_size", it).apply() }
                AppearanceSlider("行距", lineSpacing, 2f..20f) { lineSpacing = it; preferences.edit().putFloat("line_spacing", it).apply() }
                AppearanceSlider("段距", paragraphSpacing, 4f..28f) { paragraphSpacing = it; preferences.edit().putFloat("paragraph_spacing", it).apply() }
                AppearanceSlider("页边距", horizontalPadding, 12f..48f) { horizontalPadding = it; preferences.edit().putFloat("horizontal_padding", it).apply() }
                TextButton(onClick = {
                    fontSize = 20f; lineSpacing = 9f; paragraphSpacing = 8f; horizontalPadding = 28f
                    preferences.edit().clear().apply()
                }) { Text("恢复默认排版") }
            }
        },
        confirmButton = { TextButton(onClick = { showsAppearance = false }) { Text("完成") } }
    )
    if (showsAnnotation) AlertDialog(
        onDismissRequest = { showsAnnotation = false },
        title = { Text("段落批注") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(vm.paragraphs.getOrElse(vm.currentParagraph) { "" }, maxLines = 5, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.primary)
                OutlinedTextField(annotationDraft, { annotationDraft = it }, label = { Text("写下想法") }, minLines = 5, modifier = Modifier.fillMaxWidth())
                OutlinedTextField(annotationTags, { annotationTags = it }, label = { Text("标签，用逗号分隔") }, modifier = Modifier.fillMaxWidth())
            }
        },
        confirmButton = { TextButton(onClick = {
            vm.currentBook?.let { book -> notes.addAnnotation(book, annotationDraft, vm.paragraphs.getOrElse(vm.currentParagraph) { "" }, "第 ${vm.currentParagraph + 1} 段", annotationTags.split(',').map(String::trim).filter(String::isNotEmpty)) }
            annotationTags = ""; readerNoteVersion++
            showsAnnotation = false
        }, enabled = annotationDraft.isNotBlank()) { Text("保存") } },
        dismissButton = { TextButton(onClick = { showsAnnotation = false }) { Text("取消") } }
    )
    if (showsHighlighter) AlertDialog(
        onDismissRequest = { showsHighlighter = false },
        title = { Text("段落高亮") },
        text = { Column {
            listOf("yellow" to "黄色", "green" to "绿色", "blue" to "蓝色", "pink" to "粉色").forEach { (color, label) ->
                TextButton(onClick = {
                    vm.currentBook?.let { notes.setHighlight(it, vm.paragraphs.getOrElse(vm.currentParagraph) { "" }, "第 ${vm.currentParagraph + 1} 段", color) }
                    readerNoteVersion++; showsHighlighter = false
                }, modifier = Modifier.fillMaxWidth()) { Text(label, modifier = Modifier.fillMaxWidth()) }
            }
        } },
        confirmButton = { TextButton(onClick = {
            vm.currentBook?.let { notes.setHighlight(it, vm.paragraphs.getOrElse(vm.currentParagraph) { "" }, "第 ${vm.currentParagraph + 1} 段", null) }
            readerNoteVersion++; showsHighlighter = false
        }) { Text("移除高亮") } },
        dismissButton = { TextButton(onClick = { showsHighlighter = false }) { Text("取消") } }
    )
}

@Composable
private fun TextSearchDialog(vm: ReaderViewModel, onSelect: (Int) -> Unit, dismiss: () -> Unit) {
    var query by remember { mutableStateOf("") }
    val results = remember(query, vm.paragraphs) {
        if (query.isBlank()) emptyList() else vm.paragraphs.mapIndexedNotNull { index, paragraph ->
            if (paragraph.contains(query.trim(), ignoreCase = true)) index to paragraph else null
        }.take(100)
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("正文搜索") },
        text = {
            Column(Modifier.fillMaxWidth().heightIn(max = 600.dp)) {
                OutlinedTextField(query, { query = it }, label = { Text("搜索本书正文") }, singleLine = true, modifier = Modifier.fillMaxWidth())
                if (query.isNotBlank() && results.isEmpty()) Text("没有找到相关内容", modifier = Modifier.padding(vertical = 24.dp))
                LazyColumn(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                    itemsIndexed(results) { _, result ->
                        TextButton(onClick = { onSelect(result.first) }, modifier = Modifier.fillMaxWidth()) {
                            Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.Start) {
                                Text(result.second, maxLines = 3, color = MaterialTheme.colorScheme.onSurface)
                                Text("第 ${result.first + 1} 段", style = MaterialTheme.typography.labelSmall)
                            }
                        }
                    }
                }
            }
        },
        confirmButton = { TextButton(onClick = dismiss) { Text("完成") } }
    )
}

@Composable
private fun AppearanceSlider(title: String, value: Float, range: ClosedFloatingPointRange<Float>, onChange: (Float) -> Unit) {
    Column {
        Row { Text(title); Spacer(Modifier.weight(1f)); Text(value.toInt().toString()) }
        Slider(value = value, onValueChange = onChange, valueRange = range, steps = (range.endInclusive - range.start).toInt() - 1)
    }
}

@Composable
private fun VoiceLibraryDialog(vm: ReaderViewModel, dismiss: () -> Unit) {
    val context = androidx.compose.ui.platform.LocalContext.current
    var query by remember { mutableStateOf("") }
    var language by remember { mutableStateOf("all") }
    var highQualityOnly by remember { mutableStateOf(true) }
    val voices = vm.voices.filter { voice ->
        (!highQualityOnly || voice.quality >= 400)
            && (language == "all" || voice.languageTag.startsWith(language))
            && (query.isBlank() || voice.name.contains(query, true) || voice.languageTag.contains(query, true) || voice.qualityLabel.contains(query, true))
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("智能语音") },
        text = { Column(Modifier.fillMaxWidth().heightIn(max = 600.dp)) {
            OutlinedTextField(query, { query = it }, label = { Text("搜索音色或语言") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).padding(vertical = 6.dp), horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                listOf("all" to "全部", "zh" to "中文", "en" to "英语", "ja" to "日语", "ko" to "韩语").forEach { (value, label) ->
                    FilterChip(selected = language == value, onClick = { language = value }, label = { Text(label) })
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text("只看高品质音色", Modifier.weight(1f)); Switch(highQualityOnly, { highQualityOnly = it })
            }
            TextButton(onClick = { vm.chooseVoice(null) }) { Text(if (vm.selectedVoiceId == null) "✓ 自动匹配每段语言" else "自动匹配每段语言") }
            if (voices.isEmpty()) Text("没有匹配的高品质音色，可关闭筛选或下载更多语音数据。", color = MaterialTheme.colorScheme.secondary)
            Column(Modifier.weight(1f).verticalScroll(rememberScrollState())) {
                voices.forEach { voice ->
                    Row(Modifier.fillMaxWidth().clickable { vm.chooseVoice(voice.id) }.padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(voice.name, style = MaterialTheme.typography.titleSmall)
                            Text("${voice.languageTag} · ${voice.qualityLabel}${if (voice.isNetworkRequired) " · 联网" else " · 本地"}", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.secondary)
                        }
                        if (vm.selectedVoiceId == voice.id) Text("✓", color = MaterialTheme.colorScheme.primary)
                        TextButton(onClick = { vm.previewVoice(voice) }) { Text("试听") }
                    }
                    HorizontalDivider()
                }
            }
            TextButton(onClick = {
                val intent = android.content.Intent(android.speech.tts.TextToSpeech.Engine.ACTION_INSTALL_TTS_DATA)
                runCatching { context.startActivity(intent) }.onFailure { context.startActivity(android.content.Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)) }
            }) { Text("下载更多系统音色") }
            Text("音色数量取决于系统语音引擎；可安装 Google、Samsung 等 TTS 引擎。", style = MaterialTheme.typography.bodySmall)
        } },
        confirmButton = { TextButton(onClick = dismiss) { Text("完成") } }
    )
}
