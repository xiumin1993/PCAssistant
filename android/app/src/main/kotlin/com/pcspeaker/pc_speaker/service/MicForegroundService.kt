package com.pcspeaker.pc_speaker.service

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import com.pcspeaker.pc_speaker.R
import com.pcspeaker.pc_speaker.localized

/**
 * v3.1 麦克风守护前台服务
 * ----------------------------------------------------------------------------
 * 作用：手机连上电脑后，把这个服务挂成"前台服务"（带一条常驻通知），
 * Android 就不会在息屏/后台时杀掉 App 进程 —— 这样 PC 端的唤醒指令
 * （mic_state）随时能送达、麦克风随时能启动，行为接近真实麦克风。
 *
 * 注意省电策略：本服务只负责"保命"（进程不被杀），
 * 并不开录音。真正的 AudioRecord 只在 PC 应用用到麦克风时才启动，
 * 用完即关 —— 耗电大户是麦克风硬件，不是这条通知。
 */
class MicForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        // START_STICKY：万一被系统回收，会尝试重建服务
        return START_STICKY
    }

    private fun startAsForeground() {
        val channelId = "mic_standby"
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        // v3.7 国际化：文案不写死中文，统一从资源表取（values/ = 英文，
        // values-zh/ = 中文），再由 localized() 按 App 内选的语言挑一份。
        // 已知限制：通知【渠道】名在渠道创建那刻就被系统记住了，之后换语言
        // 只会改通知的标题和正文，设置页里那条渠道名要等重装 App 才更新 ——
        // 这是安卓的硬规则（渠道删了不能再建同名），不是我们的疏忽。
        val ctx = localized()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // IMPORTANCE_LOW：通知栏常驻但无声无震动，不打扰
            nm.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    ctx.getString(R.string.notif_mic_channel),
                    NotificationManager.IMPORTANCE_LOW
                )
            )
        }
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, channelId)
        } else {
            @Suppress("DEPRECATION") Notification.Builder(this)
        }
        val notification = builder
            .setContentTitle(ctx.getString(R.string.notif_mic_title))
            .setContentText(ctx.getString(R.string.notif_mic_text))
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .build()
        startForeground(1002, notification)
    }

    override fun onDestroy() {
        super.onDestroy()
    }
}
