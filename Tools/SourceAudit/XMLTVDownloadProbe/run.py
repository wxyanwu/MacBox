"""Explicit synthetic loopback gate; never accepts provider URLs or cleans trees."""
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time

MIB = 1024 * 1024
BLOCK = bytes((i * 31 + 17) % 256 for i in range(65536))


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def do_GET(self):
        parts = self.path.split('/')
        if len(parts) != 3 or parts[1] != 'bytes' or not parts[2].isdigit():
            self.send_error(404)
            return
        count = int(parts[2])
        if count not in [65536, MIB, 8 * MIB, 16 * MIB, 32 * MIB]:
            self.send_error(400)
            return
        self.send_response(200)
        self.send_header('Content-Length', str(count))
        self.send_header('Content-Type', 'application/octet-stream')
        self.send_header('Connection', 'close')
        self.end_headers()
        began = time.monotonic()
        sent = 0
        status = 'socket-write-complete'
        try:
            while sent < count:
                size = min(len(BLOCK), count - sent)
                self.wfile.write(BLOCK[:size])
                sent += size
        except (BrokenPipeError, ConnectionResetError):
            status = 'connection-ended'
        self.close_connection = True
        with self.server.records_lock:
            self.server.records.append(dict(bytes=count, socketWritten=sent,
                seconds=time.monotonic() - began, status=status,
                acceptEncoding=self.headers.get('Accept-Encoding')))

    def log_message(self, *args):
        pass


def save(path, value):
    with path.open('x') as f:
        json.dump(value, f, indent=2)
        f.write('\n')


def digest(count):
    h = hashlib.sha256()
    for _ in range(count // len(BLOCK)):
        h.update(BLOCK)
    return h.hexdigest()


def main(args):
    output = args.output
    parent = output.parent.resolve(strict=True)
    assert str(parent) == str(output.parent)
    suffix = parent.name.removeprefix('OKVideoMac-9B.')
    assert parent.parent == Path('/private/tmp') and parent.name.startswith('OKVideoMac-9B.')
    assert suffix and suffix.isascii() and suffix.isalnum()
    assert output.name.startswith('B3BMemory') and not output.exists()
    output.mkdir(mode=0o700)
    bundle = args.xctest.resolve(strict=True)
    assert bundle.suffix == '.xctest'
    binary = bundle / 'Contents/MacOS/OKVideoKitPackageTests'
    developer = Path('/Volumes/XcodeDev/Xcode.app/Contents/Developer')
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.records, server.records_lock = [], threading.Lock()
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    save(output / 'Protocol.json', dict(scalesMiB=[1, 8, 16, 32], repetitions=5,
        ratesBytesPerSecond=[0, 2 * MIB], samplingMs=10,
        allowedMedianGrowthMiB=8, allowedSlope=0.20, allowedSinglePeakMiB=64,
        platform=platform.platform(), machine=platform.machine(),
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        fixtureBlockSHA256=hashlib.sha256(BLOCK).hexdigest(), buildConcurrent=False,
        serverIsSeparateFromMeasuredXCTestProcess=True))
    results = []
    try:
        for rate in [0, 2 * MIB]:
            for size in [1, 8, 16, 32]:
                for repeat in range(5):
                    stem = f'{"fast" if rate == 0 else "slow"}-{size}-{repeat}'
                    env = dict(os.environ, OKVIDEO_XMLTV_TRIAL_PORT=str(server.server_port),
                        OKVIDEO_XMLTV_TRIAL_BYTES=str(size * MIB),
                        OKVIDEO_XMLTV_TRIAL_RATE=str(rate), OKVIDEO_XMLTV_TRIAL_SHA=digest(size * MIB))
                    command = [str(developer / 'usr/bin/xctest'), '-XCTest',
                        'OKVideoCoreTests.XMLTVFileDownloadFeasibilityTests/testRealURLSessionMemoryGate', str(bundle)]
                    process = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
                    text = process.stdout + '\n' + process.stderr
                    with (output / (stem + '.log')).open('x') as f:
                        f.write(text)
                    reports = [line.removeprefix('XMLTV_DOWNLOAD_TRIAL ') for line in text.splitlines()
                               if line.startswith('XMLTV_DOWNLOAD_TRIAL ')]
                    assert process.returncode == 0 and len(reports) == 1, (stem, process.returncode)
                    report = json.loads(reports[0])
                    assert report['written'] == report['readBytes'] == size * MIB
                    assert report['sha256'] == digest(size * MIB)
                    assert len(report['samples']) > 0
                    peak = max([report['transfer']['rss']] + [p['rss'] for p in report['samples']])
                    peak_fp = max([report['transfer']['footprint']] + [p['footprint'] for p in report['samples']])
                    report.update(peakDeltaMiB=max(0, peak - report['baseline']['rss']) / MIB,
                        peakFootprintDeltaMiB=max(0, peak_fp - report['baseline']['footprint']) / MIB,
                        seconds=(report['transfer']['nanoseconds'] - report['baseline']['nanoseconds']) / 1e9,
                        repetition=repeat, sizeMiB=size, mode='fast' if rate == 0 else 'slow', exitCode=0)
                    save(output / (stem + '.json'), report)
                    results.append({k: report[k] for k in ['mode', 'sizeMiB', 'repetition', 'peakDeltaMiB',
                        'peakFootprintDeltaMiB', 'seconds', 'maxCallbackBytes', 'callbacks']})
                    print(stem, f"RSS +{report['peakDeltaMiB']:.3f} MiB, {report['seconds']:.3f}s", flush=True)
    finally:
        server.shutdown()
        server.server_close()
        save(output / 'Server.json', server.records)
        save(output / 'Runs.json', results)
    summary = []
    for mode in ['fast', 'slow']:
        medians = []
        for size in [1, 8, 16, 32]:
            rows = [r for r in results if r['mode'] == mode and r['sizeMiB'] == size]
            assert len(rows) == 5
            medians.append(dict(sizeMiB=size, medianDeltaMiB=statistics.median(r['peakDeltaMiB'] for r in rows),
                minDeltaMiB=min(r['peakDeltaMiB'] for r in rows), maxDeltaMiB=max(r['peakDeltaMiB'] for r in rows),
                medianSeconds=statistics.median(r['seconds'] for r in rows)))
        xs = [r['sizeMiB'] for r in medians]
        ys = [r['medianDeltaMiB'] for r in medians]
        xm, ym = statistics.mean(xs), statistics.mean(ys)
        slope = sum((x-xm)*(y-ym) for x,y in zip(xs,ys)) / sum((x-xm)**2 for x in xs)
        growth = ys[-1] - ys[0]
        max_peak = max(r['peakDeltaMiB'] for r in results if r['mode'] == mode)
        summary.append(dict(mode=mode, medians=medians, slope=slope, growthMiB=growth, maxPeakMiB=max_peak,
            numericGate='PASS' if growth <= 8 and slope <= .20 and max_peak <= 64 else 'FAIL'))
    save(output / 'Summary.json', summary)
    print(json.dumps(summary, indent=2), flush=True)
    return 0 if all(r['numericGate'] == 'PASS' for r in summary) else 2


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xctest', type=Path, required=True, help='Release .xctest bundle')
    parser.add_argument('--output', type=Path, required=True)
    raise SystemExit(main(parser.parse_args()))
