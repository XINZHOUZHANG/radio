# Radio Lite 发射安全、弱网可靠性与客户端修复设计

**日期：** 2026-08-26

**状态：** 用户已逐节确认，等待书面复核

**基线：** 分支 codex/public-dummy-web-integration，起始 HEAD 8e30116

## 1. 背景与目标

本设计合并处理以下两类工作：

- 当前实机测试发现的硬件预检 404、旧服务端 8 kHz 频谱帧、频谱显示宽度和
  iOS 弱网操作问题；
- 对仓库 HEAD 8e30116 的两份代码审查中，经当前代码逐条复核后仍然成立的
  发射安全、WebSocket、认证、审计、CI 和客户端问题。

目标不是恢复已经删除的旧客户端或旧协议，而是在唯一的 Radio Lite
TypeScript 服务端和原生 SwiftUI 客户端上完成安全收口。实现采用安全优先、
分批提交、最终统一发布的方式。

## 2. 已确认的产品决策

1. 当 Radio Lite 认为电台空闲，但 Hamlib 持续回读真实 PTT 为 ON 时，系统只告警
   和审计，不自动关闭可能由现场人员手动按下的 PTT。
2. 当 Radio Lite 自己发起过发射、停发失败、租约超时、媒体故障，或者用户明确点击
   紧急停止时，系统必须持续尝试 PTT OFF，直到 Hamlib 回读确认关闭。
3. 任何有效登录账户都可执行紧急停止，不要求当前控制租约、发射令牌或发射权限。
4. 账户仍只有管理员和操作员，不增加观察员。
5. 密码继续接受任意非空 Unicode 字符串，不增加长度或复杂度下限。暴力破解和
   Argon2 拒绝服务通过登录限速与并发闸处理。
6. 测试期继续允许用户明确输入 HTTP/Tailscale 地址，但界面常驻显示未加密警告。
7. 通联日志继续使用明文 ADIF；安全审计继续使用明文 JSONL，不引入 SQLite。
8. Debian 部署只允许改动 /opt/testradio，不得修改或删除该目录以外的任何文件。
9. GitHub 只使用仓库 SSH Deploy Key，不启动 gh 登录、OAuth 或设备授权。

## 3. 范围与非目标

本次包括：

- 服务端停发确认 latch、重试、故障告警和恢复；
- rigctld 运行期监督、CAT transport 优先级和关闭顺序；
- FT8/FT4 控制租约、语音音频断流看门狗和紧急停止；
- 真实 PTT 漂移检测、允许发射频率范围和可用时的 SWR 保护；
- WebSocket 保活、Origin、实时身份复核、连接限制和撤销；
- 登录和六位码限速、账户与设备管理、审计轮转；
- 强制硬件预检证明、能力协商和协议文档；
- iOS 停发确认、弱网超时、频率状态时序、频谱裁剪、告警和管理入口；
- 服务端 CI、Release 无签名 IPA、文档和部署回滚。

本次不包括：

- 恢复已删除的旧客户端、旧网页契约或任何旧品牌字符串；
- 重新启用历史 Python 服务端；
- 外置天调；
- 自动端口轮换；
- 公网 TLS 证书自动签发；
- 对 SIGKILL、断电或物理硬件失效作无法兑现的软件保证。

历史 Python 目录只作为对照资料。审查中的 Python B16/B17 不修改生产实现；
SAFETY 文档会明确其适用范围，避免把历史实现的能力误认为当前服务能力。

## 4. 总体架构

新增或收紧五个边界清晰的单元：

1. TransmitInterlock：只负责发射状态、租约、deadline、停发确认和故障 latch。
2. RigRuntimeSupervisor：负责 rigctld 生命周期、transport 故障、恢复调度和
   真实 PTT/SWR 低频监测。
3. SafetyEventHub：把安全状态广播给控制客户端并写审计，不参与硬件操作。
4. AuthenticationBoundary：负责 HTTP/WS 身份复核、撤销、限速和连接预算。
5. iOS presentation policies：用纯值模型投影发射横幅、频谱窗口、错误提示和
   状态修订，避免把安全逻辑散落在 SwiftUI 视图中。

