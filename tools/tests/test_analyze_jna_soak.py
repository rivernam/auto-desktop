"""Unit tests for tools/Analyze-JnaSoak.py. Run: python -m unittest discover -s tools/tests -p "test_*.py"."""
import csv
import importlib.util
import io
import json
import os
import shutil
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout
from datetime import datetime, timezone

TOOLS = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TOOLS)
SPEC = importlib.util.spec_from_file_location('analyze_jna_soak', os.path.join(TOOLS, 'Analyze-JnaSoak.py'))
soak = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(soak)

MIB = 1024 * 1024


def sample(elapsed_s, private=700 * MIB, heap=60 * MIB, nmt=640 * MIB, ws=200 * MIB, handles=560, threads=40,
           cpu_ms=None, gc=None, young=None, survivor=0, collectors=None, fixture=None, driver=None, host=None):
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
    if collectors is not None:  # {'G1 young collection pauses': (invocations, timeMs), ...}
        point['gc'] = {'available': True, 'totalInvocations': sum(c[0] for c in collectors.values()),
                       'totalTimeMs': sum(c[1] for c in collectors.values()),
                       'collectors': [{'name': k, 'invocations': v[0], 'timeMs': v[1]} for k, v in collectors.items()]}
    if young is not None:
        point.update(heapRegionBytes=4 * MIB, heapYoungBytes=young, heapSurvivorBytes=survivor)
    for name, value in (('fixture', fixture), ('driver', driver), ('host', host)):
        if value is not None:
            point[name] = value
    return point


def process(cpu_ms=0.0, private=250 * MIB, handles=800, threads=20, ws=280 * MIB):
    return {'available': True, 'pid': 200, 'startUtc': '2026-01-01T00:00:00Z', 'cpuMs': cpu_ms,
            'privateBytes': private, 'workingSetBytes': ws, 'handles': handles, 'threads': threads}


def latency(p95, count=600, p50=None):
    p50 = p95 * 0.8 if p50 is None else p50
    return {'count': count, 'mean': p50, 'p50': p50, 'p95': p95, 'p99': p95 * 1.2, 'max': p95 * 1.5}


def interval(index, start_s, duration_s=60.0, session=0, snapshot_p95=60.0, count=600, ips=10.0, resources=None,
             failed=0, closed_by='interval', set_mean=16.0, info_p95=5.0, find_mean=0.32, slow=None):
    data = {
        'index': index, 'sessionIndex': session, 'pid': 100 + session,
        'startElapsedMs': start_s * 1000.0, 'endElapsedMs': (start_s + duration_s) * 1000.0,
        'durationSeconds': duration_s, 'closedBy': closed_by,
        'attemptedIterations': count + failed, 'completedIterations': count, 'failedIterations': failed,
        'mutationIterations': 4, 'requestsCompleted': count * 4, 'requestsFailed': failed, 'timeouts': failed,
        'errorCounts': {'TIMEOUT': failed} if failed else {},
        'iterationsPerSecond': ips, 'requestsPerSecond': ips * 4,
        'latencyMs': {'snapshot': latency(snapshot_p95, count), 'findElement': latency(0.4, count * 2, find_mean),
                      'getElementInfo': latency(info_p95, count), 'setValue': latency(set_mean * 1.25, 4),
                      'invoke': latency(18.0, 4)},
        'resources': resources,
    }
    if slow is not None:  # [(utc, op, ms)], already limited to the slowest by the soak script
        data['slowRequestCount'] = len(slow)
        data['slowRequestCounts'] = {op: sum(1 for s in slow if s[1] == op) for op in sorted({s[1] for s in slow})}
        data['slowRequests'] = [{'utc': utc, 'op': op, 'ms': ms, 'iteration': index * 100 + n}
                                for n, (utc, op, ms) in enumerate(slow)]
    return data


PROCESSORS = 12


