"""Frozen 9C.3 Release matrix: generate fixtures outside measured processes."""
import argparse
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import time

def generate(root, count):
    root.mkdir(parents=True)
    anchor = datetime(2026, 1, 1, tzinfo=timezone.utc)
    digest = hashlib.sha256()
    path = root / 'fixture.xml'
    with path.open('wb') as out:
        out.write(b'<tv>')
        for channel in range(100):
            out.write(f'<channel id="c{channel}"><display-name>C{channel}</display-name></channel>'.encode())
        for n in range(count):
            start = anchor + timedelta(minutes=n//100); end = start + timedelta(minutes=1)
            out.write(f'<programme channel="c{n%100}" start="{start:%Y%m%d%H%M%S} +0000" stop="{end:%Y%m%d%H%M%S} +0000"><title>T{n}</title></programme>'.encode())
            digest.update(f'{n}|c{n%100}|T{n}|{int(start.timestamp())}|{int(end.timestamp())}\n'.encode())
        out.write(b'</tv>')
    assert path.stat().st_size <= 32*1024*1024
    with path.open('rb') as src, (root/'fixture.xml.gz').open('wb') as target:
        with gzip.GzipFile(fileobj=target, mode='wb', mtime=0, filename='') as out:
            while block := src.read(65536): out.write(block)
    record = {'count':count,'digest':digest.hexdigest(), 'files':{}}
    for name in ['fixture.xml','fixture.xml.gz']:
        data=(root/name).read_bytes(); record['files'][name]={'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}
    (root/'fixture.json').write_text(json.dumps(record,indent=2))
    return record

def main():
    p=argparse.ArgumentParser(); p.add_argument('--bundle',type=Path,required=True);p.add_argument('--output',type=Path,required=True)
    a=p.parse_args(); a.output.mkdir(parents=True,exist_ok=False)
    fixtures={n:generate(a.output/str(n),n) for n in [10000,50000,100000,200000]}
    binary=a.bundle/'Contents/MacOS/OKVideoKitPackageTests'
    manifest={'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),
        'machine':subprocess.check_output(['/usr/sbin/system_profiler','SPHardwareDataType']).decode(),
        'os':subprocess.check_output(['/usr/bin/sw_vers']).decode(),
        'swift':subprocess.check_output(['/Volumes/XcodeDev/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift','--version']).decode(),
        'xcode':subprocess.check_output(['/Volumes/XcodeDev/Xcode.app/Contents/Developer/usr/bin/xcodebuild','-version']).decode(),
        'startedUTC':datetime.now(timezone.utc).isoformat(), 'protocol':'9C.3 v1',
        'fixtures':fixtures}
    # Do not include hardware serial number / UUID in evidence.
    manifest['machine']='\n'.join(line for line in manifest['machine'].splitlines() if not any(k in line for k in ['Serial Number','UUID','UDID']))
    (a.output/'manifest.json').write_text(json.dumps(manifest,indent=2))
    records=[]
    for count,fixture in fixtures.items():
        root=a.output/str(count)
        server=subprocess.Popen(['/usr/bin/python3',str(Path(__file__).with_name('server.py')),str(root)])
        try:
            for _ in range(500):
                if (root/'port').exists(): break
                time.sleep(.01)
            port=(root/'port').read_text()
            for name in ['fixture.xml','fixture.xml.gz']:
                for mode in ['cold','warm']:
                    for repeat in range(1,4):
                        label=f'{count}-{name}-{mode}-{repeat}'; output=a.output/(label+'.json')
                        env=dict(os.environ,EPG9C3_URL=f'http://127.0.0.1:{port}/{name}',EPG9C3_COUNT=str(count),
                            EPG9C3_OUTPUT=str(output),EPG9C3_DIGEST=fixture['digest'],EPG9C3_MODE=mode)
                        command=['/Volumes/XcodeDev/Xcode.app/Contents/Developer/usr/bin/xctest','-XCTest',
                            'OKVideoPersistenceTests.EPGImportResourceTests/testReleaseNetworkImportResourceGate',str(a.bundle)]
                        with (a.output/(label+'.log')).open('w') as log:
                            run=subprocess.run(command,env=env,stdout=log,stderr=subprocess.STDOUT,timeout=300)
                        value=json.loads(output.read_text()) if output.exists() else {}
                        records.append({'label':label,'exit':run.returncode,**value})
                        (a.output/'results.json').write_text(json.dumps(records,indent=2))
                        print(label, 'exit',run.returncode,'rss',value.get('rssDelta'),'footprint',value.get('footprintDelta'),flush=True)
                        if run.returncode: raise RuntimeError('gate failed; retain evidence, do not continue')
        finally: server.terminate();server.wait()
    checks=[]
    for mode in ['cold','warm']:
        for gzip_value in [False,True]:
            for metric in ['rssDelta','footprintDelta']:
                maxima={n:max(r[metric] for r in records if r['count']==n and r['mode']==mode and r['gzip']==gzip_value) for n in [50000,200000]}
                delta=maxima[200000]-maxima[50000]
                checks.append({'mode':mode,'gzip':gzip_value,'metric':metric,'scaleDelta':delta,'passed':delta<=8*1024*1024})
    (a.output/'scale-checks.json').write_text(json.dumps(checks,indent=2))
    assert all(c['passed'] for c in checks), 'scale memory gate failed'
    print('48 independent Release runs and scale checks passed',flush=True)

if __name__=='__main__': main()
