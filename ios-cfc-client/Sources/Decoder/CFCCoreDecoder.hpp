//
//  CFCCoreDecoder.hpp
//  ios-cfc-client
//
//  Cimbar 解码核心（接收端）
//
//  ⚠️ 对齐说明（v1.1.0 重构）
//  ------------------------------------------------------------------
//  网页端 (cimbar-transfer.html + cimbar-deps/recv*.js) 的接收链路为：
//      cimbard_configure_decode(mode)          // 模式配置/自动识别
//      cimbard_scan_extract_decode(...)        // 扫描→校正→解调（依赖 libcimbar+OpenCV）
//      cimbard_fountain_decode(...)            // 喷泉码重组（wirehair）
//      cimbard_get_report(...)                 // JSON 进度报告
//      cimbard_get_filename / decompress_read  // 文件名 + Zstd 解压
//
//  本类是上述 WASM 管线在 iOS 原生侧的「等价编排层」：
//   - 负责模式自动识别状态机（与 recv.js 的 modeVals=[66,68,67,4] 轮询一致）；
//   - 负责把每一帧交给底层 Backend（真实 libcimbar 引擎）；
//   - 负责进度统计与完成判定。
//
//  ❗ 真实解码能力由 Backend 提供。若未链接 libcimbar（见 CFCCoreDecoder.cpp
//     顶部的 CFC_LIBCIMBAR_BACKEND 宏），解码器会诚实地上报 backendReady=false，
//     绝不伪造进度/完成（旧版像素异或伪解码已移除）。
//

#ifndef CFCCoreDecoder_hpp
#define CFCCoreDecoder_hpp

#include <vector>
#include <string>
#include <cstdint>
#include <map>
#include <set>

namespace CFC {

/// 与网页端 setMode() 的 modeToString 保持一致
enum CimbarMode : int {
    ModeAuto = 0,
    Mode4C   = 4,    // 高密度彩色
    ModeBu   = 66,   // 高对比度
    ModeBm   = 67,   // 改进
    ModeB    = 68,   // 稳定（默认）
};

const char* ModeToString(int modeVal);

struct DecodeProgress {
    int solvedChunks = 0;          // 已重组块数（对齐 report 语义）
    int totalChunks = 0;           // 总块数
    double currentFps = 0.0;       // 捕获帧率
    double bytesPerSec = 0.0;      // 解码吞吐
    bool isComplete = false;       // 文件重组完成
    std::string fileName;          // 真实文件名（zstd header）
    std::vector<uint8_t> completedData;

    // ---- v1.1.0 新增：与网页端 HUD 对齐 ----
    int activeMode = 0;            // 当前锁定的解码模式（0=仍在自动轮询）
    bool backendReady = false;     // 底层 libcimbar 引擎是否已链接
    std::string statusText;        // 面向用户的状态说明
    uint64_t decodedBytes = 0;     // 累计成功解码字节数
};

class CoreDecoder {
public:
    CoreDecoder();
    ~CoreDecoder();

    void reset();

    /// 对齐 cimbard_configure_decode：mode<=0 表示自动识别
    void configureMode(int modeVal);
    int activeMode() const { return m_activeMode; }

    /// 底层真实解码引擎是否可用
    bool backendReady() const;

    /// 处理一帧 BGRA 像素（来自 AVCaptureVideoDataOutput）
    bool decodeFrame(const uint8_t* bgraBuffer, int width, int height,
                     int bytesPerRow, DecodeProgress& outProgress);

    /// CRC-16 CCITT (Poly: 0x1021, Init: 0xFFFF)，与 libcimbar 协议一致
    static uint16_t calculateCRC16(const uint8_t* data, size_t length);

private:
    // 模式自动识别：与 recv.js `modeVals[_counter % 4]` 轮询逻辑一致
    void advanceAutoMode();
    void onDecodeSuccessLockMode(int mode);

    int m_activeMode = 0;          // 0 = auto
    int m_autoModeIndex = 0;
    int m_candidateMode = ModeBu;  // auto 状态下正在轮询的候选模式
    uint64_t m_frameCount = 0;
    uint64_t m_startTimeMs = 0;
    uint64_t m_decodedBytes = 0;

    // 重组状态（仅当真实 Backend 启用后由其填充；保留字段以便平滑接入）
    std::map<int, std::vector<uint8_t>> m_solvedMap;
    int m_totalChunks = 0;
    uint32_t m_fileSize = 0;
    std::string m_fileName;
};

} // namespace CFC

#endif /* CFCCoreDecoder_hpp */
