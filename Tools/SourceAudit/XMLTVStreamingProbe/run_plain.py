"""9B.1 serial synthetic-file benchmark; independent 9A full semantic digest.

Outputs programme rows to a tentative file, never an array. Does not remove files.
9A generator and resource sampler stay frozen; no repository/DB/cache is opened.
"""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import struct
import subprocess
import sys

sys.path.insert(0,str(Path(__file__).resolve().parent.parent/'EPGBaseline'))
from fixture import generate

def main(binary,root,mode='plain'):
    if mode not in ('plain','gzip'):raise ValueError('Explicit input mode required')
    root=root.resolve()
    if not str(root).startswith('/private/tmp/OKVideoMac-9B.') or root.exists():
        raise ValueError('New isolated output required')
    root.mkdir(mode=0o700,parents=True)
    rows=[]
    matrix=[('scale-'+str(n),dict(count=n),3) for n in [10000,50000,100000,150000,200000]]
    matrix += [('dense',dict(count=100000,channels=3),1),('sparse',dict(count=50000,channels=25000),1),
               ('overlap-gap-long-alias',dict(count=20000,channels=1000,overlap=50,gap=35,long_every=17,title_length=96,aliases=4,offset=-300),1),
               ('gap-only',dict(count=20000,gap=100),1),('expired',dict(count=20000,shift=-100*86400),1),
               ('future',dict(count=20000,shift=100*86400),1)]
    for name,kwargs,repeats in matrix:
        fixture=generate(root/'Fixtures'/name,**kwargs)
        for repeat in range(repeats):
            output=root/f'{name}-{repeat}.json'
            spool=root/f'{name}-{repeat}.rows'
            input_name='fixture.xml.gz' if mode=='gzip' else 'fixture.xml'
            process=subprocess.run([str(binary),str(root/'Fixtures'/name/input_name),str(output),str(spool),mode],capture_output=True,text=True,timeout=240)
            if process.returncode!=0:
                raise RuntimeError(f'{name} failed exit={process.returncode}: {process.stderr}')
            value=json.loads(output.read_bytes())
            digest=hashlib.sha256()
            for channel in value['channels']:
                digest.update(b'C\0')
                for field in [channel['id'],channel['displayName']]+channel.get('aliases',[]):
                    data=field.encode('utf-8'); digest.update(struct.pack('>Q',len(data))); digest.update(data)
                digest.update(b'\n')
            with spool.open('rb') as f:
                for data in iter(lambda:f.read(1024*1024),b''):digest.update(data)
            assert digest.hexdigest()==fixture['semanticSHA256'],name
            assert value['valid']==value['emitted']==fixture['count'],name
            assert value['inputBytes']==fixture['xmlBytes'],name
            if mode=='gzip':
                assert value['memberCount']==1,name
                assert value['compressedInputBytes']==(root/'Fixtures'/name/input_name).stat().st_size,name
            assert value['peakBatchCount']<=512 and value['peakBatchEstimatedBytes']<=1048576
            stage=value['stages'][mode+'_stream_to_tentative_file']
            row=dict(case=name,mode=mode,repeat=repeat,count=fixture['count'],oracle='PASS',
                     milliseconds=stage['milliseconds'],rssDeltaMiB=(stage['sampledMaxRSS']-value['baseline']['rss'])/1048576,
                     footprintDeltaMiB=(stage['sampledMaxFootprint']-value['baseline']['footprint'])/1048576,
                     peakBatchCount=value['peakBatchCount'],peakBatchEstimatedBytes=value['peakBatchEstimatedBytes'])
            rows.append(row)
            (root/'Runs.json').write_text(json.dumps(rows,indent=2)+'\n')
            print(json.dumps(row),flush=True)
    summary=[]
    for name,kwargs,_ in matrix:
        selected=[r for r in rows if r['case']==name]
        summary.append(dict(case=name,count=kwargs['count'],runs=len(selected),
            msMedian=statistics.median(r['milliseconds'] for r in selected),
            rssDeltaMiBMedian=statistics.median(r['rssDeltaMiB'] for r in selected)))
    (root/'Summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    (root/'COMPLETE.json').write_text(json.dumps(dict(mode=mode,passed=len(rows),failed=0,skipped=0,
        binarySHA256=hashlib.sha256(binary.read_bytes()).hexdigest(),
        generatorSHA256=hashlib.sha256(Path(__file__).parent.parent.joinpath('EPGBaseline/fixture.py').read_bytes()).hexdigest()))+'\n')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--binary',required=True,type=Path);p.add_argument('--output',required=True,type=Path)
    p.add_argument('--mode',choices=['plain','gzip'],default='plain')
    a=p.parse_args();main(a.binary.resolve(strict=True),a.output,a.mode)
