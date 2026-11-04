#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#include <vector>

enum class PrimitiveKind { Fill, Text };
struct DemoPrimitive {
  PrimitiveKind kind;
  CGRect rect;
  CGFloat radius;
  uint32_t color;
  int textID;
};
struct DemoVectorItem { CGRect rect; unsigned variant; };
struct DemoScene {
  std::vector<DemoPrimitive> items;
  std::vector<DemoVectorItem> vectors;
  bool vectorGradient = false;
  void build(CGSize size, size_t count, CGFloat phase, NSString *kind = @"cards",
             bool singleChange = false, bool childMotion = false, size_t revision = 0);
  void draw(CGContextRef context) const;
  void applyLayers(CALayer *layer, CGFloat scale) const;
};
