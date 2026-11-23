"""Unit tests for tools/Analyze-JnaSoak.py. Run: python -m unittest discover -s tools/tests -p "test_*.py"."""
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
SPEC = importlib.util.spec_from_file_location('analyze_jna_soak', os.path.join(TOOLS, 'Analyze-JnaSoak.py'))
soak = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(soak)

MIB = 1024 * 1024


def sample(elapsed_s, private=700 * MIB, heap=60 * MIB, nmt=640 * MIB, ws=200 * MIB, handles=560, threads=40,
           cpu_ms=None, gc=None):
    point = {
        'iteration': 0, 'elapsedMs': elapsed_s * 1000.0,
        'resources': {'utc': '2026-01-01T00:00:00Z', 'java': {
            'available': True, 'pid': 100, 'startUtc': '2026-01-01T00:00:00Z',
            'cpuMs': elapsed_s * 250.0 if cpu_ms is None else cpu_ms, 'privateBytes': private,
            'workingSetBytes': ws, 'handles': handles, 'threads': threads}},
        'nmtReservedBytes': nmt + 9000 * MIB, 'nmtCommittedBytes': nmt,
        'heapCommittedBytes': 512 * MIB, 'heapUsedBytes': heap,
    }
    if gc is not None:
        point['gc'] = {'available': True, 'totalInvocations': gc, 'totalTimeMs': gc * 2.0}
    return point


def latency(p95, count=600, p50=None):
    p50 = p95 * 0.8 if p50 is None else p50
    return {'count': count, 'mean': p50, 'p50': p50, 'p95': p95, 'p99': p95 * 1.2, 'max': p95 * 1.5}


def interval(index, start_s, duration_s=60.0, session=0, snapshot_p95=60.0, count=600, ips=10.0, resources=None,
             failed=0, closed_by='interval'):
    return {
        'index': index, 'sessionIndex': session, 'pid': 100 + session,
        'startElapsedMs': start_s * 1000.0, 'endElapsedMs': (start_s + duration_s) * 1000.0,
        'durationSeconds': duration_s, 'closedBy': closed_by,
        'attemptedIterations': count + failed, 'completedIterations': count, 'failedIterations': failed,
        'mutationIterations': 4, 'requestsCompleted': count * 4, 'requestsFailed': failed, 'timeouts': failed,
        'errorCounts': {'TIMEOUT': failed} if failed else {},
        'iterationsPerSecond': ips, 'requestsPerSecond': ips * 4,
        'latencyMs': {'snapshot': latency(snapshot_p95, count), 'findElement': latency(0.4, count * 2),
                      'getElementInfo': latency(5.0, count), 'setValue': latency(20.0, 4), 'invoke': latency(18.0, 4)},
        'resources': resources,
    }


def report(sessions, intervals=None, **extra):
    data = {
        'schemaVersion': 2, 'utc': '2026-01-01T00:00:00Z', 'finishedUtc': '2026-01-01T08:00:00Z',
        'environment': {'os': 'Windows test', 'processorCount': 8, 'java': 'openjdk 21'},
        'passed': True, 'stage': 'complete', 'intervalSeconds': 60, 'sampleIntervalSeconds': 60,
        'attemptedIterations': 1000, 'completedIterations': 1000, 'failedIterations': 0, 'failureRate': 0,
        'mutationIterations': 50, 'requestsCompleted': 4000, 'requestsFailed': 0, 'timeouts': 0, 'errorCounts': {},
        'unexpectedJvmExits': 0, 'sessionRestarts': max(0, len(sessions) - 1),
        'latencyMs': {'snapshot': latency(60.0, 1000)},
        'operationLatencyMs': {'snapshot': latency(60.0, 1000), 'findElement': latency(0.4, 2000)},
        'latencyStatistics': {'latencyMs': 'histogram'},
        'sessions': [{'index': i, 'pid': 100 + i, 'startElapsedMs': s[0]['elapsedMs'], 'completedIterations': 500,
                      'mutationIterations': 25, 'exitedNormally': True, 'endReason': 'run-end', 'samples': s}
                     for i, s in enumerate(sessions)],
        'intervals': intervals or [],
        'elapsedMs': 8 * 3600 * 1000.0,
    }
    data.update(extra)
    return data


def run(data, **options):
    model = soak.normalize(data)
    analysis = soak.analyze(model, **options)
    return model, analysis, soak.render(model, analysis, 'input.json')


