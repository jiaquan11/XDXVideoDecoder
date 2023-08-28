#import "XDXVideoDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <pthread.h>
#include "log4cplus.h"
#import "XDXPreviewView.h"

#define kModuleName "XDXVideoDecoder"

//视频解码器视频信息
typedef struct {
    CVPixelBufferRef outputPixelbuffer;
    int              rotate;
    Float64          pts;
    int              fps;
    int              source_index;
} XDXDecodeVideoInfo;

//视频解码器视频头部信息
typedef struct {
    uint8_t *vps;
    uint8_t *sps;
    
    // H265有前后两个pps
    uint8_t *f_pps;
    uint8_t *r_pps;
    
    int vps_size;
    int sps_size;
    int f_pps_size;
    int r_pps_size;
    
    Float64 last_decode_pts;
} XDXDecoderInfo;

//类成员变量
@interface XDXVideoDecoder ()
{
    VTDecompressionSessionRef   _decoderSession;//硬件解码器实例
    CMVideoFormatDescriptionRef _decoderFormatDescription;//解码器格式描述信息

    XDXDecoderInfo  _decoderInfo;//视频解码器视频头部信息
    pthread_mutex_t _decoder_lock;
    
    uint8_t *_lastExtraData;
    int     _lastExtraDataSize;
    
    BOOL _isFirstFrame;
}

@end

@implementation XDXVideoDecoder

#pragma mark - Callback
//收到解码后数据的回调
static void VideoDecoderCallback(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef pixelBuffer, CMTime presentationTimeStamp, CMTime presentationDuration) {
    XDXDecodeVideoInfo *sourceRef = (XDXDecodeVideoInfo *)sourceFrameRefCon;
    if (pixelBuffer == NULL) {
        log4cplus_error(kModuleName, "%s: pixelbuffer is NULL status = %d",__func__,status);
        if (sourceRef) {
            free(sourceRef);
        }
        return;
    }
    
    XDXVideoDecoder *decoder = (__bridge XDXVideoDecoder *)decompressionOutputRefCon;//videotoolbox视频解码器
    
    CMSampleTimingInfo sampleTime = {
        .presentationTimeStamp  = presentationTimeStamp,
        .decodeTimeStamp        = presentationTimeStamp
    };
    
    //根据解码后的图像数据构建samplebuffer数据类型，用于渲染
    CMSampleBufferRef samplebuffer = [decoder createSampleBufferFromPixelbuffer:pixelBuffer
                                                                    videoRotate:sourceRef->rotate
                                                                     timingInfo:sampleTime];
    if (samplebuffer) {
        if ([decoder.delegate respondsToSelector:@selector(getVideoDecodeDataCallback:isFirstFrame:)]) {
            [decoder.delegate getVideoDecodeDataCallback:samplebuffer isFirstFrame:decoder->_isFirstFrame];
            if (decoder->_isFirstFrame) {
                decoder->_isFirstFrame = NO;
            }
        }
        CFRelease(samplebuffer);
    }
    
    if (sourceRef) {
        free(sourceRef);
    }
}

#pragma mark - life cycle
//类初始化操作
- (instancetype)init {
    if (self = [super init]) {
        _decoderInfo = {
            .vps = NULL, .sps = NULL, .f_pps = NULL, .r_pps = NULL,
            .vps_size = 0, .sps_size = 0, .f_pps_size = 0, .r_pps_size = 0, .last_decode_pts = 0,
        };
        _isFirstFrame = YES;
        pthread_mutex_init(&_decoder_lock, NULL);
    }
    return self;
}

//销毁解码器资源
- (void)dealloc {
    _delegate = nil;
    [self destoryDecoder];
}

