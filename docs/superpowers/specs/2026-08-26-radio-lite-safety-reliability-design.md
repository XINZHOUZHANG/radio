# Radio Lite 发射安全、弱网可靠性与客户端修复设计

**日期：** 2026-08-26

**状态：** 第二轮书面复核意见已纳入，等待最终确认

**基线：** 分支 codex/public-dummy-web-integration；审查起始 HEAD 8e30116；
本轮修订前 HEAD f03e085

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

1. TransmitInterlock：只负责发射状态、租约、deadline、`dekeyRequired` 和故障
   latch；它不拥有重连、进程重启或退避循环。
2. RigRuntimeSupervisor：每个 radioId 唯一一个，独占 rigctld 生命周期、transport
   replacement、恢复调度、PTT OFF 恢复循环和真实 PTT/SWR 低频监测。
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

单纯清除错误文本不能解除故障。对于软件承担停发责任的真实 profile，只有同一恢复
事务中的 PTT OFF 回读才能原子地同时清除 `dekeyRequired`、清除发射 `fault`、
转为 idle、发布 recovered，并重新开放起发。`set_ptt 0` 写入成功、旧遥测值或最后
命令值都不是停发证据。

本文中的 `dekeyRequired` 专指进程内状态字段；`dekey_required` 专指协议事件 kind，
二者不得作为两个独立状态实现。

### 5.2 停发恢复

正常停发先在短 deadline 内执行模式对应的 deactivate，再执行 emergencyOff，并回读
PTT。deactivate 失败不能跳过后续 PTT OFF；任一步失败或 OFF 未确认都进入
dekey_required，并记录首次进入 latch 的单调时间：

- 首次立即重试；
- 后续退避，最大间隔两秒；
- 重试在服务存活期间不设总次数上限；
- 每台电台同一时刻最多有一次 OFF 加回读序列在途；
- 只有真实 `get_ptt=false` 才按 5.1 的原子提交清除 latch 和发射 fault；
- 恢复期间拒绝所有新的 voice、digital 和 tuning 起发。

RigRuntimeSupervisor 是恢复流程的唯一 owner。它管理链路可用性、受管 rigctld
重启、transport replacement、退避时钟和 recovery generation，并且只有它能调度
恢复尝试。TransmitInterlock 只保存 latch，并提供一次性的
`attemptDeKey(currentTransport, generation)`：supervisor 在当前 generation 链路可用时
调用它；该调用只执行模式 deactivate、PTT OFF 和回读并返回结果，不能重连、重启、
等待退避或安排下一次调用。失败结果由 supervisor 安排下一次尝试，不重置既有退避。
旧 generation 的 exit、连接成功或回读不能改变新 generation。进入 closing 后任何
延迟 exit 都不能触发重启。

连续失败只更新同一个持久安全事件，不制造重复弹窗。首次失败、原因变化、
恢复成功分别写审计。`dekeyRequired` 连续 30 秒仍未得到 OFF 回读时，事件升级为
`dekey_escalated`，明确提示“软件仍无法确认停发，请联系现场人员并关闭电台及功放
电源；不要触碰正在发射的天线或馈线”。软件重试继续进行，不能把提示或人工确认
当成 OFF 证据。本版本不虚构未配置的物理继电器能力；独立硬件看门狗另行设计。

### 5.3 外部 PTT

RigRuntimeSupervisor 通过统一 RigTelemetrySampler 以约 1 Hz、低优先级、单飞方式
读取真实 PTT：

- Radio Lite 正常发射或调谐时，实际 ON 属于预期；
- Radio Lite 空闲且没有 dekey_required 时发现 ON，发布 external_ptt_observed；
- external_ptt_observed 不调用 PTT OFF，不抢夺现场人员控制；
- 回读变为 OFF 后发布 cleared；
- 用户明确点击紧急停止时，视为新的授权操作，可以尝试关闭该 PTT。