控制、媒体和硬件操作继续使用现有协议与 worker 边界。只新增所需能力和消息，
不做无关的大规模文件重排。

## 5. 发射状态机

### 5.1 状态

每台电台保留 idle、voice、digital、tuning 和 fault 运行状态，并新增独立的
dekeyRequired 安全 latch。典型变化为：

    idle -> voice | digital | tuning
                  -> fault + dekeyRequired
                  -> idle + dekeyRequired=false

dekeyRequired 表示软件有责任确认关闭发射，但尚未得到 PTT OFF 回读。它独立于
当前租约和运行状态保存，因此租约被撤销或状态变为 fault 也不会让安全循环停止。
dekeyRequired 为 true 时一律禁止新发射。只有以下条件之一成立后才能清除：

- 自动恢复得到 PTT OFF 回读；
- 用户执行紧急停止并得到 PTT OFF 回读。

单纯清除错误文本不能解除故障。

### 5.2 停发恢复

正常停发先执行模式对应的 deactivate，再执行 emergencyOff，并回读 PTT。
任一步失败都进入 dekey_required：

- 首次立即重试；
- 后续退避，最大间隔两秒；
- 重试在服务存活期间不设总次数上限；
- 每次重试允许 transport 重新连接；
- 只有回读确认 OFF 才清除 latch；
- 恢复期间拒绝所有新的 voice、digital 和 tuning 起发。

连续失败只更新同一个持久安全事件，不制造重复弹窗。首次失败、原因变化、
恢复成功分别写审计。

### 5.3 外部 PTT

RigRuntimeSupervisor 以约 1 Hz、低优先级、单飞方式读取真实 PTT：

- Radio Lite 正常发射或调谐时，实际 ON 属于预期；
- Radio Lite 空闲且没有 dekey_required 时发现 ON，发布 external_ptt_observed；
- external_ptt_observed 不调用 PTT OFF，不抢夺现场人员控制；
- 回读变为 OFF 后发布 cleared；
- 用户明确点击紧急停止时，视为新的授权操作，可以尝试关闭该 PTT。

PTT 读取失败会产生 telemetry_uncertain 告警。若系统当前承担停发责任，
读取失败继续走 dekey_required；若系统空闲，仅告警。

## 6. rigctld、transport 与进程关闭

ManagedRigctldProcess 增加常驻 unexpected-exit 观察器。主动 close 不触发意外退出；
运行期退出会通知 RigRuntimeSupervisor：

- 系统正在发射时，立即进入 dekey_required；
- 以退避方式重启受管 rigctld；
- 恢复连接后优先执行 PTT OFF 并回读；
- 空闲时恢复后先读取 PTT，外部 ON 只告警。

RigctldTransport 使用安全优先与普通命令两级队列：

- PTT OFF、紧急停止和安全回读优先；
- 普通频率、模式、遥测和控件读取不得越过已排队的安全命令；
- 当前已卡住的普通命令无法真正抢占时，在短安全超时后断开 socket，使 OFF 成为
  重连后的第一条命令；
- PTT 安全命令使用比普通 10 秒更短的超时，并依赖恢复循环重试。

服务关闭顺序为：

1. 标记 closing，拒绝新 upgrade 和新控制命令；
2. 立即关闭所有 radio runtimes 并确认停发；
3. 停止 digital 和 media worker；
4. 关闭现有 WebSocket 与 HTTP listener；
5. 汇总所有清理失败并以非零状态退出。

SIGINT、SIGTERM、SIGHUP、uncaughtException 和 unhandledRejection 共用同一个幂等
关闭入口。异常路径记录原始原因，尝试安全关闭后 exit 1。SIGKILL 和断电明确列为
软件无法拦截的边界。

## 7. 控制租约、媒体和紧急停止

FT8/FT4 服务端的两秒 transmit heartbeat 只续当前 transmit lease，不得续
control lease。control lease 只能由真实客户端 control heartbeat 续期。
客户端消失后租约自然过期，安全循环停止当前发射并取消自动 QSO。

新增 tx.emergency-stop：

