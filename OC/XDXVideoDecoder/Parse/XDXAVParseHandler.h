#import <AVFoundation/AVFoundation.h>

// FFmpeg Header File
#ifdef __cplusplus
extern "C" {
#endif
    
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#include "libavutil/opt.h"
    
#ifdef __cplusplus
};
#endif

NS_ASSUME_NONNULL_BEGIN

typedef enum : NSUInteger {
    XDXH264EncodeFormat,
    XDXH265EncodeFormat,
} XDXVideoEncodeFormat;

//存储解析的视频信息
struct XDXParseVideoDataInfo {
    uint8_t                 *data;
    int                     dataSize;
    uint8_t                 *extraData;
    int                     extraDataSize;
    Float64                 pts;
    Float64                 time_base;
    int                     videoRotate;
    int                     fps;
    CMSampleTimingInfo      timingInfo;
    XDXVideoEncodeFormat    videoFormat;
};

//存储解析的音频信息
struct XDXParseAudioDataInfo {
    uint8_t     *data;
    int         dataSize;
    int         channel;
    int         sampleRate;
    Float64     pts;
};

@interface XDXAVParseHandler : NSObject

/**
 Init Parse Handler by file path

 @param path file path
 @return the object instance
 */
- (instancetype)initWithPath:(NSString *)path;//媒体路径

/**
 Start parse file content
 
 Note:
 1.You could get the audio / video infomation by `XDXParseVideoDataInfo` ,  `XDXParseAudioDataInfo`.
 2.You could get the audio / video infomation by `AVPacket`.
 @param handler get some parse information.
 */
- (void)startParseGetAVPackeWithCompletionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, AVPacket packet))handler;

- (void)startParseWithCompletionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, struct XDXParseVideoDataInfo *videoInfo, struct XDXParseAudioDataInfo *audioInfo))handler;

/**
 Get Method
 */
- (AVFormatContext *)getFormatContext;//媒体信息上下文
- (int)getVideoStreamIndex;//视频流索引
- (int)getAudioStreamIndex;//音频流索引

@end

NS_ASSUME_NONNULL_END
