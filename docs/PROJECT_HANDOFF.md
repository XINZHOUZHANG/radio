# Radio Lite 项目交接说明

> 面向后续接手者的工作入口。本文记录的是代码库证据，不替代真实电台、Debian
> 主机或 iPhone 的现场检查。
>
> **实现快照：** `153d0f127302e05f15d8cd4b277a1a07635fbda7`<br>
> **iOS：** `0.2.6`（Build `17`）<br>
> **服务端包：** `@remote-radio/radio-lite-server` `0.1.0`<br>
> **协议：** `radio-lite.v1`

## 1. 项目目标

Radio Lite 是一个面向弱网、局域网、原生 IPv6 与 Tailscale 使用场景的远程电台
系统。目标是以 Debian 服务端和原生 iOS 客户端组合出一个安全、低带宽、可恢复的
远程操作链路：

- 通过 Hamlib/`rigctld` 完成 CAT、频率、模式、PTT、遥测和机内天调；
- 通过 Opus 提供双向语音，媒体和控制相互隔离；
- 在服务端运行 WSJT-X 工作进程，提供 FT8/FT4 解码、发射时隙、呼叫队列和自动
  QSO；
- 用 ADIF 保存通联日志；
- 以设备配对、控制租约、严格 PTT 读回和硬时限保护真实电台。

它不是 SDR 全带宽频谱项目，也不应把音频 FFT 呈现成电台的真实 IF/IQ
panadapter。历史 Python `server/` 与静态 `web/` 页面仅供比较；当前产品栈是
`radio-lite-server/` 与 `ios/RadioLite/`。

## 2. 先读什么

1. 根目录 [`AGENTS.md`](../AGENTS.md)：GitHub、SSH 和 Debian 的硬约束。
2. [`README.md`](../README.md)：产品概览与组件边界。
3. [`radio-lite-server/PROTOCOL.md`](../radio-lite-server/PROTOCOL.md)：HTTP、
   `/ws/control`、`/ws/media` 与二进制媒体契约。
4. [`docs/design/2026-08-24-radio-lite-server.md`](design/2026-08-24-radio-lite-server.md)：
   设计目标、发射安全模型和部署目标布局。
5. `docs/superpowers/specs/` 与 `docs/superpowers/plans/`：设计及计划记录。它们
   不是“已经完成”的证明；应以代码、测试、CI 和现场证据为准。

## 3. 当前架构

```text
iOS Radio Lite
  ├─ HTTP API             登录、配对、配置、日志、只读硬件预检
  ├─ /ws/control          控制租约、状态、遥测、安全事件、PTT/调谐意图
  └─ /ws/media            Opus 音频、频谱、网络策略
          │
          ▼
Radio Lite Server（TypeScript / Node 24.7+）
  ├─ 每台电台的 RadioRuntime + TransmitInterlock
  ├─ Hamlib / rigctld     CAT、PTT、机内天调、能力与仪表
  ├─ 系统音频 + Opus      语音、频谱、数字模式音频
  ├─ WSJT-X worker        FT8/FT4 解码、编码、时隙与自动 QSO
  └─ 原子文件存储         用户、设备、radio profile、审计、ADIF
```

### 主要入口

| 区域 | 入口或核心文件 | 职责 |
| --- | --- | --- |
| 服务端启动 | `radio-lite-server/src/index.ts` | 读取运行参数、初始化服务、处理进程关停信号。 |
| HTTP / WebSocket | `radio-lite-server/src/server/radio-lite-service.ts` | API、认证、`/healthz`、控制和媒体通道。 |
| 每台电台运行时 | `radio-lite-server/src/rig/radio-runtime.ts` | 控制租约、遥测、调谐完成检测和运行时生命周期。 |
| 发射安全 | `radio-lite-server/src/safety/transmit-interlock.ts` | voice / digital / tuning 的互斥、硬时限、de-key 与读回。 |
| Hamlib | `radio-lite-server/src/rig/hamlib-*.ts` | 受管或外部 `rigctld`、能力和 CAT 命令。 |
| 媒体 | `radio-lite-server/src/media/` | 系统音频、Opus、频谱、背压与弱网策略。 |
| 数字模式 | `radio-lite-server/src/digital/` | FT8/FT4 worker、解码批次、队列和自动 QSO。 |
| iOS 会话 | `ios/RadioLite/Core/RadioLite/RadioLiteSession.swift` | 登录、恢复、选台和连接生命周期。 |
| iOS 音频 | `ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift` | Opus、播放队列、录音与本地音频生命周期。 |
| iOS 界面 | `ios/RadioLite/Features/RadioLite/` | 电台控制、FT8、日志、设置和硬件配置。 |

