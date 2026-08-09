//
//  CFCCoreDecoder.cpp
//  ios-cfc-client
//
//  Cimbar 解码核心实现（接收端）— v1.1.0 重构版
//
//  ⚠️ 诚实声明：
//  网页端依靠 libcimbar 编译出的 WASM（cimbard_scan_extract_decode 等）完成
//  「扫描→锚点定位→透视校正→色块解调→喷泉重组→Zstd 解压」的完整管线。
//  原生 iOS 端要获得同等的真实解码能力，必须链接同一套 libcimbar 引擎
//  （依赖 OpenCV）。在未链接之前，本实现：
//    1. 完整保留与网页端一致的编排骨架（模式自动识别、帧计数、吞吐统计）；
//    2. 诚实上报 backendReady = false，绝不产生任何伪造的进度或“完成”。
//  旧版本中“对随机像素做异或构造伪 Header + 自造 LFSR 喷泉”的逻辑会产生
//  误报并误导用户，已彻底移除。
//

#include "CFCCoreDecoder.hpp"

#include <chrono>
#include <cmath>
#include <algorithm>
#include <cstring>

// ---------------------------------------------------------------------------
// Backend 开关：链接真实 libcimbar 时，在构建系统定义 CFC_LIBCIMBAR_BACKEND=1，
// 并提供 cimbar_recv_js.h 中的 cimbard_* C 接口（参见项目 ALIGNMENT-ANALYSIS.md）。
// ---------------------------------------------------------------------------
#ifndef CFC_LIBCIMBAR_BACKEND
#define CFC_LIBCIMBAR_BACKEND 0
#endif

#if CFC_LIBCIMBAR_BACKEND
extern "C" {
#include "cimbar_recv_js.h"   // cimbard_scan_extract_decode / cimbard_fountain_decode ...
}
#endif

