#import <UIKit/UIKit.h>
#include <mach/mach.h>
#include <os/signpost.h>
#include <sys/resource.h>
#include <algorithm>
#include <vector>
#import "DemoScene.h"
#import "SCGSurfaceRenderer.h"
#import "SCGLayer.h"

static os_log_t BenchmarkLog() {
  static os_log_t log =
      os_log_create("org.zhongyr.SCGDemo", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
  return log;
}

static double FootprintMiB() {
  task_vm_info_data_t info{};
  mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
  if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
    return -1;
  return info.phys_footprint / 1048576.0;
}

static double ProcessCPUSeconds() {
  struct rusage usage{};
  if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
  return usage.ru_utime.tv_sec + usage.ru_utime.tv_usec / 1e6 + usage.ru_stime.tv_sec +
         usage.ru_stime.tv_usec / 1e6;
}

static BOOL FixedFixtureChecks() {
  DemoScene first, second;
  // Same wall time, different update revisions must invalidate every text item.
  first.build(CGSizeMake(358, 447), 30, 1, @"text", false, false, 1);
  second.build(CGSizeMake(358, 447), 30, 1, @"text", false, false, 2);
  size_t changed = 0;
  for (size_t i = 0; i < first.items.size(); ++i) {
    if (first.items[i].kind == PrimitiveKind::Text &&
        first.items[i].textID != second.items[i].textID)
      ++changed;
  }
  if (changed != 30) return NO;
  second.build(CGSizeMake(358, 447), 30, 1, @"text", true, false, 2);
  first.build(CGSizeMake(358, 447), 30, 1, @"text", true, false, 1);
  changed = 0;
  for (size_t i = 0; i < first.items.size(); ++i) {
    if (first.items[i].kind == PrimitiveKind::Text &&
        first.items[i].textID != second.items[i].textID)
      ++changed;
  }
  if (changed != 1) return NO;
  for (NSString *kind in @[ @"text", @"fills" ]) {
    first.build(CGSizeMake(358, 447), 1000, 1, kind, false, false, 1);
    size_t primitives = 0;
    for (auto &item : first.items) {
      if (++primitives == 1) continue;  // Background.
      auto &box = item.rect;
      if ([kind isEqualToString:@"text"] ? (box.size.width != 110 || box.size.height != 16)
                                         : (box.size.width != 24 || box.size.height != 24))
        return NO;
    }
    if (primitives != 1001) return NO;
  }
  return YES;
}

static NSString *PublicLayerFailure;
static BOOL PublicLayerChecks() {
  auto fail = [](NSString *reason) { PublicLayerFailure = reason; return NO; };
  SCGLayer *layer = [SCGLayer layer];
  layer.bounds = CGRectMake(4, 6, 32, 24);
  layer.contentsScale = 2;
  __block NSUInteger draws = 0;
  __block CGRect receivedBounds = CGRectZero;
  layer.drawingBlock = ^(CGContextRef context, CGRect bounds) {
    ++draws;
    receivedBounds = bounds;
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, bounds);
  };
  NSError *error = nil;
  if (![layer renderWithError:&error] || error || !layer.contents || draws != 1 ||
      layer.needsDisplay || !CGRectEqualToRect(receivedBounds, layer.bounds))
    return fail([NSString stringWithFormat:@"initial: draws=%lu dirty=%d contents=%d error=%@", (unsigned long)draws, layer.needsDisplay, layer.contents != nil, error]);
  [layer displayIfNeeded];
  if (draws != 1) return fail(@"Duplicate display after immediate render");
  layer.contentsScale = 1;
  [layer displayIfNeeded];
  if (draws != 2) return fail(@"Scale change did not cause exactly one display");
  SCGLayer *copy = [[SCGLayer alloc] initWithLayer:layer];
  // initWithLayer: is Core Animation's copy hook, not a general geometry clone.
  copy.bounds = layer.bounds;
  copy.contentsScale = layer.contentsScale;
  if (copy.surfaceCount != 0 || ![copy renderWithError:&error] ||
      copy.contents == layer.contents || layer.surfaceCount == 0)
    return fail([NSString stringWithFormat:@"copy: surfaces=%lu error=%@", (unsigned long)copy.surfaceCount, error]);
  for (unsigned i = 0; i < 20; ++i) [layer renderWithError:&error];
  if (layer.surfaceCount > 3 || layer.ownedSurfaceBytes == 0) return fail(@"Pool allocation");
  layer.bounds = CGRectZero;
  if ([layer renderWithError:&error] || error.code != SCGLayerErrorInvalidGeometry ||
      layer.lastRenderError != error) return fail(@"Invalid bounds were not rejected");
  return YES;
}

