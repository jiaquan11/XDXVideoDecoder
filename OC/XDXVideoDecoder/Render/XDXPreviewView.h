#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface XDXPreviewView : UIView

/**
 Whether full the screen
 */
@property (nonatomic, assign, getter=isFullScreen) BOOL fullScreen;

/**
 display
 */
- (void)displayPixelBuffer:(CVPixelBufferRef)pixelBuffer;

@end

NS_ASSUME_NONNULL_END
