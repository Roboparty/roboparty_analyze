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

第一次异常冻结后导出到 `/home/robo/ebpf/results/cpu0-flight-*`，随后服务保持 captured 状态，不再挂载探针、不覆盖首个窗口。下一轮业务停止后重启服务重新记录。一键 800 Hz 脚本在业务启动前重新准备记录器、在身体启动前布防，清理时请求补充保存，并把输出目录写入本轮 `cpu0-recorder.json`。启动/冻结导出期间状态可能暂不可用，不能复用旧 READY。

输出包括 `metadata.json`（boot、时钟对、IRQ/TID、任务策略、kprobe_profile 前后及卸载前快照）、生成的 `program.bt`、`compile.log`、`stderr.log`、原始 `trace.jsonl`、排序后的 `events.jsonl` 和 `summary.json`。导出会检查各环形序号连续性、槽位匹配、切换/策略配对、自动触发与切换时间戳一致、FINAL、目标迁移及诊断错误。每次事件在探针入口取一次时间，同一切换不因写 map 而生成不同的触发时间。`valid_export` 仅表示这些检查通过，不保证不存在未观测到的事件；还需核对函数配对、实际时间覆盖和探针开销。当前 perf/BPF 挂载的 kretprobe 未出现在 kprobe_profile，故明确输出 `kretprobe_missed_verified=false`，不能把空文件解读为零漏采。已识别的编译器 cast/delete lint 保留在原始文件，其他诊断会使检查失败。

事件公共列为 `seq, ns, cpu, tid, values`。switch 的 values 为 `prev_tid,next_tid,prev_state,prev_prio,next_prio,preempt`，policy 为 `prev_policy,next_policy,prev_rtprio,next_rtprio,prev_dl_server,next_dl_server,prev_comm,next_comm`。硬/软中断 values 首项为 IRQ/vector，入口/退出分别存储，允许判断边界未配对。函数入口首项为 arg0；fair_pick_exit 首项为选中的 TID。`residency_during_wait` 是两次切换间的墙钟驻留时间，包含嵌套中断，不能当作任务独占 CPU 时间。

2026-10-23 已安装并启动开启跟踪选项的 6.18.58 内核，四个 preemptirq 事件实际存在。运行内核能力以 `preemptirq_available` 为准。全量 BPF map 写入这些高频事件的空载开销过大，已停用该路径；现在用私有 tracefs instance 的 CPU0 32 MiB 原生环形缓冲记录 preempt_disable/enable、irq_disable/enable，不改全局 current_tracer。内核事件格式使用 caller_offs/parent_offs，相对 `_stext`；由内核格式化为调用符号和偏移，避免猜字段。

新增 `preemptirq.trace`、`preemptirq-stats.txt`、四个事件的 `.format` 和本次 `kallsyms.txt`。ftrace 使用 mono 时钟，文本时间精度为 1 us；BPF 事件仍为 monotonic 纳秒。**原生环由管理进程看到 BPF 冻结标志后停止，通常晚于 BPF 窗口，不具有 BPF 前后双缓冲的立即冻结保证。** 必须检查 `summary.preemptirq.wait_start_covered` 和实际 first/last 时间。overrun 表示预期的环形覆盖；commit overrun、dropped events、解析失败会使原生导出无效。配对跨度只表示所见开关事件之间的时间，仍须结合 sched_switch 和 IRQ 嵌套分析，不能直接当作某线程连续禁止抢占的执行时间。原生环导出后会移除本次 instance；异常强杀未完成清理时，须检查 `/sys/kernel/tracing/instances/rp_cpu0_*`，避免遗留采集。

首次部署只能在无运动条件下做挂载、阈值触发、手动冻结与导出验证；空载开销对照不能替代 800 Hz 带载开销和长测验证。不要为制造触发而在机器人运行时压 CPU、关中断或调整 FIFO 优先级。