PTT 读取失败会产生 telemetry_uncertain 告警。若系统当前承担停发责任，
读取失败继续走 dekey_required；若系统空闲，仅告警。

runtime 初始化拆成无写入的 `startupObserve` 与仅供已有 latch 使用的
`recoverDeKey`。当没有 `dekeyRequired` 时，启动、重连、配置恢复和预检 resume 都只
读取 PTT/遥测，绝不发送 startup PTT OFF；之后观察到 ON 仍按 external PTT 处理。
只有 supervisor 已持有软件停发责任 latch 时才允许调用 recoverDeKey 写 OFF，因此
“先读 OFF、随后现场人员按下 PTT”的时序也不会被初始化代码自动去键。

## 6. rigctld、transport 与进程关闭

ManagedRigctldProcess 增加常驻 unexpected-exit 观察器。主动 close 不触发意外退出；
它只上报带 generation 的退出事实，不自行 restart 或发送 CAT。运行期退出会通知
唯一的 RigRuntimeSupervisor：

- 系统正在发射时，立即进入 dekey_required；
- 以退避方式重启受管 rigctld；
- 恢复连接后优先执行 PTT OFF 并回读；
- 空闲时恢复后先读取 PTT，外部 ON 只告警。

RigctldTransport 使用安全优先与普通命令两个 FIFO，不对全队列排序：

- PTT OFF、紧急停止和安全回读优先；
- 普通频率、模式、遥测和控件读取不得越过已排队的安全命令；
- 每连接最多一个命令在途，普通队列最多 32 项；队满时 telemetry read 直接丢弃或
  合并，用户显式 control 返回 `rig_queue_busy` 而不静默丢失，二者都不能挤占安全队列；
- 普通 tx.stop、紧急停止、lease/deadline、媒体断流和调谐结束都先进入同一个
  supervisor recovery generation，再按 `{radioId, recoveryGeneration}` 合并为一次
  高优先级序列；调谐需要的 tuner deactivate 也在该序列中，顺序为模式 deactivate、
  PTT OFF、`get_ptt`；
- 安全序列入队 250 毫秒仍因普通在途命令无法开始时，断开该 socket 并使普通请求
  失败；由 supervisor 恢复链路后，安全序列成为第一项；
- 单条安全 CAT 命令使用 1 秒超时；voice/digital 的 OFF 加回读序列总预算 2 秒，
  tuning 的 deactivate、OFF、回读三命令总预算 3 秒。deactivate 即使超时也继续尝试
  OFF。普通命令保持 10 秒超时。安全序列超时只把结果交回唯一 supervisor，不创建
  第二个恢复循环。

两级 FIFO 本身不增加网络往返；但安全确认本来就需要 OFF 和 `get_ptt` 两次请求，
断 socket 时还会有重连成本。优先级只对尚未开始的命令生效，不能声称零等待抢占。

统一 RigTelemetrySampler 还负责 CAT 稳态预算，防止多个客户端轮询叠加：

- 任意连续 10 秒内，空闲后台命令平均不超过 2 条/秒；发射中不超过 4 条/秒；
- 每两秒采集一次 frequency、mode、PTT 的完整状态，中间一秒只读 PTT；发射中按
  约 1 Hz 增加可用的 SWR 读取；
- `rig.state.get`、rig controls 和多个订阅者优先返回同一服务端缓存，过期刷新必须
  合并，不能按客户端数量倍增 CAT 命令；
- 用户显式写命令和紧急 OFF 分开计数并记录指标；它们可产生短时突发，但紧急 OFF
  永远优先，普通突发不能突破队列上限；
- transport 为每条 CAT 命令记录来源、优先级和单调时间，测试可断言窗口预算。

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
- command reply 只提供按钮的瞬态执行反馈；执行中、未确认和恢复等持久状态只通过
  SafetyEventHub 的同一 radio revision 事件广播并写审计；
- 幂等重复调用不会重新启动任何发射。

