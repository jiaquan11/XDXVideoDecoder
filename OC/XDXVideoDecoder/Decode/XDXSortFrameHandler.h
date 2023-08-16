#import <Foundation/Foundation.h>
#import "XDXAVParseHandler.h"

NS_ASSUME_NONNULL_BEGIN

@protocol XDXSortFrameHandlerDelegate <NSObject>

@optional
- (void)getSortedVideoNode:(CMSampleBufferRef)videoDataRef;

@end

@interface XDXSortFrameHandler : NSObject

@property (weak  , nonatomic) id<XDXSortFrameHandlerDelegate> delegate;

- (void)addDataToLinkList:(CMSampleBufferRef)videoDataRef;
- (void)cleanLinkList;

@end

NS_ASSUME_NONNULL_END