def loaded_run(count=60, slow_from=40, fixture_slow_ms=60.0, other_slow_pct=2.0, top=None):
    """A run whose late intervals are slow, with cumulative JVM, fixture, driver and host counters.

    Per iteration the JVM uses 20-23 ms, the driver 10 ms and the fixture 30-32 ms (fixture_slow_ms
    in slow intervals). Other processes use 2 % of all processors (other_slow_pct in slow intervals).
    top(k, slow) lists the busiest processes of interval k as (name, cpu ms).
    """
    totals = {'jvm': 0.0, 'fixture': 0.0, 'driver': 0.0, 'busy': 5e6, 'idle': 9e7, 'raw': 1e9, 'base': 1e7,
              'gc': 0, 'gc_ms': 0.0}

    def point(elapsed_s, busiest=()):
        return sample(elapsed_s, cpu_ms=totals['jvm'],
                      collectors={'G1 young collection pauses': (totals['gc'], totals['gc_ms'])},
                      fixture=process(totals['fixture']), driver=process(totals['driver'], private=90 * MIB),
                      host={'available': True, 'cpuBusyMs': totals['busy'], 'cpuIdleMs': totals['idle'],
                            'processorPerformanceRaw': totals['raw'], 'processorPerformanceBase': totals['base'],
                            'availableMemoryBytes': 16000 * MIB, 'acPower': True, 'batteryPercent': 100,
                            'userIdleMs': elapsed_s * 1000.0, 'fixtureForeground': True, 'fixtureMinimized': False,
                            'topProcesses': [{'name': name, 'pid': 300 + n, 'cpuMs': cpu}
                                             for n, (name, cpu) in enumerate(busiest)]})

    samples = [point(0.0)]
    intervals = []
    for k in range(count):
        slow = k >= slow_from
        iterations = 600 if slow else 900
        capacity = 60000.0 * PROCESSORS
        used = {'jvm': iterations * (20.0 + k % 4), 'driver': iterations * 10.0,
                'fixture': iterations * (fixture_slow_ms if slow else 30.0 + k % 3)}
        for name, value in used.items():
            totals[name] += value
        totals['busy'] += sum(used.values()) + capacity * (other_slow_pct if slow else 2.0) / 100.0
        totals['idle'] = 9e7 + capacity * (k + 1) - (totals['busy'] - 5e6)
        totals['raw'] += 1000.0 * 120.0
        totals['base'] += 1000.0
        totals['gc'] += 1
        totals['gc_ms'] += 130.0
        resources = point((k + 1) * 60.0, top(k, slow) if top else ())
        flat = dict(resources['resources']['java'])  # an interval's resource point is flat
        flat.update({key: value for key, value in resources.items() if key not in ('resources', 'iteration')})
        intervals.append(interval(k, k * 60.0, count=iterations, ips=iterations / 60.0, resources=flat,
                                  snapshot_p95=(180.0 if slow else 60.0) + k % 5,
                                  info_p95=(15.0 if slow else 5.0) + (k % 5) * 0.1))
        samples.append(resources)
    return report([samples], intervals, schemaVersion=3)


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


def covariate(analysis, key):
    return next(c for c in analysis['load']['covariates'] if c['key'] == key)


