#!/usr/bin/python3
# SPDX-License-Identifier: GPL-3.0
"""Bound running capture sessions without stopping the robot workload."""
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess


def guard(root, session_limit_mb, cleanup, runtime):
    if not root.is_dir():
        return
    runtime.mkdir(parents=True, exist_ok=True)
    with (runtime / 'session-guard.lock').open('w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        subprocess.run([cleanup], check=True)
        sessions = sorted(p for p in root.glob('seven-*') if p.is_dir() and not p.is_symlink())
        if not sessions or session_limit_mb == 0:
            return
        session = sessions[-1]
        try:
            manifest = json.loads((session / 'manifest.json').read_text())
        except (OSError, ValueError):
            return
        if 'ended_at_unix' in manifest:
            return
        size_kb = int(subprocess.check_output(['du', '-sk', '--', str(session)], text=True).split()[0])
        if size_kb < session_limit_mb * 1024:
            return
        pid = int(subprocess.check_output(
            ['systemctl', 'show', 'usbcan-capture.service', '-p', 'MainPID', '--value'], text=True).strip() or '0')
        if pid <= 1:
            return
        marker = runtime / 'session-rotate-request'
        identity = f'{pid}:{session.name}'
        if marker.exists() and marker.read_text() == identity:
            return
        # Signal only the capture orchestrator, never its control group or CAN.
        os.kill(pid, signal.SIGUSR1)
        marker.write_text(identity)
        print(f'session-guard: rotate {session} at {size_kb} KiB; limit={session_limit_mb} MiB', flush=True)


if __name__ == '__main__':
    guard(Path(os.environ.get('SESSION_ROOT', '/home/robo/robopi-logs')),
          int(os.environ.get('SESSION_MAX_SIZE_MB', '1024')),
          '/opt/roboparty/bin/robopi-session-cleanup', Path('/run/usbcan'))
