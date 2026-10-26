# RoboPi2 perf capture

Captures existing workloads only. Does not launch motion control, change its
affinity/priority, transmit CAN traffic, or stop existing BPF probes.

## Board commands

Run in a separate SSH terminal. The collector inherits the shell's allowed CPU
set and pins its child processes to the highest CPU in that set (currently CPU3).
Event recording still covers all CPUs. Kernel event collection has overhead on
the observed CPUs; pinning the reader does not eliminate this overhead.

```bash
# First pass: scheduler timeline, per-thread CPU, frequency and temperature.
sudo python3 /root/roboparty-perf-tools/capture.py sched 20

# Statistics only; 1-second averages cannot resolve millisecond stalls.
sudo python3 /root/roboparty-perf-tools/capture.py stats 20

# Separate pass: substitute the current inference process PID.
sudo python3 /root/roboparty-perf-tools/capture.py profile 20 --pid PID

# Once robot operation has stopped, substitute the printed OUTPUT directory.
sudo python3 /root/roboparty-perf-tools/capture.py analyze OUTPUT_DIRECTORY
```

Capture duration is limited to 2-60 seconds. Ctrl-C stops only observer process
groups created by this invocation. Results stay in `/home/robo/perf-results`.
Do not run both profiling modes simultaneously. Existing BPF probes can add
overhead; record which were active when comparing runs.

## Interpretation

- `sched-timehist.txt`: runnable-to-running delay versus actual runtime.
  The broader wait time also includes sleeping/blocking; it is not lock wait
  alone. Scheduler events do not identify a userspace mutex owner by themselves.
- `hotspots.txt`: sampled on-CPU function/callchain distribution. Frame-pointer
  unwinding may be incomplete in binaries compiled without frame pointers;
  absent stacks do not prove absent work. Symbols may need matching binaries
  and debug information. Software `cpu-clock` sampling is used at 49 Hz, not
  PMU cycles or an IPC measurement.
- `frequency.jsonl`: 1 Hz cpufreq-reported frequency and thermal readings, not
  cycle-accurate effective frequency or proof of no short throttling events.
- `before/after-system.json`: time anchors, boot identity, CPU/IRQ counters,
  effective IRQ affinities and real-time budget configuration.
- `metadata.json`, `record.stderr`, `events.txt`: check success and lost-event
  warnings before treating a timeline as complete. All-CPU tracepoints use a
  256-page buffer per CPU and can still lose events under load.

The privately extracted Ubuntu 6.8 perf executable is invoked directly because
the running kernel is a custom 6.18 build. Compatibility must be verified with
actual capture and decoding, not inferred from versions. `trace-cmd` is prepared
for later use; this script does not change the global ftrace tracer or buffers.
Idle-board smoke checks do not establish safe overhead during robot operation.

## Validation on 2026-10-22 CST

Board: RK3588S, `6.18.58-current-rockchip64`, PREEMPT_RT. Tools were downloaded
from Ubuntu package repositories and extracted privately into
`/root/roboparty-perf-tools/vendor`, without changing the installed analyze
packages. Existing apt dependencies are inconsistent: `robopi-analyze` requests
`roboparty-analyze (= 1.0.12-1)` while the installed version is `1.0.13-1`.

- perf reports version 6.8.12; trace-cmd reports 3.2.0.
- Three-second scheduler capture: 13,810 samples, 1.822 MB; timehist and event
  export succeeded. No loss warnings were found in the exported event stream.
- Three-second profile of a temporary Python test workload: 52 samples;
  function names and callchains decoded; report shows Total Lost Samples: 0.
- Thirty-second stats capture interrupted after two seconds: metadata records
  `interrupted`; no mpstat/pidstat/perf observer processes remained.
- Robot services stayed inactive; global ftrace tracer stayed `nop`. Existing
  BPF probes were left running. No operation-load overhead qualification yet.

Validation artifacts: `test/perf-toolchain-validation-20261022/smoke` in the
workspace, and `/root/roboparty-perf-tools/smoke` on the board.
