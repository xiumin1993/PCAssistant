package com.pcspeaker.pc_speaker.platform

import android.app.Activity
import android.content.pm.PackageManager
import io.flutter.plugin.common.MethodChannel

/**
 * PermissionRequester —— 危险的运行时权限的"问与答"
 * ----------------------------------------------------------------------------
 * 系统权限弹窗是异步的：用户点"允许/拒绝"之前，得先把 Flutter 的回调
 * 存起来，等 onRequestPermissionsResult 回来再应答。
 * 麦克风和相机都要这套流程，各写一份就会有两份 pending 字段和两个
 * requestCode 要维护 —— 收在这里，Activity 只负责把系统回调转过来。
 */
class PermissionRequester(private val activity: Activity) {

    /** requestCode → 还在等答复的 Flutter 回调 */
    private val pending = HashMap<Int, MethodChannel.Result>()

    /** 静默查询（不弹系统窗） */
    fun has(permission: String): Boolean =
        activity.checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    /**
     * 申请权限。已授予就直接回 true；否则弹系统窗，
     * 结果由 [onResult] 通过暂存的回调回传给 Flutter。
     */
    fun request(permission: String, requestCode: Int, result: MethodChannel.Result) {
        if (has(permission)) {
            result.success(true)
            return
        }
        pending[requestCode] = result
        activity.requestPermissions(arrayOf(permission), requestCode)
    }

    /** Activity 的 onRequestPermissionsResult 转到这里 */
    fun onResult(requestCode: Int, grantResults: IntArray) {
        val callback = pending.remove(requestCode) ?: return
        val granted =
            grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        callback.success(granted)
    }
}
