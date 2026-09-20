"""Frozen 9C.4 production Repository Release resource matrix."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).parent))
from run import generate


COUNTS = [10_000, 50_000, 100_000, 200_000]
FORMATS = ["fixture.xml", "fixture.xml.gz"]
MODES = ["cold", "warm"]
METRICS = ["rssDelta", "footprintDelta"]


def maximum(records, count, mode, gzip_value, metric):
    return max(
        record[metric]
        for record in records
        if record["count"] == count
        and record["mode"] == mode
        and record["gzip"] == gzip_value
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    arguments.output.mkdir(parents=True, exist_ok=False)

    binary = arguments.bundle / "Contents/MacOS/OKVideoKitPackageTests"
    if not binary.is_file():
        raise SystemExit(f"missing Release test binary: {binary}")
    fixtures = {count: generate(arguments.output / str(count), count) for count in COUNTS}
    machine = subprocess.check_output(
        ["/usr/sbin/system_profiler", "SPHardwareDataType"], text=True
    )
    machine = "\n".join(
        line for line in machine.splitlines()
        if not any(value in line for value in ["Serial Number", "UUID", "UDID"])
    )
    manifest = {
        "binarySHA256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "machine": machine,
        "os": subprocess.check_output(["/usr/bin/sw_vers"], text=True),
        "xcode": subprocess.check_output(
            ["/Volumes/XcodeDev/Xcode.app/Contents/Developer/usr/bin/xcodebuild", "-version"],
            text=True,
        ),
        "startedUTC": datetime.now(timezone.utc).isoformat(),
        "protocol": "9C.4 production v1",
        "sampling": {
            "memoryMilliseconds": 10,
            "diskAndFDMilliseconds": 100,
            "peakWindowEndsSecondsAfterDrain": 1,
            "settledSecondsAfterDrain": 5,
            "cold": "new process/new SQLite; baseline after production service initialization",
            "warm": "same process with active generation and maintenance drained before baseline",
        },
        "fixtures": fixtures,
    }
    (arguments.output / "manifest.json").write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False)
    )

    records = []
    selector = (
        "OKVideoPersistenceTests.EPGImportResourceTests/"
        "testReleaseProductionResourceGate"
    )
    for count in COUNTS:
        fixture = fixtures[count]
        root = arguments.output / str(count)
        server = subprocess.Popen(
            ["/usr/bin/python3", str(Path(__file__).with_name("server.py")), str(root)]
        )
        try:
            for _ in range(500):
                if (root / "port").exists():
                    break
                time.sleep(0.01)
            port = (root / "port").read_text().strip()
            for name in FORMATS:
                for mode in MODES:
                    for repeat in range(1, 4):
                        label = f"{count}-{name}-{mode}-{repeat}"
                        output = arguments.output / f"{label}.json"
                        environment = dict(
                            os.environ,
                            EPG9C4_URL=f"http://127.0.0.1:{port}/{name}",
                            EPG9C4_COUNT=str(count),
                            EPG9C4_OUTPUT=str(output),
                            EPG9C4_DIGEST=fixture["digest"],
                            EPG9C4_MODE=mode,
                        )
                        command = [
                            "/Volumes/XcodeDev/Xcode.app/Contents/Developer/usr/bin/xctest",
                            "-XCTest",
                            selector,
                            str(arguments.bundle),
                        ]
                        with (arguments.output / f"{label}.log").open("w") as log:
                            run = subprocess.run(
                                command,
                                env=environment,
                                stdout=log,
                                stderr=subprocess.STDOUT,
                                timeout=360,
                            )
                        value = json.loads(output.read_text()) if output.exists() else {}
                        record = {"label": label, "exit": run.returncode, **value}
                        records.append(record)
                        (arguments.output / "results.json").write_text(
                            json.dumps(records, indent=2)
                        )
                        print(
                            label,
                            "exit", run.returncode,
                            "rss", value.get("rssDelta"),
                            "footprint", value.get("footprintDelta"),
                            flush=True,
                        )
                        if run.returncode:
                            raise RuntimeError("production gate failed; retain evidence")
        finally:
            server.terminate()
            server.wait()

    scale_checks = []
    for mode in MODES:
        for gzip_value in [False, True]:
            for metric in METRICS:
                smaller = maximum(records, 50_000, mode, gzip_value, metric)
                larger = maximum(records, 200_000, mode, gzip_value, metric)
                delta = larger - smaller
                scale_checks.append({
                    "mode": mode,
                    "gzip": gzip_value,
                    "metric": metric,
                    "from50000": smaller,
                    "to200000": larger,
                    "scaleDelta": delta,
                    "passed": delta <= 8 * 1_024 * 1_024,
                })
    (arguments.output / "scale-checks.json").write_text(
        json.dumps(scale_checks, indent=2)
    )
    if not all(check["passed"] for check in scale_checks):
        raise RuntimeError("production scale memory gate failed")

    groups = []
    for count in COUNTS:
        for gzip_value in [False, True]:
            for mode in MODES:
                group = [
                    record for record in records
                    if record["count"] == count
                    and record["gzip"] == gzip_value
                    and record["mode"] == mode
                ]
                groups.append({
                    "count": count,
                    "gzip": gzip_value,
                    "mode": mode,
                    "rssMax": max(item["rssDelta"] for item in group),
                    "rssMedian": statistics.median(item["rssDelta"] for item in group),
                    "footprintMax": max(item["footprintDelta"] for item in group),
                    "footprintMedian": statistics.median(item["footprintDelta"] for item in group),
                    "rssSettledDeltaMax": max(item["rssSettledDelta"] for item in group),
                    "footprintSettledDeltaMax": max(item["footprintSettledDelta"] for item in group),
                })
    summary = {
        "groups": groups,
        "maxRssDelta": max(item["rssDelta"] for item in records),
        "maxFootprintDelta": max(item["footprintDelta"] for item in records),
        "maxDiskBytes": max(item["diskPeak"] for item in records),
        "maxFD": max(item["fdPeak"] for item in records),
        "maxConcurrentNowP95": max(item["concurrentNowP95"] for item in records),
        "maxConcurrentWindowP95": max(item["concurrentWindowP95"] for item in records),
    }
    (arguments.output / "summary.json").write_text(json.dumps(summary, indent=2))
    print("48 independent 9C.4 production Release runs passed", flush=True)


if __name__ == "__main__":
    main()
