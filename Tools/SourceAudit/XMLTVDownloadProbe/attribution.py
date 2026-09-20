"""9B.3B-M: synthetic-only controlled memory comparisons; no recursive cleanup."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import statistics
import subprocess
import threading
import time
from http.server import ThreadingHTTPServer
from run import Handler, BLOCK, MIB, digest, save


def summary(rows):
    result = []
    for variant, rate in sorted({(r['variant'], r['rate']) for r in rows}):
        group = [r for r in rows if (r['variant'], r['rate']) == (variant, rate)]
        medians = []
        for size in sorted({r['bytes'] for r in group}):
            batch = [r for r in group if r['bytes'] == size]
            medians.append(dict(sizeMiB=size/MIB, runs=len(batch),
                rss=statistics.median(r['rssDeltaMiB'] for r in batch),
                footprint=statistics.median(r['footprintDeltaMiB'] for r in batch),
                seconds=statistics.median(r['seconds'] for r in batch),
                completionLiveHeapMiB=statistics.median(r['completionLiveHeapMiB'] for r in batch)))
        record = dict(variant=variant, rate=rate, medians=medians)
        if len(medians) == 4 and all(r['runs'] == 5 for r in medians):
            xs, ys = [r['sizeMiB'] for r in medians], [r['rss'] for r in medians]
            xm, ym = statistics.mean(xs), statistics.mean(ys)
            slope = sum((x-xm)*(y-ym) for x,y in zip(xs,ys))/sum((x-xm)**2 for x in xs)
            growth, peak = ys[-1]-ys[0], max(r['rssDeltaMiB'] for r in group)
            record.update(slope=slope, growthMiB=growth, maxPeakMiB=peak,
                gate='PASS' if growth <= 8 and slope <= .2 and peak <= 64 else 'FAIL')
        else:
            record['gate'] = 'DIAGNOSTIC / NOT FULL MATRIX'
        result.append(record)
    return result


def main(args):
    output = args.output
    root = output.parent.resolve(strict=True)
    assert output.parent == root and root.parent == Path('/private/tmp')
    suffix = root.name.removeprefix('OKVideoMac-9B.')
    assert root.name.startswith('OKVideoMac-9B.') and suffix.isascii() and suffix.isalnum()
    assert output.name.startswith('B3M') and not output.exists()
    output.mkdir(mode=0o700)
    bundle = args.xctest.resolve(strict=True)
    assert bundle.suffix == '.xctest'
    binary = bundle/'Contents/MacOS/OKVideoKitPackageTests'
    developer = Path('/Volumes/XcodeDev/Xcode.app/Contents/Developer')
    jobs = []
    if args.mode == 'screen':
        # Interleave variants; do not give all of one implementation the same
        # temporal load bias. Every measured trial is a fresh process.
        for repeat in range(3):
            for size in [1, 32]:
                for variant in ['R0', 'R1', 'R2']:
                    jobs.append((variant, size, 2*MIB, repeat, ''))
    elif args.mode == 'profile':
        for phase in ['callback', 'completion', 'invalidated', 'released']:
            for variant in ['R0', 'R2']:
                jobs.append((variant, args.profile_size, 2*MIB, 0, phase))
    elif args.mode == 'gate':
        for rate in [0, 2*MIB]:
            for size in [1, 8, 16, 32]:
                for repeat in range(5):
                    jobs.append(('R2', size, rate, repeat, ''))
    elif args.mode == 'vmcontrol':
        for phase in ['completion', 'released']:
            for size in [1, 32]:
                for variant in ['R0', 'R2']:
                    jobs.append((variant, size, 2*MIB, 0, phase))
    else:
        jobs = [('R0', 1, 0, 0, '')] # compile/lifecycle sanity, not matrix evidence
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    server.daemon_threads = True
    server.records, server.records_lock = [], threading.Lock()
    threading.Thread(target=server.serve_forever, daemon=True).start()
    save(output/'Protocol.json', dict(mode=args.mode, jobs=jobs, platform=platform.platform(),
        machine=platform.machine(), binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        fixtureSHA256=hashlib.sha256(BLOCK).hexdigest(), samplingMs=10,
        allowedMedianGrowthMiB=8, allowedSlope=.20, allowedSinglePeakMiB=64,
        rateIsNominalCeiling=True, warmupInvalidationAwaited=True,
        transferEndsGateInterval=True, profilingSeparateFromGate=True,
        barrierSecondsMax=15, oneBarrierPerProcess=True, settledDelayMs=250,
        liveHeapMetric='malloc_zone_statistics(NULL).size_in_use; not cumulative allocated bytes',
        profilerStackLogging=args.mode == 'profile'))
    results = []
    try:
        for variant, size, rate, repeat, phase in jobs:
            stem = f'{variant}-{size}-{rate}-{repeat}-{phase or "plain"}'
            env = dict(os.environ)
            for key in ['MallocStackLogging', 'MallocStackLoggingNoCompact', 'MallocScribble', 'MallocGuardEdges']:
                env.pop(key, None)
            env.update(OKVIDEO_XMLTV_VARIANT=variant, OKVIDEO_XMLTV_TRIAL_PORT=str(server.server_port),
                OKVIDEO_XMLTV_TRIAL_BYTES=str(size*MIB), OKVIDEO_XMLTV_TRIAL_RATE=str(rate),
                OKVIDEO_XMLTV_TRIAL_SHA=digest(size*MIB), OKVIDEO_XMLTV_PAUSE=phase)
            if phase and args.mode == 'profile':
                env['MallocStackLogging'] = '1'
            command = [str(developer/'usr/bin/xctest'), '-XCTest',
                'OKVideoCoreTests.XMLTVFileDownloadFeasibilityTests/testMemoryAttribution', str(bundle)]
            # XCTest status writes stderr independently; mixing it into buffered
            # stdout can split a long JSON record. Preserve separate channels.
            errors = (output/(stem+'.stderr.log')).open('x')
            try:
                process = subprocess.Popen(command, env=env, stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=errors, text=True, bufsize=1)
            finally:
                errors.close()
            # Only this owned child is terminated if its diagnostic deadline fails.
            watchdog = threading.Timer(125, process.kill)
            watchdog.start()
            lines, captures = [], []
            try:
                with (output/(stem+'.log')).open('x') as log:
                    for line in process.stdout:
                        log.write(line); log.flush(); lines.append(line)
                        if line.startswith('XMLTV_PAUSE '):
                            assert phase
                            toolset = [('vmmap', ['-wide'])]
                            if args.mode == 'profile':
                                toolset += [('heap', ['-s', '--noContent']), ('malloc_history', ['-callTree', '-noContent'])]
                            for tool, flags in toolset:
                                began = time.monotonic()
                                try:
                                    command = (['/usr/bin/'+tool, str(process.pid), *flags] if tool == 'malloc_history'
                                               else ['/usr/bin/'+tool, *flags, str(process.pid)])
                                    captured = subprocess.run(command, capture_output=True, text=True, timeout=3)
                                    text, status = captured.stdout+captured.stderr, captured.returncode
                                except subprocess.TimeoutExpired:
                                    text, status = 'Diagnostic tool timed out; no security bypass', -1
                                with (output/(stem+'.'+tool+'.txt')).open('x') as f:
                                    f.write(text)
                                captures.append(dict(tool=tool, exitCode=status, seconds=time.monotonic()-began))
                            process.stdin.write('\n'); process.stdin.flush()
                code = process.wait(timeout=5)
            finally:
                watchdog.cancel()
                if process.poll() is None:
                    process.kill(); process.wait()
                process.stdin.close(); process.stdout.close()
            reports = [line.removeprefix('XMLTV_ATTRIBUTION ') for line in lines if line.startswith('XMLTV_ATTRIBUTION ')]
            assert code == 0 and len(reports) == 1, (stem, code, 'See preserved child log')
            report = json.loads(reports[0])
            assert report['written'] == size*MIB and report['sha256'] == digest(size*MIB)
            points = report['samples']+[report['transfer']]
            phases = {p['name']: p for p in report['phases']}
            assert {'baseline', 'completion', 'transferred', 'invalidated', 'released', 'delegateDestroyed', 'settled'} <= phases.keys()
            report.update(rssDeltaMiB=max(0, max(p['rss'] for p in points)-report['baseline']['rss'])/MIB,
                footprintDeltaMiB=max(0, max(p['footprint'] for p in points)-report['baseline']['footprint'])/MIB,
                seconds=(report['transfer']['nanoseconds']-report['baseline']['nanoseconds'])/1e9,
                completionLiveHeapMiB=phases['completion']['liveMallocBytes']/MIB,
                captures=captures, repeat=repeat)
            save(output/(stem+'.json'), report)
            results.append({k: report[k] for k in ['variant', 'bytes', 'rate', 'pause', 'repeat',
                'rssDeltaMiB', 'footprintDeltaMiB', 'seconds', 'completionLiveHeapMiB', 'maxCallbackBytes', 'captures']})
            print(stem, f'RSS +{report["rssDeltaMiB"]:.2f}, footprint +{report["footprintDeltaMiB"]:.2f}, live heap {report["completionLiveHeapMiB"]:.2f} MiB, {report["seconds"]:.2f}s', flush=True)
    finally:
        server.shutdown(); server.server_close()
        save(output/'Server.json', server.records)
        save(output/'Runs.json', results)
    totals = summary(results)
    save(output/'Summary.json', totals)
    print(json.dumps(totals, indent=2), flush=True)
    return 2 if any(r['gate'] == 'FAIL' for r in totals) else 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--xctest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mode', choices=['sanity', 'screen', 'profile', 'vmcontrol', 'gate'], required=True)
    parser.add_argument('--profile-size', type=int, choices=[1, 32], default=32)
    raise SystemExit(main(parser.parse_args()))
