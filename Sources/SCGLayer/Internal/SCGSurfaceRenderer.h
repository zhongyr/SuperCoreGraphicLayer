#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

// Private-SPI experiment. Owns bounded IOSurfaces, not a UIView backing store.
@interface SCGSurfaceRenderer : NSObject
@property(nonatomic, readonly) NSString *status;
@property(nonatomic, readonly) BOOL contextAPIAvailable;
@property(nonatomic, readonly) size_t allocatedBytes;
@property(nonatomic, readonly) NSUInteger bufferCount;
@property(nonatomic, readonly) NSUInteger droppedFrames;
- (instancetype)initWithPrivateAPIEnabled:(BOOL)enabled;
- (BOOL)renderSize:(CGSize)size
             scale:(CGFloat)scale
           toLayer:(CALayer *)layer
              draw:(void (^)(CGContextRef))draw;
// Flushes and reads back the last frame for validation only, outside timing.
- (NSData *)copyPixels;
- (CGSize)pixelSize;
@end
