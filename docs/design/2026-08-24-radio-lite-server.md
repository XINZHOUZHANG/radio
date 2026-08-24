# Radio Lite Server 设计规格

**状态：** 已确认，进入实现

**日期：** 2026-08-24
**目标系统：** Debian 13 + 原生 SwiftUI iOS 客户端

## 1. 目标

Radio Lite Server 是一个独立于 TX-5DR 的低带宽远程电台服务端。它不重新实现
无线电底层，而是把成熟组件组合成一个安全、可恢复、适合弱网的控制面：

- Hamlib `rigctld`：CAT、PTT、机内天调与不同电台机型；
- `wsjtx-lib` 原生工作进程：FT8/FT4 解码、编码与时隙调度；
- ALSA/PulseAudio/RtAudio：音频设备；
- Opus：双向语音压缩；
- FFT：低分辨率频谱；
- ADIF：服务端通联日志。

第一版不依赖 TX-5DR、不使用 SQLite、不支持外置天调，也不接 LoTW、eQSL、
QRZ 或 Club Log。已有 TX-5DR 部署和 iOS 适配器在迁移完成前保留，便于对照和
回退。

## 2. 总体结构

TypeScript 主进程负责认证、配置、控制权、协议、状态机和日志；耗时或原生任务在
独立工作进程中运行。任一工作进程退出都不能令主进程失去撤销 PTT 的能力。

```text
iOS / Web
    |
    | HTTPS/WSS，一个可配置端口
    +-- /api/v1/*          账户、配对、配置、日志
    +-- /ws/control        精简 JSON 状态与命令
    +-- /ws/media          二进制音频与频谱
                |
        Radio Lite Server (TypeScript)
          |       |        |         |
       rigctld  audio     wsjtx     ADIF
        每台一份  worker    worker   单一日志文件
```

控制与媒体是两条独立 WebSocket，但使用同一个 TCP 监听端口。控制拥塞不能阻塞
音频，频谱丢帧也不能阻塞 PTT 心跳。

## 3. 多电台模型

每台电台拥有独立的：

- `rigctld` 连接或受管本地 `rigctld` 进程；
- 输入/输出音频设备；
- 控制权租约和发射状态机；
- 频谱订阅；
- FT8/FT4 解码器、呼叫队列与自动 QSO 状态；
- 台站呼号、网格和日志标识。

不同用户可以同时操作不同电台。同一台电台在同一时间只有一个控制者；管理员可
显式接管，接管前服务端先撤销旧控制者的发射和媒体上行。

### 3.1 iOS 配置向导

用户不需要手写 Hamlib 参数。向导按以下步骤工作：

1. 从服务端内置的 Hamlib 机型目录选择厂商和机型；
2. 选择自动发现的 `/dev/serial/by-id/*` 串口，或选择网络 `rigctld`；
3. 选择已发现的音频输入和输出；
4. 执行只读连接测试，显示频率、模式和能力；
5. 在单独确认“允许真实发射”后保存配置。

内置目录只保存便于使用的默认值，实际能力始终以连接后 Hamlib 报告为准。支持
“高级设置”覆盖波特率、数据位、停止位、握手和 rigctld 端口，但普通配置不展示
这些字段。

### 3.2 首批内置机型

- Hamlib Dummy（仅模拟测试，模型 1）；
- Yaesu FT-710、FT-DX10、FT-991A；
- Icom IC-7300、IC-7610、IC-705；
- Kenwood TS-590SG、TS-890S；
- Elecraft K3/K4；
- FlexRadio 6xxx（网络 Hamlib/SmartSDR 桥接模式）。

目录可随版本更新，也允许管理员输入 Hamlib model ID 以使用未内置机型。

## 4. 发射安全与互锁

每台电台的发射状态只能是以下之一：

```text
idle -> voice | digital | tuning -> idle
  \--------------------------------> fault
```

`voice`、`digital` 和 `tuning` 互斥。FT8 发射期间拒绝语音 PTT；语音 PTT 期间暂停
自动 QSO 发射；机内天调期间拒绝音频上行和数字发射。

- PTT 客户端每 2 秒发送心跳；8 秒未收到有效心跳立即 PTT OFF；
- 单次语音连续发射最长 180 秒；
- 机内调谐默认最长 30 秒；
- 控制 WebSocket 断开、账户撤销、应用进入后台、Hamlib 异常、音频上行异常、
  进程退出或服务器关机都先执行 PTT OFF；