MediaHub 自动停发返回显式 `DeKeyOutcome`：`offConfirmed`、`recoveryPending` 或
`notResponsible`。只有 `offConfirmed` 可以结束对应安全事件；`recoveryPending`
表示 supervisor 已接管同一 radio 的 latch；`notResponsible` 只允许用于该绑定从未
成功键控或已有更高 generation 的已确认结局。其余自动停发错误在写审计后必须传播，
使现有 ptt_stop_failed 通知真正可达。

InvalidLease 只表示旧 token 不再代表当前 transmit lease，不能作为物理 PTT 已关闭
的证据，也不能清除 `dekeyRequired`、fault 或安全告警。MediaHub 不直接接收或判断
原始 InvalidLease；interlock/supervisor adapter 必须把它转换为带证据的
`offConfirmed`、`recoveryPending` 或符合上段限制的 `notResponsible`。无法证明其中
任一结局时仍须报告未确认。MediaHub 吞掉旧 lease 错误的唯一正当性是该 outcome，
而不是 InvalidLease 本身；租约失效和 latch 并发时，latch 继续重试直至真实 OFF 回读。

语音上行绑定后记录最后一帧有效音频时间。超过可配置的短阈值，默认两秒，
即使控制心跳仍在继续也停止语音发射。持续收到有效音频时不误触发。

## 8. 频率范围与 SWR

真实电台 profile 增加明确的允许发射频率范围。App 提供常用业余频段预设和
自定义区间，但服务端只信任保存后的规范化范围。

- 新保存且 hardwareTxEnabled 为 true 的真实 profile 必须至少有一个允许范围；
- 每次 voice、digital 或 tuning 起发都在服务端安全准入中检查频率。优先使用
  RigTelemetrySampler 最近不超过 2 秒的新鲜 CAT 读数；缓存缺失、过期或被并发
  `set_freq` 失效时才同步执行 `get_freq`。客户端 rigState、频谱中心频率和单纯的
  最后命令值不得作为准入缓存；
- 频率缓存或同步读数必须落在允许范围内。没有新鲜读数、读取失败或范围外均拒绝
  起发，且在完成判断前不得执行 activation。正常路径不增加额外 CAT 往返；
- 缓存校验和 activation 位于同一个 per-radio safety 串行区；其间禁止远程
  `set_freq`、`set_mode` 和第二个 start，写后回读会推进或失效相同缓存 generation；
- 这是已确认的按键延迟折中：现场人员在最近一次采样后转动实体旋钮仍可能改变频率，
  而同步读后到键控前也无法从软件上完全封闭实体操作。SAFETY 文档明确要求远程发射
  期间不在现场改频；本批不以每次 PTT 强制串口往返取代该产品决定；
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

选择 acknowledged_internal_protection 后，预检保留结构化 acknowledged warning 供
界面和审计显示，但该项不再使最终 `overallStatus` 停留在 warning；只有所有未确认的
warning 都被策略解决后，最终状态才可为 passed 并签发 proof。

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

真实 profile 的只读预检只有 `overallStatus === passed` 时才返回十分钟有效的
preflight proof；warning 和 failed 均不签发 proof，也不能授权 hardware TX 保存。
proof 使用进程内随机 HMAC 密钥签名，并绑定：

- 管理员用户 ID；
- 规范化 profile 的稳定 SHA-256 指纹；
- 签发和过期时间；
- 预检通过状态。

proof 不落盘，服务重启后失效。保存真实 profile 时重新规范化并核对指纹。指纹使用
版本化 `preflight-proof-v1` canonical JSON：UTF-8、递归键排序、去除 undefined，包含
radio id、Hamlib model、connection kind/device/baud 或 host/port、audio input/output
backend 和 id、PTT method/path/bit、hardwareTxEnabled、允许发射范围、SWR 策略及以后
新增的硬件安全字段。name、音频 label 和 station 显示信息不进入指纹。上述任一字段
变化都会使 proof 无效。Dummy profile 豁免。保存和预检均写安全审计。

