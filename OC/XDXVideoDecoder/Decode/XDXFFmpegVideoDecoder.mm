#import "XDXFFmpegVideoDecoder.h"
#include "log4cplus.h"

#define kModuleName "XDXFFmpegVideoDecoder"

@interface XDXFFmpegVideoDecoder () {
    /*  FFmpeg  */
    AVFormatContext          *m_formatContext;
    AVCodecContext           *m_videoCodecContext;
    AVFrame                  *m_videoFrame;
    
    int     m_videoStreamIndex;
    BOOL    m_isFindIDR;
    int64_t m_base_time;
}
@end

@implementation XDXFFmpegVideoDecoder

#pragma mark - C Function
//创建ffmpeg的硬件解码器
AVBufferRef *hw_device_ctx = NULL;
static int InitHardwareDecoder(AVCodecContext *ctx, const enum AVHWDeviceType type) {
    int err = av_hwdevice_ctx_create(&hw_device_ctx, type, NULL, NULL, 0);
    if (err < 0) {
        log4cplus_error(kModuleName, "Failed to create specified HW device");
        return err;
    }
    ctx->hw_device_ctx = av_buffer_ref(hw_device_ctx);
    return err;
}

//获取视频帧率
static int DecodeGetAVStreamFPSTimeBase(AVStream *st) {
    CGFloat fps, timebase = 0.0;
    if (st->time_base.den && st->time_base.num) {
        timebase = av_q2d(st->time_base);
    } else if(st->codec->time_base.den && st->codec->time_base.num) {
        timebase = av_q2d(st->codec->time_base);
    }
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num) {
        fps = av_q2d(st->avg_frame_rate);
    }
    else if (st->r_frame_rate.den && st->r_frame_rate.num) {
        fps = av_q2d(st->r_frame_rate);
    } else {
        fps = 1.0 / timebase;
    }
    return fps;
}

#pragma mark - Lifecycle
- (instancetype)initWithFormatContext:(AVFormatContext *)formatContext videoStreamIndex:(int)videoStreamIndex {
    if (self = [super init]) {
        m_formatContext     = formatContext;
        m_videoStreamIndex  = videoStreamIndex;
        
        m_isFindIDR = NO;
        m_base_time = 0;
        
        [self initDecoder];
    }
    return self;
}

//初始化ffmpeg解码器
- (void)initDecoder {
    AVStream *videoStream = m_formatContext->streams[m_videoStreamIndex];
    m_videoCodecContext = [self createVideoEncderWithFormatContext:m_formatContext
                                                            stream:videoStream
                                                  videoStreamIndex:m_videoStreamIndex];
    if (!m_videoCodecContext) {
        log4cplus_error(kModuleName, "%s: create video codec failed",__func__);
        return;
    }
    
    // Get video frame
    m_videoFrame = av_frame_alloc();
    if (!m_videoFrame) {
        log4cplus_error(kModuleName, "%s: alloc video frame failed",__func__);
        avcodec_close(m_videoCodecContext);
    }
}

#pragma mark - Public
//解码ffmpeg packet的码流数据
- (void)startDecodeVideoDataWithAVPacket:(AVPacket)packet {
    if ((packet.flags == 1) && (m_isFindIDR == NO)) {
        m_isFindIDR = YES;
        m_base_time =  m_videoFrame->pts;//获取到第一个时间戳，后续以这个为基准时间戳求差值
    }
    
    if (m_isFindIDR == YES) {
        [self startDecodeVideoDataWithAVPacket:packet
                             videoCodecContext:m_videoCodecContext
                                    videoFrame:m_videoFrame
                                      baseTime:m_base_time
                              videoStreamIndex:m_videoStreamIndex];
    }
}

- (void)stopDecoder {
    [self freeAllResources];
}

