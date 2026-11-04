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
Workloads: `static`, `repaint`, `single`, `child`, `transform`.

`repaint` changes every item. `single` changes one item and `child` moves one
item; all three rebuild the full tree or repaint the entire backing. `transform`
moves the parent view while retaining its content in all backends.

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
