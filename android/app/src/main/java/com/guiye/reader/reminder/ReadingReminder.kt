package com.guiye.reader.reminder

import android.Manifest
import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import com.guiye.reader.MainActivity
import com.guiye.reader.R
import com.guiye.reader.plans.ReadingPlanRepository
import com.guiye.reader.stats.ReadingStatsRepository
import java.util.Calendar

data class ReadingReminderSettings(
    val enabled: Boolean,
    val hour: Int,
    val minute: Int,
)

object ReadingReminderScheduler {
    const val PREFERENCES_NAME = "guiye_reading_reminder"
    const val KEY_ENABLED = "enabled"
    const val KEY_HOUR = "hour"
    const val KEY_MINUTE = "minute"

    private const val DEFAULT_HOUR = 20
    private const val DEFAULT_MINUTE = 30
    private const val CHANNEL_ID = "daily_reading_reminder"
    private const val NOTIFICATION_ID = 3107
    private const val ALARM_REQUEST_CODE = 3108
    private const val OPEN_APP_REQUEST_CODE = 3109
    internal const val ACTION_REMIND = "com.guiye.reader.action.DAILY_READING_REMINDER"

    fun settings(context: Context): ReadingReminderSettings {
        val preferences = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
        return ReadingReminderSettings(
            enabled = preferences.getBoolean(KEY_ENABLED, false),
            hour = preferences.getInt(KEY_HOUR, DEFAULT_HOUR).coerceIn(0, 23),
            minute = preferences.getInt(KEY_MINUTE, DEFAULT_MINUTE).coerceIn(0, 59),
        )
    }

    fun update(context: Context, enabled: Boolean, hour: Int, minute: Int) {
        val safeHour = hour.coerceIn(0, 23)
        val safeMinute = minute.coerceIn(0, 59)
        context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(KEY_ENABLED, enabled)
            .putInt(KEY_HOUR, safeHour)
            .putInt(KEY_MINUTE, safeMinute)
            .apply()

        if (enabled) {
            ensureNotificationChannel(context)
            scheduleNext(context, safeHour, safeMinute)
        } else {
            cancel(context)
        }
    }

    fun restoreIfEnabled(context: Context) {
        val settings = settings(context)
        if (settings.enabled && hasNotificationPermission(context)) {
            ensureNotificationChannel(context)
            scheduleNext(context, settings.hour, settings.minute)
        } else {
            cancel(context)
        }
    }

    fun hasRuntimeNotificationPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED

    fun hasNotificationPermission(context: Context): Boolean {
        if (!hasRuntimeNotificationPermission(context)) return false
        val manager = context.getSystemService(NotificationManager::class.java)
        if (!manager.areNotificationsEnabled()) return false
        val channel = manager.getNotificationChannel(CHANNEL_ID)
        return channel == null || channel.importance != NotificationManager.IMPORTANCE_NONE
    }

    fun ensureNotificationChannel(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        val channel = NotificationChannel(
            CHANNEL_ID,
            "每日阅读提醒",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "在你设置的时间提醒继续阅读"
            setShowBadge(true)
        }
        manager.createNotificationChannel(channel)
    }

    internal fun nextTriggerMillis(hour: Int, minute: Int, nowMillis: Long = System.currentTimeMillis()): Long {
        return Calendar.getInstance().apply {
            timeInMillis = nowMillis
            set(Calendar.HOUR_OF_DAY, hour.coerceIn(0, 23))
            set(Calendar.MINUTE, minute.coerceIn(0, 59))
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
            if (timeInMillis <= nowMillis) add(Calendar.DAY_OF_YEAR, 1)
        }.timeInMillis
    }

    private fun scheduleNext(context: Context, hour: Int, minute: Int) {
        val alarmManager = context.getSystemService(AlarmManager::class.java)
        val pendingIntent = alarmPendingIntent(context)
        alarmManager.cancel(pendingIntent)
        alarmManager.setAndAllowWhileIdle(
            AlarmManager.RTC_WAKEUP,
            nextTriggerMillis(hour, minute),
            pendingIntent,
        )
    }

    private fun cancel(context: Context) {
        context.getSystemService(AlarmManager::class.java).cancel(alarmPendingIntent(context))
        context.getSystemService(NotificationManager::class.java).cancel(NOTIFICATION_ID)
    }

    private fun alarmPendingIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(
        context,
        ALARM_REQUEST_CODE,
        Intent(context, ReadingReminderReceiver::class.java).setAction(ACTION_REMIND),
        PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
    )

    internal fun showNotification(context: Context) {
        if (!hasNotificationPermission(context)) return
        ensureNotificationChannel(context)
        val openApp = PendingIntent.getActivity(
            context,
            OPEN_APP_REQUEST_CODE,
            Intent(context, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val notification = Notification.Builder(context, CHANNEL_ID)
            .setSmallIcon(R.drawable.ic_reading_reminder)
            .setContentTitle("该读一会儿书了")
            .setContentText(messagePreview(context))
            .setContentIntent(openApp)
            .setAutoCancel(true)
            .setCategory(Notification.CATEGORY_REMINDER)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .build()
        context.getSystemService(NotificationManager::class.java).notify(NOTIFICATION_ID, notification)
    }

    fun messagePreview(context: Context): String {
        val goalMinutes = ReadingStatsRepository(context).goalMinutes()
        val startOfToday = Calendar.getInstance().apply {
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }.timeInMillis
        val plan = ReadingPlanRepository(context).all()
            .filter { it.deadline >= startOfToday }
            .minByOrNull { it.deadline }
        return if (plan != null) {
            "继续《${plan.bookTitle}》的读完计划，今天也完成 $goalMinutes 分钟目标吧。"
        } else {
            "今天读 $goalMinutes 分钟，让阅读进度再向前一点。"
        }
    }
}

class ReadingReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ReadingReminderScheduler.ACTION_REMIND) return
        val settings = ReadingReminderScheduler.settings(context)
        if (!settings.enabled) return
        ReadingReminderScheduler.showNotification(context)
        ReadingReminderScheduler.restoreIfEnabled(context)
    }
}

class ReadingReminderSystemReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_MY_PACKAGE_REPLACED,
            Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED,
            -> ReadingReminderScheduler.restoreIfEnabled(context)
        }
    }
}
