#!/usr/bin/env python3
"""CPU-local flight recorder. No CAN writes, workload launch, or affinity changes."""
import argparse
import ctypes
import json
import os
from pathlib import Path
import re
import shutil
import signal
import socket
import subprocess
import time

from cpu0_flight_program import ARM, DUMP, KINDS, program


def clock_pair():
    before = time.monotonic_ns()
    realtime = time.time_ns()
    after = time.monotonic_ns()
    return dict(monotonic_before_ns=before, realtime_ns=realtime,
                monotonic_after_ns=after)


def read(path):
    try:
        return Path(path).read_text()
    except OSError as exc:
        return f"UNAVAILABLE: {exc}"


def save(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n")


def without_lint(text):
    # 0.27 codegen emits these lint-only diagnostics; retain them for review.
    return re.sub(r'^.*WARNING: (?:Unnecessary cast: expression is already of type uint64|'
                      r'Return value discarded\.)\n[^\n]*\n[^\n]*\n', '', text, flags=re.M)


def diagnostics_ok(text):
    return not without_lint(text).strip()


class NativePreemptWindow:
    """Keep high-rate toggle events in a private tracefs ring, without BPF maps."""
    def __init__(self, trace, cpu, out):
        self.path = trace / 'instances' / f'rp_cpu0_{os.getpid()}'
        self.cpu, self.out = cpu, out
        self.path.mkdir()
        try:
            self.write('tracing_on', '0')
            self.write('trace_clock', 'mono')
            self.write('tracing_cpumask', f'{1 << cpu:x}')
            self.write(f'per_cpu/cpu{cpu}/buffer_size_kb', '32768')
            self.write('options/overwrite', '1')
            # Generic raw event output omits caller fields on this kernel.
            self.write('options/raw', '0')
            self.write('options/sym-offset', '1')
            self.write('options/sym-addr', '1')
            for event in ('preempt_disable', 'preempt_enable', 'irq_disable', 'irq_enable'):
                (out / f'{event}.format').write_text(read(self.path / f'events/preemptirq/{event}/format'))
                self.write(f'events/preemptirq/{event}/enable', '1')
            self.write('tracing_on', '1')
        except BaseException:
            self.close()
            raise

    def write(self, name, value):
        (self.path / name).write_text(value + '\n')

    def freeze(self):
        before = time.monotonic_ns()
        self.write('tracing_on', '0')
        return dict(before_ns=before, after_ns=time.monotonic_ns())

    def export(self):
        stats = read(self.path / f'per_cpu/cpu{self.cpu}/stats')
        (self.out / 'preemptirq-stats.txt').write_text(stats)
        with (self.path / 'trace').open() as source, (self.out / 'preemptirq.trace').open('w') as dest:
            shutil.copyfileobj(source, dest)
        return stats

    def close(self):
        if self.path.exists():
            self.write('tracing_on', '0')
            self.write('events/enable', '0')
            self.path.rmdir()


def native_summary(path, stats, trigger):
    names = ('preempt_disable', 'preempt_enable', 'irq_disable', 'irq_enable')
    counts = dict.fromkeys(names, 0)
    first = last = None
    malformed = 0
    pattern = re.compile(r'\[(\d+)\].*?\s(\d+)\.(\d+):\s+('
                         + '|'.join(names) + r'):\s*(.*)$')
    pending = {}
    pairing = {kind: dict(pairs=0, unpaired_off=0, unpaired_on=0, longest_us=0)
               for kind in ('preempt', 'irq')}
    for line in path.open():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        match = pattern.search(line)
        if not match:
            malformed += 1
            continue
        cpu, sec, frac, name, detail = match.groups()
        stamp = int(sec)*1000000000 + int(frac.ljust(9, '0'))
        first = stamp if first is None else first
        last = stamp
        counts[name] += 1
        kind = name.split('_')[0]
        if name.endswith('disable'):
            if kind in pending:
                pairing[kind]['unpaired_off'] += 1
            pending[kind] = stamp, detail
        elif kind not in pending:
            pairing[kind]['unpaired_on'] += 1
        else:
            start, caller = pending.pop(kind)
            duration = (stamp-start)/1000
            pairing[kind]['pairs'] += 1
            if duration > pairing[kind]['longest_us']:
                pairing[kind].update(longest_us=duration, start_ns=start,
                                     end_ns=stamp, caller=caller)
    for kind in pending:
        pairing[kind]['unpaired_off'] += 1
    stat_values = {key.strip(): int(value) for key, value in
                   re.findall(r'^([\w ]+):\s*(\d+)\s*$', stats, re.M)}
    valid = (all(counts.values()) and not malformed
             and stat_values.get('commit overrun') == 0
             and stat_values.get('dropped events') == 0)
    return dict(valid_export=bool(valid), event_counts=counts, first_ns=first,
                last_ns=last, timestamp_resolution_ns=1000, malformed=malformed,
                stats=stat_values, pairing=pairing,
                pairing_note='Observed toggle spans; correlate task switches and IRQ nesting before attribution',
                wait_start_covered=bool(first is not None and trigger.get('trigger_ready')
                                       and first <= trigger['trigger_ready'] <= last))


def discover(cpu):
    devices = [p for p in Path('/sys/bus/usb/devices').iterdir()
               if read(p / 'idVendor').strip() == '1209'
               and read(p / 'idProduct').strip() == '2323']
    if len(devices) != 1:
        raise RuntimeError('Expected exactly one HPM USB device')
    bus = int(read(devices[0] / 'busnum'))
    lines = read('/proc/interrupts').splitlines()
    usb = [l for l in lines if 'ehci' in l and l.split()[-1] in
           (f'usb{bus}', f'ehci_hcd:usb{bus}')]
    can = [l for l in lines if l.split() and l.split()[-1] == 'can_hipnuc']
    result = dict(usb_device=devices[0].name, usb_bus=bus, cpu=cpu, targets=[])
    for name, matches in [('usb', usb), ('imu', can)]:
        if len(matches) != 1:
            raise RuntimeError(f'Cannot identify unique {name} IRQ')
        irq = int(matches[0].split(':', 1)[0])
        tids = [int(p.parent.name) for p in Path('/proc').glob('[0-9]*/comm')
                if read(p).startswith(f'irq/{irq}-')]
        if len(tids) != 1 or os.sched_getaffinity(tids[0]) != {cpu}:
            raise RuntimeError(f'{name} IRQ must already be pinned to CPU{cpu}; no affinity is changed')
        result[name] = dict(irq=irq, tid=tids[0], line=matches[0])
        result['targets'].append(tids[0])
    return result


def snapshot(cpu):
    return dict(clock=clock_pair(), boot_id=read('/proc/sys/kernel/random/boot_id').strip(),
                kernel=os.uname().release, cmdline=read('/proc/cmdline'),
                interrupts=read('/proc/interrupts'), softirqs=read('/proc/softirqs'),
                tasks=subprocess.check_output(
                    ['ps', '-eLo', 'pid,tid,psr,cls,rtprio,pri,comm'], text=True),
                fair_runtime=read(f'/sys/kernel/debug/sched/fair_server/cpu{cpu}/runtime'),
                fair_period=read(f'/sys/kernel/debug/sched/fair_server/cpu{cpu}/period'),
                kprobe_profile=read('/sys/kernel/tracing/kprobe_profile'))


def decode(log, slots):
    maps, errors = {}, []
    final = False
    for line in without_lint(log).splitlines():
        if not line.strip():
            continue
        try:
            item = json.loads(line)
        except ValueError:
            errors.append('non_json_output: ' + line[:180])
            continue
        if item.get('type') == 'map':
            maps.update(item['data'])
        elif item.get('type') == 'printf':
            final |= 'CPU0_FINAL' in item['data']
        elif item.get('type') not in ('attached_probes',):
            errors.append('bpftrace_message: ' + line[:180])
    if not final:
        errors.append('missing_final')
    rows, coverage = [], []
    seqs = maps.get('@seq', {})
    for key, total in seqs.items():
        kind, phase = map(int, key.split(','))
        group = maps.get(f'@ring_{kind}', {})
        retained = []
        for slotkey, row in group.items():
            bank, slot = map(int, slotkey.split(','))
            if bank != phase:
                continue
            retained.append(row)
            if row[0] % slots != slot:
                errors.append(f'slot_mismatch:{kind}:{phase}:{slot}')
            rows.append(dict(kind=KINDS[kind], phase=phase, seq=row[0], ns=row[1],
                             cpu=row[2], tid=row[3], values=row[4:]))
        if sorted(r[0] for r in retained) != list(range(max(0, total-slots), total)):
            errors.append(f'sequence_gap:{kind}:{phase}')
        coverage.append(dict(kind=KINDS[kind], phase=phase, total=total,
                             retained=len(retained), overwritten=max(0, total-slots),
                             first_ns=min((r[1] for r in retained), default=None),
                             last_ns=max((r[1] for r in retained), default=None)))
    if not any(r['kind'] == 'switch' for r in rows):
        errors.append('no_switch_samples')
    policies = maps.get('@policy', {})
    for row in rows:
        if row['kind'] == 'switch':
            policy = policies.get(f"{row['phase']},{row['seq'] % slots}")
            if policy is None or policy[0] != row['seq']:
                errors.append('policy_sequence_gap')
            else:
                row['policy'] = policy[2:]
    if maps.get('@target_migrations', 0):
        errors.append('target_migrated')
    if '@attached' not in maps:
        errors.append('missing_attached_marker')
    rows.sort(key=lambda r: (r['ns'], r['kind']))
    trigger = {k[1:]: v for k, v in maps.items()
               if k in ('@trigger_ns', '@trigger_ready', '@trigger_tid',
                        '@trigger_reason', '@armed', '@freeze_at', '@frozen')}
    if trigger.get('trigger_reason') == 1 and not any(
            r['kind'] == 'switch' and r['ns'] == trigger.get('trigger_ns')
            and r['values'][1] == trigger.get('trigger_tid') for r in rows):
        errors.append('trigger_switch_mismatch')
    return dict(valid_export=not errors, errors=errors, coverage=coverage,
                trigger=trigger), rows


def intervals(rows, start, end):
    """Attribute switch-to-switch residency, not exclusive CPU execution time."""
    result = []
    switches = [r for r in rows if r['kind'] == 'switch']
    for left, right in zip(switches, switches[1:]):
        lo, hi = max(start, left['ns']), min(end, right['ns'])
        if hi > lo:
            result.append(dict(start_ns=lo, end_ns=hi, wall_us=(hi-lo)/1000,
                               tid=left['values'][1], effective_prio=left['values'][4],
                               policy=left.get('policy'),
                               note='includes nested IRQ/softirq; not exclusive CPU time'))
    return result


def client(args):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
        conn.settimeout(10)
        conn.connect(str(args.control))
        conn.sendall(args.action.encode() + b'\n')
        response = json.loads(conn.recv(65536))
    print(json.dumps(response))
    return 0 if response['ok'] else 1


def run(args):
    if os.geteuid() != 0:
        raise RuntimeError('Run as root')
    if os.uname().machine != 'aarch64':
        raise RuntimeError('Control syscall number is verified for aarch64 only')
    identity = discover(args.cpu)
    # Move only this observer; probes still execute on the observed CPU.
    allowed = os.sched_getaffinity(0) - {args.cpu}
    if not allowed:
        raise RuntimeError('No separate CPU available for the observer')
    os.sched_setaffinity(0, {max(allowed)})
    trace = Path('/sys/kernel/tracing')
    preemptirq = all((trace / f'events/preemptirq/{event}/format').exists()
                    for event in ('preempt_disable', 'preempt_enable', 'irq_disable', 'irq_enable'))
    ipi = all((trace / f'events/ipi/{event}/format').exists()
              for event in ('ipi_entry', 'ipi_exit'))
    available = read(trace / 'available_filter_functions')
    for symbol in ('ehci_irq', 'usb_giveback_urb_bh', 'gs_usb_receive_bulk_callback',
                   'rkcanfd_irq', 'fair_server_pick_task', 'dl_server_start', 'dl_server_stop'):
        if not re.search(r'^' + symbol + r'(?:\s|$)', available, re.M):
            raise RuntimeError(f'Missing required probe symbol: {symbol}')
    if not (trace / 'events/raw_syscalls/sys_enter/format').exists():
        raise RuntimeError('Missing raw syscall control tracepoint')
    args.output.mkdir(parents=True, exist_ok=True)
    out = args.output / (time.strftime('cpu0-flight-%Y%m%dT%H%M%SZ', time.gmtime()) + f'-{os.getpid()}')
    out.mkdir()
    (out / 'kallsyms.txt').write_text(read('/proc/kallsyms'))
    metadata = dict(identity=identity, preemptirq_available=preemptirq, ipi_available=ipi,
                    slots_per_kind_per_phase=args.slots, threshold_us=args.threshold_us,
                    post_ms=args.post_ms, before=snapshot(args.cpu),
                    schema='rows: seq, monotonic_ns, cpu, tid, six kind-specific values',
                    bpftrace=subprocess.check_output([args.bpftrace, '--version'], text=True).strip())
    save(out / 'metadata.json', metadata)
    metadata['preemptirq_provider'] = 'tracefs' if preemptirq else None
    code = program(args.cpu, identity['targets'], os.getpid(), args.slots,
                   args.threshold_us, args.post_ms, False, ipi)
    (out / 'program.bt').write_text(code)
    env = dict(os.environ, BPFTRACE_MAX_MAP_KEYS=str(2*args.slots), BPFTRACE_PERF_RB_PAGES='64')
    env.pop('BPFTRACE_MAP_KEYS_MAX', None)
    if not re.search(r'v0\.(?:2[7-9]|[3-9][0-9])\.', metadata['bpftrace']):
        raise RuntimeError('This recorder requires verified bpftrace >= 0.27 with codegen mode')
    with (out / 'compile.log').open('w') as compile_log:
        compiled = subprocess.run([args.bpftrace, '--mode', 'codegen', str(out / 'program.bt')],
                                  stdout=compile_log, stderr=subprocess.STDOUT,
                                  env=env, timeout=90)
    diagnostics = (out / 'compile.log').read_text()
    if compiled.returncode or not diagnostics_ok(diagnostics):
        raise RuntimeError(f'Compile diagnostics require review before attachment: {out / "compile.log"}')
    args.control.parent.mkdir(parents=True, exist_ok=True)
    if args.control.exists():
        raise RuntimeError('Control socket already exists; check existing observer')
    stop = []
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda signum, frame: stop.append(signum))
    child = None
    native = None
    state = 'starting'
    trigger_seen = False
    timeout_dump = None
    started = time.monotonic()
    logpath = out / 'trace.jsonl'
    # A socket is created exclusively. Cleanup removes only this instance's socket.
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server, logpath.open('w') as stream, \
            (out / 'stderr.log').open('w') as errstream:
        server.bind(str(args.control))
        os.chmod(args.control, 0o600)
        server.listen(2)
        server.settimeout(.1)
        try:
            if preemptirq:
                native = NativePreemptWindow(trace, args.cpu, out)
            child = subprocess.Popen([args.bpftrace, '-f', 'json', '-B', 'line',
                                      str(out / 'program.bt')], stdout=stream,
                                     stderr=errstream, env=env, start_new_session=True)
            while not stop:
                if state in ('starting', 'ready', 'armed'):
                    text = logpath.read_text(errors='replace')
                    if child.poll() is not None:
                        raise RuntimeError(f'Unexpected tracer exit; see {logpath}')
                    if state == 'starting' and 'CPU0_ATTACHED' in text:
                        state = 'ready'
                        print(f'CPU0_TRACE_READY output={out} preemptirq={preemptirq}', flush=True)
                    if state == 'starting' and time.monotonic()-started > 90:
                        raise RuntimeError(f'Probe startup timeout; see {logpath}')
                    if 'CPU0_FROZEN' in text:
                        state = 'exporting'
                        trigger_seen = True
                        break
                    if not diagnostics_ok((out / 'stderr.log').read_text(errors='replace')):
                        raise RuntimeError(f'Probe diagnostic failure; see {logpath}')
                if time.monotonic()-started >= args.seconds and timeout_dump is None:
                    ctypes.CDLL(None).getpgid(DUMP)
                    timeout_dump = time.monotonic()
                if timeout_dump is not None and time.monotonic()-timeout_dump > 5:
                    raise RuntimeError('Timed out waiting for freeze marker')
                try:
                    conn, _ = server.accept()
                except socket.timeout:
                    continue
                with conn:
                    conn.settimeout(1)
                    action = conn.recv(64).decode().strip()
                    ok = state in ('ready', 'armed')
                    if action == 'arm' and state == 'ready':
                        # This invalid getpgid is observed only for our PID.
                        ctypes.CDLL(None).getpgid(ARM)
                        state = 'armed'
                    elif action == 'dump' and state in ('ready', 'armed'):
                        ctypes.CDLL(None).getpgid(DUMP)
                    elif action not in ('status', 'arm', 'dump'):
                        ok = False
                    conn.sendall(json.dumps(dict(ok=ok, state=state, output=str(out),
                                                preemptirq_available=preemptirq)).encode())
        finally:
            if native is not None:
                metadata['preemptirq_freeze'] = native.freeze()
            if child is not None and child.poll() is None:
                if not trigger_seen:
                    ctypes.CDLL(None).getpgid(DUMP)
                    time.sleep(args.post_ms / 1000 + 1.1)
                metadata['kprobe_profile_before_detach'] = read(trace / 'kprobe_profile')
                child.send_signal(signal.SIGINT)
                try:
                    child.wait(timeout=60)
                except subprocess.TimeoutExpired:
                    child.kill()
                    child.wait()
            stream.flush()
            errstream.flush()
            args.control.unlink(missing_ok=True)
            if native is not None:
                try:
                    metadata['preemptirq_stats'] = native.export()
                finally:
                    native.close()
            metadata['after'] = snapshot(args.cpu)
            metadata['exit_code'] = child.returncode if child is not None else None
            save(out / 'metadata.json', metadata)
            summary, rows = decode(logpath.read_text(errors='replace'), args.slots)
            summary['preemptirq_available'] = preemptirq
            summary['ipi_available'] = ipi
            summary['kretprobe_missed_verified'] = False
            summary['trigger_frozen'] = trigger_seen
            if not diagnostics_ok((out / 'stderr.log').read_text(errors='replace')):
                summary['errors'].append('probe_diagnostics')
                summary['valid_export'] = False
            if metadata['exit_code'] != 0:
                summary['errors'].append('tracer_exit_nonzero')
                summary['valid_export'] = False
            trig = summary['trigger']
            if preemptirq:
                summary['preemptirq'] = native_summary(
                    out / 'preemptirq.trace', metadata.get('preemptirq_stats', ''), trig)
                if not summary['preemptirq']['valid_export']:
                    summary['errors'].append('preemptirq_export_incomplete')
                    summary['valid_export'] = False
            if trig.get('trigger_ready'):
                summary['residency_during_wait'] = intervals(rows, trig['trigger_ready'], trig['trigger_ns'])
                switch_pre = next((c for c in summary['coverage']
                                   if c['kind'] == 'switch' and c['phase'] == 0), None)
                summary['wait_start_covered'] = bool(switch_pre and switch_pre['first_ns'] <= trig['trigger_ready'])
            with (out / 'events.jsonl').open('w') as dest:
                for row in rows:
                    dest.write(json.dumps(row) + '\n')
            save(out / 'summary.json', summary)
            print(f'CPU0_TRACE_SAVED output={out} valid_export={summary["valid_export"]}', flush=True)
    if not summary['valid_export']:
        return 1
    # Preserve the first captured fault. Stay active so workload monitoring can continue.
    if trigger_seen and not stop:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
            server.bind(str(args.control))
            os.chmod(args.control, 0o600)
            server.listen(2)
            server.settimeout(.5)
            try:
                while not stop and time.monotonic()-started < args.seconds:
                    try:
                        conn, _ = server.accept()
                    except socket.timeout:
                        continue
                    with conn:
                        conn.settimeout(1)
                        action = conn.recv(64).decode().strip()
                        conn.sendall(json.dumps(dict(ok=action in ('status', 'dump'),
                            state='captured', output=str(out), preemptirq_available=preemptirq)).encode())
            finally:
                args.control.unlink(missing_ok=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('run', 'status', 'arm', 'dump'))
    parser.add_argument('--control', type=Path, default=Path('/run/roboparty-cpu0-trace/control.sock'))
    parser.add_argument('--output', type=Path, default=Path('/home/robo/ebpf/results'))
    parser.add_argument('--bpftrace', default=os.environ.get('BPFTRACE_BIN') or
                        ('/root/ebpf/bin/bpftrace' if Path('/root/ebpf/bin/bpftrace').is_file()
                         else shutil.which('bpftrace') or 'bpftrace'))
    parser.add_argument('--cpu', type=int, default=0)
    parser.add_argument('--slots', type=int, default=8192)
    parser.add_argument('--threshold-us', type=int, default=5000)
    parser.add_argument('--post-ms', type=int, default=100)
    parser.add_argument('--seconds', type=int, default=18000)
    args = parser.parse_args()
    if args.slots not in (1024, 4096, 8192) or not 1 <= args.threshold_us <= 1000000:
        parser.error('slots must be 1024/4096/8192; threshold must be 1..1000000 us')
    if not 0 <= args.post_ms <= 1000 or not 1 <= args.seconds <= 21600 or args.cpu < 0:
        parser.error('Invalid post window, duration or CPU')
    try:
        return run(args) if args.action == 'run' else client(args)
    except (OSError, RuntimeError, ValueError) as exc:
        print(f'CPU0_TRACE_ERROR: {exc}', flush=True)
        return 1


if __name__ == '__main__':
    raise SystemExit(main())