- 仅要求连接身份有效且账户未禁用；
- 不要求 control token、transmit token、canTransmit、hardwareTxEnabled 或网格；
- 先撤销 digital/voice/tuning 状态和媒体上行，再进入停发确认；
- 广播执行中、成功或未确认状态，并写审计；
- 幂等重复调用不会重新启动任何发射。

MediaHub 自动停发的非 InvalidLease 错误在写审计后必须重新抛出，使现有
ptt_stop_failed 通知真正可达。InvalidLease 只表示旧绑定已失效，不能作为物理
PTT 已关闭的证据。

语音上行绑定后记录最后一帧有效音频时间。超过可配置的短阈值，默认两秒，
即使控制心跳仍在继续也停止语音发射。持续收到有效音频时不误触发。

## 8. 频率范围与 SWR

真实电台 profile 增加明确的允许发射频率范围。App 提供常用业余频段预设和
自定义区间，但服务端只信任保存后的规范化范围。

- 新保存且 hardwareTxEnabled 为 true 的真实 profile 必须至少有一个允许范围；
- 起发前必须读取当前频率并落在允许范围内，读取失败时拒绝起发；
- 旧 profile 没有范围时仍可接收和控制，但起发返回 tx_safety_config_required；
- 配置页面明确提示补充范围，不静默改写现有文件。

SWR 策略为：

- Hamlib 报告可读 SWR 时，发射中低频采样；
- 默认 trip 3.0、reset 2.0，可在安全范围内配置；
- 超过 trip 立即进入停发恢复并锁定；
- 低于 reset 且 PTT OFF 后才允许清除；
- Hamlib 不支持 SWR 时，预检显示警告；
- 管理员必须选择 require_swr 或 acknowledged_internal_protection；
- require_swr 且无读数时拒绝发射，后者明确依赖电台机内保护。

遥测命令始终低于 PTT OFF 优先级，不得延迟停发。

## 9. 硬件预检与能力协商

健康接口保留 protocolVersion，并增加稳定 feature flags，例如：

- hardwarePreflight；
- preflightProof；
- emergencyStop；
- safetyAlerts；
- accountAdministration；
- spectrumDisplayWindow。

iOS 以 feature flags 判断能力。硬件测试端点 404 映射为
server_feature_unavailable，并提示“服务器版本过旧或反向代理路径错误”。
其他端点的 404 仍保持通用错误。

真实 profile 的只读预检成功后返回十分钟有效的 preflight proof。proof 使用
进程内随机 HMAC 密钥签名，并绑定：

- 管理员用户 ID；
- 规范化 profile 的稳定 SHA-256 指纹；
- 签发和过期时间；
- 预检通过状态。

proof 不落盘，服务重启后失效。保存真实 profile 时重新规范化并核对指纹。
型号、串口、网络 rigctld、PTT、音频或安全设置任何变化都会使 proof 无效。
Dummy profile 豁免。保存和预检均写安全审计。

## 10. WebSocket 与认证边界

HTTP 继续校验 Origin；WS upgrade 在 handleUpgrade 前使用相同规则：

- Cookie 认证的浏览器 WS 必须带匹配的 Origin；
- 原生 iOS 不带 Origin 且不带 Cookie，继续通过 auth.device 首帧认证；
- 反代的额外 Origin 必须显式配置，不能信任任意来源。

未认证 WS 窗口降为 15 秒，并增加全局及每来源 pending/active 连接上限。
服务端和 iOS 每 15 秒交换 ping/pong，连续两轮无响应即关闭连接、失败 pending
请求并进入现有重连流程。

每条具有权限影响的 WS 命令都重新确认：

- session/device 仍有效；
- 用户仍启用；
- auth revision、角色和 canTransmit 未变化。

登出、改密、账户禁用、权限变更或设备撤销时，先禁止新发射，随后停发和撤销媒体，
再关闭对应连接。紧急停发不因权限降低而被阻止。

secureCookies 通过显式部署设置启用。当前 HTTP/Tailscale 测试保持可用，但 iOS
设置页常驻显示“连接未加密”。不在本次测试阶段强制裸地址改为 HTTPS。

## 11. 登录、六位码与账户管理

