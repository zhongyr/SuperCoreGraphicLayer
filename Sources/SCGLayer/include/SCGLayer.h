#import <QuartzCore/QuartzCore.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const SCGLayerErrorDomain;
typedef NS_ERROR_ENUM(SCGLayerErrorDomain, SCGLayerError) {
  SCGLayerErrorUnavailable = 1,
  SCGLayerErrorInvalidGeometry,
  SCGLayerErrorRenderingFailed,
  SCGLayerErrorWrongThread,
};

/// The context uses points with a top-left origin. It is valid only during this call.
typedef void (^SCGDrawingBlock)(CGContextRef context, CGRect bounds);

/// Experimental CoreGraphics drawing into a bounded IOSurface pool.
/// Uses private APIs. Not suitable for an App Store submission using public APIs only.
/// Configure, invalidate, and render on the main thread. Set contentsScale explicitly.
@interface SCGLayer : CALayer

/// Symbol availability only: neither successful context creation nor GPU acceleration is guaranteed.
@property(class, nonatomic, readonly) BOOL contextAPIAvailable;

/// Setting the block invalidates the layer. Avoid strongly capturing the layer or its owner.
/// If nil, rendering calls -drawInContext: so subclasses can supply their drawing there.
@property(nonatomic, copy, nullable) SCGDrawingBlock drawingBlock;
@property(nonatomic, strong, readonly, nullable) NSError *lastRenderError;
@property(nonatomic, readonly) NSUInteger renderedFrameCount;
@property(nonatomic, readonly) NSUInteger droppedFrameCount;
@property(nonatomic, readonly) NSUInteger surfaceCount;
@property(nonatomic, readonly) size_t ownedSurfaceBytes;

/// Draw immediately instead of waiting for Core Animation's display pass.
/// A successful return submits contents; it is not a GPU completion/presentation fence.
/// Failures keep the previous contents except when a resize retires the old backing.
/// No bitmap fallback. Each dimension is limited to 4096 physical pixels.
- (BOOL)renderWithError:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
