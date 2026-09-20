import gzip
import json
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET
from fixture import generate


class FixtureTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix='OKVideoMac-9A.Fixture-', dir='/private/tmp')
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def testRepeatSeedProducesIdenticalAllFiles(self):
        for name in ['a','b']:
            generate(self.root/name, count=57, channels=7, overlap=45, gap=20, aliases=2, offset=-300)
        for name in ['fixture.xml','fixture.xml.gz','fixture.json']:
            self.assertEqual((self.root/'a'/name).read_bytes(), (self.root/'b'/name).read_bytes())

    def testCountsEscapingUnicodeGzipAndMetadata(self):
        metadata = generate(self.root/'a', count=39, channels=7, title_length=50)
        xml = (self.root/'a/fixture.xml').read_bytes()
        self.assertEqual(gzip.decompress((self.root/'a/fixture.xml.gz').read_bytes()), xml)
        tree = ET.fromstring(xml)
        self.assertEqual(len(tree.findall('channel')),7)
        self.assertEqual(len(tree.findall('programme')),39)
        self.assertIn('&<>',tree.find('programme/title').text)
        self.assertEqual(metadata['count'],39)

    def testExpiredFutureGapAndLongCrossWindow(self):
        expired = generate(self.root/'expired', count=30, channels=3, shift=-100*86400)
        future = generate(self.root/'future', count=30, channels=3, shift=100*86400)
        self.assertEqual(expired['windowCount'],0)
        self.assertEqual(future['windowCount'],0)
        gap = generate(self.root/'gap', count=30, channels=3, duration=3600, gap=100, long_every=3)
        self.assertTrue(gap['windowCount'] > 0)
        pure = generate(self.root/'puregap',count=60,channels=3,gap=100)
        for query in pure['queries']:
            if query['at'] == pure['now'] + pure['duration'] * 3 // 4:
                self.assertIsNone(query['current'])

    def testNoOverwriteAndInputLimits(self):
        generate(self.root/'a',count=3,channels=3)
        with self.assertRaises(ValueError):
            generate(self.root/'a',count=3,channels=3)
        for args in [dict(count=0),dict(channels=2),dict(offset=1000),dict(title_length=5000)]:
            with self.assertRaises(ValueError):
                generate(self.root/'bad',**args)


if __name__ == '__main__':
    unittest.main()
