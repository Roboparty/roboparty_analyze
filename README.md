# roboparty-analyze

仓库名为 `roboparty_analyze`，Debian 包名为 `roboparty-analyze`。
1.0.11 起提供旧名 `robopi-analyze` 过渡包，原有采集命令和 service 名保持兼容。

RoboPi HPM、BMS、电源和通信故障分析工具包，面向 Ubuntu 24.04 ARM64 RoboPi
系统。包内包含七维日志采集、USB-CAN 抓包、CAN ASC、HPM 串口和推理进程分析工具。

## eBPF 现场观测

安装包同时提供只读 eBPF 观测工具，用于补充 USB pcap、CAN 日志和 dmesg 无法看到的内核时序。入口包括：

```text
robopi-ebpf-link-stall CAN_IRQ USB_IRQ [SECONDS] [THRESHOLD_US]
robopi-ebpf-can-path USB_BUS USB_DEV [THRESHOLD_US] [IFINDEX] [SECONDS]
robopi-ebpf-usb-urb USB_BUS USB_DEV [SECONDS] [THRESHOLD_US]
robopi-ebpf-can-state [IFACE] [SECONDS]
robopi-ebpf-monitor-sched TID [SECONDS] [THRESHOLD_US]
robopi-ebpf-cpu-can-sched CPU CAN_IRQ_TID USB_IRQ_TID CAN_RX_TID CAN_TX_TID [SECONDS] [THRESHOLD_US]
```

这些命令需要 root、运行内核 BTF/kprobe 和 bpftrace。它们不会发送 CAN、修改波特率或 IRQ affinity；`robopi-ebpf-usb-urb` 记录主机 USB URB submit 到 HCD giveback 的生命周期，`robopi-ebpf-can-state` 记录 `can_bus_off`/`can_restart` 入口。入口事件不等于硬件恢复完成，USB-CAN 业务验证仍需接口 UP、明确固件身份和独立台架。完整边界与验证记录见安装目录的 `ebpf/README.md`。

## 服务职责

- `hpm-log-capture.service` 是常驻 HPM 日志守护进程，持续读取 `/dev/ttyS4`。
- `hpm-sreset.service` 启动时先执行一次 HPM 正常启动复位，之后作为常驻监视器，
  找不到 HPM 时执行复位。
- `usbcan-capture.service` 安装后默认启用，系统下次启动时自动开始七维采集。
- `usbcan-debug-snapshot` 用于机器人即将下电或故障发生时保存完整现场。

安装包后 HPM 服务自动启动。需要采集故障现场时执行：

```bash
sudo systemctl start usbcan-capture.service
```

查看状态：

```bash
sudo robopi-comm-status
```

结束采集：

```bash
sudo systemctl stop usbcan-capture.service
```

停止七维采集不会停止 HPM 日志守护进程。

## 七个维度

1. BMS/电源：周期记录 `bms.service` 状态。
2. CAN 状态：记录四路 CAN 的状态、错误计数和收发统计。
3. 内核日志：记录动态 `dmesg`，用于定位驱动和 USB 事件。
4. HPM 串口：记录 `/dev/ttyS4` 的 HPM 固件日志，默认 1500000 8N1，与当前 EtherCANFD 固件控制台一致。
5. USB-CAN：记录 `usbmon` 原始 USB URB PCAP。
6. CAN ASC：采集 `can0` 到 `can3` 并转换为 Vector ASC 格式。
7. 推理输出：记录 `inference_session` screen 会话文本。

没有对应设备、工具或 screen 会话时，对应文件保持为空，其他维度继续运行。

HPM 日志配置位于 `/etc/default/hpm-log-capture`，服务读取 `HPM_LOG_BAUD`；
脚本未设置该变量时也使用 1500000。旧固件可显式覆盖，须以实际烧录版本为准。
若升级保留了本地修改过的配置文件，应检查该值，不能认为更新软件包已自动改动现场设置。
`ttyS4` 的 HPM 日志与 Windows 转发的 `ttyS2/COM47` Linux 控制台是两条不同链路。

## 七维采集

命令入口：

```bash
sudo robopi-seven-capture /home/robo/robopi-logs/seven-$(date +%Y%m%d-%H%M%S)
```

也可以使用 systemd 入口：

```bash
sudo systemctl start usbcan-capture.service
```