## 4. 不可破坏的安全边界

下面的规则比“多一个功能”优先级更高。修改任何相关代码前，应先新增或保留能证明
该规则的测试。

- 一台电台同一时刻只能处于 `idle`、`voice`、`digital`、`tuning` 或故障状态；
  后三种发射相关状态互斥。
- 真实硬件必须显式 `hardwareTxEnabled=true`；Hamlib Dummy 永远只能模拟，不能成为
  真实发射的绕过路径。
- PTT OFF 必须有读回确认。发送“关闭”命令不是成功的证据。
- 连接断开、心跳超时、媒体/worker 故障、进程关停和硬时限到达都必须优先走
  de-key；不得削弱这条路径或用乐观 UI 代替确认。
- tuning 的 30 秒硬限时是 fail-safe 兜底，不能延长、移除或以普通完成路径取代。
  正常调谐由 PTT 连续两次读到 OFF 提前释放租约。
- 当前天调代码将“持久开关”和“一次性调谐动作”分开，并避免在普通收尾路径撤销
  持久开关。这是当前实现意图，不是 FT-710 CAT 语义的真机证明；任何直接 CAT
  映射必须先补齐真机记录后再写入安全规则。
- 控制与媒体通道必须保持隔离；音频或频谱拥塞不能阻塞控制、心跳或 PTT OFF。
- 硬件预检只能进行只读 CAT、能力和音频查询；它不能保存 profile、获得控制权或
  触发发射。

任何 FT-710 能力主张均应以版本化的真机记录为依据。当前工作树中没有
`docs/hardware-truth-FT710.txt`，因此不要把 Hamlib 版本、文档或其他项目的命令表
写成“已经在本机验证”的事实。

## 5. 开发过程与已完成的里程碑

项目采用“先安全底座、再媒体与数字模式、最后 iOS 体验”的路线。以下列的是有
代码提交支撑的近期里程碑，不是完整功能承诺。

| 时间 / 提交 | 已完成内容 |
| --- | --- |
| 2026-09-01 `2b128ab` | 天调启动移除了“未通告即跳过”的 discovery gate，先尝试持久天调开关再触发一次性调谐；目标电台的实际 CAT 结果仍待真机记录确认。 |
| 2026-09-01 `aa35a40` | 服务关停在 de-key 后主动收尾 HTTP 连接，降低 keep-alive 导致的长时间关闭风险。 |
| 2026-09-01 `a25227b` 至 `4d69325` | 调谐完成检测、一次性调谐交互、租约提前释放和停止路径调整。30 秒硬限时仍保留。 |
| 2026-09-01 `f2a29d6` | 引入 CI 测试超时脚本与 IPA Release 发布流程；当前 workflow 的门禁缺口见第 8、9 节。 |
| 2026-09-02 `348feea`、`c6dc83a`、`2eb0f54` | FT8 解码/时隙顺序与重试修复，以及更密集的 iOS 解码列表。 |
| 2026-09-02 `153d0f1` | iOS 接收音频播放队列改为在设备实际播放后完成计数，限制本地 AVAudioPlayerNode 积压。 |

### 最新音频修复的范围

`153d0f1` 只改动：

- `ios/RadioLite/Core/RadioLite/RadioLiteAudioEngine.swift`
- `ios/RadioLiteTests/AudioRuntimePolicyTests.swift`

此前默认 completion 回调属于 `dataConsumed` 语义，队列可能在扬声器实际播放前就
减计数；快速持续接收时，播放器内部可能积压出秒级延迟。现在接收队列使用
`.dataPlayedBack`，现有 3 帧预缓冲、12 帧上限、满队列恢复和 generation 防护均未
改变。

这是一项本地播放队列修复，不等于已经证明 LAN、原生 IPv6 或 Tailscale 的端到端
延迟达标；仍需要 CI 和“仅接收”的 iPhone 实测。

## 6. 配置与数据边界

