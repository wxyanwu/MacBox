#!/usr/bin/env python3
"""Builder-only assembly of an offline, native 8C.2 acceptance launcher.

No private data, running processes, database connections, or app installation.
The recipient needs neither Python nor Xcode.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as handle:
        for data in iter(lambda: handle.read(1024 * 1024), b''):
            digest.update(data)
    return digest.hexdigest()


def inventory(root):
    values = []
    for parent, dirs, files in os.walk(root, followlinks=False):
        for name in sorted(dirs + files):
            path = Path(parent) / name
            row = {'path': str(path.relative_to(root)),
                   'executable': bool(path.lstat().st_mode & 0o111)}
            if path.is_symlink():
                path.resolve(strict=True).relative_to(root)
                row['link'] = os.readlink(path)
            elif path.is_file():
                row['sha256'] = sha(path)
            elif path.is_dir():
                continue
            else:
                raise ValueError('Unsupported app entry')
            values.append(row)
    return sorted(values, key=lambda row: row['path'])


def assemble(app, launcher, destination):
    app, launcher = app.resolve(strict=True), launcher.resolve(strict=True)
    if destination.exists():
        raise ValueError('Destination already exists; never overwrite an acceptance delivery')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    assert (info['CFBundleIdentifier'], info['CFBundleShortVersionString'], info['CFBundleVersion']) == (
        'com.okvideomac.OKVideoMac.acceptance8b3b', '0.6.1', '101')
    index = json.loads((app / 'Contents/Resources/Legal/Compliance/SOURCE_RELEASE_INDEX.json').read_bytes())
    source_hash = index['local_acceptance']['source_sha256']
    assert len(source_hash) == 64 and all(c in '0123456789abcdef' for c in source_hash)
    for target in (app, launcher):
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(target)], check=True)
    destination.mkdir(mode=0o700, parents=False)
    copied = destination / 'OKVideoMac.app'
    subprocess.run(['/usr/bin/ditto', str(app), str(copied)], check=True)
    shutil.copy2(launcher, destination / 'AcceptanceLauncher')
    manifest = dict(schema=1, phase='8C.2-D', acceptanceOnly=True, publicReleaseEligible=False,
                    bundleID=info['CFBundleIdentifier'], version='0.6.1', build='101',
                    sourceSHA256=source_hash, launcherSHA256=sha(destination / 'AcceptanceLauncher'),
                    files=inventory(copied))
    (destination / 'AcceptanceManifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n')
    for filename, flag in [('Initialize-8C2.command', '--initialize'), ('Launch-8C2.command', '')]:
        path = destination / filename
        path.write_text('#!/bin/zsh\nset -eu\ncd -- "${0:A:h}"\n./AcceptanceLauncher ' + flag + '\n')
        path.chmod(0o755)
    shutil.copy2(Path(__file__).with_name('ACCEPTANCE_8C2_README.md'), destination / 'README.md')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(copied)], check=True)
    print('Assembled LOCAL 8C.2-D delivery; no private data included:', destination)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--launcher', required=True, type=Path)
    parser.add_argument('--destination', required=True, type=Path)
    options = parser.parse_args()
    assemble(options.app, options.launcher, options.destination)