- 服务启动时、连接每台电台后和恢复故障前都主动写入 PTT OFF；
- 只有配置中显式启用 `hardwareTxEnabled` 的真实电台可以发射；Dummy 永远只模拟；
- 权限只是安全条件之一，不能绕过互锁、租约、时限和设备能力检查。

机内天调通过 Hamlib 暴露的电台功能调用；若目标机型未报告支持，则 iOS 隐藏按钮，
服务端仍会拒绝伪造的请求。

## 5. 低带宽协议

### 5.1 控制通道

控制通道使用事件驱动 JSON。首次连接发送完整快照，之后只发送带单调 revision 的
字段变化。客户端发现 revision 缺口时请求一次新快照，不采用固定高频全量轮询。

典型消息：

```json
{"t":"rig.patch","r":"main","v":42,"d":{"frequencyHz":14074000}}
```

短字段名只用于线上信封；公共 TypeScript/Swift 模型使用完整可读字段名。命令都带
客户端生成的 `commandId`，重连重试不会重复执行 PTT、调谐或 FT8 入队。

### 5.2 媒体通道

媒体帧采用固定二进制头：

```text
version:u8 | kind:u8 | flags:u8 | radio:u8 | sequence:u32 | timestamp:u64 | payload
```

`kind` 区分 Opus 下行、Opus 上行、频谱和统计。未知版本或长度不匹配立即丢弃。

- 语音默认 Opus mono 16 kHz、约 20 kbit/s；
- 弱网可降至 12 kbit/s，局域网可升至 32 kbit/s；
- 使用 20 ms 包和小型抖动缓冲，不积压陈旧音频；
- 频谱默认 512 个 `UInt8` 点、5 FPS；
- iOS 页面不可见或应用进入后台时取消频谱订阅；
- 网络拥塞时先降频谱 FPS/点数，再降音频码率，绝不延迟控制/PTT 心跳。

默认音频加频谱目标流量为约 25–32 MB/小时，而不是旧网页协议约 450 MB/小时。

## 6. FT8/FT4

服务端完成采样、解码、编码、发射时隙和 QSO 状态机，iOS 只展示及下达操作意图。

- 支持 FT8 与 FT4；
- 解码结果使用稳定 ID 去重，同一周期结束后批量提交；
- iOS 列表不会因每条解码刷新而跳动；用户触摸或选中时冻结排序，新周期到达显示
  “有新解码”而不抢走选择；
- 支持手动呼叫、回复、呼叫队列、跳过、移除和停止；
- 自动 QSO 状态包括呼叫、报告、R 报告、RR73/73、完成、超时和失败；
- 发射由服务端对齐 UTC 时隙，iOS 延迟不参与时序；
- 自动 QSO 仍受控制权、发射权限、互锁与硬件 TX 开关约束；
- 成功完成后以稳定 QSO ID 自动写入 ADIF，重试不会重复记账。

## 7. 日志

日志保存在：

```text
/var/lib/radio-lite/logbook/station.adi
```

FT8/FT4 成功完成后自动记录，语音通联由 iOS 手动提交。使用标准 ADIF 字段
`OPERATOR`、`STATION_CALLSIGN`、`MY_GRIDSQUARE`，并用
`APP_RADIOLITE_RADIO_ID` 与 `APP_RADIOLITE_QSO_ID` 区分电台和防重。

服务启动时流式读取 ADIF，建立轻量内存索引。追加前校验字段并在锁内写入；定期做
原子备份。损坏的尾部记录被隔离到 `.recovery`，前面的有效 QSO 仍可读取。API 支持
筛选、分页、网格聚合、ADIF 导入与导出。日志文件始终是用户可直接复制的明文。

## 8. 账户、配对与传输安全

仅有 `admin` 和 `operator` 两种角色，没有观察员。管理员可以管理账户及发射权限；
操作员可控制电台，只有 `canTransmit=true` 才能发射。

- 用户名和密码登录；
- 密码使用 Argon2id PHC 字符串，账户写入权限为 0600 的 `users.json`；
- 首次启动在终端显示一次性 6 位初始化码，有效 10 分钟；
- 已登录管理员生成单次使用的 6 位设备配对码，有效 2 分钟；
- 配对成功返回高熵设备凭证，iOS 保存到 Keychain；6 位码不是长期令牌；
- 设备凭证可单独撤销，账户禁用会撤销该账户的所有控制权和 PTT；
- `audit.jsonl` 追加记录登录、配对、PTT、调谐、接管和账户操作，不记录密码、
  配对码或令牌；