默认 screen 会话名为 `inference_session`，临时指定其他会话：

```bash
sudo env INFERENCE_SCREEN_SESSION=my_inference \
  robopi-seven-capture /home/robo/robopi-logs/seven-$(date +%Y%m%d-%H%M%S)
```

按 `Ctrl-C` 结束命令入口的采集。会话目录包含：

```text
manifest.json
bms-status.txt
can-details.jsonl
dmesg-live.txt
hpm-uart-live.txt
usbcan.pcap*
can.log
inference-session.txt
usb-capture.txt
```

## USB-CAN 配置

七维采集直接向当前会话目录写入 `usbcan.pcap*`，每个分片约 64 MB，
封口分片保留至会话清理，不再每 10 秒镜像复制。`/run/usbcan/current-session`
指向最近会话，供快照工具定位。会话大小、轮转和总保留量由 session guard 管理；
`SESSION_MAX_SIZE_MB` 是软上限，磁盘写入量与可用空间仍需监测。
会话 PCAP 使用缓冲写入，不再逐包 flush；正常轮转和停止会刷新尾部，
突然断电可能丢失尚未刷出的尾部记录。

运行期间及停止时仅保存 CAN 原始 `can.log`，不自动转换 ASC。停止业务后按需执行：

```bash
robopi-can-capture --convert /home/robo/robopi-logs/seven-实际会话
```

该命令仅转换已有文件，不发送 CAN 报文。七维分析器直接读取 `can.log`，不依赖 ASC。
采集服务及其子进程限制在 CPU2/3，保留 Nice=15、batch 调度和 idle I/O。
主进程每秒检查关键采集进程；意外退出会结束本轮并返回失败，由 systemd 重启采集。
最终 manifest 保存 `candump_status`、`usb_capture_status`、`capture_failed` 和
`failed_recorder`；`usb-capture.txt` 保留 tcpdump 的统计和报错。状态字段为原始退出码，
受控停止可能记录 130/143，应结合 `capture_failed` 判断。
`recorder-status.tsv` 保存各采集进程的原始退出码及是否由本轮清理请求终止。

单独运行 `usbcan-capture` 时，循环 PCAP 默认写入 `/run/usbcan/usbcan.pcap*`，配置文件为
`/etc/default/usbcan-capture`：

```text
USBMON_IFACE=auto
CAN_INTERFACE=can3
CAPTURE_DIR=/run/usbcan
FILE_SIZE_MB=64
FILE_COUNT=8
```

默认保留 8 个、每个约 64 MB 的文件，达到数量后覆盖最旧文件。自动识别 USB Bus
异常时可以查看：

```bash
lsusb
lsusb -t
sudo tcpdump -D | grep usbmon
```

HPM 日志实时查看：

```bash
sudo journalctl -fu hpm-log-capture.service
```

## 紧急快照

故障出现或机器人即将下电时执行：

```bash
sudo usbcan-debug-snapshot
sync
```

默认生成以下内容：

```text
/home/robo/usbcan-snapshots/YYYYMMDD-HHMMSS/
/home/robo/usbcan-snapshots/YYYYMMDD-HHMMSS.zip
/home/robo/usbcan-snapshots/YYYYMMDD-HHMMSS.zip.sha256
```

快照会暂停七维采集服务，复制 PCAP 和当前状态后恢复服务；HPM 守护进程始终保持
运行。自定义输出目录：

```bash
sudo env USBCAN_SNAPSHOT_DIR=/mnt/logs usbcan-debug-snapshot
```

校验压缩包：

```bash
cd /home/robo/usbcan-snapshots
sha256sum -c YYYYMMDD-HHMMSS.zip.sha256
unzip -l YYYYMMDD-HHMMSS.zip | head
```

## 分析与导出

分析七维快照，每个维度生成一个 CSV 文件（`can_frames.csv`、`bms.csv`、`dmesg.csv`、
`hpm_uart.csv`、`thermal.csv`、`inference.csv`、`can_details.csv`、`usb_pcap.csv`，
没有数据的维度不生成文件），外加 `summary.json` 汇总各文件与行数：

```bash
robopi-seven-analyze /home/robo/usbcan-snapshots/YYYYMMDD-HHMMSS
```

需要旧的合并时间轴时加 `--merged`，额外生成 `timeline.csv`：