#pragma mark - Public
- (void)startDecodeVideoData:(XDXParseVideoDataInfo *)videoInfo {
    // get extra data
    if (videoInfo->extraData && videoInfo->extraDataSize) {//视频解码器的扩展信息
        uint8_t *extraData = videoInfo->extraData;
        int     size       = videoInfo->extraDataSize;
        
        BOOL isNeedUpdate = [self isNeedUpdateExtraDataWithNewExtraData:extraData
                                                                newSize:size
                                                               lastData:&_lastExtraData
                                                               lastSize:&_lastExtraDataSize];
        if (isNeedUpdate) {
            log4cplus_info(kModuleName, "%s: update extra data",__func__);
            [self getNALUInfoWithVideoFormat:videoInfo->videoFormat
                                   extraData:extraData
                               extraDataSize:size
                                 decoderInfo:&_decoderInfo];//提取sps,pps,vps等信息
        }
    }
    
    // create decoder
    if (!_decoderSession) {//创建解码器
        _decoderSession = [self createDecoderWithVideoInfo:videoInfo
                                              videoDescRef:&_decoderFormatDescription
                                               videoFormat:kCVPixelFormatType_420YpCbCr8BiPlanarFullRange//等同于NV12
                                                      lock:_decoder_lock
                                                  callback:VideoDecoderCallback
                                               decoderInfo:_decoderInfo];
    }
    
    pthread_mutex_lock(&_decoder_lock);
    if (!_decoderSession) {
        log4cplus_error(kModuleName, "%s: _decoderSession is NULL",__func__);
        pthread_mutex_unlock(&_decoder_lock);
        return;
    }
    
    /*  If open B frame, the code will not be used.
    if(_decoderInfo.last_decode_pts != 0 && videoInfo->pts <= _decoderInfo.last_decode_pts){
        log4cplus_error(kModuleName, "decode timestamp error ! current:%f, last:%f",videoInfo->pts, _decoderInfo.last_decode_pts);
        pthread_mutex_unlock(&_decoder_lock);
        return;
    }
     */
    
    _decoderInfo.last_decode_pts = videoInfo->pts;
    
    pthread_mutex_unlock(&_decoder_lock);
    
    // start decode
    [self startDecode:videoInfo
              session:_decoderSession
                 lock:_decoder_lock];//开始解码
}

- (void)stopDecoder {
    [self destoryDecoder];
}

#pragma mark - private methods

#pragma mark Create / Destory decoder
- (VTDecompressionSessionRef)createDecoderWithVideoInfo:(XDXParseVideoDataInfo *)videoInfo videoDescRef:(CMVideoFormatDescriptionRef *)videoDescRef videoFormat:(OSType)videoFormat lock:(pthread_mutex_t)lock callback:(VTDecompressionOutputCallback)callback decoderInfo:(XDXDecoderInfo)decoderInfo {
    pthread_mutex_lock(&lock);
    
    OSStatus status;
    if (videoInfo->videoFormat == XDXH264EncodeFormat) {
        const uint8_t *const parameterSetPointers[2] = {decoderInfo.sps, decoderInfo.f_pps};
        const size_t parameterSetSizes[2] = {static_cast<size_t>(decoderInfo.sps_size), static_cast<size_t>(decoderInfo.f_pps_size)};
        status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                     2,
                                                                     parameterSetPointers,
                                                                     parameterSetSizes,
                                                                     4,
                                                                     videoDescRef);
    }else if (videoInfo->videoFormat == XDXH265EncodeFormat) {
        if (decoderInfo.r_pps_size == 0) {
            const uint8_t *const parameterSetPointers[3] = {decoderInfo.vps, decoderInfo.sps, decoderInfo.f_pps};
            const size_t parameterSetSizes[3] = {static_cast<size_t>(decoderInfo.vps_size), static_cast<size_t>(decoderInfo.sps_size), static_cast<size_t>(decoderInfo.f_pps_size)};
            if (@available(iOS 11.0, *)) {
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                             3,
                                                                             parameterSetPointers,
                                                                             parameterSetSizes,
                                                                             4,
                                                                             NULL,
                                                                             videoDescRef);
            } else {
                status = -1;
                log4cplus_error(kModuleName, "%s: System version is too low!",__func__);
            }
        } else {
            const uint8_t *const parameterSetPointers[4] = {decoderInfo.vps, decoderInfo.sps, decoderInfo.f_pps, decoderInfo.r_pps};
            const size_t parameterSetSizes[4] = {static_cast<size_t>(decoderInfo.vps_size), static_cast<size_t>(decoderInfo.sps_size), static_cast<size_t>(decoderInfo.f_pps_size), static_cast<size_t>(decoderInfo.r_pps_size)};
            if (@available(iOS 11.0, *)) {
                status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                                                                             4,
                                                                             parameterSetPointers,
                                                                             parameterSetSizes,
                                                                             4,
                                                                             NULL,
                                                                             videoDescRef);
            } else {
                status = -1;
                log4cplus_error(kModuleName, "%s: System version is too low!",__func__);
            }
        }
    }else {
        status = -1;
    }
    
    if (status != noErr) {
        log4cplus_error(kModuleName, "%s: NALU header error !",__func__);
        pthread_mutex_unlock(&lock);
        [self destoryDecoder];
        return NULL;
    }
    
    uint32_t pixelFormatType = videoFormat;
    const void *keys[]       = {kCVPixelBufferPixelFormatTypeKey};
    const void *values[]     = {CFNumberCreate(NULL, kCFNumberSInt32Type, &pixelFormatType)};
    CFDictionaryRef attrs    = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
    
    VTDecompressionOutputCallbackRecord callBackRecord;
    callBackRecord.decompressionOutputCallback = callback;
    callBackRecord.decompressionOutputRefCon   = (__bridge void *)self;
    
    VTDecompressionSessionRef session;
    status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                          *videoDescRef,
                                          NULL,
                                          attrs,
                                          &callBackRecord,
                                          &session);//创建解码器
    
    CFRelease(attrs);
    pthread_mutex_unlock(&lock);
    if (status != noErr) {
        log4cplus_error(kModuleName, "%s: Create decoder failed",__func__);
        [self destoryDecoder];
        return NULL;
    }
    return session;
}

