package com.pcspeaker.pc_speaker.camera

import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Camera1Controller —— 直连 HAL1 的采集路径（只给 LEGACY 设备用）
 * ----------------------------------------------------------------------------
 * 【v3.9】为什么要有第二条路：实测本机 `dumpsys media.camera` 打印
 *   Camera module HAL API version: 0x100   ← HAL 是 v1，不是 v3
 * 也就是说 Camera2 在这台机上【没有真正的 HAL 支撑】，全靠 framework 的
 * legacy 兼容层（LegacyCameraDevice）把 Camera1 的预览帧转换出来：
 *   · 它要用一条 GL 线程做缓冲转换（实测 CameraDeviceGLT 单独吃了 0.97 核）；
 *   · CONTROL_AE_TARGET_FPS_RANGE 这类控制它基本不认 —— 我们下发了 (30,30)，
 *     相机照样只给 10fps，且不随环境亮度变化、不随我们处理速度变化。
 *
 * 换成 Camera1 直连 HAL1 之后：
 *   · setPreviewFpsRange(30000,30000) 是 HAL1 自己的原生参数，认；
 *   · 回调直接给 NV21 —— 连 YUV→NV21 那一步都省了（conv 9ms → 0）；
 *   · 没有 GL 转换线程那一个核的开销。
 *
 * ⚠ 分辨率/帧率档位【完全不变】，仍然由 Dart 从设备能力清单挑出来传进来，
 *   只是不再绕兼容层 —— 这不是"降档"，是"换一条不打折的路"。
 *
 * 这个类的职责边界很清楚：【只管把相机硬件跑起来、把帧交给 FramePipeline】。
 * 编码、保序、统计那些事一概不碰（那是 FramePipeline 的活）。
 */