密码策略保持任意非空 Unicode。UserStore 的 Argon2 验证从全局文件写入串行链中
拆出，受小型并发闸控制。验证完成后在签发会话前重新核对用户 auth revision，
避免改密竞态。

登录限制同时按：

- 规范化用户名加来源；
- 来源总体；
- 全局待处理 Argon2 数量。

响应统一使用 429 和 Retry-After，不泄露用户名是否存在。成功登录清除账户维度失败。

六位码修复 blockedUntil 被 failure window 提前清除的问题。只要仍在封禁期，
不得创建新 bucket。每个 code record 另有全局失败上限，达到上限立即作废，
防止多来源分布式猜测。

只有在管理员配置可信代理列表时才读取 Forwarded/X-Forwarded-For；默认使用
socket remoteAddress。

新增并文档化以下 API 与 iOS 管理入口：

- 用户创建、启用/禁用、角色和 canTransmit 修改；
- 自助改密；
- 配对设备列表、命名和撤销；
- 管理员审计分页查看；
- 当前会话登出及相应实时撤销。

仍不增加观察员角色。

## 12. 审计、错误与敏感信息

安全审计保持 JSONL，按 8 MB 轮转，最多保留五个文件（当前文件加四个历史文件）。
轮转与 append 使用同一串行边界，文件和目录权限保持现有安全设置。readNewest
从尾部读取有界数据，不把整个日志载入内存。

审计覆盖：

- 登录、登出、限速；
- 用户和权限变更；
- 配对码签发、兑换、设备 refresh 重放和撤销；
- profile 预检、保存和 hardwareTxEnabled 变化；
- PTT、天调、FT8/FT4、紧急停止和所有安全告警；
- rigctld 退出、恢复及停发确认。

传输开启采用“先写意图审计，成功键控后写结果”。意图审计失败则拒绝新发射。
紧急停发、权限降低和撤销永远不能被审计写入失败阻塞；这类失败另行 latch 告警。

删除基于错误消息正则的 400 映射。只有显式 ValidationError/HttpError 才能把安全
消息返回客户端，第三方和内部异常统一映射为固定 500。

非管理员读取 radio profile 时返回裁剪视图，不暴露串口路径、PTT 路径和原始音频
设备 ID。无效 Cookie 不回退 Bearer 的保守行为保持不变，因为自动回退会隐藏会话
配置错误并扩大凭证混用面。

首次初始化码仍可在服务日志显示，但文案改为明确说明 systemd/journald 可能保存该码，
不再声称“从不落盘”。码仍为短时、单次使用。

安全 timer 不再 unref，避免安全循环成为进程可被提前退出时忽略的资源。
MediaHub revokeOwner 重命名或增加明确注释，防止以后误认为它已经执行停发。

## 13. iOS 网络与状态一致性

网络策略拆分为：

- HTTP resource timeout：300 秒，并保留 waitsForConnectivity；
- 普通 WS 控制命令：15 秒；
- 停发和紧急停止：更短的发送/确认策略并允许有界重试。

WS 请求超时会断开陈旧 socket，失败全部 pending，并触发现有指数退避重连。

松开 PTT 的顺序固定为：

1. 立即停止麦克风采集、上行和本地 AVAudioSession；
2. 保留 transmit token，进入 stopPending；
3. 在任何接收音频恢复 await 之前发送 tx.stop；
4. 成功确认后清 token；
5. 失败短暂退避重试；
6. 重试耗尽后保持“远端停发未确认”安全告警；
7. 最后恢复接收音频。

这同时避免松手后麦克风继续运行、手机发热，以及 UI 已显示未发射但服务器尚未确认。

rigState 增加本地 revision/generation。轮询发起时捕获 revision；任何成功的频率、
模式或控制写入都会推进 revision。旧轮询回复若不再拥有当前 revision，直接丢弃。
并行 refresh 也只允许最新 generation 发布。

## 14. iOS 发射告警与管理界面

电台页顶部使用不会反复弹出的持久横幅：

- 本机语音、数字或天调发射：红色，显示持续秒数；
- 外部/现场 PTT：橙色，明确“只告警，未自动干预”；
- 停发未确认或安全恢复中：深红色；
- 恢复成功后横幅按事件状态消失。

