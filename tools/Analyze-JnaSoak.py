#!/usr/bin/env python3
"""Analyze a Test-JnaSoak.ps1 JSON report and write a Markdown stability report.

Supports the original 60-second soak format (no schemaVersion, session samples only) and the
interval format (schemaVersion 2). Interrupted runs and checkpoints are analyzed as far as their
data goes; anything that is not in the input is reported as NOT AVAILABLE instead of estimated.
Only the Python standard library is used.

    python tools/Analyze-JnaSoak.py target/windows-uia-jna-soak.json \
        --output target/jna-soak-analysis.md --csv-dir target
"""
import argparse
import csv
import glob
import json
import math
import os
import statistics
import sys

NA = 'NOT AVAILABLE'
MIB = 1024.0 * 1024.0

# name, sample field, unit, absolute growth floor per hour, relative growth floor per hour
MEMORY_METRICS = [
    ('Heap used (lower envelope)', 'heap_used', 'bytes', 2 * MIB, 0.01),
    ('Heap committed', 'heap_committed', 'bytes', 4 * MIB, 0.01),
    ('NMT reserved', 'nmt_reserved', 'bytes', 4 * MIB, 0.01),
    ('NMT committed', 'nmt_committed', 'bytes', 2 * MIB, 0.01),
    ('Private bytes', 'private', 'bytes', 4 * MIB, 0.01),
    ('Working set', 'working_set', 'bytes', 4 * MIB, 0.01),
]
COUNT_METRICS = [
    ('Handles', 'handles', 'count', 10.0, 0.01),
    ('Threads', 'threads', 'count', 1.0, 0.01),
]
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


def resource_point(source, session_index, elapsed_ms=None):
    """Normalize a session sample, an interval resource point or failure resources."""
    source = obj(source)
    nested = obj(source.get('resources'))
    java = obj(nested.get('java')) if nested else obj(source.get('java'))
    flat = source if 'privateBytes' in source or 'cpuMs' in source else java
    gc = obj(source.get('gc'))
    elapsed = num(source.get('elapsedMs')) if elapsed_ms is None else elapsed_ms
    return {
        'session': session_index,
        'elapsed_s': None if elapsed is None else elapsed / 1000.0,
        'utc': (nested or source).get('utc'),
        'pid': flat.get('pid'),
        'jvm_start': flat.get('startUtc'),
        'heap_used': num(source.get('heapUsedBytes')),
        'heap_committed': num(source.get('heapCommittedBytes')),
        'nmt_reserved': num(source.get('nmtReservedBytes')),
        'nmt_committed': num(source.get('nmtCommittedBytes')),
        'private': num(flat.get('privateBytes')),
        'working_set': num(flat.get('workingSetBytes')),
        'cpu_ms': num(flat.get('cpuMs')),
        'handles': num(flat.get('handles')),
        'threads': num(flat.get('threads')),
        'gc_count': num(gc.get('totalInvocations')) if gc.get('available') else None,
        'gc_time_ms': num(gc.get('totalTimeMs')) if gc.get('available') else None,
    }


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


def analyze_memory(model, warmup_s, min_hours):
    rows = []
    for session in model['sessions'] or [{'index': 0, 'start_s': None}]:
        points = [p for p in model['points'] if p['session'] == session['index']]
        for name, field, unit, absolute, relative in MEMORY_METRICS + COUNT_METRICS:
            series = [(p['elapsed_s'], p[field]) for p in points]
            result = trend(series, session['start_s'], warmup_s, absolute, relative, min_hours,
                           envelope=field == 'heap_used')
            result.update(name=name, field=field, unit=unit, session=session['index'])
            rows.append(result)
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


