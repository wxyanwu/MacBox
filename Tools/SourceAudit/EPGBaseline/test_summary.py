import json
from pathlib import Path
import tempfile
import unittest

from summarize import MIB, summarize


class SummaryTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix='OKVideoMac-9A.Summary-', dir='/private/tmp')
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        (self.root/'Host.json').write_text('{}')

    def save_rows(self, rows):
        (self.root/'Runs.json').write_text(json.dumps(rows))

    def testMissingColdIsNotInventedAsMeasurementOrPass(self):
        self.save_rows([dict(case='limit', format='gzip', repeat=0, mode='production', status='EXPECTED_LIMIT_REJECTION')])
        original = (self.root/'Runs.json').read_bytes()
        result = summarize(self.root)
        self.assertEqual(result['statusCounts'], {'EXPECTED_LIMIT_REJECTION': 1, 'NOT_RUN_NO_VALID_PRODUCTION_CACHE': 1})
        self.assertEqual(result['stageMetrics'], [])
        self.assertEqual(result['summary'], [])
        self.assertEqual((self.root/'Runs.json').read_bytes(), original)

    def testExistingNonexecutedColdNotCountedTwice(self):
        self.save_rows([
            dict(case='limit', format='gzip', repeat=0, mode='production', status='EXPECTED_LIMIT_REJECTION'),
            dict(case='limit', format='gzip', repeat=0, mode='cold', status='NOT_RUN_NO_VALID_PRODUCTION_CACHE')])
        result = summarize(self.root)
        self.assertEqual(sum(result['statusCounts'].values()), 2)

    def testQueryPeaksExcludedAndSlopeUsesProgrammeScale(self):
        rows = []
        for count, delta in [(10000, 10), (50000, 30)]:
            stage = dict(milliseconds=1, sampledMaxRSS=(5+delta)*MIB,
                         sampledMaxFootprint=(2+delta)*MIB, after=dict(processPeakRSS=(5+delta)*MIB))
            report = dict(baseline=dict(rss=5*MIB, footprint=2*MIB),
                          stages=dict(import_data=stage, queries=dict(stage, sampledMaxRSS=999*MIB)), distributions={})
            name = f'{count}.json'
            (self.root/name).write_text(json.dumps(report))
            rows.append(dict(case=f'scale-{count}', count=count, format='gzip', repeat=0,
                             mode='production', status='PASS', report=name))
        self.save_rows(rows)
        result = summarize(self.root)
        self.assertEqual([s['peakRSSDeltaMiBMedian'] for s in result['summary']], [10, 30])
        self.assertEqual([s['importMsMedian'] for s in result['summary']], [1, 1])
        self.assertEqual(result['slopes'][0]['rssMiBPer10K'], 5)


if __name__ == '__main__':
    unittest.main()
