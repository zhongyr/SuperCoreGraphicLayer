# Measurements and reproduction

The [current device dataset](results/scglayer-v6/summary.json) measures the
standalone demo through SCGLayer's public interface: **fixture version 6**.
It includes six physical-device functional cases, twelve uninstrumented runs,
and five traces with validated display-swap correlation. The source commit,
source hashes, and signed executable hash are preserved in the summary.

The [original presenter experiment](results/presenter-v5/README.md) is archived
separately as fixture 5. Its results are not combined with this library study.

## Device experiment

2026-11-04 · iPhone 12 / A14 · iOS 27.2 beta (24B5110a) · Release · target 60 Hz.
Canvas: 358×447 points at 3× (1074×1341 pixels). There are 1,000 items plus a
background. The layer backend detaches every previous content layer, allocates
every replacement, and inserts the entire tree on each update.

| Scene | Backend | Display swaps/s | Swap spacing p95 | Next callback p95, same trace |
| --- | --- | ---: | ---: | ---: |
| Complex path | CAShapeLayer tree | 5.00 | 350.27 ms | 16.81 ms |
| Complex path | drawRect | 5.94 | 183.42 ms | 175.70 ms |
| Complex path | SCGLayer | 59.98 | 16.68 ms | 16.75 ms |
| Linear gradient | CAGradientLayer tree | **Unavailable** | Incomplete trace | Incomplete trace |
| Linear gradient | drawRect | 48.89 | 33.37 ms | 20.29 ms |
| Linear gradient | SCGLayer | 59.58 | 16.68 ms | 16.75 ms |

Actual trace values, stage intervals, Metal command buffers, and correlation
counts are in [traces.json](results/scglayer-v6/traces.json). All retained traces
passed the update-to-swap correlation threshold. These are app-associated display
events from Instruments, not optical scanout measurements or proof that every
swap has different pixels. Incomplete captures from this study are preserved in
[excluded-traces.json](results/scglayer-v6/excluded-traces.json); a failed device
launch is recorded in [capture-attempts.json](results/scglayer-v6/capture-attempts.json).
No cadence result is assigned to a failed launch or an incomplete capture.

The CAGradientLayer capture was repeated with only Core Animation Commits,
Core Animation Server, Frame Lifetimes, Display, and Points of Interest instruments
to reduce collection overhead. Its different schemas did not provide the app-associated
records required by this study's correlation check. Its process measurements remain
available below; its display cadence is unknown. This is a capture limitation,
not a measured low FPS result.

### Separate process measurements

Two uninstrumented runs per condition: 3 s warmup, 10 s sampling, 25 s idle
between runs, fresh processes, shuffled backend order with seed 1729. Values below
are medians. The per-run values are in
[runs.json](results/scglayer-v6/runs.json), which links each run's timestamp CSV in
[intervals](results/scglayer-v6/intervals); ranges are in
[summary.json](results/scglayer-v6/summary.json) and [CSV](results/scglayer-v6/summary.csv).

| Scene | Backend | App CPU, % of one core | End-of-run App footprint |
| --- | --- | ---: | ---: |
| Complex path | CAShapeLayer tree | 58.8% | 7.2 MiB |
| Complex path | drawRect | 97.8% | 24.2 MiB |
| Complex path | SCGLayer | 71.4% | 79.5 MiB |
| Linear gradient | CAGradientLayer tree | 55.7% | 7.2 MiB |
| Linear gradient | drawRect | 100.1% | 24.0 MiB |
| Linear gradient | SCGLayer | 47.4% | 34.2 MiB |

CPU is the process user+system delta divided by steady wall time; it excludes
render-server CPU. Footprint is a snapshot including benchmark bookkeeping,
not a peak or total system graphics memory measurement. Owned surface bytes can
already be charged to footprint and must not simply be added to it. The measured
three-buffer pool owned about 16.7 MiB. Pool bytes account for only part of each App footprint.

All included runs locked configuration controls, had no configuration changes
or cancelled intervals, and had Low Power Mode disabled. Thermal state remained
nominal/fair (0/1). This does not establish identical frequencies. Two repeats
and one trace per condition do not establish statistical confidence intervals.

## Device validation

The installed Release app passed all six shape/gradient × backend functional
cases. The native checks passed for context creation, red/blue pixel parity and
orientation, invalid bounds, disabled-API errors, resize/scale, bounded buffers,
fixed fixtures, full layer-tree replacement, and public SCGLayer behavior.
The public-layer check also exercises immediate rendering, invalidation, and
independent pools when copying a layer. [Functional records →](results/scglayer-v6/functional.json)

The first functional case began cold with no warmup and recorded two busy-buffer
skips. All native checks passed. The initial local harness incorrectly required
zero skips; this assertion was removed because a busy bounded pool is documented
to skip an update. No renderer code was changed, and the original counts remain
in the records. `poolDroppedFrames` includes warmup and automatic display passes;
it is not a count of missing display frames. The summary records these counters
separately for instrumented and uninstrumented runs. Actual cadence comes from
the display trace.

SCGLayer busy-buffer counters (including warmup): complex paths: 0–0 across the two process runs, 0 in the trace run; linear gradients: 0–2 across the two process runs, 8 in the trace run.

### Drawing workload

The `drawRect` and SCGLayer backends both call the same `DemoScene::draw`
CoreGraphics routine, with the same geometry, resource variants, and draw order.
`drawRect` obtains its context from `UIGraphicsGetCurrentContext()` inside UIKit's
drawing callback. SCGLayer creates its own IOSurface-backed context with
the private constructor, flushes drawing, and publishes the surface as contents.
The comparison therefore changes the context/presentation path while keeping
the scene drawing code the same. The CAShapeLayer tree is a separate reference.

For complex paths, the measured display cadence ratio is
59.9761 / 5.9432 ≈ 10.1× versus `drawRect`; for linear gradients
it is 59.5751 / 48.8894 ≈ 1.22×. Ratios use the unrounded trace rates.
These are presentation-rate ratios for the recorded workload, not isolated GPU
speedups or guarantees about every CoreGraphics operation.

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

### Where the path workload spends time

In the CAShapeLayer trace, the app requested 59.95 updates/s while
display swaps reached 5.00/s. The following mean intervals locate the slow
stages; they are overlapping wall-clock intervals, not additive CPU/GPU busy times.

| Path backend | App-update interval | Render-server interval | Render-server GPU interval |
| --- | ---: | ---: | ---: |
| CAShapeLayer tree | 11.85 ms | 179.29 ms | 119.64 ms |
| drawRect | 166.13 ms | 3.38 ms | 0.49 ms |
| SCGLayer | 12.43 ms | 4.65 ms | 0.65 ms |

The last column excludes the app's CGContext GPU work. SCGLayer's path trace also
recorded 2,400 app Metal command buffers, accessing three canvas-sized
IOSurfaces; their mean commit-to-completion was
6.21 ms, including queueing and scheduling. This confirms GPU work
in the measured context path; it does not establish that every CGContext operation
is GPU accelerated. `drawRect` recorded no app Metal buffers in this particular run.

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
This beta-device capture worked with Xcode 26.3. Exporter failures were
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
