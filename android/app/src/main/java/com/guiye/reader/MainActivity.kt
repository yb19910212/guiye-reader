package com.guiye.reader

import android.os.Bundle
import androidx.activity.ComponentActivity
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
import androidx.lifecycle.viewmodel.compose.viewModel
import com.guiye.reader.library.Book
import com.guiye.reader.speech.SpeechState

private val Paper = Color(0xFFF6F3EA)
private val Ink = Color(0xFF1E2B24)
private val Moss = Color(0xFF315F49)
private val Highlight = Color(0xFFE3ECDD)

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Moss, background = Paper, surface = Paper, onBackground = Ink)) {
                GuiyeApp()
            }
        }
    }
}

@Composable
private fun GuiyeApp(vm: ReaderViewModel = viewModel()) {
    if (vm.currentBook == null) LibraryScreen(vm) else ReaderScreen(vm)
}

@Composable
private fun LibraryScreen(vm: ReaderViewModel) {
    val importer = rememberLauncherForActivityResult(ActivityResultContracts.OpenMultipleDocuments()) { uris ->
        uris.forEach(vm::importBook)
    }
    Scaffold(
        topBar = { TopAppBar(title = { Text("归页") }, actions = { TextButton(onClick = { importer.launch(arrayOf("text/plain", "application/epub+zip", "application/pdf")) }) { Text("导入") } }) },
        floatingActionButton = { ExtendedFloatingActionButton(onClick = { importer.launch(arrayOf("text/plain", "application/epub+zip", "application/pdf")) }, text = { Text("导入书籍") }) }
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize().background(Paper).padding(horizontal = 20.dp)) {
            Text("我的书库", style = MaterialTheme.typography.headlineMedium, modifier = Modifier.padding(top = 18.dp))
            Text("书籍保存在本机 · EPUB / PDF / TXT", color = Moss, modifier = Modifier.padding(top = 5.dp, bottom = 20.dp))
            vm.importError?.let { Text(it, color = MaterialTheme.colorScheme.error, modifier = Modifier.padding(bottom = 12.dp)) }
            if (vm.books.isEmpty()) {
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Column(horizontalAlignment = Alignment.CenterHorizontally) {
                        Text("还没有书", style = MaterialTheme.typography.titleLarge)
                        Text("从系统文件选择器导入第一本电子书", color = Color.Gray, modifier = Modifier.padding(top = 8.dp))
                    }
                }
            } else {
                Column(Modifier.verticalScroll(rememberScrollState()), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    vm.books.forEach { BookRow(it, vm::openBook) }
                    Spacer(Modifier.height(90.dp))
                }
            }
        }
    }
}

@Composable
private fun BookRow(book: Book, open: (Book) -> Unit) {
    Surface(
        modifier = Modifier.fillMaxWidth().clickable { open(book) },
        shape = RoundedCornerShape(14.dp), color = Color.White.copy(alpha = .62f)
    ) {
        Row(Modifier.padding(14.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(width = 54.dp, height = 72.dp).background(Moss, RoundedCornerShape(5.dp)), contentAlignment = Alignment.Center) {
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
        Column(Modifier.padding(padding).fillMaxSize().background(Paper).verticalScroll(rememberScrollState()).padding(horizontal = 28.dp, vertical = 24.dp)) {
            Text(vm.currentBook?.title ?: "阅读", style = MaterialTheme.typography.headlineMedium, color = Ink)
            Text("${vm.currentBook?.format?.name} · 本地文件", color = Moss, modifier = Modifier.padding(top = 8.dp, bottom = 22.dp))
            vm.paragraphs.forEachIndexed { index, paragraph ->
                Text(paragraph, style = MaterialTheme.typography.bodyLarge.copy(fontFamily = FontFamily.Serif), modifier = Modifier.fillMaxWidth().background(if (index == vm.currentParagraph && vm.speechState != SpeechState.IDLE) Highlight else Color.Transparent, RoundedCornerShape(8.dp)).clickable { vm.currentParagraph = index }.padding(10.dp), color = Ink)
                Spacer(Modifier.height(8.dp))
            }
        }
    }
}