服务端由 `RADIO_LITE_DATA_DIR` 指定运行数据目录，开发默认值为 `./data`。典型持久
数据包括 `users.json`、`devices.json`、`radios.json`、`audit.jsonl` 和
`station-log.adif`。这些文件是用户数据，发布包、临时 staging 或源码切换不得覆盖。

iOS 长期凭据存放在 Keychain，地址和选择状态使用 UserDefaults。不要在 issue、日志、
交接文档或提交中泄露密码、Token、私钥、环境文件、具体 profile、声卡/串口名称或
PTT 配置。

设计中的 `/opt/radio-lite` 与 `/var/lib/radio-lite` 是目标布局；历史 Debian 机器曾
使用 `/opt/testradio`。二者不能互相替代为现场事实。接手部署前必须只读确认实际
服务、当前工作目录、Node 路径、监听端口、数据目录和硬件资源占用。

## 7. 本地开发与验证

### 环境

- 服务端需要 Node.js `24.7` 或更高版本；
- iOS 工程使用 Swift `5.9`、iOS `17.0`、XcodeGen；
- Debian 真实音频依赖系统提供的 ALSA/PulseAudio 工具和 `opus-tools`；
- 先用 Hamlib Dummy 和合成音频验证，再进入真实硬件预检。

### 推荐命令

```powershell
# 服务端：使用有超时保护的命令；不要直接跑 npm test
npm --prefix radio-lite-server run typecheck
npm --prefix radio-lite-server run test:ci

# iOS 与服务端协议契约（跨平台）
node scripts/check-ios-radio-lite-contract.mjs

# 控制面板契约
node scripts/check-radio-control-dashboard.mjs

# 所有改动提交前
git diff --check
```

Windows 不安装、不伪造 Xcode 验证。iOS 原生编译、XCTest 和 IPA 由 macOS / GitHub
Actions 负责；本地 macOS 的生成方式见 [`ios/README.md`](../ios/README.md)。

注意：根 README 与服务端 README 中仍有 `npm run check` / `npm test` 示例；当前
`.github/workflows/ios.yml` 的 `server-check` 也运行 `npm --prefix
radio-lite-server run check`，它会展开为无外层统一超时的 `npm test`。在无硬件或 CI
环境，优先使用上面的 `test:ci` / `check:ci` 组合。后续应单独统一 README 和 workflow，
但不要为了“变绿”放宽测试超时。

## 8. 当前验证状态

| 项目 | 状态 | 证据或限制 |
| --- | --- | --- |
| 最新 iOS 音频改动的范围检查 | 有限的历史证据 | `153d0f1` 提交前曾做 scoped `git diff --check` 和独立审查；这不验证本文件或完整工作树。 |
| 最新 Swift / XCTest | 待 CI | 当前 Windows 环境未安装且按约束未调用 Xcode。 |
| 真实 iPhone 接收延迟 | 待人工测试 | 只测接收；分别覆盖 LAN、原生 IPv6、Tailscale。 |
| FT-710 能力真值 | 缺失 | 未找到版本化的真机 capability snapshot。 |
| Debian 线上服务状态 | 未在本工作树确认 | 不要由设计文档或历史会话推断。 |
| 正式版本化部署 / 回滚脚本 | 未在当前树实现 | 相关 release/deployment 文档是计划，不是已交付机制。 |
| IPA 发布门禁 | 存在风险 | `unsigned-device-ipa` 当前没有依赖 `server-check`、`protocol-contract` 或 `xcode-build-and-test` 的 `needs:`，可能在其他 job 失败时仍发布 IPA。 |

## 9. 待解决问题与建议顺序

### P0：先完成验证与可恢复发布

1. 先修正 workflow：`server-check` 应使用有超时保护的 `check:ci`，且
   `unsigned-device-ipa` 应只在 `server-check`、`protocol-contract`、
   `web-check` 与 `xcode-build-and-test` 成功后才发布。修复前不得把 IPA 当作
   全部质量门禁已通过的发布物。
2. 对当前 HEAD 运行 GitHub iOS CI，确认 `server-check`、`protocol-contract`、
   `web-check`、`xcode-build-and-test` 与 `unsigned-device-ipa` 均成功；不无限等待或
   重复触发工作流。
3. 在 iPhone 上做“仅接收”连续音频测试，记录 LAN、原生 IPv6 和 Tailscale 下的
   初始延迟、持续运行后的延迟、丢帧与恢复行为。不得在此验收中发射。
