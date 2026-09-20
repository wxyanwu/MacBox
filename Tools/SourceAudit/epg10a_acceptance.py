#!/usr/bin/env python3
"""Aggregate the independent EPG 10A Release query and AppKit runs."""

from __future__ import annotations

import argparse
import json
import statistics
from pathlib import Path


MIB = 1024 * 1024


def load(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def median(values: list[float]) -> float:
    return float(statistics.median(values))


def mib(value: int | float) -> float:
    return float(value) / MIB


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve()
    app_paths = sorted(root.glob("app-run-*.json"))
    query_paths = sorted(root.glob("query-run-*.json"))
    if len(app_paths) != 3 or len(query_paths) != 3:
        raise SystemExit("expected exactly three App and three query result files")
    apps = [load(path) for path in app_paths]
    queries = [load(path) for path in query_paths]

    binary_hashes = {item["binarySHA256"] for item in apps}
    fixture_hashes = {item["fixtureSHA256"] for item in apps}
    if len(binary_hashes) != 1 or len(fixture_hashes) != 1:
        raise SystemExit("Release binary or fixture identity changed between runs")

    app_checks = {
        "firstVisibleDrawP95Milliseconds": max(
            item["firstVisibleDrawMilliseconds"] for item in apps
        ),
        "drawP95Milliseconds": max(item["drawP95Milliseconds"] for item in apps),
        "frameIntervalP95Milliseconds": max(
            item["frameIntervalP95Milliseconds"] for item in apps
        ),
        "rssPeakDeltaBytes": max(item["rssPeakDeltaBytes"] for item in apps),
        "mainDispatchDelayOver100Milliseconds": sum(
            item["mainDispatchDelayOver100Milliseconds"] for item in apps
        ),
    }
    passed = (
        app_checks["firstVisibleDrawP95Milliseconds"] <= 500
        and app_checks["drawP95Milliseconds"] <= 25
        and app_checks["frameIntervalP95Milliseconds"] <= 25
        and app_checks["rssPeakDeltaBytes"] <= 32 * MIB
        and app_checks["mainDispatchDelayOver100Milliseconds"] == 0
    )

    matrices = [item["matrix"] for item in queries]
    keys = {
        (entry["channelCount"], entry["programmeCount"])
        for matrix in matrices
        for entry in matrix
    }
    if len(keys) != 12 or any(len(matrix) != 12 for matrix in matrices):
        raise SystemExit("query matrix must contain 100/500/1000 x 10K/50K/100K/200K")
    query_summary = []
    for channel_count, programme_count in sorted(keys):
        samples = [
            next(
                entry
                for entry in matrix
                if entry["channelCount"] == channel_count
                and entry["programmeCount"] == programme_count
            )
            for matrix in matrices
        ]
        record = {
            "channelCount": channel_count,
            "programmeCount": programme_count,
            "windowP95MaximumMilliseconds": max(
                item["windowP95Milliseconds"] for item in samples
            ),
            "windowP95MedianMilliseconds": median(
                [item["windowP95Milliseconds"] for item in samples]
            ),
            "windowSingleMaximumMilliseconds": max(
                item["windowMaximumMilliseconds"] for item in samples
            ),
            "samplesPerRun": samples[0]["sampleCount"],
        }
        if (
            record["windowP95MaximumMilliseconds"] > 10
            or record["windowSingleMaximumMilliseconds"] > 50
        ):
            passed = False
        query_summary.append(record)

    summary = {
        "schemaVersion": 1,
        "result": "PASS" if passed else "FAIL",
        "runCount": 3,
        "percentileAlgorithm": "nearest-rank ceil(N*0.95)-1",
        "binarySHA256": next(iter(binary_hashes)),
        "fixtureSHA256": next(iter(fixture_hashes)),
        "deviceModel": apps[0]["deviceModel"],
        "operatingSystem": apps[0]["operatingSystem"],
        "app": {
            "runs": apps,
            "maximums": app_checks,
            "medians": {
                "firstVisibleDrawMilliseconds": median(
                    [item["firstVisibleDrawMilliseconds"] for item in apps]
                ),
                "frameIntervalP95Milliseconds": median(
                    [item["frameIntervalP95Milliseconds"] for item in apps]
                ),
                "rssPeakDeltaBytes": median(
                    [item["rssPeakDeltaBytes"] for item in apps]
                ),
            },
        },
        "queryMatrix": query_summary,
    }
    (root / "summary.json").write_text(
        json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    lines = [
        "# EPG 10A Release performance evidence",
        "",
        f"Result: **{summary['result']}**",
        "",
        f"Device: `{summary['deviceModel']}`; {summary['operatingSystem']}; arm64.",
        f"Release binary SHA-256: `{summary['binarySHA256']}`.",
        f"Fixture SHA-256: `{summary['fixtureSHA256']}`.",
        "Percentiles use nearest-rank `ceil(N × 0.95) - 1`.",
        "",
        "## AppKit/App process runs",
        "",
        "| Run | First visible draw ms | Draw P95 ms | Frame P95 ms | RSS peak Δ MiB | footprint peak Δ MiB | >100 ms main delays |",
        "|---:|---:|---:|---:|---:|---:|---:|",
    ]
    for index, item in enumerate(apps, 1):
        lines.append(
            f"| {index} | {item['firstVisibleDrawMilliseconds']:.3f} | "
            f"{item['drawP95Milliseconds']:.3f} | "
            f"{item['frameIntervalP95Milliseconds']:.3f} | "
            f"{mib(item['rssPeakDeltaBytes']):.2f} | "
            f"{mib(item['footprintPeakDeltaBytes']):.2f} | "
            f"{item['mainDispatchDelayOver100Milliseconds']} |"
        )
    lines += [
        "",
        "The sampled window covers the bounded production loader, first draw, narrow/wide/full-screen-sized layouts, 1×/2× layers, two-axis scrolling, a date jump, generation replacement, one second after exit, and a five-second settled point. Memory is sampled every 10 ms. Frame cadence comes from CVDisplayLink with delivery on the App main queue.",
        "",
        "## Store query matrix",
        "",
        "| Channels | Programmes | Worst run P95 ms | Median run P95 ms | Worst single ms | Samples/run |",
        "|---:|---:|---:|---:|---:|---:|",
    ]
    for item in query_summary:
        lines.append(
            f"| {item['channelCount']} | {item['programmeCount']} | "
            f"{item['windowP95MaximumMilliseconds']:.3f} | "
            f"{item['windowP95MedianMilliseconds']:.3f} | "
            f"{item['windowSingleMaximumMilliseconds']:.3f} | "
            f"{item['samplesPerRun']} |"
        )
    (root / "REPORT.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(root / "REPORT.md")
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