运行中的 managed-serial 电台不能直接抢占自己的串口做预检。设置页提供显式的
“停止该电台并预检”动作，并提前提示短暂断开：

1. 服务端为该 radio 建立十分钟 reconfiguration fence，拒绝新的控制和起发，但仍
   允许紧急停止；fence 由 supervisor 持有，不随管理员页面或网络断开而消失；
2. 若存在 voice、digital、tuning、`dekeyRequired`、外部 PTT ON 或 PTT 状态不确定，
   不进入预检；软件负责的发射先完成停发确认；
3. 安全关闭现有 runtime、确认受管 rigctld 退出并释放 canonical serial claim；
4. 对表单中的候选 profile 独占该 canonical device 完成预检并签发 proof；
5. 保存成功、用户取消或服务端单调时钟到期后进入 resume；仅在测试进程已确认清理
   完成时才可继续；
6. resume 使用不会写 PTT 的探测 transport 先读真实 PTT。只有确认 OFF 才解除 fence
   并按新配置或旧配置创建 `startupObserve` runtime；该 runtime 初始化和后续外部 PTT
   监测都不写 OFF。若 ON 或不确定，保持 fence，发布 external PTT/telemetry 告警；
   supervisor 保持低频、只读的 probe，直到现场 PTT 自行恢复为 OFF 后才恢复 runtime。

普通“保存”不会暗中停掉正在工作的电台。缺少 proof 时返回可识别的
`preflight_requires_runtime_stop`，由 iOS 引导管理员执行上述动作。cleanup uncertain
时设备继续 quarantine，不得签发 proof 或解除为可发射状态。fence 的取消、到期和
安全 resume 均有审计与假时钟测试。

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
当前 generation 使用预打开的常驻文件句柄并串行 append；轮转是明确的 generation
边界，在同一栅栏内执行 sync、close、rename/prune、创建新当前文件、目录 sync 和
reopen，不能在 rename 后继续写旧句柄。文件和目录权限保持现有安全设置。
readNewest 从尾部读取有界数据，不把整个日志载入内存；崩溃留下的不完整末行被跳过
并产生 `audit_tail_incomplete`，不能使整次查询失败。

文件固定命名为 `audit.jsonl` 与 `audit.1.jsonl` 至 `audit.4.jsonl`。轮转时先关闭当前
句柄，删除最旧文件，按 3→4、2→3、1→2 降序 rename，再把 current→1，最后创建并
打开新 current；Debian 上每个影响目录项的轮转批次必须 fsync 目录。启动恢复扫描这
五个名字，保留所有完整记录、补建缺失 current、删除超出保留数的最旧文件，绝不以
空文件覆盖已有 generation。任何 crash point 后都允许有编号空洞，但不能丢弃仍在
保留窗口内的完整文件。

管理员分页按 current、1、2、3、4 从新到旧跨文件读取，cursor 包含 generation 与
byte offset；目标 generation 已被轮转删除时返回 `audit_cursor_expired`。末行损坏
通过内存审计健康状态和 stderr 告警，不能递归 append `audit_tail_incomplete` 到同一
受损日志。

审计覆盖：

- 登录、登出、限速；
- 用户和权限变更；
- 配对码签发、兑换、设备 refresh 重放和撤销；
- profile 预检、保存和 hardwareTxEnabled 变化；
- PTT、天调、FT8/FT4、紧急停止和所有安全告警；
- rigctld 退出、恢复及停发确认。

审计 writer 使用安全意图与普通事件两个 FIFO，但仍只有一个文件写入在途；安全意图
队列最多 32 项且每台 radio 只允许一个 pending start，普通队列最多 1024 项。普通
队满触发审计健康告警；新的非安全事件可失败，但不能挤掉已接收的安全意图。

