#!/usr/bin/env python3
"""Export Instruments tables; preserve retry failures rather than invent missing data."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import xml.etree.ElementTree as ET


def decode(path):
    tree = ET.parse(path)
    ids = {e.attrib["id"]: e for e in tree.iter() if "id" in e.attrib}
    result = []
    columns = []
    # xctrace omits repeated schemas from later matching tables in the same export.
    for table in tree.findall(".//node"):
        schema = table.find("schema")
        if schema is not None:
            columns = [c.findtext("mnemonic") for c in schema.findall("col")]
        if not columns:
            raise ValueError(f"No schema for exported table in {path}")
        for row in table.findall("row"):
            values = {}
            for key, cell in zip(columns, list(row)):
                cell = ids.get(cell.get("ref"), cell)
                if cell.tag == "backtrace":
                    frames = []
                    for frame in cell:
                        frame = ids.get(frame.get("ref"), frame)
                        binary = frame.find("binary")
                        if binary is not None:
                            binary = ids.get(binary.get("ref"), binary)
                        frames.append({"name": frame.get("name", frame.get("addr", "")),
                                       "binary": binary.get("name", "") if binary is not None else ""})
                    values[key] = frames
                else:
                    values[key] = (cell.text or "").strip() or cell.get("fmt", "")
            result.append(values)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--schemas", nargs="+")
    args = parser.parse_args()
    output = args.trace.with_name(args.trace.stem + "-export")
    output.mkdir(exist_ok=True)
    error_path = output / "export-errors.json"
    errors = json.loads(error_path.read_text()) if error_path.exists() else []
    # These installed exporters can read the recordings. Some versions crash in
    # XRRemoteDevice's symbol loading; retrying another installed version works.
    developers = [os.environ.get("DEVELOPER_DIR", "")] + [
        str(p / "Contents/Developer") for p in sorted(Path("/Applications").glob("Xcode*.app"))]
    developers = list(dict.fromkeys(d for d in developers if d and Path(d).exists()))
    if not developers:
        developers = [os.environ.get("DEVELOPER_DIR", "")]

    def export(name, selector):
        path = output / name
        if path.exists() and path.stat().st_size:
            try:
                ET.parse(path)
                return path
            except ET.ParseError:
                pass
        for attempt in range(6):
            path.unlink(missing_ok=True)
            env = dict(os.environ)
            developer = developers[attempt % len(developers)]
            if developer:
                env["DEVELOPER_DIR"] = developer
            cmd = ["xcrun", "xctrace", "export", "--input", str(args.trace),
                   *selector, "--output", str(path)]
            try:
                r = subprocess.run(cmd, capture_output=True, text=True, timeout=90, env=env)
                if r.returncode == 0:
                    ET.parse(path)
                    return path
                errors.append({"table": name, "developer": developer, "exit": r.returncode,
                               "stderr": r.stderr[-1500:]})
            except (subprocess.TimeoutExpired, ET.ParseError) as error:
                errors.append({"table": name, "error": str(error)})
        return None

    toc = export("toc.xml", ["--toc"])
    if toc is None:
        (output / "export-errors.json").write_text(json.dumps(errors, indent=2))
        raise SystemExit("Unable to export table of contents")
    tree = ET.parse(toc)
    available = sorted({e.get("schema") for e in tree.findall(".//table")})
    selected = args.schemas or [s for s in available if s.startswith("hitches") or
                               s in ["os-signpost", "os-signpost-interval", "points-of-interest",
                                     "display-surface-swap", "time-profile",
                                     "metal-command-buffer-frame-assignment",
                                     "metal-command-buffer-completed", "metal-io-surface-access"]]
    summary = {"trace": str(args.trace), "availableSchemas": available,
               "durationSeconds": tree.findtext(".//summary/duration"),
               "endReason": tree.findtext(".//summary/end-reason"), "tables": {}}
    summary_path = output / "export-summary.json"
    if summary_path.exists():
        summary["tables"] = json.loads(summary_path.read_text()).get("tables", {})
    for schema in selected:
        if schema not in available:
            continue
        path = export(schema + ".xml", ["--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'])
        if path is None:
            summary["tables"][schema] = {"error": "export failed"}
            continue
        rows = decode(path)
        (output / (schema + ".json")).write_text(json.dumps(rows, indent=2) + "\n")
        summary["tables"][schema] = {"rows": len(rows)}
        print(args.trace.name, schema, len(rows), flush=True)
    (output / "export-errors.json").write_text(json.dumps(errors, indent=2) + "\n")
    (output / "export-summary.json").write_text(json.dumps(summary, indent=2) + "\n")


if __name__ == "__main__":
    main()
