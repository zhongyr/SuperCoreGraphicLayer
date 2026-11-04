# Using SCGLayer

`SCGLayer` is a `CALayer` subclass. Its drawing block receives a borrowed
`CGContextRef`, with UIKit-style points and a top-left origin. A nonzero bounds
origin is respected. Do not retain or release the context, and balance any
CoreGraphics save/restore calls made inside the block.

```swift
import UIKit
import SCGLayer

let drawingLayer = SCGLayer()
drawingLayer.frame = view.bounds
drawingLayer.contentsScale = view.contentScaleFactor
drawingLayer.drawingBlock = { context, bounds in
    context.setFillColor(UIColor.systemCyan.cgColor)
    context.fillEllipse(in: bounds.insetBy(dx: 24, dy: 24))
}
view.layer.addSublayer(drawingLayer)
```

Keep the layer's frame in sync with your view's layout. Invalidate with
`setNeedsDisplay()` when drawing inputs change. Updating bounds or `contentsScale`
also invalidates the layer. A transform or opacity change can reuse its backing.
Use weak captures when the block refers to its owning controller or layer.

For immediate drawing in Objective-C:

```objc
NSError *error = nil;
if (![drawingLayer renderWithError:&error]) {
  NSLog(@"SCGLayer: %@", error.localizedDescription);
}
```

This consumes the pending display request. Success means that contents were
submitted, not that the GPU has finished or that a frame reached the screen.
For automatic display, inspect `lastRenderError` after the display pass. All
configuration and rendering belong on the main thread; a wrong-thread immediate
call returns an error without mutating the layer.

Subclasses may override `drawInContext:` instead of installing a drawing block.
The block takes precedence when present. Keep SCGLayer's `display` implementation
so the IOSurface path remains in use; CALayer delegate drawing is not part of this
API. `initWithLayer:` supports Core Animation's custom-property copy hook and
does not share writable pools. It is not a general view/layer geometry cloning API.

## Allocation and failures

The renderer maintains at most three BGRA8 sRGB IOSurfaces at a fixed size. It
never writes into the current front buffer and checks `IOSurfaceIsInUse` before
recycling another one. If every buffer is busy, the attempted frame is dropped
and the previous contents remain. There is no silent bitmap fallback.

Each dimension is limited to 4096 physical pixels. Nonfinite, empty, negative,
or oversized geometry is rejected. Resize retires the old pool before allocating
the new one. Core Animation can retain old surfaces, so three buffers is a bound
on the current owned pool, not total system memory during repeated resize.

`ownedSurfaceBytes` and `surfaceCount` describe that pool. `renderedFrameCount`
counts successful submissions; `droppedFrameCount` counts buffer-busy failures.
Neither counter is a presentation counter. Allocation/context errors are exposed
through `lastRenderError` and the immediate method's error argument.

`contextAPIAvailable` checks symbol availability only. Context creation can still
fail, and acceleration must be verified on the actual device/OS/workload. The
private constructor and direct IOSurface layer contents have no public stability
or synchronization contract. The experiment uses `CGContextFlush` before
publication; it does not expose a public GPU completion fence.

Flattening a scene makes independent changes redraw the whole backing. Keep
separately animated views/layers as separate compositor boundaries when useful.
Neither lower total memory nor faster rendering is guaranteed for every workload.

See the [distribution risks](../README.md#private-api-and-distribution-risks)
before using this outside a controlled experiment.
