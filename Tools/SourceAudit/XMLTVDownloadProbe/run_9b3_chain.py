"""9B.3 Release gate: real loopback download-task -> file -> batch parser."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import statistics
import struct
import subprocess
import sys
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "EPGBaseline"))
from fixture import ANCHOR, channel, generate, noise

MIB = 1024 * 1024


def save(path, value):
    with path.open("x") as file:
        json.dump(value, file, indent=2)
        file.write("\n")


def programme_digest(count, channels=1000, seed=17, title_length=24,
                     duration=1800, offset=480):
    digest = hashlib.sha256()
    for index in range(count):
        channel_index, slot = index % channels, index // channels
        identity = channel(channel_index, 0)[0]
        _ = noise(seed, index)
        start = ANCHOR + slot * duration
        end = start + duration
        title = f"节目{index:07d} " + ("测é📺&<> " * (title_length // 7 + 1))[:title_length]
        digest.update(b"P\0")
        for field in [identity, title, start, end]:
            value = str(field).encode("utf-8")
            digest.update(struct.pack(">Q", len(value)))
            digest.update(value)
        digest.update(b"\n")
    return digest.hexdigest()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def do_GET(self):
        name = self.path.removeprefix("/")
        if name not in ["fixture.xml", "fixture.xml.gz"]:
            self.send_error(404)
            return
        path = self.server.fixture / name
        size = path.stat().st_size
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        written = 0
        state = "complete"
        try:
            with path.open("rb") as source:
                for block in iter(lambda: source.read(64 * 1024), b""):
                    self.wfile.write(block)
                    written += len(block)
        except (BrokenPipeError, ConnectionResetError):
            state = "cancelled"
        self.close_connection = True
        with self.server.records_lock:
            self.server.records.append(dict(
                name=name,
                declared=size,
                written=written,
                state=state,
                acceptEncoding=self.headers.get("Accept-Encoding"),
            ))

    def log_message(self, *args):
        pass


def invoke(bundle, url, mode, metadata, digest):
    developer = Path("/Volumes/XcodeDev/Xcode.app/Contents/Developer")
    environment = dict(os.environ,
        OKVIDEO_XMLTV_9B3_URL=url,
        OKVIDEO_XMLTV_9B3_MODE=mode,
        OKVIDEO_XMLTV_9B3_COUNT=str(metadata["count"]),
        OKVIDEO_XMLTV_9B3_COMPRESSED=str(metadata["gzipBytes"]),
        OKVIDEO_XMLTV_9B3_EXPANDED=str(metadata["xmlBytes"]),
        OKVIDEO_XMLTV_9B3_DECLARED=str(metadata["xmlBytes"]),
        OKVIDEO_XMLTV_9B3_PROGRAMME_SHA=digest)
    command = [str(developer / "usr/bin/xctest"), "-XCTest",
        "OKVideoCoreTests.XMLTVDownloaderTests/testRealLoopbackNetworkFileParserChain",
        str(bundle)]
    return subprocess.run(command, env=environment, capture_output=True,
                          text=True, timeout=240)


def main(arguments):
    output = arguments.output
    parent = output.parent.resolve(strict=True)
    suffix = parent.name.removeprefix("OKVideoMac-9B.")
    assert output.parent == parent and parent.parent == Path("/private/tmp")
    assert parent.name.startswith("OKVideoMac-9B.") and suffix.isascii() and suffix.isalnum()
    assert output.name.startswith("9B3Chain") and not output.exists()
    output.mkdir(mode=0o700)

    bundle = arguments.xctest.resolve(strict=True)
    assert bundle.suffix == ".xctest"
    binary = bundle / "Contents/MacOS/OKVideoKitPackageTests"
    fixture = output / "Fixture"
    metadata = generate(fixture, count=200_000)
    assert metadata["xmlBytes"] > 32 * MIB
    assert metadata["gzipBytes"] <= 32 * MIB
    assert metadata["xmlBytes"] <= 64 * MIB
    digest = programme_digest(metadata["count"])

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    server.fixture = fixture
    server.records = []
    server.records_lock = threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    reports = []
    try:
        for index in range(3):
            process = invoke(bundle,
                f"http://127.0.0.1:{server.server_port}/fixture.xml.gz",
                "gzip", metadata, digest)
            (output / f"gzip-{index}.stdout.log").write_text(process.stdout)
            (output / f"gzip-{index}.stderr.log").write_text(process.stderr)
            rows = [line.removeprefix("XMLTV_9B3_CHAIN ")
                    for line in process.stdout.splitlines()
                    if line.startswith("XMLTV_9B3_CHAIN ")]
            assert process.returncode == 0 and len(rows) == 1, process.returncode
            report = json.loads(rows[0])
            report["rssDeltaMiB"] = max(0, report["peak"]["rss"] - report["baseline"]["rss"]) / MIB
            report["footprintDeltaMiB"] = max(0, report["peak"]["footprint"] - report["baseline"]["footprint"]) / MIB
            save(output / f"gzip-{index}.json", report)
            reports.append(report)

        process = invoke(bundle,
            f"http://127.0.0.1:{server.server_port}/fixture.xml",
            "plain-reject", metadata, digest)
        (output / "plain-reject.stdout.log").write_text(process.stdout)
        (output / "plain-reject.stderr.log").write_text(process.stderr)
        rows = [line.removeprefix("XMLTV_9B3_CHAIN ")
                for line in process.stdout.splitlines()
                if line.startswith("XMLTV_9B3_CHAIN ")]
        assert process.returncode == 0 and len(rows) == 1
        plain_rejected = json.loads(rows[0])["result"] == "PASS"
    finally:
        server.shutdown()
        server.server_close()
        save(output / "Server.json", server.records)

    checks = dict(
        gzipRuns=len(reports) == 3,
        counts=all(row["count"] == metadata["count"] for row in reports),
        inputBytes=all(row["downloadedBytes"] == metadata["gzipBytes"] and
                       row["expandedBytes"] == metadata["xmlBytes"] for row in reports),
        boundedBatches=all(row["peakBatchCount"] <= 512 and
                           row["peakBatchEstimatedBytes"] <= MIB for row in reports),
        rss=all(row["rssDeltaMiB"] <= 64 for row in reports),
        footprint=all(row["footprintDeltaMiB"] <= 64 for row in reports),
        identityEncoding=all(row["acceptEncoding"] == "identity"
            for row in server.records),
        # Server socket completion is not evidence of client admission. The
        # XCTest assertion above is the authority for the declared-size reject.
        plainRejected=plain_rejected,
    )
    summary = dict(
        decision="PASS" if all(checks.values()) else "FAIL",
        checks=checks,
        gzipRSSDeltaMiB=[row["rssDeltaMiB"] for row in reports],
        medianRSSDeltaMiB=statistics.median(row["rssDeltaMiB"] for row in reports),
        fixture=metadata,
        programmeSHA256=digest,
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    )
    save(output / "Summary.json", summary)
    print(json.dumps(summary, indent=2))
    return 0 if summary["decision"] == "PASS" else 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--xctest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    raise SystemExit(main(parser.parse_args()))
