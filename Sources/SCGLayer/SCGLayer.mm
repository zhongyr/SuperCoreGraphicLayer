#import "include/SCGLayer.h"
#import "Internal/SCGSurfaceRenderer.h"
#include <cmath>

#if !__has_feature(objc_arc)
#error SCGLayer requires Objective-C ARC
#endif

NSErrorDomain const SCGLayerErrorDomain = @"SCGLayerErrorDomain";

@interface SCGLayer ()
- (BOOL)renderFrameWithError:(NSError **)error;
@end

@implementation SCGLayer {
  SCGSurfaceRenderer *_renderer;
  NSError *_lastRenderError;
  NSUInteger _renderedFrameCount;
}
@synthesize drawingBlock = _drawingBlock;

+ (BOOL)contextAPIAvailable {
  return [[SCGSurfaceRenderer alloc] initWithPrivateAPIEnabled:YES].contextAPIAvailable;
}

- (instancetype)init {
  if ((self = [super init])) self.needsDisplayOnBoundsChange = YES;
  return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
  if ((self = [super initWithCoder:coder])) self.needsDisplayOnBoundsChange = YES;
  return self;
}

- (instancetype)initWithLayer:(id)layer {
  if ((self = [super initWithLayer:layer])) {
    if ([layer isKindOfClass:SCGLayer.class]) _drawingBlock = [((SCGLayer *)layer).drawingBlock copy];
    // Never share writable backing pools with Core Animation's layer copies.
  }
  return self;
}

- (void)setDrawingBlock:(SCGDrawingBlock)block {
  _drawingBlock = [block copy];
  [self setNeedsDisplay];
}

- (void)setContentsScale:(CGFloat)scale {
  CGFloat old = self.contentsScale;
  [super setContentsScale:scale];
  if (old != scale) [self setNeedsDisplay];
}

- (void)display {
  [self renderFrameWithError:nullptr];
}

- (BOOL)renderWithError:(NSError **)error {
  if (!NSThread.isMainThread) {
    if (error) *error = [NSError errorWithDomain:SCGLayerErrorDomain code:SCGLayerErrorWrongThread
                                      userInfo:@{NSLocalizedDescriptionKey: @"Render on the main thread"}];
    return NO;
  }
  // Let Core Animation clear the dirty flag, avoiding a second automatic draw
  // after an explicit render in the same transaction.
  [self setNeedsDisplay];
  [self displayIfNeeded];
  if (error) *error = _lastRenderError;
  return _lastRenderError == nil;
}

- (BOOL)renderFrameWithError:(NSError **)error {
  if (error) *error = nil;
  if (!NSThread.isMainThread) {
    if (error) *error = [NSError errorWithDomain:SCGLayerErrorDomain code:SCGLayerErrorWrongThread
                                      userInfo:@{NSLocalizedDescriptionKey: @"Render on the main thread"}];
    return NO;
  }
  CGRect bounds = self.bounds;
  CGFloat scale = self.contentsScale;
  NSError *failure = nil;
  if (!std::isfinite(bounds.origin.x) || !std::isfinite(bounds.origin.y) ||
      !std::isfinite(bounds.size.width) || !std::isfinite(bounds.size.height) ||
      !std::isfinite(scale) || scale <= 0 || bounds.size.width <= 0 || bounds.size.height <= 0 ||
      ceil(bounds.size.width * scale) > 4096 || ceil(bounds.size.height * scale) > 4096) {
    failure = [NSError errorWithDomain:SCGLayerErrorDomain code:SCGLayerErrorInvalidGeometry
                             userInfo:@{NSLocalizedDescriptionKey: @"Use finite, nonempty bounds and a positive scale; maximum 4096 pixels per dimension"}];
  } else {
    if (!_renderer) _renderer = [[SCGSurfaceRenderer alloc] initWithPrivateAPIEnabled:YES];
    if (!_renderer.contextAPIAvailable) {
      failure = [NSError errorWithDomain:SCGLayerErrorDomain code:SCGLayerErrorUnavailable
                               userInfo:@{NSLocalizedDescriptionKey: _renderer.status}];
    } else {
      BOOL rendered = [_renderer renderSize:bounds.size scale:scale toLayer:self draw:^(CGContextRef context) {
        CGContextTranslateCTM(context, -bounds.origin.x, -bounds.origin.y);
        if (self->_drawingBlock) self->_drawingBlock(context, bounds);
        else [self drawInContext:context];
      }];
      if (rendered) ++_renderedFrameCount;
      else failure = [NSError errorWithDomain:SCGLayerErrorDomain code:SCGLayerErrorRenderingFailed
                                    userInfo:@{NSLocalizedDescriptionKey: _renderer.status}];
    }
  }
  _lastRenderError = failure;
  if (error) *error = failure;
  return failure == nil;
}

- (NSError *)lastRenderError { return _lastRenderError; }
- (NSUInteger)renderedFrameCount { return _renderedFrameCount; }
- (NSUInteger)droppedFrameCount { return _renderer.droppedFrames; }
- (NSUInteger)surfaceCount { return _renderer.bufferCount; }
- (size_t)ownedSurfaceBytes { return _renderer.allocatedBytes; }
@end
