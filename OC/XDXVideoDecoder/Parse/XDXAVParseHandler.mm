#import "XDXAVParseHandler.h"
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include "log4cplus.h"

#pragma mark - Global Var

#define kModuleName "XDXParseHandler"

static const int kXDXParseSupportMaxFps     = 60;
static const int kXDXParseFpsOffSet         = 5;
static const int kXDXParseWidth1920         = 1920;
static const int kXDXParseHeight1080        = 1080;
static const int kXDXParseSupportMaxWidth   = 3840;
static const int kXDXParseSupportMaxHeight  = 2160;

@interface XDXAVParseHandler ()
{
    /*  Flag  */
    BOOL m_isStopParse;
    
    /*  FFmpeg  */
    AVFormatContext          *m_formatContext;
    AVBitStreamFilterContext *m_bitFilterContext;
//    AVBSFContext             *m_bsfContext;
    
    int m_videoStreamIndex;
    int m_audioStreamIndex;
    
    /*  Video info  */
    int m_video_width, m_video_height, m_video_fps;
}

@end

@implementation XDXAVParseHandler

//静态方法，根据时间基准计算得到帧率
#pragma mark - C Function
static int GetAVStreamFPSTimeBase(AVStream *st) {
    CGFloat fps, timebase = 0.0;
    
    if (st->time_base.den && st->time_base.num) {
        timebase = av_q2d(st->time_base);
        log4cplus_info(kModuleName, "1-timebase %f, num: %d, den: %d", timebase, st->time_base.num, st->time_base.den);
    } else if(st->codec->time_base.den && st->codec->time_base.num) {
        timebase = av_q2d(st->codec->time_base);
        log4cplus_info(kModuleName, "2-timebase %f, num: %d, den: %d", timebase, st->codec->time_base.num, st->codec->time_base.den);
    }
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num) {
        fps = av_q2d(st->avg_frame_rate);
        log4cplus_info(kModuleName, "1-fps: %f", fps);
    } else if (st->r_frame_rate.den && st->r_frame_rate.num) {
        fps = av_q2d(st->r_frame_rate);
        log4cplus_info(kModuleName, "2-fps: %f", fps);
    } else {
        fps = 1.0 / timebase;
        log4cplus_info(kModuleName, "3-fps: %f", fps);
    }
    return fps;
}

#pragma mark - Init
//initialize为自动调用方法
+ (void)initialize {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        av_register_all();//注册ffmpeg库各个模块
    });
}

- (instancetype)initWithPath:(NSString *)path {
    if (self = [super init]) {
        [self prepareParseWithPath:path];
    }
    return self;
}

//公共方法
#pragma mark - public methods
- (void)startParseGetAVPackeWithCompletionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, AVPacket packet))handler {
    [self startParseGetAVPacketWithFormatContext:m_formatContext
                                videoStreamIndex:m_videoStreamIndex
                                audioStreamIndex:m_audioStreamIndex
                               completionHandler:handler];
}

- (void)startParseWithCompletionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, struct XDXParseVideoDataInfo *videoParseInfo, struct XDXParseAudioDataInfo *audioParseInfo))handler {
    [self startParseWithFormatContext:m_formatContext
                     videoStreamIndex:m_videoStreamIndex
                     audioStreamIndex:m_audioStreamIndex
                    completionHandler:handler];
}

- (void)stopParse {
    m_isStopParse = YES;
}

//外部获取方法
#pragma mark Get Method
//获取媒体文件上下文
- (AVFormatContext *)getFormatContext {
    return m_formatContext;
}
//获取视频索引
- (int)getVideoStreamIndex {
    return m_videoStreamIndex;
}
//获取音频索引
- (int)getAudioStreamIndex {
    return m_audioStreamIndex;
}

