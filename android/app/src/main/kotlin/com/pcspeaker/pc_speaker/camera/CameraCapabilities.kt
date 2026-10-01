package com.pcspeaker.pc_speaker.camera

import android.content.Context
import android.content.pm.PackageManager
import android.graphics.ImageFormat
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.util.Log
import android.util.Size

/**
 * CameraCapabilities —— 问设备"你能跑什么画质"
 * ----------------------------------------------------------------------------
 * 返回形如：
 * [ {facing:"back",  sizes:[{width:1280,height:720,maxFps:30}, ...]},
 *   {facing:"front", sizes:[{width:640, height:480,maxFps:30}, ...]} ]
 *
 * CameraCharacteristics = 相机的"身份证+说明书"，
 * 不用打开相机就能查它支持哪些分辨率、每种分辨率最高多少帧。
 * 探测是纯读操作，无权限要求，App 启动时即可调用。
 */
internal class CameraCapabilities(
    private val context: Context,
    private val cameraManager: CameraManager
) {

    /** Camera1 探测结果：设备自报的预览尺寸表 + 自报的帧率上界（fps） */
    private data class Cam1Caps(val sizes: List<Size>, val maxFps: Int)

    fun probe(): List<Map<String, Any>> {
        val result = ArrayList<Map<String, Any>>()
        try {
            for (id in cameraManager.cameraIdList) {
                val ch = cameraManager.getCameraCharacteristics(id)
                val facingInt = ch.get(CameraCharacteristics.LENS_FACING) ?: continue
                val facing = when (facingInt) {
                    CameraCharacteristics.LENS_FACING_BACK -> "back"
                    CameraCharacteristics.LENS_FACING_FRONT -> "front"
                    else -> "external" // 外接摄像头（极少见），也支持
                }
                // 拿到"输出流配置"表：YUV_420_888 格式下相机支持的尺寸清单
                val map = ch.get(
                    CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP
                ) ?: continue
                // ── 这颗镜头自报的帧率上限（兜底用，仍然来自设备）──────────────
                // 下面每个尺寸都会去查 getOutputMinFrameDuration 算最高帧率，
                // 但个别 HAL 会返回 0 / 抛异常。那种情况下不能用常量 30 顶上
                // （那是代码编的），而要用设备自己声明的"我最高能跑多少"：
                // CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES 就是设备给的区间表。
                // 只有连这张表都拿不到（极老的 HAL1 设备）才退到 30 ——
                // 那已经不是"编造"，而是"设备什么都不肯说"时的最后手段。
                var aeHi = 0
                try {
                    val ranges = ch.get(
                        CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES
                    )
                    if (ranges != null) {
                        for (r in ranges) if (r.upper > aeHi) aeHi = r.upper
                    }
                } catch (_: Exception) {
                    // 拿不到就保持 0，下面会退到常量
                }
                // 【v3.12】先问设备：这颗头的 Camera2 是真 HAL 还是兼容层？
                // LEGACY → 下面是 framework 模拟出来的 Camera2，尺寸表不可信，
                // 要改用 Camera1 的参数表（见 camera1Caps）。
                val level = try {
                    ch.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)
                } catch (_: Exception) {
                    null
                }
                val legacy =
                    level == CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY

                // ── 【v3.12】HAL1(LEGACY) 设备改用 Camera1 的尺寸表 ──────────
                // 实测本机：Camera2 的 YUV 清单最大只报 960×720，而设备真实的
                // `preview-size-values` 最大是 1280×720 —— 于是"自动最高档"
                // 选出来的其实是次高档，画面白白少 33% 像素（这就是"清晰度差"
                // 的根因）。原因：HAL1 设备上 Camera2 只是 framework 的兼容层，
                // 它给的 stream configuration map 并不等于硬件真正能跑的预览尺寸。
                // 我们本来就走 Camera1 采集，直接用 Camera1 的
                // supportedPreviewSizes —— 同样是【设备自己上报】的，且就是
                // 采集中真实生效的那张参数表，最准。拿不到就照旧用 Camera2 清单。
                val c1 = if (legacy) camera1Caps(id) else null
                // 帧率同理：HAL1 的 supportedPreviewFpsRange 比兼容层的
                // AE_TARGET_FPS_RANGES 更贴近实际能锁住的帧率。
                val deviceMaxFps = when {
                    c1 != null && c1.maxFps > 0 -> c1.maxFps
                    aeHi > 0 -> aeHi
                    else -> 30
                }

                // 取设备给的尺寸清单。正常情况下 YUV_420_888 一定有；
                // 万一某台机器报空，退到"预览尺寸表"（SurfaceTexture）——
                // 那同样是设备自己声明的，不是我们编的。
                var yuvSizes: Array<Size>? = null
                if (c1 != null && c1.sizes.isNotEmpty()) {
                    yuvSizes = c1.sizes.toTypedArray()
                }
                if (yuvSizes.isNullOrEmpty()) {
                    yuvSizes = map.getOutputSizes(ImageFormat.YUV_420_888)
                }
                if (yuvSizes.isNullOrEmpty()) {
                    yuvSizes = map.getOutputSizes(SurfaceTexture::class.java)
                }
                val all = yuvSizes
                    // ============================================================
                    // v3.8.2：【设备支持到多少就报多少】—— 不再有任何"替设备做主"
                    // 的画质封顶（此前误设的 1080p 上限会把能跑更高档的机器按着）。
                    // 最高档由 Dart 侧自动挑（面积最大的一档），想降档就在下拉框手选。
                    // ============================================================
                    // 只留两道【防异常】安全阀，都与机型无关：
                    //  1) 长边 ≤4096：个别 HAL 会把"静止拍照尺寸"（如 8000×6000）
                    //     混进视频流清单，那种尺寸做连续取流会直接 OOM。
                    //  2) 宽高均为偶数：NV21 色度是 2×2 采样，奇数尺寸会让色度
                    //     采样错位（画面泛绿/条纹）。正常设备都是偶数，只挡畸形值。
                    // ⚠ 必须用 maxOf/minOf 判断：少数设备按【竖屏】报尺寸（2160×3840）。
                    .filter {
                        maxOf(it.width, it.height) <= 4096 &&
                                it.width % 2 == 0 && it.height % 2 == 0
                    }
                    .sortedByDescending { it.width.toLong() * it.height }

                // ── 档位抽样：最多报 12 档，但必须【两头都有】──────────────
                // 直接 take(12) 拿到的永远是最高的 12 档，低分辨率档会被挤掉，
                // 用户在弱网 / 省电 / 嫌卡的场景下想手动降档就没得选了。
                // 所以：头 8 档（含最高档）+ 中间均匀抽 3 档 + 最低档（必留）。
                val headCount = minOf(8, all.size)
                val picked = ArrayList(all.take(headCount))
                val rest = all.drop(headCount)
                if (rest.isNotEmpty()) {
                    val mid = rest.dropLast(1) // 最低档单独处理，保证一定入选
                    val step = maxOf(1, (mid.size + 2) / 3)
                    var i = 0
                    while (i < mid.size && picked.size < 11) {
                        picked.add(mid[i])
                        i += step
                    }
                    picked.add(rest.last()) // 最低档：极端弱网/省电场景的兜底选项
                }

                val sizes = picked
                    .map {
                        val minDur = try {
                            // 该尺寸下"两帧之间最少要间隔多少纳秒" → 换算最高帧率
                            map.getOutputMinFrameDuration(ImageFormat.YUV_420_888, it)
                        } catch (_: IllegalArgumentException) {
                            -1L // 查不到：下面改用设备自报的 deviceMaxFps
                        }
                        // 帧率只认两个来源，且优先设备按尺寸报的：
                        //   ① 该尺寸自己的 minFrameDuration（最准）
                        //   ② 设备声明的 AE 帧率区间上界（尺寸查不到时）
                        // 上限 240 只挡 HAL 报出的畸大值，下限 1 挡 0fps（传 0
                        // 会让原生不出帧）。不再有"统一按 30 封顶"这种替设备做主。
                        val maxFps = if (minDur > 0)
                            (1_000_000_000.0 / minDur).toInt().coerceIn(1, 240)
                        else deviceMaxFps.coerceIn(1, 240)
                        mapOf(
                            "width" to it.width,
                            "height" to it.height,
                            "maxFps" to maxFps,
                        )
                    }
                if (sizes.isNotEmpty()) {
                    result.add(mapOf("facing" to facing, "sizes" to sizes))
                }
            }
        } catch (_: Exception) {
            // 个别机型查询会抛异常，返回已收集到的部分即可，不崩溃
        }
        return result
    }

    /**
     * 【v3.12】用 Camera1 直接问设备：这颗镜头能跑哪些预览尺寸、最高多少帧。
     *
     * 只给 HAL1(LEGACY) 设备用 —— 那些机器上 Camera2 是兼容层，清单不可信
     *（本机实测：Camera2 最大只报 960×720，设备真实能力是 1280×720）。
     *
     * 返回 null 表示"问不到"（没权限 / 相机正被占用 / HAL 怪癖），
     * 调用方会回退到 Camera2 的清单 —— 探测失败不影响开相机，只是档位表
     * 可能不全，绝不会因此开不了摄像头。
     *
     * ⚠ 必须在【相机没被占用】时问：Camera1 的 open 是独占的，采集进行中
     * 再 open 会抛异常（这里 catch 住返回 null）。所以只在 App 刚连上、
     * 还没开硬件的探测阶段调用（Dart 侧 ensureCaps 只探一次，见 _capsReady）。
     */
    @Suppress("DEPRECATION")
    private fun camera1Caps(camId: String): Cam1Caps? {
        val idx = camId.toIntOrNull() ?: return null
        // 没授权就不碰硬件 —— 免得在某些 ROM 上弹异常日志甚至崩溃
        if (context.checkSelfPermission(android.Manifest.permission.CAMERA) !=
            PackageManager.PERMISSION_GRANTED
        ) return null

        var cam: android.hardware.Camera? = null
        return try {
            cam = android.hardware.Camera.open(idx)
            val p = cam.parameters
            val sizes = p.supportedPreviewSizes?.map { Size(it.width, it.height) }
            // 帧率：HAL1 用"千分之一 fps"为单位的区间表，取所有区间的最大上界
            var hi = 0
            val ranges = p.supportedPreviewFpsRange
            if (ranges != null) {
                for (r in ranges) if (r.size >= 2 && r[1] > hi) hi = r[1]
            }
            if (sizes.isNullOrEmpty()) null else Cam1Caps(sizes, hi / 1000)
        } catch (e: Exception) {
            Log.i("CamPerf", "Camera1 能力探测不可用（$camId）：" + e.javaClass.simpleName)
            null
        } finally {
            try {
                cam?.release()
            } catch (_: Exception) {
            }
        }
    }

    /** 按朝向（"back"/"front"）查相机 id，找不到返回 null */
    fun findCameraId(facing: String): String? {
        val want = when (facing) {
            "front" -> CameraCharacteristics.LENS_FACING_FRONT
            "external" -> CameraCharacteristics.LENS_FACING_EXTERNAL
            else -> CameraCharacteristics.LENS_FACING_BACK
        }
        try {
            for (id in cameraManager.cameraIdList) {
                val f = cameraManager.getCameraCharacteristics(id)
                    .get(CameraCharacteristics.LENS_FACING)
                if (f != null && f == want) return id
            }
        } catch (_: Exception) {
        }
        return null
    }
}
