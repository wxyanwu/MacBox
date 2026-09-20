"""Serial isolated-process baseline. Serves generated fixtures on 127.0.0.1 only."""
import argparse
from functools import partial
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import threading
import time
import zlib
from fixture import generate


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        parts = self.path.split('/')
        if len(parts) != 3 or parts[1] not in self.server.allowed or parts[2] not in ['fixture.xml','fixture.xml.gz']:
            self.send_error(404); return
        path = self.server.fixture_root / parts[1] / parts[2]
        self.server.requests.append(parts[1] + '/' + parts[2])
        self.send_response(200)
        self.send_header('Content-Length',str(path.stat().st_size))
        self.send_header('Content-Type','application/gzip' if parts[2].endswith('.gz') else 'application/xml')
        self.end_headers()
        try:
            with path.open('rb') as file:
                for data in iter(lambda:file.read(64*1024),b''):
                    self.wfile.write(data)
        except (BrokenPipeError,ConnectionResetError):
            pass  # Production byte-limit cancellation is expected, not EOF success.
    def log_message(self,*args):
        pass


def run(binary, root, repetitions, quick=False):
    root = root.resolve()
    if not str(root).startswith('/private/tmp/OKVideoMac-9A.') or root.exists():
        raise ValueError('New explicit /private/tmp/OKVideoMac-9A.* output directory required')
    root.mkdir(mode=0o700,parents=True)
    fixture_root = root/'Fixtures'
    matrix = [('scale-'+str(n),dict(count=n)) for n in ([10000] if quick else [10000,50000,100000,150000,200000])]
    if not quick:
        matrix += [
            ('dense',dict(count=100000,channels=3)),
            ('sparse',dict(count=50000,channels=25000)),
            ('overlap-gap-long-alias',dict(count=20000,channels=1000,overlap=50,gap=35,long_every=17,title_length=96,aliases=4,offset=-300)),
            ('gap-only',dict(count=20000,gap=100)),
            ('expired',dict(count=20000,shift=-100*86400)),
            ('future',dict(count=20000,shift=100*86400)),
            ('limit-200001',dict(count=200001))]
    fixtures = {}
    for name, kwargs in matrix:
        fixtures[name] = generate(fixture_root/name,**kwargs)
        print('generated',name,fixtures[name]['xmlBytes'],fixtures[name]['gzipBytes'],flush=True)
    server = ThreadingHTTPServer(('127.0.0.1',0),Handler)
    server.fixture_root, server.allowed, server.requests = fixture_root, set(fixtures), []
    thread = threading.Thread(target=server.serve_forever,daemon=True); thread.start()
    host = dict(platform=platform.platform(), machine=platform.machine(), python=platform.python_version(),
                zlib=zlib.ZLIB_VERSION, zlibRuntime=zlib.ZLIB_RUNTIME_VERSION,
                binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
                fixtureGeneratorSHA256=hashlib.sha256(Path(__file__).with_name('fixture.py').read_bytes()).hexdigest(),
                samplingMs=10, repetitions=repetitions, osDiskCacheFlushed=False,
                cpu=subprocess.check_output(['sysctl','-n','machdep.cpu.brand_string'],text=True).strip(),
                physicalMemory=int(subprocess.check_output(['sysctl','-n','hw.memsize'],text=True)))
    (root/'Host.json').write_text(json.dumps(host,indent=2)+'\n')
    results = []
    try:
        for name, metadata in fixtures.items():
            formats = ['plain','gzip'] if name.startswith('scale') else ['gzip']
            for format in formats:
                input_name = 'fixture.xml' + ('.gz' if format == 'gzip' else '')
                for repeat in range(repetitions if name.startswith('scale') else 1):
                    cache = root/f'Cache-{name}-{format}-{repeat}'
                    modes = ['fetch','staged','production','cold']
                    if name == 'scale-200000' and format == 'gzip':
                        modes.append('cancel')
                    production_ok = False
                    for mode in modes:
                        if mode == 'cold' and not production_ok:
                            results.append(dict(case=name,format=format,repeat=repeat,mode=mode,status='NOT_RUN_NO_VALID_PRODUCTION_CACHE'))
                            (root/'Runs.json').write_text(json.dumps(results,indent=2)+'\n')
                            continue
                        report = root/f'{name}-{format}-{repeat}-{mode}.json'
                        url = f'http://127.0.0.1:{server.server_port}/{name}/{input_name}'
                        command = [str(binary),mode,str(fixture_root/name/'fixture.json'),str(fixture_root/name/input_name),url,str(cache),str(report)]
                        started = time.monotonic()
                        try:
                            process = subprocess.run(command,capture_output=True,text=True,timeout=240)
                            value = json.loads(report.read_bytes()) if report.exists() else {'status':'NO_REPORT'}
                            if process.stderr:
                                # Synthetic harness only; no user URLs or credentials.
                                (root/(report.stem+'.stderr')).write_text(process.stderr)
                            expected_reject = (mode in ['fetch','production'] and (metadata['xmlBytes'] if format=='plain' else metadata['gzipBytes']) > 32*1024*1024)
                            expected_reject |= mode in ['staged','production'] and (metadata['xmlBytes'] > 64*1024*1024 or metadata['count'] > 200000)
                            status = 'PASS' if process.returncode == 0 else ('EXPECTED_LIMIT_REJECTION' if expected_reject and process.returncode == 1 and value['status']=='REJECTED_OR_FAILED' else 'FAILED')
                            if expected_reject and process.returncode == 0:
                                status = 'FAILED_LIMIT_NOT_ENFORCED'
                            row = dict(case=name,format=format,repeat=repeat,mode=mode,status=status,exitCode=process.returncode,report=report.name,
                                       elapsedSeconds=time.monotonic()-started,count=metadata['count'])
                            if mode=='production': production_ok = status=='PASS'
                        except subprocess.TimeoutExpired:
                            row = dict(case=name,format=format,repeat=repeat,mode=mode,status='TIMEOUT_NOT_COMPLETED',count=metadata['count'])
                        results.append(row)
                        (root/'Runs.json').write_text(json.dumps(results,indent=2)+'\n')
                        print(name,format,repeat,mode,row['status'],flush=True)
    finally:
        server.shutdown(); server.server_close()
        (root/'Runs.json').write_text(json.dumps(results,indent=2)+'\n')
        (root/'Requests.json').write_text(json.dumps(server.requests,indent=2)+'\n')
    return results


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',type=Path,required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--repetitions',type=int,default=3)
    parser.add_argument('--quick',action='store_true')
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 5: parser.error('repetitions must be 1...5')
    rows = run(args.binary.resolve(strict=True),args.output,args.repetitions,args.quick)
    if any(r['status'].startswith(('FAILED','TIMEOUT')) for r in rows): sys.exit(1)
