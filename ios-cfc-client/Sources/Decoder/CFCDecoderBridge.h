//
//  CFCDecoderBridge.h
//  ios-cfc-client
//
//  Objective-C++ Bridge interfacing Swift AVFoundation with C++ Cimbar Decoder
//
//  v1.1.0：对齐网页端接收链路
//   - isBusy：背压控制，解码器忙碌时丢弃新帧（对齐 recv.js framesInFlight 限流）
//   - configureMode：模式配置（对齐 cimbard_configure_decode）
//   - 像素格式校验：仅处理 32BGRA，避免脏数据进入解码器
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CFCDecoderDelegate <NSObject>
@optional
- (void)didUpdateProgressWithRank:(NSInteger)rank total:(NSInteger)total fps:(double)fps bytesPerSec:(double)bytesPerSec;
- (void)didCompleteTransferWithFileName:(NSString *)fileName fileData:(NSData *)fileData;
- (void)didFailWithError:(NSString *)errorMessage;
/// v1.1.0 新增：模式与引擎状态（对齐网页端模式指示 / 解码信息）
- (void)didUpdateActiveMode:(NSInteger)mode backendReady:(BOOL)backendReady statusText:(NSString *)statusText;
@end

@interface CFCDecoderBridge : NSObject

@property (nonatomic, weak) id<CFCDecoderDelegate> delegate;
@property (nonatomic, readonly) BOOL isDecoding;
/// 背压标志：解码器正在处理上一帧（串行队列非空）时为 YES
@property (atomic, readonly) BOOL isBusy;

+ (instancetype)sharedInstance;

- (void)startDecodingSession;
- (void)stopDecodingSession;
- (void)resetDecoder;

/// 对齐 cimbard_configure_decode；mode<=0 表示自动识别
- (void)configureMode:(NSInteger)mode;

/// Process pixel buffer directly from AVCaptureVideoDataOutput SampleBuffer.
/// 返回 NO 表示本帧被丢弃（解码器忙碌 / 格式不符 / 会话未启动）。
- (BOOL)processSampleBuffer:(CMSampleBufferRef)sampleBuffer;

@end

NS_ASSUME_NONNULL_END
