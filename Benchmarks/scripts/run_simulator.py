#!/usr/bin/env python3
"""Build and exercise the native probe, preserving reports and screenshots."""

import argparse
import json
from pathlib import Path
import subprocess
import time


def run(*args, check=True):
    return subprocess.run(args, check=check, capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udid", default="booted", help="Boot a simulator first, or supply its UDID")
    parser.add_argument("--seconds", type=float, default=3)
    parser.add_argument("--require-private", action="store_true")
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 30:
        parser.error("--seconds must be between 1 and 30")
    root = Path(__file__).resolve().parents[2]
    source = root / "Demo"
    output = args.output.resolve() if args.output else root / "out/validation"
    output.mkdir(parents=True, exist_ok=True)
    build = run("xcodebuild", "-project", str(source / "SCGDemo.xcodeproj"),
                "-scheme", "SCGDemo", "-configuration", "Release", "-sdk", "iphonesimulator",
                "-derivedDataPath", str(output), "CODE_SIGNING_ALLOWED=NO", "build", check=False)
    (output / "build.log").write_text(build.stdout + build.stderr)
    if build.returncode:
        raise SystemExit(f"Build failed: {output / 'build.log'}")
    app = output / "Build/Products/Release-iphonesimulator/SCGDemo.app"
    simctl = ("xcrun", "simctl")
    bundle = "org.zhongyr.SCGDemo"
    run(*simctl, "install", args.udid, str(app))
    container = Path(run(*simctl, "get_app_container", args.udid, bundle, "data").stdout.strip())
    report_path = container / "Documents/report.json"
    results = []
    cases = [(backend, workload, 30, False, 0) for backend in ("layers", "draw", "surface")
             for workload in ("static", "repaint", "transform")]
    cases += [(backend, "repaint", 1000, False, 0) for backend in ("layers", "draw", "surface")]
    cases += [("surface", "static", 30, True, 0)]
    # The injected wait is outside encode timing, but must appear in the wider interval.
    cases += [("draw", "repaint", 30, False, 40)]
    cases = [(*case, "cards") for case in cases]
    cases += [(backend, workload, 30, False, 0, scene)
              for scene in ("shape", "gradient") for backend in ("layers", "draw", "surface")
              for workload in ("static", "repaint")]
    for backend, workload, count, disabled, stall_ms, scene in cases:
        name = f"{backend}-{workload}-{count}" + ("-disabled" if disabled else "")
        if scene != "cards":
            name = scene + "-" + name
        if stall_ms:
            name += f"-stall-{stall_ms}ms"
        run(*simctl, "terminate", args.udid, bundle, check=False)
        report_path.unlink(missing_ok=True)
        run(*simctl, "launch", args.udid, bundle, "-backend", backend, "-workload", workload,
            "-scene", scene, "-warmup-seconds", "0",
            "-count", str(count), "-seconds", str(args.seconds), "-self-test", "YES",
            "-disable-private-api", "YES" if disabled else "NO", "-test-stall-ms", str(stall_ms))
        deadline = time.monotonic() + args.seconds + 20
        while not report_path.exists():
            if time.monotonic() >= deadline:
                raise SystemExit(f"No report for {name}: app failed to launch or complete")
            time.sleep(0.25)
        report = json.loads(report_path.read_text())
        (output / f"{name}.json").write_text(json.dumps(report, indent=2) + "\n")
        run(*simctl, "io", args.udid, "screenshot", str(output / f"{name}.png"))
        checks = report["checks"]
        assert checks["fixedFixture"], report
        assert checks["layerTreeRebuilt"], report
        assert report["fixtureVersion"] == 6 and report["scene"] == scene, report
        assert report["backend"] == {"layers": "layers", "draw": "drawRect",
                                      "surface": "SCGLayer"}[backend], name
        assert report["workload"] == workload, name
        assert report["configurationChanges"] == 0 and report["automaticControlsLocked"], name
        if backend == "layers":
            assert report["layerTreeRebuilds"] == report["submittedFrames"], name
            if workload == "repaint":
                assert report["layerTreeRebuilds"] == report["updateAttempts"], name
        assert checks["disabledAPIRejected"], report
        assert checks["invalidSizeRejected"], report
        if checks["contextCreated"]:
            assert checks["publicLayer"], (name, checks)
            for key in ("pixelParity", "resizeAndScale", "poolBounded"):
                assert checks[key], (name, key, report)
        elif args.require_private and not disabled:
            raise SystemExit(f"Private CGContext unavailable: {report}")
        assert report["ownedSurfaceCount"] <= 3, report
        assert report["measurementVersion"] == 2, report
        assert not report["pendingInterval"], name
        assert report["cancelledIntervals"] == 0, name
        intervals = report["updateIntervals"]
        assert len(intervals) == report["updateAttempts"] > 0, name
        for interval in intervals:
            assert interval["endCallback"] == interval["startCallback"] + 1, interval
            elapsed = (interval["nextCallbackSeconds"] - interval["startSeconds"]) * 1000
            assert elapsed > 0 and abs(elapsed - interval["elapsedMS"]) < 0.001, interval
        expected_mean = sum(i["elapsedMS"] for i in intervals) / len(intervals)
        assert abs(expected_mean - report["updateToNextCallbackMeanMS"]) < 0.001, name
        expected_long = sum(i["elapsedMS"] > 1.5 * i["expectedIntervalMS"]
                            for i in intervals if i["expectedIntervalMS"] > 0)
        assert expected_long == report["updateToNextCallbackOver1_5BudgetCount"], name
        if workload == "static":
            assert len(intervals) == 1, name  # Idle callbacks must not become update samples.
        if stall_ms:
            assert all(i["elapsedMS"] >= stall_ms for i in intervals), name
            assert report["updateToNextCallbackOver1_5BudgetCount"] > 0, name
        if disabled:
            assert report["submittedFrames"] == 0 and report["ownedIOSurfaceBytes"] == 0, report
        elif backend != "surface" or checks["contextCreated"]:
            assert report["submittedFrames"] > 0, report
            if workload != "repaint":
                assert report["submittedFrames"] <= 2, report
        results.append({"case": name, **report})
        print(f"{name}: next-callback mean/p95="
              f"{report['updateToNextCallbackMeanMS']:.3f}/{report['updateToNextCallbackP95MS']:.3f} ms, "
              f"encode={report['encodeMeanMS']:.3f} ms, "
              f"footprint={report['processFootprintMiB']:.1f} MiB, "
              f"surfaces={report['ownedSurfaceCount']}", flush=True)
    (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
    print(f"Passed {len(results)} cases. Simulator functionality only. Artifacts: {output}")


if __name__ == "__main__":
    main()
