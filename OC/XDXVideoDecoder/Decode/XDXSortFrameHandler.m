#import "XDXSortFrameHandler.h"

const static int g_maxSize = 4;//最多只排序四个图像数据，应该是有问题的(某些带B帧视频的最大B帧数不只4帧)

//排序数组
struct XDXSortLinkList {
    CMSampleBufferRef dataArray[g_maxSize];
    int index;
};

typedef struct XDXSortLinkList XDXSortLinkList;

@interface XDXSortFrameHandler ()
{
    XDXSortLinkList _sortLinkList;
}

@end

@implementation XDXSortFrameHandler

#pragma mark - Lifecycle

//初始化操作
- (instancetype)init {
    if (self = [super init]) {
        XDXSortLinkList linkList = {
            .index = 0,
            .dataArray = {0},
        };
        
        _sortLinkList = linkList;
    }
    return self;
}

#pragma mark - Public
//添加需要排序的CMSampleBufferRef图像数据到排序数组中
- (void)addDataToLinkList:(CMSampleBufferRef)sampleBufferRef {
    CFRetain(sampleBufferRef);//添加计数引用
    _sortLinkList.dataArray[_sortLinkList.index] = sampleBufferRef;//先加入链表数组
    _sortLinkList.index++;
    
    //当数组满了，才进行排序，并通过代理获取一次性全部输出
    if (_sortLinkList.index == g_maxSize) {
        _sortLinkList.index = 0;
        
        // sort
        [self selectSortWithLinkList:&_sortLinkList];//选择排序，对链表数组中的数据根据时间戳大小重新排序
        
        for (int i = 0; i < g_maxSize; i++) {
            if ([self.delegate respondsToSelector:@selector(getSortedVideoNode:)]) {//相当于Android中的监听器，监听到有数据就回调
                [self.delegate getSortedVideoNode:_sortLinkList.dataArray[i]];//获取排序好的图像数据
                CFRelease(_sortLinkList.dataArray[i]);//释放图像数据
                _sortLinkList.dataArray[i] = NULL;
            }
        }
    }
}

//销毁链表数组
- (void)cleanLinkList {
    _sortLinkList.index = 0;
    for (int i = 0; i < g_maxSize; i++) {
        if (CMSampleBufferIsValid(_sortLinkList.dataArray[i])) {
            CFRelease(_sortLinkList.dataArray[i]);
        }
        _sortLinkList.dataArray[i] = NULL;
    }
}

#pragma mark - Private
//选择排序算法：根据显示时间戳大小进行排序
- (void)selectSortWithLinkList:(XDXSortLinkList *)sortLinkList {
    for (int i = 0; i < g_maxSize; i++) {
        int64_t minPTS = i;
        for (int j = i + 1; j < g_maxSize; j++) {
            if ([self getPTS:sortLinkList->dataArray[j]] < [self getPTS:sortLinkList->dataArray[minPTS]]) {
                minPTS = j;//遍历找到数组中最小的时间戳
            }
        }
        
        //找到新的最小时间戳，则进行交换位置赋值
        if (i != minPTS) {
            void *tmp = sortLinkList->dataArray[i];
            sortLinkList->dataArray[i] = sortLinkList->dataArray[minPTS];
            sortLinkList->dataArray[minPTS] = tmp;
        }
    }
}

//获取图像数据包的显示时间戳
- (int64_t)getPTS:(CMSampleBufferRef)sampleBufferRef {
    int64_t pts = (int64_t)(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBufferRef)) * 1000);
    return pts;
}
@end