横幅和电台页常驻紧急停止按钮。按钮调用 tx.emergency-stop，而不是复用要求旧
transmit token 的 tx.stop。

PTT 和天调增加按下、启动确认、松开和失败触感。VoiceOver 提供动作名称、当前状态、
持续时间和风险提示。自定义 hold button 提供可访问动作，不只依赖 DragGesture。

设置页补齐：

- Hamlib 型号、连接、PTT 方法和音频端点；
- 硬件只读测试结果与 preflight proof 状态；
- 允许发射频率范围和 SWR 能力/策略；
- 用户、发射权限和设备撤销；
- 未加密连接警告和服务端能力信息。

## 15. 频谱显示窗口

服务端生产 worker 继续发布固定 0–4 kHz 频谱。协议和契约样例统一为 4 kHz。

iOS 使用 AppStorage 保存用户请求的上限：

- 范围 3000–4000 Hz；
- 默认 4000 Hz；
- 步长 100 Hz；
- 修改立即生效，不重连、不改变电台 passband。

显示投影保留原始 frame span，不在 decoder 层伪造。有效上限为用户选择、
capability span 和 frame span 的最小值。可见 bin 数根据原始 span 按比例计算，
频谱折线与每一行 waterfall history 使用同一个裁剪 helper。

因此：

- 4 kHz 帧加 4 kHz 设置显示全部；
- 4 kHz 帧加 3 kHz 设置显示前约 75%；
- 旧 8 kHz 帧加 4 kHz 设置显示前约一半；
- 轴标签、无障碍描述和点数均使用有效上限；
- frame span 与 capability 冲突会记录诊断，但不会仅修改坐标造成频率失真。

## 16. CI、构建与版本

GitHub Actions 增加独立 server-check：

- Ubuntu；
- 固定受支持的 Node 24 版本；
- npm ci；
- npm run check。

删除 IPA job 中硬编码的 0.2.3/9 断言。版本只从 project.yml/构建设置读取；
CI 验证版本非空且格式合法。

CI 同时产出：

- Debug unsigned IPA，用于诊断；
- Release unsigned IPA，用于长期真机、发热、功耗、Opus 和频谱性能测试。

ATS 互斥检查继续保留。测试期允许 HTTP 的决定要在构建说明和 App 内清楚显示，
不把它误写为生产安全默认值。

## 17. 测试策略

所有修复遵循红—绿—重构：

### 服务端故障测试

- 连续多次 deactivate/emergencyOff 失败，之后恢复，确认 latch 持续重试；
- 恢复前不能再次起发；
- managed rigctld 运行期 exit 触发告警、重启和停发恢复；
- 自动媒体停发失败真正产生 ptt_stop_failed；
- digital heartbeat 不延长 control lease；
- audio 绑定后静默两秒会停发，持续音频不误停；
- emergency-stop 不需要旧租约且幂等；
- 外部 PTT 只告警、不自动 OFF；
- 安全命令不被后续遥测越过；
- service close 即使 media close 卡住也先调用 runtime close；
- SIGHUP 和异常关闭只执行一次并 exit 1。

### 协议与认证测试

- 错误、正确和缺失 Origin 的 WS upgrade；
- 半开连接在约两轮 heartbeat 内关闭；
- logout、改密、禁用和设备撤销立即使旧 WS 失效并先停发；
- 登录双维度限速不进入 Argon2 队列；
- 六位码完整封禁时长和每码全局上限；
- 审计轮转、尾部读取、权限及安全事件覆盖；
- 真实 profile 无 proof 拒绝保存，相同指纹 proof 允许，修改后拒绝；
- 频段外、频率未知、SWR trip/恢复与不支持 SWR 的确认策略。

### iOS 测试

- 旧 rig.state 回复不能覆盖新频率/模式；
- HTTP 仍为 300 秒，WS 为 15 秒；
- tx.stop 发送早于接收音频恢复；
- 停发失败保留 token、重试并显示未确认；
- 404 feature-unavailable 与其他 HTTP 错误分开；
- 4k→4k、4k→3k、8k→4k 的频谱和 waterfall 裁剪；
- 设置值夹在 3000–4000 并持久化；
- 发射横幅状态、持续时间、紧急停止、无障碍和触感策略。

