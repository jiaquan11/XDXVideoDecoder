#import <Foundation/Foundation.h>
#import "XDXAVParseHandler.h"

NS_ASSUME_NONNULL_BEGIN

//定义需遵守的协议
@protocol XDXVideoDecoderDelegate <NSObject>

@optional
- (void)getVideoDecodeDataCallback:(CMSampleBufferRef)sampleBuffer isFirstFrame:(BOOL)isFirstFrame;

@end

@interface XDXVideoDecoder : NSObject

@property (weak, nonatomic) id<XDXVideoDecoderDelegate> delegate;

/**
    Start / Stop decoder
 */
- (void)startDecodeVideoData:(struct XDXParseVideoDataInfo *)videoInfo;//开始解码
- (void)stopDecoder;//结束解码

/**
    Reset timestamp when you parse a new file (only use the decoder as global var)
 */
- (void)resetTimestamp;//重置时间戳方法

@end

NS_ASSUME_NONNULL_END
