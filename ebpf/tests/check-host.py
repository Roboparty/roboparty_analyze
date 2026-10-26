#!/usr/bin/env python3
"""Exercise CAN timing/accounting on a local libc sleep, never on the board.

Requires root and bpftrace. Only probe attachment sites are substituted; the
timing, scheduler tracking and reporting logic are the production script.
"""
import ctypes
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


def worker():
    libc = ctypes.CDLL(None)
    # The controller releases the worker only once all probes are attached.
    sys.stdin.readline()
    for _ in range(30):
        libc.usleep(50000)


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--worker":
        worker()
        return
    if os.geteuid() != 0:
        raise SystemExit("Run with sudo; this test attaches local observation probes.")
    source = Path(__file__).resolve().parents[1] / "trace-can-irq.bt"
    iterations = "--iterations" in sys.argv
    libc_path = next(
        line.split()[-1] for line in Path("/proc/self/maps").read_text().splitlines()
        if re.search(r"/libc(?:-[0-9.]+)?\.so(?:\.6)?$", line.split()[-1])
    )
    program = source.read_text().replace(
        "kprobe:rkcanfd_handle_rx_int", f"uprobe:{libc_path}:usleep"
    ).replace(
        "kretprobe:rkcanfd_handle_rx_int", f"uretprobe:{libc_path}:usleep"
    )
    # Jammy's stripped 0.14 executable may lack BEGIN_trigger/END_trigger.
    # Trigger the same initialization/finalization bodies from this controller.
    program = program.replace("\nBEGIN\n", "\ntracepoint:syscalls:sys_enter_getpgid\n/pid == $5/\n")
    program = program.replace("\nEND\n", "\ntracepoint:syscalls:sys_enter_getsid\n/pid == $5/\n")
    if iterations:
        program += "\n" + source.with_name("trace-can-iterations.bt").read_text().replace(
            "kprobe:rkcanfd_handle_rx_int_one", f"uprobe:{libc_path}:nanosleep"
        )
    child = subprocess.Popen(
        [sys.executable, __file__, "--worker"], stdin=subprocess.PIPE, text=True
    )
    tracer = None
    # All temporary output belongs under the repository test/tmp directory.
    temp_root = Path(__file__).resolve().parents[3] / "test" / "tmp"
    temp_root.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryFile(mode="w+", dir=temp_root) as output:
            tracer = subprocess.Popen(
                ["bpftrace", "-B", "none", "-e", program,
                 str(child.pid), "2147483647", "10000", str(int(iterations)), str(os.getpid())],
                stdout=output, stderr=subprocess.STDOUT, text=True,
            )
            deadline = time.monotonic() + 20
            while time.monotonic() < deadline:
                os.getpgid(0)
                output.seek(0)
                text = output.read()
                if "CAN_IRQ_READY:" in text:
                    break
                if tracer.poll() is not None:
                    raise RuntimeError(text)
                time.sleep(0.1)
            else:
                raise RuntimeError("Timed out waiting for probe attachment")
            child.stdin.write("go\n")
            child.stdin.flush()
            child.wait(timeout=10)
            os.getsid(0)
            time.sleep(0.2)
            tracer.send_signal(signal.SIGINT)
            tracer.wait(timeout=10)
            output.seek(0)
            text = output.read()
            (temp_root / "ebpf-host-smoke.log").write_text(text)
            if tracer.returncode != 0 or "ERROR:" in text:
                raise RuntimeError(text)
            samples = re.findall(r"wall_us=(\d+) offcpu_us=(\d+)", text)
            assert samples, text
            assert any(int(wall) >= 40000 and int(off) >= 35000
                       for wall, off in samples), samples
            assert "CAN_IRQ_FINAL:" in text and "NO_CAN_SAMPLES:" not in text, text
            assert "@can_returns: 30" in text, text
            assert not re.search(r"@can_accounting_errors: [1-9]", text), text
            if iterations:
                assert "@can_iterations_max: 1" in text, text
            print(f"PASS: 30 paired 50ms sleep calls; off-CPU accounting, summary and iterations={iterations} verified")
    finally:
        for process in (tracer, child):
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == "__main__":
    main()
