"""One bounded D/C vmmap pair at settled cycles 2 and 8; never a numeric gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import threading
import time
from http.server import ThreadingHTTPServer

from run import BLOCK, Handler, MIB, digest, save


def wait_for_stop(process: subprocess.Popen, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        pid, status = os.waitpid(process.pid, os.WNOHANG | os.WUNTRACED)
        if pid == process.pid:
            if os.WIFSTOPPED(status) and os.WSTOPSIG(status) == signal.SIGSTOP:
                return
            if os.WIFEXITED(status) or os.WIFSIGNALED(status):
                raise RuntimeError("profile child exited before the expected pause")
        time.sleep(0.02)
    raise TimeoutError("profile child did not reach the expected pause")


def run_profile(bundle: Path, output: Path, port: int, mode: str) -> dict:
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
        OKVIDEO_B1M_RUN=f"{mode}-profile",
        OKVIDEO_B1M_PROFILE_PHASES="1",
    )
    for key in ("MallocStackLogging", "MallocStackLoggingNoCompact", "MallocScribble", "MallocGuardEdges"):
        environment.pop(key, None)
    stdout_path = output / f"{mode}.stdout.log"
    stderr_path = output / f"{mode}.stderr.log"
    with stdout_path.open("x") as stdout, stderr_path.open("x") as stderr:
        process = subprocess.Popen(command, env=environment, stdout=stdout, stderr=stderr)
        try:
            for cycle in (2, 8):
                wait_for_stop(process, 60)
                with (output / f"{mode}-cycle{cycle}.vmmap.txt").open("x") as vmmap:
                    result = subprocess.run(
                        ["/usr/bin/vmmap", "-summary", str(process.pid)],
                        stdout=vmmap,
                        stderr=subprocess.STDOUT,
                        text=True,
                        timeout=30,
                    )
                if result.returncode != 0:
                    raise RuntimeError(f"vmmap failed for {mode} cycle {cycle}")
                os.kill(process.pid, signal.SIGCONT)
            code = process.wait(timeout=90)
        finally:
            if process.poll() is None:
                os.kill(process.pid, signal.SIGCONT)
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
    lines = [
        line.removeprefix("B1M_MEMORY ")
        for line in stdout_path.read_text().splitlines()
        if line.startswith("B1M_MEMORY ")
    ]
    assert code == 0 and len(lines) == 1, (mode, code, "see preserved logs")
    report = json.loads(lines[0])
    assert report["mode"] == mode and len(report["results"]) == 8
    assert all(row["copiedBytes"] == 32 * MIB for row in report["results"])
    assert all(row["sha256"] == digest(32 * MIB) for row in report["results"])
    save(output / f"{mode}.json", report)
    return report


def main(arguments) -> int:
    root = arguments.output.parent.resolve(strict=True)
    assert arguments.output.parent == root and root.parent == Path("/private/tmp")
    suffix = root.name.removeprefix("OKVideoMac-9B.")
    assert root.name.startswith("OKVideoMac-9B.") and suffix.isascii() and suffix.isalnum()
    assert arguments.output.name.startswith("B1M") and not arguments.output.exists()
    arguments.output.mkdir(mode=0o700)
    bundle = arguments.xctest.resolve(strict=True)
    binary = bundle / "Contents/MacOS/OKVideoKitPackageTests"
    save(arguments.output / "Protocol.json", dict(
        purpose="bounded lifecycle VM-region attribution; not a performance gate",
        modes=["direct", "converted"],
        phases=["settled-cycle-2", "settled-cycle-8"],
        bodyMiB=32,
        cycles=8,
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        fixtureBlockSHA256=hashlib.sha256(BLOCK).hexdigest(),
        noMallocStackLogging=True,
        production=False,
    ))
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.records = []
    server.records_lock = threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        reports = [run_profile(bundle, arguments.output, server.server_port, mode) for mode in ("direct", "converted")]
        save(arguments.output / "Summary.json", dict(
            decision="EVIDENCE ONLY",
            modes=[report["mode"] for report in reports],
            vmmapFiles=[f"{mode}-cycle{cycle}.vmmap.txt" for mode in ("direct", "converted") for cycle in (2, 8)],
        ))
        return 0
    finally:
        server.shutdown()
        server.server_close()
        save(arguments.output / "Server.json", server.records)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    raise SystemExit(main(parser.parse_args()))
