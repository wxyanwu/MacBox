"""R3 URLSessionDownloadTask repeated-session review; synthetic loopback only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import threading
from http.server import ThreadingHTTPServer

from run import BLOCK, Handler, MIB, digest, save


def slope(values):
    xs = list(range(2, len(values) + 1))
    ys = values[1:]
    xm, ym = statistics.mean(xs), statistics.mean(ys)
    return sum((x - xm) * (y - ym) for x, y in zip(xs, ys)) / sum(
        (x - xm) ** 2 for x in xs
    )


def assess(report):
    rows = report["results"]
    rss = [row["settledRSS"] / MIB for row in rows]
    footprint = [row["settledFootprint"] / MIB for row in rows]
    heap = [row["settledLiveMalloc"] / MIB for row in rows]
    first, last = rows[1:4], rows[5:8]

    def window(values, group):
        return statistics.median(values[row["index"] - 1] for row in group)

    result = dict(
        settledRSSSlopeMiBPerCycle=slope(rss),
        settledFootprintSlopeMiBPerCycle=slope(footprint),
        earlyLateRSSGrowthMiB=window(rss, last) - window(rss, first),
        earlyLateFootprintGrowthMiB=window(footprint, last) - window(footprint, first),
        earlyLateLiveHeapGrowthMiB=window(heap, last) - window(heap, first),
        maximumSettledRSSDeltaMiB=max(rss) - report["baseline"]["rss"] / MIB,
        maximumTransferPeakDeltaMiB=max(row["peakRSSDeltaMiB"] for row in rows),
        maximumFDGrowth=max(row["openFDs"] for row in rows) - report["baselineFDs"],
        medianSeconds=statistics.median(row["seconds"] for row in rows),
    )
    checks = dict(
        rssSlope=result["settledRSSSlopeMiBPerCycle"] <= 1.0,
        footprintSlope=result["settledFootprintSlopeMiBPerCycle"] <= 0.5,
        rssWindowGrowth=result["earlyLateRSSGrowthMiB"] <= 8,
        footprintWindowGrowth=result["earlyLateFootprintGrowthMiB"] <= 4,
        liveHeapWindowGrowth=result["earlyLateLiveHeapGrowthMiB"] <= 2,
        settledRSSCeiling=result["maximumSettledRSSDeltaMiB"] <= 64,
        transferPeakCeiling=result["maximumTransferPeakDeltaMiB"] <= 64,
        fdGrowth=result["maximumFDGrowth"] <= 2,
        foundationTemporaryFilesRemoved=all(
            row["foundationTemporaryFileRemoved"] for row in rows
        ),
        copiedBytes=all(row["copiedBytes"] == report["bytes"] for row in rows),
    )
    result["checks"] = checks
    result["provisionalCompositeGate"] = "PASS" if all(checks.values()) else "FAIL"
    return result


def main(args):
    output = args.output
    root = output.parent.resolve(strict=True)
    assert output.parent == root and root.parent == Path("/private/tmp")
    suffix = root.name.removeprefix("OKVideoMac-9B.")
    assert root.name.startswith("OKVideoMac-9B.") and suffix.isascii() and suffix.isalnum()
    assert output.name.startswith("R3") and not output.exists()
    output.mkdir(mode=0o700)

    bundle = args.xctest.resolve(strict=True)
    assert bundle.suffix == ".xctest"
    binary = bundle / "Contents/MacOS/OKVideoKitPackageTests"
    developer = Path("/Volumes/XcodeDev/Xcode.app/Contents/Developer")
    save(output / "Protocol.json", dict(
        variant="R3",
        bodyMiB=32,
        cycles=8,
        writer="fast",
        copyBufferBytes=65_536,
        fixtureSHA256=hashlib.sha256(BLOCK).hexdigest(),
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        settleMs=250,
        samplingMs=10,
        discardFirstCycleForSlope=True,
        stableWindows="cycles 2-4 versus cycles 6-8",
        provisionalOnly=True,
        officialPriorRSSGateRemainsFailed=True,
        thresholds=dict(
            rssSlopeMiBPerCycle=1,
            footprintSlopeMiBPerCycle=0.5,
            rssEarlyLateMiB=8,
            footprintEarlyLateMiB=4,
            liveHeapEarlyLateMiB=2,
            settledRSSMiB=64,
            transferPeakMiB=64,
            fdGrowth=2,
        ),
        noProfiler=True,
        noForcedMemoryPressure=True,
        noProductionChanges=True,
    ))

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.records = []
    server.records_lock = threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        env = dict(
            os.environ,
            OKVIDEO_XMLTV_TRIAL_PORT=str(server.server_port),
            OKVIDEO_XMLTV_TRIAL_BYTES=str(32 * MIB),
            OKVIDEO_XMLTV_REPEAT_CYCLES="8",
            OKVIDEO_XMLTV_TRIAL_SHA=digest(32 * MIB),
        )
        command = [
            str(developer / "usr/bin/xctest"),
            "-XCTest",
            "OKVideoCoreTests.XMLTVDownloadTaskFeasibilityTests/"
            "testDownloadTaskRepeatedSessionStability",
            str(bundle),
        ]
        process = subprocess.run(command, env=env, capture_output=True, text=True, timeout=180)
        (output / "R3-fast.stdout.log").write_text(process.stdout)
        (output / "R3-fast.stderr.log").write_text(process.stderr)
        lines = [
            line.removeprefix("XMLTV_DOWNLOAD_TASK_STABILITY ")
            for line in process.stdout.splitlines()
            if line.startswith("XMLTV_DOWNLOAD_TASK_STABILITY ")
        ]
        assert process.returncode == 0 and len(lines) == 1, process.returncode
        report = json.loads(lines[0])
        assert report["variant"] == "R3" and len(report["results"]) == 8
        assert report["downloadTaskUsed"] and not report["dataDelegateUsed"]
        assert report["copyBufferBytes"] == 65_536
        report["assessment"] = assess(report)
        save(output / "R3-fast.json", report)
        save(output / "Summary.json", dict(
            decision=(
                "ELIGIBLE FOR CHANGE B DESIGN REVIEW"
                if report["assessment"]["provisionalCompositeGate"] == "PASS"
                else "R3 REJECTED"
            ),
            assessment=report["assessment"],
        ))
        print(json.dumps(report["assessment"], indent=2), flush=True)
        return 0 if report["assessment"]["provisionalCompositeGate"] == "PASS" else 2
    finally:
        server.shutdown()
        server.server_close()
        save(output / "Server.json", server.records)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    raise SystemExit(main(parser.parse_args()))
