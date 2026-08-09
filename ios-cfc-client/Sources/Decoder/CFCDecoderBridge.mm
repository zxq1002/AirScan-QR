//
//  CFCDecoderBridge.mm
//  ios-cfc-client
//
//  Objective-C++ Bridge Implementation — v1.1.0
//
//  对齐网页端接收链路的关键改造：
//   1. 背压控制：解码器忙碌时丢弃新帧（对齐 recv.js `_framesInFlight > 20` 限流），
//      避免串行队列无限堆积导致内存暴涨与延迟放大。
//   2. 像素格式校验：仅处理 32BGRA，杜绝脏数据进入解码核心。
//   3. 引擎状态透传：把模式 / backendReady / 状态文案上抛给 UI，
//      解码引擎未链接时诚实提示（不再伪造进度）。
//

#import "CFCDecoderBridge.h"
#include "CFCCoreDecoder.hpp"

#include <atomic>

@implementation CFCDecoderBridge {
    std::unique_ptr<CFC::CoreDecoder> _cppDecoder;
    dispatch_queue_t _processingQueue;
    std::atomic<bool> _busy;             // 背压标志
    BOOL _warnedBackendMissing;          // 引擎缺失提示只报一次
}

+ (instancetype)sharedInstance {
    static CFCDecoderBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[CFCDecoderBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _cppDecoder = std::make_unique<CFC::CoreDecoder>();
        _processingQueue = dispatch_queue_create("com.airscan.cfc.decoder", DISPATCH_QUEUE_SERIAL);
        _isDecoding = NO;
        _busy = false;
        _warnedBackendMissing = NO;
        NSLog(@"[CFCBridge] 解码桥接服务初始化成功");
    }
    return self;
}

- (BOOL)isBusy {
    return _busy.load() ? YES : NO;
}

- (void)startDecodingSession {
    dispatch_async(_processingQueue, ^{
        self->_cppDecoder->reset();
        self->_isDecoding = YES;
        NSLog(@"[CFCBridge] 开始解码 Session (backendReady=%d)", self->_cppDecoder->backendReady());
    });
}

- (void)stopDecodingSession {
    dispatch_async(_processingQueue, ^{
        self->_isDecoding = NO;
    });
}

- (void)resetDecoder {
    dispatch_async(_processingQueue, ^{
        self->_cppDecoder->reset();
        self->_warnedBackendMissing = NO;
        self->_isDecoding = YES;
        NSLog(@"[CFCBridge] 解码器已重置");
    });
}

- (void)configureMode:(NSInteger)mode {
    dispatch_async(_processingQueue, ^{
        self->_cppDecoder->configureMode((int)mode);
    });
}

- (BOOL)processSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    if (!_isDecoding || !sampleBuffer) return NO;

    // 背压：解码器仍在处理上一帧 → 丢弃本帧（对齐网页端限流）
    if (_busy.exchange(true)) {
        return NO;
    }

    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) {
        _busy = false;
        return NO;
    }

    // 像素格式校验：与 CameraManager 配置的 32BGRA 一致
    OSType pixelFormat = CVPixelBufferGetPixelFormatType(imageBuffer);
    if (pixelFormat != kCVPixelFormatType_32BGRA) {
        _busy = false;
        return NO;
    }

    CFRetain(sampleBuffer);
    dispatch_async(_processingQueue, ^{
        [self _processRetainedSampleBuffer:sampleBuffer];
        CFRelease(sampleBuffer);
        self->_busy = false;
    });
    return YES;
}

- (void)_processRetainedSampleBuffer:(CMSampleBufferRef)sampleBuffer {
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!imageBuffer) return;

    CVPixelBufferLockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    int width = (int)CVPixelBufferGetWidth(imageBuffer);
    int height = (int)CVPixelBufferGetHeight(imageBuffer);
    int bytesPerRow = (int)CVPixelBufferGetBytesPerRow(imageBuffer);
    uint8_t *baseAddress = (uint8_t *)CVPixelBufferGetBaseAddress(imageBuffer);

    CFC::DecodeProgress progress;
    bool isComplete = _cppDecoder->decodeFrame(baseAddress, width, height, bytesPerRow, progress);

    CVPixelBufferUnlockBaseAddress(imageBuffer, kCVPixelBufferLock_ReadOnly);

    // 引擎缺失：只提示一次，避免刷屏
    BOOL backendReady = progress.backendReady ? YES : NO;
    NSString *statusText = [NSString stringWithUTF8String:progress.statusText.c_str()];
    if (!backendReady && !_warnedBackendMissing) {
        _warnedBackendMissing = YES;
        NSLog(@"[CFCBridge] ⚠️ %@", statusText);
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.delegate && [self.delegate respondsToSelector:@selector(didUpdateProgressWithRank:total:fps:bytesPerSec:)]) {
            [self.delegate didUpdateProgressWithRank:progress.solvedChunks
                                               total:progress.totalChunks
                                                 fps:progress.currentFps
                                         bytesPerSec:progress.bytesPerSec];
        }

        if (self.delegate && [self.delegate respondsToSelector:@selector(didUpdateActiveMode:backendReady:statusText:)]) {
            [self.delegate didUpdateActiveMode:progress.activeMode
                                  backendReady:backendReady
                                    statusText:statusText];
        }

        if (isComplete && self.delegate && [self.delegate respondsToSelector:@selector(didCompleteTransferWithFileName:fileData:)]) {
            NSString *fileName = [NSString stringWithUTF8String:progress.fileName.c_str()];
            if (fileName.length == 0) fileName = @"received_file";
            NSData *data = [NSData dataWithBytes:progress.completedData.data() length:progress.completedData.size()];
            [self.delegate didCompleteTransferWithFileName:fileName fileData:data];
            self->_isDecoding = NO;
        }
    });
}

@end
