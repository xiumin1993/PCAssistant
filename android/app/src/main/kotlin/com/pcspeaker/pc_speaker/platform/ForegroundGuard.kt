package com.pcspeaker.pc_speaker.platform

import android.app.Activity
import android.app.Service
import android.content.Intent
import android.os.Build
import com.pcspeaker.pc_speaker.service.CamForegroundService
import com.pcspeaker.pc_speaker.service.MicForegroundService

/**
 * ForegroundGuard —— 两个"保命"前台服务的开关
 * ----------------------------------------------------------------------------
 * 麦克风和摄像头各有一条常驻通知（连上电脑时挂上，断开时摘掉），
 * 目的是让系统在息屏/后台时别把进程杀掉。启停逻辑本来写在 Activity 里，
 * 四个函数各自带着一份状态标记；挪到这里之后，Activity 只剩一句调用。
 */
class ForegroundGuard(private val activity: Activity) {

    private var micStarted = false
    private var camStarted = false

    fun startMic() {
        if (micStarted) return
        start(MicForegroundService::class.java)
        micStarted = true
    }

    fun stopMic() {
        if (!micStarted) return
        activity.stopService(Intent(activity, MicForegroundService::class.java))
        micStarted = false
    }

    fun startCam() {
        if (camStarted) return
        start(CamForegroundService::class.java)
        camStarted = true
    }

    fun stopCam() {
        if (!camStarted) return
        activity.stopService(Intent(activity, CamForegroundService::class.java))
        camStarted = false
    }

    /**
     * v3.7 国际化：语言切换后，把"已经在挂着"的常驻通知重发一遍。
     *
     * 为什么需要这一步：前台服务的通知是在 onStartCommand 里用当时的语言建好的，
     * 之后 App 内换语言并不会自动回去改它 —— 不重发就会出现"界面已中文、
     * 通知栏还是英文"的割裂，只有断开重连才纠正。
     *
     * 为什么直接再 startService 就够：服务已在运行时，startService 不会重建服务，
     * 只是再回调一次 onStartCommand；而 startForeground(同一个 id, 新通知)
     * 的语义就是"原地更新这条通知"。所以状态机（有没有在录音/开相机）完全不受影响。
     *
     * 为什么用 flag 判断而不是查系统：micStarted / camStarted 就是
     * 本 App 自己启停这两个服务的唯一入口，它们为 true 等价于服务在跑，
     * 比反射查 ActivityManager 轻得多也可靠得多。
     */
    fun refresh() {
        // 仍走 O+ 分支：对已运行的服务，startForegroundService 同样安全，
        // 且能避免万一进程刚被回收时踩到后台启动限制。
        if (micStarted) start(MicForegroundService::class.java)
        if (camStarted) start(CamForegroundService::class.java)
    }

    private fun start(cls: Class<out Service>) {
        val intent = Intent(activity, cls)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startForegroundService(intent)
        } else {
            activity.startService(intent)
        }
    }
}