## 应用计数、socket排队与CPU0同窗记录（2026-10-22准备）

**重要现场记录：本轮准备期间误将bpftrace 0.27的`-d all`当作只编译，实际挂载了新探针。调度探针出现map容量告警，随后2026-10-22 05:41:50 CST运控报多路count=26并退出；不能排除新增探针及告警输出的影响，不能将此事件当成无干扰复现。已停止本轮启动的探针，没有重新启动机器人。** 没有安装库、替换应用或修改绑核。板上暂存目录为`/root/roboparty-count-trace-staging`，应用补丁尚未生效。

已纠正只编译入口为`--mode codegen --emit-elf`；0.27源码在codegen模式下于运行/挂载路径之前返回。**`-d all`只是调试输出开关，`--dry-run`也会先挂载探针，都不能当作无挂载检查。** 调度环和排队环改为显式map容量，避免依赖环境默认值。源代码依据：https://github.com/bpftrace/bpftrace/blob/v0.27.0/src/main.cpp 。

应用补丁在`../diagnostics/application-response-trace.patch`，基于`test/robo/rp1_deploy_wbc`副本；修改前LRO、SocketCAN和RobotInterface三个cpp与板上源码SHA256一致。补丁需在后续停止测试后检查并应用到对应工作区，重编译motors和inference后，**下次启动**才会生效。LRO类布局发生改变，不能仅替换运行中的动态库，也不能只重编其中一个依赖模块。

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

单独只编译socket探针、不会挂载：

```bash
sudo env BPFTRACE_BIN=/root/ebpf/bin/bpftrace bash run-app-can-queue.sh APP_PID RX_TID can0 20 --compile-only
```

分析应用CSV：`python3 ../diagnostics/analyze-response-trace.py /path/to/motor-response-*.csv`。应最终核对同次故障的“反馈入目标socket→出队→read返回→回调清零”，以及期间计数递增和CPU执行者，不能用不同运行的片段拼接为因果闭环。任何探针无样本、缺FINAL、map更新失败、kretprobe漏采或丢事件，都必须报告不完整；只编译通过不代表挂载和运行开销验证通过。

## CPU与can0线程的详细时间线

旧版逐事件打印的板端验证失败：READY后1048.702ms运控因can0七电机count=26退出；出现43次栈解析错误、60887个丢失事件且无FINAL。不能排除采集开销触发或加重故障。**当前version=2已改用内核有界记录，移除逐事件打印和栈展开；尚不能据此宣称运行开销满足机器人实时要求。**

10月22日冻结日志证明原生CAN IRQ在CPU0就绪后等待34.436ms；`previous_comm=irq/77-ehci_hcd`只标识切换前一个任务，不能证明EHCI连续占用全部34ms。现有日志尚不能解释can0收发线程在同窗等待什么。

新增 `run-cpu-can-sched.sh`，安装后入口为 `robopi-ebpf-cpu-can-sched`。仅观察已有线程，不启动运控。先用 `ps -eLo pid,tid,psr,cls,rtprio,comm`、`/proc/interrupts` 和线程亲和性确认本轮CPU、两个IRQ线程及can0 RX/TX线程；参数是 **TID，不是IRQ编号**，不能复用旧日志里的165/633等值。

```bash
sudo env COMPILE_ONLY=1 robopi-ebpf-cpu-can-sched CPU CAN_IRQ_TID USB_IRQ_TID CAN_RX_TID CAN_TX_TID 30 5000
# 编译检查通过后，正式采集入口（需要本轮真实线程号）：
sudo robopi-ebpf-cpu-can-sched CPU CAN_IRQ_TID USB_IRQ_TID CAN_RX_TID CAN_TX_TID 30 5000
```

