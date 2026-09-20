"""Tests the native launcher against signed, non-production fixture bundles.

Set OKVIDEO_ACCEPTANCE_TEST_LAUNCHER to a compiled/signed launcher. These tests
only invoke --check / --initialize and never open the fixture application.
"""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

from create_acceptance_delivery import assemble, sha


@unittest.skipUnless(os.environ.get('OKVIDEO_ACCEPTANCE_TEST_LAUNCHER'), 'Explicit native launcher test binary required')
class AcceptanceLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='OKVideoMac-LauncherTest-', dir='/private/tmp')
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.app = self.base / 'Fixture.app'
        resources = self.app / 'Contents/Resources/Legal/Compliance'
        resources.mkdir(parents=True)
        binary = self.app / 'Contents/MacOS/OKVideoMac'
        binary.parent.mkdir()
        binary.write_text('#!/bin/sh\nexit 99\n')
        binary.chmod(0o755)
        (self.app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'com.okvideomac.OKVideoMac.acceptance8b3b',
            'CFBundleVersion': '101', 'CFBundleShortVersionString': '0.6.1',
            'CFBundleExecutable': 'OKVideoMac', 'CFBundlePackageType': 'APPL'}))
        (resources / 'SOURCE_RELEASE_INDEX.json').write_text(json.dumps({'local_acceptance': {'source_sha256': 'c' * 64}}))
        subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(self.app)], check=True, capture_output=True)
        self.delivery = self.base / '8C2 delivery with spaces'
        assemble(self.app, Path(os.environ['OKVIDEO_ACCEPTANCE_TEST_LAUNCHER']), self.delivery)
        self.root = Path(tempfile.mkdtemp(prefix='OKVideoMac-8B3B-LauncherTest.', dir='/private/tmp'))
        self.addCleanup(shutil.rmtree, self.root)

    def run_launcher(self, *args, success=False):
        result = subprocess.run([str(self.delivery / 'AcceptanceLauncher'), *args], capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def testValidAndMissingRootFailClosed(self):
        self.run_launcher('--check', '--root', str(self.root), success=True)
        self.run_launcher('--check', '--root', '')
        self.run_launcher('--check', '--root', str(self.root / 'missing'))
        self.run_launcher('--check')
        self.assertEqual(list(self.root.iterdir()), [])

    def testRootAliasLinksPermissionsAndNonAcceptanceLocationReject(self):
        self.run_launcher('--check', '--root', str(self.base))
        self.root.chmod(0o755)
        self.run_launcher('--check', '--root', str(self.root))
        self.root.chmod(0o700)
        link = self.root / 'escape'
        link.symlink_to(self.base, target_is_directory=True)
        self.run_launcher('--check', '--root', str(self.root))
        link.unlink()
        sentinel = self.base / 'private-data'
        sentinel.write_text('PRIVATE_FIXTURE_DO_NOT_WRITE')
        before = sha(sentinel)
        os.link(sentinel, link)
        self.run_launcher('--check', '--root', str(self.root))
        self.assertEqual(sha(sentinel), before)

    def testDatabasePermissionGuard(self):
        folder = self.root / 'Application Support/Database'
        folder.mkdir(parents=True)
        db = folder / 'OKVideoMac.sqlite3'
        db.write_bytes(b'fixture only - never opened as sqlite')
        db.chmod(0o644)
        self.run_launcher('--check', '--root', str(self.root))
        db.chmod(0o600)
        self.run_launcher('--check', '--root', str(self.root), success=True)

    def testManifestIdentitySourceAndLauncherMismatchReject(self):
        path = self.delivery / 'AcceptanceManifest.json'
        original = json.loads(path.read_text())
        for field, value in [('bundleID', 'com.okvideomac.OKVideoMac'), ('phase', 'public'),
                             ('sourceSHA256', 'd' * 64), ('launcherSHA256', '0' * 64),
                             ('publicReleaseEligible', True)]:
            with self.subTest(field=field):
                changed = dict(original, **{field: value})
                path.write_text(json.dumps(changed))
                self.run_launcher('--check', '--root', str(self.root))

    def testAppMutationAndExternalAppLinkReject(self):
        app = self.delivery / 'OKVideoMac.app'
        extra = app / 'Contents/Injected.txt'
        extra.write_text('not in sealed inventory')
        self.run_launcher('--check', '--root', str(self.root))
        extra.unlink()
        moved = self.base / 'Outside.app'
        app.rename(moved)
        app.symlink_to(moved, target_is_directory=True)
        self.run_launcher('--check', '--root', str(self.root))

    def testInitializeExplicitReusableAndNeverOverwrite(self):
        self.run_launcher('--initialize', success=True)
        config = self.delivery / 'AcceptanceWorkspace.json'
        initialized = Path(json.loads(config.read_text())['root'])
        self.addCleanup(shutil.rmtree, initialized)
        before = config.read_bytes()
        self.assertEqual(list(initialized.iterdir()), [])
        self.run_launcher('--check', success=True)
        self.run_launcher('--initialize')
        self.assertEqual(config.read_bytes(), before)

    def testDeliveryCanMoveAndUnknownArgumentsReject(self):
        self.delivery = self.delivery.rename(self.base / 'Moved 8C2')
        self.run_launcher('--check', '--root', str(self.root), success=True)
        self.run_launcher('--launch-official')
        self.assertFalse((self.delivery / 'AcceptanceWorkspace.json').exists())


if __name__ == '__main__':
    unittest.main()
