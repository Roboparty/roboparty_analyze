"""Generate bounded BPF map rings; each event kind has a single CPU writer."""

KINDS = {
    1: "switch", 2: "wakeup", 3: "hard_entry", 4: "hard_exit",
    5: "soft_entry", 6: "soft_exit", 7: "ehci_entry", 8: "ehci_exit",
    9: "giveback_entry", 10: "giveback_exit", 11: "gs_entry", 12: "gs_exit",
    13: "rkcan_entry", 14: "rkcan_exit", 15: "fair_pick_entry",
    16: "fair_pick_exit", 17: "server_start", 18: "server_stop",
    19: "pi_priority", 20: "preempt_off", 21: "preempt_on",
    22: "irq_off", 23: "irq_on",
    24: "ipi_entry", 25: "ipi_exit",
}
ARM = 2147483600
DUMP = ARM - 1


def program(cpu, targets, controller, slots=8192, threshold_us=5000,
            post_ms=100, preemptirq=False, ipi=False):
    target = " || ".join(f"$pid == {tid}" for tid in targets)
    parts = [f'''
BEGIN {{ printf("CPU0_PROBES_BEGIN\\n"); }}
tracepoint:raw_syscalls:sys_enter
/pid == {controller} && args->id == 155/
{{
    $command = (uint64)args->args[0];
    if ($command == {ARM} && !@armed && !@trigger_ns) {{
        @armed = nsecs;
        printf("CPU0_ARMED ns=%llu\\n", @armed);
    }}
    if ($command == {DUMP} && !@trigger_ns) {{
        @trigger_reason = 2;
        @trigger_ns = nsecs;
        @freeze_at = @trigger_ns + {post_ms * 1000000};
    }}
}}
interval:s:1 {{
    if (!@attached) {{ @attached = nsecs; printf("CPU0_ATTACHED\\n"); }}
    if (@trigger_ns && nsecs >= @freeze_at && !@frozen) {{
        @frozen = nsecs;
        printf("CPU0_FROZEN ns=%llu\\n", @frozen);
    }}
}}
END {{ printf("CPU0_FINAL\\n"); }}
''']

    def record(kind, values):
        # Pre/post use different banks: recovery traffic cannot overwrite history.
        return f'''
        $phase = (uint64)(@trigger_ns != 0);
        $seq = (uint64)@seq[{kind}, $phase];
        @ring_{kind}[$phase, $seq % {slots}] =
            ($seq, $now, (uint64)cpu, (uint64)tid, {values});
        @seq[{kind}, $phase] = (uint64)($seq + 1);
'''

    def probe(name, kind, values="0, 0, 0, 0, 0, 0", before=""):
        parts.append(f'''
{name}
/cpu == {cpu} && !@frozen/
{{
    $now = nsecs;
    if (!@freeze_at || $now <= @freeze_at) {{
        {before}
        {record(kind, values)}
    }}
}}
''')

    # Raw sched_switch supplies task pointers and the unencoded prev_state.
    parts.append(f'''
rawtracepoint:sched_switch
/cpu == {cpu} && !@frozen/
{{
    $now = nsecs;
    if (!@freeze_at || $now <= @freeze_at) {{
        $prev = (struct task_struct *)arg1;
        $next = (struct task_struct *)arg2;
        $pid = $prev->pid;
        if ({target}) {{
            if (arg0 || arg3 == 0) {{
                if (!@ready[$pid]) {{ @ready[$pid] = $now; }}
            }} else {{ delete(@ready[$pid]); }}
        }}
        {record(1, '(uint64)$prev->pid, (uint64)$next->pid, (uint64)arg3, (uint64)$prev->prio, (uint64)$next->prio, (uint64)arg0')}
        $s = (uint64)$seq;
        @policy[$phase, $s % {slots}] = ($s, $now,
            (uint64)$prev->policy, (uint64)$next->policy,
            (uint64)$prev->rt_priority, (uint64)$next->rt_priority,
            (uint64)$prev->dl_server, (uint64)$next->dl_server,
            str($prev->comm), str($next->comm));
        $pid = $next->pid;
        if ({target}) {{
            $ready = @ready[$pid];
            if ($ready && @armed && $ready >= @armed && !@trigger_ns &&
                (int64)$now - (int64)$ready >= {threshold_us * 1000}) {{
                @trigger_reason = 1;
                @trigger_tid = $pid;
                @trigger_ready = $ready;
                @trigger_ns = $now;
                @freeze_at = @trigger_ns + {post_ms * 1000000};
            }}
            delete(@ready[$pid]);
        }}
    }}
}}
tracepoint:sched:sched_wakeup
/!@frozen/
{{
    $now = nsecs;
    $pid = args->pid;
    if ({target}) {{
        if (!@ready[$pid]) {{ @ready[$pid] = $now; }}
    }}
    if (cpu == {cpu} && (!@freeze_at || $now <= @freeze_at)) {{
        {record(2, '(uint64)args->pid, (uint64)args->prio, (uint64)args->target_cpu, 0, 0, 0')}
    }}
}}
tracepoint:sched:sched_migrate_task
/!@frozen/
{{
    $pid = args->pid;
    if ({target}) {{ @target_migrations = count(); }}
}}
''')
    probe("tracepoint:irq:irq_handler_entry", 3, "(uint64)args->irq, 0, 0, 0, 0, 0")
    probe("tracepoint:irq:irq_handler_exit", 4, "(uint64)args->irq, (uint64)args->ret, 0, 0, 0, 0")
    probe("tracepoint:irq:softirq_entry", 5, "(uint64)args->vec, 0, 0, 0, 0, 0")
    probe("tracepoint:irq:softirq_exit", 6, "(uint64)args->vec, 0, 0, 0, 0, 0")
    if ipi:
        probe("tracepoint:ipi:ipi_entry", 24, "str(args->reason), 0, 0, 0, 0, 0")
        probe("tracepoint:ipi:ipi_exit", 25, "str(args->reason), 0, 0, 0, 0, 0")
    for fn, kind in [("ehci_irq", 7), ("usb_giveback_urb_bh", 9),
                     ("gs_usb_receive_bulk_callback", 11), ("rkcanfd_irq", 13),
                     ("fair_server_pick_task", 15)]:
        probe(f"kprobe:{fn}", kind, "(uint64)arg0, 0, 0, 0, 0, 0")
        values = "0, 0, 0, 0, 0, 0"
        before = ""
        if kind == 15:
            before = "$selected = (struct task_struct *)retval; $selected_pid = (uint64)0; if ($selected) { $selected_pid = (uint64)$selected->pid; }"
            values = "$selected_pid, (uint64)retval, 0, 0, 0, 0"
        probe(f"kretprobe:{fn}", kind + 1, values, before)
    for fn, kind in [("dl_server_start", 17), ("dl_server_stop", 18)]:
        probe(f"kprobe:{fn}", kind, "(uint64)arg0, 0, 0, 0, 0, 0")
    probe("tracepoint:sched:sched_pi_setprio", 19,
          "(uint64)args->pid, (uint64)args->oldprio, (uint64)args->newprio, 0, 0, 0")
    if preemptirq:
        for event, kind in [("preempt_disable", 20), ("preempt_enable", 21),
                            ("irq_disable", 22), ("irq_enable", 23)]:
            # Raw arguments are full IPs; formatted events use signed _stext offsets.
            probe(f"rawtracepoint:{event}", kind,
                  "(uint64)arg0, (uint64)arg1, 0, 0, 0, 0")
    return "\n".join(parts)