### 全量验证

- radio-lite-server 类型检查与全部测试；
- Web 全部测试；
- 协议契约检查；
- XCTest、模拟器构建和 unsigned device build；
- Debug 与 Release IPA；
- Dummy 环境断线、停发失败、外部 PTT、FT8 自动停止和旧频谱帧验收。

真实电台在这些测试通过前只接 Dummy 或假负载。

## 18. 实施切片与提交顺序

1. CI 与故障注入测试基础。
2. interlock dekey latch、安全事件和自动停发错误传播。
3. rigctld 监督、transport 优先级、真实 PTT/SWR 与关闭顺序。
4. control lease、WS heartbeat、紧急停止和音频断流。
5. 认证撤销、限速、六位码、审计、错误映射。
6. preflight proof、频率范围、能力协商与协议文档。
7. iOS 停发、弱网、rigState revision 和发射横幅。
8. iOS 频谱、配置/账户页面、无障碍和触感。
9. 全量回归、版本、Debug/Release IPA、文档和发布。

每个切片有独立失败测试、实现、局部测试和提交。最终统一跑全量验证。

## 19. GitHub 与 Debian 发布

开发期间所有提交先保存在本地。全部验证通过后使用：

- .codex-ssh/github_radio_deploy_ed25519；
- .codex-ssh/github_known_hosts；
- SSH port 443；
- StrictHostKeyChecking。

不调用 gh auth login，不生成设备码。推送失败时不阻塞开发，保留本地提交并刷新
Git bundle。

Debian 发布只在新版服务端与 IPA CI 通过后执行：

- 所有新版本、备份、数据和回滚材料都放在 /opt/testradio；
- 读取并保留当前数据目录、监听地址和端口；
- 不删除 testradio 目录；
- 不修改 /opt/testradio 以外的服务、文件或目录；
- 健康检查失败时只在该目录内回退；
- 首轮只用 Dummy，真电台由用户另行确认后测试。

## 20. 审查条目处置

确认修复：

- A1–A4：停发 latch、自动停发错误、rigctld 监督、digital 控制租约；
- A5–A8：WS Origin/身份撤销、账户管理、登录限速；
- B1–B15：其中 B5 精确为运行期 PTT 漂移检测，写后回读原机制保留；
- B19–B20：发射横幅、紧急停止、触感和无障碍；
- N1–N6：N1 只修停发优先排序，不保留已经不成立的“额外网络 RTT”论据；
- N7：保留 Debug，新增 Release unsigned IPA；
- C1、C3、C4、C5 与适用的 C6 小项；
- 硬件预检 404 和 3–4 kHz 频谱显示设置。

有意保留或延期：

- B18：测试期明确 HTTP/ATS 选择保留，但增加持续风险提示；生产 TLS 收口另行验收；
- B16/B17：历史 Python 服务端不再使用，不修改其生产逻辑，只澄清文档；
- 无效 Cookie 不回退 Bearer：保留保守行为；
- 不恢复旧客户端、旧服务端或旧品牌。

## 21. 完成标准

本批工作完成必须同时满足：

- 软件负责的任何停发失败都会持续重试、全局告警并在回读 OFF 后恢复；
- 外部现场 PTT 只告警，除非用户主动点击紧急停止；
- 杀死 rigctld、断媒体、断控制、过期租约和关闭服务均通过 Dummy 故障测试；
- FT8/FT4 不能在客户端消失后自行续控制权；
- iOS 松开 PTT 后麦克风和本地音频会话立即结束；
- iOS 在 15 秒内报告失联控制命令，HTTP 慢连接仍可等 300 秒；
- 硬件预检、频段范围与 SWR 策略在真实 profile 保存和发射入口生效；
- 旧 8 kHz 频谱帧可按 3–4 kHz 设置正确裁剪；
- 账户/设备撤销即时生效，审计有界并可查询；
- 服务端、Web、协议、XCTest、Debug IPA 和 Release IPA 全部通过；
- 本地提交、GitHub 推送和 Debian 部署遵守既定认证与目录安全约束。