传输开启采用高优先级 `radio.ptt-start.requested` 意图审计；必须在 activation/PTT ON
之前完成 write 加 sync。默认 admission budget 为 250 毫秒并可配置、可测试；它约束
本次起发的准入决定，不假装能抢占已经在途的普通 sync 或轮转栅栏。队列满、deadline、
write 或 sync 失败均返回 `tx_audit_unavailable`，永久 disarm 该 start attempt，不得
创建 lease、绑定媒体或在后台稍后自动键控。尚未开始的超时意图从队列移除；已经开始
的写入可以完成并留下 requested 记录，但其完成也永远不能重新武装该 attempt。成功
键控后追加 keyed/result 记录；该事后记录失败只触发审计健康告警，不能妨碍停发。

紧急停发、权限降低、撤销、deadline 和 dekey 恢复永远不能等待审计；这类审计失败
另行 latch 告警。审计健康依赖只能阻止新的起发，绝不能反向阻止关闭发射。

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
6. 本地有界重试耗尽或控制 WS 断开时，只保留“远端状态未确认”的降级告警；
7. 最后恢复接收音频。

这同时避免松手后麦克风继续运行、手机发热，以及 UI 已显示未发射但服务器尚未确认。
客户端用独立私有记录
`{radioId, transmitToken, mode, startedAckRevision, stopPending, retryAttempt}` 维护停发重试，
不能复用“按住 PTT”布尔值。transmit token 只作为重试 identity，不能作为横幅的权威
发射真相。成功 tx.stop reply 可以结束本地重试 identity，但不能清除服务端持久横幅；
断线形成的“远端状态未确认”只能由匹配 epoch/radio 的服务端 snapshot 结束。

rigState 增加本地 revision/generation。轮询发起时捕获 revision；任何成功的频率、
模式或控制写入都会推进 revision。旧轮询回复若不再拥有当前 revision，直接丢弃。
并行 refresh 也只允许最新 generation 发布。

## 14. iOS 发射告警与管理界面

当 `health.features.safetyAlerts=true` 时，控制 WS 在认证和每次重连后为每台电台发送
`SafetyAlertSnapshot { safetyEpoch, radioId, revision, alert: SafetyAlert? }`。
`safetyEpoch` 是服务进程启动时生成的随机标识；revision 在同一 epoch 内按 radio
单调递增；`alert: null` 是“当前无持久告警”的唯一 snapshot 表达，recovered 只作为
增量 transition，不能充当空状态。

SafetyEventHub 在同一个串行边界内先注册客户端、捕获完整 snapshot set 与 revision，
再只投递同 epoch 且 `revision > snapshot.revision` 的后续事件，状态变化不能落入订阅
与快照之间的空窗。每条连接的 outbound queue 必须先按顺序放入 snapshot begin、全部
radio snapshot、snapshot end，再放入这期间缓冲的增量事件；iOS 在 end 前缓存新 epoch
事件，并在完整 snapshot set 原子应用后再按 revision 回放。增量事件至少包含
safetyEpoch、radioId、revision、kind、startedAt；kind 覆盖 active、external_ptt、
dekey_required、dekey_escalated 和 recovered。非管理员只收到分类后的 source，不公开
owner 身份；管理员可收到 owner userId，不发送凭证。

同一 radio 的持久发射横幅唯一由服务端 snapshot 加 revision 投影：本地按键状态只
显示“正在请求/正在停止”等瞬态控件，不能覆盖或清除服务端横幅；`rig.state.ptt` 只作
遥测。epoch 不匹配、乱序、重复、旧 revision 和其他 radio 的事件不得改变当前横幅。
新 epoch 的完整 snapshot 原子替换旧 epoch。断线或尚未取得 snapshot 时，iOS 保留
最后一个非 null 服务端 SafetyAlert 的全部 kind，并标记 stale/“远端状态未确认”；
dekey_required、dekey_escalated 和 external PTT 至少保持原严重级别，不能因断线降级
消失。若从未收到非 null alert，但本地仍持有 stopPending，也显示该降级状态。只有
匹配 epoch/radio 的完整 snapshot 可以替换或清除这些 stale 状态。
重连后用服务端 snapshot 原子替换降级状态。旧服务器未声明 safetyAlerts 时进入明确
标注的兼容降级，不能伪称拥有权威安全状态。

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
capability span 和 frame span 的最小值。频谱 history 元素改为
`SpectrumHistoryRow { bins, frameSpanHz, centerFrequencyHz }`，保留足够分辨率的原始
bins，逐行先裁剪再下采样到渲染列数。不能先用最新 frame 的 span 或全局 axis 裁剪
旧行，也不能先把 8 kHz 压缩后再截一半。