//销毁解码器的相关资源
- (void)destoryDecoder {
    pthread_mutex_lock(&_decoder_lock);
    
    if (_decoderInfo.vps) {//vps
        free(_decoderInfo.vps);
        _decoderInfo.vps_size = 0;
        _decoderInfo.vps = NULL;
    }
    
    if (_decoderInfo.sps) {//sps
        free(_decoderInfo.sps);
        _decoderInfo.sps_size = 0;
        _decoderInfo.sps = NULL;
    }
    
    if (_decoderInfo.f_pps) {//pps
        free(_decoderInfo.f_pps);
        _decoderInfo.f_pps_size = 0;
        _decoderInfo.f_pps = NULL;
    }
    
    if (_decoderInfo.r_pps) {//pps
        free(_decoderInfo.r_pps);
        _decoderInfo.r_pps_size = 0;
        _decoderInfo.r_pps = NULL;
    }
    
    if (_lastExtraData) {//视频解码器扩展信息
        free(_lastExtraData);
        _lastExtraDataSize = 0;
        _lastExtraData = NULL;
    }
    
    if (_decoderSession) {//解码器实例
        VTDecompressionSessionWaitForAsynchronousFrames(_decoderSession);
        VTDecompressionSessionInvalidate(_decoderSession);
        CFRelease(_decoderSession);
        _decoderSession = NULL;
    }
    
    if (_decoderFormatDescription) {//视频解码器格式描述信息
        CFRelease(_decoderFormatDescription);
        _decoderFormatDescription = NULL;
    }
    pthread_mutex_unlock(&_decoder_lock);
}

//判断是否需要更新extraData数据给到解码器
- (BOOL)isNeedUpdateExtraDataWithNewExtraData:(uint8_t *)newData newSize:(int)newSize lastData:(uint8_t **)lastData lastSize:(int *)lastSize {
    BOOL isNeedUpdate = NO;
    if (*lastSize == 0) {
        isNeedUpdate = YES;
    }else {
        if (*lastSize != newSize) {
            isNeedUpdate = YES;
        }else {
            if (memcmp(newData, *lastData, newSize) != 0) {//比较存放内存的值是否相同
                isNeedUpdate = YES;
            }
        }
    }
    
    if (isNeedUpdate) {
        [self destoryDecoder];//销毁解码器
        
        //使用新的视频解码器扩展信息
        *lastData = (uint8_t *)malloc(newSize);
        memcpy(*lastData, newData, newSize);
        *lastSize = newSize;
    }
    return isNeedUpdate;
}

#pragma mark Parse NALU Header
- (void)copyDataWithOriginDataRef:(uint8_t **)originDataRef newData:(uint8_t *)newData size:(int)size {
    if (*originDataRef) {
        free(*originDataRef);
        *originDataRef = NULL;
    }
    *originDataRef = (uint8_t *)malloc(size);
    memcpy(*originDataRef, newData, size);
}

