#import "DemoScene.h"
#import <CoreText/CoreText.h>
#include <cmath>


namespace {
UIColor *Color(uint32_t argb) {
  return [UIColor colorWithRed:((argb >> 16) & 255) / 255.0
                         green:((argb >> 8) & 255) / 255.0
                          blue:(argb & 255) / 255.0
                         alpha:(argb >> 24) / 255.0];
}
NSArray *GradientColors(unsigned variant) {
  static NSArray *palettes[2];
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    palettes[0] = @[
      (id)Color(0xfff97316).CGColor, (id)Color(0xff8b5cf6).CGColor, (id)Color(0xff06b6d4).CGColor
    ];
    palettes[1] = @[
      (id)Color(0xff22c55e).CGColor, (id)Color(0xffec4899).CGColor, (id)Color(0xff3b82f6).CGColor
    ];
  });
  return palettes[variant];
}
CGGradientRef Gradient(unsigned variant) {
  static CGGradientRef gradients[2];
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGFloat locations[] = {0, .4, 1};
    for (unsigned v = 0; v < 2; ++v)
      gradients[v] =
          CGGradientCreateWithColors(space, (__bridge CFArrayRef)GradientColors(v), locations);
    CGColorSpaceRelease(space);
  });
  return gradients[variant];
}
NSArray<NSNumber *> *GradientLocations() {
  static NSArray<NSNumber *> *locations = @[ @0, @.4, @1 ];
  return locations;
}
CGPathRef ShapePath(unsigned variant) {
  // Two immutable paths shared by every backend: 16 cubic outer segments
  // plus an elliptical hole. Geometry changes with the update revision.
  static CGPathRef paths[2];
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (unsigned v = 0; v < 2; ++v) {
      CGPoint points[16];
      for (unsigned i = 0; i < 16; ++i) {
        CGFloat angle = i * M_PI / 8 + v * .15;
        CGFloat radius = i % 2 ? 6 + v : 10 - v;
        points[i] = CGPointMake(12 + radius * cos(angle), 12 + radius * sin(angle));
      }
      CGMutablePathRef path = CGPathCreateMutable();
      CGPathMoveToPoint(path, nullptr, points[0].x, points[0].y);
      for (unsigned i = 0; i < 16; ++i) {
        CGPoint a = points[(i + 15) % 16], b = points[i];
        CGPoint c = points[(i + 1) % 16], d = points[(i + 2) % 16];
        CGPathAddCurveToPoint(path, nullptr, b.x + (c.x - a.x) / 6, b.y + (c.y - a.y) / 6,
                              c.x - (d.x - b.x) / 6, c.y - (d.y - b.y) / 6, c.x, c.y);
      }
      CGPathCloseSubpath(path);
      CGPathAddEllipseInRect(path, nullptr, CGRectMake(9.5, 9.5, 5, 5));
      paths[v] = path;
    }
  });
  return paths[variant];
}
CTLineRef TextLine(int32_t textID) {
  static CTLineRef lines[2];
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (NSUInteger i = 0; i < 2; ++i) {
      NSAttributedString *text = [[NSAttributedString alloc]
          initWithString:i ? @"SCG · frame 002" : @"SCG · CGContext"
              attributes:@{
                NSFontAttributeName : [UIFont systemFontOfSize:11 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName : UIColor.whiteColor
              }];
      lines[i] = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)text);
    }
  });
  return lines[textID == 2 ? 1 : 0];
}
void DrawText(CGContextRef context, CGRect rect, int32_t textID) {
  CGContextSaveGState(context);
  CGContextClipToRect(context, rect);
  CGContextTranslateCTM(context, rect.origin.x, rect.origin.y + 12);
  CGContextScaleCTM(context, 1, -1);
  CGContextSetTextMatrix(context, CGAffineTransformIdentity);
  CGContextSetTextPosition(context, 0, 0);
  CTLineDraw(TextLine(textID), context);
  CGContextRestoreGState(context);
}
}  // namespace

@interface DemoTextLayer : CALayer
@property(nonatomic) int32_t textID;
@end
@implementation DemoTextLayer
- (void)drawInContext:(CGContextRef)context {
  DrawText(context, self.bounds, self.textID);
}
@end