#pragma mark - Private
- (AVCodecContext *)createVideoEncderWithFormatContext:(AVFormatContext *)formatContext stream:(AVStream *)stream videoStreamIndex:(int)videoStreamIndex {
    AVCodecContext *codecContext = NULL;
    AVCodec *codec = NULL;
    
    const char *codecName = av_hwdevice_get_type_name(AV_HWDEVICE_TYPE_VIDEOTOOLBOX);//iOS端通过ffmpeg硬解，内部封装的是VIDEOTOOLBOX框架
    enum AVHWDeviceType type = av_hwdevice_find_type_by_name(codecName);
    if (type != AV_HWDEVICE_TYPE_VIDEOTOOLBOX) {
        log4cplus_error(kModuleName, "%s: Not find hardware codec.",__func__);
        return NULL;
    }
    
    int ret = av_find_best_stream(formatContext, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    if (ret < 0) {
        log4cplus_error(kModuleName, "av_find_best_stream faliture");
        return NULL;
    }
    
    codecContext = avcodec_alloc_context3(codec);
    if (!codecContext) {
        log4cplus_error(kModuleName, "avcodec_alloc_context3 faliture");
        return NULL;
    }
    
    ret = avcodec_parameters_to_context(codecContext, formatContext->streams[videoStreamIndex]->codecpar);
    if (ret < 0) {
        log4cplus_error(kModuleName, "avcodec_parameters_to_context faliture");
        return NULL;
    }
    
    ret = InitHardwareDecoder(codecContext, type);//创建硬件解码器
    if (ret < 0) {
        log4cplus_error(kModuleName, "hw_decoder_init faliture");
        return NULL;
    }
    
    ret = avcodec_open2(codecContext, codec, NULL);//打开硬件解码器
    if (ret < 0) {
        log4cplus_error(kModuleName, "avcodec_open2 faliture");
        return NULL;
    }
    return codecContext;
}

- (void)startDecodeVideoDataWithAVPacket:(AVPacket)packet videoCodecContext:(AVCodecContext *)videoCodecContext videoFrame:(AVFrame *)videoFrame baseTime:(int64_t)baseTime videoStreamIndex:(int)videoStreamIndex {
    Float64 current_timestamp = [self getCurrentTimestamp];
    AVStream *videoStream = m_formatContext->streams[videoStreamIndex];
    int fps = DecodeGetAVStreamFPSTimeBase(videoStream);//获取帧率
    
    avcodec_send_packet(videoCodecContext, &packet);
    while (0 == avcodec_receive_frame(videoCodecContext, videoFrame)) {
        CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)videoFrame->data[3];//ffmpeg硬解出来的图像也是NV12
        CMTime presentationTimeStamp = kCMTimeInvalid;
        int64_t originPTS = videoFrame->pts;
        int64_t newPTS    = originPTS - baseTime;//得到新的时间戳 (这里这样做其实是没必要的，解码后的videoFrame->pts，本身就是递增的)
        presentationTimeStamp = CMTimeMakeWithSeconds(current_timestamp + newPTS * av_q2d(videoStream->time_base) , fps);
        //构建一个CMSampleBufferRef，用于渲染。其实直接给pixelBuffer过去渲染就行了
        CMSampleBufferRef sampleBufferRef = [self convertCVImageBufferRefToCMSampleBufferRef:(CVPixelBufferRef)pixelBuffer
                                                                   withPresentationTimeStamp:presentationTimeStamp];
        if (sampleBufferRef) {
            if ([self.delegate respondsToSelector:@selector(getDecodeVideoDataByFFmpeg:)]) {
                [self.delegate getDecodeVideoDataByFFmpeg:sampleBufferRef];
            }
            
            CFRelease(sampleBufferRef);
        }
    }
}

- (void)freeAllResources {
    if (m_videoCodecContext) {
        avcodec_send_packet(m_videoCodecContext, NULL);
        avcodec_flush_buffers(m_videoCodecContext);
        
        if (m_videoCodecContext->hw_device_ctx) {
            av_buffer_unref(&m_videoCodecContext->hw_device_ctx);
            m_videoCodecContext->hw_device_ctx = NULL;
        }
        avcodec_close(m_videoCodecContext);
        m_videoCodecContext = NULL;
    }
    
    if (m_videoFrame) {
        av_free(m_videoFrame);
        m_videoFrame = NULL;
    }
}

#pragma mark - Other
- (CMSampleBufferRef)convertCVImageBufferRefToCMSampleBufferRef:(CVImageBufferRef)pixelBuffer withPresentationTimeStamp:(CMTime)presentationTimeStamp {
    CVPixelBufferLockBaseAddress(pixelBuffer, 0);
    CMSampleBufferRef newSampleBuffer = NULL;
    OSStatus res = 0;
    
    CMSampleTimingInfo timingInfo;
    timingInfo.duration              = kCMTimeInvalid;
    timingInfo.decodeTimeStamp       = presentationTimeStamp;
    timingInfo.presentationTimeStamp = presentationTimeStamp;//ffmpeg的解码时间戳，是递增顺序的
    
    CMVideoFormatDescriptionRef videoFormatDesc = NULL;
    res = CMVideoFormatDescriptionCreateForImageBuffer(NULL, pixelBuffer, &videoFormatDesc);
    if (res != 0) {
        log4cplus_error(kModuleName, "%s: Create video format description failed!",__func__);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return NULL;
    }
    
    res = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault,
                                             pixelBuffer,
                                             true,
                                             NULL,
                                             NULL,
                                             videoFormatDesc,
                                             &timingInfo, &newSampleBuffer);
    CFRelease(videoFormatDesc);
    if (res != 0) {
        log4cplus_error(kModuleName, "%s: Create sample buffer failed!",__func__);
        CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
        return NULL;
        
    }
    
    CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
    return newSampleBuffer;
}

//获取系统时间戳
- (Float64)getCurrentTimestamp {
    CMClockRef hostClockRef = CMClockGetHostTimeClock();
    CMTime hostTime = CMClockGetTime(hostClockRef);
    return CMTimeGetSeconds(hostTime);
}
@end
