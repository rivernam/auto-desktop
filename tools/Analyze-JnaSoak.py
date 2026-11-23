#!/usr/bin/env python3
"""Analyze a Test-JnaSoak.ps1 JSON report and write a Markdown stability report.

Supports the original 60-second soak format (no schemaVersion, session samples only), the
interval format (schemaVersion 2) and the instrumented format (schemaVersion 3: fixture, driver
and host samples, heap generations, slow requests and one GC log per JVM next to the report).
Interrupted runs and checkpoints are analyzed as far as their data goes; anything that is not in
the input is reported as NOT AVAILABLE instead of estimated. Only the Python standard library is used.

    python tools/Analyze-JnaSoak.py target/windows-uia-jna-soak.json \
        --output target/jna-soak-analysis.md --csv-dir target
"""
import argparse
import csv
import glob
import json
import math
import os
import re
import statistics
import sys
from datetime import datetime, timedelta, timezone

NA = 'NOT AVAILABLE'
MIB = 1024.0 * 1024.0

# name, sample field, unit, absolute growth floor per hour, relative growth floor per hour
MEMORY_METRICS = [
    ('Heap used (lower envelope)', 'heap_used', 'bytes', 2 * MIB, 0.01),
    ('Heap committed', 'heap_committed', 'bytes', 4 * MIB, 0.01),
    ('NMT reserved', 'nmt_reserved', 'bytes', 4 * MIB, 0.01),
    ('NMT committed', 'nmt_committed', 'bytes', 2 * MIB, 0.01),
    ('Private bytes', 'private', 'bytes', 4 * MIB, 0.01),
    # COM, JNA and other native allocations that HotSpot does not track.
    ('Native outside NMT (private − NMT committed)', 'native_untracked', 'bytes', 4 * MIB, 0.01),
    ('Working set', 'working_set', 'bytes', 4 * MIB, 0.01),
]
COUNT_METRICS = [
    ('Handles', 'handles', 'count', 10.0, 0.01),
    ('Threads', 'threads', 'count', 1.0, 0.01),
]
# process, name, sample field, short field, unit, absolute and relative growth floor per hour.
# These processes outlive JVM restarts, so they are trended over the whole run.
PROCESS_METRICS = [
    ('fixture', 'Fixture private bytes', 'fixture_private', 'private', 'bytes', 4 * MIB, 0.01),
    ('fixture', 'Fixture handles', 'fixture_handles', 'handles', 'count', 10.0, 0.01),
    ('fixture', 'Fixture threads', 'fixture_threads', 'threads', 'count', 1.0, 0.01),
    ('driver', 'Driver private bytes', 'driver_private', 'private', 'bytes', 4 * MIB, 0.01),
    ('driver', 'Driver handles', 'driver_handles', 'handles', 'count', 10.0, 0.01),
]
PROCESS_FIELDS = (('cpu_ms', 'cpuMs'), ('private', 'privateBytes'), ('working_set', 'workingSetBytes'),
                  ('handles', 'handles'), ('threads', 'threads'))
# key, interval load field, label, digits. Compared between slow and normal intervals in section 4.
LOAD_COVARIATES = [
    ('info_p95', 'info_p95', 'getElementInfo p95 (ms)', 2),
    ('find_mean', 'find_mean', 'findElement mean (ms)', 3),
    ('jvm_cpu', 'jvm_cpu_ms_per_iter', 'JVM CPU (ms/iter)', 1),
    ('fixture_cpu', 'fixture_cpu_ms_per_iter', 'Fixture CPU (ms/iter)', 1),
    ('driver_cpu', 'driver_cpu_ms_per_iter', 'Driver CPU (ms/iter)', 1),
    ('driver_overhead', 'driver_overhead_ms_per_iter', 'Driver time between requests (ms/iter)', 1),
    ('gc_ms', 'gc_ms', 'GC pause (ms/interval)', 0),
    ('host_cpu', 'host_cpu_pct', 'Host CPU (% of all processors)', 1),
    ('other_cpu', 'other_cpu_pct', 'Other processes CPU (% of all processors)', 1),
    ('perf', 'perf_pct', 'Processor speed (% of nominal)', 0),
    ('user_idle', 'user_idle_s', 'Time since user input (s)', 0),
    ('available_memory', 'available_memory_mib', 'Available memory (MiB)', 0),
]
SLOW_INTERVAL_FACTOR = 1.5
MOVING_RHO = 0.6
GC_MATCH_TOLERANCE_S = 0.005
OPERATIONS = ['snapshot', 'findElement', 'getElementInfo', 'setValue', 'invoke']
LEGACY_OPERATION = {'snapshot': 'snapshot', 'findEdit': 'findElement', 'findButton': 'findElement',
                    'elementInfo': 'getElementInfo', 'setValue': 'setValue', 'invoke': 'invoke'}
MIN_TREND_POINTS = 4
HEAP_ENVELOPE_BLOCK = 5


class SoakInputError(Exception):
    """The input cannot be read as a soak report."""


# --------------------------------------------------------------------------- input

def _parse(path):
    try:
        with open(path, 'rb') as handle:
            raw = handle.read()
    except OSError as error:
        raise SoakInputError('cannot read %s: %s' % (path, error))
    try:
        data = json.loads(raw.decode('utf-8-sig'))
    except UnicodeDecodeError as error:
        raise SoakInputError('%s is not UTF-8 text: %s' % (path, error))
    except ValueError as error:
        raise SoakInputError('%s is not valid JSON: %s' % (path, error))
    if not isinstance(data, dict):
        raise SoakInputError('%s does not contain a JSON object' % path)
    return data


def load_report(path, recover=True):
    """Return (report, source). Falls back to an intact pending checkpoint next to the report.

    Save-UiaJson writes `<report>.<guid>.pending` and atomically replaces the report. A pending
    file only survives when the writer was killed between the two steps.
    """
    try:
        return _parse(path), path
    except SoakInputError as primary:
        if not recover:
            raise
        candidates = sorted(glob.glob(glob.escape(path) + '.*.pending'), key=os.path.getmtime, reverse=True)
        for candidate in candidates:
            try:
                return _parse(candidate), candidate
            except SoakInputError:
                continue
        raise primary


def num(value):
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return float(value) if math.isfinite(value) else None


def obj(value):
    return value if isinstance(value, dict) else {}


def seq(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict):  # ConvertTo-Json renders a one-element list as an object in some cases
        return [value]
    return []


def flag(value):
    return value if isinstance(value, bool) else None


def difference(left, right):
    return None if left is None or right is None else left - right


def process_point(source, prefix):
    """Counters of the fixture or driver process; absent in reports before schemaVersion 3."""
    source = obj(source)
    live = source.get('available') is True
    return {'%s_%s' % (prefix, key): num(source.get(raw)) if live else None for key, raw in PROCESS_FIELDS}


def resource_point(source, session_index, elapsed_ms=None):
    """Normalize a session sample, an interval resource point or failure resources."""
    source = obj(source)
    nested = obj(source.get('resources'))
    java = obj(nested.get('java')) if nested else obj(source.get('java'))
    flat = source if 'privateBytes' in source or 'cpuMs' in source else java
    gc = obj(source.get('gc'))
    host = obj(source.get('host'))
    live = host.get('available') is True
    collectors = None
    if gc.get('available'):
        collectors = {str(c.get('name')): (num(c.get('invocations')) or 0.0, num(c.get('timeMs')) or 0.0)
                      for c in (obj(c) for c in seq(gc.get('collectors'))) if c.get('name')} or None
    elapsed = num(source.get('elapsedMs')) if elapsed_ms is None else elapsed_ms
    point = {
        'session': session_index,
        'elapsed_s': None if elapsed is None else elapsed / 1000.0,
        'utc': (nested or source).get('utc'),
        'pid': flat.get('pid'),
        'jvm_start': flat.get('startUtc'),
        'heap_used': num(source.get('heapUsedBytes')),
        'heap_committed': num(source.get('heapCommittedBytes')),
        'heap_young': num(source.get('heapYoungBytes')),
        'heap_survivor': num(source.get('heapSurvivorBytes')),
        'nmt_reserved': num(source.get('nmtReservedBytes')),
        'nmt_committed': num(source.get('nmtCommittedBytes')),
        'private': num(flat.get('privateBytes')),
        'working_set': num(flat.get('workingSetBytes')),
        'cpu_ms': num(flat.get('cpuMs')),
        'handles': num(flat.get('handles')),
        'threads': num(flat.get('threads')),
        'gc_count': num(gc.get('totalInvocations')) if gc.get('available') else None,
        'gc_time_ms': num(gc.get('totalTimeMs')) if gc.get('available') else None,
        'gc_collectors': collectors,
        # Cumulative since boot: the difference between two points covers the time between them.
        'host_busy_ms': num(host.get('cpuBusyMs')) if live else None,
        'host_idle_ms': num(host.get('cpuIdleMs')) if live else None,
        'host_perf_raw': num(host.get('processorPerformanceRaw')) if live else None,
        'host_perf_base': num(host.get('processorPerformanceBase')) if live else None,
        'host_available_memory': num(host.get('availableMemoryBytes')) if live else None,
        'host_ac_power': flag(host.get('acPower')) if live else None,
        'host_user_idle_ms': num(host.get('userIdleMs')) if live else None,
        'host_fixture_foreground': flag(host.get('fixtureForeground')) if live else None,
        'host_fixture_minimized': flag(host.get('fixtureMinimized')) if live else None,
        'host_top': [(str(p.get('name')), num(p.get('cpuMs'))) for p in (obj(p) for p in seq(host.get('topProcesses')))
                     if p.get('name')] if live else [],
    }
    point.update(process_point(source.get('fixture'), 'fixture'))
    point.update(process_point(source.get('driver'), 'driver'))
    # G1 counts survivor regions as young, so the remainder is old plus humongous regions. Young
    # regions are counted whole even when partly filled, which makes this an estimate that reads low
    # by up to a few regions; the GC log gives the exact region counts.
    old = difference(point['heap_used'], point['heap_young'])
    point['heap_old'] = None if old is None else max(0.0, old)
    point['native_untracked'] = difference(point['private'], point['nmt_committed'])
    return point


def parse_utc(text):
    """Timestamps written by .NET ('o' format, seven fractional digits) or without a fraction."""
    match = re.match(r'^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(?:\.(\d+))?Z?$', str(text or ''))
    if not match:
        return None
    year, month, day, hour, minute, second = (int(part) for part in match.groups()[:6])
    micro = int(((match.group(7) or '') + '000000')[:6])
    try:
        return datetime(year, month, day, hour, minute, second, micro, tzinfo=timezone.utc)
    except ValueError:
        return None


def latency_entry(value):
    value = obj(value)
    entry = {key: num(value.get(key)) for key in ('count', 'mean', 'p50', 'p95', 'p99', 'max')}
    return entry if entry['count'] else None