def metric(analysis, field, session=0):
    return next(r for r in analysis['memory'] if r['field'] == field and r['session'] == session)


def hours(count, step_minutes=5):
    return [i * step_minutes * 60.0 for i in range(count)]


class AnalyzerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_normal_report_is_stable(self):
        samples = [sample(t, gc=i) for i, t in enumerate(hours(97))]  # 8 h
        intervals = [interval(i, i * 60.0) for i in range(480)]
        model, analysis, text = run(report([samples], intervals))
        self.assertEqual(model['schema'], 2)
        for field in ('private', 'nmt_committed', 'handles', 'threads', 'heap_used'):
            self.assertEqual(metric(analysis, field)['status'], 'STABLE', field)
        self.assertEqual(analysis['latency']['ops']['snapshot']['status'], 'STABLE')
        self.assertIn('**종합 판정: PASS**', text)
        for number in range(1, 13):
            self.assertIn('## %d. ' % number, text)
        self.assertIn('GC (HotSpot jvmstat', text)

    def test_missing_fields_are_not_estimated(self):
        model, analysis, text = run({'passed': True, 'sessions': [{'samples': [{'elapsedMs': 0}]}]})
        self.assertIn(soak.NA, text)
        self.assertIn('구간별 지연 데이터 NOT AVAILABLE', text)
        self.assertNotIn('None', text)
        self.assertEqual(metric(analysis, 'private')['status'], soak.NA)
        self.assertIsNone(model['requests_completed'])

    def test_failure_during_run(self):
        samples = [sample(t) for t in hours(6)]
        failure = {'code': 'TIMEOUT', 'operation': 'snapshot', 'message': 'Timed out waiting for snapshot.',
                   'elapsedMs': 1500000.0, 'sessionIndex': 0, 'intervalIndex': 25, 'jvmExited': True}
        data = report([samples], [interval(i, i * 60.0) for i in range(25)] +
                      [interval(25, 1500.0, 20.0, count=3, failed=1, closed_by='failure')],
                      passed=False, stage='iteration/900', error='Timed out waiting for snapshot.',
                      failedIterations=1, attemptedIterations=1001, timeouts=1, requestsFailed=1,
                      errorCounts={'TIMEOUT': 1}, failures=[failure], unexpectedJvmExits=1)
        data['sessions'][0].update(exitedNormally=False, unexpectedExit=True, exitCode=-1073741819, endReason='failure')
        model, analysis, text = run(data)
        self.assertEqual(soak.run_status(model), 'FAILED')
        self.assertIn('**종합 판정: FAIL**', text)
        self.assertIn('TIMEOUT=1', text)
        self.assertIn('Abnormal JVM termination', text)
        self.assertIn('Timed out waiting for snapshot.', text)
        self.assertIn('failure', text)

    def test_multiple_sessions_are_trended_separately(self):
        first = [sample(t, private=700 * MIB + t * 10) for t in hours(49)]  # 4 h, tiny growth
        second = [sample(4 * 3600.0 + t, private=650 * MIB + t * 10) for t in hours(49)]
        intervals = [interval(i, i * 60.0, session=0 if i < 240 else 1) for i in range(480)]
        model, analysis, text = run(report([first, second], intervals))
        self.assertEqual(len(model['sessions']), 2)
        self.assertEqual(metric(analysis, 'private', 0)['status'], 'STABLE')
        self.assertEqual(metric(analysis, 'private', 1)['status'], 'STABLE')
        self.assertIn('| Session restarts | 1 |', text)

    def test_memory_growth_is_flagged(self):
        samples = [sample(t, private=700 * MIB + t / 3600.0 * 20 * MIB, nmt=640 * MIB + t / 3600.0 * 8 * MIB)
                   for t in hours(49)]
        model, analysis, text = run(report([samples]))
        private = metric(analysis, 'private')
        self.assertEqual(private['status'], 'SUSTAINED GROWTH')
        self.assertAlmostEqual(private['slope_h'] / MIB, 20.0, places=3)
        self.assertEqual(metric(analysis, 'nmt_committed')['status'], 'SUSTAINED GROWTH')
        self.assertEqual(metric(analysis, 'working_set')['status'], 'STABLE')
        self.assertIn('**종합 판정: PASS WITH WARNINGS**', text)

    def test_memory_stabilization_is_not_reported_as_leak(self):
        values = [700 * MIB + min(t, 7200.0) / 3600.0 * 30 * MIB for t in hours(97)]
        samples = [sample(t, private=v) for t, v in zip(hours(97), values)]
        _, analysis, _ = run(report([samples]))
        self.assertIn(metric(analysis, 'private')['status'], ('STABLE', 'GROWTH SLOWING'))

    def test_heap_sawtooth_uses_lower_envelope(self):
        samples = [sample(t, heap=(40 + (i % 5) * 50) * MIB) for i, t in enumerate(hours(97))]
        _, analysis, _ = run(report([samples]))
        heap = metric(analysis, 'heap_used')
        self.assertTrue(heap['envelope'])
        self.assertEqual(heap['status'], 'STABLE')

    def test_short_run_is_inconclusive(self):
        samples = [sample(t, private=700 * MIB + t * 10000) for t in range(0, 61, 10)]
        model, analysis, text = run(report([samples], elapsedMs=61000.0))
        self.assertEqual(metric(analysis, 'private')['status'], 'INCONCLUSIVE')
        self.assertIn('INCONCLUSIVE', text)
        self.assertNotIn('WARN', text)

    def test_latency_increase_is_degradation(self):
        intervals = [interval(i, i * 60.0, snapshot_p95=50.0 + i * 0.25, ips=10.0 - i * 0.01) for i in range(240)]
        _, analysis, text = run(report([[sample(t) for t in hours(49)]], intervals))
        snapshot = analysis['latency']['ops']['snapshot']
        self.assertEqual(snapshot['status'], 'DEGRADING')
        self.assertGreater(snapshot['late_p95'], snapshot['early_p95'] * 1.2)
        self.assertEqual(analysis['latency']['ops']['getElementInfo']['status'], 'STABLE')
        self.assertEqual(analysis['latency']['throughput']['status'], 'DEGRADING')
        self.assertIn('snapshot p95 rose', text)

    def test_low_count_intervals_are_excluded(self):
        intervals = [interval(i, i * 60.0, count=5 if i % 2 else 600, snapshot_p95=500.0 if i % 2 else 50.0)
                     for i in range(160)]
        _, analysis, text = run(report([[sample(t) for t in hours(49)]], intervals), warmup_s=0)
        snapshot = analysis['latency']['ops']['snapshot']
        self.assertEqual(snapshot['excluded'], 80)
        self.assertEqual(snapshot['status'], 'STABLE')
        self.assertIn('low-count', text)

    def test_short_latency_window_is_inconclusive(self):
        intervals = [interval(i, i * 60.0, snapshot_p95=50.0 + i * 10.0, ips=22.0 - i * 2.0)
                     for i in range(5)]
        _, analysis, text = run(report([[sample(t) for t in hours(10)]], intervals), warmup_s=0)
        self.assertEqual(analysis['latency']['ops']['snapshot']['status'], 'INCONCLUSIVE')
        self.assertEqual(analysis['latency']['ops']['snapshot']['direction'], 'DEGRADING')
        self.assertEqual(analysis['latency']['throughput']['status'], 'INCONCLUSIVE')
        self.assertNotIn('**WARN**', text)
        self.assertIn('INCONCLUSIVE (DEGRADING)', text)
        self.assertNotIn('p95 지연 증가 없음', text)
        self.assertNotIn('성능 저하 징후 없음', text)
        self.assertIn('판정하지 않음 (INCONCLUSIVE)', text)

    def test_too_few_intervals_are_insufficient(self):
        _, analysis, _ = run(report([[sample(t) for t in hours(10)]], [interval(0, 0.0), interval(1, 60.0)]), warmup_s=0)
        self.assertEqual(analysis['latency']['ops']['snapshot']['status'], 'INSUFFICIENT DATA')

    def test_invalid_json(self):
        path = os.path.join(self.directory, 'broken.json')
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write('{"passed": true, "sessions": [')
        with self.assertRaises(soak.SoakInputError):
            soak.load_report(path)
        with redirect_stderr(io.StringIO()) as errors:
            self.assertEqual(soak.main([path, '--output', os.path.join(self.directory, 'out.md')]), 2)
        self.assertIn('not valid JSON', errors.getvalue())
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write('[1, 2]')
        with self.assertRaises(soak.SoakInputError):
            soak.load_report(path)

    def test_checkpoint_without_finish_is_analyzed(self):
        data = report([[sample(t) for t in hours(13)]], [interval(i, i * 60.0) for i in range(60)],
                      passed=False, stage='iteration/600')
        for key in ('finishedUtc', 'latencyMs', 'operationLatencyMs', 'elapsedMs', 'failedIterations', 'failureRate'):
            del data[key]
        model, analysis, text = run(data)
        self.assertEqual(soak.run_status(model), 'INCOMPLETE CHECKPOINT')
        self.assertEqual(model['failed'], 0)
        self.assertTrue(analysis['latency']['available'])
        self.assertIn('종료 기록이 없는 체크포인트', text)
        self.assertIn('Whole-run latency: NOT AVAILABLE', text)

    def test_pending_checkpoint_recovery(self):
        path = os.path.join(self.directory, 'soak.json')
        with open(path, 'w', encoding='utf-8') as handle:
            handle.write('{"truncated": ')
        pending = path + '.0123456789abcdef.pending'
        with open(pending, 'w', encoding='utf-8') as handle:
            json.dump(report([[sample(t) for t in hours(5)]]), handle)
        data, source = soak.load_report(path)
        self.assertEqual(source, pending)
        self.assertTrue(data['passed'])
        with self.assertRaises(soak.SoakInputError):
            soak.load_report(path, recover=False)

    def test_cli_writes_markdown_and_csv(self):
        path = os.path.join(self.directory, 'soak.json')
        with open(path, 'w', encoding='utf-8-sig') as handle:  # Windows PowerShell may add a BOM
            json.dump(report([[sample(t) for t in hours(13)]], [interval(i, i * 60.0) for i in range(60)]), handle)
        output = os.path.join(self.directory, 'nested', 'analysis.md')
        with redirect_stdout(io.StringIO()):
            self.assertEqual(soak.main([path, '--output', output, '--csv-dir', self.directory]), 0)
        with open(output, encoding='utf-8') as handle:
            self.assertIn('## 12. 후속 권고', handle.read())
        with open(os.path.join(self.directory, 'jna-soak-intervals.csv'), encoding='utf-8') as handle:
            rows = handle.read().splitlines()
        self.assertEqual(len(rows), 61)
        self.assertIn('snapshot_p95', rows[0])
        with open(os.path.join(self.directory, 'jna-soak-resources.csv'), encoding='utf-8') as handle:
            self.assertEqual(len(handle.read().splitlines()), 14)