内存边界保持最多 32 行；每行最多保留 capability 声明且协议允许的 512 个 bins，
超出上限的帧在 decoder 边界拒绝，不允许 history 无界增长。渲染仍可下采样到现有
最大 96 列，但下采样发生在逐行裁剪之后。

切换 radio 或中心频率变化时清空 history；仅 span 或 bin 数变化不清空。每一行用
自己的 frameSpanHz 计算 effective span，并映射到同一当前显示宽度。当前轴标签使用
当前 frame 的有效 span，但不能反过来充当旧行的数据尺度。

因此：

- 4 kHz 帧加 4 kHz 设置显示全部；
- 4 kHz 帧加 3 kHz 设置显示前约 75%；
- 旧 8 kHz 帧加 4 kHz 设置显示前约一半；
- 轴标签、无障碍描述和点数均使用有效上限；
- frame span 与 capability 冲突会记录诊断，但不会仅修改坐标造成频率失真。

## 16. CI、构建与版本

GitHub Actions 增加独立 server-check：

- Ubuntu；
- job id 与显示名均为 `server-check`；
- Node 精确版本只保存在仓库 `.node-version`，初始为 24.7.0，workflow 读取该文件；
- npm ci；
- npm run check。

同时增加独立 web-check，并把 `web/**` 加入 workflow 触发路径：

- job id 与显示名均为 `web-check`，Ubuntu 并读取同一 `.node-version`；
- 当前 Web 没有依赖锁文件，先在 web 工作目录直接执行 `npm test`；
- 若以后引入依赖，必须提交 lockfile 后改为 `npm ci && npm test`；
- server-check 与 web-check 在 pull request 和 push 均运行；Release artifact job 通过
  `needs` 强制依赖二者。仓库 ruleset/branch protection 另将这两个精确 job name 设为
  required checks；这是一次性仓库设置，不通过重复 GitHub 设备授权完成。

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
- rigctld exit、连接失败和停发失败并发时只有一个 supervisor 恢复循环；旧 generation
  回调不能清除新 latch，close 后 exit 不能重启；
- 恢复前不能再次起发；
- managed rigctld 运行期 exit 触发告警、重启和停发恢复；
- 自动媒体停发失败真正产生 ptt_stop_failed；
- digital heartbeat 不延长 control lease；
- audio 绑定后静默两秒会停发，持续音频不误停；
- emergency-stop 不需要旧租约且幂等；
- 外部 PTT 只告警、不自动 OFF；
- `dekeyRequired` 持续 30 秒升级现场断电处置横幅，但不触碰外部 PTT，且仍只在 OFF
  回读后恢复；
- 安全命令不被后续遥测越过；卡住普通命令后断 socket，重连首条为 OFF；普通 FIFO
  保序，普通 stop、紧急停止、deadline、媒体断流和 tuning deactivate 进入同一
  generation，重复安全请求合并；tuner deactivate 超时后仍在三秒总预算内尝试 OFF
  与回读；
- 典型空闲和发射场景任意连续 10 秒的 CAT 命令计数分别不超过 2 条/秒和 4 条/秒，多个
  `rig.state.get` 客户端不能倍增采样；
- 频率缓存不超过 2 秒时正常起发零额外 CAT 往返，过期/缺失/失效时同步读取，未知
  或范围外保持 PTT OFF；并发远程改频不能越过 safety 串行区；