def normalize(report):
    schema = num(report.get('schemaVersion')) or 1
    attempted = num(report.get('attemptedIterations'))
    completed = num(report.get('completedIterations'))
    failed = num(report.get('failedIterations'))
    if failed is None and attempted is not None and completed is not None:
        failed = attempted - completed
    model = {
        'schema': int(schema),
        'raw': report,
        'passed': report.get('passed') is True,
        'stage': report.get('stage'),
        'error': report.get('error'),
        'interrupted': report.get('interrupted') is True,
        'finished': report.get('finishedUtc'),
        'checkpoint': report.get('checkpointUtc'),
        'start': report.get('utc'),
        'elapsed_s': None if num(report.get('elapsedMs')) is None else num(report.get('elapsedMs')) / 1000.0,
        'duration_limit_s': num(report.get('durationLimitSeconds')),
        'sample_s': num(report.get('sampleIntervalSeconds')),
        'interval_s': num(report.get('intervalSeconds')),
        'environment': obj(report.get('environment')),
        'attempted': attempted, 'completed': completed, 'failed': failed,
        'failure_rate': num(report.get('failureRate')),
        'mutations': num(report.get('mutationIterations')),
        'requests_completed': num(report.get('requestsCompleted')),
        'requests_failed': num(report.get('requestsFailed')),
        'timeouts': num(report.get('timeouts')),
        'error_counts': obj(report.get('errorCounts')),
        'failures': [obj(f) for f in seq(report.get('failures'))],
        'unexpected_exits': num(report.get('unexpectedJvmExits')),
        'latency': {k: latency_entry(v) for k, v in obj(report.get('latencyMs')).items()},
        'op_latency': {k: latency_entry(v) for k, v in obj(report.get('operationLatencyMs')).items()},
        'latency_method': obj(report.get('latencyStatistics')).get('latencyMs'),
        'failure_resources': report.get('failureResources'),
        'slow_threshold_ms': num(report.get('slowRequestThresholdMs')),
        'slow_limit': num(report.get('slowRequestLimit')),
        'top_processes': num(report.get('topProcesses')),
        'gc_logging': report.get('gcLogging') is True,
        'sessions': [], 'points': [], 'intervals': [],
    }
    if model['failure_rate'] is None and attempted:
        model['failure_rate'] = (failed or 0) / attempted
    for position, raw_session in enumerate(seq(report.get('sessions'))):
        raw_session = obj(raw_session)
        index = int(num(raw_session.get('index')) if num(raw_session.get('index')) is not None else position)
        samples = [resource_point(s, index) for s in seq(raw_session.get('samples'))]
        samples = [p for p in samples if p['elapsed_s'] is not None]
        start_ms = num(raw_session.get('startElapsedMs'))
        model['sessions'].append({
            'index': index, 'pid': raw_session.get('pid'),
            'jvm_start': raw_session.get('jvmStartUtc') or (samples[0]['jvm_start'] if samples else None),
            'start_s': start_ms / 1000.0 if start_ms is not None else (samples[0]['elapsed_s'] if samples else None),
            'completed': num(raw_session.get('completedIterations')),
            'mutations': num(raw_session.get('mutationIterations')),
            'exited_normally': raw_session.get('exitedNormally') if isinstance(raw_session.get('exitedNormally'), bool) else None,
            'unexpected_exit': raw_session.get('unexpectedExit') is True,
            'exit_code': raw_session.get('exitCode'),
            'end_reason': raw_session.get('endReason'),
            'shutdown_error': raw_session.get('shutdownError'),
            'resource_change': obj(raw_session.get('resourceChange')),
            'gc_log': raw_session.get('gcLog') if isinstance(raw_session.get('gcLog'), str) else None,
            'samples': samples,
        })
        model['points'].extend(samples)
    seen = {(p['session'], round(p['elapsed_s'], 3)) for p in model['points']}
    for raw_interval in seq(report.get('intervals')):
        raw_interval = obj(raw_interval)
        session_index = int(num(raw_interval.get('sessionIndex')) or 0)
        point = resource_point(raw_interval.get('resources'), session_index) if raw_interval.get('resources') else None
        if point and point['elapsed_s'] is not None and (session_index, round(point['elapsed_s'], 3)) not in seen:
            seen.add((session_index, round(point['elapsed_s'], 3)))
            model['points'].append(point)
        start = num(raw_interval.get('startElapsedMs'))
        end = num(raw_interval.get('endElapsedMs'))
        duration = num(raw_interval.get('durationSeconds'))
        if duration is None and start is not None and end is not None:
            duration = (end - start) / 1000.0
        model['intervals'].append({
            'index': int(num(raw_interval.get('index')) if num(raw_interval.get('index')) is not None else len(model['intervals'])),
            'session': session_index,
            'start_s': None if start is None else start / 1000.0,
            'end_s': None if end is None else end / 1000.0,
            'duration_s': duration,
            'closed_by': raw_interval.get('closedBy'),
            'attempted': num(raw_interval.get('attemptedIterations')),
            'completed': num(raw_interval.get('completedIterations')) or 0.0,
            'failed': num(raw_interval.get('failedIterations')) or 0.0,
            'mutations': num(raw_interval.get('mutationIterations')),
            'requests': num(raw_interval.get('requestsCompleted')),
            'requests_failed': num(raw_interval.get('requestsFailed')) or 0.0,
            'timeouts': num(raw_interval.get('timeouts')) or 0.0,
            'errors': obj(raw_interval.get('errorCounts')),
            'ips': num(raw_interval.get('iterationsPerSecond')),
            'rps': num(raw_interval.get('requestsPerSecond')),
            'sampling_ms': num(raw_interval.get('samplingMs')),
            'latency': {k: latency_entry(v) for k, v in obj(raw_interval.get('latencyMs')).items()},
            'resources': point,
            # None when the report predates slow request tracking.
            'slow_count': num(raw_interval.get('slowRequestCount')),
            'slow_counts': {k: num(v) or 0.0 for k, v in obj(raw_interval.get('slowRequestCounts')).items()},
            'slow_requests': [{'end': parse_utc(s.get('utc')), 'utc': s.get('utc'), 'op': s.get('op'),
                               'ms': num(s.get('ms')), 'iteration': num(s.get('iteration'))}
                              for s in (obj(s) for s in seq(raw_interval.get('slowRequests')))],
        })
    model['points'].sort(key=lambda p: (p['session'], p['elapsed_s']))
    model['intervals'].sort(key=lambda i: i['index'])
    return model


# --------------------------------------------------------------------------- statistics

def theil_sen(xs, ys):
    slopes = [(ys[j] - ys[i]) / (xs[j] - xs[i])
              for i in range(len(xs)) for j in range(i + 1, len(xs)) if xs[j] != xs[i]]
    return statistics.median(slopes) if slopes else None


def least_squares(xs, ys):
    if len(xs) < 2:
        return None, None
    mean_x, mean_y = statistics.fmean(xs), statistics.fmean(ys)
    sxx = sum((x - mean_x) ** 2 for x in xs)
    if sxx == 0:
        return None, None
    slope = sum((x - mean_x) * (y - mean_y) for x, y in zip(xs, ys)) / sxx
    total = sum((y - mean_y) ** 2 for y in ys)
    residual = sum((y - (mean_y + slope * (x - mean_x))) ** 2 for x, y in zip(xs, ys))
    return slope, (1 - residual / total) if total else 1.0


def lower_envelope(series, block):
    """Minimum of each block of consecutive samples, approximating the post-GC heap floor."""
    if len(series) < block * MIN_TREND_POINTS:
        return series, False
    result = []
    for start in range(0, len(series) - block + 1, block):
        chunk = series[start:start + block]
        result.append(min(chunk, key=lambda item: item[1]))
    return result, True