@Suppress("DEPRECATION")
internal class Camera1Controller(
    private val state: CameraState,
    private val pipeline: FramePipeline,
    private val preview: PreviewTexture
) {

    private var cam1: android.hardware.Camera? = null
    private var cam1Thread: HandlerThread? = null
    private var cam1Handler: Handler? = null

    /**
     * 离屏"预览承载"。Camera1 不挂一个承载就不出帧。
     * ⚠ 必须用一个字段【持有引用】：SurfaceTexture 靠 finalize 释放显存，
     * 只 new 出来不存的话随时可能被 GC 回收 → 相机拿到一个已释放的纹理，
     * 表现是"预览跑一会儿就报错/黑屏"，而且很难复现。
     * 拿到 Flutter 纹理时它就是那块纹理（见 PreviewTexture），拿不到才退回纯离屏。
     */
    private var cam1DummySurface: SurfaceTexture? = null

    // ══════════════════════════════════════════════════════════════════
    // 【v3.14】自动对焦
    // ------------------------------------------------------------------
    // 之前两条路径【都没有设过任何对焦参数】。本机实测（dumpsys media.camera）：
    //   focus-mode: auto            ← 单次对焦模式，必须自己调 autoFocus() 才动
    //   focus-distances: Infinity   ← 焦点一直停在无穷远
    //   focus-done: false           ← 从没完成过一次对焦
    // 而 focus-mode-values 里明明有 continuous-video / continuous-picture。
    // 于是镜头停在上电默认位，近处永远糊 —— 这就是"预览清晰度差"的主因
    //（预览本身是 GPU 纹理直出、零压缩，与原生相机同一条路，不是压缩问题）。
    //
    // 优先级：continuous-video > continuous-picture > auto(+触发) > macro > edof
    //   视频推流选 continuous-video：它专为连续画面设计，对焦过程平滑，
    //   不会像 picture 那样频繁"拉风箱"（画面来回呼吸）。
    //   只有 auto 时必须在 startPreview 之后【手动触发】一次，并且要周期性
    //   重触发 —— 单次对焦不会跟着场景变化，手机一动就又糊了。
    // 一切取自【设备自己上报的】supportedFocusModes，不写死任何机型假设。
    // ══════════════════════════════════════════════════════════════════
    private var focusMode: String? = null
    private var refocusRunnable: Runnable? = null

    /** 回调缓冲数量：够 PIPELINE_WORKERS 帧同时在飞 + 相机自己手里再拿几张 */
    private val bufferCount = CameraConfig.PIPELINE_WORKERS + 3

    /**
     * 起相机并开始出帧。返回 null = 成功，否则是错误码。
     */
    fun start(camId: String): String? {
        val id = camId.toIntOrNull() ?: return "NO_CAMERA"

        // Camera1 的回调会投递到【调用 open() 的那条线程的 Looper】上，
        // 所以必须在后台线程里 open —— 否则每帧都砸在主线程上。
        val thread = HandlerThread("cam1-bg")
        thread.start()
        cam1Thread = thread
        cam1Handler = Handler(thread.looper)

        var opened: android.hardware.Camera? = null
        var openError: String? = null
        val latch = CountDownLatch(1)
        cam1Handler?.post {
            opened = try {
                android.hardware.Camera.open(id)
            } catch (_: Exception) {
                openError = "OPEN_ERROR"
                null
            }
            latch.countDown()
        }
        if (!latch.await(3, TimeUnit.SECONDS) || opened == null) {
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            return openError ?: "OPEN_ERROR"
        }
        val cam = opened!!

        // ── 参数：分辨率 / 格式 / 帧率 / 对焦 ──────────────────────────
        // 全部来自设备支持表，尺寸由上层从能力清单挑好传进来，这里不替设备做主。
        val params = cam.parameters
        params.setPreviewSize(state.width, state.height)
        params.previewFormat = ImageFormat.NV21
        applyFocusMode(params)

        // 帧率：HAL1 的原生参数是"预览帧率区间"，单位 1/1000 fps。
        // ① 优先 (target,target) 固定区间 —— 下限=上限时相机不许自己往下滑；
        // ② 没有就挑"能容纳目标帧率"的里上界最高的；③ 再没有就挑上界最高的。
        val want = state.fps * 1000
        var chosen: IntArray? = null
        val ranges = try {
            params.supportedPreviewFpsRange
        } catch (_: Exception) {
            null
        }
        if (ranges != null && ranges.isNotEmpty()) {
            for (r in ranges) {
                if (r.size >= 2 && r[0] == want && r[1] == want) {
                    chosen = r
                    break
                }
            }
            if (chosen == null) {
                var best: IntArray? = null
                for (r in ranges) {
                    if (r.size < 2) continue
                    if (r[0] <= want && want <= r[1]) {
                        if (best == null || r[1] > best[1]) best = r
                    }
                }
                if (best == null) {
                    for (r in ranges) {
                        if (r.size < 2) continue
                        if (best == null || r[1] > best[1]) best = r
                    }
                }
                chosen = best
            }
        }
        if (chosen != null) {
            params.setPreviewFpsRange(chosen[0], chosen[1])
            Log.i(
                "CamPerf",
                "Camera1 fpsRange target=" + want + " chosen=(" +
                        chosen[0] + "," + chosen[1] + ") all=" +
                        (ranges?.joinToString(",") { "(${it[0]},${it[1]})" } ?: "?")
            )
        }
        try {
            cam.parameters = params
        } catch (_: Exception) {
            cam.release()
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            return "BAD_SIZE"
        }

        // HAL 有最终解释权：个别机器会把尺寸悄悄改成它支持的最近一档。
        // 必须以【相机回读的实际尺寸】为准 —— 否则回调里 data 是 1280×720
        // 而我们按 960×720 去采样，画面会直接错位/花屏。
        try {
            val actual = cam.parameters.previewSize
            if (actual != null && (actual.width != state.width || actual.height != state.height)) {
                Log.i(
                    "CamPerf",
                    "Camera1 尺寸被 HAL 调整：" + state.width + "x" + state.height +
                            " → " + actual.width + "x" + actual.height + "（以实际为准）"
                )
                state.width = actual.width
                state.height = actual.height
            }
        } catch (_: Exception) {
            // 读不回来就按请求值走，绝大多数机器本来就一致
        }

        // Camera1 必须有个"预览承载"才能出帧。
        // 【v3.11】优先挂 Flutter 注册的纹理 —— 画面直通 GPU，预览零解码；
        // 注册表不可用时才退回离屏空纹理（那时预览走 Dart 侧 JPEG 解码）。
        try {
            val st = preview.acquire(state.width, state.height)
                ?: SurfaceTexture(0).also { cam1DummySurface = it }
            cam.setPreviewTexture(st)
        } catch (_: Exception) {
            cam.release()
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            return "SESSION_FAILED"
        }

        // 预分配回调缓冲：不预分配的话 HAL 每帧 new 一个 ~1MB 数组 → GC 抖动。
        val bufSize = state.width * state.height * 3 / 2
        for (i in 0 until bufferCount) cam.addCallbackBuffer(ByteArray(bufSize))

        cam.setPreviewCallbackWithBuffer { data, camera ->
            pipeline.onCallback()
            if (pipeline.saturated) {
                // 流水线满了：这一帧放弃，但缓冲必须立刻还回去，
                // 否则相机手里的缓冲越来越少 → 反过来把帧率压下去（背压）。
                pipeline.onDropped()
                camera.addCallbackBuffer(data)
                return@setPreviewCallbackWithBuffer
            }
            pipeline.onArrived()
            // 【v3.9】回调给的就是 NV21，不用再转格式（Camera2 才需要那一步）
            pipeline.submitNv21(data, state.width, state.height, "C1") {
                // 缓冲在【处理完之后】才还 —— 还早了相机会往这块内存里写下帧，
                // 正在读它的 JPEG 编码器就会读到半新半旧的画面。
                camera.addCallbackBuffer(data)
            }
        }

        return try {
            cam.startPreview()
            cam1 = cam
            state.running = true
            // 【v3.14】连续对焦自己会一直调，只有"单次对焦"才需要我们触发
            scheduleAutoFocus(cam)
            null
        } catch (_: Exception) {
            cam.release()
            thread.quitSafely()
            cam1Thread = null
            cam1Handler = null
            "SESSION_FAILED"
        }
    }

    /** 停止并释放这条路径上的一切（没开过就是空操作） */
    fun stop() {
        try {
            cam1?.setPreviewCallback(null)
        } catch (_: Exception) {
        }
        // 【v3.14】停掉周期性重对焦：相机都要关了，再排队触发就是浪费
        refocusRunnable?.let { r ->
            try {
                cam1Handler?.removeCallbacks(r)
            } catch (_: Exception) {
            }
        }
        refocusRunnable = null
        focusMode = null
        try {
            cam1?.cancelAutoFocus()
        } catch (_: Exception) {
        }
        try {
            cam1?.stopPreview()
        } catch (_: Exception) {
        }
        try {
            cam1?.release()
        } catch (_: Exception) {
        }
        cam1 = null
        try {
            cam1DummySurface?.release()
        } catch (_: Exception) {
        }
        cam1DummySurface = null
        preview.release() // 【v3.11】预览纹理也要还回去
        try {
            cam1Thread?.quitSafely()
        } catch (_: Exception) {
        }
        cam1Thread = null
        cam1Handler = null
    }

    /** 这条路径是否在跑（CameraEngine.stop() 要用它判断要不要调 stop） */
    fun isActive(): Boolean = cam1 != null

    /**
     * 挑一个自动对焦模式写进参数。
     * 全程只认【设备自己上报的】supportedFocusModes —— 不同机器差别极大
     * （有连续对焦的、只有单次对焦的、定焦的），写死任何一种都会在别的机器上出错。
     * 任何一步失败都只是"不对焦"，绝不影响开相机。
     */
    private fun applyFocusMode(params: android.hardware.Camera.Parameters) {
        val modes = try {
            params.supportedFocusModes
        } catch (_: Exception) {
            null
        }
        if (modes.isNullOrEmpty()) {
            Log.i("CamPerf", "Camera1 对焦：设备未上报 supportedFocusModes，沿用默认")
            return
        }
        // Camera1 的常量都在 Camera.Parameters 里，Kotlin 不能把类赋给变量，
        // 所以这里用完整限定名（写起来啰嗦，但零歧义）。
        val auto = android.hardware.Camera.Parameters.FOCUS_MODE_AUTO
        val video = android.hardware.Camera.Parameters.FOCUS_MODE_CONTINUOUS_VIDEO
        val picture = android.hardware.Camera.Parameters.FOCUS_MODE_CONTINUOUS_PICTURE
        val macro = android.hardware.Camera.Parameters.FOCUS_MODE_MACRO
        val edof = android.hardware.Camera.Parameters.FOCUS_MODE_EDOF
        var pick: String? = when {
            modes.contains(video) -> video
            modes.contains(picture) -> picture
            modes.contains(auto) -> auto
            modes.contains(macro) -> macro
            modes.contains(edof) -> edof
            else -> null
        }
        if (pick != null) {
            pick = try {
                params.focusMode = pick
                pick
            } catch (_: Exception) {
                null // 个别 HAL 拒收某个模式：置空沿用默认，不能因此开不了相机
            }
        }
        focusMode = pick
        Log.i(
            "CamPerf",
            "Camera1 对焦 supported=" + modes.joinToString(",") +
                    " chosen=" + (pick ?: "default")
        )
    }

    /**
     * 只有"单次对焦"模式才需要我们自己触发。
     * 连续对焦（continuous-*）是相机内部持续进行的，调 autoFocus 反而会打断它。
     * 单次对焦不会跟着场景变化，所以按固定间隔重新触发一次。
     * 必须在 startPreview 之后调 —— 没出预览就对焦，HAL 会直接忽略或报错。
     */
    private fun scheduleAutoFocus(cam: android.hardware.Camera) {
        if (focusMode != android.hardware.Camera.Parameters.FOCUS_MODE_AUTO) return
        val handler = cam1Handler ?: return
        val task = object : Runnable {
            override fun run() {
                if (!state.running || cam1 == null) return
                try {
                    cam.autoFocus(null)
                } catch (_: Exception) {
                    // 有些 HAL 在持续预览下拒绝单次对焦：停掉，别每 4 秒刷一条日志
                    refocusRunnable = null
                    return
                }
                handler.postDelayed(this, CameraConfig.REFOCUS_INTERVAL_MS)
            }
        }
        refocusRunnable = task
        // 刚开预览先让它稳定一下再对焦，立刻调容易被 HAL 忽略
        handler.postDelayed(task, 700)
    }
}