# Lines copied from a JDK 17 log written with the options that Test-JnaSoak.ps1 passes.
GC_LOG = '''\
[2026-11-23T03:05:29.262+0000][0.011s][info][gc,init] Heap Region Size: 4M
[2026-11-23T03:05:30.039+0000][0.795s][info][gc,start    ] GC(0) Pause Young (Normal) (G1 Evacuation Pause)
[2026-11-23T03:05:30.049+0000][0.799s][info ][gc          ] GC(0) Pause Young (Normal) (G1 Evacuation Pause) 24M->3M(508M) 4.491ms
[2026-11-23T03:05:30.049+0000][0.799s][info ][safepoint   ] Safepoint "G1CollectForAllocation", Time since last: 774786100 ns, Reaching safepoint: 77900 ns, At safepoint: 4627500 ns, Total: 4705400 ns
[2026-11-23T03:05:31.064+0000][1.812s][info ][safepoint   ] Safepoint "Cleanup", Time since last: 1012795200 ns, Reaching safepoint: 72600 ns, At safepoint: 7200 ns, Total: 79800 ns
[2026-11-23T03:06:10.875+0000][41.623s][info ][gc,start    ] GC(3) Pause Young (Normal) (G1 Evacuation Pause)
[2026-11-23T03:06:10.923+0000][41.674s][trace][gc,age      ] GC(3) Age table with threshold 1 (max threshold 15)
[2026-11-23T03:06:10.923+0000][41.674s][trace][gc,age      ] GC(3) - age   1:   16480072 bytes,   16480072 total
[2026-11-23T03:06:10.923+0000][41.675s][info ][gc,phases   ] GC(3)   Evacuate Collection Set: 45.3ms
[2026-11-23T03:06:10.923+0000][41.675s][debug][gc,phases   ] GC(3)     Object Copy (ms):              Min: 32.4, Avg: 37.5, Max: 41.8, Diff:  9.4, Sum: 374.9, Workers: 10
[2026-11-23T03:06:10.923+0000][41.675s][debug][gc,phases   ] GC(3)     Reference Processing: 4.9ms
[2026-11-23T03:06:10.923+0000][41.676s][info ][gc,heap     ] GC(3) Survivor regions: 4->5(6)
[2026-11-23T03:06:10.923+0000][41.676s][info ][gc,heap     ] GC(3) Old regions: 1->2
[2026-11-23T03:06:10.923+0000][41.676s][info ][gc,heap     ] GC(3) Humongous regions: 0->1
[2026-11-23T03:06:10.923+0000][41.677s][info ][gc          ] GC(3) Pause Young (Normal) (G1 Evacuation Pause) 126M->19M(508M) 53.968ms
[2026-11-23T03:06:10.923+0000][41.677s][info ][safepoint   ] Safepoint "G1CollectForAllocation", Time since last: 16747000000 ns, Reaching safepoint: 91200 ns, At safepoint: 54100000 ns, Total: 54191200 ns
this line is not part of the log format
'''


