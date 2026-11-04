# Measurements and reproduction

The [archived dataset](results/presenter-v5/summary.json) measures the original
IOSurface presenter that was extracted into SCGLayer. It is **fixture version 5**.
The standalone library demo is **version 6**: it removes the original display-list
dependency and uses SCGLayer's public interface. Do not silently combine their
measurements. The packaged library has passed simulator functionality checks;
the archived device performance numbers belong to the presenter experiment.

## Device experiment

2026-11-04 · iPhone 12 / A14 · iOS 27.2 beta (24B5110a) · Release · target 60 Hz.
Canvas: 358×447 points at 3× (1074×1341 pixels). There are 1,000 items plus a
background. The layer backend detaches every previous content layer, allocates
every replacement, and inserts the entire tree on each update.

| Scene | Backend | Display swaps/s | Swap spacing p95 | Next callback p95, same trace |
| --- | --- | ---: | ---: | ---: |
| Complex path | CAShapeLayer tree | 6.00 | 183.50 ms | 16.81 ms |
| Complex path | drawRect | 5.77 | 183.62 ms | 183.69 ms |
| Complex path | IOSurface presenter | 59.78 | 16.70 ms | 16.73 ms |
| Linear gradient | CAGradientLayer tree | **Unavailable** | Incomplete trace | Incomplete trace |
| Linear gradient | drawRect | 47.18 | 33.37 ms | 20.42 ms |
| Linear gradient | IOSurface presenter | 59.29 | 16.70 ms | 16.76 ms |

Actual trace values, stage intervals, Metal command buffers, and correlation
counts are in [traces.json](results/presenter-v5/traces.json). These are
app-associated display events from Instruments, not optical scanout measurements
or proof that every swap has different pixels.

The excluded gradient-layer trace had 269 steady app updates but only one
associated display-swap record, with long gaps in that event stream. Its observed
event count is **not** a valid FPS result. The exclusion is preserved in
[excluded-traces.json](results/presenter-v5/excluded-traces.json). A subsequent
capture failed to finalize. No missing events were replaced with zeros or inferred
from callback timing.

### Separate process measurements

Two uninstrumented runs per condition: 3 s warmup, 10 s sampling, 25 s idle
between runs, fresh processes, shuffled backend order with seed 1729. Values below
are medians. The per-run values are in
[runs.json](results/presenter-v5/runs.json), which links each run's timestamp CSV in
[intervals](results/presenter-v5/intervals); ranges are in
[summary.json](results/presenter-v5/summary.json) and [CSV](results/presenter-v5/summary.csv).

| Scene | Backend | App CPU, % of one core | End-of-run App footprint |
| --- | --- | ---: | ---: |
| Complex path | CAShapeLayer tree | 59.0% | 7.3 MiB |
| Complex path | drawRect | 97.8% | 21.1 MiB |
| Complex path | IOSurface presenter | 70.3% | 81.7 MiB |
| Linear gradient | CAGradientLayer tree | 55.2% | 7.2 MiB |
| Linear gradient | drawRect | 100.2% | 24.0 MiB |
| Linear gradient | IOSurface presenter | 48.0% | 33.3 MiB |

CPU is the process user+system delta divided by steady wall time; it excludes
render-server CPU. Footprint is a snapshot including benchmark bookkeeping,
not a peak or total system graphics memory measurement. Owned surface bytes can
already be charged to footprint and must not simply be added to it. The measured
three-buffer pool owned about 16.7 MiB. Pool bytes account for only part of each App footprint.

All included runs locked configuration controls, had no configuration changes
or cancelled intervals, and had Low Power Mode disabled. Thermal state remained
nominal/fair (0/1). This does not establish identical frequencies. Two repeats
and one trace per condition do not establish statistical confidence intervals.

### Drawing workload