def analyze_latency(model, warmup_s, min_requests, tolerance, min_hours):
    intervals = model['intervals']
    result = {'available': bool(intervals), 'ops': {}, 'throughput': None, 'outliers': []}
    if not intervals:
        return result
    nominal = model['interval_s']
    session_start = {s['index']: s['start_s'] or 0.0 for s in model['sessions']}
    for operation in OPERATIONS + ['throughput']:
        source = 'snapshot' if operation == 'throughput' else operation
        valid = [i for i in intervals
                 if not interval_flags(i, nominal, min_requests, source)
                 and i['start_s'] is not None
                 and i['start_s'] - session_start.get(i['session'], 0.0) >= warmup_s]
        excluded = len(intervals) - len(valid)
        if operation == 'throughput':
            points = [((i['start_s'] + i['end_s']) / 2 / 3600.0, i['ips']) for i in valid
                      if i['ips'] is not None and i['end_s'] is not None]
            keys = ['ips']
        else:
            points = [((i['start_s'] + i['end_s']) / 2 / 3600.0, i['latency'][operation])
                      for i in valid if i['end_s'] is not None]
            keys = ['p50', 'p95', 'p99']
        entry = {'valid': len(points), 'excluded': excluded, 'status': 'INSUFFICIENT DATA'}
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
                entry['status'] = ('DEGRADING' if ratio > 1 + tolerance and (entry['slope_h'] or 0) > 0
                                   else 'IMPROVING' if ratio < 1 / (1 + tolerance) else 'STABLE')
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