- JSON 数据通过临时文件、`fsync` 和同目录原子替换保存，并保留上一版备份。

公网模式要求 HTTPS/WSS。为兼容 Tailscale 或可信局域网，可由管理员显式启用
HTTP/WS；iOS 配置页必须明确显示“不加密连接”，不能把 HTTP 自动改写为 HTTPS。
服务默认监听一个可配置端口；改端口后重启生效，不做自动轮换。

## 9. 故障恢复

| 故障 | 服务端行为 | 客户端行为 |
|---|---|---|
| 控制连接断开 | 立即撤销控制租约并 PTT OFF | 指数退避重连，禁止本地 PTT |
| 媒体连接断开 | 停止音频上行；若正在语音发射则 PTT OFF | 清空抖动缓冲后重连 |
| `rigctld` 退出 | PTT OFF、标记 fault、有限次数重启 | 显示设备故障，不乐观更新 |
| 声卡拔出 | 停止相关 worker；发射时 PTT OFF | 提示重新选择设备 |
| FT8 worker 退出 | 取消数字发射与队列当前任务 | 保留队列并标记暂停 |
| ADIF 尾部损坏 | 隔离损坏尾部并从备份恢复索引 | 日志只读并提示管理员 |
| 服务器重启 | 启动先 PTT OFF，不恢复发射/控制租约 | 重新认证和获取快照 |

所有自动重启都有退避和上限，避免坏设备导致重启风暴。恢复后必须重新获得控制权，
不会自动继续之前的 PTT、调谐或 FT8 发射。

## 10. Debian 13 部署

采用原生 systemd 服务而不是强制 Docker：

- `/opt/radio-lite/`：只读应用和版本目录；
- `/etc/radio-lite/config.json`：监听与全局配置；
- `/var/lib/radio-lite/`：账户、设备、审计和 ADIF；
- `/var/log/radio-lite/`：可轮转运行日志；
- `radio-lite.service`：低权限专用用户，按需加入 `dialout` 与 `audio` 组。

Hamlib、ALSA/PulseAudio、Opus 和 DSP 动态库由 Debian 包管理器提供，不复制进应用
包。升级使用版本目录加 `current` 符号链接；切换前备份配置和日志，健康检查失败时
回滚旧版本。卸载程序不删除 `/var/lib/radio-lite`。

## 11. iOS 迁移

连接配置增加协议类型 `TX-5DR` 与 `Radio Lite`。在 Radio Lite 完成真实设备验收前，
现有 TX-5DR 配置、Keychain 凭证和功能保持不变。

Radio Lite 适配器分阶段接入：

1. 配对、登录、发现和电台向导；
2. CAT、控制权、PTT、机内天调；
3. Opus 音频与低带宽频谱；
4. FT8/FT4、队列和自动 QSO；
5. ADIF 日志和网格地图；
6. 完整弱网及后台生命周期验收。

iOS 在 PTT 松开、应用退后台、音频中断或控制连接丢失时立即停止录音并释放
`AVAudioSession`，避免此前出现的后台麦克风持续运行和发热。

## 12. 验收标准

- Dummy 模式可连续运行 24 小时，无失控 PTT、无持续内存增长；
- 拔网、杀客户端、杀媒体 worker、杀 `rigctld` 均在 8 秒内确认 PTT OFF；
- 两台模拟电台可由两个账户同时独立操作；同台控制权互斥；
- 5 分钟级高延迟连接仍可登录和恢复，PTT 心跳使用独立优先通道；
- 默认音频加频谱小于 35 MB/小时；
- FT8/FT4 连续 100 个时隙无错时隙发射，完成日志无重复；
- iOS 松开 PTT 后麦克风指示和音频会话立即结束；
- 配置、账户和 ADIF 在进程崩溃模拟后仍可恢复；
- 真实电台测试必须先通过 Dummy 全套测试，并由管理员单独开启硬件发射。

## 13. 实施顺序

1. TypeScript 工程、配置格式、内置机型、设备发现和多电台注册表；
2. 用户 JSON、Argon2id、6 位初始化/配对、审计；
3. 控制 WebSocket、租约、PTT/机内天调互锁与 Dummy；
4. Opus 媒体协议、频谱和弱网自适应；
5. FT8/FT4 worker、队列、自动 QSO；
6. ADIF 日志、网格 API；
7. SwiftUI Radio Lite 适配器和完整验收；
8. Debian 13 systemd 安装、升级与回滚。