//在extradata中提取vps,sps,pps等信息
- (void)getNALUInfoWithVideoFormat:(XDXVideoEncodeFormat)videoFormat extraData:(uint8_t *)extraData extraDataSize:(int)extraDataSize decoderInfo:(XDXDecoderInfo *)decoderInfo {

    uint8_t *data = extraData;
    int      size = extraDataSize;
    
    int startCodeVPSIndex  = 0;
    int startCodeSPSIndex  = 0;
    int startCodeFPPSIndex = 0;
    int startCodeRPPSIndex = 0;
    int nalu_type = 0;
    
    for (int i = 0; i < size; i ++) {
        if (i >= 3) {
            if ((data[i] == 0x01) && (data[i - 1] == 0x00) && (data[i - 2] == 0x00) && (data[i - 3] == 0x00)) {
                if (videoFormat == XDXH264EncodeFormat) {
                    if (startCodeSPSIndex == 0) {//首先找到SPS，记录索引
                        startCodeSPSIndex = i;
                    }
                    if (i > startCodeSPSIndex) {//PPS
                        startCodeFPPSIndex = i;
                    }
                } else if (videoFormat == XDXH265EncodeFormat) {
                    if (startCodeVPSIndex == 0) {//首先找到VPS，记录索引
                        startCodeVPSIndex = i;
                        continue;
                    }
                    if ((i > startCodeVPSIndex) && (startCodeSPSIndex == 0)) {//SPS
                        startCodeSPSIndex = i;
                        continue;
                    }
                    if ((i > startCodeSPSIndex) && (startCodeFPPSIndex == 0)) {//第一个PPS
                        startCodeFPPSIndex = i;
                        continue;
                    }
                    if ((i > startCodeFPPSIndex) && (startCodeRPPSIndex == 0)) {//第二个PPS
                        startCodeRPPSIndex = i;
                    }
                }
            }
        }
    }
    
    int spsSize = startCodeFPPSIndex - startCodeSPSIndex - 4;
    decoderInfo->sps_size = spsSize;
    
    if (videoFormat == XDXH264EncodeFormat) {
        int f_ppsSize = size - (startCodeFPPSIndex + 1);
        decoderInfo->f_pps_size = f_ppsSize;
        
        nalu_type = ((uint8_t)data[startCodeSPSIndex + 1] & 0x1F);//取低5位
        if (nalu_type == 0x07) {//sps
            uint8_t *sps = &data[startCodeSPSIndex + 1];
            [self copyDataWithOriginDataRef:&decoderInfo->sps newData:sps size:spsSize];//拷贝sps
        }
        
        nalu_type = ((uint8_t)data[startCodeFPPSIndex + 1] & 0x1F);
        if (nalu_type == 0x08) {//pps
            uint8_t *pps = &data[startCodeFPPSIndex + 1];
            [self copyDataWithOriginDataRef:&decoderInfo->f_pps newData:pps size:f_ppsSize];//拷贝pps
        }
    } else {
        int vpsSize = startCodeSPSIndex - startCodeVPSIndex - 4;
        decoderInfo->vps_size = vpsSize;
        
        int f_ppsSize = 0;
        if (startCodeRPPSIndex != 0) {
            f_ppsSize = startCodeRPPSIndex - startCodeFPPSIndex - 4;
            decoderInfo->f_pps_size = f_ppsSize;
        }else {
            f_ppsSize = size - (startCodeFPPSIndex + 1);
            decoderInfo->f_pps_size = f_ppsSize;
        }
        
        nalu_type = ((uint8_t) data[startCodeVPSIndex + 1] & 0x4F);
        if (nalu_type == 0x40) {//vps
            uint8_t *vps = &data[startCodeVPSIndex + 1];
            [self copyDataWithOriginDataRef:&decoderInfo->vps newData:vps size:vpsSize];
        }
        
        nalu_type = ((uint8_t) data[startCodeSPSIndex + 1] & 0x4F);
        if (nalu_type == 0x42) {//sps
            uint8_t *sps = &data[startCodeSPSIndex + 1];
            [self copyDataWithOriginDataRef:&decoderInfo->sps newData:sps size:spsSize];
        }
        
        nalu_type = ((uint8_t) data[startCodeFPPSIndex + 1] & 0x4F);
        if (nalu_type == 0x44) {//pps
            uint8_t *pps = &data[startCodeFPPSIndex + 1];
            [self copyDataWithOriginDataRef:&decoderInfo->f_pps newData:pps size:f_ppsSize];
        }
        
        if (startCodeRPPSIndex == 0) {
            return;
        }
        
        int r_ppsSize = size - (startCodeRPPSIndex + 1);
        decoderInfo->r_pps_size = r_ppsSize;
        
        nalu_type = ((uint8_t) data[startCodeRPPSIndex + 1] & 0x4F);
        if (nalu_type == 0x44) {
            uint8_t *pps = &data[startCodeRPPSIndex + 1];
            [self copyDataWithOriginDataRef:&decoderInfo->r_pps newData:pps size:r_ppsSize];
        }
    }
}

