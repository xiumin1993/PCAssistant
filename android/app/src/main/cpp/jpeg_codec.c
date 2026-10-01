/* ============================================================================
 * NV21 → JPEG 的原生编码器（libjpeg-turbo + TurboJPEG API）
 *
 * 相机（Camera1）给的是 NV21：一整块 Y 平面，后面跟着交错存放的 V/U 半平面。
 * TurboJPEG 的 tjCompressFromYUVPlanes 要的是三个独立平面（I420 布局），
 * 所以中间必须把交错的 VU 拆开。这一步用 NEON 的 vld2q_u8 一次读 32 字节、
 * 同时吐出 16 个 V 和 16 个 U —— 因为 NV21 的排布恰好是 V,U,V,U...
 * 偶数索引全是 V、奇数索引全是 U，正好对应 vld2 的两个通道。
 *
 * 性能要点：
 *   · 所有缓冲按线程缓存（__thread），稳定状态下每帧零 malloc；
 *   · JPEG 编码器句柄同样每线程只初始化一次；
 *   · 用 GetByteArrayElements 而不是 GetByteArrayRegion —— 后者会先把
 *     整帧 1.3 MB 拷一遍，白扔一次内存带宽。
 * ==========================================================================*/

#include <jni.h>
#include <stdlib.h>
#include <string.h>

#include "turbojpeg.h"

#if defined(__aarch64__) || defined(__ARM_NEON)
#include <arm_neon.h>
#define HAVE_NEON 1
#endif

/* 每线程一份的状态：拆出来的色度平面 + JPEG 输出缓冲 + 编码器句柄。
 * 用 TLS 而不是全局静态，是为了万一上层把编码丢到多个线程也不会互相踩。 */
typedef struct {
    unsigned char *u;     /* U 平面（从交错里拆出） */
    unsigned char *v;     /* V 平面 */
    size_t uv_cap;        /* 上面两块各分配了多少字节 */
    unsigned char *jpg;   /* JPEG 输出缓冲 */
    unsigned long jpg_cap;
    tjhandle tj;          /* TurboJPEG 压缩句柄 */
} Codec;

static __thread Codec tls_codec = {NULL, NULL, 0, NULL, 0, NULL};

/* 按需要的大小扩容色度缓冲。尺寸只会在切换画质档时变，之后一直复用。 */
static int ensure_uv(Codec *c, size_t need) {
    if (c->uv_cap >= need && c->u && c->v) return 1;
    free(c->u);
    free(c->v);
    c->u = (unsigned char *)malloc(need);
    c->v = (unsigned char *)malloc(need);
    if (!c->u || !c->v) {
        free(c->u);
        free(c->v);
        c->u = NULL;
        c->v = NULL;
        c->uv_cap = 0;
        return 0;
    }
    c->uv_cap = need;
    return 1;
}

static int ensure_jpg(Codec *c, unsigned long need) {
    if (c->jpg_cap >= need && c->jpg) return 1;
    free(c->jpg);
    c->jpg = (unsigned char *)malloc(need);
    if (!c->jpg) {
        c->jpg_cap = 0;
        return 0;
    }
    c->jpg_cap = need;
    return 1;
}

/* 把 NV21 交错的 VU 半平面拆成两个独立平面。
 * src 指向整帧开头，uv_off = width*height 处就是 VU 交错区的起点。 */
static void deinterleave_vu(const unsigned char *src, size_t uv_off,
                            unsigned char *u, unsigned char *v, size_t n) {
    const unsigned char *vu = src + uv_off;
    size_t i = 0;

#ifdef HAVE_NEON
    /* vld2q_u8 一次吃 32 字节：val[0] = 偶数下标(V)，val[1] = 奇数下标(U) */
    for (; i + 16 <= n; i += 16) {
        uint8x16x2_t d = vld2q_u8(vu + i * 2);
        vst1q_u8(v + i, d.val[0]);
        vst1q_u8(u + i, d.val[1]);
    }
#endif
    /* 尾巴（不足 16 字节的部分）走标量 */
    for (; i < n; i++) {
        v[i] = vu[i * 2];
        u[i] = vu[i * 2 + 1];
    }
}

/* ---------------------------------------------------------------------------
 * JNI 入口
 *
 * encode() 和 encodeTagged() 的区别只在于：后者会在 JPEG 前面留 1 个字节
 * 写入"方向标记"（协议要求帧头带方向，PC 端据此摆正）。让 turbojpeg 直接
 * 写进 [1..] 的位置，就能省掉 Kotlin 侧"新建大 1 字节的数组 + 整帧拷贝"
 * 这一步 —— 720p 下一帧约 100 KB，24 fps 就是每秒 2.4 MB 的白拷。
 * ------------------------------------------------------------------------ */

