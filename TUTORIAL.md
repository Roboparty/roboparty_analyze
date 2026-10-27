# RoboPi 七维日志系统 · 使用教程

适用版本：roboparty-analyze 1.0.11 及以上（旧包名 robopi-analyze 的基础用法仍兼容）。

---

## 1. 这套系统是干什么的

机器人在现场出故障时,人往往不在场。这套系统在机器人上**持续记录七个层面的运行数据**,故障发生后把所有数据对齐到同一根时间轴上,回答那个最关键的问题:

> **到底是谁先出问题的?**

七个维度,从物理层到应用层:

| # | 维度 | 记录什么 | 输出文件 |
|---|---|---|---|
| ① | BMS 电源 | 电压、电流、电量、电源状态(每秒一条) | `bms-status.txt` |
| ② | CAN 接口状态 | 各路 CAN 的收发计数、错误计数(每秒一条) | `can-details.jsonl` |
| ③ | 内核日志 | 驱动、USB、设备重置事件 | `dmesg-live.txt` |
| ④ | HPM 串口 | 主控固件日志 | `hpm-uart-live.txt` |
| ⑤ | USB 原始抓包 | USB-CAN 物理层通信(环形缓冲) | `usbcan.pcap*` |
| ⑥ | CAN 报文 | 四路电机总线的报文 | `can.log` + `can.asc` |
| ⑦ | 推理输出 | inference 程序的屏幕输出 | `inference-session.txt` |

---

## 2. 开机后会发生什么(无需任何操作)

机器人开机后,采集服务自动启动,并创建一个带时间戳的**会话目录**:

```
/home/robo/robopi-logs/seven-20260917-091256/
```

七个维度同时开始往这个目录里写数据。**不需要敲任何命令。**

同时:

- USB 抓包写入内存环形区 `/run/usbcan`(最多 8×64 MB,自动滚动覆盖);
- 启动前及每 20 秒清理旧会话，默认保留 7 天内、总量目标 6000 MiB，始终保护当前会话;
- 活动会话达到 1024 MiB 或运行 1800 秒时轮转，不停止机器人控制;
- 启动前检查磁盘空间,不够会明确报错,不会写出一堆空文件;
- 会话的 `manifest.json` 里记录了本次开机的 boot id 和主板序列号。

---

## 3. 日常使用:三条命令

### 看一眼系统状态

```bash
sudo robopi-comm-status
```

终端实时面板:CAN 接口状态、环形抓包情况、HPM 最近日志。按 `Ctrl-C` 退出(不影响采集)。

### 结束一次采集(生成完整产物)

```bash
sudo systemctl stop usbcan-capture
```

**停止时自动完成三件事:**

1. `can.log` 转换成 `can.asc`(Vector ASC 格式,可用专业工具打开);
2. 把环形区里的 USB 抓包复制进会话目录;
3. 在 `manifest.json` 里补上结束时间。

> **注意**:`can.asc` 和 `usbcan.pcap*` **只在停止后才会出现**。采集期间它们是空的,这是设计如此,不是故障。

### 重新开始采集

```bash
sudo systemctl start usbcan-capture
```

会创建一个**新的**会话目录。

---

## 4. 会话目录里有什么

```
/home/robo/robopi-logs/seven-20260917-091256/
├── manifest.json          会话信息:起止时间、boot id、主板序列号
├── bms-status.txt         ① 电压/电流/电量,每秒一条
├── can-details.jsonl      ② CAN 接口统计
├── dmesg-live.txt         ③ 内核日志(只含采集期间的)
├── hpm-uart-live.txt      ④ HPM 固件日志
├── usbcan.pcap0~7         ⑤ USB 抓包(停止后出现)
├── can.log                ⑥ CAN 报文原始格式
├── can.asc                ⑥ CAN 报文 Vector ASC 格式(停止后出现)
└── inference-session.txt  ⑦ 推理程序输出
```

**这个目录就是完整现场,整个目录都要保存,不要只挑其中的文件。**

---

## 5. 分析日志

```bash
robopi-seven-analyze /home/robo/robopi-logs/seven-20260917-091256
```

在会话目录里按维度生成 CSV 文件(没有数据的维度不生成文件),外加 `summary.json`:

| 文件 | 内容 |
|---|---|
| `can_frames.csv` | **核心产出**:can0~can3 每帧一行,`interface`/`frame` 分列(原生总线如 can_hipnuc 已过滤) |
| `bms.csv` | 电压/电流/SoC/功率,数值为独立列 |
| `dmesg.csv` | 内核日志 |
| `hpm_uart.csv` | HPM 串口日志 |
| `thermal.csv` | 温度记录 |
| `inference.csv` | inference screen 会话日志 |
| `can_details.csv` | CAN 接口状态快照 |
| `usb_pcap.csv` | 每个 pcap 的首/末包时间 |
| `summary.json` | 各维度事件数,以及维度→文件→行数的映射(`outputs` 字段) |

输出示例:

```
bms.csv: 187 rows
can_frames.csv: 31204 rows
can_details.csv: 214 rows
dmesg.csv: 2 rows
hpm_uart.csv: 218 rows
events: 31829
{"bms": 187, "can-asc": 31204, "can-details": 214, "dmesg": 2, "hpm-uart": 218, "session": 2, "usb-pcap": 2}
```

**最后的 JSON 是体检报告**:每个维度贡献了多少条事件。任何一维的原始文件有数据、但这里显示 0,说明该维度的解析出了问题。

所有 CSV 共享同一 Unix 时间轴,需要交叉对照时按 `timestamp` 列合并即可。要旧的合并时间轴,加 `--merged` 生成 `timeline.csv`(可达几十万行,**不要用 cat 打开**,用 `head`、`grep`,或拷到电脑上用 Excel 打开)。

