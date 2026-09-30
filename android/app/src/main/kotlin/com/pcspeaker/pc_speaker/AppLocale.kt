package com.pcspeaker.pc_speaker

import android.content.Context
import android.content.res.Configuration
import java.util.Locale

/**
 * AppLocale —— 原生层的"当前用哪种语言"（v3.7 国际化）
 * ----------------------------------------------------------------------------
 * Flutter 界面上的语言是 MaterialApp 的 locale 决定的，但通知栏文案、
 * 桌面应用名这些由安卓系统渲染的字，看的是 res/values-<语言>/ 资源目录。
 * 两套机制要同步，否则会出现"App 里是英文、通知栏还是中文"的割裂感。
 *
 * 同步方式：Flutter 每次改语言都通过 com.pcspeaker/audio 通道的 setLocale
 * 把选择告诉这里，这里落进 SharedPreferences（前台服务是另一个入口，
 * 它启动时要能读到上次的选择，不能只存在内存里）。
 *
 * 存的是"用户的选择"而不是"算出来的结果"：
 *   null  = auto，跟随系统（什么都不做，安卓默认行为就是跟随系统）
 *   "en"  = 强制英文
 *   "zh"  = 强制简体中文
 */
object AppLocale {
    private const val PREFS = "app_locale"
    private const val KEY = "code"

    /// Flutter 同步过来的选择；"auto" 一律存成 null（= 不覆盖系统语言）
    fun save(ctx: Context, code: String?) {
        val normalized = when (code?.lowercase()) {
            "en" -> "en"
            "zh" -> "zh"
            else -> null
        }
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit()
            .putString(KEY, normalized)
            .apply()
    }

    /// 当前覆盖的语言；null = 跟随系统
    fun overrideCode(ctx: Context): String? =
        ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)
}

/**
 * 把任意 Context 转成"用当前有效语言取字符串"的 Context。
 *
 * 用法：`localized().getString(R.string.notif_mic_title)`
 *
 * 为什么要 createConfigurationContext 而不是直接改 resources：
 * 安卓不允许运行时篡改已有 Context 的配置；正确做法是基于它派生一个
 * 带新 Configuration 的 Context，再从这个派生对象上取字符串。
 * 没设过覆盖（auto）时直接返回自己，省掉一次对象创建。
 */
fun Context.localized(): Context {
    val code = AppLocale.overrideCode(this) ?: return this
    val config = Configuration(resources.configuration)
    config.setLocale(Locale(code))
    return createConfigurationContext(config)
}