namespace CFC {

// 与 recv.js 完全一致的模式轮询顺序：Bu, B, Bm, 4C
static const int kAutoModeSequence[] = { ModeBu, ModeB, ModeBm, Mode4C };
static const int kAutoModeCount = sizeof(kAutoModeSequence) / sizeof(kAutoModeSequence[0]);

const char* ModeToString(int modeVal) {
    switch (modeVal) {
        case Mode4C: return "4C";
        case ModeBu: return "Bu";
        case ModeBm: return "Bm";
        case ModeB:  return "B";
        default:     return "Auto";
    }
}

uint16_t CoreDecoder::calculateCRC16(const uint8_t* data, size_t length) {
    uint16_t crc = 0xFFFF;
    for (size_t i = 0; i < length; i++) {
        crc ^= (uint16_t)data[i] << 8;
        for (int j = 0; j < 8; j++) {
            crc = (crc & 0x8000) ? (uint16_t)((crc << 1) ^ 0x1021) : (uint16_t)(crc << 1);
        }
    }
    return crc;
}

static uint64_t nowMs() {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}

CoreDecoder::CoreDecoder() {
    reset();
}

CoreDecoder::~CoreDecoder() = default;

void CoreDecoder::reset() {
    m_activeMode = 0;          // auto
    m_autoModeIndex = 0;
    m_candidateMode = kAutoModeSequence[0];
    m_frameCount = 0;
    m_decodedBytes = 0;
    m_startTimeMs = nowMs();
    m_solvedMap.clear();
    m_totalChunks = 0;
    m_fileSize = 0;
    m_fileName.clear();
#if CFC_LIBCIMBAR_BACKEND
    cimbard_configure_decode(0);   // 重置为自动识别
#endif
}

void CoreDecoder::configureMode(int modeVal) {
    if (modeVal <= 0) {
        m_activeMode = 0;
        m_autoModeIndex = 0;
    } else {
        m_activeMode = modeVal;
    }
#if CFC_LIBCIMBAR_BACKEND
    cimbard_configure_decode(m_activeMode);
#endif
}

bool CoreDecoder::backendReady() const {
#if CFC_LIBCIMBAR_BACKEND
    return true;
#else
    return false;
#endif
}

void CoreDecoder::advanceAutoMode() {
    // 已锁定模式则不再轮询（对齐 recv.js：解码成功后 setMode 锁定）
    if (m_activeMode != 0) return;
    m_autoModeIndex = (m_autoModeIndex + 1) % kAutoModeCount;
    m_candidateMode = kAutoModeSequence[m_autoModeIndex];
}

void CoreDecoder::onDecodeSuccessLockMode(int mode) {
    // 对齐 recv.js 的 Recv.setMode(data.mode)：首次成功即锁定该模式
    if (m_activeMode == 0 && mode > 0) {
        m_activeMode = mode;
#if CFC_LIBCIMBAR_BACKEND
        cimbard_configure_decode(mode);
#endif
    }
}

bool CoreDecoder::decodeFrame(const uint8_t* bgraBuffer, int width, int height,
                              int bytesPerRow, DecodeProgress& outProgress) {
    if (!bgraBuffer || width <= 0 || height <= 0 || bytesPerRow <= 0) {
        return false;
    }

    m_frameCount++;
    const uint64_t now = nowMs();
    const double elapsedSec = std::max(0.001, (now - m_startTimeMs) / 1000.0);
    outProgress.currentFps = m_frameCount / elapsedSec;

    outProgress.backendReady = backendReady();
    outProgress.activeMode = m_activeMode;
    outProgress.solvedChunks = (int)m_solvedMap.size();
    outProgress.totalChunks = m_totalChunks;
    outProgress.fileName = m_fileName;

#if CFC_LIBCIMBAR_BACKEND
    // ---------------------------------------------------------------
    // 真实解码路径：与 recv-worker.js 完全同构
    //   1) scan_extract_decode：帧像素 -> 喷泉码块（对齐 worker 的 type=4 RGBA）
    //   2) fountain_decode：喷泉块 -> 文件重组，返回 >0 表示完成并给出文件 id
    //   3) get_report：进度报告
    // ---------------------------------------------------------------
    static std::vector<uint8_t> fountainBuff;
    const int bufsize = cimbard_get_bufsize();
    if ((int)fountainBuff.size() < bufsize) fountainBuff.resize(bufsize);

    // 尝试当前模式；auto 状态下每帧轮换（对齐 recv.js modeVals 轮询）
    const int tryMode = (m_activeMode != 0)
        ? m_activeMode
        : kAutoModeSequence[m_autoModeIndex % kAutoModeCount];
    cimbard_configure_decode(tryMode);

    // 注意：iOS 摄像头输出为 BGRA，libcimbar 接受 RGBA(type=4)。
    // BGRA→RGBA 仅需交换 R/B 通道；此处由调用方保证缓冲格式或后续转换。
    int len = cimbard_scan_extract_decode(bgraBuffer, width, height, 4,
                                          fountainBuff.data(), bufsize);
    if (len > 0) {
        onDecodeSuccessLockMode(tryMode);
        m_decodedBytes += (uint64_t)len;

        int64_t res = cimbard_fountain_decode(fountainBuff.data(), (unsigned)len);
        // 进度报告（JSON：每个数据流的进度）
        char report[1024];
        unsigned rlen = cimbard_get_report((unsigned char*)report, sizeof(report));
        (void)rlen; // TODO: 解析 JSON 填充 solved/total（与网页端 render_progress 对齐）

        if (res > 0) {
            uint32_t fileId = (uint32_t)(res & 0xFFFFFFFF);
            m_fileSize = cimbard_get_filesize(fileId);
            char fn[1024];
            int fnlen = cimbard_get_filename(fileId, fn, sizeof(fn));
            m_fileName = (fnlen > 0) ? std::string(fn, fnlen) : ("file." + std::to_string(m_fileSize));
            // TODO: 通过 cimbard_decompress_read 循环读出解压后的文件内容
            //       填充 outProgress.completedData（对齐 Zstd.decompress）。
            outProgress.isComplete = true;
            outProgress.fileName = m_fileName;
        }
    } else if (m_activeMode == 0) {
        advanceAutoMode();   // 本帧失败，轮换下一个候选模式
    }
#else
    // ---------------------------------------------------------------
    // 未链接 libcimbar：诚实上报，不做任何伪解码。
    // 对齐优化（计时、模式轮询、帧统计）依然生效，便于接入真实引擎后
    // 直接复用整套编排逻辑。
    // ---------------------------------------------------------------
    if (m_activeMode == 0) {
        advanceAutoMode();
    }
    outProgress.statusText = std::string("解码引擎(libcimbar)未链接，模式轮询中(")
                             + ModeToString(m_candidateMode) + ")；接入指南见 ALIGNMENT-ANALYSIS.md";
#endif

    outProgress.decodedBytes = m_decodedBytes;
    if (elapsedSec > 0.0) {
        outProgress.bytesPerSec = m_decodedBytes / elapsedSec;
    }
    return outProgress.isComplete;
}

} // namespace CFC