默认30秒、5000微秒阈值，最长3600秒。输出目录含 `before.txt`、`sched.log`、`after.txt`；编译模式仅生成before和compile.log，不挂载、不产生运行事件。运行中仅输出READY，结束后导出map，不逐事件跨内核/用户态打印。默认启动后1秒预热，随后观察到目标线程就绪等待超过阈值时，继续保留约100ms并冻结记录。冻结不改变机器人状态；实际冻结由后续sched_switch或1秒定时器完成，定时器兜底可能更晚，必须以 `@frozen` 为准。命令到指定时长后卸载并导出；导出时仍会有CPU与磁盘开销。

编译器及导出进程默认放在允许CPU中编号最大的非观测CPU，可用 `TRACER_CPU` 指定；这只改变本采集器用户态进程亲和性，不改变机器人、IRQ或探针在事件上下文中的执行CPU。导出后自动核对8192槽内的seq连续性和槽位对应关系，缺失则失败。这个检查不能证明探针观察到了所有内核事件，也不能替代负载影响评估。

支持 `BPFTRACE_BIN=/path/to/bpftrace`，默认优先本目录 `bin/bpftrace`，其次系统命令。本机0.14的BEGIN符号缺失会导致原始入口挂载失败，不能忽略该错误；验证范围与板端失败记录见 `VERIFICATION-cpu-can-sched.txt`。

- `@switch_ring[slot]`：指定CPU的最近8192条切换。元组为 `(seq, ns, prev_tid, next_tid, prev_state, prev_prio, next_prio, prev_comm, next_comm)`，按seq排序，检查序列连续性。仅此CPU保存全部切换；目标线程在其他CPU只保留慢等待摘要。
- `@wait_ring[tid, slot]`：每线程最近64次慢off-CPU或就绪等待，元组为 `(seq, run_ns, out_ns, out_state, ready_ns, cpu, ready_wait_us)`。out_ns/ready_ns为0代表未观察到对应边界。off-CPU包含主动睡眠，不能当CPU饥饿；可运行切出按0/256识别，快照保存内核格式供核对。
- `@sys_ring[tid, slot]`：每线程最近64次慢系统调用，元组为 `(seq, enter_ns, exit_ns, cpu, syscall_id, arg0, ret)`。arg0只在对应调用中才是fd，编号按采集机器架构解释。耗时包含执行、阻塞和抢占；当前不采集阻塞栈。
- `@hard_ring[irq, slot]`：指定CPU每IRQ最近32次配对，元组为 `(seq, enter_ns, exit_ns, interrupted_tid, handler_ret)`；`@soft_ring[vec, slot]`同样保留最近32次软中断，末字段为tid。中断保留窗口通常比8192条切换更短，不能将缺记录视为没有中断，也不覆盖NMI/固件等所有干扰。
- `@trigger`：`(ns, tid, cpu, ready_ns, ready_wait_us)`；`@freeze_at`是计划冻结时间，`@frozen`为实际冻结时间。多CPU触发存在竞争，因此不保证记录的是全局最早异常，也不把触发认定为停机根因。

map槽位覆盖旧记录是设计行为；容量固定不等于保留固定秒数。只解释各ring实际覆盖的交集，不能跨不同保留窗口拼出“完整”时间线。存在挂载/导出边界、map更新失败或探针未执行等风险，无lost提示不证明全部事件已观察；需核对seq、目标计数和采集状态。目标退出在冻结前停止跟踪该TID，冻结后状态全部保持原样。

这些探针仍不记录应用内部队列入队、每个电机接收回调清零和计数递增，无法单独解释USB已见反馈却count=26的全部时序；这部分需要后续应用诊断点。

## 监控主线程调度

`run-monitor-sched.sh TID [SECONDS=1800] [THRESHOLD_US=5000]` 只观测已有线程，不启动或停止机器人。`TID` 应是本轮Python测试监控的主线程ID；不能复用上轮PID。安装后入口为 `robopi-ebpf-monitor-sched`，最长单次6小时，目标退出后自动结束。

