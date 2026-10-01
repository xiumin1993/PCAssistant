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
 * v3.4 摄像头守护前台服务
 * ----------------------------------------------------------------------------
 * 与 MicForegroundService 同理：连上电脑后挂常驻通知保住进程，
 * 息屏时 PC 的 cam_state 指令才能唤醒相机。
 * 服务本身不开相机 —— 真正采集只在 PC 应用观看时才打开。
 * Android 14 起相机类前台服务要求 foregroundServiceType="camera"（见 Manifest）。
 */
class CamForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startAsForeground()
        return START_STICKY
    }

    private fun startAsForeground() {
        val channelId = "cam_standby"
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        // 同 MicForegroundService：文案进资源表，语言跟着 App 内设置走
        val ctx = localized()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            nm.createNotificationChannel(
                NotificationChannel(
                    channelId,
                    ctx.getString(R.string.notif_cam_channel),
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
            .setContentTitle(ctx.getString(R.string.notif_cam_title))
            .setContentText(ctx.getString(R.string.notif_cam_text))
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .build()
        startForeground(1003, notification)
    }
}
