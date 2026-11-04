# SCGLayer Lab

Open `SCGDemo.xcodeproj`, select the **SCGDemo** scheme, and run on an iOS
simulator. For a device, select your own signing team. No Pods, downloaded assets,
or other repositories are needed. The demo compiles the library's actual sources.

The three backends are a rebuilt layer tree, `UIView.drawRect:`, and `SCGLayer`.
The scene is selected with launch arguments:

```text
-scene shape -backend surface -workload repaint -count 1000
```

Scenes: `cards`, `fills`, `text`, `shape`, `gradient`.
Backends: `layers`, `draw`, `surface` (SCGLayer).
Workloads: `static`, `repaint`, `single`, `child`, `transform`, `motion`.

`repaint` changes every item. `single` changes one item and `child` moves one
item; all three rebuild the full tree or repaint the entire backing. `transform`
moves the parent view while retaining its content in all backends.

**Motion** moves every path or gradient through the same four-second wave using
elapsed time. Each update rebuilds the full layer tree or repaints the entire
CoreGraphics backing. It keeps the resource variants fixed, so movement makes
stutters visible without alternating-color flicker. This showcase is separate
from the `repaint` workload used for the archived benchmark.

The README's [path GIF](../Docs/assets/shape-comparison.gif) and
[gradient GIF](../Docs/assets/gradient-comparison.gif) are actual iPhone 12 screen
recordings. Each backend was captured separately at normal speed. GIF previews
use 25/20 fps; the companion MP4s preserve a 60 fps container with captured frames
repeated where necessary. They are visual demonstrations, not FPS measurements.
No motion interpolation or backend-specific playback speed is applied.

To reproduce on a Mac with one unlocked, trusted USB iPhone, launch the desired
scene/backend in Motion mode with 1,000 items, then record its screen without audio:

```sh
swift Demo/Tools/RecordDevice.swift out/shape-surface.mov 6
```

Record `shape` and `gradient` with `layers`, `draw`, and `surface`; name each file
`<scene>-<backend>.mov`. [RenderComparisons.py](Tools/RenderComparisons.py) crops the
iPhone 12 canvas and composes the three panels. Install `pillow` and
`imageio-ffmpeg` in a local Python environment, then run:

```sh
python Demo/Tools/RenderComparisons.py out/recordings --font /path/to/font.ttf
```

The script uses seconds 1–5 of each six-second recording and keeps playback at
1×. The checked-in [capture manifest](../Docs/assets/capture-manifest.json)
records source hashes and conversion settings. Full screen recordings stay local;
published media contains only the demo canvas and labels.

Add `-seconds 10 -warmup-seconds 3` for an automated run. It locks the controls,
pauses when complete, and writes `Documents/report.json`. Omit `-seconds` for
interactive use. `-self-test YES` runs native correctness checks before sampling;
leave it off for performance measurements.

The on-screen next-callback timing is **not presented FPS**. Use the
[trace workflow](../Benchmarks/README.md) to measure actual display cadence.

Run the simulator suite from the repository root:

```sh
python3 Benchmarks/scripts/run_simulator.py --udid <booted-simulator-UUID> --require-private
python3 -m unittest discover -s Benchmarks/scripts -p 'test_*.py'
```

The 26 simulator cases exercise all backends, vector fixtures, static/transform
reuse, forced API unavailability, and a deliberate callback stall. Native checks
cover pixel orientation, resize/scale, a bounded pool, layer-tree replacement,
even-odd holes, immediate-render invalidation, and independent backing pools for
layer copies. Simulator results establish functionality, not device acceleration.