---

## 6. 导出归档

把一个会话打包成带校验的压缩包,用于存档或发给其他人分析:

```bash
robopi-seven-export /home/robo/robopi-logs/seven-20260917-091256 \
    /home/robo/robopi-logs/seven-20260917-091256.zip
```

产出:

```
seven-xxx.zip           整个会话(内含逐文件校验和 files.sha256)
seven-xxx.zip.sha256    压缩包的校验和
```

接收方验证完整性:

```bash
sha256sum -c seven-xxx.zip.sha256     # 应输出 OK
```

---

## 7. 下电前的操作(重要)

**直接断电会丢数据**:环形抓包在内存里,断电即失;`can.asc` 也不会生成(收尾动作没跑)。

正确流程:

```bash
sudo systemctl stop usbcan-capture
sync
# 然后再断电
```

来不及正常停止时(机器人即将故障下电),用紧急快照:

```bash
sudo usbcan-debug-snapshot
sync
```

它会暂停采集几秒钟,把环形区抢救到 `/home/robo/usbcan-snapshots/`(持久存储),打包成 zip + sha256,然后自动恢复采集。

---

## 8. 常见问题

### 怎么确认采集在正常跑?

三层检查,缺一不可:

```bash
# ① 服务在跑吗
systemctl is-active usbcan-capture

# ② 维度进程都在吗(应有 6~7 个)
pgrep -af "dimensions/|candump|tcpdump"

# ③ 数据在增长吗
watch -n 3 "ls -l /home/robo/robopi-logs/seven-*/"
```

> 服务显示 active 不代表数据在写 —— 一定看第 ③ 条。

### can.asc 是 0,是不是坏了?

先看 `can.log`:

- `can.log` 也是 0 → 采集期间四路电机总线上没有报文(机器人没在跑控制),正常;
- `can.log` 有数据、`can.asc` 是 0 → 还没执行停止,执行 `systemctl stop` 后再 看。

### can.log 里有 can_top / can_hipnuc 的帧,正常吗?

正常。采集监听所有 CAN 接口,`can.log` 会包含原生三路的帧(主要是 IMU)。
**`can.asc` 只包含电机四路 can0~can3**,转换时原生接口已被过滤,时间轴分析也同样只统计四路。

### 磁盘会满吗?

三层防护:

1. 会话写在 `/home/robo/robopi-logs`(29 GB 分区);
2. 每次启动前检查剩余空间,不足则明确报错;
3. `robopi-session-guard.timer` 每 20 秒清理旧会话（默认 7 天 / 6000 MiB），活动会话达到 1024 MiB 时请求轮转，另有 1800 秒轮转。

配置在 `/etc/default/usbcan-capture`。这些是软上限：活动会话不会被删除，检查间隔及退出转换期间可能暂时超出预算；轮转也会有采集空窗。USB pcap 的 8×64 MB 上限只约束环形抓包，不等于全部 CAN 日志的上限。增量 ASC 每批最多读取 16 MiB 原始日志，避免转换落后时生成巨大的临时副本。

### bms-status.txt 是空的?

检查 BMS 服务:`systemctl status bms.service`。bms_daemon 没跑时没有数据来源。

### inference-session.txt 是空的?

要么推理程序没在 `inference_session` 这个 screen 会话里跑,要么它没输出。
采集会持续 15 分钟反复尝试挂载,推理晚启动也能接上。

---

## 9. 配置参考

配置文件:`/etc/default/usbcan-capture`(改完 `systemctl restart usbcan-capture` 生效)。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `SESSION_ROOT` | `/home/robo/robopi-logs` | 会话目录(放在大分区) |
| `SESSION_RETENTION_DAYS` | `7` | 会话保留天数 |
| `SESSION_RETENTION_COUNT` | `10` | 每个目录保留的会话数 |
| `USBCAN_CAN_WAIT_SECS` | `120` | 等待 CAN 接口就绪的最长秒数 |
| `CAN_INTERFACE` | `can3` | 用于定位 USB 总线的 CAN 接口 |
| `FILE_SIZE_MB` / `FILE_COUNT` | `64` / `8` | 环形抓包的单文件大小和个数 |
| `INFERENCE_SCREEN_SESSION` | `inference_session` | 要挂载的 screen 会话名 |

---

## 10. 命令速查表

| 想做什么 | 命令 |
|---|---|
| 看实时状态面板 | `sudo robopi-comm-status` |
| 停止采集(生成 can.asc 和 pcap) | `sudo systemctl stop usbcan-capture` |
| 开始采集 | `sudo systemctl start usbcan-capture` |
| 看采集服务的日志 | `sudo journalctl -fu usbcan-capture` |
| 分析一个会话 | `robopi-seven-analyze <会话目录>` |
| 打包导出 | `robopi-seven-export <会话目录> <输出.zip>` |
| 紧急快照(下电前) | `sudo usbcan-debug-snapshot` |
| 重启四路 CAN | `sudo robopi-can-restart` |
| 确认数据在增长 | `watch -n 3 "ls -l /home/robo/robopi-logs/seven-*/"` |

---

## 11. 一图记住整个流程

```
开机 ──► 自动开始记录(无需操作)
  │
  ├── 平时:不用管,数据持续写入 /home/robo/robopi-logs/seven-<时间戳>/
  │
  ├── 想看状态:sudo robopi-comm-status
  │
  ├── 想要 can.asc / pcap:sudo systemctl stop usbcan-capture
  │
  ├── 想分析:robopi-seven-analyze <会话目录>
  │
  ├── 想存档:robopi-seven-export <会话目录> <输出.zip>
  │
  └── 要断电:先 stop(或 usbcan-debug-snapshot)→ sync → 再断
```
