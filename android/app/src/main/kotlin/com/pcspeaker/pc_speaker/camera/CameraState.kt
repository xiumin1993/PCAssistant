package com.pcspeaker.pc_speaker.camera

/**
 * CameraState —— 一次采集会话的"当前参数"
 * ----------------------------------------------------------------------------
 * 采集链路被拆成了好几个类（能力探测、Camera1/Camera2 控制器、方向计算、
 * 预览纹理……），它们都要读同一份"现在用的是哪颗头、多大画面、多少帧"。
 * 与其给每个函数塞一串参数，不如把这些值收在一个对象里共享。
 *
 * 它不是"全局单例"：一个 CameraEngine 持有一份，生命周期跟着引擎走。
 *
 * ⚠ 并发：采集线程、工作线程、Flutter 主线程都会碰它。
 * 单次的读写都是原子的（Int/Boolean/String 引用），不需要加锁；
 * 但"先读宽度再读高度"这种组合不是原子的 —— 好在只有 start/stop 会写，
 * 而 start/stop 都在主线程调用，取帧过程中不会被改。
 */
internal class CameraState {

    /** 是否正在采集。stop() 之后残余的帧不再往外发（见 FramePipeline.enabled） */
    @Volatile
    var running = false

    /** 当前用的镜头："back" / "front" */
    var facing = "back"

    var width = 640
    var height = 480
    var fps = 30

    /**
     * 传感器"安装角度"：这个镜头拍出的画面相对手机自然方向顺时针装了多少度。
     * 后置一般 90、前置一般 270（从系统查，不要写死）。
     * 用它 + 手机当前持握角度，才能算出"每帧该再转多少度才是正的"。
     */
    var sensorOrientation = 90

    /**
     * 【v3.4.1】手动旋转偏移（0/90/180/270，顺时针）。
     * 自动摆正（传感器角+持握角）之外，再叠加用户手动点"旋转90°"的偏移。
     *
     * @Volatile：采集/压缩线程每帧都要读它，Flutter 主线程写它，
     * 加 Volatile 保证写完立刻对其它线程可见（不需要锁，读频极高）。
     *
     * 它不随 stop() 清零 —— 用户设定一次，断线重连/切镜头都继续生效。
     */
    @Volatile
    var manualRotation = 0
}
