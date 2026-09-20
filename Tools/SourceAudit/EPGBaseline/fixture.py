"""Deterministic synthetic XMLTV only; no provider data or network access.

Generator v1: integer PRNG, UTC arithmetic, explicit offset, gzip mtime=0.
Large XML is streamed to disk, not stored in the repository.
"""
import argparse
from datetime import datetime, timedelta, timezone
import gzip
import hashlib
import json
from pathlib import Path
import struct
from xml.sax.saxutils import escape, quoteattr

ANCHOR = 1789257600  # 2026-09-13 00:00:00 UTC; never Date.now().


def record_hash(digest, kind, fields):
    digest.update(kind.encode('ascii') + b'\0')
    for field in fields:
        value = str(field).encode('utf-8')
        digest.update(struct.pack('>Q', len(value)))
        digest.update(value)
    digest.update(b'\n')


def noise(seed, index):
    x = (seed ^ (index * 0x9E3779B9)) & 0xFFFFFFFF
    x ^= x >> 16
    x = (x * 0x85EBCA6B) & 0xFFFFFFFF
    x ^= x >> 13
    return x


def channel(index, aliases):
    identity = 'CCTV1' if index == 0 else f'ch{index:05d}'
    name = 'CCTV1' if index == 0 else f'频道 {index:05d} 📺 e\u0301'
    names = [name] + [f'别名 {index:05d}-{n}' for n in range(aliases)]
    if index in (1, 2):
        names.append('共同别名')
    return identity, names


def generate(destination, count=10000, channels=1000, seed=17, title_length=24,
             aliases=1, overlap=0, gap=0, duration=1800, offset=480,
             shift=0, long_every=0):
    if destination.exists():
        raise ValueError('New output directory required; never overwrite fixtures')
    if not (0 < count <= 1000000 and 3 <= channels <= 100000 and 1 <= title_length <= 4096
            and 0 <= aliases <= 8 and 0 <= overlap <= 100 and 0 <= gap <= 100
            and 1 <= duration <= 86400 and -720 <= offset <= 840 and long_every >= 0):
        raise ValueError('Invalid bounded synthetic fixture parameters')
    destination.mkdir(parents=True, mode=0o700)
    zone = timezone(timedelta(minutes=offset))
    def stamp(seconds):
        return datetime.fromtimestamp(seconds, zone).strftime('%Y%m%d%H%M%S %z')
    digest = hashlib.sha256()
    xml_digest = hashlib.sha256()
    # Retain only three channels for independent sample-oracle queries.
    samples = {channel(i, aliases)[0]: [] for i in range(3)}
    now = ANCHOR + 2 * 3600
    window_start, window_end = now - 86400, now + 7 * 86400
    window_count = 0
    with (destination / 'fixture.xml').open('xb') as file:
        def emit(text):
            data = text.encode('utf-8')
            file.write(data)
            xml_digest.update(data)
        emit('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n')
        for i in range(channels):
            identity, names = channel(i, aliases)
            emit(f'<channel id={quoteattr(identity)}>')
            for name in names:
                emit('<display-name>' + escape(name) + '</display-name>')
            emit('</channel>\n')
            record_hash(digest, 'C', [identity] + names)
        for i in range(count):
            c, slot = i % channels, i // channels
            identity = channel(c, 0)[0]
            random = noise(seed, i)
            start = ANCHOR + shift + slot * duration
            if random % 100 < overlap:
                start -= duration // 2
            length = max(1, duration // 2) if (random >> 8) % 100 < gap else duration
            end = start + (duration * 20 if long_every and i % long_every == 0 else length)
            title = f'节目{i:07d} ' + ('测é📺&<> ' * (title_length // 7 + 1))[:title_length]
            emit(f'<programme channel={quoteattr(identity)} start={quoteattr(stamp(start))} stop={quoteattr(stamp(end))}><title>{escape(title)}</title></programme>\n')
            record_hash(digest, 'P', [identity, title, start, end])
            if end > window_start and start < window_end:
                window_count += 1
            if identity in samples:
                samples[identity].append(dict(channelID=identity, title=title, start=start, end=end, ordinal=i))
        emit('</tv>\n')
    with (destination/'fixture.xml').open('rb') as source, (destination/'fixture.xml.gz').open('xb') as target:
        with gzip.GzipFile(filename='', fileobj=target, mode='wb', mtime=0, compresslevel=6) as zipper:
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                zipper.write(chunk)
    def selected(item):
        return {k: v for k, v in item.items() if k != 'ordinal'} if item else None
    query_results = []
    for identity, programmes in samples.items():
        ordered = sorted(programmes, key=lambda p: (p['start'], p['ordinal']))
        times = sorted({now, now + duration * 3 // 4, ANCHOR - 1, ANCHOR, ANCHOR + duration,
                        ANCHOR + duration - 1, window_end, now + 1000 * 86400})
        for at in times:
            current = next((p for p in reversed(ordered) if p['start'] <= at < p['end']), None)
            following = next((p for p in ordered if p['start'] > at), None)
            query_results.append(dict(channelID=identity, at=at, current=selected(current), next=selected(following)))
    metadata = dict(generatorVersion=1, count=count, channels=channels, seed=seed,
        titleLength=title_length, aliases=aliases, overlapPercent=overlap, gapPercent=gap,
        duration=duration, offsetMinutes=offset, shift=shift, longEvery=long_every,
        anchor=ANCHOR, now=now, xmlSHA256=xml_digest.hexdigest(),
        semanticSHA256=digest.hexdigest(), windowStart=window_start, windowEnd=window_end,
        windowCount=window_count, queries=query_results,
        xmlBytes=(destination/'fixture.xml').stat().st_size,
        gzipBytes=(destination/'fixture.xml.gz').stat().st_size,
        gzipSHA256=hashlib.sha256((destination/'fixture.xml.gz').read_bytes()).hexdigest())
    (destination/'fixture.json').write_text(json.dumps(metadata, ensure_ascii=False, sort_keys=True, indent=2) + '\n')
    return metadata


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    for flag, default in [('count',10000),('channels',1000),('seed',17),('title-length',24),
                          ('aliases',1),('overlap',0),('gap',0),('duration',1800),('offset',480),
                          ('shift',0),('long-every',0)]:
        parser.add_argument('--'+flag, type=int, default=default)
    args = vars(parser.parse_args())
    output = generate(**args)
    print(json.dumps({k:output[k] for k in ['count','xmlBytes','gzipBytes','semanticSHA256']}))
