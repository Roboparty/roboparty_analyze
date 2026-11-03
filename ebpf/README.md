# CAN / USB 停顿观测

## CPU0 故障窗口记录器（2026-10-23）

`cpu0-flight.py run` 自动识别当前 HPM EHCI 和 can_hipnuc IRQ 线程，要求两者已固定到被观察 CPU；不修改 IRQ 或业务亲和性，不发送 CAN。用户态采集管理进程放到另一个允许核，内核探针仍在事件发生的 CPU 执行。需要 aarch64、运行内核 BTF 和 bpftrace 0.27；系统 0.20 不支持本程序使用的 BTF 类型。先用 `--mode codegen` 检查，再挂载，不能用 `-d` 当作只编译。

`rp-cpu0-trace.service` 启动后保持未布防，`cpu0-flight.py arm` 才启用 IRQ 就绪等待阈值触发（默认 5000 us）。BPF 调度/IRQ 记录的阈值触发在内核探针执行，不依赖用户态发现故障；触发时锁定此前环形记录，并把随后 100 ms 写入另一组有界槽位。每类事件、每阶段默认 8192 条，容量不等于固定秒数。只能解释各类记录实际覆盖的交集。

采集内容：CPU0 全部 sched_switch、CPU0 发出的 wakeup、两路目标 IRQ 的跨 CPU 唤醒起点、实际调度策略/RT 优先级/有效优先级、task 的 dl_server 指针、硬 IRQ handler/softirq 入口退出、可用时的 IPI 入口退出、EHCI/USB BH/gs_usb/rkcanfd 函数入口退出、fair_server 选择任务及 dl_server start/stop、PI 优先级变化。硬 IRQ handler 边界不包含全部架构中断进出序言/尾声，不覆盖 NMI 或固件执行。`policy` 不等于有效调度优先级；fair_server_pick_task 选中任务也不单独证明它已运行，要与紧邻的 sched_switch 对照。

命令：

```bash
sudo systemctl start rp-cpu0-trace
sudo python3 /opt/roboparty/lib/roboparty-analyze/ebpf/cpu0-flight.py status
sudo python3 /opt/roboparty/lib/roboparty-analyze/ebpf/cpu0-flight.py arm
# 故障之外的手动保存，不触碰机器人：
sudo python3 /opt/roboparty/lib/roboparty-analyze/ebpf/cpu0-flight.py dump
```

第一次异常冻结后导出到 `/home/robo/ebpf/results/cpu0-flight-*`，随后服务保持 captured 状态，不再挂载探针、不覆盖首个窗口。下一轮业务停止后重启服务重新记录。启动/冻结导出期间状态可能暂不可用，不能复用旧 READY。

输出包括 `metadata.json`（boot、时钟对、IRQ/TID、任务策略、kprobe_profile 前后及卸载前快照）、生成的 `program.bt`、`compile.log`、`stderr.log`、原始 `trace.jsonl`、排序后的 `events.jsonl` 和 `summary.json`。导出会检查各环形序号连续性、槽位匹配、切换/策略配对、自动触发与切换时间戳一致、FINAL、目标迁移及诊断错误。每次事件在探针入口取一次时间，同一切换不因写 map 而生成不同的触发时间。`valid_export` 仅表示这些检查通过，不保证不存在未观测到的事件；还需核对函数配对、实际时间覆盖和探针开销。当前 perf/BPF 挂载的 kretprobe 未出现在 kprobe_profile，故明确输出 `kretprobe_missed_verified=false`，不能把空文件解读为零漏采。已识别的编译器 cast/delete lint 保留在原始文件，其他诊断会使检查失败。

事件公共列为 `seq, ns, cpu, tid, values`。switch 的 values 为 `prev_tid,next_tid,prev_state,prev_prio,next_prio,preempt`，policy 为 `prev_policy,next_policy,prev_rtprio,next_rtprio,prev_dl_server,next_dl_server,prev_comm,next_comm`。硬/软中断 values 首项为 IRQ/vector，入口/退出分别存储，允许判断边界未配对。函数入口首项为 arg0；fair_pick_exit 首项为选中的 TID。`residency_during_wait` 是两次切换间的墙钟驻留时间，包含嵌套中断，不能当作任务独占 CPU 时间。

2026-10-23 已安装并启动开启跟踪选项的 6.18.58 内核，四个 preemptirq 事件实际存在。运行内核能力以 `preemptirq_available` 为准。全量 BPF map 写入这些高频事件的空载开销过大，已停用该路径；现在用私有 tracefs instance 的 CPU0 32 MiB 原生环形缓冲记录 preempt_disable/enable、irq_disable/enable，不改全局 current_tracer。内核事件格式使用 caller_offs/parent_offs，相对 `_stext`；由内核格式化为调用符号和偏移，避免猜字段。

