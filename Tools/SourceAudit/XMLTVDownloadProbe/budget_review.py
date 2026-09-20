"""9B.3B-G: synthetic repeated-session budget review, never a production gate."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess
import threading
from http.server import ThreadingHTTPServer
from run import Handler, BLOCK, MIB, digest, save


def slope(values):
    xs = list(range(2, len(values) + 1))
    ys = values[1:]
    xm, ym = statistics.mean(xs), statistics.mean(ys)
    return sum((x-xm)*(y-ym) for x,y in zip(xs,ys))/sum((x-xm)**2 for x in xs)


def assess(report):
    rows = report['results']; baseline = report['baseline']
    stable = rows[1:]
    window_width = 3 if len(stable) >= 6 else 2
    first = stable[:window_width]
    last = stable[-window_width:]
    rss = [r['settledRSS']/MIB for r in rows]
    footprint = [r['settledFootprint']/MIB for r in rows]
    heap = [r['settledLiveMalloc']/MIB for r in rows]
    window = lambda values, group: statistics.median(values[r['index']-1] for r in group)
    result = dict(
        settledRSSSlopeMiBPerCycle=slope(rss),
        settledFootprintSlopeMiBPerCycle=slope(footprint),
        earlyLateRSSGrowthMiB=window(rss,last)-window(rss,first),
        earlyLateFootprintGrowthMiB=window(footprint,last)-window(footprint,first),
        earlyLateLiveHeapGrowthMiB=window(heap,last)-window(heap,first),
        maximumSettledRSSDeltaMiB=max(rss)-baseline['rss']/MIB,
        maximumTransferPeakDeltaMiB=max(r['peakRSSDeltaMiB'] for r in rows),
        maximumFDGrowth=max(r['openFDs'] for r in rows)-report['baselineFDs'],
        medianSeconds=statistics.median(r['seconds'] for r in rows))
    checks = dict(
        rssSlope=result['settledRSSSlopeMiBPerCycle'] <= 1.0,
        footprintSlope=result['settledFootprintSlopeMiBPerCycle'] <= 0.5,
        rssWindowGrowth=result['earlyLateRSSGrowthMiB'] <= 8,
        footprintWindowGrowth=result['earlyLateFootprintGrowthMiB'] <= 4,
        liveHeapWindowGrowth=result['earlyLateLiveHeapGrowthMiB'] <= 2,
        settledRSSCeiling=result['maximumSettledRSSDeltaMiB'] <= 64,
        transferPeakCeiling=result['maximumTransferPeakDeltaMiB'] <= 64,
        fdGrowth=result['maximumFDGrowth'] <= 2)
    result['provisionalCompositeGate'] = 'PASS' if all(checks.values()) else 'FAIL'
    result['checks'] = checks
    return result


def main(args):
    output = args.output
    root = output.parent.resolve(strict=True)
    assert output.parent == root and root.parent == Path('/private/tmp')
    suffix = root.name.removeprefix('OKVideoMac-9B.')
    assert root.name.startswith('OKVideoMac-9B.') and suffix.isascii() and suffix.isalnum()
    assert output.name.startswith('B3G') and not output.exists()
    output.mkdir(mode=0o700)
    bundle = args.xctest.resolve(strict=True); assert bundle.suffix == '.xctest'
    binary = bundle/'Contents/MacOS/OKVideoKitPackageTests'
    developer = Path('/Volumes/XcodeDev/Xcode.app/Contents/Developer')
    scenarios = [('R0',0,8),('R2',0,8),('R0',2*MIB,5),('R2',2*MIB,5)]
    save(output/'Protocol.json', dict(bodyMiB=32,scenarios=[dict(variant=v,rate=r,cycles=c) for v,r,c in scenarios],
        fixtureSHA256=hashlib.sha256(BLOCK).hexdigest(),binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        harnessSHA256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),settleMs=250,
        discardFirstCycleForSlope=True,stableWindowRule='disjoint 3+3 when possible; otherwise 2+2',
        provisionalOnly=True,officialPriorRSSGateRemainsFailed=True,
        thresholds=dict(rssSlopeMiBPerCycle=1,footprintSlopeMiBPerCycle=.5,rssEarlyLateMiB=8,
            footprintEarlyLateMiB=4,liveHeapEarlyLateMiB=2,settledRSSMiB=64,transferPeakMiB=64,fdGrowth=2),
        noProfiler=True,noForcedMemoryPressure=True,noProductionChanges=True))
    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.daemon_threads=True; server.records=[]; server.records_lock=threading.Lock()
    threading.Thread(target=server.serve_forever,daemon=True).start()
    reports=[]
    try:
        for variant,rate,cycles in scenarios:
            stem=f'{variant}-{"fast" if rate==0 else "slow"}'
            env=dict(os.environ,OKVIDEO_XMLTV_VARIANT=variant,OKVIDEO_XMLTV_TRIAL_PORT=str(server.server_port),
                OKVIDEO_XMLTV_TRIAL_BYTES=str(32*MIB),OKVIDEO_XMLTV_TRIAL_RATE=str(rate),
                OKVIDEO_XMLTV_REPEAT_CYCLES=str(cycles),OKVIDEO_XMLTV_TRIAL_SHA=digest(32*MIB))
            command=[str(developer/'usr/bin/xctest'),'-XCTest',
                'OKVideoCoreTests.XMLTVFileDownloadFeasibilityTests/testRepeatedSessionStability',str(bundle)]
            process=subprocess.run(command,env=env,capture_output=True,text=True,timeout=500)
            (output/(stem+'.stdout.log')).write_text(process.stdout)
            (output/(stem+'.stderr.log')).write_text(process.stderr)
            lines=[x.removeprefix('XMLTV_STABILITY ') for x in process.stdout.splitlines() if x.startswith('XMLTV_STABILITY ')]
            assert process.returncode==0 and len(lines)==1,(stem,process.returncode)
            report=json.loads(lines[0]); assert len(report['results'])==cycles
            assert all(r['openFDs']>=0 for r in report['results'])
            report['assessment']=assess(report)
            save(output/(stem+'.json'),report); reports.append(report)
            print(stem,report['assessment'],flush=True)
    finally:
        server.shutdown();server.server_close()
        save(output/'Server.json',server.records)
    save(output/'Results.json',reports)
    decision='ELIGIBLE FOR HUMAN GATE REVIEW' if all(r['assessment']['provisionalCompositeGate']=='PASS' for r in reports) else 'COMPOSITE GATE REJECTED'
    save(output/'Summary.json',dict(decision=decision,results=[dict(variant=r['variant'],rate=r['rate'],cycles=r['cycles'],assessment=r['assessment']) for r in reports]))
    print(decision)
    return 0 if decision.startswith('ELIGIBLE') else 2


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xctest',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    raise SystemExit(main(p.parse_args()))
