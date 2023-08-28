#import "ViewController.h"
#import "XDXAVParseHandler.h"
#import "XDXPreviewView.h"
#import "XDXVideoDecoder.h"
#import "XDXFFmpegVideoDecoder.h"
#import "XDXSortFrameHandler.h"

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

#define kModuleName "ViewController"

//ViewController同时作为XDXVideoDecoderDelegate，XDXFFmpegVideoDecoderDelegate，XDXSortFrameHandlerDelegate的协议代理，用于接收其相关操作数据
@interface ViewController ()<XDXVideoDecoderDelegate,XDXFFmpegVideoDecoderDelegate, XDXSortFrameHandlerDelegate>

//类属性变量
@property (strong, nonatomic) XDXPreviewView    *previewView;
@property (weak, nonatomic  ) IBOutlet UIButton *startBtn;

@property (nonatomic, assign) BOOL isH265File;
@property (strong, nonatomic) XDXSortFrameHandler *sortHandler;

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupUI];
    
    self.isH265File = YES;//播放H265的视频文件
    
    self.sortHandler = [[XDXSortFrameHandler alloc] init];//分配渲染帧排序的类实例
    self.sortHandler.delegate = self;//设置ViewController作为XDXSortFrameHandler的代理，
}

//加载渲染控件。这里的view为UIViewController那边的UIView
- (void)setupUI {
    self.previewView = [[XDXPreviewView alloc] initWithFrame:self.view.frame];//创建渲染类实例
    [self.view addSubview:self.previewView];//加载渲染控件到UIView上
    [self.view bringSubviewToFront:self.startBtn];//添加点击按钮到UIView上
}

//点击播放按钮的响应函数 开始解析媒体文件
- (IBAction)startParseDidClicked:(id)sender {
    BOOL isUseFFmpeg = NO;
    if (isUseFFmpeg) {
        log4cplus_info(kModuleName, "use FFmpeg!");
        [self startDecodeByFFmpegWithIsH265Data:self.isH265File];//使用ffmpeg接口进行软解码
    }else {
        log4cplus_info(kModuleName, "use VideoToolbox!");
        [self startDecodeByVTSessionWithIsH265Data:self.isH265File];//使用硬件VideoToolbox接口进行硬解码
    }
}

- (void)startDecodeByFFmpegWithIsH265Data:(BOOL)isH265 {
    NSString *path = [[NSBundle mainBundle] pathForResource:isH265 ? @"testh265" : @"testh264" ofType:@"MOV"];
    XDXAVParseHandler *parseHandler = [[XDXAVParseHandler alloc] initWithPath:path];//创建ffmpeg解析器
    XDXFFmpegVideoDecoder *decoder = [[XDXFFmpegVideoDecoder alloc] initWithFormatContext:[parseHandler getFormatContext] videoStreamIndex:[parseHandler getVideoStreamIndex]];//创建ffmpeg解码器
    decoder.delegate = self;//设置ffmpeg解码器的代理
    
    [parseHandler startParseGetAVPackeWithCompletionHandler:^(BOOL isVideoFrame, BOOL isFinish, AVPacket packet) {
        if (isFinish) {//结束解码
            [decoder stopDecoder];
            return;
        }
        
        if (isVideoFrame) {
            [decoder startDecodeVideoDataWithAVPacket:packet];//丢给ffmpeg解码器解码Packet数据
        }
    }];
}

- (void)startDecodeByVTSessionWithIsH265Data:(BOOL)isH265 {
    NSString *path = [[NSBundle mainBundle] pathForResource:isH265 ? @"test30frames_1080p_ld2" : @"testh264"  ofType:@"mp4"];
    XDXAVParseHandler *parseHandler = [[XDXAVParseHandler alloc] initWithPath:path];//创建ffmpeg解析器
    XDXVideoDecoder *decoder = [[XDXVideoDecoder alloc] init];//创建VideoToolbox硬件解码器
    decoder.delegate = self;//设置VideoToolbox解码器的代理
    
    [parseHandler startParseWithCompletionHandler:^(BOOL isVideoFrame, BOOL isFinish, struct XDXParseVideoDataInfo *videoInfo, struct XDXParseAudioDataInfo *audioInfo) {
        if (isFinish) {//结束解码
            [decoder stopDecoder];
            return;
        }
        
        if (isVideoFrame) {
//            log4cplus_info(kModuleName, "%s: controller data size:%d", __func__, videoInfo->dataSize);
            [decoder startDecodeVideoData:videoInfo];//硬件解码
        }
    }];
}

#pragma mark - Decode Callback
//ffmpeg解码图像回调，用于后续渲染
-(void)getDecodeVideoDataByFFmpeg:(CMSampleBufferRef)sampleBuffer {
    CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sampleBuffer);
    [self.previewView displayPixelBuffer:pix];
}

//VideoToolbox硬解图像回调，用于后续渲染
- (void)getVideoDecodeDataCallback:(CMSampleBufferRef)sampleBuffer isFirstFrame:(BOOL)isFirstFrame {
    if (self.isH265File) {//目前提供的H265视频文件带B帧，所以进行渲染排序（其实默认所有视频文件走排序也是可以的，不用区分）
        // Note : the first frame not need to sort.
        if (isFirstFrame) {//首帧直接渲染，不用排序
            [self.sortHandler cleanLinkList];
            CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sampleBuffer);
            [self.previewView displayPixelBuffer:pix];
            return;
        }
        
        [self.sortHandler addDataToLinkList:sampleBuffer];//加入排序数组，排序好再渲染
    }else {
        CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sampleBuffer);
        [self.previewView displayPixelBuffer:pix];
    }
}

//ViewController作为XDXSortFrameHandler的代理，需实现协议函数，作为回调函数，用于回调排序好的图像数据，用于渲染
#pragma mark - Sort Callback
- (void)getSortedVideoNode:(CMSampleBufferRef)sampleBuffer {
    int64_t pts = (int64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1000);
    static int64_t lastpts = 0;
    NSLog(@"Test marigin - %lld",pts - lastpts);//打印排序好的前后时间戳的时间间隔
    lastpts = pts;
    
    //获取到排序好的图像数据，然后丢给渲染器进行渲染
    CVPixelBufferRef pix = CMSampleBufferGetImageBuffer(sampleBuffer);
    [self.previewView displayPixelBuffer:pix];
}
@end
