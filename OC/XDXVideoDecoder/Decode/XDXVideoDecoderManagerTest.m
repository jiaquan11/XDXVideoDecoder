
#import "XDXVideoDecoderManagerTest.h"
#import "XDXVideoDecoder.h"
#include "log4cplus.h"
#define kModuleName "XDXVideoDecoderManagerTest"

@interface XDXVideoDecoderManagerTest()<XDXVideoDecoderDelegate>
@property (strong, nonatomic) XDXVideoDecoder *decoder;
@end

@implementation XDXVideoDecoderManagerTest
- (void)startDecodeByVTSessionWithIsH265NakedData:(NSString*)path{
    self.decoder = [[XDXVideoDecoder alloc] init];
    self.decoder.delegate = self;
    
    NSInputStream* inputStream = [NSInputStream inputStreamWithFileAtPath:path];
    NSData *data = [self getBytesFromInputStream:inputStream];
    if (!data || (data.length == 0)) {
        return;
    }
    log4cplus_info(kModuleName, "%s: data length: %d", __func__, data.length);
    
    int FIX_EXTRADATA_SIZE = 87;
    int FPS = 30;
    int startIndex = FIX_EXTRADATA_SIZE;
    int nextFrameStart = -1;
    
    Float64 current_timestamp = [self getCurrentTimestamp];
    
    struct XDXParseVideoDataInfo videoParseInfo = {0};
    videoParseInfo.videoFormat = XDXH265EncodeFormat;
    videoParseInfo.videoRotate = 0;
    videoParseInfo.extraDataSize = FIX_EXTRADATA_SIZE;
    videoParseInfo.extraData = (uint8_t *)malloc(videoParseInfo.extraDataSize);
    memcpy(videoParseInfo.extraData, data.bytes, videoParseInfo.extraDataSize);
    
    nextFrameStart = [self findByFrame:data start:startIndex+1 totalSize:data.length];
    uint8_t* video_data = (uint8_t*)malloc(nextFrameStart - startIndex);
    uint32_t big_endian_length = CFSwapInt32HostToBig(nextFrameStart - startIndex - 4);
    log4cplus_info(kModuleName, "%s: big_endian_length: %d", __func__, big_endian_length);
    memcpy(video_data, &big_endian_length, sizeof(big_endian_length));
    
    memcpy(video_data + 4, data.bytes + startIndex + 4, nextFrameStart - startIndex - 4);
    
    videoParseInfo.data = video_data;
    videoParseInfo.dataSize = (nextFrameStart - startIndex);
    
    CMSampleTimingInfo timingInfo;
    CMTime presentationTimeStamp     = kCMTimeInvalid;
    presentationTimeStamp            = CMTimeMakeWithSeconds(current_timestamp, FPS);
    timingInfo.presentationTimeStamp = presentationTimeStamp;
    timingInfo.decodeTimeStamp       = CMTimeMakeWithSeconds(current_timestamp, FPS);
    videoParseInfo.timingInfo        = timingInfo;
    
    [self.decoder startDecodeVideoData:&videoParseInfo];
    
    free(videoParseInfo.data);
    free(videoParseInfo.extraData);
    
    
     bool isDecodeSuccess = [self.decoder getDecoderStatus];
     if (isDecodeSuccess) {
         NSLog(@"VideoDecoderManagerTest decode success");
     } else {
         NSLog(@"VideoDecoderManagerTest decode failed");
     }
}

- (NSInteger) findByFrame:(NSData *)data start:(NSInteger)start totalSize:(NSInteger)totalSize {
    const uint8_t* bytes = data.bytes;
    for (NSInteger i = start; i < totalSize - 4; i++) {
        if ((bytes[i] == 0x00) && (bytes[i + 1] == 0x00) && (bytes[i + 2] == 0x00) && (bytes[i + 3] == 0x01)) {
            return i;
        }
    }
    return -1;
}

- (NSData *)getBytesFromInputStream:(NSInputStream *)inputStream {
    if (!inputStream) {
        return nil;
    }
    
    NSMutableData *data = [NSMutableData data];
    uint8_t buffer[8192]; // 8KB 缓冲区大小
    NSInteger bytesRead;
    
    [inputStream open];
    while ((bytesRead = [inputStream read:buffer maxLength:sizeof(buffer)]) > 0) {
        [data appendBytes:buffer length:bytesRead];
    }
    [inputStream close];
    return data;
}

//获取系统时间戳
- (Float64)getCurrentTimestamp {
    CMClockRef hostClockRef = CMClockGetHostTimeClock();
    CMTime hostTime = CMClockGetTime(hostClockRef);
    return CMTimeGetSeconds(hostTime);
}

- (void)getVideoDecodeDataCallback:(CMSampleBufferRef)sampleBuffer isFirstFrame:(BOOL)isFirstFrame {
    NSLog(@"getVideoDecodeDataCallback isFirstFrame: %d", isFirstFrame);
}

@end