class InstrumentationTests(unittest.TestCase):
    """Schema 3: fixture, driver and host samples, heap generations, slow requests and GC logs."""

    def setUp(self):
        self.directory = tempfile.mkdtemp()

    def tearDown(self):
        shutil.rmtree(self.directory, ignore_errors=True)

    def test_interval_load_is_derived_from_cumulative_counters(self):
        _, analysis, text = run(loaded_run())
        load = analysis['load']['intervals']
        self.assertEqual(len(load), 60)
        row = load[12]
        self.assertAlmostEqual(row['jvm_cpu_ms_per_iter'], 20.0)
        self.assertAlmostEqual(row['fixture_cpu_ms_per_iter'], 30.0)
        self.assertAlmostEqual(row['driver_cpu_ms_per_iter'], 10.0)
        self.assertAlmostEqual(row['host_cpu_pct'], 100.0 * (900 * 60.0 + 0.02 * 720000.0) / 720000.0)
        self.assertAlmostEqual(row['other_cpu_pct'], 2.0)
        self.assertAlmostEqual(row['perf_pct'], 120.0)
        self.assertEqual((row['gc_count'], row['gc_ms']), (1, 130.0))
        self.assertAlmostEqual(row['user_idle_s'], 780.0)
        # 60 s minus the request latencies, per iteration: the script's own time between requests.
        self.assertAlmostEqual(row['driver_overhead_ms_per_iter'], (60000.0 - 49081.6) / 900, places=6)
        # The first interval starts from the session's first sample.
        self.assertAlmostEqual(load[0]['jvm_cpu_ms_per_iter'], 20.0)
        self.assertIn('Fixture ms/iter', text)

    def test_processor_speed_is_not_available_when_the_counter_base_steps_back(self):
        # Seen twice in a 2 h run on 12 processors: the base fell by 2**32 / 12 between two samples.
        data = loaded_run()
        for point in data['sessions'][0]['samples']:  # an interval's resource point shares this host object
            host = point['host']
            host['processorPerformanceBase'] += 2 * 10 ** 9
            if point['elapsedMs'] >= 14 * 60000.0:
                host['processorPerformanceBase'] -= 2 ** 32 // PROCESSORS
        _, analysis, text = run(data)
        load = analysis['load']['intervals']
        self.assertIsNone(load[13]['perf_pct'])
        self.assertEqual((load[12]['perf_pct'], load[14]['perf_pct']), (120.0, 120.0))
        speed = covariate(analysis, 'perf')
        self.assertEqual((speed['normal'], speed['slow']), (120.0, 120.0))
        self.assertIn('기준값이 되돌아간 구간', text)

    def test_slow_intervals_are_compared_with_normal_ones(self):
        _, analysis, text = run(loaded_run())
        load = analysis['load']
        self.assertEqual(load['status'], 'COMPARED')
        self.assertAlmostEqual(load['baseline_p95'], 62.0)
        self.assertEqual([r['index'] for r in load['intervals'] if r['slow']], list(range(40, 60)))
        self.assertEqual(sum(1 for r in load['intervals'] if r['valid']), 50)  # 10 warmup intervals
        fixture = covariate(analysis, 'fixture_cpu')
        self.assertEqual((fixture['normal'], fixture['slow']), (31.0, 60.0))
        self.assertGreater(fixture['rho'], 0.7)
        self.assertGreater(covariate(analysis, 'info_p95')['rho'], 0.7)
        self.assertLess(abs(covariate(analysis, 'jvm_cpu')['rho']), 0.3)
        self.assertAlmostEqual(covariate(analysis, 'other_cpu')['slow'], 2.0)
        self.assertIn('fixture_cpu', load['moving'])
        self.assertNotIn('jvm_cpu', load['moving'])
        self.assertIn('느린 구간 20개', text)

    def test_other_process_load_moves_with_slow_intervals(self):
        _, analysis, _ = run(loaded_run(fixture_slow_ms=31.0, other_slow_pct=30.0))
        other = covariate(analysis, 'other_cpu')
        self.assertEqual((other['normal'], round(other['slow'], 6)), (2.0, 30.0))
        self.assertIn('other_cpu', analysis['load']['moving'])
        self.assertNotIn('fixture_cpu', analysis['load']['moving'])

    def test_a_steady_run_has_no_slow_intervals(self):
        _, analysis, text = run(loaded_run(slow_from=60))
        self.assertEqual(analysis['load']['status'], 'NO SLOW INTERVALS')
        self.assertFalse(any(r['slow'] for r in analysis['load']['intervals']))
        self.assertIn('느린 구간 없음', text)
        # The correlation table is still printed, so the sentence under it must agree with it.
        self.assertIn('info_p95', analysis['load']['moving'])
        self.assertNotIn('함께 움직인 측정값 (|ρ| ≥ 0.6): 없음', text)

    def test_load_columns_missing_from_older_reports_are_not_estimated(self):
        data, _ = soak.load_report(os.path.join(ROOT, 'docs', 'test-results', '2026-11-23-jna-soak-1h-intervals.json'))
        _, analysis, text = run(data)
        load = analysis['load']
        row = load['intervals'][15]
        self.assertAlmostEqual(row['jvm_cpu_ms_per_iter'], 20.9, places=1)
        self.assertAlmostEqual(row['driver_overhead_ms_per_iter'], 11.3, places=1)
        self.assertEqual((row['gc_count'], round(row['gc_ms'])), (1, 128))
        for key in ('fixture_cpu_ms_per_iter', 'driver_cpu_ms_per_iter', 'host_cpu_pct', 'other_cpu_pct', 'perf_pct'):
            self.assertIsNone(row[key], key)
        self.assertEqual(load['status'], 'COMPARED')
        self.assertEqual(sum(1 for r in load['intervals'] if r['slow']), 27)
        # Only calls that cross into the provider process slowed down; work inside the JVM did not.
        self.assertGreater(covariate(analysis, 'info_p95')['rho'], 0.85)
        self.assertLess(covariate(analysis, 'find_mean')['rho'], 0.3)
        self.assertLess(abs(covariate(analysis, 'jvm_cpu')['slow'] / covariate(analysis, 'jvm_cpu')['normal'] - 1), 0.1)
        self.assertIsNone(covariate(analysis, 'fixture_cpu')['rho'])
        self.assertNotIn('None', text)

    def test_low_count_operations_are_trended_on_merged_window_means(self):
        intervals = [interval(i, i * 60.0, set_mean=16.0 + i * 0.1) for i in range(240)]
        _, analysis, text = run(report([[sample(t) for t in hours(49)]], intervals))
        set_value = analysis['latency']['ops']['setValue']
        self.assertEqual((set_value['basis'], set_value['window_intervals']), ('mean', 5))
        self.assertEqual(set_value['status'], 'DEGRADING')
        self.assertGreater(set_value['late_mean'], set_value['early_mean'] * 1.2)
        invoke = analysis['latency']['ops']['invoke']
        self.assertEqual((invoke['basis'], invoke['status']), ('mean', 'STABLE'))
        self.assertEqual(analysis['latency']['ops']['snapshot']['basis'], 'p95')
        self.assertIn('setValue mean rose', text)

    def test_native_memory_outside_nmt_is_trended(self):
        growing = [sample(t, private=700 * MIB + t / 3600.0 * 12 * MIB) for t in hours(49)]
        _, analysis, text = run(report([growing]))
        native = metric(analysis, 'native_untracked')
        self.assertEqual(native['status'], 'SUSTAINED GROWTH')
        self.assertAlmostEqual(native['first'] / MIB, 60.0)
        self.assertAlmostEqual(native['slope_h'] / MIB, 12.0, places=3)
        self.assertIn('Native outside NMT', text)
        tracked = [sample(t, private=700 * MIB + t / 3600.0 * 12 * MIB, nmt=640 * MIB + t / 3600.0 * 12 * MIB)
                   for t in hours(49)]
        _, analysis, _ = run(report([tracked]))
        self.assertEqual(metric(analysis, 'native_untracked')['status'], 'STABLE')

    def generation_samples(self, concurrent_cycles):
        return [sample(t, heap=(100 + i) * MIB, young=80 * MIB, survivor=16 * MIB,
                       collectors={'G1 young collection pauses': (i, i * 130.0),
                                   'G1 full collection pauses': (0, 0.0),
                                   'G1 concurrent cycle pauses': (concurrent_cycles, 5.0 * concurrent_cycles)})
                for i, t in enumerate(hours(49))]

    def test_old_generation_estimate_is_never_negative(self):
        # Young regions are counted whole even when partly filled, so used - young can dip below zero.
        model = soak.normalize(report([[sample(0.0, heap=5 * MIB, young=8 * MIB)]]))
        self.assertEqual(model['points'][0]['heap_old'], 0.0)

    def test_heap_generations_are_reported(self):
        model, analysis, text = run(report([self.generation_samples(0)]))
        self.assertAlmostEqual(model['points'][0]['heap_old'] / MIB, 20.0)
        self.assertAlmostEqual(model['points'][-1]['heap_old'] / MIB, 68.0)
        generations = analysis['generations'][0]
        self.assertEqual((generations['old_collections'], generations['young_collections']), (0, 48))
        self.assertAlmostEqual(generations['old_delta'] / MIB, 48.0)
        self.assertAlmostEqual(generations['survivor_median'] / MIB, 16.0)
        self.assertAlmostEqual(generations['young_pause_mean_ms'], 130.0)
        self.assertIn('Old(used − young)', text)

    def test_heap_growth_without_an_old_collection_is_inconclusive(self):
        model, analysis, text = run(report([self.generation_samples(0)]))
        heap = metric(analysis, 'heap_used')
        self.assertEqual((heap['status'], heap['direction']), ('INCONCLUSIVE', 'SUSTAINED GROWTH'))
        self.assertFalse([m for level, m in soak.stability_findings(model, analysis) if 'Heap used' in m])
        self.assertIn('old 영역 수거가 없어', text)
        model, analysis, _ = run(report([self.generation_samples(2)]))
        self.assertEqual(metric(analysis, 'heap_used')['status'], 'SUSTAINED GROWTH')
        self.assertTrue([m for level, m in soak.stability_findings(model, analysis) if 'Heap used' in m])

    def test_fixture_growth_is_a_provider_side_warning(self):
        samples = [sample(t, fixture=process(private=250 * MIB + t / 3600.0 * 30 * MIB, handles=800 + t / 3600.0 * 50),
                          driver=process(private=90 * MIB + t / 3600.0 * 30 * MIB)) for t in hours(49)]
        model, analysis, text = run(report([samples]))
        rows = {(r['process'], r['field']): r for r in analysis['process_memory']}
        self.assertEqual(rows[('fixture', 'private')]['status'], 'SUSTAINED GROWTH')
        self.assertAlmostEqual(rows[('fixture', 'private')]['slope_h'] / MIB, 30.0, places=3)
        self.assertEqual(rows[('fixture', 'handles')]['status'], 'SUSTAINED GROWTH')
        self.assertEqual(rows[('fixture', 'threads')]['status'], 'STABLE')
        self.assertEqual(rows[('driver', 'private')]['status'], 'SUSTAINED GROWTH')
        findings = soak.stability_findings(model, analysis)
        self.assertTrue(any(level == 'WARN' and 'Fixture private bytes' in message for level, message in findings))
        self.assertTrue(any(level == 'NOTE' and 'Driver private bytes' in message for level, message in findings))
        self.assertFalse(any(level == 'WARN' and 'Driver' in message for level, message in findings))
        self.assertIn('**종합 판정: PASS WITH WARNINGS**', text)
        self.assertIn('Fixture private bytes', text)

    def test_processes_missing_from_older_reports_are_not_available(self):
        model, analysis, text = run(report([[sample(t) for t in hours(49)]]))
        self.assertTrue(analysis['process_memory'])
        self.assertTrue(all(r['status'] == soak.NA for r in analysis['process_memory']))
        self.assertIn('**종합 판정: PASS**', text)

    def test_gc_log_pauses_and_safepoints_are_parsed(self):
        log = soak.parse_gc_log(GC_LOG)
        self.assertEqual([(p['id'], p['ms']) for p in log['pauses']], [(0, 4.491), (3, 53.968)])
        pause = log['pauses'][1]
        self.assertEqual(pause['kind'], 'Pause Young (Normal) (G1 Evacuation Pause)')
        self.assertEqual(pause['end'], datetime(2026, 11, 23, 3, 6, 10, 923000, tzinfo=timezone.utc))
        self.assertEqual((pause['before_mb'], pause['after_mb'], pause['heap_mb']), (126, 19, 508))
        self.assertEqual((pause['object_copy_ms'], pause['reference_ms'], pause['survivor_bytes']), (37.5, 4.9, 16480072))
        # Old and humongous regions left after the pause, in bytes: exact to the region, unlike used - young.
        self.assertEqual(pause['old_bytes'], 3 * 4 * MIB)
        self.assertIsNone(log['pauses'][0]['object_copy_ms'])
        self.assertIsNone(log['pauses'][0]['old_bytes'])
        summary = soak.analyze_gc(dict(log, files=['x.log'], missing=[]))
        self.assertEqual((summary['old_first'], summary['old_last'], summary['old_pauses']), (12 * MIB, 12 * MIB, 1))
        self.assertEqual([(s['name'], s['total_ms']) for s in log['safepoints']],
                         [('G1CollectForAllocation', 4.7054), ('Cleanup', 0.0798), ('G1CollectForAllocation', 54.1912)])
        local = soak.parse_gc_log('[2026-11-23T12:06:10.923+0900][1.000s][info][gc] GC(7) Pause Remark 30M->30M(508M) 2.000ms')
        self.assertEqual(local['pauses'][0]['end'], datetime(2026, 11, 23, 3, 6, 10, 923000, tzinfo=timezone.utc))

    def slow_report(self):
        slow = [('2026-11-23T03:06:10.9300000Z', 'snapshot', 120.0),       # 10.810-10.930 spans GC(3) 10.869-10.923
                ('2026-11-23T03:06:20.0000000Z', 'snapshot', 150.0),       # no pause nearby
                ('2026-11-23T03:06:30.0000000Z', 'getElementInfo', 110.0)]
        intervals = [interval(i, i * 60.0, slow=slow if i == 3 else []) for i in range(8)]
        data = report([[sample(t) for t in hours(3)]], intervals, schemaVersion=3,
                      slowRequestThresholdMs=100, slowRequestLimit=10, gcLogging=True)
        data['sessions'][0]['gcLog'] = 'soak.gc-100.log'
        return data

    def test_slow_requests_are_matched_to_gc_pauses(self):
        with open(os.path.join(self.directory, 'soak.gc-100.log'), 'w', encoding='utf-8') as handle:
            handle.write(GC_LOG)
        model = soak.normalize(self.slow_report())
        gc = soak.load_gc_logs(model, self.directory)
        self.assertEqual((len(gc['pauses']), gc['missing']), (2, []))
        analysis = soak.analyze(model, gc=gc)
        slow = analysis['slow']
        self.assertEqual((slow['threshold_ms'], slow['total'], slow['by_operation']),
                         (100.0, 3, {'getElementInfo': 1, 'snapshot': 2}))
        self.assertEqual((len(slow['recorded']), slow['overlapping']), (3, 1))
        matched = [r for r in slow['recorded'] if r['gc']]
        self.assertEqual((matched[0]['ms'], matched[0]['gc']['id'], matched[0]['interval']), (120.0, 3, 3))
        text = soak.render(model, analysis, 'soak.json')
        self.assertIn('GC 일시정지와 겹친 요청 1개', text)
        self.assertIn('GC 로그의 일시정지 2회', text)

    def test_rotated_gc_log_parts_are_read_together(self):
        lines = GC_LOG.splitlines(keepends=True)
        split = next(n for n, line in enumerate(lines) if 'GC(3)' in line)
        # The JVM renames a full log to name.0 and continues in name: the region size stays in the old part.
        with open(os.path.join(self.directory, 'soak.gc-100.log.0'), 'w', encoding='utf-8') as handle:
            handle.writelines(lines[:split])
        with open(os.path.join(self.directory, 'soak.gc-100.log'), 'w', encoding='utf-8') as handle:
            handle.writelines(lines[split:])
        gc = soak.load_gc_logs(soak.normalize(self.slow_report()), self.directory)
        self.assertEqual([(p['id'], p['old_bytes']) for p in gc['pauses']], [(0, None), (3, 12 * MIB)])
        self.assertEqual((gc['files'], gc['missing']), (['soak.gc-100.log'], []))

    def test_a_missing_gc_log_leaves_slow_requests_unmatched(self):
        model = soak.normalize(self.slow_report())
        gc = soak.load_gc_logs(model, self.directory)
        self.assertEqual(gc['missing'], ['soak.gc-100.log'])
        analysis = soak.analyze(model, gc=gc)
        self.assertIsNone(analysis['slow']['overlapping'])
        self.assertEqual(analysis['slow']['total'], 3)
        text = soak.render(model, analysis, 'soak.json')
        self.assertIn('soak.gc-100.log', text)
        self.assertIn('GC 로그: NOT AVAILABLE', text)

    def test_reports_without_slow_request_tracking_say_so(self):
        _, analysis, text = run(report([[sample(t) for t in hours(13)]], [interval(i, i * 60.0) for i in range(60)]))
        self.assertFalse(analysis['slow']['available'])
        self.assertIn('느린 요청 기록: NOT AVAILABLE', text)

    def test_host_environment_is_listed(self):
        data = loaded_run()
        data['environment'].update(cpu='Test CPU 9000', cpuNominalMhz=2000, memoryBytes=32 * 1024 * MIB,
                                   gitCommit='abcdef0123' * 4, gitDirty=True,
                                   power={'scheme': '381b4222-f694-41f0-9685-ff5bb260df2e', 'schemeName': 'Balanced',
                                          'overlay': '00000000-0000-0000-0000-000000000000'})
        _, _, text = run(data)
        self.assertIn('schemaVersion 3', text)
        for expected in ('Test CPU 9000 (nominal 2,000 MHz)', '32.0 GiB', 'Balanced', 'abcdef0123ab (modified)',
                         '| Power source | AC in 61 of 61 samples |'):
            self.assertIn(expected, text)

    def test_generations_are_labelled_with_the_collector_in_use(self):
        def session(prefix, full):
            return [sample(t, heap=(20 + i) * MIB, young=12 * MIB, survivor=MIB,
                           collectors={prefix + ' young collection pauses': (10 * (i + 1), 30.0 * (i + 1)),
                                       prefix + ' ' + full + ' collection pauses': (0, 0.0)})
                    for i, t in enumerate(hours(4))]

        _, analysis, text = run(report([session('Serial', 'full')], schemaVersion=3))
        self.assertEqual(analysis['generations'][0]['young_collections'], 40)
        self.assertIn('세대별 Heap과 수거 횟수 (Serial)', text)
        self.assertIn('tenured', text)
        self.assertNotIn('humongous 영역의 합에 대한 추정값', text)
        _, _, text = run(report([session('G1', 'full')], schemaVersion=3))
        self.assertIn('세대별 Heap과 수거 횟수 (G1)', text)
        self.assertIn('humongous 영역의 합에 대한 추정값', text)

    def test_jvm_options_are_listed_with_the_environment(self):
        data = loaded_run()
        _, _, text = run(data)
        self.assertNotIn('JVM options', text)  # older reports did not record them
        data['jvmOptions'] = ['-Xms16m', '-XX:+UseSerialGC']
        _, _, text = run(data)
        self.assertIn('| JVM options | `-Xms16m -XX:+UseSerialGC` |', text)
        data['jvmOptions'] = []
        _, _, text = run(data)
        self.assertIn('| JVM options | none |', text)

    def test_busiest_processes_are_summarized_for_slow_and_normal_intervals(self):
        def busiest(k, slow):
            return [('scanner.exe', 5000.0 if slow else 200.0)] + ([('updater.exe', 300.0)] if k % 2 else [])

        _, analysis, text = run(loaded_run(top=busiest))
        processes = {p['name']: p for p in analysis['load']['processes']}
        self.assertEqual((processes['scanner.exe']['slow_ms'], processes['scanner.exe']['normal_ms']), (5000.0, 200.0))
        # Seen in half of the intervals: the average counts the others as zero.
        self.assertEqual((processes['updater.exe']['slow_ms'], processes['updater.exe']['slow_seen']), (150.0, 10))
        self.assertEqual(analysis['load']['processes'][0]['name'], 'scanner.exe')
        self.assertIn('scanner.exe', text)

    def test_process_names_are_absent_unless_recorded(self):
        _, analysis, text = run(loaded_run())
        self.assertEqual(analysis['load']['processes'], [])
        self.assertIn('상위 프로세스 기록: NOT AVAILABLE', text)

    def test_cli_reads_the_gc_log_next_to_the_report_and_writes_new_csv_columns(self):
        data = loaded_run()
        data['sessions'][0]['gcLog'] = 'soak.gc-100.log'
        path = os.path.join(self.directory, 'soak.json')
        with open(path, 'w', encoding='utf-8') as handle:
            json.dump(data, handle)
        with open(os.path.join(self.directory, 'soak.gc-100.log'), 'w', encoding='utf-8') as handle:
            handle.write(GC_LOG)
        output = os.path.join(self.directory, 'analysis.md')
        with redirect_stdout(io.StringIO()):
            self.assertEqual(soak.main([path, '--output', output, '--csv-dir', self.directory]), 0)
        with open(output, encoding='utf-8') as handle:
            self.assertIn('GC 로그의 일시정지 2회', handle.read())
        with open(os.path.join(self.directory, 'jna-soak-resources.csv'), encoding='utf-8') as handle:
            header = handle.readline().strip().split(',')
        for column in ('heap_old', 'native_untracked', 'fixture_cpu_ms', 'fixture_private', 'driver_cpu_ms',
                       'host_busy_ms', 'host_idle_ms', 'host_user_idle_ms'):
            self.assertIn(column, header)
        with open(os.path.join(self.directory, 'jna-soak-intervals.csv'), encoding='utf-8') as handle:
            rows = list(csv.DictReader(handle))
        self.assertEqual(float(rows[12]['fixture_cpu_ms_per_iter']), 30.0)
        self.assertEqual(float(rows[12]['other_cpu_pct']), 2.0)
        self.assertEqual((rows[12]['slow_interval'], rows[45]['slow_interval']), ('0', '1'))


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