#pragma mark Decode
- (void)startDecode:(XDXParseVideoDataInfo *)videoInfo session:(VTDecompressionSessionRef)session lock:(pthread_mutex_t)lock {
    pthread_mutex_lock(&lock);
    uint8_t *data  = videoInfo->data;
    int     size   = videoInfo->dataSize;
    int     rotate = videoInfo->videoRotate;
    CMSampleTimingInfo timingInfo = videoInfo->timingInfo;
//    log4cplus_info(kModuleName, "%s: start decode data size: %d",__func__, size);
    
    uint8_t *tempData = (uint8_t *)malloc(size);
    memcpy(tempData, data, size);

    XDXDecodeVideoInfo *sourceRef = (XDXDecodeVideoInfo *)malloc(sizeof(XDXDecodeVideoInfo));
    sourceRef->outputPixelbuffer  = NULL;
    sourceRef->rotate             = rotate;//视频角度
    sourceRef->pts                = videoInfo->pts;//显示时间戳
    sourceRef->fps                = videoInfo->fps;//帧率
    
    CMBlockBufferRef blockBuffer;
    OSStatus status = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault,
                                                         (void *)tempData,
                                                         size,
                                                         kCFAllocatorNull,
                                                         NULL,
                                                         0,
                                                         size,
                                                         0,
                                                         &blockBuffer);//构建一个blockBuffer
    
    if (status == kCMBlockBufferNoErr) {
        CMSampleBufferRef sampleBuffer = NULL;
        const size_t sampleSizeArray[] = { static_cast<size_t>(size) };
        
        status = CMSampleBufferCreateReady(kCFAllocatorDefault,
                                           blockBuffer,
                                           _decoderFormatDescription,
                                           1,
                                           1,
                                           &timingInfo,
                                           1,
                                           sampleSizeArray,
                                           &sampleBuffer);//blockBuffer再构建成一个sampleBuffer
        
        if (status == kCMBlockBufferNoErr && sampleBuffer) {
            VTDecodeFrameFlags flags   = kVTDecodeFrame_EnableAsynchronousDecompression;//异步模式
            VTDecodeInfoFlags  flagOut = 0;
            OSStatus decodeStatus      = VTDecompressionSessionDecodeFrame(session,
                                                                           sampleBuffer,
                                                                           flags,//解码模式
                                                                           sourceRef,
                                                                           &flagOut);//开始解码
            if(decodeStatus == kVTInvalidSessionErr) {
                pthread_mutex_unlock(&lock);
                [self destoryDecoder];
                if (blockBuffer)
                    CFRelease(blockBuffer);
                free(tempData);
                tempData = NULL;
                CFRelease(sampleBuffer);
                return;
            }
            CFRelease(sampleBuffer);
        }
    }
    
    if (blockBuffer) {
        CFRelease(blockBuffer);
    }
    
    free(tempData);
    tempData = NULL;
    pthread_mutex_unlock(&lock);
}

#pragma mark - Other
- (CMSampleBufferRef)createSampleBufferFromPixelbuffer:(CVImageBufferRef)pixelBuffer videoRotate:(int)videoRotate timingInfo:(CMSampleTimingInfo)timingInfo {
    if (!pixelBuffer) {
        return NULL;
    }
    
    CVPixelBufferRef final_pixelbuffer = pixelBuffer;
    CMSampleBufferRef samplebuffer = NULL;
    CMVideoFormatDescriptionRef videoInfo = NULL;
    OSStatus status = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, final_pixelbuffer, &videoInfo);
    status = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, final_pixelbuffer, true, NULL, NULL, videoInfo, &timingInfo, &samplebuffer);
    
    if (videoInfo != NULL) {
        CFRelease(videoInfo);
    }
    
    if (samplebuffer == NULL || status != noErr) {
        return NULL;
    }
    return samplebuffer;
}

- (void)resetTimestamp {
    _decoderInfo.last_decode_pts = 0;
}

@end