//私有方法
#pragma mark - Private
#pragma mark Prepare
- (void)prepareParseWithPath:(NSString *)path {
    // Create format context
    m_formatContext = [self createFormatContextbyFilePath:path];//打开媒体文件，获取流信息
    if (m_formatContext == NULL) {
        log4cplus_error(kModuleName, "%s: create format context failed.",__func__);
        return;
    }
    
    // Get video stream index
    m_videoStreamIndex = [self getAVStreamIndexWithFormatContext:m_formatContext isVideoStream:YES];//获取视频索引
    
    // Get video stream
    AVStream *videoStream = m_formatContext->streams[m_videoStreamIndex];//获取视频流
    m_video_width  = videoStream->codecpar->width;//视频的宽
    m_video_height = videoStream->codecpar->height;//视频的高
    m_video_fps    = GetAVStreamFPSTimeBase(videoStream);//获取到视频的帧率
    log4cplus_info(kModuleName, "%s: video index:%d, width:%d, height:%d, fps:%d",__func__,m_videoStreamIndex,m_video_width,m_video_height,m_video_fps);
    
    //判断本机器是否支持视频解码的宽高及帧率
    BOOL isSupport = [self isSupportVideoStream:videoStream
                                  formatContext:m_formatContext
                                    sourceWidth:m_video_width
                                   sourceHeight:m_video_height
                                      sourceFps:m_video_fps];
    if (!isSupport) {
        log4cplus_error(kModuleName, "%s: Not support the video stream",__func__);
        return;
    }
    
    // Get audio stream index
    m_audioStreamIndex = [self getAVStreamIndexWithFormatContext:m_formatContext isVideoStream:NO];//获取音频流的索引
    
    // Get audio stream
    AVStream *audioStream = m_formatContext->streams[m_audioStreamIndex];
    isSupport = [self isSupportAudioStream:audioStream formatContext:m_formatContext];//判断是否支持音频格式
    if (!isSupport) {
        log4cplus_error(kModuleName, "%s: Not support the audio stream",__func__);
        return;
    }
}

//打开媒体文件，获取流信息
- (AVFormatContext *)createFormatContextbyFilePath:(NSString *)filePath {
    if (filePath == nil) {
        log4cplus_error(kModuleName, "%s: file path is NULL",__func__);
        return NULL;
    }
    
    AVFormatContext  *formatContext = NULL;
    AVDictionary     *opts          = NULL;
    
    av_dict_set(&opts, "timeout", "1000000", 0);//设置超时1秒
    
    formatContext = avformat_alloc_context();
    BOOL isSuccess = avformat_open_input(&formatContext, [filePath cStringUsingEncoding:NSUTF8StringEncoding], NULL, &opts) < 0 ? NO : YES;
    av_dict_free(&opts);
    if (!isSuccess) {
        if (formatContext) {
            avformat_free_context(formatContext);
        }
        return NULL;
    }
    
    if (avformat_find_stream_info(formatContext, NULL) < 0) {
        avformat_close_input(&formatContext);
        return NULL;
    }
    return formatContext;
}

//根据媒体信息获取指定流的索引
- (int)getAVStreamIndexWithFormatContext:(AVFormatContext *)formatContext isVideoStream:(BOOL)isVideoStream {
    int avStreamIndex = -1;
    for (int i = 0; i < formatContext->nb_streams; i++) {
        if ((isVideoStream ? AVMEDIA_TYPE_VIDEO : AVMEDIA_TYPE_AUDIO) == formatContext->streams[i]->codecpar->codec_type) {
            avStreamIndex = i;
        }
    }
    
    if (avStreamIndex == -1) {
        log4cplus_error(kModuleName, "%s: Not find the stream",__func__);//__func__宏名称表示当前函数的名称
        return NULL;
    }else {
        return avStreamIndex;
    }
}