4. 采集并提交 FT-710 的只读 Hamlib 能力真值，例如 `set_func ?`、`get_func ?`、
   `vfo_op ?`、`get_level ?` 与版本信息。保留空输出，不能用推断替代。
5. 建立受控 Debian 发布：版本目录、staging、健康检查、de-key 完成证明、原子
   `current` 切换和回滚。先验证安全停机，再考虑真实电台部署。

### P1：让低延迟与控制状态可观测

1. 把端到端音频延迟拆成 capture、编码、网络、解码、播放队列等可观测指标；新的
   `.dataPlayedBack` 修复只覆盖最后一段。
2. 为 CAT 轮询和用户命令明确优先级、deadline 与 revision，避免迟到的遥测覆盖
   新控制状态。
3. 为 S 表、PWR、ALC、SWR 标记来源、更新时间和“不可用”状态；先以本机实测校准，
   不要借用其他项目的数值表。
4. 统一 README、服务端 README 和 CI 推荐命令，消除无超时 `npm test` 示例。

### P2：扩展能力前先闭环现有设计

1. `IcomWlanDriver` 和部分网络/TCI 方向尚未形成完整的 profile → runtime → iOS →
   safety → preflight 链路；不要把依赖或设计稿当作产品支持。
2. SSTV / Radiofax / 图像模式目前主要是设计与计划，不是已交付端到端功能。
3. FT-710 的真实宽带频谱需要独立的硬件、驱动、资源互斥和安全验证；现有音频 FFT
   不应冒充真实 RF/IF scope。

## 10. 发布与仓库交接状态

当前开发分支为 `codex/public-dummy-web-integration`。相对于原远端的可见基线，
本地包含最新三次音频设计/计划/实现提交；不要把未经 CI 的本地提交宣称为已发布。

### 外部交接备注（2026-09-02，必须重新核验）

以下信息来自本次本地交接会话，不是当前 checkout 可自行验证的事实。执行任何发布
动作前必须重新做只读预检。

用户要求将完整项目迁移到 `Times1368/liteRadio` 的 `main`。当时使用现有严格主机
校验和项目部署密钥进行只读预检返回 `Repository not found`，因此：

- 没有向目标仓库推送；
- 没有 force push、没有覆盖 `main`、没有触发新的 Actions；
- 已在本开发机生成完整 Git 历史 bundle 作为恢复材料，但它不属于仓库内容。

恢复发布前，由仓库所有者确认目标仓库存在，并为当前受控 SSH 凭据提供写权限。
随后先只读确认目标 `main` 是否为空或是否为当前 HEAD 的祖先；只有不存在分叉且无需
覆盖历史时，才使用普通非强制推送：

```text
HEAD:refs/heads/main
```

如果目标 `main` 已有无关历史，停止并请仓库所有者选择保留、合并或重建；绝不使用
force push 解决分叉。

## 11. 接手检查清单

1. 确认当前路径、分支、HEAD 和 `git status --short`；`.superpowers/` 是本机未跟踪
   工作材料，除非明确采用，否则不应加入提交。
2. 先读本文件、`AGENTS.md`、README、PROTOCOL 与相关变更的 spec/plan。
3. 按变更范围运行最小、可重复的验证；不要因为一次 iOS 文案或 UI 改动而盲跑全套
   硬件相关测试。
4. 在没有真实设备和明确授权时，禁止 PTT、Tune、FT8/FT4、语音或其他射频写操作。
5. 在 Debian 上只将变更限制于授权目录；不触碰 `tx5dr.service`、持久 profile 或
   实际电台，除非任务明确授权。
6. 发布前固定完整 SHA、workflow / Run URL、IPA checksum 和 Debian 健康检查证据。
7. 每个独立变更单独提交；提交前检查 `git diff --check`，并将“代码事实”“CI
   事实”“真机事实”分别写清楚。

## 12. 维护原则

- 先测量再推断，尤其是 Hamlib、FT-710、声卡、串口、网络和 PTT 行为；
- 先保持 de-key 可信，再追求功能清单；
- 先闭合部署和回滚，再扩大机型、图像模式或频谱能力；
- 参考其他项目的架构可以，但不复制来源和许可证不清晰的代码；
- 将每次现场发现沉淀为可版本化的真值文件和回归测试，让下一位维护者不必重走
  同一轮排查。
