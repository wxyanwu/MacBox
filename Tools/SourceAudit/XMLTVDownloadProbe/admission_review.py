"""B1 real loopback response admission. No provider inputs, recursive cleanup or app launch."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import subprocess
import threading
from http.server import ThreadingHTTPServer
from run import Handler, BLOCK, MIB, digest, save
from download_task_review import assess

XML = b'<?xml version="1.0"?><tv><channel id="one"><display-name>Test</display-name></channel></tv>'
GZIP = gzip.compress(XML, mtime=0)
# Generated from precisely XML with node:zlib brotliCompressSync; independent
# Apple decoding is validated against XML's hash by the observer test.
BR = bytes.fromhex('1b5a00208c942eee12d4eac8f326909d4b24d0b487bfb073ca9906a2b5256de1e5e267b8e7f07928a4ec5ad9b00f5555d1c236d28fe5bcdb1086c9d05fb3df143b948c602d')
FIXTURES = {
    'xml': (XML, None, 'application/xml', XML),
    'gzip': (gzip.compress(XML, mtime=0), 'gzip', 'application/xml', XML),
    'br': (BR, 'br', 'application/xml', XML),
    'file.xml.gz': (GZIP, None, 'application/gzip', GZIP),
    'double.xml.gz': (gzip.compress(GZIP, mtime=0), 'gzip', 'application/gzip', GZIP),
}


class AdmissionHandler(Handler):
    def do_GET(self):
        if self.path.startswith('/bytes/'):
            return super().do_GET()
        name = self.path.removeprefix('/')
        if name not in FIXTURES and name not in ('status404', 'status206', 'range', 'oversize'):
            self.send_error(404)
            return
        wire, coding, content_type, entity = FIXTURES.get(name, (XML, None, 'application/xml', XML))
        self.send_response({'status404': 404, 'status206': 206}.get(name, 200))
        self.send_header('Content-Length', str(33*MIB if name == 'oversize' else len(wire)))
        self.send_header('Content-Type', content_type)
        self.send_header('Connection', 'close')
        if coding:
            self.send_header('Content-Encoding', coding)
        if name == 'range':
            self.send_header('Content-Range', f'bytes 0-{len(wire)-1}/{len(wire)}')
        self.end_headers()
        status = 'written'
        try:
            if name == 'oversize':
                # A valid over-limit body, not a falsely declared truncated XML.
                # Strict admission should cancel before this can finish.
                for _ in range(33*MIB//len(BLOCK)):
                    self.wfile.write(BLOCK)
            else:
                self.wfile.write(wire)
        except (BrokenPipeError, ConnectionResetError):
            status = 'cancelled'
        self.close_connection = True
        with self.server.records_lock:
            self.server.records.append(dict(fixture=name, coding=coding, status=status,
                acceptEncoding=self.headers.get('Accept-Encoding')))


def sha(data):
    return hashlib.sha256(data).hexdigest()


def main(args):
    root = args.output.parent.resolve(strict=True)
    assert root == args.output.parent and root.parent == Path('/private/tmp')
    assert root.name.startswith('OKVideoMac-9B.') and root.name.removeprefix('OKVideoMac-9B.').isalnum()
    assert args.output.name.startswith('B1') and not args.output.exists()
    args.output.mkdir(mode=0o700)
    bundle = args.xctest.resolve(strict=True)
    assert bundle.suffix == '.xctest'
    save(args.output/'Protocol.json', dict(mode=args.mode, fixtureBlockSHA256=sha(BLOCK),
        binarySHA256=sha((bundle/'Contents/MacOS/OKVideoKitPackageTests').read_bytes()),
        harnessSHA256=sha(Path(__file__).read_bytes()), production=False,
        memoryRule='R3 repeated-session thresholds unchanged; 8 cycles; 250ms settle',
        memoryInterval='includes pinned fd copy, caller SHA/read and full teardown; conservative vs R3 transfer-only peak',
        fixtures={k: dict(wireBytes=len(v[0]),wireSHA256=sha(v[0]),coding=v[1],
            entityBytes=len(v[3]),entitySHA256=sha(v[3]),xmlSHA256=sha(XML)) for k,v in FIXTURES.items()}))
    server = ThreadingHTTPServer(('127.0.0.1', 0), AdmissionHandler)
    server.daemon_threads = True
    server.records, server.records_lock = [], threading.Lock()
    threading.Thread(target=server.serve_forever,daemon=True).start()
    results = []
    try:
        jobs = [('testAdmissionAndCoding','B1_MATRIX'),('testConversionCancellationWindows','B1_CANCEL')]
        if args.mode == 'memory':
            jobs = [('testConvertedDownloadMemory','B1_MEMORY')]
        for name, prefix in jobs:
            env = dict(os.environ, OKVIDEO_B1_PORT=str(server.server_port))
            for key in ('MallocStackLogging','MallocStackLoggingNoCompact','MallocScribble','MallocGuardEdges'):
                env.pop(key, None)
            command=['/Volumes/XcodeDev/Xcode.app/Contents/Developer/usr/bin/xctest','-XCTest',
                'OKVideoCoreTests.XMLTVDownloadAdmissionTests/'+name, str(bundle)]
            # Own and reap only this child, including interruption/timeout.
            with (args.output/(name+'.stdout.log')).open('x') as out, (args.output/(name+'.stderr.log')).open('x') as err:
                child = subprocess.Popen(command,env=env,stdout=out,stderr=err)
                try:
                    code = child.wait(timeout=150)
                finally:
                    if child.poll() is None:
                        child.terminate()
                        try: child.wait(timeout=5)
                        except subprocess.TimeoutExpired: child.kill(); child.wait()
            text = (args.output/(name+'.stdout.log')).read_text()
            lines = [line[len(prefix)+1:] for line in text.splitlines() if line.startswith(prefix+' ')]
            assert code == 0 and len(lines) == 1, (name,code,'see preserved logs')
            result = json.loads(lines[0])
            if prefix == 'B1_MATRIX':
                for row in result:
                    if row['handoffs']:
                        wire, coding, kind, entity = FIXTURES[row['fixture']]
                        assert row['sha256'] == sha(entity) and row['readBytes'] == len(entity), row
                    if not row['diagnostic'] and row['fixture'] in ('gzip','br','double.xml.gz'):
                        assert row['failure'] == 'coding', row
                    if not row['diagnostic'] and row['fixture']=='oversize':
                        assert row['failure']=='length' and 'response' in row['events'], row
            if prefix == 'B1_MEMORY':
                assert len(result['results']) == 8
                assert all(r['sha256']==digest(32*MIB) and r['openFDs']>=0 for r in result['results'])
                result['assessment'] = assess(result)
            save(args.output/(name+'.json'), result)
            results.append(dict(test=name,passed=True))
            print(name, result['assessment'] if prefix=='B1_MEMORY' else f'{len(result)} rows PASS',flush=True)
            if prefix=='B1_MEMORY' and result['assessment']['provisionalCompositeGate']!='PASS':
                save(args.output/'Gate.json',dict(decision='FAIL',results=results))
                return 2
        save(args.output/'Gate.json',dict(decision='PASS',results=results))
        return 0
    finally:
        server.shutdown(); server.server_close()
        save(args.output/'Server.json',server.records)


if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--xctest',type=Path,required=True)
    p.add_argument('--output',type=Path,required=True)
    p.add_argument('--mode',choices=['matrix','memory'],required=True)
    raise SystemExit(main(p.parse_args()))
