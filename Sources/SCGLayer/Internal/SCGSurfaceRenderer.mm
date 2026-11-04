#import "SCGSurfaceRenderer.h"

#import <IOSurface/IOSurfaceRef.h>
#include <dlfcn.h>
#include <cmath>
#include <cstring>
#include <memory>
#include <vector>

// Signatures: WebKit Source/WebCore/PAL/pal/spi/cg/CoreGraphicsSPI.h.
using CreateContext = CGContextRef (*)(IOSurfaceRef, size_t, size_t, size_t, size_t,
                                       CGColorSpaceRef, CGBitmapInfo, CFDictionaryRef);
using CreateLegacyContext = CGContextRef (*)(IOSurfaceRef, size_t, size_t, size_t, size_t,
                                             CGColorSpaceRef, CGBitmapInfo);

namespace {
struct Buffer {
  IOSurfaceRef surface = nullptr;
  CGContextRef context = nullptr;
  ~Buffer() {
    if (context) CGContextRelease(context);
    if (surface) CFRelease(surface);
  }
};
}  // namespace

@implementation SCGSurfaceRenderer {
  CreateContext _create;
  CreateLegacyContext _createLegacy;
  std::vector<std::unique_ptr<Buffer>> _buffers;
  Buffer *_front;
  size_t _width, _height;
  CGFloat _scale;
}

- (instancetype)initWithPrivateAPIEnabled:(BOOL)enabled {
  if ((self = [super init])) {
    if (enabled) {
      _create = reinterpret_cast<CreateContext>(
          dlsym(RTLD_DEFAULT, "CGIOSurfaceContextCreateWithOptions"));
      _createLegacy =
          reinterpret_cast<CreateLegacyContext>(dlsym(RTLD_DEFAULT, "CGIOSurfaceContextCreate"));
    }
    _status = _create         ? @"CGIOSurfaceContextCreateWithOptions"
              : _createLegacy ? @"CGIOSurfaceContextCreate"
                              : @"Private CGContext unavailable (no fallback)";
  }
  return self;
}

- (BOOL)contextAPIAvailable { return _create || _createLegacy; }

- (size_t)allocatedBytes {
  size_t bytes = 0;
  for (auto &buffer : _buffers) bytes += IOSurfaceGetAllocSize(buffer->surface);
  return bytes;
}

- (NSUInteger)bufferCount {
  return _buffers.size();
}

- (BOOL)renderSize:(CGSize)size
             scale:(CGFloat)scale
           toLayer:(CALayer *)layer
              draw:(void (^)(CGContextRef))draw {
  NSAssert(NSThread.isMainThread, @"SCGLayer draws and presents on the main thread");
  if (!_create && !_createLegacy) return NO;
  double width = ceil(size.width * scale), height = ceil(size.height * scale);
  if (!std::isfinite(width) || !std::isfinite(height) || !std::isfinite(scale) || scale <= 0 ||
      width <= 0 || height <= 0 || width > 4096 || height > 4096) {
    _status = @"Invalid or oversized surface (limit: 4096 px per dimension)";
    return NO;
  }
  if (_width != width || _height != height || _scale != scale) {
    // CA retains previously published contents. Releasing our ownership does not
    // authorize writing to that old surface; these buffers are never reused.
    layer.contents = nil;
    _buffers.clear();
    _front = nullptr;
    _width = width;
    _height = height;
    _scale = scale;
  }
  Buffer *back = nullptr;
  for (auto &buffer : _buffers) {
    // The front buffer can be pending a CA commit even when IsInUse is false.
    if (buffer.get() != _front && !IOSurfaceIsInUse(buffer->surface)) {
      back = buffer.get();
      break;
    }
  }
  if (!back && _buffers.size() < 3) {
    auto buffer = std::make_unique<Buffer>();
    size_t rowBytes = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, _width * 4);
    NSDictionary *properties = @{
      (id)kIOSurfaceWidth : @(_width),
      (id)kIOSurfaceHeight : @(_height),
      (id)kIOSurfaceBytesPerElement : @4,
      (id)kIOSurfaceBytesPerRow : @(rowBytes),
      (id)kIOSurfaceAllocSize : @(IOSurfaceAlignProperty(kIOSurfaceAllocSize, rowBytes * _height)),
      (id)kIOSurfacePixelFormat : @((uint32_t)'BGRA')
    };
    buffer->surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!buffer->surface) {
      _status = @"IOSurfaceCreate failed";
      return NO;
    }
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGBitmapInfo format =
        kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst;
    // Use the ordinary IOSurface backend; no entitlement or WebKit identity spoofing.
    buffer->context =
        _create ? _create(buffer->surface, _width, _height, 8, 32, colorSpace, format, nullptr)
                : _createLegacy(buffer->surface, _width, _height, 8, 32, colorSpace, format);
    CGColorSpaceRelease(colorSpace);
    if (!buffer->context) {
      _status = @"Private CGContext constructor returned NULL";
      return NO;
    }
    back = buffer.get();
    _buffers.push_back(std::move(buffer));
  }
  if (!back) {
    ++_droppedFrames;
    _status = @"All presentation buffers are busy; previous contents retained";
    return NO;  // Bounded pool: keep the old frame instead of racing the compositor.
  }
  CGContextRef context = back->context;
  CGContextSaveGState(context);
  CGContextClearRect(context, CGRectMake(0, 0, _width, _height));
  CGContextTranslateCTM(context, 0, _height);
  CGContextScaleCTM(context, scale, -scale);  // UIKit points, top-left origin.
  draw(context);
  CGContextRestoreGState(context);
  // Submit pending CGContext work before publishing the surface. This is not
  // a public GPU completion fence; Core Animation handles surface presentation.
  CGContextFlush(context);
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  layer.contentsScale = scale;
  // IOSurface layer contents is also an internal presentation path used by WebKit.
  layer.contents = (__bridge id)back->surface;
  [CATransaction commit];
  _front = back;
  _status = _create ? @"Private IOSurface CGContext (GPU execution unverified)"
                    : @"Legacy IOSurface CGContext (GPU execution unverified)";
  return YES;
}

- (CGSize)pixelSize {
  return CGSizeMake(_width, _height);
}

- (NSData *)copyPixels {
  if (!_front) return nil;
  CGContextFlush(_front->context);
  IOSurfaceRef surface = _front->surface;
  if (IOSurfaceLock(surface, kIOSurfaceLockReadOnly, nullptr) != 0) return nil;
  NSMutableData *pixels = [NSMutableData dataWithLength:_width * _height * 4];
  const uint8_t *src = static_cast<const uint8_t *>(IOSurfaceGetBaseAddress(surface));
  uint8_t *dst = static_cast<uint8_t *>(pixels.mutableBytes);
  size_t rowBytes = IOSurfaceGetBytesPerRow(surface);
  for (size_t y = 0; y < _height; ++y) memcpy(dst + y * _width * 4, src + y * rowBytes, _width * 4);
  IOSurfaceUnlock(surface, kIOSurfaceLockReadOnly, nullptr);
  return pixels;
}
@end