- (BOOL)isSupportVideoStream:(AVStream *)stream formatContext:(AVFormatContext *)formatContext sourceWidth:(int)sourceWidth sourceHeight:(int)sourceHeight sourceFps:(int)sourceFps {
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_VIDEO) {   // Video
        AVCodecID codecID = stream->codecpar->codec_id;
        log4cplus_info(kModuleName, "%s: Current video codec format is %s",__func__, avcodec_find_decoder(codecID)->name);
        // 目前只支持H264、H265(HEVC iOS11)编码格式的视频文件
        if ((codecID != AV_CODEC_ID_H264 && codecID != AV_CODEC_ID_HEVC) || (codecID == AV_CODEC_ID_HEVC && [[UIDevice currentDevice].systemVersion floatValue] < 11.0)) {
            log4cplus_error(kModuleName, "%s: Not support the codec",__func__);
            return NO;
        }
        
        // iPhone 8以上机型支持有旋转角度的视频
        AVDictionaryEntry *tag = NULL;
        tag = av_dict_get(formatContext->streams[m_videoStreamIndex]->metadata, "rotate", tag, 0);
        if (tag != NULL) {
            int rotate = [[NSString stringWithFormat:@"%s",tag->value] intValue];
//            if (rotate != 0 && (iphoneType <= 8)) {
//                log4cplus_error(kModuleName, "%s: Not support rotate for device ",__func__);
//            }
        }
        
        /*
         各机型支持的最高分辨率和FPS组合:
         
         iPhone 6S: 60fps -> 720P
         30fps -> 4K
         
         iPhone 7P: 60fps -> 1080p
         30fps -> 4K
         
         iPhone 8: 60fps -> 1080p
         30fps -> 4K
         
         iPhone 8P: 60fps -> 1080p
         30fps -> 4K
         
         iPhone X: 60fps -> 1080p
         30fps -> 4K
         
         iPhone XS: 60fps -> 1080p
         30fps -> 4K
         */
        
        // 目前最高支持到60FPS  帧率不能超过60fps
        if (sourceFps > kXDXParseSupportMaxFps + kXDXParseFpsOffSet) {
            log4cplus_error(kModuleName, "%s: Not support the fps",__func__);
            return NO;
        }
        
        // 目前最高支持到3840*2160 分辨率不能超过4K
        if ((sourceWidth > kXDXParseSupportMaxWidth) || (sourceHeight > kXDXParseSupportMaxHeight)) {
            log4cplus_error(kModuleName, "%s: Not support the resolution",__func__);
            return NO;
        }
        
        // 60FPS -> 1080P   60fps的帧率，只能支持到1080P
        if ((sourceFps > (kXDXParseSupportMaxFps - kXDXParseFpsOffSet)) && ((sourceWidth > kXDXParseWidth1920) || (sourceHeight > kXDXParseHeight1080))) {
            log4cplus_error(kModuleName, "%s: Not support the fps and resolution",__func__);
            return NO;
        }
        
        // 30FPS -> 4K  30fps的帧率，可以支持到4K
        if (sourceFps > kXDXParseSupportMaxFps / 2 + kXDXParseFpsOffSet && (sourceWidth >= kXDXParseSupportMaxWidth || sourceHeight >= kXDXParseSupportMaxHeight)) {
            log4cplus_error(kModuleName, "%s: Not support the fps and resolution",__func__);
            return NO;
        }
        
        // 6S
//        if ([[XDXAnywhereTool deviceModelName] isEqualToString:@"iPhone 6s"] && sourceFps > kXDXParseSupportMaxFps - kXDXParseFpsOffSet && (sourceWidth >= kXDXParseWidth1920  || sourceHeight >= kXDXParseHeight1080)) {
//            log4cplus_error(kModuleName, "%s: Not support the fps and resolution",__func__);
//            return NO;
//        }
        return YES;
    }else {
        return NO;
    }
}

- (BOOL)isSupportAudioStream:(AVStream *)stream formatContext:(AVFormatContext *)formatContext {
    if (stream->codecpar->codec_type == AVMEDIA_TYPE_AUDIO) {
        AVCodecID codecID = stream->codecpar->codec_id;
        log4cplus_info(kModuleName, "%s: Current audio codec format is %s",__func__, avcodec_find_decoder(codecID)->name);
        // 本项目只支持AAC格式的音频
        if (codecID != AV_CODEC_ID_AAC) {
            log4cplus_error(kModuleName, "%s: Only support AAC format for the demo.",__func__);
            return NO;
        }
        return YES;
    }else {
        return NO;
    }
}

#pragma mark Start Parse
//这里ffmpeg解析读取到的packet,不断通过回调函数给到ffmpeg解码模块那边进行解码
- (void)startParseGetAVPacketWithFormatContext:(AVFormatContext *)formatContext videoStreamIndex:(int)videoStreamIndex audioStreamIndex:(int)audioStreamIndex completionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, AVPacket packet))handler{
    m_isStopParse = NO;
    dispatch_queue_t parseQueue = dispatch_queue_create("parse_queue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(parseQueue, ^{//异步处理
        AVPacket packet;
        while (!self->m_isStopParse) {
            if (!formatContext) {
                break;
            }

            av_init_packet(&packet);
            int size = av_read_frame(formatContext, &packet);
            if ((size < 0) || (packet.size < 0)) {//这里会退出流数据的读取,结束播放
                handler(YES, YES, packet);
                log4cplus_error(kModuleName, "%s: Parse finish",__func__);
                break;
            }
            
            if (packet.stream_index == videoStreamIndex) {
                handler(YES, NO, packet);
            } else {//音频数据暂不处理，不播放
                handler(NO, NO, packet);
            }
            
            av_packet_unref(&packet);//释放packet引用计数
        }
        
        [self freeAllResources];//媒体流解析完后，释放所有的解析资源
    });
}