def trend(series, session_start, warmup_s, absolute_floor, relative_floor, min_hours, envelope=False):
    """Classify a resource series of (elapsed seconds, value) for one JVM session."""
    series = [(t, v) for t, v in series if t is not None and v is not None]
    result = {'n': len(series), 'status': 'INSUFFICIENT DATA', 'conclusive': False}
    if not series:
        result['status'] = NA
        return result
    result.update(first=series[0][1], last=series[-1][1], min=min(v for _, v in series),
                  max=max(v for _, v in series), delta=series[-1][1] - series[0][1])
    start = series[0][0] if session_start is None else session_start
    warm = [(t, v) for t, v in series if t - start < warmup_s]
    post = [(t, v) for t, v in series if t - start >= warmup_s]
    result['warmup_median'] = statistics.median(v for _, v in warm) if warm else None
    result['post_median'] = statistics.median(v for _, v in post) if post else None
    result['envelope'] = False
    if envelope:
        post, result['envelope'] = lower_envelope(post, HEAP_ENVELOPE_BLOCK)
    result['post_n'] = len(post)
    if len(post) < MIN_TREND_POINTS:
        result['reason'] = 'fewer than %d post-warmup samples' % MIN_TREND_POINTS
        return result
    xs = [t / 3600.0 for t, _ in post]
    ys = [v for _, v in post]
    span = xs[-1] - xs[0]
    result['span_h'] = span
    slope = theil_sen(xs, ys)
    ols, r2 = least_squares(xs, ys)
    third = max(1, len(ys) // 3)
    early, late = statistics.median(ys[:third]), statistics.median(ys[-third:])
    half = len(post) // 2
    late_slope = theil_sen(xs[half:], ys[half:]) if len(post) - half >= 3 else None
    threshold = max(absolute_floor, relative_floor * abs(statistics.median(ys)))
    result.update(slope_h=slope, ols_h=ols, r2=r2, early=early, late=late, late_slope_h=late_slope,
                  threshold_h=threshold)
    rising = slope is not None and slope > threshold and late - early > 0.25 * threshold * span
    if rising and late_slope is not None and late_slope <= threshold:
        status = 'GROWTH SLOWING'
    elif rising:
        status = 'SUSTAINED GROWTH'
    elif slope is not None and slope < -threshold:
        status = 'DECREASING'
    else:
        status = 'STABLE'
    result['direction'] = status
    result['conclusive'] = span >= min_hours
    result['status'] = status if result['conclusive'] else 'INCONCLUSIVE'
    if not result['conclusive']:
        result['reason'] = 'post-warmup window %.1f min < %.1f h' % (span * 60, min_hours)
    return result


def nearest_rank(values, quantile):
    ordered = sorted(values)
    return ordered[max(0, math.ceil(len(ordered) * quantile) - 1)] if ordered else None


def ranks(values):
    """Average ranks, so that tied values do not get an order of their own."""
    order = sorted(range(len(values)), key=lambda index: values[index])
    result = [0.0] * len(values)
    start = 0
    while start < len(order):
        end = start
        while end + 1 < len(order) and values[order[end + 1]] == values[order[start]]:
            end += 1
        for position in range(start, end + 1):
            result[order[position]] = (start + end) / 2.0 + 1
        start = end + 1
    return result


def spearman(xs, ys):
    """Rank correlation; None when either side does not vary."""
    if len(xs) < 3:
        return None
    rank_x, rank_y = ranks(xs), ranks(ys)
    mean_x, mean_y = statistics.fmean(rank_x), statistics.fmean(rank_y)
    sxx = sum((x - mean_x) ** 2 for x in rank_x)
    syy = sum((y - mean_y) ** 2 for y in rank_y)
    if sxx == 0 or syy == 0:
        return None
    return sum((x - mean_x) * (y - mean_y) for x, y in zip(rank_x, rank_y)) / math.sqrt(sxx * syy)


# --------------------------------------------------------------------------- analysis

def resolve_warmup(model, warmup_s):
    if warmup_s is not None:
        return warmup_s
    spans = []
    for session in model['sessions']:
        times = [p['elapsed_s'] for p in model['points'] if p['session'] == session['index']]
        if times:
            spans.append(max(times) - (session['start_s'] if session['start_s'] is not None else min(times)))
    span = max(spans) if spans else 0.0
    return min(600.0, 0.2 * span)


def collector_totals(points):
    """(young collections, young pause ms, old collections) since the JVM started, for G1 counters.

    None when the latest sample has no collector whose name marks it as the young collector.
    """
    for point in reversed(points):
        collectors = point['gc_collectors']
        if collectors:
            young = [value for name, value in collectors.items() if 'young' in name.lower()]
            if not young:
                return None
            old = [value for name, value in collectors.items() if 'young' not in name.lower()]
            return sum(v[0] for v in young), sum(v[1] for v in young), sum(v[0] for v in old)
    return None


def analyze_memory(model, warmup_s, min_hours):
    rows = []
    for session in model['sessions'] or [{'index': 0, 'start_s': None}]:
        points = [p for p in model['points'] if p['session'] == session['index']]
        collections = collector_totals(points)
        for name, field, unit, absolute, relative in MEMORY_METRICS + COUNT_METRICS:
            series = [(p['elapsed_s'], p[field]) for p in points]
            result = trend(series, session['start_s'], warmup_s, absolute, relative, min_hours,
                           envelope=field == 'heap_used')
            result.update(name=name, field=field, unit=unit, session=session['index'])
            if (field == 'heap_used' and collections and collections[2] == 0
                    and result['status'] in ('SUSTAINED GROWTH', 'GROWTH SLOWING')):
                # Promoted objects stay in the old generation until it is collected. Before the first
                # such collection a rising heap floor does not tell a leak from uncollected garbage.
                result.update(direction=result['status'], status='INCONCLUSIVE', conclusive=False,
                              no_old_collection=True, reason='no old-generation collection in this JVM')
            rows.append(result)
    return rows


def analyze_process_memory(model, warmup_s, min_hours):
    """Fixture and driver trends over the whole run; both processes outlive JVM restarts."""
    points = sorted((p for p in model['points'] if p['elapsed_s'] is not None), key=lambda p: p['elapsed_s'])
    start = points[0]['elapsed_s'] if points else None
    rows = []
    for process, name, field, short, unit, absolute, relative in PROCESS_METRICS:
        result = trend([(p['elapsed_s'], p[field]) for p in points], start, warmup_s, absolute, relative, min_hours)
        result.update(name=name, process=process, field=short, unit=unit)
        rows.append(result)
    return rows


def analyze_generations(model):
    """G1 generation sizes and collection counts per JVM. Descriptive: no leak verdict is derived."""
    rows = []
    for session in model['sessions']:
        points = [p for p in model['points'] if p['session'] == session['index']]
        old = [(p['elapsed_s'], p['heap_old']) for p in points if p['heap_old'] is not None]
        survivors = [p['heap_survivor'] for p in points if p['heap_survivor'] is not None]
        totals = collector_totals(points)
        if not old and not totals:
            continue
        row = {'session': session['index'], 'n': len(old), 'old_first': None, 'old_last': None, 'old_delta': None,
               'span_h': None, 'survivor_median': statistics.median(survivors) if survivors else None,
               'survivor_max': max(survivors) if survivors else None,
               'young_collections': None, 'young_pause_mean_ms': None, 'old_collections': None}
        if old:
            row.update(old_first=old[0][1], old_last=old[-1][1], old_delta=old[-1][1] - old[0][1],
                       span_h=(old[-1][0] - old[0][0]) / 3600.0)
        if totals:
            young, young_ms, old_count = totals
            row.update(young_collections=int(young), old_collections=int(old_count),
                       young_pause_mean_ms=young_ms / young if young else None)
        rows.append(row)
    return rows


def cpu_series(model):
    """CPU use between consecutive samples as a percentage of one logical processor."""
    rows = []
    for session in model['sessions']:
        points = [p for p in model['points'] if p['session'] == session['index'] and p['cpu_ms'] is not None]
        for before, after in zip(points, points[1:]):
            wall = (after['elapsed_s'] - before['elapsed_s']) * 1000.0
            if wall > 0:
                rows.append({'session': session['index'], 'elapsed_s': after['elapsed_s'],
                             'cpu_pct': 100.0 * (after['cpu_ms'] - before['cpu_ms']) / wall})
    return rows


def interval_flags(interval, nominal_s, min_requests, operation='snapshot'):
    flags = []
    if nominal_s and interval['duration_s'] is not None and interval['duration_s'] < 0.5 * nominal_s:
        flags.append('short')
    entry = interval['latency'].get(operation)
    if not entry or (entry['count'] or 0) < min_requests:
        flags.append('low-count')
    if interval['failed']:
        flags.append('failure')
    if interval['closed_by'] in ('failure', 'interrupted'):
        flags.append(interval['closed_by'])
    return flags


def merged_windows(intervals, operation, min_requests):
    """Count-weighted means over runs of consecutive intervals that together reach min_requests.

    setValue and invoke run a few times per interval, so a single interval cannot give a percentile.
    Counts, means and maxima of consecutive intervals merge exactly; percentiles do not.
    """
    windows = []
    current = None
    for interval in intervals:
        entry = interval['latency'].get(operation)
        if not entry or not entry['count'] or entry['mean'] is None:
            continue
        if current and current['session'] != interval['session']:
            current = None
        if current is None:
            current = {'session': interval['session'], 'start_s': interval['start_s'], 'count': 0.0, 'sum': 0.0,
                       'max': 0.0, 'intervals': 0}
        current['count'] += entry['count']
        current['sum'] += entry['count'] * entry['mean']
        current['max'] = max(current['max'], entry['max'] or 0.0)
        current['intervals'] += 1
        current['end_s'] = interval['end_s']
        if current['count'] >= min_requests:
            current['mean'] = current['sum'] / current['count']
            windows.append(current)
            current = None
    return windows


def latency_status(ratio, slope, tolerance):
    if ratio is None:
        return NA
    if ratio > 1 + tolerance and (slope or 0) > 0:
        return 'DEGRADING'
    return 'IMPROVING' if ratio < 1 / (1 + tolerance) else 'STABLE'


def analyze_latency(model, warmup_s, min_requests, tolerance, min_hours):
    intervals = model['intervals']
    result = {'available': bool(intervals), 'ops': {}, 'throughput': None, 'outliers': []}
    if not intervals:
        return result
    nominal = model['interval_s']
    session_start = {s['index']: s['start_s'] or 0.0 for s in model['sessions']}
    for operation in OPERATIONS + ['throughput']:
        source = 'snapshot' if operation == 'throughput' else operation
        steady = [i for i in intervals if i['start_s'] is not None
                  and i['start_s'] - session_start.get(i['session'], 0.0) >= warmup_s]
        valid = [i for i in steady if not interval_flags(i, nominal, min_requests, source)]
        excluded = len(intervals) - len(valid)
        if operation == 'throughput':
            points = [((i['start_s'] + i['end_s']) / 2 / 3600.0, i['ips']) for i in valid
                      if i['ips'] is not None and i['end_s'] is not None]
            keys = ['ips']
        else:
            points = [((i['start_s'] + i['end_s']) / 2 / 3600.0, i['latency'][operation])
                      for i in valid if i['end_s'] is not None]
            keys = ['p50', 'p95', 'p99']
        entry = {'valid': len(points), 'excluded': excluded, 'status': 'INSUFFICIENT DATA', 'basis': 'p95'}
        if len(points) < 4 and operation != 'throughput':
            # Too few requests per interval for percentiles: compare merged-window means instead.
            usable = [i for i in steady if i['end_s'] is not None and not [
                f for f in interval_flags(i, nominal, min_requests, source) if f != 'low-count']]
            windows = merged_windows(usable, operation, min_requests)
            if len(windows) >= 4:
                means = [w['mean'] for w in windows]
                xs = [(w['start_s'] + w['end_s']) / 2 / 3600.0 for w in windows]
                quarter = max(1, len(windows) // 4)
                early, late = statistics.median(means[:quarter]), statistics.median(means[-quarter:])
                entry.update(basis='mean', windows=len(windows),
                             window_intervals=int(statistics.median(w['intervals'] for w in windows)),
                             early_mean=early, late_mean=late, ratio=late / early if early else None,
                             slope_h=theil_sen(xs, means), span_h=xs[-1] - xs[0])
                entry['status'] = latency_status(entry['ratio'], entry['slope_h'], tolerance)
                if entry['status'] != NA and entry['span_h'] < min_hours:
                    entry['direction'], entry['status'] = entry['status'], 'INCONCLUSIVE'
        if len(points) >= 4:
            quarter = max(1, len(points) // 4)
            for key in keys:
                values = [p[1] if key == 'ips' else p[1][key] for p in points]
                entry['early_' + key] = statistics.median(values[:quarter])
                entry['late_' + key] = statistics.median(values[-quarter:])
            primary = 'ips' if operation == 'throughput' else 'p95'
            values = [p[1] if primary == 'ips' else p[1][primary] for p in points]
            entry['slope_h'] = theil_sen([p[0] for p in points], values)
            entry['span_h'] = points[-1][0] - points[0][0]
            early, late = entry['early_' + primary], entry['late_' + primary]
            ratio = late / early if early else None
            entry['ratio'] = ratio
            if ratio is None:
                entry['status'] = NA
            elif operation == 'throughput':
                entry['status'] = 'DEGRADING' if ratio < 1 / (1 + tolerance) else 'IMPROVING' if ratio > 1 + tolerance else 'STABLE'
            else:
                entry['status'] = latency_status(ratio, entry['slope_h'], tolerance)
            if entry['status'] != NA and entry['span_h'] < min_hours:
                # One early and one late minute of a short run are not a trend.
                entry['direction'], entry['status'] = entry['status'], 'INCONCLUSIVE'
        if operation == 'throughput':
            result['throughput'] = entry
        else:
            result['ops'][operation] = entry
    reference = (model['op_latency'].get('snapshot') or model['latency'].get('snapshot') or {}).get('p99')
    for interval in intervals:
        entry = interval['latency'].get('snapshot')
        if entry and entry['max'] is not None:
            result['outliers'].append((entry['max'], interval))
    result['outliers'].sort(key=lambda item: item[0], reverse=True)
    result['outliers'] = result['outliers'][:5]
    result['outlier_reference_p99'] = reference
    return result


def interval_loads(model):
    """Work and host load per interval, from the cumulative counters at both ends of the interval.

    The starting point is the latest resource sample at or before the interval start: the previous
    interval's closing sample, or the session's first sample for its first interval.
    """
    rows = []
    for interval in model['intervals']:
        after = interval['resources']
        before = None
        if interval['start_s'] is not None:
            earlier = [p for p in model['points']
                       if p['session'] == interval['session'] and p['elapsed_s'] <= interval['start_s'] + 0.001]
            before = earlier[-1] if earlier else None

        def spent(key):
            if after is None or before is None:
                return None
            return difference(after[key], before[key])

        completed = interval['completed']

        def per_iteration(value):
            return None if value is None or not completed else value / completed

        # Each sample lists the processes that were busiest since the sample before it, so every
        # sample taken inside the interval contributes, including its closing sample.
        busiest = {}
        if interval['start_s'] is not None and interval['end_s'] is not None:
            for point in model['points']:
                if (point['session'] == interval['session']
                        and interval['start_s'] < point['elapsed_s'] <= interval['end_s'] + 0.5):
                    for name, cpu in point['host_top']:
                        busiest[name] = busiest.get(name, 0.0) + (cpu or 0.0)

        latency = interval['latency']
        snapshot = latency.get('snapshot') or {}
        busy, idle = spent('host_busy_ms'), spent('host_idle_ms')
        capacity = None if busy is None or idle is None or busy + idle <= 0 else busy + idle
        own = [spent('cpu_ms'), spent('fixture_cpu_ms'), spent('driver_cpu_ms')]
        other = None if capacity is None or None in own else max(0.0, busy - sum(own))
        base = spent('host_perf_base')
        accounted = [entry['count'] * entry['mean'] for entry in latency.values()
                     if entry and entry['count'] and entry['mean'] is not None]
        duration = interval['duration_s']
        rows.append({
            'index': interval['index'], 'session': interval['session'], 'snapshot_p95': snapshot.get('p95'),
            'info_p95': (latency.get('getElementInfo') or {}).get('p95'),
            'find_mean': (latency.get('findElement') or {}).get('mean'),
            'jvm_cpu_ms_per_iter': per_iteration(spent('cpu_ms')),
            'fixture_cpu_ms_per_iter': per_iteration(spent('fixture_cpu_ms')),
            'driver_cpu_ms_per_iter': per_iteration(spent('driver_cpu_ms')),
            # Wall time of the interval that no request accounts for: the script's own work.
            'driver_overhead_ms_per_iter': per_iteration(duration * 1000.0 - sum(accounted))
            if duration and accounted else None,
            'gc_count': spent('gc_count'), 'gc_ms': spent('gc_time_ms'),
            'host_cpu_pct': None if capacity is None else 100.0 * busy / capacity,
            'other_cpu_pct': None if other is None else 100.0 * other / capacity,
            # The counter is an average weighted by its base: delta raw / delta base is already a percentage.
            # Windows keeps one 32-bit base per logical processor and reports their mean, which steps back
            # whenever one of them wraps. An interval that contains such a step has no usable value.
            'perf_pct': None if base is None or base <= 0 or spent('host_perf_raw') is None
            else spent('host_perf_raw') / base,
            'user_idle_s': None if after is None or after['host_user_idle_ms'] is None
            else after['host_user_idle_ms'] / 1000.0,
            'available_memory_mib': None if after is None or after['host_available_memory'] is None
            else after['host_available_memory'] / MIB,
            'ac_power': None if after is None else after['host_ac_power'],
            'top': sorted(busiest.items(), key=lambda item: item[1], reverse=True),
            'slow_requests': interval['slow_count'], 'valid': False, 'slow': False,
        })
    return rows


def analyze_load(model, warmup_s, min_requests):
    """Split valid intervals into normal and slow ones and show which measurements differ between them.

    Slow means a snapshot p95 above SLOW_INTERVAL_FACTOR times the lower quartile of all valid
    intervals. The comparison is descriptive: a measurement that moves with latency is a lead, not a cause.
    """
    rows = interval_loads(model)
    result = {'intervals': rows, 'status': 'INSUFFICIENT DATA' if rows else NA, 'baseline_p95': None,
              'threshold_p95': None, 'valid': 0, 'slow': 0, 'covariates': [], 'moving': [], 'processes': []}
    session_start = {s['index']: s['start_s'] or 0.0 for s in model['sessions']}
    for interval, row in zip(model['intervals'], rows):
        row['valid'] = (row['snapshot_p95'] is not None and interval['start_s'] is not None
                        and interval['start_s'] - session_start.get(interval['session'], 0.0) >= warmup_s
                        and not interval_flags(interval, model['interval_s'], min_requests))
    valid = [row for row in rows if row['valid']]
    result['valid'] = len(valid)
    comparable = len(valid) >= 8
    if comparable:
        result['baseline_p95'] = nearest_rank([row['snapshot_p95'] for row in valid], 0.25)
        result['threshold_p95'] = SLOW_INTERVAL_FACTOR * result['baseline_p95']
        for row in valid:
            row['slow'] = row['snapshot_p95'] > result['threshold_p95']
        result['slow'] = sum(1 for row in valid if row['slow'])
        result['status'] = 'COMPARED' if result['slow'] else 'NO SLOW INTERVALS'
    for key, field, label, digits in LOAD_COVARIATES:
        measured = [row for row in valid if row[field] is not None]
        normal = [row[field] for row in measured if not row['slow']]
        slow = [row[field] for row in measured if row['slow']]
        entry = {'key': key, 'label': label, 'digits': digits, 'n': len(measured),
                 'normal': statistics.median(normal) if comparable and len(normal) >= 3 else None,
                 'slow': statistics.median(slow) if comparable and len(slow) >= 3 else None,
                 'rho': spearman([row['snapshot_p95'] for row in measured], [row[field] for row in measured])
                 if comparable and len(measured) >= 8 else None}
        result['covariates'].append(entry)
        if entry['rho'] is not None and abs(entry['rho']) >= MOVING_RHO:
            result['moving'].append(key)
    # CPU time of the busiest other processes, averaged per interval. A process outside a sample's
    # list counts as zero, so a short burst is diluted over the intervals where it was not listed.
    names = {}
    for row in valid:
        group = 'slow' if row['slow'] else 'normal'
        for name, cpu in row['top']:
            entry = names.setdefault(name, {'name': name, 'slow_sum': 0.0, 'normal_sum': 0.0, 'slow_seen': 0, 'normal_seen': 0})
            entry[group + '_sum'] += cpu
            entry[group + '_seen'] += 1
    slow_count, normal_count = result['slow'], len(valid) - result['slow']
    for entry in names.values():
        entry['slow_ms'] = entry.pop('slow_sum') / slow_count if slow_count else None
        entry['normal_ms'] = entry.pop('normal_sum') / normal_count if normal_count else None
    result['processes'] = sorted(names.values(), key=lambda e: (e['slow_ms'] or 0.0, e['normal_ms'] or 0.0),
                                 reverse=True)[:10]
    return result


GC_LINE = re.compile(r'^\[(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3})([+-]\d{4})\]\[(\d+\.\d+)s\]\[\w+\s*\]\[([\w,]+)\s*\] (.*)$')
GC_PAUSE = re.compile(r'^GC\((\d+)\) (Pause .+?) (\d+)M->(\d+)M\((\d+)M\) (\d+\.\d+)ms$')
GC_OBJECT_COPY = re.compile(r'^GC\((\d+)\)\s+Object Copy \(ms\):\s+Min:\s*[\d.]+, Avg:\s*([\d.]+)')
GC_REFERENCES = re.compile(r'^GC\((\d+)\)\s+Reference Processing: ([\d.]+)ms')
GC_AGE = re.compile(r'^GC\((\d+)\) - age\s+\d+:\s+\d+ bytes,\s+(\d+) total')
GC_REGIONS = re.compile(r'^GC\((\d+)\) (Old|Humongous) regions: \d+->(\d+)')
GC_REGION_SIZE = re.compile(r'^Heap Region Size: (\d+)M')
SAFEPOINT = re.compile(r'^Safepoint "([^"]+)".*?Total: (\d+) ns')


def parse_gc_log(text, region_mb=None):
    """Stop-the-world pauses and safepoints from a unified JVM log decorated with time or utctime and uptime.

    A pause line is written when the pause ends, so its window is [end - ms, end]. Lines in any other
    format are ignored. region_mb supplies the heap region size when this part of a rotated log does
    not contain the JVM's start-up lines.
    """
    pauses, safepoints, details = [], [], {}
    for line in text.splitlines():
        match = GC_LINE.match(line)
        if not match:
            continue
        stamp, offset, uptime, tags, message = match.groups()
        if tags == 'gc,init':
            size = GC_REGION_SIZE.match(message)
            if size:
                region_mb = int(size.group(1))
            continue
        if tags == 'gc,heap':
            regions = GC_REGIONS.match(message)
            if regions:  # regions left after the pause
                detail = details.setdefault(int(regions.group(1)), {})
                detail['old_regions'] = detail.get('old_regions', 0) + int(regions.group(3))
            continue
        if tags == 'safepoint':
            safepoint = SAFEPOINT.match(message)
            if safepoint:
                safepoints.append({'end': datetime.strptime(stamp + offset, '%Y-%m-%dT%H:%M:%S.%f%z').astimezone(timezone.utc),
                                   'name': safepoint.group(1), 'total_ms': int(safepoint.group(2)) / 1e6})
            continue
        if tags == 'gc,phases':
            for pattern, key in ((GC_OBJECT_COPY, 'object_copy_ms'), (GC_REFERENCES, 'reference_ms')):
                detail = pattern.match(message)
                if detail:
                    details.setdefault(int(detail.group(1)), {})[key] = float(detail.group(2))
            continue
        if tags == 'gc,age':
            age = GC_AGE.match(message)
            if age:  # the running total on the last age line is everything that survived
                details.setdefault(int(age.group(1)), {})['survivor_bytes'] = int(age.group(2))
            continue
        pause = GC_PAUSE.match(message) if tags == 'gc' else None
        if pause:
            number = int(pause.group(1))
            detail = details.pop(number, {})
            old_regions = detail.get('old_regions')
            pauses.append({'id': number, 'kind': pause.group(2), 'ms': float(pause.group(6)),
                           'end': datetime.strptime(stamp + offset, '%Y-%m-%dT%H:%M:%S.%f%z').astimezone(timezone.utc),
                           'uptime_s': float(uptime), 'before_mb': int(pause.group(3)), 'after_mb': int(pause.group(4)),
                           'heap_mb': int(pause.group(5)), 'object_copy_ms': detail.get('object_copy_ms'),
                           'reference_ms': detail.get('reference_ms'), 'survivor_bytes': detail.get('survivor_bytes'),
                           'old_bytes': None if old_regions is None or region_mb is None
                           else old_regions * region_mb * MIB})
    return {'pauses': pauses, 'safepoints': safepoints, 'region_mb': region_mb}


def load_gc_logs(model, directory, explicit=None):
    """Read each session's GC log from the report's directory, including rotated parts (name.0, name.1, ...).

    explicit paths replace the names recorded in the report and are used as given.
    """
    result = {'pauses': [], 'safepoints': [], 'files': [], 'missing': []}
    names = list(explicit) if explicit else [s['gc_log'] for s in model['sessions'] if s['gc_log']]
    for name in names:
        path = name if explicit or os.path.isabs(name) else os.path.join(directory, name)
        parts = [p for p in [path] + sorted(glob.glob(glob.escape(path) + '.*')) if os.path.isfile(p)]
        if not parts:
            result['missing'].append(name)
            continue
        texts = []
        for part in parts:
            with open(part, encoding='utf-8', errors='replace') as handle:
                texts.append(handle.read())
        # The region size is logged once at JVM start, which rotation moves into an older part.
        sizes = [parse_gc_log(text)['region_mb'] for text in texts]
        region_mb = next((size for size in sizes if size is not None), None)
        for text in texts:
            parsed = parse_gc_log(text, region_mb)
            result['pauses'].extend(parsed['pauses'])
            result['safepoints'].extend(parsed['safepoints'])
        result['files'].append(name)
    result['pauses'].sort(key=lambda pause: pause['end'])
    result['safepoints'].sort(key=lambda safepoint: safepoint['end'])
    return result


def analyze_gc(gc):
    """Pause statistics from the GC logs; the jvmstat counters only give counts and totals."""
    pauses = gc['pauses']
    result = {'files': gc['files'], 'missing': gc['missing'], 'count': len(pauses), 'longest': [], 'other_safepoint': None}
    if not pauses:
        return result
    durations = [pause['ms'] for pause in pauses]

    def median_of(key):
        values = [pause[key] for pause in pauses if pause[key] is not None]
        return statistics.median(values) if values else None

    old = [pause['old_bytes'] for pause in pauses if pause['old_bytes'] is not None]
    result.update(p50=nearest_rank(durations, 0.50), p95=nearest_rank(durations, 0.95), max=max(durations),
                  total_ms=sum(durations), longest=sorted(pauses, key=lambda pause: pause['ms'], reverse=True)[:5],
                  object_copy_median=median_of('object_copy_ms'), reference_median=median_of('reference_ms'),
                  survivor_median=median_of('survivor_bytes'),
                  old_first=old[0] if old else None, old_last=old[-1] if old else None, old_pauses=len(old))
    # A safepoint that is not a collection also stops every Java thread.
    others = [s for s in gc['safepoints'] if 'Collect' not in s['name'] and 'GC' not in s['name']]
    if others:
        result['other_safepoint'] = max(others, key=lambda safepoint: safepoint['total_ms'])
    return result


def analyze_slow(model, gc):
    """Count slow requests and match the recorded ones against GC pause windows."""
    tracked = [i for i in model['intervals'] if i['slow_count'] is not None]
    result = {'available': bool(model['slow_threshold_ms']) and bool(tracked),
              'threshold_ms': model['slow_threshold_ms'], 'limit': model['slow_limit'], 'total': None,
              'by_operation': {}, 'recorded': [], 'overlapping': None}
    if not result['available']:
        return result
    result['total'] = int(sum(i['slow_count'] for i in tracked))
    for interval in tracked:
        for operation, count in interval['slow_counts'].items():
            result['by_operation'][operation] = result['by_operation'].get(operation, 0) + int(count)
        for request in interval['slow_requests']:
            if request['ms'] is not None:
                result['recorded'].append(dict(request, interval=interval['index'], gc=None))
    if gc['files']:
        tolerance = timedelta(seconds=GC_MATCH_TOLERANCE_S)
        for request in result['recorded']:
            if request['end'] is None:
                continue
            start = request['end'] - timedelta(milliseconds=request['ms'])
            best = None
            for pause in gc['pauses']:
                pause_start = pause['end'] - timedelta(milliseconds=pause['ms'])
                overlap = min(request['end'] + tolerance, pause['end']) - max(start - tolerance, pause_start)
                if overlap > timedelta(0) and (best is None or overlap > best[0]):
                    best = (overlap, pause)
            request['gc'] = best[1] if best else None
        result['overlapping'] = sum(1 for request in result['recorded'] if request['gc'])
    return result


def operation_overall(model):
    """Whole-run per-operation statistics; legacy files only allow exact merges of count/mean/max."""
    if model['op_latency']:
        return {k: dict(v, merged=False) for k, v in model['op_latency'].items() if v}, 'reported'
    merged = {}
    for name, entry in model['latency'].items():
        if not entry:
            continue
        operation = LEGACY_OPERATION.get(name, name)
        if operation not in merged:
            merged[operation] = dict(entry, merged=False, parts=1)
            continue
        target = merged[operation]
        count = (target['count'] or 0) + (entry['count'] or 0)
        target['mean'] = ((target['mean'] or 0) * (target['count'] or 0) + (entry['mean'] or 0) * (entry['count'] or 0)) / count
        target['max'] = max(target['max'] or 0, entry['max'] or 0)
        target['count'] = count
        target['p50'] = target['p95'] = target['p99'] = None  # percentiles cannot be merged exactly
        target['merged'] = True
    return merged, 'derived'


def consistency_checks(model):
    """Compare first/last-sample deltas with the resourceChange the soak script recorded."""
    fields = {'privateBytes': 'private', 'workingSetBytes': 'working_set', 'cpuMs': 'cpu_ms', 'handles': 'handles',
              'threads': 'threads', 'nmtReservedBytes': 'nmt_reserved', 'nmtCommittedBytes': 'nmt_committed',
              'heapCommittedBytes': 'heap_committed', 'heapUsedBytes': 'heap_used'}
    checks = []
    for session in model['sessions']:
        recorded = session['resource_change']
        samples = session['samples']
        if not recorded or len(samples) < 2:
            continue
        for raw_name, field in fields.items():
            if raw_name not in recorded or samples[0][field] is None or samples[-1][field] is None:
                continue
            computed = samples[-1][field] - samples[0][field]
            checks.append((session['index'], raw_name, num(recorded[raw_name]), computed,
                           abs(computed - (num(recorded[raw_name]) or 0)) < 1e-6))
    return checks


def analyze(model, warmup_s=None, min_hours=1.0, min_requests=20, tolerance=0.2, gc=None):
    warmup = resolve_warmup(model, warmup_s)
    gc = gc or {'pauses': [], 'safepoints': [], 'files': [],
                'missing': [s['gc_log'] for s in model['sessions'] if s['gc_log']]}
    return {
        'warmup_s': warmup, 'min_hours': min_hours, 'min_requests': min_requests, 'tolerance': tolerance,
        'memory': analyze_memory(model, warmup, min_hours),
        'process_memory': analyze_process_memory(model, warmup, min_hours),
        'generations': analyze_generations(model),
        'cpu': cpu_series(model),
        'latency': analyze_latency(model, warmup, min_requests, tolerance, min_hours),
        'load': analyze_load(model, warmup, min_requests),
        'gc': analyze_gc(gc),
        'slow': analyze_slow(model, gc),
        'operations': operation_overall(model),
        'checks': consistency_checks(model),
    }


# --------------------------------------------------------------------------- report

def fmt(value, digits=2, unit=''):
    if value is None:
        return NA
    return ('{:,.%df}' % digits).format(value) + unit


def fmt_bytes(value, signed=False):
    if value is None:
        return NA
    return ('{:+,.1f}' if signed else '{:,.1f}').format(value / MIB) + ' MiB'


def fmt_metric(value, unit, signed=False):
    if unit == 'bytes':
        return fmt_bytes(value, signed)
    if value is None:
        return NA
    return ('{:+,.1f}' if signed else '{:,.1f}').format(value)


def fmt_int(value):
    return NA if value is None else '{:,}'.format(int(value))


def slope_text(entry, min_hours):
    """A per-hour slope is shown only when the fitted window is long enough not to be an extrapolation."""
    span = entry.get('span_h')
    return fmt(entry.get('slope_h'), 3) if span is not None and span >= min_hours else NA


def status_text(entry):
    if entry.get('status') == 'INCONCLUSIVE':
        return 'INCONCLUSIVE (%s)' % entry.get('direction', NA)
    return entry.get('status', NA)


def table(headers, rows):
    lines = ['| ' + ' | '.join(headers) + ' |', '|' + '|'.join('---' for _ in headers) + '|']
    lines += ['| ' + ' | '.join(str(cell) for cell in row) + ' |' for row in rows]
    return lines


def dash(value, digits=1):
    """A cell of the wide load tables, where a measurement missing from the input is shown as a dash."""
    return '-' if value is None else ('{:,.%df}' % digits).format(value)


def utc_text(moment):
    return NA if moment is None else moment.strftime('%Y-%m-%dT%H:%M:%S.') + '%03dZ' % (moment.microsecond // 1000)


def trend_cells(row):
    unit = row['unit']
    return (row['n'], fmt_metric(row.get('first'), unit), fmt_metric(row.get('last'), unit),
            fmt_metric(row.get('delta'), unit, True), fmt_metric(row.get('min'), unit),
            fmt_metric(row.get('max'), unit), fmt_metric(row.get('warmup_median'), unit),
            fmt_metric(row.get('post_median'), unit),
            fmt_metric(row.get('slope_h'), unit, True) if row['conclusive'] else NA, fmt(row.get('r2'), 2),
            'INCONCLUSIVE (%s)' % row['direction'] if row['status'] == 'INCONCLUSIVE' else row['status'])


TREND_HEADERS = ['Samples', 'First', 'Last', 'Last-first', 'Min', 'Max', 'Warmup median', 'Post-warmup median',
                 'Theil-Sen /h', 'OLS R²', 'Trend']


def run_status(model):
    if model['passed']:
        return 'PASSED'
    if model['interrupted']:
        return 'INTERRUPTED'
    if not model['finished']:
        return 'INCOMPLETE CHECKPOINT'
    return 'FAILED'


def stability_findings(model, analysis):
    findings = []
    if not model['passed']:
        findings.append(('FAIL', 'Run did not pass (status %s, stage %s): %s'
                         % (run_status(model), model['stage'], model['error'] or 'no error message')))
    abnormal = [s for s in model['sessions'] if s['unexpected_exit'] or s['exited_normally'] is False]
    exits = model['unexpected_exits']
    if exits or abnormal:
        findings.append(('FAIL', 'Abnormal JVM termination: %s session(s) %s'
                         % (fmt_int(exits if exits is not None else len(abnormal)),
                            ', '.join(str(s['index']) for s in abnormal) or NA)))
    if model['failed']:
        findings.append(('FAIL', 'Failed iterations: %s of %s' % (fmt_int(model['failed']), fmt_int(model['attempted']))))
    if model['timeouts']:
        findings.append(('FAIL', 'Request timeouts: %s' % fmt_int(model['timeouts'])))
    for row in analysis['memory']:
        if row['status'] in ('SUSTAINED GROWTH', 'GROWTH SLOWING'):
            findings.append(('WARN' if row['status'] == 'SUSTAINED GROWTH' else 'NOTE',
                             '%s %s at %s/h in session %d (late-half %s/h)' % (
                                 row['name'], row['status'].lower(), fmt_metric(row['slope_h'], row['unit'], True),
                                 row['session'], fmt_metric(row['late_slope_h'], row['unit'], True))))
    for row in analysis['process_memory']:
        if row['status'] in ('SUSTAINED GROWTH', 'GROWTH SLOWING'):
            # Growth in the provider process may be caused by the client; the driver is only the test tool.
            warn = row['status'] == 'SUSTAINED GROWTH' and row['process'] == 'fixture'
            findings.append(('WARN' if warn else 'NOTE', '%s %s at %s/h over the run (late-half %s/h)' % (
                row['name'], row['status'].lower(), fmt_metric(row['slope_h'], row['unit'], True),
                fmt_metric(row['late_slope_h'], row['unit'], True))))
    for operation, entry in analysis['latency']['ops'].items():
        if entry['status'] == 'DEGRADING' and entry['basis'] == 'mean':
            findings.append(('WARN', '%s mean rose from %s to %s ms (early vs late merged windows)'
                             % (operation, fmt(entry.get('early_mean')), fmt(entry.get('late_mean')))))
        elif entry['status'] == 'DEGRADING':
            findings.append(('WARN', '%s p95 rose from %s to %s ms (early vs late intervals)'
                             % (operation, fmt(entry.get('early_p95')), fmt(entry.get('late_p95')))))
    throughput = analysis['latency']['throughput']
    if throughput and throughput['status'] == 'DEGRADING':
        findings.append(('WARN', 'Throughput fell from %s to %s iterations/s'
                         % (fmt(throughput.get('early_ips')), fmt(throughput.get('late_ips')))))
    return findings


def verdict(model, analysis, findings):
    if any(level == 'FAIL' for level, _ in findings):
        return 'FAIL'
    if any(level == 'WARN' for level, _ in findings):
        return 'PASS WITH WARNINGS'
    evaluated = [r for r in analysis['memory'] if r['status'] not in (NA, 'INSUFFICIENT DATA')]
    if not evaluated or any(r['status'] == 'INCONCLUSIVE' for r in evaluated):
        return 'PASS (long-term memory behaviour INCONCLUSIVE)'
    return 'PASS'


def render(model, analysis, source):
    lines = []
    out = lines.append
    env = model['environment']
    out('# Java/JNA 장시간 안정성 분석')
    out('')
    out('입력: `%s` · 형식: %s · 생성: `tools/Analyze-JnaSoak.py`' % (
        source.replace('\\', '/'),
        'schemaVersion %d (구간 집계%s)' % (model['schema'], ', 프로세스·호스트 계측' if model['schema'] >= 3 else '')
        if model['schema'] >= 2 else '기존 형식(schemaVersion 없음, 구간 데이터 없음)'))
    out('')
    findings = stability_findings(model, analysis)
    out('**종합 판정: %s**' % verdict(model, analysis, findings))
    out('')

    out('## 1. 테스트 환경 및 실행 요약')
    out('')
    java = (env.get('java') or NA).splitlines()
    rows = [
        ('OS', env.get('os') or NA), ('PowerShell', env.get('powerShell') or NA),
        ('Logical processors', env.get('processorCount') or NA), ('Java', java[0] if java else NA),
        ('JAR SHA-256', env.get('jarSha256') or NA),
        ('Start (UTC)', model['start'] or NA), ('Finish (UTC)', model['finished'] or NA),
        ('Last checkpoint (UTC)', model['checkpoint'] or NA),
        ('Elapsed', NA if model['elapsed_s'] is None else '%s s (%.2f h)' % (fmt(model['elapsed_s'], 1), model['elapsed_s'] / 3600)),
        ('Duration limit', fmt(model['duration_limit_s'], 0, ' s')),
        ('Resource sample period', fmt(model['sample_s'], 0, ' s')),
        ('Aggregation interval', fmt(model['interval_s'], 0, ' s')),
        ('Warmup excluded from trends', '%s s per JVM session' % fmt(analysis['warmup_s'], 0)),
        ('Sessions (JVMs)', len(model['sessions'])),
        ('Resource samples / intervals', '%d / %d' % (len(model['points']), len(model['intervals']))),
    ]
    # Recorded from schemaVersion 3 on; older reports simply have no such rows.
    if env.get('cpu'):
        nominal = num(env.get('cpuNominalMhz'))
        rows.append(('CPU', '%s%s' % (env['cpu'], '' if nominal is None else ' (nominal %s MHz)' % fmt_int(nominal))))
    if num(env.get('memoryBytes')) is not None:
        rows.append(('Memory', '%.1f GiB' % (num(env.get('memoryBytes')) / (1024 * MIB))))
    power = obj(env.get('power'))
    if power.get('scheme'):
        rows.append(('Power scheme', '%s%s' % (
            '%s (%s)' % (power['schemeName'], power['scheme']) if power.get('schemeName') else power['scheme'],
            ', mode overlay %s' % power['overlay'] if power.get('overlay') else '')))
    on_ac = [p['host_ac_power'] for p in model['points'] if p['host_ac_power'] is not None]
    if on_ac:
        rows.append(('Power source', 'AC in %d of %d samples' % (sum(1 for value in on_ac if value), len(on_ac))))
    if env.get('gitCommit'):
        rows.append(('Source commit', '%s%s' % (str(env['gitCommit'])[:12], ' (modified)' if env.get('gitDirty') is True else '')))
    if model['slow_threshold_ms'] is not None:
        rows.append(('Slow request tracking', 'disabled' if not model['slow_threshold_ms'] else
                     '>= %s ms, slowest %s per interval keep their time' % (
                         fmt(model['slow_threshold_ms'], 0), fmt_int(model['slow_limit']))))
    logs = [s['gc_log'] for s in model['sessions'] if s['gc_log']]
    if logs:
        rows.append(('GC log', ', '.join('`%s`' % name for name in logs)))
    lines.extend(table(['Item', 'Value'], rows))
    out('')

    out('## 2. 테스트 성공/실패 현황')
    out('')
    rows = [
        ('Status', run_status(model)), ('Stage', model['stage'] or NA), ('Error', model['error'] or '-'),
        ('Attempted / completed iterations', '%s / %s' % (fmt_int(model['attempted']), fmt_int(model['completed']))),
        ('Mutation iterations (setValue + invoke)', fmt_int(model['mutations'])),
        ('Failed iterations', fmt_int(model['failed'])),
        ('Failure rate', NA if model['failure_rate'] is None else '%.4f%%' % (100 * model['failure_rate'])),
        ('Completed / failed requests', '%s / %s' % (fmt_int(model['requests_completed']), fmt_int(model['requests_failed']))),
        ('Timeouts', fmt_int(model['timeouts'])),
        ('Error codes', ', '.join('%s=%s' % (k, v) for k, v in model['error_counts'].items()) or
         ('-' if model['schema'] >= 2 else NA)),
        ('Session restarts', NA if not model['sessions'] else str(len(model['sessions']) - 1)),
    ]
    lines.extend(table(['Item', 'Value'], rows))
    if model['failures']:
        out('')
        out('Failure events:')
        out('')
        lines.extend(table(['Elapsed (s)', 'Session', 'Interval', 'Code', 'Operation', 'JVM exited', 'Message'], [
            (fmt((num(f.get('elapsedMs')) or 0) / 1000 if num(f.get('elapsedMs')) is not None else None, 1),
             f.get('sessionIndex', NA), f.get('intervalIndex', '-'), f.get('code', NA), f.get('operation') or '-',
             f.get('jvmExited', NA), str(f.get('message', '')).replace('|', '/'))
            for f in model['failures']]))
    out('')

    out('## 3. 전체 응답 성능')
    out('')
    method = model['latency_method'] or (
        'Exact nearest-rank over every retained sample (legacy format).' if model['schema'] < 2 else NA)
    out('분위수 계산: %s' % method)
    out('')
    if model['latency']:
        lines.extend(table(['Request (script key)', 'Count', 'Mean ms', 'p50 ms', 'p95 ms', 'p99 ms', 'Max ms'], [
            (k, fmt_int(v['count']), fmt(v['mean']), fmt(v['p50']), fmt(v['p95']), fmt(v['p99']), fmt(v['max']))
            for k, v in model['latency'].items() if v]))
    else:
        out('Whole-run latency: %s' % NA)
    operations, origin = analysis['operations']
    if operations:
        out('')
        out('Per operation (%s):' % ('reported by the soak script' if origin == 'reported' else
                                     'derived; merged percentiles are NOT AVAILABLE because the legacy file has no samples to merge'))
        out('')
        lines.extend(table(['Operation', 'Count', 'Mean ms', 'p50 ms', 'p95 ms', 'p99 ms', 'Max ms'], [
            (k, fmt_int(v['count']), fmt(v['mean']), fmt(v['p50']), fmt(v['p95']), fmt(v['p99']), fmt(v['max']))
            for k, v in operations.items()]))
    out('')

    out('## 4. 시간 구간별 응답 성능')
    out('')
    latency = analysis['latency']
    if not latency['available']:
        out('%s: this JSON has no per-interval latency data. Only whole-run statistics exist.' % NA)
    else:
        out('구간 내부 분위수는 정확한 nearest-rank 값이다. `short`: 명목 길이의 절반 미만, `low-count`: snapshot 요청 %d개 미만. '
            '두 경우와 실패 구간, 워밍업 구간은 추세 비교에서 제외한다.' % analysis['min_requests'])
        out('')
        rows = []
        for interval in model['intervals']:
            snap = interval['latency'].get('snapshot') or {}
            find = interval['latency'].get('findElement') or {}
            invoke = interval['latency'].get('invoke') or {}
            set_value = interval['latency'].get('setValue') or {}
            rows.append((interval['index'], interval['session'],
                         fmt(interval['start_s'], 0), fmt(interval['duration_s'], 1),
                         fmt_int(interval['completed']), fmt_int(interval['mutations']),
                         fmt_int(interval['requests']), fmt_int(interval['failed']), fmt_int(interval['timeouts']),
                         fmt(interval['ips']), fmt(snap.get('p50')), fmt(snap.get('p95')), fmt(snap.get('p99')),
                         fmt(snap.get('max')), fmt(find.get('p95')), fmt(set_value.get('p95')), fmt(invoke.get('p95')),
                         ' '.join(interval_flags(interval, model['interval_s'], analysis['min_requests'])) or '-'))
        lines.extend(table(['#', 'JVM', 'Start s', 'Dur s', 'Iter', 'Mut', 'Req', 'Fail', 'T/O', 'Iter/s',
                            'Snap p50', 'Snap p95', 'Snap p99', 'Snap max', 'Find p95', 'Set p95', 'Invoke p95', 'Flags'],
                           rows))
        out('')
        out('초반·후반 비교 (유효 구간의 첫 1/4과 마지막 1/4 중앙값, 허용 변동 ±%d%%):' % round(100 * analysis['tolerance']))
        out('')
        rows = []
        for operation, entry in latency['ops'].items():
            if entry['basis'] == 'mean':
                continue
            rows.append((operation, entry['valid'], entry['excluded'], fmt(entry.get('early_p50')), fmt(entry.get('late_p50')),
                         fmt(entry.get('early_p95')), fmt(entry.get('late_p95')), fmt(entry.get('early_p99')),
                         fmt(entry.get('late_p99')), slope_text(entry, analysis['min_hours']), status_text(entry)))
        lines.extend(table(['Operation', 'Valid', 'Excluded', 'Early p50', 'Late p50', 'Early p95', 'Late p95',
                            'Early p99', 'Late p99', 'p95 slope ms/h', 'Status'], rows))
        throughput = latency['throughput'] or {}
        out('')
        out('처리량: early %s → late %s iterations/s, slope %s /h, status %s' % (
            fmt(throughput.get('early_ips')), fmt(throughput.get('late_ips')), slope_text(throughput, analysis['min_hours']),
            status_text(throughput) if throughput else NA))
        out('')
        out('setValue와 invoke는 변경 간격(기본 15초)마다 1회씩 실행되어 구간 하나로는 분위수를 낼 수 없다. '
            '요청 수가 %d개에 이를 때까지 연속 구간을 묶고, 묶음의 평균(요청 수 가중)을 첫 1/4과 마지막 1/4끼리 비교한다. '
            '묶음이 4개 미만이면 3절의 전체 통계만 본다. 기울기는 유효 구간이 %.1f시간 이상일 때만 표시한다.'
            % (analysis['min_requests'], analysis['min_hours']))
        merged = [(operation, entry) for operation, entry in latency['ops'].items() if entry['basis'] == 'mean']
        if merged:
            out('')
            lines.extend(table(['Operation', 'Windows', 'Intervals per window', 'Early mean', 'Late mean', 'Late / early',
                                'Mean slope ms/h', 'Status'], [
                (operation, entry['windows'], entry['window_intervals'], fmt(entry.get('early_mean')),
                 fmt(entry.get('late_mean')), fmt(entry.get('ratio')), slope_text(entry, analysis['min_hours']),
                 status_text(entry)) for operation, entry in merged]))
        if latency['outliers']:
            out('')
            reference = latency['outlier_reference_p99']
            out('Snapshot 최대 지연 상위 구간 (전체 p99 %s ms 대비):' % fmt(reference))
            out('')
            lines.extend(table(['Interval', 'Start s', 'Max ms', 'x run p99'], [
                (i['index'], fmt(i['start_s'], 0), fmt(value), fmt(value / reference) if reference else NA)
                for value, i in latency['outliers']]))
        load = analysis['load']
        out('')
        out('구간별 부하. JVM·Fixture·Driver는 반복 1회당 CPU 시간, Between req는 요청 사이에 측정 스크립트가 쓴 시간이다. '
            'Host와 Other(JVM·Fixture·Driver를 뺀 나머지)는 전체 논리 프로세서 대비 %%, Speed는 명목 주파수 대비 프로세서 속도 %%다. '
            'Fixture는 시험 앱(UIA 공급자), Driver는 측정 스크립트 프로세스다. `-`는 입력에 없는 값이다 (%s).' % NA)
        out('')
        lines.extend(table(['#', 'Iter/s', 'Snap p95', 'JVM ms/iter', 'Fixture ms/iter', 'Driver ms/iter',
                            'Between req ms/iter', 'GC n', 'GC ms', 'Host %', 'Other %', 'Speed %', 'Slow req',
                            'User idle s', 'Class'], [
            (row['index'], dash(interval['ips'], 2), dash(row['snapshot_p95'], 2), dash(row['jvm_cpu_ms_per_iter']),
             dash(row['fixture_cpu_ms_per_iter']), dash(row['driver_cpu_ms_per_iter']),
             dash(row['driver_overhead_ms_per_iter']), dash(row['gc_count'], 0), dash(row['gc_ms'], 0),
             dash(row['host_cpu_pct']), dash(row['other_cpu_pct']), dash(row['perf_pct'], 0),
             dash(row['slow_requests'], 0), dash(row['user_idle_s'], 0),
             'slow' if row['slow'] else 'normal' if row['valid'] else 'excluded')
            for interval, row in zip(model['intervals'], load['intervals'])]))
        out('')
        if load['status'] == 'COMPARED':
            out('느린 구간 %d개 / 유효 구간 %d개. 느린 구간은 snapshot p95가 %s ms를 넘는 구간이다 '
                '(유효 구간 하위 25%% 값 %s ms의 %.1f배).' % (
                    load['slow'], load['valid'], fmt(load['threshold_p95']), fmt(load['baseline_p95']), SLOW_INTERVAL_FACTOR))
        elif load['status'] == 'NO SLOW INTERVALS':
            out('느린 구간 없음: 유효 구간 %d개의 snapshot p95가 모두 %s ms 이하다 (하위 25%% 값 %s ms의 %.1f배).' % (
                load['valid'], fmt(load['threshold_p95']), fmt(load['baseline_p95']), SLOW_INTERVAL_FACTOR))
        else:
            out('느린 구간 비교: 유효 구간이 8개 미만이라 판정하지 않는다 (INSUFFICIENT DATA).')
        if load['status'] in ('COMPARED', 'NO SLOW INTERVALS'):
            out('')
            lines.extend(table(['Measurement', 'Intervals', 'Normal median', 'Slow median', 'Slow / normal',
                                'Spearman ρ vs snapshot p95'], [
                (c['label'], c['n'], fmt(c['normal'], c['digits']), fmt(c['slow'], c['digits']),
                 fmt(c['slow'] / c['normal']) if c['slow'] is not None and c['normal'] else NA, fmt(c['rho']))
                for c in load['covariates']]))
            out('')
            labels = {key: label for key, _, label, _ in LOAD_COVARIATES}
            out('snapshot p95와 함께 움직인 측정값 (|ρ| ≥ %.1f): %s. 순위 상관은 같은 구간에서 함께 변했다는 뜻이며 원인을 증명하지 않는다. '
                '값이 변하지 않았거나 입력에 없는 측정값의 ρ는 %s다.' % (
                    MOVING_RHO, ', '.join(labels[key] for key in load['moving']) or '없음', NA))
        out('')
        if load['processes']:
            out('JVM·Fixture·Driver를 뺀 상위 CPU 프로세스 (유효 구간 1개당 평균 CPU 시간). 표본마다 상위 %s개만 기록되므로 '
                '목록에 없던 구간은 0으로 계산된다:' % fmt_int(model['top_processes']))
            out('')
            lines.extend(table(['Process', 'Slow intervals ms', 'Normal intervals ms', 'Listed in slow / normal intervals'], [
                (p['name'].replace('|', '/'), fmt(p['slow_ms'], 0), fmt(p['normal_ms'], 0),
                 '%d / %d' % (p['slow_seen'], p['normal_seen'])) for p in load['processes']]))
        else:
            out('상위 프로세스 기록: %s. `Test-JnaSoak.ps1 -TopProcesses N`으로 실행하면 표본마다 다른 프로세스의 '
                'CPU 시간과 이름을 남긴다.' % NA)
    out('')

    def memory_section(title, fields):
        out(title)
        out('')
        lines.extend(table(['Metric', 'JVM'] + TREND_HEADERS, [
            (row['name'], row['session']) + trend_cells(row) for row in analysis['memory'] if row['field'] in fields]))
        out('')

    def process_section(fields):
        rows = [row for row in analysis['process_memory'] if row['field'] in fields]
        if all(row['status'] == NA for row in rows):
            out('시험 앱(Fixture)과 측정 스크립트(Driver) 프로세스의 표본: %s.' % NA)
        else:
            out('시험 앱(Fixture, UIA 공급자)과 측정 스크립트(Driver) 프로세스. JVM 재시작과 무관하므로 전체 실행 기간으로 본다:')
            out('')
            lines.extend(table(['Metric'] + TREND_HEADERS, [(row['name'],) + trend_cells(row) for row in rows]))
        out('')

    memory_section('## 5. JVM Heap 및 Native Memory',
                   {'heap_used', 'heap_committed', 'nmt_reserved', 'nmt_committed'})
    out('Theil-Sen 기울기(/h)는 워밍업 이후 관측 구간이 %.1f시간 이상일 때만 표시하며, 짧은 구간을 시간당 값으로 외삽하지 않는다. '
        % analysis['min_hours'])
    out('')
    out('Heap used는 GC 주기에 따라 톱니형으로 변하므로 추세는 연속 %d개 표본의 최솟값(하한 포락선)으로 계산한다. '
        '표본이 부족하면 원 표본을 사용한다. Heap은 Java 객체, NMT는 HotSpot이 추적하는 네이티브 영역이며 서로 다른 지표다.'
        % HEAP_ENVELOPE_BLOCK)
    gc_points = [p for p in model['points'] if p['gc_count'] is not None]
    out('')
    if gc_points:
        first, last = gc_points[0], gc_points[-1]
        out('GC (HotSpot jvmstat, 첫 → 마지막 표본, 세션별 누적값): %s → %s 회, %s → %s ms' % (
            fmt_int(first['gc_count']), fmt_int(last['gc_count']), fmt(first['gc_time_ms'], 1), fmt(last['gc_time_ms'], 1)))
    else:
        out('GC 횟수·시간: %s' % NA)
    if analysis['generations']:
        out('')
        out('세대별 Heap과 수거 횟수 (G1). Old(used − young)는 old와 humongous 영역의 합에 대한 추정값이고 survivor는 young에 '
            '포함된다. young은 덜 찬 영역도 통째로 세므로 추정값은 몇 영역만큼 작게 나올 수 있다. Old 증가는 누수 판정에 쓰지 않는다:')
        out('')
        lines.extend(table(['JVM', 'Samples', 'Old first', 'Old last', 'Old last-first', 'Survivor median', 'Survivor max',
                            'Young collections', 'Young mean pause ms', 'Old collections (full + concurrent)'], [
            (g['session'], g['n'], fmt_bytes(g['old_first']), fmt_bytes(g['old_last']), fmt_bytes(g['old_delta'], True),
             fmt_bytes(g['survivor_median']), fmt_bytes(g['survivor_max']), fmt_int(g['young_collections']),
             fmt(g['young_pause_mean_ms'], 1), fmt_int(g['old_collections'])) for g in analysis['generations']]))
        for g in analysis['generations']:
            if g['old_collections'] == 0:
                out('')
                out('JVM %d: old 영역 수거가 없어, 승격된 객체가 누수인지 아직 수거되지 않은 가비지인지 이 실행으로는 구분할 수 없다.'
                    % g['session'])
    gc = analysis['gc']
    out('')
    if gc['count']:
        out('GC 로그의 일시정지 %d회 (%s): 중앙값 %s ms, p95 %s ms, 최대 %s ms, 합계 %s ms. '
            'Object Copy 작업자 평균의 중앙값 %s ms, Reference Processing 중앙값 %s ms, 일시정지 후 생존 객체 중앙값 %s.' % (
                gc['count'], ', '.join('`%s`' % name for name in gc['files']), fmt(gc['p50'], 1), fmt(gc['p95'], 1),
                fmt(gc['max'], 1), fmt(gc['total_ms'], 0), fmt(gc['object_copy_median'], 1),
                fmt(gc['reference_median'], 1), fmt_bytes(gc['survivor_median'])))
        if gc['old_pauses']:
            out('')
            out('일시정지 직후 old + humongous 영역 (영역 단위로 정확한 값): 첫 기록 %s → 마지막 기록 %s.' % (
                fmt_bytes(gc['old_first']), fmt_bytes(gc['old_last'])))
        out('')
        lines.extend(table(['End (UTC)', 'GC', 'Kind', 'Pause ms', 'Heap MiB', 'Object copy ms', 'Reference ms'], [
            (utc_text(p['end']), p['id'], p['kind'], fmt(p['ms'], 1), '%d → %d (%d)' % (p['before_mb'], p['after_mb'], p['heap_mb']),
             fmt(p['object_copy_ms'], 1), fmt(p['reference_ms'], 1)) for p in gc['longest']]))
        if gc['other_safepoint']:
            out('')
            out('GC가 아닌 safepoint 중 최대: %s ms ("%s", %s).' % (
                fmt(gc['other_safepoint']['total_ms'], 2), gc['other_safepoint']['name'], utc_text(gc['other_safepoint']['end'])))
    elif gc['missing']:
        out('GC 로그: %s (파일 없음: %s). 보고서와 같은 폴더에 두거나 `--gc-log`로 지정한다.' % (
            NA, ', '.join('`%s`' % name for name in gc['missing'])))
    else:
        out('GC 로그: %s (%s).' % (NA, '`-NoGcLog`로 실행' if model['schema'] >= 3 else '이 형식은 GC 로그를 남기지 않는다'))
    out('')
    memory_section('## 6. Private Bytes / Working Set', {'private', 'native_untracked', 'working_set'})
    out('Private bytes는 프로세스 전용 커밋 메모리, Working set은 현재 물리 메모리에 있는 페이지로 OS가 회수할 수 있다. '
        'Native outside NMT는 HotSpot이 추적하지 않는 COM·JNA 등 네이티브 할당의 증감을 보여준다.')
    out('')
    process_section({'private'})
    memory_section('## 7. CPU / 핸들 / 스레드 추세', {'handles', 'threads'})
    process_section({'handles', 'threads'})
    cpu = analysis['cpu']
    if cpu:
        values = [row['cpu_pct'] for row in cpu]
        quarter = max(1, len(values) // 4)
        out('CPU (표본 사이 JVM CPU 시간 / 경과 시간, 논리 프로세서 1개 = 100%%): median %s%%, max %s%%, '
            'first quarter %s%% → last quarter %s%%' % (
                fmt(statistics.median(values), 1), fmt(max(values), 1),
                fmt(statistics.median(values[:quarter]), 1), fmt(statistics.median(values[-quarter:]), 1)))
    else:
        out('CPU 사용률: %s' % NA)
    out('')

    out('## 8. 메모리 누수 의심 징후')
    out('')
    out('최초·최종 값 차이만으로 판정하지 않는다. 각 JVM 세션에서 워밍업 이후 표본의 Theil-Sen 기울기, '
        '초반 1/3과 후반 1/3 중앙값, 후반부 기울기를 함께 본다. 임계값은 지표별 절대 하한과 중앙값의 1%%/h 중 큰 값이다. '
        '관측 구간이 %.1f시간 미만이면 결론을 내리지 않는다.' % analysis['min_hours'])
    out('')
    tracked = analysis['memory'] + analysis['process_memory']

    def scope(row):
        return 'JVM %d' % row['session'] if 'session' in row else 'whole run'

    suspects = [r for r in tracked if r['status'] in ('SUSTAINED GROWTH', 'GROWTH SLOWING')]
    if suspects:
        lines.extend(table(['Metric', 'Scope', 'Status', 'Slope /h', 'Late-half slope /h', 'Threshold /h',
                            'Early → late median', 'Conclusive'], [
            (r['name'], scope(r), r['status'], fmt_metric(r['slope_h'], r['unit'], True),
             fmt_metric(r['late_slope_h'], r['unit'], True), fmt_metric(r['threshold_h'], r['unit']),
             '%s → %s' % (fmt_metric(r['early'], r['unit']), fmt_metric(r['late'], r['unit'])),
             'yes') for r in suspects]))
    elif any(r['conclusive'] for r in tracked):
        out('워밍업 이후 충분히 관측된 지표 중 임계값을 넘는 지속 증가 없음.')
    evaluated = [r for r in tracked if r['status'] not in (NA, 'INSUFFICIENT DATA')]
    uncollected = [r for r in evaluated if r['status'] == 'INCONCLUSIVE' and r.get('no_old_collection')]
    short = [r for r in evaluated if r['status'] == 'INCONCLUSIVE' and not r.get('no_old_collection')]
    if not evaluated:
        out('')
        out('추세 판정 가능한 지표 없음: %s.' % NA)
    elif short:
        rising = ['%s (%s)' % (r['name'], scope(r)) for r in short
                  if r['direction'] in ('SUSTAINED GROWTH', 'GROWTH SLOWING')]
        out('')
        out('관측 구간이 짧아 장기 누수 여부는 판단할 수 없다 (INCONCLUSIVE, %s). 짧은 구간에서 증가한 지표: %s. '
            '시작 직후의 증가를 시간당 값으로 외삽하지 않는다.' % (short[0].get('reason'), ', '.join(rising) or '없음'))
    for r in uncollected:
        out('')
        out('%s (%s): %s 방향이지만 old 영역 수거가 없어 판정하지 않는다 (INCONCLUSIVE). 승격된 객체는 old 영역이 '
            '수거되기 전까지 남으므로, 그 전의 하한 증가는 누수와 가비지 누적을 구분하지 못한다.'
            % (r['name'], scope(r), r['direction']))
    out('')

    out('## 9. 성능 저하 징후')
    out('')
    if not latency['available']:
        out('구간별 지연 데이터 %s. 성능 저하 추세를 판정할 수 없다.' % NA)
    else:
        def change(operation, entry):
            # Low-count operations are compared on merged-window means, the others on interval p95.
            measure = 'mean' if entry['basis'] == 'mean' else 'p95'
            return '%s %s: %s → %s ms (x%s)' % (operation, '묶음 평균' if measure == 'mean' else 'p95',
                                                 fmt(entry.get('early_' + measure)), fmt(entry.get('late_' + measure)),
                                                 fmt(entry.get('ratio')))

        degraded = [(k, v) for k, v in latency['ops'].items() if v['status'] == 'DEGRADING']
        if degraded:
            for operation, entry in degraded:
                out('- %s, slope %s ms/h' % (change(operation, entry), slope_text(entry, analysis['min_hours'])))
        else:
            pending = [(k, v) for k, v in latency['ops'].items()
                       if v['status'] == 'INCONCLUSIVE' and v.get('direction') == 'DEGRADING']
            if pending:
                for operation, entry in pending:
                    out('- %s. 증가했으나 유효 구간이 %.1f시간 미만이라 판정하지 않음 (INCONCLUSIVE).' % (
                        change(operation, entry), analysis['min_hours']))
            else:
                out('- 허용 변동(±%d%%)을 넘는 p95 지연 증가 없음 (요청이 적은 연산은 묶음 평균 기준).'
                    % round(100 * analysis['tolerance']))
        throughput = latency['throughput'] or {}
        out('- 처리량: %s' % (status_text(throughput) if throughput else NA))
        if any(v['status'] == 'INCONCLUSIVE' for v in list(latency['ops'].values()) + [throughput]):
            out('- 유효 구간이 %.1f시간 미만인 항목은 INCONCLUSIVE로 표시하고 경고로 판정하지 않는다.' % analysis['min_hours'])
        insufficient = [k for k, v in latency['ops'].items() if v['status'] == 'INSUFFICIENT DATA']
        if insufficient:
            out('- 유효 구간 또는 묶음이 4개 미만이라 판정 불가: %s' % ', '.join(insufficient))
    slow = analysis['slow']
    out('')
    if not slow['available']:
        out('느린 요청 기록: %s (%s).' % (NA, '`-SlowRequestMs 0`으로 실행' if model['slow_threshold_ms'] == 0
                                    else 'schemaVersion 3부터 구간별로 기록'))
    else:
        recorded = slow['recorded']
        out('느린 요청 (지연 %s ms 이상): 전체 %s개 (%s). 구간마다 가장 느린 %s개만 완료 시각을 남기며, 그렇게 기록된 요청은 %d개다.' % (
            fmt(slow['threshold_ms'], 0), fmt_int(slow['total']),
            ', '.join('%s %d' % item for item in sorted(slow['by_operation'].items())) or '-',
            fmt_int(slow['limit']), len(recorded)))
        if slow['overlapping'] is None:
            out('')
            out('GC 로그가 없어 느린 요청을 GC 일시정지와 대조하지 못했다 (%s).' % NA)
        else:
            apart = [r['ms'] for r in recorded if not r['gc']]
            out('')
            out('기록된 요청 중 GC 일시정지와 겹친 요청 %d개, 겹치지 않은 요청 %d개%s. 겹치지 않은 요청은 GC로 설명되지 않는 지연이다.' % (
                slow['overlapping'], len(apart),
                ' (중앙값 %s ms, 최대 %s ms)' % (fmt(statistics.median(apart), 1), fmt(max(apart), 1)) if apart else ''))
        if recorded:
            out('')
            lines.extend(table(['End (UTC)', 'Interval', 'Operation', 'Latency ms', 'Overlapping GC pause'], [
                (utc_text(r['end']), r['interval'], r['op'] or NA, fmt(r['ms'], 1),
                 NA if slow['overlapping'] is None else
                 'GC(%d) %s ms' % (r['gc']['id'], fmt(r['gc']['ms'], 1)) if r['gc'] else '-')
                for r in sorted(recorded, key=lambda r: r['ms'], reverse=True)[:10]]))
    out('')

    out('## 10. 안정성 평가')
    out('')
    rows = [(s['index'], s['pid'] or NA, s['jvm_start'] or NA, fmt_int(s['completed']), fmt_int(s['mutations']),
             s['end_reason'] or NA, NA if s['exited_normally'] is None else ('yes' if s['exited_normally'] else 'no'),
             'yes' if s['unexpected_exit'] else ('no' if model['schema'] >= 2 else NA), s['shutdown_error'] or '-')
            for s in model['sessions']]
    if rows:
        lines.extend(table(['JVM', 'PID', 'JVM start (UTC)', 'Iterations', 'Mutations', 'End reason', 'Exited normally',
                            'Unexpected exit', 'Shutdown error'], rows))
    else:
        out('JVM 세션 기록: %s' % NA)
    out('')
    if findings:
        for level, message in findings:
            out('- **%s** %s' % (level, message))
    else:
        undecided = [r for r in analysis['memory'] + analysis['process_memory'] if r['status'] == 'INCONCLUSIVE'] + [
            v for v in list(analysis['latency']['ops'].values()) + [analysis['latency']['throughput'] or {}]
            if v.get('status') == 'INCONCLUSIVE']
        if undecided:
            out('- 실패와 비정상 종료 없음. 메모리·성능 추세 일부는 확정하지 않았다 (8·9절 INCONCLUSIVE 참고).')
        else:
            out('- 실패, 비정상 종료, 지속 증가 또는 성능 저하 징후 없음.')
    if analysis['checks']:
        mismatches = [c for c in analysis['checks'] if not c[4]]
        out('- 기록된 `resourceChange`와 첫·마지막 표본 재계산 비교: %d개 항목 중 %d개 불일치.' % (
            len(analysis['checks']), len(mismatches)))
        for session, name, recorded, computed, _ in mismatches:
            out('  - JVM %s %s: recorded %s, computed %s' % (session, name, recorded, computed))
    out('')

    out('## 11. 데이터의 한계')
    out('')
    limits = [
        'HotSpot NMT는 JVM이 할당한 네이티브 메모리만 집계한다. COM 객체 참조 수와 UIAutomationCore 등 네이티브 DLL의 '
        '할당은 직접 계수하지 않으므로 COM 해제 여부는 Private bytes, 핸들, JVM 종료로 간접 관찰한다.',
        'Working set은 공유 페이지를 포함하며 OS가 회수할 수 있어 누수 지표로 단독 사용하지 않는다.',
        'Heap used는 표본 시점의 GC 위상에 좌우된다. GC 직후 값이 아니므로 하한 포락선도 근사치다.',
        '실패한 반복에서 실패 전에 완료된 요청의 지연은 집계되지 않는다. 실패 요청은 오류 코드별로 계수한다.',
        'jcmd 표본 수집은 별도 프로세스로 실행되며 수집 시간은 구간 지속 시간에서 제외한다(`samplingMs`).',
    ]
    if model['schema'] < 2:
        limits.append('기존 형식은 구간별 지연, 요청·오류 코드별 계수, GC 횟수를 포함하지 않는다: %s.' % NA)
    else:
        limits.append('전체 실행 분위수는 1% 폭의 로그 히스토그램 근사(최대 1% 과대)이며 count·mean·max는 정확하다. '
                      '구간 분위수는 정확하다.')
    if model['schema'] < 3:
        limits.append('시험 앱·측정 스크립트·호스트 지표, 세대별 Heap, 느린 요청의 시각, GC 로그는 schemaVersion 3부터 기록된다: %s.' % NA)
    else:
        limits.append('Host·Other CPU와 프로세서 속도는 두 표본 사이의 평균이다. 표본 수집 때 실행되는 jcmd의 CPU 시간은 '
                      'Other에 포함된다.')
        limits.append('프로세서 속도 카운터의 기준값은 논리 프로세서마다 32비트라서 주기적으로 되돌아간다. '
                      '기준값이 되돌아간 구간의 속도는 계산하지 않는다: %s.' % NA)
        limits.append('상위 프로세스 목록은 표본 시점에 살아 있는 프로세스만 포함한다. 두 표본 사이에 시작해서 끝난 '
                      '프로세스는 Other CPU에만 반영된다.')
        limits.append('느린 요청은 구간마다 가장 느린 몇 개만 완료 시각을 남기고 나머지는 개수만 센다. GC 로그와는 같은 '
                      '시스템 시계를 기준으로 %d ms 오차를 허용해 대조한다.' % round(GC_MATCH_TOLERANCE_S * 1000))
    if not gc_points:
        limits.append('GC 횟수와 시간: %s.' % NA)
    if model['elapsed_s'] is not None and model['elapsed_s'] < analysis['min_hours'] * 3600:
        limits.append('관측 기간 %.1f분은 장기 누수 판정 기준 %.1f시간보다 짧다.' % (model['elapsed_s'] / 60, analysis['min_hours']))
    if not model['finished']:
        limits.append('종료 기록이 없는 체크포인트다. 마지막 체크포인트 이후의 데이터는 없다.')
    for item in limits:
        out('- ' + item)
    out('')

    out('## 12. 후속 권고')
    out('')
    advice = []
    if model['schema'] < 2:
        advice.append('구간별 추세가 필요하면 현재 `Test-JnaSoak.ps1`(`-IntervalSeconds`)로 다시 측정한다.')
    elif model['schema'] < 3:
        advice.append('느린 구간의 원인을 좁히려면 현재 `Test-JnaSoak.ps1`로 다시 측정한다. 시험 앱·호스트 지표와 GC 로그가 '
                      '함께 기록되어 4절에서 무엇이 지연과 함께 변했는지 볼 수 있다.')
    if model['elapsed_s'] is None or model['elapsed_s'] < analysis['min_hours'] * 3600:
        advice.append('메모리 추세 판정을 위해 8시간 시험을 실행한다.')
    if any(r['status'] == 'SUSTAINED GROWTH' and r['conclusive'] for r in analysis['memory']):
        advice.append('증가 지표가 있는 세션에서 NMT detail baseline/diff와 핸들 종류(Handle 도구 등)를 수집해 원인을 분리한다.')
    if any(level == 'FAIL' for level, _ in findings):
        advice.append('실패 이벤트의 시각과 같은 구간의 리소스 값을 확인하고 동일 조건으로 재현한다.')
    if latency['available'] and any(v['status'] == 'DEGRADING' for v in latency['ops'].values()):
        advice.append('지연 증가가 메모리 또는 핸들 증가와 같은 시점에서 시작하는지 CSV 시계열로 대조한다.')
    advice.append('실제 설비 앱과 x86 JVM에서의 장시간 시험은 별도로 필요하다.')
    for item in advice:
        out('- ' + item)
    out('')
    return '\n'.join(lines)


# --------------------------------------------------------------------------- CSV

RESOURCE_COLUMNS = ['session', 'pid', 'elapsed_s', 'utc', 'heap_used', 'heap_committed', 'nmt_reserved',
                    'nmt_committed', 'private', 'working_set', 'cpu_ms', 'handles', 'threads', 'gc_count', 'gc_time_ms',
                    # schemaVersion 3; empty for older reports
                    'heap_young', 'heap_survivor', 'heap_old', 'native_untracked',
                    'fixture_cpu_ms', 'fixture_private', 'fixture_working_set', 'fixture_handles', 'fixture_threads',
                    'driver_cpu_ms', 'driver_private', 'driver_working_set', 'driver_handles', 'driver_threads',
                    'host_busy_ms', 'host_idle_ms', 'host_perf_raw', 'host_perf_base', 'host_available_memory',
                    'host_ac_power', 'host_user_idle_ms', 'host_fixture_foreground', 'host_fixture_minimized']
LOAD_COLUMNS = ['jvm_cpu_ms_per_iter', 'fixture_cpu_ms_per_iter', 'driver_cpu_ms_per_iter',
                'driver_overhead_ms_per_iter', 'gc_count', 'gc_ms', 'host_cpu_pct', 'other_cpu_pct', 'perf_pct',
                'user_idle_s', 'slow_requests']


def write_csv(model, directory, load=None):
    os.makedirs(directory, exist_ok=True)
    resources = os.path.join(directory, 'jna-soak-resources.csv')
    with open(resources, 'w', newline='', encoding='utf-8') as handle:
        writer = csv.writer(handle)
        writer.writerow(RESOURCE_COLUMNS)
        for point in model['points']:
            writer.writerow(['' if point[c] is None else point[c] for c in RESOURCE_COLUMNS])
    written = [resources]
    if model['intervals']:
        intervals = os.path.join(directory, 'jna-soak-intervals.csv')
        header = ['index', 'session', 'start_s', 'end_s', 'duration_s', 'closed_by', 'completed', 'failed',
                  'mutations', 'requests', 'requests_failed', 'timeouts', 'iterations_per_s', 'requests_per_s']
        for operation in OPERATIONS:
            header += ['%s_%s' % (operation, key) for key in ('count', 'mean', 'p50', 'p95', 'p99', 'max')]
        header += ['heap_used', 'nmt_committed', 'private', 'working_set', 'handles', 'threads']
        loads = {row['index']: row for row in (load or {}).get('intervals', [])}
        header += LOAD_COLUMNS + ['valid_interval', 'slow_interval']
        with open(intervals, 'w', newline='', encoding='utf-8') as handle:
            writer = csv.writer(handle)
            writer.writerow(header)
            for i in model['intervals']:
                row = [i['index'], i['session'], i['start_s'], i['end_s'], i['duration_s'], i['closed_by'],
                       i['completed'], i['failed'], i['mutations'], i['requests'], i['requests_failed'],
                       i['timeouts'], i['ips'], i['rps']]
                for operation in OPERATIONS:
                    entry = i['latency'].get(operation) or {}
                    row += [entry.get(key) for key in ('count', 'mean', 'p50', 'p95', 'p99', 'max')]
                point = i['resources'] or {}
                row += [point.get(k) for k in ('heap_used', 'nmt_committed', 'private', 'working_set', 'handles', 'threads')]
                measured = loads.get(i['index'])
                row += [None] * (len(LOAD_COLUMNS) + 2) if measured is None else (
                    [measured[k] for k in LOAD_COLUMNS] + [int(measured['valid']), int(measured['slow'])])
                writer.writerow(['' if value is None else value for value in row])
        written.append(intervals)
    return written


# --------------------------------------------------------------------------- CLI

def main(argv=None):
    parser = argparse.ArgumentParser(description='Analyze a Test-JnaSoak.ps1 JSON report.')
    parser.add_argument('input', help='soak JSON report or checkpoint')
    parser.add_argument('--output', default=os.path.join('target', 'jna-soak-analysis.md'),
                        help='Markdown report path (default: target/jna-soak-analysis.md)')
    parser.add_argument('--csv-dir', help='also write jna-soak-resources.csv and jna-soak-intervals.csv here')
    parser.add_argument('--warmup-seconds', type=float,
                        help='per-session warmup excluded from trends (default: min(600, 20%% of the session))')
    parser.add_argument('--min-trend-hours', type=float, default=1.0,
                        help='post-warmup span required for a conclusive memory trend (default: 1)')
    parser.add_argument('--min-interval-requests', type=int, default=20,
                        help='intervals with fewer snapshot requests are excluded from latency trends (default: 20)')
    parser.add_argument('--tolerance', type=float, default=0.2,
                        help='relative early/late change tolerated before flagging (default: 0.2)')
    parser.add_argument('--no-recover', action='store_true', help='do not fall back to a pending checkpoint file')
    parser.add_argument('--gc-log', action='append', metavar='PATH',
                        help='JVM GC log to read instead of the files named in the report, which are looked up '
                             'next to the report (repeat for several JVM sessions)')
    args = parser.parse_args(argv)
    try:
        report, source = load_report(args.input, recover=not args.no_recover)
    except SoakInputError as error:
        print('error: %s' % error, file=sys.stderr)
        return 2
    if source != args.input:
        print('warning: %s is unreadable; analyzing pending checkpoint %s' % (args.input, source), file=sys.stderr)
    model = normalize(report)
    gc = load_gc_logs(model, os.path.dirname(os.path.abspath(source)), args.gc_log)
    for name in gc['missing']:
        print('warning: GC log %s was not found' % name, file=sys.stderr)
    analysis = analyze(model, args.warmup_seconds, args.min_trend_hours, args.min_interval_requests, args.tolerance, gc)
    markdown = render(model, analysis, source)
    directory = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(directory, exist_ok=True)
    with open(args.output, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(markdown)
    print('wrote %s' % args.output)
    if args.csv_dir:
        for path in write_csv(model, args.csv_dir, analysis['load']):
            print('wrote %s' % path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