- `set_ptt 0` 成功但回读 ON、超时或格式错误仍保留 fault+latch；回读 OFF 时 latch、
  fault、事件和起发禁令原子恢复；
- InvalidLease 与租约过期并发时仍由 latch 重试，不能误报已停发；
- service close 即使 media close 卡住也先调用 runtime close；
- SIGHUP 和异常关闭只执行一次并 exit 1；
- deployment drain 遇到活跃发射、dekey latch、外部 PTT ON、读回超时或并发
  tx.start 时均拒绝替换；旧/过期 proof、CLI 断线和回滚也覆盖，成功路径只能在同一
  drain generation 内取得新鲜 OFF 证明。

### 协议与认证测试

- 错误、正确和缺失 Origin 的 WS upgrade；
- 半开连接在约两轮 heartbeat 内关闭；
- logout、改密、禁用和设备撤销立即使旧 WS 失效并先停发；
- 登录双维度限速不进入 Argon2 队列；
- 六位码完整封禁时长和每码全局上限；
- 审计轮转每个 crash point、代际句柄、崩溃末行、跨五文件分页/cursor expiry、权限及
  安全事件覆盖；
- 意图审计在 250 毫秒上界内 durable 后才能键控；队列满、write/sync 卡住或失败时
  PTT 保持 OFF，且不得残留 lease、token 或媒体绑定；超时后晚到的 durable write
  也不能重新武装该 start attempt；
- 真实 profile 无 proof 拒绝保存，相同指纹 proof 允许，修改后拒绝；
- 运行中 managed-serial profile 必须通过“停止并预检”fence，串口不会被自己的
  runtime 阻塞；warning/failed、活跃/未知 PTT 或 cleanup uncertain 时不能签发 proof；
  保存、取消和到期恢复都先做无写入 PTT 探测，外部 ON 不得触发 startupSafe；
- 频段外、频率未知、SWR trip/恢复与不支持 SWR 的确认策略。

### iOS 测试

- 旧 rig.state 回复不能覆盖新频率/模式；
- HTTP 仍为 300 秒，WS 为 15 秒；
- tx.stop 发送早于接收音频恢复；
- 停发失败保留 token、重试并显示未确认；
- safetyAlerts snapshot 是横幅权威；覆盖 snapshot/event 原子交接、`alert:null`、
  新 epoch、乱序 revision、其他 radio 和本地旧 PTT 状态；断线降级在重连 snapshot
  后原子替换；
- 连接在 active、external PTT、dekey_required 和 dekey_escalated 任一状态断开时，
  stale 横幅不消失也不降低严重级别，只有完整匹配 snapshot 可清除；
- 本地 start 尚未得到 server active 时不显示持久红色横幅；本地松手、停止音频或
  emergency-stop reply 都不能清除仍为 active/dekey 的服务端横幅；
- 404 feature-unavailable 与其他 HTTP 错误分开；
- 4k→4k、4k→3k、8k→4k 的频谱和 waterfall 裁剪；同一 history 混合 8k/4k 行时
  各按自身 span 裁剪，span 变化不清历史，中心频率变化清空 history；
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
3. rigctld 唯一 supervisor、transport 优先级、CAT 预算、真实 PTT/SWR 与关闭顺序。
4. control lease、WS heartbeat、紧急停止和音频断流。
5. 认证撤销、限速、六位码、代际审计句柄、错误映射。
6. preflight proof、停止并预检、频率缓存/范围、能力协商与协议文档。
7. iOS 停发、弱网、rigState revision 和服务端权威发射横幅。
8. iOS 逐行 span 频谱、配置/账户页面、无障碍和触感。
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

部署脚本通过 `/opt/testradio/run/control.sock` 的本机 Unix socket 调用
`radio-lite deploy drain`；socket 只允许服务 OS 用户和部署用户访问，不开放网络端口。
服务端持有 drain ownership，不因 CLI 断开或客户端退出而解除，并分配单调
drainGeneration：先进入 draining，拒绝新 upgrade、控制和 tx.start，但保留
emergency-stop；随后在同一个 generation fence 内证明所有 runtime 均无
voice/digital/tuning、`dekeyRequired=false`，并取得新鲜 PTT OFF 回读。

