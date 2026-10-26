#!/usr/bin/env python3
"""Exercise the wrapper with fake sysfs, sudo, observer and WBC; no hardware."""
import json
import gzip
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def main():
    if os.geteuid() == 0:
        raise SystemExit('Run this test as a non-root user')
    source = Path(__file__).resolve().parents[1] / 'run-wbc-test.sh'
    temporary = source.parents[2] / 'test/tmp'
    temporary.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='wbc-wrapper-', dir=temporary) as directory:
        root = Path(directory)
        binary = root / 'bin'
        binary.mkdir()
        sysfs = root / 'sys'
        for name, value in {
            'kernel/realtime': '1', 'kernel/btf/vmlinux': 'fixture',
            'bus/usb/devices/3-1/idVendor': '1209',
            'bus/usb/devices/3-1/idProduct': '2323',
            'bus/usb/devices/3-1/busnum': '3',
            'bus/usb/devices/3-1/devnum': '10',
        }.items():
            target = sysfs / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(value)
        driver = sysfs / 'class/net/can_hipnuc/device/driver'
        driver.parent.mkdir(parents=True)
        target = sysfs / 'drivers/rockchip_canfd'
        target.mkdir(parents=True)
        driver.symlink_to(target)
        interrupts = root / 'interrupts'
        interrupts.write_text(' 77: 10 0 GICv3 1 Level ehci_hcd:usb3\n 91: 10 0 GICv3 2 Level can_hipnuc\n')
        script = root / 'run-wbc-test.sh'
        script.write_text(source.read_text().replace('/sys/', str(sysfs) + '/')
                          .replace('/proc/interrupts', str(interrupts))
                          .replace('/boot/config-', str(root / 'boot/config-'))
                          .replace('/proc/config.gz', str(root / 'config.gz')))
        workspace = root / 'wbc'
        (workspace / 'tools').mkdir(parents=True)
        (workspace / 'tools/start_rp1_teleop.sh').write_text(
            '#!/bin/bash\nprintf "%s\\n" "$@" > "$TEST_LAUNCH_LOG"\n'
            'printf "WBC MOCK STARTED\\n"\n')
        observer = root / 'run-link-stall.sh'
        observer.write_text('''#!/bin/bash
set -eu
if [[ ${TEST_MODE:-} == fail ]]; then exit 7; fi
trap 'printf stopped > "$TEST_STOP_LOG"; exit 0' TERM
mkdir -p "$OUTPUT_DIR"
printf '{"output":"%s","realtime_ns":1}\n' "$OUTPUT_DIR" > "$READY_FILE"
for ((i=0;i<30;i++)); do sleep 0.1; done
''')
        commands = {
            'sudo': '#!/bin/bash\n[[ $1 == -n ]] || exit 90\nshift\nexec "$@"\n',
            'screen': '#!/bin/bash\nexit 1\n',
            'bpftrace': '#!/bin/bash\nexit 0\n',
            'ethtool': '#!/bin/bash\nexit 0\n',
            'ip': '#!/bin/bash\nexit 0\n',
        }
        for name, content in commands.items():
            target = binary / name
            target.write_text(content)
            target.chmod(0o755)
        env = dict(os.environ, PATH=str(binary) + ':' + os.environ['PATH'],
                   TEST_LAUNCH_LOG=str(root / 'launch.args'), TEST_STOP_LOG=str(root / 'stopped'))
        command = ['bash', str(script), '--workspace', str(workspace),
                   '--output', str(root / 'results'), '--seconds', '10']
        result = subprocess.run(command + ['--check'], env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stdout + result.stderr
        assert 'CAN IRQ: 91' in result.stdout and 'USB IRQ: 77' in result.stdout
        assert not (root / 'results').exists() and not (root / 'launch.args').exists()
        (sysfs / 'kernel/realtime').unlink()
        boot_config = root / 'boot' / ('config-' + os.uname().release)
        boot_config.parent.mkdir()
        boot_config.write_text('CONFIG_PREEMPT_RT=y\n')
        result = subprocess.run(command + ['--check'], env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stdout + result.stderr
        boot_config.unlink()
        with gzip.open(root / 'config.gz', 'wt') as stream:
            stream.write('CONFIG_PREEMPT_RT=y\n')
        result = subprocess.run(command + ['--check'], env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode == 0, result.stdout + result.stderr
        (root / 'config.gz').unlink()
        result = subprocess.run(command + ['--check'], env=env, capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and 'Requires PREEMPT_RT' in result.stderr
        boot_config.write_text('CONFIG_PREEMPT_RT=y\n')
        result = subprocess.run(command + ['--', '--no-ego', '--capture-output', 'a b'],
                                env=env, capture_output=True, text=True, timeout=15)
        assert result.returncode == 0, result.stdout + result.stderr
        assert (root / 'launch.args').read_text().splitlines() == ['--no-ego', '--capture-output', 'a b']
        runs = list((root / 'results').glob('wbc-test-*'))
        before = json.loads((runs[0] / 'before.json').read_text())
        assert before['uid'] == os.getuid() and before['sha256']
        assert 'WBC MOCK STARTED' in (runs[0] / 'wbc-launch.log').read_text()
        (root / 'launch.args').unlink()
        result = subprocess.run(command, env={**env, 'TEST_MODE': 'fail'},
                                capture_output=True, text=True, timeout=10)
        assert result.returncode != 0 and not (root / 'launch.args').exists(), result
        process = subprocess.Popen(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        deadline = time.monotonic() + 10
        while not (root / 'launch.args').exists() and time.monotonic() < deadline:
            if process.poll() is not None:
                raise AssertionError(process.communicate())
            time.sleep(0.05)
        assert (root / 'launch.args').exists()
        process.send_signal(signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        assert process.returncode == 143, stdout + stderr
        assert (root / 'stopped').exists(), stdout + stderr
        assert 'background robot components may still be running' in stderr
    print('PASS: RT sysfs/config fallbacks, read-only check, auto IRQ discovery, argument forwarding, hashes, failed readiness gate and observer-only cleanup')


if __name__ == '__main__':
    main()