The `drawRect` and IOSurface backends both call the same `DemoScene::draw`
CoreGraphics routine, with the same geometry, resource variants, and draw order.
`drawRect` obtains its context from `UIGraphicsGetCurrentContext()` inside UIKit's
drawing callback. The presenter creates its own IOSurface-backed context with
the private constructor, flushes drawing, and publishes the surface as contents.
The comparison therefore changes the context/presentation path while keeping
the scene drawing code the same. The CAShapeLayer tree is a separate reference.

For complex paths, the measured display cadence ratio is 59.7816 / 5.7668 ≈ 10.4×
versus `drawRect`; for linear gradients it is 59.2859 / 47.1818 ≈ 1.26×. Ratios use
the unrounded trace rates. These are presentation-rate ratios for the recorded
workload, not isolated GPU speedups or guarantees about every CoreGraphics operation.

- **Shape:** opaque 24×24 pt path, 16 cubic outer segments, a four-segment
  elliptical hole, even-odd fill, and a 1.25 pt white round stroke.
- **Gradient:** opaque 24×24 pt rectangle, three sRGB stops at 0, 0.4, 1 along
  a diagonal axis. Earlier rectangles can be occluded at high counts; renderers
  may optimize that work differently.
- All backends share two immutable resource variants. Every update alternates
  their geometry/color by revision. Resource construction is cached, while all
  layer objects are rebuilt. This does not measure unique uncached path creation,
  arbitrary SVG, radial gradients, masks, or shadows. Alternating resources can
  visually alias when frames are skipped.

### Why next callback is insufficient

The demo timer starts immediately before constructing/mutating a scene and ends
as the first operation in the next executed CADisplayLink callback. It includes
deferred app drawing, callback delays, and refresh waiting. It is retained as an
App responsiveness metric; it is not a completion or presentation fence.

The trace joins app updates to render-server stages and display swaps by swap ID
and surface ID on one display. Display cadence selects **swap timestamps inside
the SteadyState interval**, including warmup-origin frames presented there.
Stage statistics instead select updates beginning inside that interval.
The analyzer requires at least 90% update-to-swap correlation before accepting
its observed event count as display cadence, and saves diagnostics on failure.

Render-server render/GPU wall intervals overlap and must not be added or treated
as isolated busy time. The App's CGContext Metal buffers are reported separately;
commit-to-completion includes queueing and scheduling. Profiling also adds overhead,
so trace and uninstrumented process measurements are kept separate.

## Run the standalone version

Build and install a signed Release Demo first, then run from the repository root:

```sh
python3 Benchmarks/scripts/benchmark_device.py \
  --device <iPhone-UDID> --output out/my-study \
  --scenes shape gradient --counts 1000 \
  --seconds 10 --warmup 3 --repeats 2 --cooldown 25
```

Choose a new output directory for each study. The runner checks fixture version,
configuration, complete callback intervals, thermal state, and full layer-tree
rebuild counters. It rejects serious/critical thermal state or Low Power Mode.

For a separate instrumented run:

```sh
python3 Benchmarks/scripts/benchmark_device.py \
  --device <iPhone-UDID> --output out/my-traces \
  --scenes shape gradient --counts 1000 \
  --seconds 8 --warmup 12 --repeats 1 --cooldown 25 \
  --trace "Animation Hitches"

python3 Benchmarks/scripts/export_trace.py out/my-traces/shape-repaint-1000-surface-r1.trace
python3 Benchmarks/scripts/analyze_trace.py out/my-traces/shape-repaint-1000-surface-r1-export
```

Use an Xcode version compatible with the device; `DEVELOPER_DIR` selects it.
The original beta-device capture worked with Xcode 26.3. Exporter failures were
observed in installed Xcode versions, so the helper preserves errors and retries
available exporters. Missing tables or incomplete signpost windows fail analysis.

The records checked into this repository contain exported numeric measurements
without device identifiers or local filesystem paths. Full Instruments bundles
remain local and are excluded by `.gitignore`.

To reproduce the README plot in an optional Python environment:

```sh
python3 -m venv out/plot-env
out/plot-env/bin/pip install matplotlib
out/plot-env/bin/python Benchmarks/scripts/render_chart.py
```