class ExistingResultTests(unittest.TestCase):
    """The original 60-second reports must reproduce the figures quoted in docs/TEST-RESULTS.md."""

    def load(self, name):
        data, _ = soak.load_report(os.path.join(ROOT, 'docs', 'test-results', name))
        return run(data)

    def test_stabilization_soak(self):
        model, analysis, text = self.load('windows-uia-jna-soak-stabilization.json')
        self.assertEqual(model['schema'], 1)
        self.assertEqual((model['completed'], model['mutations'], model['failed']), (958, 11, 0))
        self.assertAlmostEqual(model['latency']['snapshot']['p95'], 61.8688)
        self.assertAlmostEqual(model['latency']['snapshot']['p99'], 89.5645)
        self.assertAlmostEqual(metric(analysis, 'private')['delta'] / MIB, 13.25, places=2)
        self.assertAlmostEqual(metric(analysis, 'working_set')['delta'] / MIB, 138.4, places=1)
        self.assertAlmostEqual(metric(analysis, 'nmt_committed')['delta'] / MIB, 10.04, places=2)
        self.assertEqual(metric(analysis, 'handles')['delta'], -2)
        self.assertEqual(metric(analysis, 'threads')['delta'], -3)
        self.assertTrue(analysis['checks'] and all(check[4] for check in analysis['checks']))
        self.assertFalse(analysis['latency']['available'])
        self.assertIn('NOT AVAILABLE: this JSON has no per-interval latency data', text)
        self.assertIn('INCONCLUSIVE', text)

    def test_recheck_soak(self):
        model, analysis, _ = self.load('2026-11-23-pr-2-jna-soak-recheck.json')
        self.assertEqual((model['completed'], model['mutations']), (992, 11))
        self.assertAlmostEqual(model['latency']['snapshot']['p95'], 58.0017)
        self.assertAlmostEqual(model['latency']['snapshot']['p99'], 72.3233)
        self.assertAlmostEqual(metric(analysis, 'private')['delta'] / MIB, 15.83, places=2)
        self.assertTrue(all(check[4] for check in analysis['checks']))


if __name__ == '__main__':
    unittest.main()