新增 `preemptirq.trace`、`preemptirq-stats.txt`、四个事件的 `.format` 和本次 `kallsyms.txt`。ftrace 使用 mono 时钟，文本时间精度为 1 us；BPF 事件仍为 monotonic 纳秒。**原生环由管理进程看到 BPF 冻结标志后停止，通常晚于 BPF 窗口，不具有 BPF 前后双缓冲的立即冻结保证。** 必须检查 `summary.preemptirq.wait_start_covered` 和实际 first/last 时间。overrun 表示预期的环形覆盖；commit overrun、dropped events、解析失败会使原生导出无效。配对跨度只表示所见开关事件之间的时间，仍须结合 sched_switch 和 IRQ 嵌套分析，不能直接当作某线程连续禁止抢占的执行时间。原生环导出后会移除本次 instance；异常强杀未完成清理时，须检查 `/sys/kernel/tracing/instances/rp_cpu0_*`，避免遗留采集。

首次部署只能在无运动条件下做挂载、阈值触发、手动冻结与导出验证；空载开销对照不能替代 800 Hz 带载开销和长测验证。不要为制造触发而在机器人运行时压 CPU、关中断或调整 FIFO 优先级。

## 应用计数、socket排队与CPU0同窗记录（2026-10-22准备）

**重要现场记录：本轮准备期间误将bpftrace 0.27的`-d all`当作只编译，实际挂载了新探针。调度探针出现map容量告警，随后2026-10-22 05:41:50 CST运控报多路count=26并退出；不能排除新增探针及告警输出的影响，不能将此事件当成无干扰复现。已停止本轮启动的探针，没有重新启动机器人。** 没有安装库、替换应用或修改绑核。板上暂存目录为`/root/roboparty-count-trace-staging`，应用补丁尚未生效。

已纠正只编译入口为`--mode codegen --emit-elf`；0.27源码在codegen模式下于运行/挂载路径之前返回。**`-d all`只是调试输出开关，`--dry-run`也会先挂载探针，都不能当作无挂载检查。** 调度环和排队环改为显式map容量，避免依赖环境默认值。源代码依据：https://github.com/bpftrace/bpftrace/blob/v0.27.0/src/main.cpp 。

记录器默认关闭。下一次由操作者启动测试时，预先建立可写目录，在实际inference进程的启动环境中设置：

```bash
export MOTOR_RESPONSE_TRACE=1
export MOTOR_RESPONSE_TRACE_DIR=/home/robo/perf-results/response-trace
```

不要为当前进程执行restart来设置环境变量。目录须预先存在且应用用户可写。启用后初始化32个线程槽，每槽32768个事件，约64MiB事件存储，先分配初始化再启动CAN线程。实时路径不做逐帧文件写入、不取用户栈；后台普通调度线程每100ms检查冻结状态，离线异常触发后导出CSV。它仍有原子操作、取时钟和缓存竞争开销，需要先短测量化。超过线程槽数会记录dropped；每槽覆盖旧事件并报告overwritten，不能视为全程日志。

应用CSV使用CLOCK_MONOTONIC，记录：

| kind | 事件 | before/after/detail含义 |
| --- | --- | --- |
| 1 | LRO计数原子递增 | 原子操作返回的旧值、新值 |
| 2 | LRO接收回调清零 | exchange得到的旧值、清零后值；不是用两次load猜旧值 |
| 3 | 离线检查读取计数 | 此次实际读取值；阈值检查逻辑不改 |
| 4 | 运控socket read返回 | socket fd、读取字节数、CAN载荷长度 |
| 5 | 用户态发送队列入队尝试 | socket fd、入队是否成功、载荷长度 |
| 6 | 实际socket write最终返回 | socket fd、返回字节数、失败时errno |
| 7 | 确认离线，即将抛异常 | detail为实际offline_threshold；随后冻结 |

事件另含ifindex、电机ID/CAN ID、对象地址、线程ID、CPU和前8字节载荷。计数操作以`start_ns..end_ns`包围原子操作；线程可能在操作前后被抢占，因此区间重叠时不强行排列原子操作先后。SocketRead记录点在read返回后；它与内核出队不是同一时刻。仅LRO计数已接入，其他电机类型不声称覆盖。冻结只保留保护前窗口，不记录停机后的恢复；正常进程析构也会导出，SIGKILL/崩溃/断电不保证导出。

