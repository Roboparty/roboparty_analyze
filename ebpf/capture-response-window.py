#!/usr/bin/env python3
"""Observe an existing app; stop only our two tracer process groups on dump/timeout."""
import argparse
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("pid", type=int)
    parser.add_argument("rx_tid", type=int)
    parser.add_argument("tx_tid", type=int)
    parser.add_argument("can_irq_tid", type=int)
    parser.add_argument("usb_irq_tid", type=int)
    parser.add_argument("trace_file", type=Path, help="Empty CSV created by this app at startup")
    parser.add_argument("--iface", default="can0")
    parser.add_argument("--cpu", type=int, default=0)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--bpftrace", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 21600:
        parser.error("seconds must be 1..21600")
    if any(value <= 0 for value in (args.pid, args.rx_tid, args.tx_tid,
                                   args.can_irq_tid, args.usb_irq_tid)):
        parser.error("PID and TIDs must be positive")
    if not re.fullmatch(r"[A-Za-z0-9_.:-]+", args.iface):
        parser.error("invalid interface")
    for tid in (args.rx_tid, args.tx_tid):
        if not Path(f"/proc/{args.pid}/task/{tid}/stat").exists():
            parser.error("RX/TX must belong to the existing application PID")
    for tid in (args.can_irq_tid, args.usb_irq_tid):
        if not Path(f"/proc/{tid}/stat").exists():
            parser.error("IRQ TID no longer exists")
    if not args.trace_file.is_file() or args.trace_file.stat().st_size:
        parser.error("trace_file must be the app's existing, empty CSV")
    if not args.trace_file.name.startswith(f"motor-response-{args.pid}-"):
        parser.error("trace_file PID does not match")
    iface_path = Path("/sys/class/net") / args.iface
    if (iface_path / "type").read_text().strip() != "280":
        parser.error("interface is not CAN")
    ifindex = int((iface_path / "ifindex").read_text())
    observer_cpus = os.sched_getaffinity(0) - {args.cpu}
    if not observer_cpus:
        parser.error("no separate allowed CPU for observer userspace")
    os.sched_setaffinity(0, {max(observer_cpus)})
    os.nice(19)
    args.output.mkdir(parents=True, exist_ok=False)
    root = Path(__file__).resolve().parent
    env = dict(os.environ, BPFTRACE_MAX_MAP_KEYS="32768", BPFTRACE_MAP_KEYS_MAX="32768")
    jobs = [
        ("sched", [str(root / "trace-response-sched.bt"), args.cpu, args.can_irq_tid,
                   args.usb_irq_tid, args.rx_tid, args.tx_tid], "RESPONSE_SCHED_READY", "RESPONSE_SCHED_FINAL"),
        ("queue", [str(root / "trace-app-can-queue.bt"), args.pid, args.rx_tid,
                   ifindex, args.seconds + 90], "APP_CAN_QUEUE_READY", "APP_CAN_QUEUE_FINAL"),
    ]
    metadata = {"pid": args.pid, "rx_tid": args.rx_tid, "tx_tid": args.tx_tid,
                "can_irq_tid": args.can_irq_tid, "usb_irq_tid": args.usb_irq_tid,
                "cpu": args.cpu, "ifindex": ifindex, "trace_file": str(args.trace_file),
                "boot_id": Path("/proc/sys/kernel/random/boot_id").read_text().strip(),
                "monotonic_ns": time.monotonic_ns(), "realtime_ns": time.time_ns()}
    def probe_profile():
        for path in ("/sys/kernel/tracing/kprobe_profile", "/sys/kernel/debug/tracing/kprobe_profile"):
            try:
                return Path(path).read_text()
            except OSError:
                continue
        return "unavailable"
    metadata["kprobe_profile_before"] = probe_profile()
    for tid in (args.rx_tid, args.tx_tid, args.can_irq_tid, args.usb_irq_tid):
        metadata[f"tid_{tid}_stat"] = Path(f"/proc/{tid}/stat").read_text()
        metadata[f"tid_{tid}_status"] = Path(f"/proc/{tid}/status").read_text()
    children = []
    reason = "startup_failure"
    try:
        for name, params, ready, final in jobs:
            stream = (args.output / f"{name}.log").open("w")
            child = subprocess.Popen([args.bpftrace, "-B", "none", *map(str, params)],
                                     stdout=stream, stderr=subprocess.STDOUT,
                                     env=env, start_new_session=True)
            children.append((child, stream))
        startup = time.monotonic() + 60
        while True:
            if any(child.poll() is not None for child, _ in children):
                raise RuntimeError("Tracer exited during startup; inspect logs")
            if all(ready in (args.output / f"{name}.log").read_text(errors="replace")
                   for name, _, ready, _ in jobs):
                break
            if time.monotonic() >= startup:
                raise RuntimeError("Tracer startup timed out")
            time.sleep(0.1)
        print(f"RESPONSE_WINDOW_READY output={args.output}", flush=True)
        deadline = time.monotonic() + args.seconds
        reason = "timeout"
        while time.monotonic() < deadline:
            if args.trace_file.stat().st_size:
                reason = "application_dump"
                break
            if any(child.poll() is not None for child, _ in children):
                raise RuntimeError("Tracer exited early; inspect logs")
            if not Path(f"/proc/{args.pid}/task/{args.rx_tid}").exists():
                reason = "application_rx_exit"
                break
            time.sleep(0.02)
    except KeyboardInterrupt:
        reason = "observer_interrupted"
    finally:
        # Every PGID below was created here. Never signal the application PID.
        for child, _ in children:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
        for child, stream in children:
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()
            stream.close()
        metadata["reason"] = reason
        metadata["returncodes"] = [child.returncode for child, _ in children]
        metadata["end_monotonic_ns"] = time.monotonic_ns()
        metadata["kprobe_profile_after"] = probe_profile()
        (args.output / "metadata.json").write_text(json.dumps(metadata, indent=2))
    for name, _, _, final in jobs:
        text = (args.output / f"{name}.log").read_text(errors="replace")
        if final not in text or re.search(r"ERROR:|lost \d+ events|failed to attach|Map full|retcode: -", text, re.I):
            raise SystemExit(f"Incomplete {name} trace: {args.output}")
    if any(child.returncode != 0 for child, _ in children):
        raise SystemExit("Tracer failed; inspect logs")
    print(f"Saved: {args.output}; reason={reason}. Robot was not signalled.", flush=True)


if __name__ == "__main__":
    main()
