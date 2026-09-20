"""B1-M common-harness direct/converted comparison; loopback and Release only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
from http.server import ThreadingHTTPServer

from download_task_review import assess
from run import BLOCK, Handler, MIB, digest, save


SCHEDULE = [
    ("direct", "D1"),
    ("converted", "C1"),
    ("converted", "C2"),
    ("direct", "D2"),
    ("direct", "D3"),
    ("converted", "C3"),
]


def validate_output(output: Path) -> None:
    root = output.parent.resolve(strict=True)
    assert output.parent == root and root.parent == Path("/private/tmp")
    suffix = root.name.removeprefix("OKVideoMac-9B.")
    assert root.name.startswith("OKVideoMac-9B.") and suffix.isascii() and suffix.isalnum()
    assert output.name.startswith("B1M") and not output.exists()


def run_child(bundle: Path, output: Path, port: int, mode: str, label: str) -> dict:
    developer = Path("/Volumes/XcodeDev/Xcode.app/Contents/Developer")
    command = [
        str(developer / "usr/bin/xctest"),
        "-XCTest",
        "OKVideoCoreTests.XMLTVDownloadMemoryComparisonTests/"
        "testCommonLifecycleRepeatedSessionMemory",
        str(bundle),
    ]
    environment = dict(
        os.environ,
        OKVIDEO_B1M_MODE=mode,
        OKVIDEO_B1M_PORT=str(port),
        OKVIDEO_B1M_BYTES=str(32 * MIB),
        OKVIDEO_B1M_CYCLES="8",
        OKVIDEO_B1M_SHA=digest(32 * MIB),
        OKVIDEO_B1M_RUN=label,
    )
    for key in ("MallocStackLogging", "MallocStackLoggingNoCompact", "MallocScribble", "MallocGuardEdges"):
        environment.pop(key, None)
    stdout_path = output / f"{label}.stdout.log"
    stderr_path = output / f"{label}.stderr.log"
    with stdout_path.open("x") as stdout, stderr_path.open("x") as stderr:
        child = subprocess.Popen(command, env=environment, stdout=stdout, stderr=stderr)
        try:
            code = child.wait(timeout=240)
        finally:
            if child.poll() is None:
                child.terminate()
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
    lines = [
        line.removeprefix("B1M_MEMORY ")
        for line in stdout_path.read_text().splitlines()
        if line.startswith("B1M_MEMORY ")
    ]
    assert code == 0 and len(lines) == 1, (label, code, "see preserved logs")
    report = json.loads(lines[0])
    assert report["mode"] == mode and report["runLabel"] == label
    assert report["bytes"] == 32 * MIB and report["cycles"] == 8
    assert len(report["results"]) == 8
    assert all(row["copiedBytes"] == 32 * MIB for row in report["results"])
    assert all(row["sha256"] == digest(32 * MIB) for row in report["results"])
    report["assessment"] = assess(report)
    save(output / f"{label}.json", report)
    return report


def decision(reports: list[dict]) -> tuple[str, str]:
    direct = [r["assessment"]["provisionalCompositeGate"] for r in reports if r["mode"] == "direct"]
    converted = [r["assessment"]["provisionalCompositeGate"] for r in reports if r["mode"] == "converted"]
    direct_pass = all(value == "PASS" for value in direct)
    converted_pass = all(value == "PASS" for value in converted)
    if direct_pass and converted_pass:
        return "PASS", "common harness stable in all preregistered processes"
    if direct_pass and not converted_pass and all(value == "FAIL" for value in converted):
        return "BLOCKED", "failure associated with converted path; no fix identified"
    if not direct_pass and not converted_pass and all(value == "FAIL" for value in direct + converted):
        return "BLOCKED", "shared harness or lifecycle remains unstable"
    return "BLOCKED", "mixed result is inconclusive"


def main(arguments) -> int:
    validate_output(arguments.output)
    arguments.output.mkdir(mode=0o700)
    bundle = arguments.xctest.resolve(strict=True)
    assert bundle.suffix == ".xctest"
    binary = bundle / "Contents/MacOS/OKVideoKitPackageTests"
    protocol = Path(__file__).with_name("B1M_PROTOCOL.md")
    save(arguments.output / "Protocol.json", dict(
        protocolVersion=1,
        schedule=[label for _, label in SCHEDULE],
        variants={label: mode for mode, label in SCHEDULE},
        bodyMiB=32,
        cycles=8,
        warmupBytes=65_536,
        settleMilliseconds=250,
        samplingMilliseconds=10,
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        protocolSHA256=hashlib.sha256(protocol.read_bytes()).hexdigest(),
        fixtureBlockSHA256=hashlib.sha256(BLOCK).hexdigest(),
        noProfiler=True,
        noForcedMemoryPressure=True,
        noRetry=True,
        production=False,
    ))

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.records = []
    server.records_lock = threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    reports = []
    try:
        for mode, label in SCHEDULE:
            report = run_child(bundle, arguments.output, server.server_port, mode, label)
            reports.append(report)
            print(label, report["assessment"]["provisionalCompositeGate"], flush=True)
        result, reason = decision(reports)
        summary = dict(
            decision=result,
            reason=reason,
            runs=[dict(
                label=report["runLabel"],
                mode=report["mode"],
                gate=report["assessment"]["provisionalCompositeGate"],
                assessment=report["assessment"],
            ) for report in reports],
        )
        save(arguments.output / "Summary.json", summary)
        print(json.dumps(summary, indent=2), flush=True)
        return 0 if result == "PASS" else 2
    finally:
        server.shutdown()
        server.server_close()
        save(arguments.output / "Server.json", server.records)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    raise SystemExit(main(parser.parse_args()))