static BOOL LayerRebuildChecks() {
  // Hold the old tree alive so identity checks cannot pass through address reuse.
  for (NSString *kind in @[ @"fills", @"text", @"shape", @"gradient" ]) {
    DemoScene scene;
    CALayer *host = [CALayer layer];
    scene.build(CGSizeMake(358, 447), 30, 1, kind);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    scene.applyLayers(host, 3);
    NSArray<CALayer *> *oldLayers = [host.sublayers copy];
    // Even identical content must allocate and insert an entirely new tree.
    scene.applyLayers(host, 3);
    NSArray<CALayer *> *newLayers = [host.sublayers copy];
    [CATransaction commit];
    if (oldLayers.count != 31 || newLayers.count != 31) return NO;
    for (CALayer *old in oldLayers) {
      if (old.superlayer || [newLayers indexOfObjectIdenticalTo:old] != NSNotFound) return NO;
    }
    for (NSUInteger i = 0; i < newLayers.count; ++i) {
      CALayer *child = newLayers[i];
      if (child.superlayer != host || !CGRectEqualToRect(child.frame, oldLayers[i].frame))
        return NO;
      if ([kind isEqualToString:@"text"] && i > 0 && !child.needsDisplay) return NO;
      if ([kind isEqualToString:@"shape"] && i > 0) {
        if (![child isKindOfClass:CAShapeLayer.class]) return NO;
        CAShapeLayer *shape = (CAShapeLayer *)child;
        if (CGPathContainsPoint(shape.path, nullptr, CGPointMake(12, 12), YES) ||
            !CGPathContainsPoint(shape.path, nullptr, CGPointMake(12, 16), YES))
          return NO;
      }
      if ([kind isEqualToString:@"gradient"] && i > 0 &&
          (![child isKindOfClass:CAGradientLayer.class] ||
           ((CAGradientLayer *)child).colors.count != 3))
        return NO;
    }
    if ([kind isEqualToString:@"shape"] || [kind isEqualToString:@"gradient"]) {
      scene.build(CGSizeMake(358, 447), 30, 1, kind, false, false, 1);
      for (size_t i = 0; i < scene.vectors.size(); ++i) {
        if (scene.vectors[i].variant != (i + 1) % 2 ||
            !CGSizeEqualToSize(scene.vectors[i].rect.size, CGSizeMake(24, 24)))
          return NO;
      }
    }
  }
  return YES;
}

