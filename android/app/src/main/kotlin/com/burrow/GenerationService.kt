package com.burrow

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * 一个只干一件事的前台服务：**模型还在回话的时候，别让系统把进程收了。**
 *
 * 为什么需要它：Android 对退到后台的普通进程没有任何承诺。用户按一下 Home
 * 键，几秒到几分钟之内进程就可能被回收 —— 而正在跑的那一轮请求随之消失，
 * 已经付过钱的 token 一起没了，回来看到的是半句话。这不是可以靠 Dart 侧
 * 写得更小心来解决的事：进程都不在了，代码在哪儿都一样。
 *
 * 前台服务是系统唯一认的那句"我这会儿真的在干活，别杀我"。代价是必须挂一条
 * 用户看得见的通知 —— 这个交换是对的：后台偷偷跑活儿本来就该被看见。
 *
 * 只在**真的在生成**的那几十秒里开着，一轮结束立刻停。常驻一条通知换不到
 * 任何东西，只会让人把整个 app 的通知关掉。
 */
class GenerationService : Service() {

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        ensureChannel()
        val notification = buildNotification(intent?.getStringExtra(EXTRA_TEXT))
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            // API 34 起必须报类型。这一轮干的事就是"等一个网络请求回来"，
            // dataSync 是唯一说得通的那个。
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        // 不要 START_STICKY：进程真被杀掉之后重启一个空的服务没有意义 ——
        // 那一轮对话的上下文全在已经死掉的那个 Dart VM 里。
        return START_NOT_STICKY
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "正在生成",
            // LOW：不出声、不横幅。它是一条状态，不是一件需要处理的事。
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "模型正在回话时显示，回完自动消失"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(text: String?): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Burrow 正在生成")
            .setContentText(text ?: "模型正在回话")
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentIntent(open)
            .setOngoing(true)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "burrow.generation"
        private const val NOTIFICATION_ID = 4801
        private const val EXTRA_TEXT = "text"

        fun start(context: Context, text: String?) {
            val intent = Intent(context, GenerationService::class.java)
                .putExtra(EXTRA_TEXT, text)
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GenerationService::class.java))
        }
    }
}