void DemoScene::build(CGSize size, size_t count, CGFloat phase, NSString *kind,
                      bool singleChange, bool childMotion, size_t revision) {
  items.clear();
  vectors.clear();
  vectorGradient = [kind isEqualToString:@"gradient"];
  items.push_back({PrimitiveKind::Fill, CGRectMake(0, 0, size.width, size.height), 0, 0xff112032, 0});
  if (vectorGradient || [kind isEqualToString:@"shape"]) {
    for (size_t i = 0; i < count; ++i) {
      CGFloat x = 8 + fmod(i * 37.0, MAX(1, size.width - 40));
      CGFloat y = 8 + fmod(i * 53.0, MAX(1, size.height - 40));
      if (childMotion && i == 0) x += 6 * sin(phase * 2);
      size_t contentRevision = childMotion || (singleChange && i != 0) ? 0 : revision;
      vectors.push_back({CGRectMake(x, y, 24, 24), (unsigned)((i + contentRevision) % 2)});
    }
    return;
  }
  const size_t columns = 3, rows = (count + columns - 1) / columns;
  CGFloat cellWidth = (size.width - 16) / columns, cellHeight = (size.height - 16) / rows;
  bool fixedText = [kind isEqualToString:@"text"], fixedFill = [kind isEqualToString:@"fills"];
  for (size_t i = 0; i < count; ++i) {
    CGFloat x = 8 + (i % columns) * cellWidth, y = 8 + (i / columns) * cellHeight;
    if (fixedText || fixedFill) {
      x = 8 + fmod(i * 37.0, MAX(1, size.width - (fixedText ? 126 : 40)));
      y = 8 + fmod(i * 53.0, MAX(1, size.height - 40));
      if (childMotion && i == 0) x += 6 * sin(phase * 2);
    }
    CGFloat gap = MIN(3, cellHeight / 5);
    CGFloat contentPhase = childMotion || (singleChange && i != 0) ? 0 : phase;
    size_t contentRevision = childMotion || (singleChange && i != 0) ? 0 : revision;
    if (!fixedText) {
      uint32_t blue = 90 + ((i * 13 + (fixedFill ? contentRevision * 31 : (size_t)(contentPhase * 80))) % 130);
      items.push_back({PrimitiveKind::Fill,
          CGRectMake(x, y, fixedFill ? 24 : cellWidth - 4, fixedFill ? 24 : MAX(1, cellHeight - gap)),
          fixedFill ? 4 : MIN(5, cellHeight / 4), (fixedFill ? 0x80245000 : 0xff245000) | blue, 0});
    }
    if (fixedText || (!fixedFill && cellHeight > 18)) {
      items.push_back({PrimitiveKind::Text, CGRectMake(x + 4, y + 2, fixedText ? 110 : cellWidth - 12, 16),
                      0, 0, fixedText ? (int)(1 + contentRevision % 2) : 1});
    }
  }
}

void DemoScene::draw(CGContextRef context) const {
  for (const auto &item : items) {
    if (item.kind == PrimitiveKind::Text) {
      DrawText(context, item.rect, item.textID);
    } else {
      CGContextSetFillColorWithColor(context, Color(item.color).CGColor);
      CGPathRef path = CGPathCreateWithRoundedRect(item.rect, item.radius, item.radius, nullptr);
      CGContextAddPath(context, path);
      CGContextFillPath(context);
      CGPathRelease(path);
    }
  }
  for (const auto &item : vectors) {
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, item.rect.origin.x, item.rect.origin.y);
    if (vectorGradient) {
      CGContextClipToRect(context, CGRectMake(0, 0, 24, 24));
      CGContextDrawLinearGradient(context, Gradient(item.variant), CGPointZero, CGPointMake(24, 24),
                                  0);
    } else {
      CGContextAddPath(context, ShapePath(item.variant));
      CGContextSetFillColorWithColor(context, (__bridge CGColorRef)GradientColors(item.variant)[1]);
      CGContextSetStrokeColorWithColor(context, UIColor.whiteColor.CGColor);
      CGContextSetLineWidth(context, 1.25);
      CGContextSetLineJoin(context, kCGLineJoinRound);
      CGContextSetLineCap(context, kCGLineCapRound);
      CGContextDrawPath(context, kCGPathEOFillStroke);
    }
    CGContextRestoreGState(context);
  }
}

void DemoScene::applyLayers(CALayer *layer, CGFloat scale) const {
  // Full content-tree rebuild baseline: no layer or text-backing reuse.
  layer.sublayers = nil;
  for (const auto &item : items) {
    CALayer *child;
    if (item.kind == PrimitiveKind::Text) {
      child = [DemoTextLayer layer];
      ((DemoTextLayer *)child).textID = item.textID;
      child.frame = item.rect;
      child.contentsScale = scale;
      [child setNeedsDisplay];
    } else {
      child = [CALayer layer];
      child.frame = item.rect;
      child.backgroundColor = Color(item.color).CGColor;
      child.cornerRadius = item.radius;
    }
    [layer addSublayer:child];
  }
  for (const auto &item : vectors) {
    CALayer *child;
    if (vectorGradient) {
      CAGradientLayer *gradient = [CAGradientLayer layer];
      gradient.colors = GradientColors(item.variant);
      gradient.locations = GradientLocations();
      gradient.startPoint = CGPointZero;
      gradient.endPoint = CGPointMake(1, 1);
      gradient.type = kCAGradientLayerAxial;
      gradient.opaque = YES;
      child = gradient;
    } else {
      CAShapeLayer *shape = [CAShapeLayer layer];
      shape.path = ShapePath(item.variant);
      shape.fillRule = kCAFillRuleEvenOdd;
      shape.fillColor = (__bridge CGColorRef)GradientColors(item.variant)[1];
      shape.strokeColor = UIColor.whiteColor.CGColor;
      shape.lineWidth = 1.25;
      shape.lineJoin = kCALineJoinRound;
      shape.lineCap = kCALineCapRound;
      child = shape;
    }
    child.frame = item.rect;
    child.contentsScale = scale;
    [layer addSublayer:child];
  }
}