def analyze(model, warmup_s=None, min_hours=1.0, min_requests=20, tolerance=0.2):
    warmup = resolve_warmup(model, warmup_s)
    return {
        'warmup_s': warmup, 'min_hours': min_hours, 'min_requests': min_requests, 'tolerance': tolerance,
        'memory': analyze_memory(model, warmup, min_hours),
        'cpu': cpu_series(model),
        'latency': analyze_latency(model, warmup, min_requests, tolerance, min_hours),
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
    for operation, entry in analysis['latency']['ops'].items():
        if entry['status'] == 'DEGRADING':
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
        'schemaVersion %d (구간 집계)' % model['schema'] if model['schema'] >= 2 else '기존 형식(schemaVersion 없음, 구간 데이터 없음)'))
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
        out('setValue와 invoke는 변경 간격(기본 15초)마다 1회씩 실행되어 구간당 요청이 적다. '
            '요청 수가 기준 미만인 구간은 해당 연산의 추세에서 제외되며, 이 경우 3절의 전체 통계를 기준으로 본다. '
            '기울기는 유효 구간이 %.1f시간 이상일 때만 표시한다.' % analysis['min_hours'])
        if latency['outliers']:
            out('')
            reference = latency['outlier_reference_p99']
            out('Snapshot 최대 지연 상위 구간 (전체 p99 %s ms 대비):' % fmt(reference))
            out('')
            lines.extend(table(['Interval', 'Start s', 'Max ms', 'x run p99'], [
                (i['index'], fmt(i['start_s'], 0), fmt(value), fmt(value / reference) if reference else NA)
                for value, i in latency['outliers']]))
    out('')

    def memory_section(title, fields):
        out(title)
        out('')
        rows = []
        for row in analysis['memory']:
            if row['field'] not in fields:
                continue
            unit = row['unit']
            rows.append((row['name'], row['session'], row['n'],
                         fmt_metric(row.get('first'), unit), fmt_metric(row.get('last'), unit),
                         fmt_metric(row.get('delta'), unit, True), fmt_metric(row.get('min'), unit),
                         fmt_metric(row.get('max'), unit), fmt_metric(row.get('warmup_median'), unit),
                         fmt_metric(row.get('post_median'), unit),
                         fmt_metric(row.get('slope_h'), unit, True) if row['conclusive'] else NA,
                         fmt(row.get('r2'), 2),
                         'INCONCLUSIVE (%s)' % row['direction'] if row['status'] == 'INCONCLUSIVE' else row['status']))
        lines.extend(table(['Metric', 'JVM', 'Samples', 'First', 'Last', 'Last-first', 'Min', 'Max',
                            'Warmup median', 'Post-warmup median', 'Theil-Sen /h', 'OLS R²', 'Trend'], rows))

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
    out('')
    memory_section('## 6. Private Bytes / Working Set', {'private', 'working_set'})
    out('Private bytes는 프로세스 전용 커밋 메모리, Working set은 현재 물리 메모리에 있는 페이지로 OS가 회수할 수 있다.')
    out('')
    memory_section('## 7. CPU / 핸들 / 스레드 추세', {'handles', 'threads'})
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
    suspects = [r for r in analysis['memory'] if r['status'] in ('SUSTAINED GROWTH', 'GROWTH SLOWING')]
    if suspects:
        lines.extend(table(['Metric', 'JVM', 'Status', 'Slope /h', 'Late-half slope /h', 'Threshold /h',
                            'Early → late median', 'Conclusive'], [
            (r['name'], r['session'], r['status'], fmt_metric(r['slope_h'], r['unit'], True),
             fmt_metric(r['late_slope_h'], r['unit'], True), fmt_metric(r['threshold_h'], r['unit']),
             '%s → %s' % (fmt_metric(r['early'], r['unit']), fmt_metric(r['late'], r['unit'])),
             'yes') for r in suspects]))
    elif any(r['conclusive'] for r in analysis['memory']):
        out('워밍업 이후 충분히 관측된 지표 중 임계값을 넘는 지속 증가 없음.')
    evaluated = [r for r in analysis['memory'] if r['status'] not in (NA, 'INSUFFICIENT DATA')]
    short = [r for r in evaluated if r['status'] == 'INCONCLUSIVE']
    if not evaluated:
        out('')
        out('추세 판정 가능한 지표 없음: %s.' % NA)
    elif short:
        rising = ['%s (JVM %d)' % (r['name'], r['session']) for r in short
                  if r['direction'] in ('SUSTAINED GROWTH', 'GROWTH SLOWING')]
        out('')
        out('관측 구간이 짧아 장기 누수 여부는 판단할 수 없다 (INCONCLUSIVE, %s). 짧은 구간에서 증가한 지표: %s. '
            '시작 직후의 증가를 시간당 값으로 외삽하지 않는다.' % (short[0].get('reason'), ', '.join(rising) or '없음'))
    out('')

    out('## 9. 성능 저하 징후')
    out('')
    if not latency['available']:
        out('구간별 지연 데이터 %s. 성능 저하 추세를 판정할 수 없다.' % NA)
    else:
        degraded = [(k, v) for k, v in latency['ops'].items() if v['status'] == 'DEGRADING']
        if degraded:
            for operation, entry in degraded:
                out('- %s p95: %s → %s ms (x%s), slope %s ms/h' % (
                    operation, fmt(entry.get('early_p95')), fmt(entry.get('late_p95')), fmt(entry.get('ratio')),
                    slope_text(entry, analysis['min_hours'])))
        else:
            out('- 허용 변동(±%d%%)을 넘는 p95 지연 증가 없음.' % round(100 * analysis['tolerance']))
        throughput = latency['throughput'] or {}
        out('- 처리량: %s' % (status_text(throughput) if throughput else NA))
        if any(v['status'] == 'INCONCLUSIVE' for v in list(latency['ops'].values()) + [throughput]):
            out('- 유효 구간이 %.1f시간 미만인 항목은 INCONCLUSIVE로 표시하고 경고로 판정하지 않는다.' % analysis['min_hours'])
        insufficient = [k for k, v in latency['ops'].items() if v['status'] == 'INSUFFICIENT DATA']
        if insufficient:
            out('- 유효 구간 4개 미만으로 판정 불가: %s' % ', '.join(insufficient))
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
                    'nmt_committed', 'private', 'working_set', 'cpu_ms', 'handles', 'threads', 'gc_count', 'gc_time_ms']


def write_csv(model, directory):
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
    args = parser.parse_args(argv)
    try:
        report, source = load_report(args.input, recover=not args.no_recover)
    except SoakInputError as error:
        print('error: %s' % error, file=sys.stderr)
        return 2
    if source != args.input:
        print('warning: %s is unreadable; analyzing pending checkpoint %s' % (args.input, source), file=sys.stderr)
    model = normalize(report)
    analysis = analyze(model, args.warmup_seconds, args.min_trend_hours, args.min_interval_requests, args.tolerance)
    markdown = render(model, analysis, source)
    directory = os.path.dirname(os.path.abspath(args.output))
    os.makedirs(directory, exist_ok=True)
    with open(args.output, 'w', encoding='utf-8', newline='\n') as handle:
        handle.write(markdown)
    print('wrote %s' % args.output)
    if args.csv_dir:
        for path in write_csv(model, args.csv_dir):
            print('wrote %s' % path)
    return 0


if __name__ == '__main__':
    sys.exit(main())
