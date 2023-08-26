#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/*
 渲染的View类
 */
@interface XDXPreviewView : UIView

/**
 Whether full the screen
 */
@property (nonatomic, assign, getter=isFullScreen) BOOL fullScreen;//是否全屏渲染变量

/**
 display
 */
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;//传入渲染的图像数据进行渲染

@end

NS_ASSUME_NONNULL_END
