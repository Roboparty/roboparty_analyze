#!/usr/bin/env python3
"""Bounded perf capture; never launch or signal the robot application."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time


BASE = Path(__file__).resolve().parent
VENDOR = BASE / "vendor"
ENV = dict(os.environ)
ENV["LD_LIBRARY_PATH"] = str(VENDOR / "usr/lib/aarch64-linux-gnu") + (
    ":" + ENV["LD_LIBRARY_PATH"] if ENV.get("LD_LIBRARY_PATH") else ""
)


def perf_binary():
    matches = sorted(VENDOR.glob("usr/lib/linux-tools-*/perf"))
    if matches:
        return str(matches[-1])
    binary = shutil.which("perf")
    if not binary:
        raise SystemExit("perf is unavailable")
    return binary


def save_command(directory, name, command):
    with (directory / name).open("w") as stream:
        return subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                              env=ENV, check=False).returncode


def snapshot(directory, phase):
    save_command(directory, phase + "-threads.txt",
                 ["ps", "-eLo", "pid,tid,psr,cls,rtprio,pri,ni,pcpu,comm"])
    data = {"realtime_ns": time.time_ns(), "monotonic_ns": time.monotonic_ns(),
            "collector_affinity": sorted(os.sched_getaffinity(0))}
    paths = [Path("/proc") / item for item in (
        "cmdline", "interrupts", "softirqs", "stat", "schedstat",
        "sys/kernel/random/boot_id", "sys/kernel/sched_rt_runtime_us",
        "sys/kernel/sched_rt_period_us")]
    paths += list(Path("/proc/irq").glob("*/effective_affinity_list"))
    paths += list(Path("/sys/devices/system/cpu/cpufreq").glob("policy*/*freq"))
    for path in paths:
        try:
            data[str(path)] = path.read_text()
        except OSError:
            pass
    (directory / (phase + "-system.json")).write_text(json.dumps(data, indent=2))


def frequency_sample():
    result = {"realtime_ns": time.time_ns(), "monotonic_ns": time.monotonic_ns()}
    for pattern in ("/sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq",
                    "/sys/class/thermal/thermal_zone*/temp"):
        for path in Path("/").glob(pattern.lstrip("/")):
            try:
                result[str(path)] = int(path.read_text())
            except (OSError, ValueError):
                pass
    return result


def analyze(args):
    directory = Path(args.directory).resolve()
    meta = json.loads((directory / "metadata.json").read_text())
    perf = perf_binary()
    source = str(directory / "perf.data")
    if meta["mode"] == "sched":
        command = [perf, "sched", "timehist", "-i", source]
        name = "sched-timehist.txt"
    elif meta["mode"] == "profile":
        command = [perf, "report", "--stdio", "--no-children", "-i", source]
        name = "hotspots.txt"
    else:
        print("Stats only: read mpstat.txt, pidstat.txt and frequency.jsonl")
        return
    status = save_command(directory, name, command)
    # Keep perf's loss records and warnings in the exported event stream.
    script_status = save_command(directory, "events.txt",
                                 [perf, "script", "--show-lost-events", "-i", source])
    print(f"Analysis: {directory / name}; events and loss warnings: events.txt")
    if status or script_status:
        raise SystemExit("Analysis failed; inspect the generated files")
    print("Check record.stderr and events.txt for LOST/lost warnings before interpreting gaps.")


def capture(args):
    if os.geteuid() != 0:
        raise SystemExit("Run capture as root")
    if not 2 <= args.seconds <= 60:
        raise SystemExit("Duration must be between 2 and 60 seconds")
    if args.mode == "profile" and (not args.pid or not Path(f"/proc/{args.pid}").exists()):
        raise SystemExit("profile requires --pid with an existing process ID")
    for tool in ("mpstat", "pidstat", "taskset"):
        if not shutil.which(tool):
            raise SystemExit(f"Missing tool: {tool}")
    lock = open("/run/roboparty-perf-capture.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit("Another capture from this toolkit is running")
    collector_cpu = max(os.sched_getaffinity(0))
    prefix = ["taskset", "-c", str(collector_cpu)]
    root = Path(args.output)
    root.mkdir(parents=True, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    directory = root / f"{stamp}-{args.mode}-{os.getpid()}"
    directory.mkdir()
    if shutil.disk_usage(directory).free < 1024 ** 3:
        raise SystemExit("Need at least 1 GiB free on output filesystem")
    meta = {"mode": args.mode, "seconds": args.seconds, "pid": args.pid,
            "collector_cpu": collector_cpu, "status": "preparing",
            "uname": list(os.uname()), "start_realtime_ns": time.time_ns()}
    children = []
    streams = []
    interrupted = False

    def stop_requested(signum, frame):
        nonlocal interrupted
        interrupted = True

    def launch(name, command):
        stream = (directory / name).open("w")
        streams.append(stream)
        process = subprocess.Popen(prefix + command, stdout=stream,
                                   stderr=subprocess.STDOUT, env=ENV, start_new_session=True)
        children.append(process)
        return process

    def stop_children():
        # Only process groups created by this invocation are signalled.
        for process in children:
            if process.poll() is None:
                try:
                    os.killpg(process.pid, signal.SIGINT)
                except ProcessLookupError:
                    pass
        for process in children:
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait()

    snapshot(directory, "before")
    signal.signal(signal.SIGINT, stop_requested)
    signal.signal(signal.SIGTERM, stop_requested)
    recorder = None
    try:
        if args.mode != "stats":
            command = [perf_binary(), "record", "--clockid", "mono", "-m", "256",
                       "-o", str(directory / "perf.data")]
            if args.mode == "sched":
                command += ["-a"]
                for event in ("sched_switch", "sched_wakeup", "sched_wakeup_new",
                              "sched_migrate_task"):
                    if not Path(f"/sys/kernel/tracing/events/sched/{event}/id").exists():
                        raise RuntimeError(f"Missing tracepoint: {event}")
                    command += ["-e", "sched:" + event]
            else:
                command += ["-p", str(args.pid), "-e", "cpu-clock", "-F", "49",
                            "--call-graph", "fp"]
            command += ["--", "sleep", str(args.seconds)]
            meta["record_command"] = command
            recorder = launch("record.stderr", command)
        launch("mpstat.txt", ["mpstat", "-P", "ALL", "1", str(args.seconds)])
        launch("pidstat.txt", ["pidstat", "-t", "-u", "-w", "-p",
                               str(args.pid) if args.pid else "ALL", "1", str(args.seconds)])
        meta["status"] = "recording"
        print(f"OUTPUT={directory}", flush=True)
        print("Recording observers only; Ctrl-C stops this capture. Robot is untouched.", flush=True)
        start = time.monotonic()
        next_sample = start
        with (directory / "frequency.jsonl").open("w") as frequency:
            while not interrupted and time.monotonic() - start < args.seconds:
                if recorder is not None and recorder.poll() is not None:
                    if recorder.returncode != 0:
                        raise RuntimeError("perf exited early; inspect record.stderr")
                    break
                if time.monotonic() >= next_sample:
                    frequency.write(json.dumps(frequency_sample()) + "\n")
                    frequency.flush()
                    next_sample += 1
                time.sleep(0.1)
        meta["status"] = "interrupted" if interrupted else "finished"
    except BaseException as exc:
        meta["status"] = "failed"
        meta["error"] = str(exc)
        raise
    finally:
        stop_children()
        for stream in streams:
            stream.close()
        meta["end_realtime_ns"] = time.time_ns()
        meta["child_returncodes"] = [p.returncode for p in children]
        if recorder is not None and recorder.returncode not in (0, -signal.SIGINT, 130):
            meta["status"] = "failed"
        snapshot(directory, "after")
        (directory / "metadata.json").write_text(json.dumps(meta, indent=2))
    if meta["status"] == "failed":
        raise SystemExit(f"Capture failed: {directory}")
    print(f"Saved: {directory}")
    print(f"After stopping robot, analyze with: python3 {BASE / 'capture.py'} analyze {directory}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="mode", required=True)
    for mode in ("stats", "sched", "profile"):
        command = sub.add_parser(mode)
        command.add_argument("seconds", type=int, nargs="?", default=20)
        command.add_argument("--pid", type=int)
        command.add_argument("--output", default="/home/robo/perf-results")
    command = sub.add_parser("analyze")
    command.add_argument("directory")
    args = parser.parse_args()
    analyze(args) if args.mode == "analyze" else capture(args)


if __name__ == "__main__":
    main()
