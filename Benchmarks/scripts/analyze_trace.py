#!/usr/bin/env python3
"""Join app updates to compositor work and display swaps in an exported trace."""

import argparse
from collections import Counter
import json
from pathlib import Path
import statistics


def stats(values):
    values = sorted(values)
    if not values:
        return {"count": 0}
    return {"count": len(values), "mean": statistics.mean(values),
            "p95": values[int((len(values) - 1) * .95)], "max": values[-1]}


def analyze(folder, window=None):
    required = ["hitches-updates", "hitches-renders", "hitches-gpu",
                "hitches-frame-lifetimes", "display-surface-swap"]
    for name in required:
        if not (folder / (name + ".json")).exists():
            raise ValueError(f"Missing required export: {name}")

    def rows(name):
        path = folder / (name + ".json")
        return json.loads(path.read_text()) if path.exists() else []

    signs = [r for r in rows("os-signpost") if r.get("name") == "SteadyState"
             and r.get("subsystem") == "org.zhongyr.SCGDemo"]
    if window is None:
        begins = [int(r["time"]) for r in signs if "begin" in r["event-type"].lower()]
        ends = [int(r["time"]) for r in signs if "end" in r["event-type"].lower()]
        if len(begins) != 1 or len(ends) != 1 or ends[0] <= begins[0]:
            raise ValueError("Trace must contain exactly one complete SteadyState signpost interval")
        start, end = begins[0], ends[0]
        window_source = "SteadyState signposts"
    else:
        start, end = (int(v * 1e9) for v in window)
        if not 0 <= start < end:
            raise ValueError("Diagnostic window must satisfy 0 <= start < end")
        window_source = "explicit diagnostic window"

    def key(row):
        return row["swap-id"], row["surface-id"]

    all_updates = [r for r in rows("hitches-updates")
               if r["process"].startswith("SCGDemo ")
               and r["containment-level"] == "0"]
    updates = [r for r in all_updates if start <= int(r["start"]) < end]
    if len({r["display"] for r in updates}) > 1:
        raise ValueError("This demo analyzer requires a single display")
    update_keys = {key(r) for r in updates}
    stages = {}
    for name in ["hitches-updates", "hitches-renders", "hitches-gpu", "hitches-frame-lifetimes"]:
        selected = updates if name == "hitches-updates" else [
            r for r in rows(name) if key(r) in update_keys and r.get("containment-level", "0") == "0"]
        stages[name] = stats([int(r["duration"]) / 1e6 for r in selected])

    swaps = {key(r): r for r in rows("display-surface-swap") if key(r) in update_keys}
    swap_times = sorted({int(r["timestamp"]) for r in swaps.values()})
    intervals = [(b - a) / 1e6 for a, b in zip(swap_times, swap_times[1:])]
    latencies = [(int(swaps[key(r)]["timestamp"]) - int(r["start"])) / 1e6
                 for r in updates if key(r) in swaps]
    if any(value < 0 for value in latencies):
        raise ValueError("A display swap precedes its associated update")
    # For display cadence, select by presentation time. An update from warmup
    # may legitimately reach the display inside steady state, and vice versa.
    all_update_keys = {key(r) for r in all_updates}
    display_window = [r for r in rows("display-surface-swap")
                      if start <= int(r["timestamp"]) < end]
    steady_swap_times = sorted({int(r["timestamp"]) for r in display_window
                               if key(r) in all_update_keys})
    steady_swap_intervals = [(b - a) / 1e6
                            for a, b in zip(steady_swap_times, steady_swap_times[1:])]
    requests = [r for r in rows("os-signpost") if r.get("name") == "UpdateToCallback"
                and r.get("subsystem") == "org.zhongyr.SCGDemo"
                and r.get("event-type") == "Begin" and start <= int(r["time"]) < end]
    hitches = [r for r in rows("hitches") if r.get("process", "").startswith("SCGDemo ")
               and int(r["start"]) < end and int(r["start"]) + int(r["duration"]) > start]
    app_buffers = {r["cmdbuffer-id"]: r for r in rows("metal-command-buffer-frame-assignment")
                   if r.get("process", "").startswith("SCGDemo ")
                   and r["is-compositor"] == "0" and start <= int(r["commit-time"]) < end}
    completions = {r["cmdbuffer-id"]: int(r["timestamp"])
                   for r in rows("metal-command-buffer-completed")}
    completion_ms = [(completions[cid] - int(r["commit-time"])) / 1e6
                     for cid, r in app_buffers.items() if cid in completions]
    accesses = [r for r in rows("metal-io-surface-access")
                if r["cmdbuffer-id"] in app_buffers and r["process"].startswith("SCGDemo ")]
    surface_accesses = Counter((r["surface-id"], r["width"], r["height"], r["access-type"])
                               for r in accesses)
    metal_available = all((folder / (name + ".json")).exists() for name in [
        "metal-command-buffer-frame-assignment", "metal-command-buffer-completed",
        "metal-io-surface-access"])

    samples = [r for r in rows("time-profile") if r.get("process", "").startswith("SCGDemo ")
               and start <= int(r["time"]) < end and r["thread-state"] == "Running"]
    inclusive, leaves = Counter(), Counter()
    total_weight = sum(int(r["weight"]) for r in samples)
    for row in samples:
        frames = row.get("stack", [])
        if not isinstance(frames, list):
            continue
        weight = int(row["weight"])
        for frame in {f["binary"] + ": " + f["name"] for f in frames}:
            inclusive[frame] += weight
        if frames:
            leaves[frames[0]["binary"] + ": " + frames[0]["name"]] += weight

    def hotspots(counter):
        return [{"symbol": symbol, "sampledMS": weight / 1e6,
                 "percentOfSamples": 100 * weight / total_weight if total_weight else 0}
                for symbol, weight in counter.most_common(30)]

    return {
        "exportFolder": str(folder), "windowSource": window_source,
        "steadyStartSeconds": start / 1e9, "steadyEndSeconds": end / 1e9,
        "steadySeconds": (end - start) / 1e9,
        "stagesMS": stages, "appUpdateCount": len(updates),
        "uniqueAppSwapIDs": len(update_keys), "matchedDisplaySwapCount": len(swaps),
        "appRequestedUpdateCount": len(requests),
        "appRequestedUpdatesPerSecond": len(requests) * 1e9 / (end - start),
        "steadyDisplaySwapCount": len(steady_swap_times),
        "steadyDisplaySwapsPerSecond": len(steady_swap_times) * 1e9 / (end - start),
        "steadyDisplaySwapIntervalMS": stats(steady_swap_intervals),
        "allDisplaySwapCountWithinSteady": len(display_window),
        "unmatchedAppSwapIDs": len(update_keys - swaps.keys()),
        "displaySwapCorrelationCoverage": len(swaps) / len(update_keys) if update_keys else None,
        "displayCadenceReliable": bool(update_keys) and len(swaps) / len(update_keys) >= .9,
        "displayCadenceQualityNote": "Require at least 90% update-to-swap correlation before interpreting observed event counts as cadence. Missing events are not zero presented frames.",
        "appUpdateToDisplaySwapMS": stats(latencies),
        "appAssociatedDisplaySwapIntervalMS": stats(intervals),
        "appAssociatedDisplaySwapsPerSecond":
            (len(swap_times) - 1) * 1e9 / (swap_times[-1] - swap_times[0]) if len(swap_times) > 1 else 0,
        "instrumentHitchCount": len(hitches),
        "instrumentHitchDurationsMS": [int(r["duration"]) / 1e6 for r in hitches],
        "appMetalDataAvailable": metal_available,
        "appMetalCommandBufferCount": len(app_buffers) if metal_available else None,
        "appMetalCommitToCompletionMS": stats(completion_ms),
        "appMetalIOSurfaceAccesses": [
            {"surfaceID": key[0], "width": int(key[1]), "height": int(key[2]),
             "accessType": int(key[3]), "count": count}
            for key, count in sorted(surface_accesses.items())],
        "cpuProfileDataAvailable": (folder / "time-profile.json").exists(),
        "cpuProfileSampleCount": len(samples), "cpuProfileWeightMS": total_weight / 1e6,
        "cpuProfilePercentOfOneCore": 100 * total_weight / (end - start),
        "topInclusiveCPU": hotspots(inclusive), "topLeafCPU": hotspots(leaves),
        "limits": [
            "App update duration is a Core Animation interval, not isolated on-core CPU time.",
            "hitches-renders and hitches-gpu are overlapping render-server intervals; do not add them or treat them as isolated busy time.",
            "hitches-gpu does not include all app CGContext GPU execution; app Metal buffers are reported separately.",
            "Metal commit-to-completion includes scheduling/queue wait, not isolated GPU busy time.",
            "Display swaps are joined to app updates by swap and surface IDs on one display.",
            "Steady display cadence selects swap timestamps inside SteadyState, including warmup-origin frames presented there.",
            "Update-to-swap starts at Instruments' app-update interval, not the demo's update timer.",
            "Trace swaps are not an optical scanout measurement or proof of distinct image content; zero hitches does not imply 60 FPS.",
            "CPU samples are statistical and inclusive stacks overlap; profiling adds overhead."
        ]
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("export_folder", type=Path)
    parser.add_argument("--window", nargs=2, type=float, metavar=("START", "END"),
                        help="Diagnostic window in trace seconds; final studies use signposts")
    args = parser.parse_args()
    result = analyze(args.export_folder, args.window)
    path = args.export_folder / "analysis.json"
    path.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if not k.startswith("top")}, indent=2))
    if not result["displayCadenceReliable"]:
        raise SystemExit("Incomplete update-to-swap correlation. Diagnostics saved; do not interpret the observed event count as FPS.")


if __name__ == "__main__":
    main()