- (void)startParseWithFormatContext:(AVFormatContext *)formatContext videoStreamIndex:(int)videoStreamIndex audioStreamIndex:(int)audioStreamIndex completionHandler:(void (^)(BOOL isVideoFrame, BOOL isFinish, struct XDXParseVideoDataInfo *videoInfo, struct XDXParseAudioDataInfo *audioInfo))handler{
    m_isStopParse = NO;
    
    dispatch_queue_t parseQueue = dispatch_queue_create("parse_queue", DISPATCH_QUEUE_SERIAL);
    dispatch_async(parseQueue, ^{
        int fps = GetAVStreamFPSTimeBase(formatContext->streams[videoStreamIndex]);//获取视频帧率
        AVPacket    packet;
        AVRational  input_base;
        input_base.num = 1;
        input_base.den = 1000;
        
        Float64 current_timestamp = [self getCurrentTimestamp];//获取系统时间戳
        while (!self->m_isStopParse) {
            av_init_packet(&packet);
            if (!formatContext) {
                break;
            }
            
            int size = av_read_frame(formatContext, &packet);
            if ((size < 0) || (packet.size < 0)) {//退出读取
                handler(YES, YES, NULL, NULL);
                log4cplus_error(kModuleName, "%s: Parse finish",__func__);
                break;
            }
            
            if (packet.stream_index == videoStreamIndex) {
                XDXParseVideoDataInfo videoParseInfo = {0};
                
                // get the rotation angle of video
                AVDictionaryEntry *tag = NULL;
                tag = av_dict_get(formatContext->streams[videoStreamIndex]->metadata, "rotate", tag, 0);
                if (tag != NULL) {
                    int rotate = [[NSString stringWithFormat:@"%s",tag->value] intValue];
                    switch (rotate) {
                        case 90:
                            videoParseInfo.videoRotate = 90;
                            break;
                        case 180:
                            videoParseInfo.videoRotate = 180;
                            break;
                        case 270:
                            videoParseInfo.videoRotate = 270;
                            break;
                        default:
                            videoParseInfo.videoRotate = 0;
                            break;
                    }
                }
                
                int video_size = packet.size;
                uint8_t *video_data = (uint8_t *)malloc(video_size);//分配视频包内存，保存视频码流给到解码器
                memcpy(video_data, packet.data, video_size);
                
                static char filter_name[32];
                if (formatContext->streams[videoStreamIndex]->codecpar->codec_id == AV_CODEC_ID_H264) {
                    strncpy(filter_name, "h264_mp4toannexb", 32);
                    videoParseInfo.videoFormat = XDXH264EncodeFormat;
                } else if (formatContext->streams[videoStreamIndex]->codecpar->codec_id == AV_CODEC_ID_HEVC) {
                    strncpy(filter_name, "hevc_mp4toannexb", 32);
                    videoParseInfo.videoFormat = XDXH265EncodeFormat;
                } else {
                    break;
                }
                
                /* new API can't get correct sps, pps.
                 if (!self->m_bsfContext) {
                 const AVBitStreamFilter *filter = av_bsf_get_by_name(filter_name);
                 av_bsf_alloc(filter, &self->m_bsfContext);
                 av_bsf_init(self->m_bsfContext);
                 avcodec_parameters_copy(self->m_bsfContext->par_in, formatContext->streams[videoStreamIndex]->codecpar);
                 }
                 */
                
                int extrasize = formatContext->streams[videoStreamIndex]->codec->extradata_size;
                NSLog(@"-------------parse extra data------------size:%d", extrasize);
                NSMutableString *extraDataString = [NSMutableString string];
                [extraDataString appendFormat:@"\n"];
                for (int i = 0; i < extrasize; i++) {
                    [extraDataString appendFormat:@"%02X ", formatContext->streams[videoStreamIndex]->codec->extradata[i]];
                    if ((i + 1) % 16 == 0) {
                        [extraDataString appendFormat:@"\n"];
                    }
                }
                NSLog(@"%@", extraDataString);
                
                // get sps,pps. If not call it, get sps , pps is incorrect. use new_packet to resolve memory leak.
                AVPacket new_packet = packet;

                if (self->m_bitFilterContext == NULL) {
                    self->m_bitFilterContext = av_bitstream_filter_init(filter_name);
                }
                /*过滤一下，每个视频帧前添加startcode
                 这个函数会对extradata进行解析，提取出vps,sps,pps，并在每个数据字段前添加startcode.
                 同时对每个图像数据包进行过滤，也将avcc字段转换为startcode四字节，但这并不是IOS硬解所需要的，IOS硬解所需要是AVCC字段的图像数据包，因此
                 直接将packet.data传送给IOS的VideoToolsBox解码器解码就行，不需要这个过滤后的newpacket.data数据.
                 但是创建IOS硬件解码器的VideoFormat信息需要实际的VPS,SPS,PPS数据，所以这里过滤可以把extradata中的VPS,SPS,PPS提取出来，并在前面添加了
                 startcode,变成00 00 00 01 vps,00 00 00 01 sps,00 00 00 01 pps,在创建IOS的VideoToolsBox的videoformat时，需要去掉这些statcode,取
                 实际数据
                 */
                av_bitstream_filter_filter(self->m_bitFilterContext, formatContext->streams[videoStreamIndex]->codec, NULL, &new_packet.data, &new_packet.size, packet.data, packet.size, 0);//new_packet.data为输入，packet.data为输出
                
                //log4cplus_info(kModuleName, "%s: extra data : %s , size : %d",__func__,formatContext->streams[videoStreamIndex]->codec->extradata,formatContext->streams[videoStreamIndex]->codec->extradata_size);
                
//                log4cplus_info(kModuleName, "%s: packet size: %d, new packet size: %d",__func__, packet.size, new_packet.size);
                
                /*
                 根据特定规则生成时间戳
                 可以根据自己的需求自定义时间戳生成规则.这里使用当前系统时间戳加上数据包中的自带的pts/dts生成了时间戳*/
                CMSampleTimingInfo timingInfo;
                CMTime presentationTimeStamp     = kCMTimeInvalid;
                presentationTimeStamp            = CMTimeMakeWithSeconds(current_timestamp + packet.pts * av_q2d(formatContext->streams[videoStreamIndex]->time_base), fps);//计算得到显示时间戳 pts
                timingInfo.presentationTimeStamp = presentationTimeStamp;
                timingInfo.decodeTimeStamp       = CMTimeMakeWithSeconds(current_timestamp + av_rescale_q(packet.dts, formatContext->streams[videoStreamIndex]->time_base, input_base), fps); //计算得到解码时间戳 dts

                videoParseInfo.data          = video_data;
                videoParseInfo.dataSize      = video_size;
                videoParseInfo.extraDataSize = formatContext->streams[videoStreamIndex]->codec->extradata_size;
                videoParseInfo.extraData     = (uint8_t *)malloc(videoParseInfo.extraDataSize);
                videoParseInfo.timingInfo    = timingInfo;
                videoParseInfo.pts           = packet.pts * av_q2d(formatContext->streams[videoStreamIndex]->time_base);
                videoParseInfo.fps           = fps;
                
                log4cplus_info(kModuleName, "%s: packet pts: %lld, packet dts: %lld, videoParseInfo pts:%f",__func__, packet.pts, packet.dts, videoParseInfo.pts);

                memcpy(videoParseInfo.extraData, formatContext->streams[videoStreamIndex]->codec->extradata, videoParseInfo.extraDataSize);
                av_free(new_packet.data);//需要及时释放

                // send videoInfo
                if (handler) {
                    handler(YES, NO, &videoParseInfo, NULL);
                }

                //每次使用，每次分配，用完后需要及时释放
                free(videoParseInfo.extraData);
                free(videoParseInfo.data);
            }
            
            if (packet.stream_index == audioStreamIndex) {
                XDXParseAudioDataInfo audioParseInfo = {0};
                audioParseInfo.data = (uint8_t *)malloc(packet.size);
                memcpy(audioParseInfo.data, packet.data, packet.size);
                audioParseInfo.dataSize = packet.size;//音频包大小
                audioParseInfo.channel = formatContext->streams[audioStreamIndex]->codecpar->channels;//音频通道
                audioParseInfo.sampleRate = formatContext->streams[audioStreamIndex]->codecpar->sample_rate;//音频采样率
                audioParseInfo.pts = packet.pts * av_q2d(formatContext->streams[audioStreamIndex]->time_base);//音频时间戳
                // send audio info
                if (handler) {
                    handler(NO, NO, NULL, &audioParseInfo);
                }
                
                free(audioParseInfo.data);
            }
            
            av_packet_unref(&packet);
        }
        
        [self freeAllResources];
    });
}

- (void)freeAllResources {
    log4cplus_info(kModuleName, "%s: Free all resources !",__func__);
    if (m_formatContext) {
        avformat_close_input(&m_formatContext);
        m_formatContext = NULL;
    }
    
    if (m_bitFilterContext) {
        av_bitstream_filter_close(m_bitFilterContext);
        m_bitFilterContext = NULL;
    }
    
//    if (m_bsfContext) {
//        av_bsf_free(&m_bsfContext);
//        m_bsfContext = NULL;
//    }
}

#pragma mark Other
//获取系统时间戳
- (Float64)getCurrentTimestamp {
    CMClockRef hostClockRef = CMClockGetHostTimeClock();
    CMTime hostTime = CMClockGetTime(hostClockRef);
    return CMTimeGetSeconds(hostTime);
}

@end