`trace-app-can-queue.bt`通过指定RX线程的`skb_recv_datagram`学习**运控自身的sock指针**，跟踪同一个克隆skb从`sock_queue_rcv_skb_reason`入口到出队返回的时间；这不是candump的socket。入队入口略早于实际插入，初始已有积压没有配对时标记unpaired，不能当零延迟；重复CAN载荷不能独立唯一标识报文，需同时核对ID、顺序和线程。当前应用不使用MSG_PEEK，其他接收方式应另行核对。`trace-response-sched.bt`保留CPU0最近16384次切换和目标线程最近1024次就绪等待，不像旧探针在首次长等待时提前冻结。

联合入口只挂载观察探针，不启动业务：

```bash
sudo python3 capture-response-window.py APP_PID CAN0_RX_TID CAN0_TX_TID IMU_IRQ_TID USB_IRQ_TID \
  /path/to/motor-response-APP_PID-START_NS.csv \
  --bpftrace /root/ebpf/bin/bpftrace --output /path/to/new-capture-directory --seconds 20
```

PID/TID必须重新核对，不能抄旧值。CSV须为该进程启动时已创建、尚为空的文件。先做20秒观察开销验证，再考虑延长；入口最高允许21600秒，但有界环只保留最近窗口，不保证保留6小时全部事件。看到应用CSV开始导出、RX退出、达到时限或Ctrl-C时，联合入口**仅向自己新建的两个探针进程组发送信号**，不向机器人PID发信号；后台导出检测会带来约100ms以上的滞后，需检查环形窗口是否仍覆盖保护发生时刻。两个探针都是CLOCK_MONOTONIC，可与应用记录直接对齐。

分析应用CSV：`analyze-response-trace /path/to/motor-response-*.csv`。应最终核对同次故障的“反馈入目标socket→出队→read返回→回调清零”，以及期间计数递增和CPU执行者，不能用不同运行的片段拼接为因果闭环。任何探针无样本、缺FINAL、map更新失败、kretprobe漏采或丢事件，都必须报告不完整；只编译通过不代表挂载和运行开销验证通过。

## 监控主线程调度

`run-monitor-sched.sh TID [SECONDS=1800] [THRESHOLD_US=5000]` 只观测已有线程，不启动或停止机器人。`TID` 应是本轮Python测试监控的主线程ID；不能复用上轮PID。安装后入口为 `robopi-ebpf-monitor-sched`，最长单次6小时，目标退出后自动结束。

`MONITOR_OFFCPU` 包含主动休眠、等待及抢占，不能直接解释为CPU饥饿；`MONITOR_READY_WAIT` 单独记录观察到可运行后至真正运行的等待。直方图保留所有配对样本，慢事件每类每秒最多打印一次。没有样本或边界未配对不能解释成没有停顿。源码位于合并后的 `roboparty_analyze/ebpf/`，不再向旧的独立 `deb/ebpf` 目录新增功能。

测试监控同时应使用 `recvmsg` 采集 `SO_TIMESTAMPNS_NEW` 和 `SO_RXQ_OVFL`，并在超时时用 `SO_MEMINFO` 记录当前socket丢弃数、用 `MSG_PEEK` 观察队首积压。内核收包时间戳属于CLOCK_REALTIME，监控安全阈值仍按原monotonic逻辑判断；实时时钟校正可能影响诊断年龄，不能直接混用两个时钟。用户态阶段wall时间减线程CPU时间也包含阻塞和中断，并非精确调度等待，需与此探针对照。

## 使用

### 单独监控

目标板需要 root、`bpftrace`、`python3`、GNU coreutils，以及运行内核的 BTF、kprobe 和调度 tracepoint 支持。现有入口只观察已有线程，不启动设备或机器人：

```bash
sudo bash run-monitor-sched.sh TID 1800 5000
sudo bash run-can-state.sh can0 120
```

`run-monitor-sched.sh` 观测指定 TID 的 off-CPU/就绪等待；`run-can-state.sh` 观测 CAN bus-off/restart。两者都不会修改 IRQ 亲和性、波特率或发送 CAN 帧。

## 验证与限制

检查脚本语法：

```bash
bash -n run-can-state.sh run-monitor-sched.sh
```

旧版 `-d` 只适用于历史 bpftrace，**不能用于 0.27**；0.27 的无挂载编译使用 `--mode codegen`。缺少目标平台符号时可能警告或失败，应在目标内核再次检查。日志没有样本、探针挂载失败、没有结束摘要或发现事件丢失时，不能宣称延迟正常。退出码非零表示错误、无样本、发现采集不完整或被中断，完整有样本的采集返回零；它不代表通信没有故障。结束时未配对的入口也可能只是采集边界。

本目录没有自动上板、刷写或修改系统配置的步骤。eBPF/kprobe 仍有观测开销，需要对照不挂探针时的行为。