`MONITOR_OFFCPU` 包含主动休眠、等待及抢占，不能直接解释为CPU饥饿；`MONITOR_READY_WAIT` 单独记录观察到可运行后至真正运行的等待。直方图保留所有配对样本，慢事件每类每秒最多打印一次。没有样本或边界未配对不能解释成没有停顿。源码位于合并后的 `roboparty_analyze/ebpf/`，不再向旧的独立 `deb/ebpf` 目录新增功能。

测试监控同时应使用 `recvmsg` 采集 `SO_TIMESTAMPNS_NEW` 和 `SO_RXQ_OVFL`，并在超时时用 `SO_MEMINFO` 记录当前socket丢弃数、用 `MSG_PEEK` 观察队首积压。内核收包时间戳属于CLOCK_REALTIME，监控安全阈值仍按原monotonic逻辑判断；实时时钟校正可能影响诊断年龄，不能直接混用两个时钟。用户态阶段wall时间减线程CPU时间也包含阻塞和中断，并非精确调度等待，需与此探针对照。

## 公共接收路径采集

`run-can-path.sh` / `trace-can-path.bt` 补充观测 USB 回调、完整的原生 CAN IRQ、CAN offload、NAPI 与 SocketCAN 分发。默认按 ifindex 分组统计全部 CAN 接口，不启用接口、不产生 CAN 流量。可与下面的 `run-link-stall.sh` 同时运行，比较各自 READY 之后的重叠窗口。

```bash
sudo bash run-can-path.sh 120 5000
# 仅观察一个接口：
sudo bash run-can-path.sh 120 5000 can_hipnuc
```

这个新增脚本要求 **bpftrace 0.27 或更新版本**，使用模块限定的探针与运行中模块的 BTF。特别是 `can_raw:raw_rcv` 与内核 IPv4 的 `raw_rcv` 同名，不能用无模块限定的探针替代。原有 USB/IRQ 脚本仍使用系统 bpftrace；新增入口优先使用本目录 `bin/bpftrace`，也可通过 `BPFTRACE_BIN` 指定，不需要覆盖 `/usr/bin/bpftrace`。

