package com.guiye.reader

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.guiye.reader.remote.WebDavItem

@Composable
fun RemoteLibraryDialog(vm: ReaderViewModel, openSmbFolder: () -> Unit, dismiss: () -> Unit) {
    var address by remember { mutableStateOf("") }
    var username by remember { mutableStateOf("") }
    var password by remember { mutableStateOf("") }
    var items by remember { mutableStateOf<List<WebDavItem>>(emptyList()) }
    var loading by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }
    var requestAddress by remember { mutableStateOf<String?>(null) }
    LaunchedEffect(requestAddress) {
        val value = requestAddress ?: return@LaunchedEffect
        loading = true; message = null
        vm.loadWebDav(value, username, password).onSuccess { items = it }.onFailure { message = it.message }
        loading = false; requestAddress = null
    }
    AlertDialog(
        onDismissRequest = dismiss,
        title = { Text("网络书库") },
        text = { Column(Modifier.fillMaxWidth().heightIn(max = 600.dp).verticalScroll(rememberScrollState())) {
            Text("WebDAV", style = MaterialTheme.typography.titleMedium)
            OutlinedTextField(address, { address = it }, label = { Text("HTTPS WebDAV 文件夹地址") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(username, { username = it }, label = { Text("用户名") }, singleLine = true, modifier = Modifier.weight(1f))
                OutlinedTextField(password, { password = it }, label = { Text("密码") }, singleLine = true, visualTransformation = PasswordVisualTransformation(), modifier = Modifier.weight(1f))
            }
            Button(onClick = { requestAddress = address.trim() }, enabled = !loading && address.isNotBlank(), modifier = Modifier.padding(vertical = 8.dp)) { Text("打开远程文件夹") }
            if (loading) LinearProgressIndicator(Modifier.fillMaxWidth())
            message?.let { Text(it, color = MaterialTheme.colorScheme.primary) }
            if (items.any { !it.isDirectory && it.isBook }) Button(onClick = {
                loading = true; vm.importWebDav(items.filter { !it.isDirectory && it.isBook }, username, password) { result -> loading = false; message = result }
            }) { Text("导入当前文件夹全部书籍") }
            items.forEach { item ->
                Row(Modifier.fillMaxWidth().padding(vertical = 5.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text((if (item.isDirectory) "📁 " else "📖 ") + item.name, Modifier.weight(1f))
                    TextButton(onClick = {
                        if (item.isDirectory) { address = item.url; requestAddress = item.url }
                        else { loading = true; vm.importWebDav(listOf(item), username, password) { result -> loading = false; message = result } }
                    }) { Text(if (item.isDirectory) "打开" else "导入") }
                }
            }
            HorizontalDivider(Modifier.padding(vertical = 14.dp))
            Text("SMB 网络文件夹", style = MaterialTheme.typography.titleMedium)
            Text("通过 Android 系统文件提供器选择已连接的 SMB 文件夹，归页会递归导入其中的 EPUB、PDF 和 TXT。", style = MaterialTheme.typography.bodySmall)
            Button(onClick = openSmbFolder, modifier = Modifier.padding(top = 8.dp)) { Text("选择 SMB / 网络文件夹") }
        } },
        confirmButton = { TextButton(onClick = dismiss) { Text("完成") } }
    )
}
