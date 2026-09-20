"""B1-N converted per-operation/shared-session comparison; loopback only."""
from __future__ import annotations

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
    ("perOperation", "P1"),
    ("sharedSession", "S1"),
    ("sharedSession", "S2"),
    ("perOperation", "P2"),
    ("perOperation", "P3"),
    ("sharedSession", "S3"),
]


def child_environment(port: int) -> dict:
    environment = dict(os.environ, OKVIDEO_B1N_PORT=str(port))
    for key in ("MallocStackLogging", "MallocStackLoggingNoCompact", "MallocScribble", "MallocGuardEdges"):
        environment.pop(key, None)
    return environment


def execute(bundle: Path, output: Path, port: int, test: str, name: str, extra: dict | None = None) -> str:
    developer = Path("/Volumes/XcodeDev/Xcode.app/Contents/Developer")
    command = [
        str(developer / "usr/bin/xctest"),
        "-XCTest",
        f"OKVideoCoreTests.XMLTVDownloadSharedSessionTests/{test}",
        str(bundle),
    ]
    environment = child_environment(port)
    if extra:
        environment.update(extra)
    stdout_path = output / f"{name}.stdout.log"
    stderr_path = output / f"{name}.stderr.log"
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
    assert code == 0, (name, code, "see preserved logs")
    return stdout_path.read_text()


def decide(reports: list[dict]) -> tuple[str, str]:
    per_operation = [r["assessment"]["provisionalCompositeGate"] for r in reports if r["mode"] == "perOperation"]
    shared = [r["assessment"]["provisionalCompositeGate"] for r in reports if r["mode"] == "sharedSession"]
    if all(value == "FAIL" for value in per_operation) and all(value == "PASS" for value in shared):
        return "PASS", "session reuse removes the reproducible per-operation converted RSS failure"
    if all(value == "PASS" for value in per_operation + shared):
        return "BLOCKED", "stable result did not reproduce or isolate the prior failure"
    return "BLOCKED", "mixed or shared-session failure does not support the direction"


def main(arguments) -> int:
    root = arguments.output.parent.resolve(strict=True)
    assert arguments.output.parent == root and root.parent == Path("/private/tmp")
    suffix = root.name.removeprefix("OKVideoMac-9B.")
    assert root.name.startswith("OKVideoMac-9B.") and suffix.isascii() and suffix.isalnum()
    assert arguments.output.name.startswith("B1N") and not arguments.output.exists()
    arguments.output.mkdir(mode=0o700)
    bundle = arguments.xctest.resolve(strict=True)
    binary = bundle / "Contents/MacOS/OKVideoKitPackageTests"
    protocol = Path(__file__).with_name("B1N_PROTOCOL.md")
    save(arguments.output / "Protocol.json", dict(
        protocolVersion=1,
        schedule=[label for _, label in SCHEDULE],
        variants={label: mode for mode, label in SCHEDULE},
        bodyMiB=32,
        cycles=8,
        warmupBytes=65_536,
        settleMilliseconds=250,
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        protocolSHA256=hashlib.sha256(protocol.read_bytes()).hexdigest(),
        fixtureBlockSHA256=hashlib.sha256(BLOCK).hexdigest(),
        noRetry=True,
        noProfiler=True,
        noForcedMemoryPressure=True,
        production=False,
    ))
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.records = []
    server.records_lock = threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    reports = []
    try:
        execute(
            bundle,
            arguments.output,
            server.server_port,
            "testSharedRouterIsolatesCancelledOperation",
            "router-isolation",
        )
        for mode, label in SCHEDULE:
            text = execute(
                bundle,
                arguments.output,
                server.server_port,
                "testConvertedSessionReuseMemory",
                label,
                dict(
                    OKVIDEO_B1N_MODE=mode,
                    OKVIDEO_B1N_BYTES=str(32 * MIB),
                    OKVIDEO_B1N_CYCLES="8",
                    OKVIDEO_B1N_SHA=digest(32 * MIB),
                    OKVIDEO_B1N_RUN=label,
                ),
            )
            lines = [
                line.removeprefix("B1N_MEMORY ")
                for line in text.splitlines()
                if line.startswith("B1N_MEMORY ")
            ]
            assert len(lines) == 1, (label, "missing report")
            report = json.loads(lines[0])
            assert report["mode"] == mode and report["runLabel"] == label
            assert len(report["results"]) == 8
            assert all(row["copiedBytes"] == 32 * MIB for row in report["results"])
            assert all(row["sha256"] == digest(32 * MIB) for row in report["results"])
            report["assessment"] = assess(report)
            save(arguments.output / f"{label}.json", report)
            reports.append(report)
            print(label, report["assessment"]["provisionalCompositeGate"], flush=True)
        gate, reason = decide(reports)
        summary = dict(
            decision=gate,
            reason=reason,
            routerIsolation="PASS",
            runs=[dict(
                label=r["runLabel"],
                mode=r["mode"],
                gate=r["assessment"]["provisionalCompositeGate"],
                assessment=r["assessment"],
                afterSessionCloseFDs=r["afterSessionCloseFDs"],
            ) for r in reports],
        )
        save(arguments.output / "Summary.json", summary)
        print(json.dumps(summary, indent=2), flush=True)
        return 0 if gate == "PASS" else 2
    finally:
        server.shutdown()
        server.server_close()
        save(arguments.output / "Server.json", server.records)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    raise SystemExit(main(parser.parse_args()))
