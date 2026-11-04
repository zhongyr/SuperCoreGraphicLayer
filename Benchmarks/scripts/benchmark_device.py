#!/usr/bin/env python3
"""Run controlled workloads on an already-installed, signed physical-device app."""

import argparse
import json
import math
from pathlib import Path
import random
import statistics
import subprocess
import time

BUNDLE = "org.zhongyr.SCGDemo"


def command(*args, check=True, timeout=60):
    return subprocess.run(args, check=check, capture_output=True, text=True, timeout=timeout)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--counts", type=int, nargs="+", default=[30, 100, 300, 1000, 3000])
    parser.add_argument("--scenes", nargs="+", choices=["fills", "text", "shape", "gradient"], default=["fills", "text"])
    parser.add_argument("--workloads", nargs="+", choices=["repaint", "single", "child", "transform"], default=["repaint"])
    parser.add_argument("--seconds", type=float, default=30)
    parser.add_argument("--warmup", type=float, default=5)
    parser.add_argument("--repeats", type=int, default=3)
    parser.add_argument("--cooldown", type=float, default=10,
                        help="Idle seconds between runs to reduce thermal drift")
    parser.add_argument("--trace", choices=["Animation Hitches", "Metal System Trace", "Time Profiler"])
    parser.add_argument("--backends", nargs="+", choices=["layers", "draw", "surface"], default=["layers", "draw", "surface"])
    args = parser.parse_args()
    if not (1 <= args.seconds <= 60 and 0 <= args.warmup <= 60 and 1 <= args.repeats <= 10):
        parser.error("Invalid duration, warmup or repeat count")
    if any(n < 1 or n > 10000 for n in args.counts):
        parser.error("Counts must be in 1..10000")
    if not 0 <= args.cooldown <= 300:
        parser.error("Cooldown must be in 0..300 seconds")
    if (args.output / "manifest.json").exists():
        parser.error("Output already contains a study; choose a new directory to preserve its evidence")
    args.output.mkdir(parents=True, exist_ok=True)
    manifest = {**vars(args), "output": str(args.output), "target": "physical iPhone",
                "seed": 1729, "startedUTC": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
    (args.output / "manifest.json").write_text(json.dumps(manifest, indent=2))
    command("xcrun", "devicectl", "device", "info", "details", "--device", args.device,
            "--json-output", str(args.output / "device.json"))
    rng = random.Random(1729)
    cases = []
    for scene in args.scenes:
        for workload in args.workloads:
            for count in args.counts:
                for repeat in range(args.repeats):
                    backends = list(args.backends)
                    rng.shuffle(backends)
                    cases.extend((scene, workload, count, repeat, b) for b in backends)
    reports = []
    for index, (scene, workload, count, repeat, backend) in enumerate(cases):
        name = f"{scene}-{workload}-{count}-{backend}-r{repeat+1}"
        report_path = args.output / f"{name}.json"
        launch_path = args.output / f"{name}-launch.json"
        # A new run ID makes stale container output impossible to accept.
        run_id = f"{name}-{time.time_ns()}"
        command("xcrun", "devicectl", "device", "process", "launch", "--device", args.device,
                "--terminate-existing", "--json-output", str(launch_path), "--", BUNDLE,
                "-backend", backend, "-scene", scene, "-workload", workload, "-count", str(count),
                "-seconds", str(args.seconds), "-warmup-seconds", str(args.warmup),
                "-self-test", "NO", "-test-stall-ms", "0", "-disable-private-api", "NO",
                "-run-id", run_id)
        launched = time.monotonic()
        if args.trace:
            pid = json.loads(launch_path.read_text())["result"]["process"]["processIdentifier"]
            trace_path = args.output / f"{name}.trace"
            cmd = ["xcrun", "xctrace", "record", "--template", args.trace, "--device", args.device,
                   "--instrument", "Points of Interest",
                   "--attach", str(pid), "--time-limit", f"{math.ceil(args.seconds + args.warmup + 2)}s",
                   "--output", str(trace_path), "--no-prompt"]
            with (args.output / f"{name}-trace.log").open("w") as log:
                result = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=args.seconds + args.warmup + 120)
            if result.returncode:
                raise SystemExit(f"Trace failed ({result.returncode}); inspect {name}-trace.log")
        remaining = args.warmup + args.seconds + 1 - (time.monotonic() - launched)
        if remaining > 0:
            time.sleep(remaining)
        deadline = time.monotonic() + 30
        while True:
            report_path.unlink(missing_ok=True)
            copied = command("xcrun", "devicectl", "device", "copy", "from", "--device", args.device,
                             "--domain-type", "appDataContainer", "--domain-identifier", BUNDLE,
                             "--source", "Documents/report.json", "--destination", str(report_path), check=False)
            if copied.returncode == 0:
                report = json.loads(report_path.read_text())
                if report.get("runID") == run_id:
                    break
            if time.monotonic() >= deadline:
                raise SystemExit(f"No completed matching report for {name}: {copied.stderr}")
            time.sleep(1)
        assert report["scene"] == scene and report["cards"] == count, name
        assert report["fixtureVersion"] == 6, name
        assert report["backend"] == {"layers": "layers", "draw": "drawRect",
                                      "surface": "SCGLayer"}[backend], name
        assert report["workload"] == workload, name
        assert report["configurationChanges"] == 0 and report["automaticControlsLocked"], name
        assert report["layerUpdatePolicy"] == "rebuild-all-content-layers", name
        if backend == "layers":
            assert report["layerTreeRebuilds"] == report["submittedFrames"], name
            assert report["layerObjectsCreated"] == report["layerTreeRebuilds"] * (count + 1), name
            assert report["layerObjectsDetached"] == (report["layerTreeRebuilds"] - 1) * (count + 1), name
            if workload != "transform":
                assert report["layerTreeRebuilds"] == report["updateAttempts"], name
        assert report["submittedFrames"] > 0 and not report["pendingInterval"], name
        assert report["cancelledIntervals"] == 0, f"Backgrounded during {name}"
        assert report["steadyIntervalCount"] > 0, name
        assert len(report["updateIntervals"]) == report["updateAttempts"], name
        assert all(i["endCallback"] == i["startCallback"] + 1 for i in report["updateIntervals"]), name
        steady = [i for i in report["updateIntervals"] if not i["warmup"]]
        assert len(steady) == report["steadyIntervalCount"], name
        report["benchmarkCase"] = name
        report["traced"] = bool(args.trace)
        report["longCallbackPercent"] = 100 * report["updateToNextCallbackOver1_5BudgetCount"] / len(steady)
        report["validThermalRun"] = report["maxThermalState"] < 2 and not report["lowPowerMode"]
        report_path.write_text(json.dumps(report, indent=2) + "\n")
        reports.append(report)
        (args.output / "results.json").write_text(json.dumps(reports, indent=2) + "\n")
        print(f"[{index+1}/{len(cases)}] {name}: callback p95={report['updateToNextCallbackP95MS']:.2f}ms "
              f"long={report['longCallbackPercent']:.1f}% CPU={report.get('processCPUPercentOfOneCore', 0):.1f}% "
              f"footprint={report['processFootprintMiB']:.1f}MiB thermal={report['maxThermalState']}", flush=True)
        if not report["validThermalRun"]:
            raise SystemExit("Thermal state >= serious or Low Power Mode; recorded run is invalid. Cool device before continuing.")
        time.sleep(args.cooldown)
    rows = []
    keys = ["updateToNextCallbackMeanMS", "updateToNextCallbackP95MS", "longCallbackPercent",
            "processCPUPercentOfOneCore", "encodeMeanMS", "processFootprintMiB", "ownedIOSurfaceBytes"]
    groups = sorted({(r["scene"], r["workload"], r["cards"], r["backend"]) for r in reports})
    for scene, workload, count, backend in groups:
        group = [r for r in reports if (r["scene"], r["workload"], r["cards"], r["backend"]) == (scene, workload, count, backend)]
        rows.append({"scene": scene, "workload": workload, "count": count, "backend": backend,
                     "repeats": len(group), **{k: statistics.median(r[k] for r in group) for k in keys}})
    (args.output / "summary.json").write_text(json.dumps(rows, indent=2) + "\n")
    print(f"Completed {len(reports)} runs: {args.output}", flush=True)


if __name__ == "__main__":
    main()