/* 真正的编码过程。tag >= 0 时表示要在帧头留一个字节写方向标记。 */
static jbyteArray do_encode(JNIEnv *env, jbyteArray nv21, jint width,
                            jint height, jint quality, int tag) {
    if (width <= 0 || height <= 0) return NULL;
    /* 4:2:0 要求宽高都是偶数；不是偶数就没法拆半平面，直接让上层回退 */
    if ((width & 1) || (height & 1)) return NULL;

    const size_t y_size = (size_t)width * (size_t)height;
    const size_t frame = y_size + y_size / 2;
    if (nv21 == NULL) return NULL;
    if ((*env)->GetArrayLength(env, nv21) < (jsize)frame) return NULL;

    Codec *c = &tls_codec;
    if (!c->tj) {
        c->tj = tjInitCompress();
        if (!c->tj) return NULL;
    }

    const size_t uv_n = y_size / 4; /* 每个色度平面的字节数 */
    if (!ensure_uv(c, uv_n)) return NULL;

    /* 输出缓冲按最坏情况开一次：一幅 4:2:0 JPEG 不会超过 tjBufSize */
    unsigned long need = (unsigned long)tjBufSize(width, height, TJSAMP_420);
    if (need == 0) return NULL;
    if (tag >= 0) need += 1; /* 给方向标记留位置 */
    if (!ensure_jpg(c, need)) return NULL;

    /* ART 上对 byte[] 是 pin 住返回直接指针，不会拷贝整帧 */
    jbyte *src = (*env)->GetByteArrayElements(env, nv21, NULL);
    if (src == NULL) return NULL;
    const unsigned char *y = (const unsigned char *)src;

    deinterleave_vu(y, y_size, c->u, c->v, uv_n);

    const unsigned char *planes[3];
    int strides[3];
    planes[0] = y;
    planes[1] = c->u;
    planes[2] = c->v;
    strides[0] = width;
    strides[1] = width / 2;
    strides[2] = width / 2;

    /* 有标记时让编码器从 [1] 开始写，[0] 留给方向字节 —— 零额外拷贝 */
    const unsigned char head = (unsigned char)(tag >= 0 ? tag : 0);
    const int head_len = (tag >= 0) ? 1 : 0;
    unsigned char *dst = c->jpg + head_len;
    unsigned long jpeg_size = 0;
    /* TJFLAG_NOREALLOC：缓冲是我们开的且足够大，别再自己去 realloc */
    int rc = tjCompressFromYUVPlanes(c->tj, planes, width, strides, height,
                                     TJSAMP_420, &dst, &jpeg_size,
                                     quality, TJFLAG_NOREALLOC);

    (*env)->ReleaseByteArrayElements(env, nv21, src, JNI_ABORT);

    if (rc != 0 || jpeg_size == 0) return NULL;

    const jsize total = (jsize)(jpeg_size + head_len);
    jbyteArray out = (*env)->NewByteArray(env, total);
    if (out == NULL) return NULL;
    if (head_len) c->jpg[0] = head;
    (*env)->SetByteArrayRegion(env, out, 0, total, (const jbyte *)c->jpg);
    return out;
}

JNIEXPORT jbyteArray JNICALL
Java_com_pcspeaker_pc_1speaker_JpegCodec_encode(JNIEnv *env, jclass clazz,
                                                jbyteArray nv21, jint width,
                                                jint height, jint quality) {
    (void)clazz;
    return do_encode(env, nv21, width, height, quality, -1);
}

JNIEXPORT jbyteArray JNICALL
Java_com_pcspeaker_pc_1speaker_JpegCodec_encodeTagged(JNIEnv *env, jclass clazz,
                                                      jbyteArray nv21,
                                                      jint width, jint height,
                                                      jint quality, jint orient) {
    (void)clazz;
    return do_encode(env, nv21, width, height, quality, orient & 0xFF);
}

/* 自检：库加载后先编一张最小的图，确认 NEON/turbojpeg 真能跑。
 * 返回 1 = 可用，0 = 不可用（上层会退回 YuvImage）。 */
JNIEXPORT jint JNICALL
Java_com_pcspeaker_pc_1speaker_JpegCodec_selfTest(JNIEnv *env, jclass clazz) {
    (void)env;
    (void)clazz;

    tjhandle h = tjInitCompress();
    if (!h) return 0;

    /* 16x16 的 4:2:0：Y 满平面 + 两个 8x8 色度平面，内容全灰 */
    unsigned char y[256];
    unsigned char u[64];
    unsigned char v[64];
    memset(y, 128, sizeof(y));
    memset(u, 128, sizeof(u));
    memset(v, 128, sizeof(v));

    const unsigned char *planes[3] = {y, u, v};
    int strides[3] = {16, 8, 8};
    unsigned char *buf = NULL;
    unsigned long size = 0;
    int rc = tjCompressFromYUVPlanes(h, planes, 16, strides, 16, TJSAMP_420,
                                     &buf, &size, 75, 0);
    if (rc == 0 && buf) tjFree(buf);
    tjDestroy(h);

    /* 一张合规的 JPEG 至少要有 SOI+EOI，正常输出远大于此 */
    return (rc == 0 && size > 64) ? 1 : 0;
}
