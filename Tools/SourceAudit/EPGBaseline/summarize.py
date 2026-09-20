"""Summarize measured results; never converts rejected/unexecuted work to passes."""
import argparse
from collections import Counter, defaultdict
import json
from pathlib import Path
import statistics

MIB = 1024 * 1024


def summarize(root):
    rows = json.loads((root/'Runs.json').read_bytes())
    # The first runner revision could omit its final non-executed cold row from
    # the incremental journal. Restore ONLY this control-flow status, never a
    # timing, measurement, successful query, or pass. Preserve Runs.json intact.
    for row in list(rows):
        if row['mode']=='production' and row['status']!='PASS' and not any(
            r['case']==row['case'] and r['format']==row['format'] and r['repeat']==row['repeat'] and r['mode']=='cold' for r in rows):
            rows.append(dict(case=row['case'],format=row['format'],repeat=row['repeat'],mode='cold',
                             status='NOT_RUN_NO_VALID_PRODUCTION_CACHE',derivedFromFailedProduction=True))
    host = json.loads((root/'Host.json').read_bytes())
    groups = defaultdict(list)
    metrics = []
    for row in rows:
        if not row.get('report'):
            continue
        value = json.loads((root/row['report']).read_bytes())
        for stage, metric in value['stages'].items():
            metrics.append(dict(case=row['case'],format=row['format'],repeat=row['repeat'],mode=row['mode'],status=row['status'],
                stage=stage,milliseconds=metric['milliseconds'],rssMiB=metric['sampledMaxRSS']/MIB,
                rssDeltaMiB=max(0,metric['sampledMaxRSS']-value['baseline']['rss'])/MIB,
                footprintDeltaMiB=max(0,metric['sampledMaxFootprint']-value['baseline']['footprint'])/MIB,
                kernelCumulativePeakRSSMiB=metric['after']['processPeakRSS']/MIB))
        if row['status']=='PASS' and row['case'].startswith('scale-') and row['mode'] in ['production','staged','cold']:
            # Peaks from import stages only. Queries/oracle are not used to inflate import measurement.
            stages = [v for k,v in value['stages'].items() if k not in ['queries','warm_repository_cached_rebuilds_snapshot']]
            item = dict(count=row['count'],format=row['format'],mode=row['mode'],
                peakRSSDeltaMiB=max(max(0,s['sampledMaxRSS']-value['baseline']['rss']) for s in stages)/MIB,
                peakFootprintDeltaMiB=max(max(0,s['sampledMaxFootprint']-value['baseline']['footprint']) for s in stages)/MIB,
                importMs=sum(s['milliseconds'] for k,s in value['stages'].items() if k not in ['queries','warm_repository_cached_rebuilds_snapshot']))
            groups[(row['count'],row['format'],row['mode'])].append(item)
    summary = []
    for key, values in sorted(groups.items()):
        result = dict(count=key[0],format=key[1],mode=key[2],runs=len(values))
        for field in ['peakRSSDeltaMiB','peakFootprintDeltaMiB','importMs']:
            result[field+'Median'] = statistics.median(v[field] for v in values)
            result[field+'Max'] = max(v[field] for v in values)
        summary.append(result)
    slopes = []
    for format in ['plain','gzip']:
        for mode in ['production','staged','cold']:
            series = sorted((r for r in summary if r['format']==format and r['mode']==mode),key=lambda r:r['count'])
            for previous,current in zip(series,series[1:]):
                slopes.append(dict(format=format,mode=mode,fromCount=previous['count'],toCount=current['count'],
                    rssMiBPer10K=(current['peakRSSDeltaMiBMedian']-previous['peakRSSDeltaMiBMedian'])*10000/(current['count']-previous['count'])))
            if len(series)>1:
                xs=[s['count']/10000 for s in series]; ys=[s['peakRSSDeltaMiBMedian'] for s in series]
                meanx,meany=statistics.mean(xs),statistics.mean(ys)
                slope=sum((x-meanx)*(y-meany) for x,y in zip(xs,ys))/sum((x-meanx)**2 for x in xs)
                ss=sum((y-meany)**2 for y in ys)
                residual=sum((y-(meany+slope*(x-meanx)))**2 for x,y in zip(xs,ys))
                slopes.append(dict(format=format,mode=mode,scope='OLS_all_supported_scales',rssMiBPer10K=slope,
                                   rSquared=1-residual/ss if ss else None))
    result=dict(host=host,statusCounts=dict(Counter(r['status'] for r in rows)),summary=summary,slopes=slopes,stageMetrics=metrics)
    (root/'Summary.json').write_text(json.dumps(result,indent=2)+'\n')
    lines=['# 9A measured baseline','', 'No production optimization. Loopback only; new process per sample.','',
           '## Run status','',json.dumps(result['statusCounts'],sort_keys=True),'',
           '## Resource scaling','',
           '| Programmes | Input | Mode | Runs | Median import ms | Median peak RSS delta MiB | Max RSS delta MiB | Median footprint delta MiB |',
           '|---:|---|---|---:|---:|---:|---:|---:|']
    for r in summary:
        lines.append(f"| {r['count']} | {r['format']} | {r['mode']} | {r['runs']} | {r['importMsMedian']:.2f} | {r['peakRSSDeltaMiBMedian']:.2f} | {r['peakRSSDeltaMiBMax']:.2f} | {r['peakFootprintDeltaMiBMedian']:.2f} |")
    lines += ['', 'staged deliberately retains intermediate objects; not an actual Repository peak. Its window reference scan is not a production API.', '',
              '## RSS slope (median process delta)','', '| Input | Mode | Range | MiB / 10K |', '|---|---|---|---:|']
    for r in slopes:
        span=r.get('scope',f"{r.get('fromCount')} → {r.get('toCount')}")
        lines.append(f"| {r['format']} | {r['mode']} | {span} | {r['rssMiBPer10K']:.3f} |")
    lines += ['', '## Query distributions (first repetition; all raw runs retained)', '',
              '| Case | Input | Mode | Query | Samples | p50 ms | p95 ms | max ms |', '|---|---|---|---|---:|---:|---:|---:|']
    for row in rows:
        if row.get('repeat')!=0 or row.get('status')!='PASS' or not row.get('report'):continue
        value=json.loads((root/row['report']).read_bytes())
        for name,d in sorted(value['distributions'].items()):
            lines.append(f"| {row['case']} | {row['format']} | {row['mode']} | {name} | {d['samples']} | {d['p50ms']:.5f} | {d['p95ms']:.5f} | {d['maxms']:.5f} |")
    lines += ['', 'Cold = fresh process/cache deserialization, not flushed macOS filesystem cache. First-query n=1 is not a robust percentile.',
              'The 30 window samples are a reference full scan, not an implemented window query service.',
              'The 10ms sampler can miss short peaks. Kernel peak RSS is cumulative across earlier stages; never sum stage peaks.']
    (root/'Summary.md').write_text('\n'.join(lines)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root',type=Path)
    result=summarize(parser.parse_args().root)
    print(json.dumps(result['statusCounts']))