static NSDictionary *SurfaceChecks(BOOL enabled) {
  SCGSurfaceRenderer *presenter = [[SCGSurfaceRenderer alloc] initWithPrivateAPIEnabled:enabled];
  CALayer *layer = [CALayer layer];
  BOOL invalidRejected = ![presenter renderSize:CGSizeZero
                                          scale:1
                                        toLayer:layer
                                           draw:^(CGContextRef){
                                           }];
  BOOL disabledRejected =
      ![[[SCGSurfaceRenderer alloc] initWithPrivateAPIEnabled:NO] renderSize:CGSizeMake(32, 24)
                                                                     scale:1
                                                                   toLayer:layer
                                                                      draw:^(CGContextRef){
                                                                      }];
  auto paint = ^(CGContextRef context) {
    CGContextSetRGBFillColor(context, 1, 0, 0, 1);
    CGContextFillRect(context, CGRectMake(0, 0, 32, 12));
    CGContextSetRGBFillColor(context, 0, 0, 1, 1);
    CGContextFillRect(context, CGRectMake(0, 12, 32, 12));
  };
  BOOL created = [presenter renderSize:CGSizeMake(32, 24) scale:1 toLayer:layer draw:paint];
  if (!created)
    return @{
      @"contextCreated" : @NO,
      @"status" : presenter.status,
      @"invalidSizeRejected" : @(invalidRejected),
      @"disabledAPIRejected" : @(disabledRejected)
    };
  NSData *actual = [presenter copyPixels];
  NSMutableData *expected = [NSMutableData dataWithLength:32 * 24 * 4];
  CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef bitmap = CGBitmapContextCreate(
      expected.mutableBytes, 32, 24, 8, 32 * 4, colorSpace,
      kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
  CGContextTranslateCTM(bitmap, 0, 24);
  CGContextScaleCTM(bitmap, 1, -1);
  paint(bitmap);
  CGContextRelease(bitmap);
  CGColorSpaceRelease(colorSpace);
  BOOL pixelParity = [actual isEqualToData:expected];
  BOOL resized = [presenter renderSize:CGSizeMake(40, 30) scale:2 toLayer:layer draw:paint];
  BOOL scaleCorrect = CGSizeEqualToSize(presenter.pixelSize, CGSizeMake(80, 60));
  // Repeated offscreen publication must remain bounded and never write the front.
  for (int i = 0; i < 20; ++i)
    [presenter renderSize:CGSizeMake(40, 30) scale:2 toLayer:layer draw:paint];
  return @{
    @"contextCreated" : @YES,
    @"pixelParity" : @(pixelParity),
    @"invalidSizeRejected" : @(invalidRejected),
    @"disabledAPIRejected" : @(disabledRejected),
    @"resizeAndScale" : @(resized && scaleCorrect),
    @"poolBounded" : @(presenter.bufferCount <= 3),
    @"poolBytes" : @(presenter.allocatedBytes),
    @"status" : presenter.status
  };
}

// Forced unavailability exercises the demo's failure UI without exposing a library test switch.
@interface UnavailableDemoLayer : SCGLayer
@end
@implementation UnavailableDemoLayer
- (void)display {}
- (BOOL)renderWithError:(NSError **)error {
  if (error) *error = [NSError errorWithDomain:SCGLayerErrorDomain code:SCGLayerErrorUnavailable userInfo:nil];
  return NO;
}
@end

@interface DemoDrawView : UIView
@property(nonatomic, copy) void (^render)(CGContextRef);
@end
@implementation DemoDrawView
- (void)drawRect:(CGRect)rect {
  if (self.render) self.render(UIGraphicsGetCurrentContext());
}
@end

@interface DemoController : UIViewController
@end

struct UpdateInterval {
  CFTimeInterval start, nextCallback;
  double budgetMS;
  NSUInteger startCallback, endCallback;
};

struct EncodeSample {
  CFTimeInterval start;
  double milliseconds;
};

@implementation DemoController {
  UISegmentedControl *_backend, *_workload, *_density;
  UILabel *_stats;
  UIView *_canvas, *_drawing;
  SCGLayer *_surface;
  CADisplayLink *_link;
  DemoScene _scene;
  std::vector<EncodeSample> _encodeMS;
  std::vector<double> _cadenceMS;
  std::vector<UpdateInterval> _updateIntervals;
  CFTimeInterval _start, _lastTick, _lastStats;
  CFTimeInterval _pendingUpdateStart, _pausedAt;
  double _pendingBudgetMS, _testStallMS;
  NSUInteger _callbackSequence, _pendingCallback, _updateAttempts, _cancelledIntervals;
  BOOL _needsPaint;
  size_t _count;
  double _duration;
  BOOL _privateEnabled, _finished;
  NSUInteger _submittedFrames;
  NSUInteger _layerTreeRebuilds, _layerObjectsCreated, _layerObjectsDetached;
  NSUInteger _configurationChanges;  // Lifetime count; do not clear in reset.
  NSDictionary *_checks;
  NSString *_sceneKind, *_runID;
  double _warmupSeconds;
  BOOL _steadyStarted;
  NSInteger _initialThermalState, _maxThermalState;
  os_signpost_id_t _pendingSignpost;
  double _steadyCPUStart, _steadyCPUSeconds, _steadyWallStart, _steadyWallSeconds;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  NSUserDefaults *args = NSUserDefaults.standardUserDefaults;
  _privateEnabled = ![args boolForKey:@"disable-private-api"];
  _duration = [args doubleForKey:@"seconds"];
  _warmupSeconds = MAX(0, MIN(60, [args doubleForKey:@"warmup-seconds"]));
  _sceneKind = [args stringForKey:@"scene"] ?: @"cards";
  if (![@[ @"cards", @"fills", @"text", @"shape", @"gradient" ] containsObject:_sceneKind])
    _sceneKind = @"cards";
  _runID = [args stringForKey:@"run-id"] ?: @"interactive";
  UIApplication.sharedApplication.idleTimerDisabled = YES;
  // Validation only: deliberately delay after encoding to exercise the wider timer.
  _testStallMS = MAX(0, MIN(100, [args doubleForKey:@"test-stall-ms"]));
  _count = MAX(1, [args integerForKey:@"count"] ?: 30);
  _count = MIN(_count, 10000);
  if ([args boolForKey:@"self-test"]) {
    NSMutableDictionary *checks = [SurfaceChecks(_privateEnabled) mutableCopy];
    checks[@"fixedFixture"] = @(FixedFixtureChecks());
    checks[@"layerTreeRebuilt"] = @(LayerRebuildChecks());
    if (_privateEnabled) checks[@"publicLayer"] = @(PublicLayerChecks());
    if (PublicLayerFailure) checks[@"publicLayerFailure"] = PublicLayerFailure;
    _checks = checks;
  }
  UILabel *title = [UILabel new];
  title.text = [_sceneKind isEqualToString:@"shape"]      ? @"CAShapeLayer probe"
               : [_sceneKind isEqualToString:@"gradient"] ? @"Gradient probe"
                                                          : @"SCGLayer Lab";
  title.font = [UIFont boldSystemFontOfSize:24];
  _backend = [[UISegmentedControl alloc] initWithItems:@[ @"Layers", @"drawRect", @"SCGLayer" ]];
  _backend.selectedSegmentIndex = [@[ @"layers", @"draw", @"surface" ]
      indexOfObject:[args stringForKey:@"backend"] ?: @"layers"];
  if (_backend.selectedSegmentIndex == NSNotFound) _backend.selectedSegmentIndex = 0;
  _workload =
      [[UISegmentedControl alloc] initWithItems:@[ @"Static", @"All", @"Host", @"One", @"Child" ]];
  _workload.selectedSegmentIndex = [@[ @"static", @"repaint", @"transform", @"single", @"child" ]
      indexOfObject:[args stringForKey:@"workload"] ?: @"static"];
  if (_workload.selectedSegmentIndex == NSNotFound) _workload.selectedSegmentIndex = 0;
  _density = [[UISegmentedControl alloc] initWithItems:@[ @"30 items", @"300", @"1000" ]];
  _density.selectedSegmentIndex = _count == 1000 ? 2 : _count == 300 ? 1 : 0;
  for (UISegmentedControl *control in @[ _backend, _workload, _density ]) {
    [control addTarget:self action:@selector(change:) forControlEvents:UIControlEventValueChanged];
    control.enabled = _duration <= 0;  // Automated runs keep their launch configuration.
  }
  _stats = [UILabel new];
  _stats.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
  _stats.numberOfLines = 0;
  UIStackView *controls = [[UIStackView alloc]
      initWithArrangedSubviews:@[ title, _backend, _workload, _density, _stats ]];
  controls.axis = UILayoutConstraintAxisVertical;
  controls.spacing = 10;
  controls.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:controls];
  _canvas = [UIView new];
  _canvas.backgroundColor = UIColor.secondarySystemBackgroundColor;
  _canvas.clipsToBounds = YES;
  _canvas.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:_canvas];
  [NSLayoutConstraint activateConstraints:@[
    [controls.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
    [controls.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
    [controls.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    [_canvas.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                      constant:300],
    [_canvas.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
    [_canvas.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-16],
    [_canvas.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                         constant:-16]
  ]];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(pause:)
                                               name:UIApplicationWillResignActiveNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(resume:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];
  [self reset];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  if (!_link) {
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self resume:nil];
  }
}
- (void)viewDidDisappear:(BOOL)animated {
  [super viewDidDisappear:animated];
  [self pause:nil];
  [_link invalidate];
  _link = nil;
}
- (void)pause:(NSNotification *)note {
  _link.paused = YES;
  if (!_pausedAt) _pausedAt = CACurrentMediaTime();
  if (_pendingUpdateStart) {
    os_signpost_interval_end(BenchmarkLog(), _pendingSignpost, "UpdateToCallback", "cancelled");
    ++_cancelledIntervals;
    _pendingUpdateStart = 0;  // Background time is not rendering latency.
  }
}
- (void)resume:(NSNotification *)note {
  if (_pausedAt && _start) _start += CACurrentMediaTime() - _pausedAt;
  _pausedAt = 0;
  _lastTick = 0;
  _link.paused = _finished;
}
- (void)change:(UISegmentedControl *)control {
  ++_configurationChanges;
  if (control == _density)
    _count = _density.selectedSegmentIndex == 0   ? 30
             : _density.selectedSegmentIndex == 1 ? 300
                                                  : 1000;
  [self reset];
}
- (void)reset {
  [_drawing removeFromSuperview];
  _surface = nil;
  _encodeMS.clear();
  _cadenceMS.clear();
  _updateIntervals.clear();
  _pendingUpdateStart = _pausedAt = 0;
  _callbackSequence = _pendingCallback = _updateAttempts = _cancelledIntervals = 0;
  _needsPaint = YES;
  _submittedFrames = 0;
  _layerTreeRebuilds = _layerObjectsCreated = _layerObjectsDetached = 0;
  _lastTick = _lastStats = 0;
  _start = 0;  // Start the benchmark on the first display-link callback.
  _steadyStarted = NO;
  _steadyCPUStart = _steadyCPUSeconds = _steadyWallStart = _steadyWallSeconds = 0;
  _initialThermalState = _maxThermalState = NSProcessInfo.processInfo.thermalState;
  _finished = NO;
  _link.paused = NO;
  if (_backend.selectedSegmentIndex == 1) {
    DemoDrawView *drawView = [DemoDrawView new];
    __weak DemoController *weakSelf = self;
    drawView.render = ^(CGContextRef context) {
      DemoController *owner = weakSelf;
      if (!owner) return;
      double start = CACurrentMediaTime();
      os_signpost_id_t signpost = os_signpost_id_generate(BenchmarkLog());
      os_signpost_interval_begin(BenchmarkLog(), signpost, "DrawRect");
      owner->_scene.draw(context);
      owner->_encodeMS.push_back({start, (CACurrentMediaTime() - start) * 1000});
      os_signpost_interval_end(BenchmarkLog(), signpost, "DrawRect");
      ++owner->_submittedFrames;
    };
    drawView.opaque = YES;
    drawView.contentMode = UIViewContentModeRedraw;
    _drawing = drawView;
  } else {
    _drawing = [UIView new];
    if (_backend.selectedSegmentIndex == 2) {
      _surface = _privateEnabled ? [SCGLayer layer] : [UnavailableDemoLayer layer];
      __weak DemoController *weakSelf = self;
      _surface.drawingBlock = ^(CGContextRef context, CGRect bounds) {
        DemoController *owner = weakSelf;
        if (owner) owner->_scene.draw(context);
      };
      [_drawing.layer addSublayer:_surface];
    }
  }
  [_canvas addSubview:_drawing];
  [self.view setNeedsLayout];
  [self updateStats];
}
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!CGSizeEqualToSize(_drawing.bounds.size, _canvas.bounds.size)) {
    _drawing.bounds = (CGRect){CGPointZero, _canvas.bounds.size};
    _drawing.center = CGPointMake(CGRectGetMidX(_canvas.bounds), CGRectGetMidY(_canvas.bounds));
    _needsPaint = YES;  // Start every measured update at the same callback boundary.
  }
}
- (void)paint:(CGFloat)phase {
  if (CGRectIsEmpty(_drawing.bounds)) return;
  _scene.build(_drawing.bounds.size, _count, phase, _sceneKind, _workload.selectedSegmentIndex == 3,
               _workload.selectedSegmentIndex == 4, _updateAttempts);
  if (_backend.selectedSegmentIndex == 1) {
    [_drawing setNeedsDisplay];
    return;
  }
  CGFloat scale = self.view.window.screen.scale ?: self.view.contentScaleFactor;
  double start = CACurrentMediaTime();
  os_signpost_id_t signpost = os_signpost_id_generate(BenchmarkLog());
  os_signpost_interval_begin(BenchmarkLog(), signpost, "ApplyContent");
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  BOOL submitted = YES;
  if (_surface) {
    _surface.frame = _drawing.bounds;
    _surface.contentsScale = scale;
    submitted = [_surface renderWithError:nullptr];
  } else {
    _layerObjectsDetached += _drawing.layer.sublayers.count;
    _scene.applyLayers(_drawing.layer, scale);
    _layerObjectsCreated += _drawing.layer.sublayers.count;
    ++_layerTreeRebuilds;
  }
  [CATransaction commit];
  if (submitted) {
    _encodeMS.push_back({start, (CACurrentMediaTime() - start) * 1000});
    ++_submittedFrames;
  }
  os_signpost_interval_end(BenchmarkLog(), signpost, "ApplyContent");
}
- (void)tick:(CADisplayLink *)link {
  // This MUST be the first operation: close the previous update before doing
  // any new work. Neither link.timestamp nor targetTimestamp is callback entry.
  double now = CACurrentMediaTime();
  ++_callbackSequence;
  if (_pendingUpdateStart) {
    _updateIntervals.push_back(
        {_pendingUpdateStart, now, _pendingBudgetMS, _pendingCallback, _callbackSequence});
    _pendingUpdateStart = 0;
    os_signpost_interval_end(BenchmarkLog(), _pendingSignpost, "UpdateToCallback");
  }
  if (_lastTick) _cadenceMS.push_back((now - _lastTick) * 1000);
  _lastTick = now;
  if (!_start) _start = now;
  double elapsed = now - _start;
  _maxThermalState = MAX(_maxThermalState, NSProcessInfo.processInfo.thermalState);
  if (!_steadyStarted && elapsed >= _warmupSeconds) {
    _steadyStarted = YES;
    _steadyCPUStart = ProcessCPUSeconds();
    _steadyWallStart = now;
    os_signpost_interval_begin(BenchmarkLog(), OS_SIGNPOST_ID_EXCLUSIVE, "SteadyState",
                               "run=%{public}s", _runID.UTF8String);
  }
  // Stop only after closing the last update on its NEXT callback. Do not start
  // another update on this final callback, or its interval would be lost.
  if (_duration > 0 && elapsed >= _warmupSeconds + _duration) {
    _finished = YES;
    _link.paused = YES;
    _steadyCPUSeconds = ProcessCPUSeconds() - _steadyCPUStart;
    _steadyWallSeconds = now - _steadyWallStart;
    os_signpost_interval_end(BenchmarkLog(), OS_SIGNPOST_ID_EXCLUSIVE, "SteadyState");
    dispatch_async(dispatch_get_main_queue(), ^{
      [self updateStats];
      NSDictionary *report = [self report];
      NSData *json = [NSJSONSerialization dataWithJSONObject:report
                                                     options:NSJSONWritingPrettyPrinted
                                                       error:nil];
      NSString *path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/report.json"];
      [json writeToFile:path atomically:YES];
      NSLog(@"DEMO_REPORT_READY %@", self->_runID);
    });
    return;
  }
  if (!CGRectIsEmpty(_drawing.bounds) && (_needsPaint || _workload.selectedSegmentIndex != 0)) {
    _pendingBudgetMS = (link.targetTimestamp - link.timestamp) * 1000;
    _pendingCallback = _callbackSequence;
    ++_updateAttempts;
    _pendingUpdateStart = CACurrentMediaTime();
    _pendingSignpost = os_signpost_id_generate(BenchmarkLog());
    os_signpost_interval_begin(BenchmarkLog(), _pendingSignpost, "UpdateToCallback");
    // Include fixture generation, mutations, deferred drawRect/CA work and the
    // remaining run-loop time up to entry into the next actual callback.
    if (_needsPaint || _workload.selectedSegmentIndex == 1 || _workload.selectedSegmentIndex >= 3) {
      [self paint:elapsed];
      _needsPaint = NO;
    }
    if (_workload.selectedSegmentIndex == 2) {
      _drawing.transform = CGAffineTransformMakeTranslation(8 * sin(elapsed * 2), 0);
    }
    if (_testStallMS > 0) [NSThread sleepForTimeInterval:_testStallMS / 1000];
  }
  // Avoid changing benchmark UI during timed runs. Interactive mode shows live stats.
  if (_duration <= 0 && now - _lastStats > 1) {
    [self updateStats];
    _lastStats = now;
  }
}
- (NSDictionary *)report {
  double total = 0;
  std::vector<double> samples;
  for (auto &sample : _encodeMS) {
    if (sample.start < _start + _warmupSeconds) continue;
    total += sample.milliseconds;
    samples.push_back(sample.milliseconds);
  }
  std::sort(samples.begin(), samples.end());
  double p95 = samples.empty() ? 0 : samples[(size_t)((samples.size() - 1) * .95)];
  double cadenceTotal = 0;
  for (double value : _cadenceMS) cadenceTotal += value;
  std::vector<double> intervalMS;
  double intervalTotal = 0;
  NSUInteger overBudget = 0;
  NSMutableArray *rawIntervals = [NSMutableArray arrayWithCapacity:_updateIntervals.size()];
  for (const auto &interval : _updateIntervals) {
    double value = (interval.nextCallback - interval.start) * 1000;
    BOOL warmup = interval.start < _start + _warmupSeconds;
    if (!warmup) {
      intervalMS.push_back(value);
      intervalTotal += value;
    }
    // A jitter-tolerant callback-latency threshold, NOT a count of dropped presentations.
    if (!warmup && interval.budgetMS > 0 && value > 1.5 * interval.budgetMS) ++overBudget;
    [rawIntervals addObject:@{
      @"startSeconds" : @(interval.start),
      @"nextCallbackSeconds" : @(interval.nextCallback),
      @"elapsedMS" : @(value),
      @"expectedIntervalMS" : @(interval.budgetMS),
      @"startCallback" : @(interval.startCallback),
      @"endCallback" : @(interval.endCallback),
      @"warmup" : @(warmup)
    }];
  }
  std::sort(intervalMS.begin(), intervalMS.end());
  auto percentile = [&](double fraction) {
    return intervalMS.empty() ? 0.0 : intervalMS[(size_t)((intervalMS.size() - 1) * fraction)];
  };
  CGFloat scale = self.view.window.screen.scale ?: self.view.contentScaleFactor;
  size_t backing = (size_t)ceil(_drawing.bounds.size.width * scale) *
                   (size_t)ceil(_drawing.bounds.size.height * scale) * 4;
  return @{
    @"measurementVersion" : @2,
    @"fixtureVersion" : @6,
    @"configurationChanges" : @(_configurationChanges),
    @"automaticControlsLocked" : @(!_backend.enabled && !_workload.enabled && !_density.enabled),
    @"layerUpdatePolicy" : @"rebuild-all-content-layers",
    @"layerTreeRebuilds" : @(_layerTreeRebuilds),
    @"layerObjectsCreated" : @(_layerObjectsCreated),
    @"layerObjectsDetached" : @(_layerObjectsDetached),
    @"backend" : @[ @"layers", @"drawRect", @"SCGLayer" ][_backend.selectedSegmentIndex],
    @"workload" : @[ @"static", @"repaint", @"transform", @"single",
                     @"child" ][_workload.selectedSegmentIndex],
    @"scene" : _sceneKind,
    @"vectorResourcePolicy" : @"two-immutable-variants-shared-by-all-backends",
    @"canvasOriginX" : @([_drawing convertPoint:CGPointZero toView:self.view].x),
    @"canvasOriginY" : @([_drawing convertPoint:CGPointZero toView:self.view].y),
    @"runID" : _runID,
    @"processCPUSeconds" : @(_steadyCPUSeconds),
    @"steadyWallSeconds" : @(_steadyWallSeconds),
    @"processCPUPercentOfOneCore" :
        @(_steadyWallSeconds > 0 ? 100 * _steadyCPUSeconds / _steadyWallSeconds : 0),
    @"warmupSeconds" : @(_warmupSeconds),
    @"measurementSeconds" : @(_duration),
    @"steadyIntervalCount" : @(intervalMS.size()),
    @"steadyEncodeCount" : @(samples.size()),
    @"initialThermalState" : @(_initialThermalState),
    @"maxThermalState" : @(_maxThermalState),
    @"finalThermalState" : @(NSProcessInfo.processInfo.thermalState),
    @"lowPowerMode" : @(NSProcessInfo.processInfo.lowPowerModeEnabled),
    @"cards" : @(_count),
    @"submittedFrames" : @(_submittedFrames),
    @"encodeMeanMS" : @(samples.empty() ? 0 : total / samples.size()),
    @"encodeP95MS" : @(p95),
    @"callbackCadenceMeanMS" : @(_cadenceMS.empty() ? 0 : cadenceTotal / _cadenceMS.size()),
    @"updateToNextCallbackMeanMS" : @(intervalMS.empty() ? 0 : intervalTotal / intervalMS.size()),
    @"updateToNextCallbackP95MS" : @(percentile(.95)),
    @"updateToNextCallbackP99MS" : @(percentile(.99)),
    @"updateToNextCallbackMaxMS" : @(percentile(1)),
    @"updateToNextCallbackOver1_5BudgetCount" : @(overBudget),
    @"updateAttempts" : @(_updateAttempts),
    @"cancelledIntervals" : @(_cancelledIntervals),
    @"pendingInterval" : @(_pendingUpdateStart != 0),
    @"updateIntervals" : rawIntervals,
    @"testStallMS" : @(_testStallMS),
    @"processFootprintMiB" : @(FootprintMiB()),
    @"oneBGRA8BackingBytesEstimate" : @(backing),
    @"ownedIOSurfaceBytes" : @(_surface.ownedSurfaceBytes),
    @"ownedSurfaceCount" : @(_surface.surfaceCount),
    @"poolDroppedFrames" : @(_surface.droppedFrameCount),
    @"contentSublayers" : @(_drawing.layer.sublayers.count),
    @"scale" : @(scale),
    @"widthPoints" : @(_drawing.bounds.size.width),
    @"heightPoints" : @(_drawing.bounds.size.height),
    @"status" : _surface ? (_privateEnabled ? (_surface.lastRenderError.localizedDescription ?: @"SCGLayer · private CGContext") : @"Private API disabled for validation") : @"Public API",
    @"checks" : _checks ?: @{},
    @"os" : UIDevice.currentDevice.systemVersion,
    @"measurementLimits" :
        @"Update start to NEXT actual display-link callback entry includes "
        @"deferred app drawing, run-loop work and refresh wait. Not a GPU or "
        @"presentation fence: render-server/GPU work may overlap later callbacks. "
        @"Failed update attempts are included; check status/submittedFrames. "
        @"Process footprint excludes some render-server resources. Primary aggregates exclude "
        @"warmup."
  };
}
- (void)updateStats {
  NSDictionary *r = [self report];
  _stats.text = [NSString
      stringWithFormat:
          @"%@\nNext callback mean/p95: %.2f / %.2f ms\nCPU encode mean/p95: %.2f / %.2f ms"
          @"\nProcess footprint: %.1f MiB\nOwned surfaces: %.1f MiB · dropped %@"
          @"\nEncode calls: %@ · content layers: %@\nCallback latency is not GPU completion.",
          r[@"status"], [r[@"updateToNextCallbackMeanMS"] doubleValue],
          [r[@"updateToNextCallbackP95MS"] doubleValue], [r[@"encodeMeanMS"] doubleValue],
          [r[@"encodeP95MS"] doubleValue], [r[@"processFootprintMiB"] doubleValue],
          [r[@"ownedIOSurfaceBytes"] doubleValue] / 1048576, r[@"poolDroppedFrames"],
          r[@"submittedFrames"], r[@"contentSublayers"]];
}
@end

@interface DemoAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation DemoAppDelegate
- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [DemoController new];
  [self.window makeKeyAndVisible];
  return YES;
}
@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(DemoAppDelegate.class));
  }
}
