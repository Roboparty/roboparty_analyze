#!/usr/bin/env python3
"""Offline export-integrity and attribution tests; no probe attachment."""
import importlib.util
import json
import io
from pathlib import Path
from types import SimpleNamespace
import unittest

spec = importlib.util.spec_from_file_location('flight', Path(__file__).with_name('cpu0-flight.py'))
flight = importlib.util.module_from_spec(spec)
spec.loader.exec_module(flight)


def log_for(rows, total, policy=True):
    maps = {'@attached': 1, '@seq': {'1,0': total}, '@ring_1': rows,
            '@policy': {k: [r[0], r[1], 0, 1, 0, 50, 0, 0, 'prev', 'irq']
                        for k, r in rows.items()} if policy else {}}
    return '\n'.join([json.dumps(dict(type='map', data=maps)),
                      json.dumps(dict(type='printf', data='CPU0_FINAL\n'))])


class ExportTests(unittest.TestCase):
    def test_native_window_parses_microseconds_and_caller(self):
        log = ('# tracer: nop\n'
               ' task-5 [000] d... 12.000001: preempt_disable: caller=foo parent=bar\n'
               ' task-5 [000] d... 12.000010: irq_disable: caller=irqfoo parent=bar\n'
               ' task-5 [000] d... 12.000015: irq_enable: caller=irqbar parent=bar\n'
               ' task-5 [000] d... 12.000021: preempt_enable: caller=baz parent=bar\n')
        path = SimpleNamespace(open=lambda: io.StringIO(log))
        stats = 'entries: 4\noverrun: 200\ncommit overrun: 0\ndropped events: 0\n'
        result = flight.native_summary(path, stats, {'trigger_ready': 12000002000})
        self.assertTrue(result['valid_export'])
        self.assertTrue(result['wait_start_covered'])
        self.assertEqual(result['pairing']['preempt']['longest_us'], 20)
        self.assertEqual(result['pairing']['irq']['longest_us'], 5)
        self.assertFalse(flight.native_summary(path, stats.replace('dropped events: 0',
                                                                 'dropped events: 1'), {})['valid_export'])

    def test_wrap_is_valid_when_contiguous(self):
        log = log_for({'0,0': [2, 300, 0, 4, 4, 5, 0, 120, 49, 1],
                       '0,1': [3, 400, 0, 5, 5, 6, 0, 49, 120, 1]}, 4)
        result, rows = flight.decode(log, 2)
        self.assertTrue(result['valid_export'])
        self.assertEqual(result['coverage'][0]['overwritten'], 2)
        self.assertEqual([r['seq'] for r in rows], [2, 3])

    def test_missing_sequence_rejected(self):
        result, _ = flight.decode(log_for({'0,0': [2, 300, 0, 4, 4, 5, 0, 120, 49, 1]}, 4), 2)
        self.assertFalse(result['valid_export'])

    def test_missing_policy_rejected(self):
        result, _ = flight.decode(log_for({'0,0': [0, 300, 0, 4, 4, 5, 0, 120, 49, 1]}, 1, False), 2)
        self.assertIn('policy_sequence_gap', result['errors'])

    def test_warning_and_missing_final_rejected(self):
        result, _ = flight.decode('WARNING: map full\n', 2)
        self.assertFalse(result['valid_export'])
        self.assertIn('missing_final', result['errors'])

    def test_known_compiler_lint_preserves_runtime_warnings(self):
        lint = 'p.bt:1: WARNING: Return value discarded.\n delete(@x);\n ~~~~~~~~~~\n'
        log = log_for({'0,0': [0, 300, 0, 4, 4, 5, 0, 120, 49, 1]}, 1)
        self.assertTrue(flight.decode(lint + log, 2)[0]['valid_export'])
        self.assertFalse(flight.decode(lint + 'WARNING: map full\n' + log, 2)[0]['valid_export'])

    def test_trigger_must_match_switch_timestamp(self):
        log = log_for({'0,0': [0, 300, 0, 4, 4, 5, 0, 120, 49, 1]}, 1)
        for stamp, valid in [(300, True), (301, False)]:
            marker = json.dumps(dict(type='map', data={
                '@trigger_reason': 1, '@trigger_ns': stamp, '@trigger_tid': 5}))
            self.assertEqual(flight.decode(log + '\n' + marker, 2)[0]['valid_export'], valid)

    def test_residency_clips_to_wait_and_excludes_unknown_tail(self):
        rows = [dict(kind='switch', ns=100, values=[1, 2, 0, 120, 49, 1]),
                dict(kind='switch', ns=200, values=[2, 3, 0, 49, 120, 0]),
                dict(kind='switch', ns=400, values=[3, 4, 0, 120, 49, 1])]
        result = flight.intervals(rows, 150, 300)
        self.assertEqual([(r['tid'], r['start_ns'], r['end_ns']) for r in result],
                         [(2, 150, 200), (3, 200, 300)])

    def test_separate_banks_and_preemption_events(self):
        code = flight.program(0, [12, 13], 100, preemptirq=True, ipi=True)
        self.assertIn('@ring_1[$phase,', code)
        self.assertIn('rawtracepoint:irq_disable', code)
        self.assertNotIn('args->caller', code)
        self.assertIn('$next->dl_server', code)
        self.assertIn('kretprobe:fair_server_pick_task', code)
        self.assertIn('tracepoint:ipi:ipi_entry', code)
        self.assertIn('@trigger_ns = $now;', code)
        self.assertIn('($seq, $now,', code)


if __name__ == '__main__':
    unittest.main()
