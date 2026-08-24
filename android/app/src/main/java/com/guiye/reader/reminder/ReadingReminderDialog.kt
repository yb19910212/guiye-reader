package com.guiye.reader.reminder

import android.Manifest
import android.app.TimePickerDialog
import android.content.Intent
import android.os.Build
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp

@Composable
fun ReadingReminderDialog(onDismiss: () -> Unit) {
    val context = LocalContext.current
    val saved = remember { ReadingReminderScheduler.settings(context) }
    var enabled by remember { mutableStateOf(saved.enabled) }
    var hour by remember { mutableIntStateOf(saved.hour) }
    var minute by remember { mutableIntStateOf(saved.minute) }
    var permissionMessage by remember { mutableStateOf<String?>(null) }

    fun persistAndDismiss() {
        ReadingReminderScheduler.update(
            context = context,
            enabled = enabled,
            hour = hour,
            minute = minute,
        )
        onDismiss()
    }

    val notificationPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted && ReadingReminderScheduler.hasNotificationPermission(context)) {
            persistAndDismiss()
        } else {
            if (!granted) enabled = false
            ReadingReminderScheduler.update(
                context,
                enabled = false,
                hour = hour,
                minute = minute,
            )
            permissionMessage = if (granted) {
                "“每日阅读提醒”通知频道已被系统关闭，请在系统通知设置中重新开启。"
            } else {
                "未获得通知权限，阅读提醒已保持关闭。你可以稍后在系统设置中授权。"
            }
        }
    }

    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("每日阅读提醒") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(Modifier.weight(1f)) {
                        Text("开启提醒")
                        Text(
                            "每天大约在设定时间发送一次本地通知",
                            style = MaterialTheme.typography.bodySmall,
                        )
                    }
                    Switch(
                        checked = enabled,
                        onCheckedChange = {
                            enabled = it
                            permissionMessage = null
                        },
                    )
                }

                Text("提醒时间", style = MaterialTheme.typography.labelMedium)
                OutlinedButton(
                    onClick = {
                        TimePickerDialog(
                            context,
                            { _, selectedHour, selectedMinute ->
                                hour = selectedHour
                                minute = selectedMinute
                            },
                            hour,
                            minute,
                            true,
                        ).show()
                    },
                    enabled = enabled,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text("%02d:%02d".format(hour, minute))
                }

                Text("提醒内容", style = MaterialTheme.typography.labelMedium)
                Text(
                    ReadingReminderScheduler.messagePreview(context),
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )

                Text(
                    "提醒只保存在本机，不使用云推送。系统省电策略可能让通知比设定时间稍晚送达。",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                permissionMessage?.let {
                    Column(modifier = Modifier.padding(top = 4.dp)) {
                        Text(
                            it,
                            color = MaterialTheme.colorScheme.error,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        TextButton(onClick = {
                            val intent = Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS)
                                .putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
                            runCatching { context.startActivity(intent) }
                        }) { Text("打开系统通知设置") }
                    }
                }
            }
        },
        confirmButton = {
            Button(onClick = {
                if (
                    enabled &&
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                    !ReadingReminderScheduler.hasRuntimeNotificationPermission(context)
                ) {
                    notificationPermission.launch(Manifest.permission.POST_NOTIFICATIONS)
                } else if (enabled && !ReadingReminderScheduler.hasNotificationPermission(context)) {
                    ReadingReminderScheduler.update(context, false, hour, minute)
                    permissionMessage = "App 通知或“每日阅读提醒”频道已被系统关闭，请先在系统通知设置中开启。"
                } else {
                    persistAndDismiss()
                }
            }) {
                Text("保存")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("取消") }
        },
    )
}