safe-to-stop proof 绑定 process boot id、drainGeneration 和签发单调时间，最长有效五秒；
proof 签发与 PTT 回读在同一 drain 串行边界，旧 generation、旧进程或超时 proof 均
拒绝。服务不可达、读回超时/不确定、外部 PTT ON、正在发射或 drain 期间并发起发都
必须拒绝部署，不能靠“先检查再重启”的竞态窗口继续。CLI 成功返回 0；活跃发射返回
10、latch/外部 PTT 返回 11、遥测不确定返回 12、服务/本机认证不可用返回 13。所有
非零路径不得停止、替换或删除任何文件/进程，只保留 drain 以便 emergency-stop 或由
明确的 `deploy drain-cancel` 安全解除。

若新版本健康检查失败，只有能证明它从未取得任何 runtime/发射能力，或已对它完成
同样的 drain，才允许启动旧版本回滚。部署测试覆盖旧 proof 重放、proof 超时、CLI
断开后 fence 仍在、各非零码无替换副作用及回滚路径。

## 20. 审查条目处置

确认修复：

- A1–A4：停发 latch、自动停发错误、rigctld 监督、digital 控制租约；
- A5–A8：WS Origin/身份撤销、账户管理、登录限速；
- B1–B15：其中 B5 精确为运行期 PTT 漂移检测，写后回读原机制保留；
- B19–B20：发射横幅、紧急停止、触感和无障碍；
- N1–N6：N1 使用安全/普通双 FIFO 修停发优先；队列本身不增加 RTT，但明确保留
  OFF、回读和必要重连的真实成本；
- N7：保留 Debug，新增 Release unsigned IPA；
- C1、C3、C4、C5 与适用的 C6 小项；
- 硬件预检 404 和 3–4 kHz 频谱显示设置。

有意保留或延期：

- B18：测试期明确 HTTP/ATS 选择保留，但增加持续风险提示；生产 TLS 收口另行验收；
- B16/B17：历史 Python 服务端不再使用，不修改其生产逻辑，只澄清文档；
- 独立硬件看门狗/继电器：T2 本批只要求 30 秒后升级为明确的现场断电处置指令，
  不把 Node timer 冒充跨崩溃的物理保护；真正的硬件兜底另行设计和验收；
- 无效 Cookie 不回退 Bearer：保留保守行为；
- 不恢复旧客户端、旧服务端或旧品牌。

## 21. 完成标准

本批工作完成必须同时满足：

- 软件负责的任何停发失败都会持续重试、全局告警并在回读 OFF 后恢复；
- rigctld 与 dekey 恢复只有一个 supervisor owner，客户端横幅只有服务端
  safetyAlerts 权威；
- 外部现场 PTT 只告警，除非用户主动点击紧急停止；
- 杀死 rigctld、断媒体、断控制、过期租约和关闭服务均通过 Dummy 故障测试；
- FT8/FT4 不能在客户端消失后自行续控制权；
- iOS 松开 PTT 后麦克风和本地音频会话立即结束；
- iOS 在 15 秒内报告失联控制命令，HTTP 慢连接仍可等 300 秒；
- 硬件预检、频段范围与 SWR 策略在真实 profile 保存和发射入口生效；
- 旧 8 kHz 频谱帧可按 3–4 kHz 设置正确裁剪；
- 混合跨度的瀑布历史逐行按自己的 span 正确显示；
- 账户/设备撤销即时生效，审计有界并可查询；
- 稳态 CAT 预算受测试约束，部署在确认全部 PTT OFF 前不会替换进程；
- 服务端、Web、协议、XCTest、Debug IPA 和 Release IPA 全部通过；
- 本地提交、GitHub 推送和 Debian 部署遵守既定认证与目录安全约束。