验证用 ARM64 工具来源为 [bpftrace 官方 v0.27.0 Release](https://github.com/bpftrace/bpftrace/releases/tag/v0.27.0)，资产名 `bpftrace-aarch64`，SHA256 为 `13879e0b6c6b3fa6384ad24859157b6ce352aac9d84f55eabadc68c2c6084274`。二进制不纳入源代码；安装到板上本目录的 `bin/bpftrace` 并赋予执行权限即可。新增脚本还需要 `can`、`can_dev`、`can_raw`、`gs_usb`、`rockchip_canfd` 的运行时 BTF；缺少条件时直接报错，不猜测私有结构体偏移。

| 指标 | 实际测量范围 |
| --- | --- |
| `function_us` / `function_max_us` / `PATH_SLOW` | 各函数入口到返回的墙钟耗时，包含抢占和嵌套调用，不能相加作为总延迟 |
| `gs_usb_receive_bulk_callback` | USB 接收回调，发生在该 URB 的 usbmon C 之后；正常帧映射到对应 CAN 接口，无法解析的完成归入 ifindex 0 |
| `rkcanfd_irq` | 完整原生 CAN IRQ 处理，包括接收和错误处理，不只是 FIFO drain helper |
| `can_rx_offload_irq_finish` | 接收队列合并、加锁和安排 NAPI 的耗时；同时记录入口时队列长度最大值 |
| `napi_wait_us` / `NAPI_WAIT` | `__napi_schedule()` 入口到对应 offload NAPI poll 入口；预算耗尽后的再次 poll 不一定有新 schedule，单独计数 |
| `queue_to_delivery_us` / `CAN_QUEUE_WAIT` | 同一个 skb 成功进入 offload 队列后，到 `netif_receive_skb()` 入口；包含排队和前面帧的处理，不是纯调度延迟 |
| `can_receive` / `raw_rcv` / `sock_queue_rcv_skb_reason` | CAN 协议分发、RAW socket 分发和 socket 入队各阶段耗时 |
| `socket_drop_reason` | socket 入队返回的非零内核 drop reason，按接口和原因编号计数；不能把所有原因都称为缓冲区满 |
| `native_fifo_overruns` / `CAN_OVERFLOW` | 同一次原生 CAN IRQ 入口与返回之间的 `rx_over_errors` 增量，不是精确丢帧数或硬件溢出瞬间 |

输出目录为 `results/can-path-时间-随机后缀/`，包含 `before.txt`、`trace.log`、`after.txt`。`ifname` 提供接口索引与名称对应关系。函数按线程、函数和嵌套深度配对；队列按 skb 生命周期配对，并在交付或被释放时清理。结束时 `calls`、`queued_ns`、`napi_ready_ns` 中的残留可能是采集边界，也可能需要继续调查，不能单独认定卡死。`return_without_entry` 可能来自探针启动/停止边界或丢失探针事件，须结合样本覆盖和探针状态判断。

采集秒数从 BPF 的 BEGIN 开始计算，1 秒定时器到期后冻结统计并退出；`capture_start_ns` / `capture_stop_ns` 标记实际窗口。编译与卸载不计入指定秒数，但会增加命令总耗时。实板观察到卸载在 `synchronize_rcu_tasks_trace()` 等待，可能需要数十秒才输出最终汇总；外层超时是额外 90 秒的看门狗，触发后按失败处理。窗口边界仍可能留下在途调用，不要求每层计数严格相等。

所有成功配对样本进入统计；慢事件按函数/接口每秒最多输出一次。退出码 0 只表示至少有一部分函数配对且程序正常结束；2 表示没有配对样本；其他非零码表示采集错误或中断。缺少某个阶段的样本不等于该阶段正常。此全链路模式的探针数量较多，测量开销未标定，建议先短时间采集，再与不挂探针时对照。

2026-10-21 已在板上通过原生 IMU CAN 的 5 秒短测：1999 个队列配对样本，NAPI 等待最大 72 us，队列至协议栈最大 98 us；SocketCAN 各阶段均有配对样本。USB-CAN 当时为 DOWN，USB bulk 路径未获得样本。完整范围、计数与限制见 [VERIFICATION-can-path.txt](VERIFICATION-can-path.txt)，原始日志位于 `results/can-path-20261021T142719Z-PZg2lQ/`。

针对 RK3588 PREEMPT_RT 上原生 IMU CAN 与 HPM USB CAN 同时出现约 906 ms 接收空洞的排查工具。只挂载观测探针、读取状态和写日志；不发送 CAN 帧，不修改波特率、IRQ 亲和性或优先级，不复位 USB，不安装常驻 service。

这套工具观测 Linux，不能直接读取 HPM CPU、固件心跳或设备端 IRQ。USB 抓包的完成时间是主机软件处理时间，不能当作 USB 总线实际完成时刻。

## 使用

### WBC 完整流程

`run-wbc-test.sh` 包装已有 `rp1_deploy_wbc/tools/start_rp1_teleop.sh`，保留其默认的 RP1 teleop、双手 50 Hz 和手柄映射；EGO 与 ROS 录制仍按原脚本默认关闭。它先确认两组探针都进入事件循环，再启动业务。用运行 WBC 的普通用户执行：

```bash
bash run-wbc-test.sh --workspace /home/robo/rp1_deploy_wbc --check
bash run-wbc-test.sh --workspace /home/robo/rp1_deploy_wbc --seconds 1800
```

普通用户需有可用的 `sudo -n` 权限启动观测；包装不修改 sudoers。`--check` 只读，不启动探针或业务。已有同名 WBC screen 会话时会拒绝启动，避免原脚本自动清理它们。原脚本包含编译，编译时间计入监控窗口；日志和配置指纹保存在本次独立目录。Ctrl-C 仅停止本次观测，**不会停止已经进入后台的机器人程序**。

`sudo -n` 可以使用已有授权配置或有效的认证缓存；不可用时，由已有 root 会话单独启动观测，确认 `LINK_STALL_READY` 后，再以应用用户启动 WBC，不为测试修改 sudoers。若通过 root 的 `systemd-run` 创建 `User=robo` 的 WBC 服务，需同时设置 `LimitRTPRIO=90` 和 `LimitMEMLOCK=infinity`；否则实时线程创建可能报 `Operation not permitted`。不要把整套 WBC 改为 root 运行。

### 单独监控

目标板需要 root、`bpftrace`、`python3`、`ethtool`、`iproute2`、GNU coreutils，以及运行内核的 BTF、kprobe 和调度 tracepoint 支持。原生 CAN 与 USB 设备需已由现有流程启用。脚本不会启动它们。

先确定**本次启动**的 IRQ，历史 IRQ 77 不可直接照抄：

```bash
grep -E 'can_hipnuc|ehci' /proc/interrupts
lsusb -d 1209:2323
```

将下面的 `CAN_IRQ` 和 `USB_IRQ` 替换成实际数字，采集 120 秒，慢事件阈值 5000 微秒：

```bash
sudo bash run-link-stall.sh CAN_IRQ USB_IRQ 120 5000
```

默认接口名是 `can_hipnuc`，可用 `IMU_IFACE` 指定。输出在 `results/link-stall-时间-随机后缀/`，也可设置 `OUTPUT_DIR`。采集到时自动卸载探针；Ctrl-C 同样触发清理。日志默认不逐帧输出，慢事件每种类型/线程或端点每秒最多打印一次，直方图和最大值保留全部测量。

首次建议不启用逐次 FIFO 读探针。需要确定一次 IRQ 内循环次数时：

```bash
sudo env TRACE_RX_ITERATIONS=1 bash run-link-stall.sh CAN_IRQ USB_IRQ 120 5000
```

这会额外在 `rkcanfd_handle_rx_int_one()` 每次调用时执行探针，有测量开销。如果函数被内联或不可探测，脚本明确报错；用默认模式重试。`iterations` 是 FIFO 读取尝试次数，不等于有效 CAN 帧数。默认模式的 `iterations=0 iter_enabled=0` 表示未测量，不能解读为没有循环。

已有的 `run-usb-giveback.sh` / `trace-usb-giveback.bt` 保留，可单独观测 USB：

```bash
sudo bash run-usb-giveback.sh 120 5000
```

## 观测边界

| 输出 | 含义 | 不能据此断言 |
| --- | --- | --- |
| `CAN_SLOW` / `can_wall_us` | `rkcanfd_handle_rx_int()` 进入到返回的耗时 | 耗时全部是函数忙循环 |
| `can_offcpu_us` | 函数期间由 sched_switch 观测到的离开 CPU 时间 | 硬中断/NMI 内耗时也被扣除了 |
| `can_oncpu_est_us` | 总耗时减去上述离开 CPU 时间 | 精确的函数纯 CPU 时间 |
| `can_iterations` | 可选：本次处理内单条读取函数的调用次数 | 所有读取都有有效帧 |
| `IRQ_WAIT` | 指定 CAN/USB IRQ 线程唤醒或被抢占后，到再次运行的时间 | `previous_comm` 就是全程阻塞者 |
| USB `SLOW` / `delay_us` | HCD giveback 函数入口到实际回调入口的时间 | 设备收到命令到返回反馈的时间 |
| `before.txt` / `after.txt` | IRQ 计数、亲和性、线程优先级、RT 预算、接口状态、`ethtool -S` | 快照中每项读取都发生在同一时刻 |

`rx_fifo_empty_errors` 在两次 `ethtool -S` 中的增量可佐证空 FIFO 误读。它不是 eBPF 循环计数，两次快照也不能给出每次错误的精确时间。快照命令超时或失败会保留错误输出，不应将缺失计数当成零。

## 如何区分原因

1. CAN 函数总耗时很长、离开 CPU 时间很少，同时迭代数和空 FIFO 错误大幅增加：支持 CAN IRQ 内异常循环，需要结合 IRQ 所在 CPU 判断对 USB 的影响。
2. CAN 函数总耗时很长，但主要耗在离开 CPU，或出现很长的 `IRQ_WAIT`：支持线程调度等待，不能直接归咎于 FIFO 循环。
3. USB giveback 延迟很大：HCD 已进入交还 URB 的路径，后续 BH/回调处理迟到。优先检查主机侧，不能据此说 HPM 没有响应。
4. USB 没有新 giveback 入口：这套 USB 探针看不到更早的 EHCI IRQ、硬件传输或 HPM 状态，仍需补这几个位置的观测；不是 HPM 故障的单独证明。

`nsecs` 使用本机 bpftrace 版本的默认时钟，两个探针进程必须使用同一版本。快照同时保存 realtime、monotonic 和 boottime 供核对，不可直接把 `nsecs` 当 Unix 时间。两组探针启动有先后，仅比较双方都已挂载的重叠窗口。

联合监控通过两组一次性 interval 事件、进程存活和错误日志检查后输出 `LINK_STALL_READY`。设置 `READY_FILE` 为新的绝对路径时，会原子写入包含输出路径及三种时钟的 JSON，供 WBC 包装使用。BEGIN 中的配置打印不作为就绪依据。

调度探针只跟踪所选两个 IRQ 线程，不跟踪全部 softirq/kworker；读取 `/proc/softirqs` 只是前后计数。抢占状态按 Linux 6.18 的 `TASK_REPORT_MAX=256` 处理。跨内核系列使用前应核对 tracepoint 格式。IRQ 线程重建或 USB 重枚举后应停止并重新采集，脚本不会自动跟随新 PID/设备地址。

## 验证与限制

检查脚本语法：

```bash
bash -n run-link-stall.sh run-usb-giveback.sh
sudo bpftrace -d trace-can-irq.bt CAN_TID USB_TID 5000 0
sudo bpftrace -d trace-usb-giveback.bt USB_BUS USB_DEV 5000
```

以上`-d`示例仅适用于历史旧版bpftrace，**不能用于0.27**；0.27无挂载编译使用`--mode codegen`，详见本页开头的现场纠正记录。缺少目标平台符号时可能警告或失败，应在目标内核再次检查。日志没有样本、探针挂载失败、没有结束摘要或发现事件丢失时，不能宣称延迟正常。退出码非零表示错误、无样本、发现采集不完整或被中断，完整有样本的采集返回零；它不代表通信没有故障。结束时未配对的入口也可能只是采集边界。

本目录没有自动上板、刷写或修改系统配置的步骤。eBPF/kprobe 仍有观测开销，特别是逐次 FIFO 探针，需要对照不挂探针时的行为。

本地验证（2026-10-21）：Shell 语法、bpftrace 0.14 编译、普通/循环计数两种合成测试通过。合成测试将 CAN 函数探针替换为开发机 libc 的 `usleep` / `nanosleep`，30 次 50 ms 调用全部配对，离开 CPU 的时间约 50 ms，每次内部调用计数为 1。开发机的 bpftrace 可执行文件缺少 `BEGIN_trigger`，因此测试用控制进程的 syscall 触发相同初始化和结束逻辑；正式脚本会通过自检拒绝这种不可用的 bpftrace。尚未在目标 ARM64 板上挂载，也没有证明现场根因。

可重复的主机侧合成验证：

```bash
sudo python3 tests/check-host.py
sudo python3 tests/check-host.py --iterations
```