```bash
robopi-seven-analyze --merged /home/robo/usbcan-snapshots/YYYYMMDD-HHMMSS
```

导出 ZIP 和 SHA-256：

```bash
robopi-seven-export /home/robo/usbcan-snapshots/YYYYMMDD-HHMMSS
```

只分析 USB-CAN PCAP：

```bash
analyze-ethercan-pcap /home/robo/usbcan-snapshots/YYYYMMDD-HHMMSS --top 50
```

第一次分析建议不要指定 Bus、Device 或 Endpoint，先根据报告确认设备位置，再按需
添加 `--bus`、`--device` 或 `--endpoint` 过滤条件。

## 文件索引

### 七个维度

| 文件 | 维度 | 输出文件 |
|---|---|---|
| `dimensions/01_bms_status.sh` | BMS/电源状态 | `bms-status.txt` |
| `dimensions/02_can_details.sh` | CAN 状态和统计 | `can-details.jsonl` |
| `dimensions/03_kernel_dmesg.sh` | 内核动态日志 | `dmesg-live.txt` |
| `dimensions/04_hpm_uart.sh` | HPM `ttyS4` 日志 | `hpm-uart-live.txt` |
| `dimensions/05_usb_pcap.sh` | USB-CAN 原始抓包 | `usbcan.pcap*` |
| `dimensions/06_can_asc.sh` | CAN 原始记录；显式离线转换 ASC | `can.log`，按需生成 `can.asc` |
| `dimensions/07_inference_screen.sh` | inference screen 输出 | `inference-session.txt` |

### 采集和分析

| 文件 | 作用 |
|---|---|
| `capture/capture_seven_dimensions.sh` | 七维同步采集编排 |
| `capture/capture_usbcan_ring.sh` | USB-CAN 循环抓包实现 |
| `capture/capture_hpm_uart.sh` | HPM 原始串口读取实现 |
| `bin/save_usbcan_snapshot.sh` | 保存七维故障快照、ZIP 和 SHA-256 |
| `bin/export_seven_dimensions.sh` | 分析、打包七维会话 |
| `bin/restart_can_interfaces.sh` | 重启四路 CAN，不修改 CAN 配置 |
| `bin/guard_sessions.py` | 每 20 秒清理旧会话，活动会话超过容量限制时请求轮转 |
| `bin/show_communication_dashboard.py` | 在线通信状态面板 |
| `analysis/analyze_seven_dimensions.py` | 七维日志按维度拆分为 CSV（`--merged` 出合并时间轴） |
| `analysis/analyze_usbcan_urb.py` | 分析 USB URB 状态和错误 |
| `analysis/analyze_usbcan_timeline.py` | 按时间窗口统计 USB 流量 |
| `analysis/analyze_usbcan_echo.py` | 检查 CAN TX echo context |
| `analysis/compare_usbcan_captures.py` | 对比 USB-CAN 抓包 |
| `analysis/extract_usbcan_error_windows.py` | 截取 USB 错误时间窗口 |
| `analysis/check_usbcan_snapshot.sh` | 检查快照文件完整性 |

### HPM 工具

| 文件 | 作用 |
|---|---|
| `bin/flash_hpm.sh` | 擦除并烧录 HPM 固件 |
| `bin/hpmtool.py` | HPM USB BootROM 工具 |
| `firmware/` | 随包提供的 HPM/EtherCANFD 固件 |

安装后的稳定命令包括 `robopi-seven-capture`、`robopi-seven-analyze`、
`robopi-seven-export`、`robopi-comm-status`、`usbcan-capture`、
`usbcan-debug-snapshot`、`hpm-log-capture`、`robopi-can-capture` 和
`robopi-can-restart`。HPM 自动复位由 `hpm-sreset.service` 在后台处理。

`bin/flash_hpm.sh` 在烧录前停止 `hpm-sreset.service`，烧录完成后重新启动它，
避免 HPM 进入 USB BootROM 时被监视器复位；可用 `HPM_RESET_SERVICE` 覆盖服务名。

源码目录职责：

```text
bin/         可直接执行的运维、烧录和导出命令
capture/     七维采集流程脚本
dimensions/  七个独立日志采集维度
analysis/    离线分析程序
tests/       测试脚本、样例抓包和分析结果
README.md     项目说明和使用文档
etc/         默认配置、systemd 单元和固件
```
