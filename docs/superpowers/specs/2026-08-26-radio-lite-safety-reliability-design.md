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

新增或收紧六个边界清晰的单元：

1. TransmitInterlock：只负责发射状态、租约、deadline、`dekeyRequired` 和故障
   latch；它不拥有重连、进程重启或退避循环。
2. RigRuntimeSupervisor：每个 radioId 唯一一个，独占 rigctld 生命周期、transport
   replacement、恢复调度、PTT OFF 恢复循环和真实 PTT/SWR 低频监测。
3. SwrSafetyStore：把每台电台的 armed/trip/rearm 状态以原子、全局串行的明文事务
   保存在配置数据目录中，提供跨进程崩溃的 fail-closed 证据，不执行 CAT。
4. SafetyEventHub：把安全状态广播给控制客户端并写审计，不参与硬件操作。
5. AuthenticationBoundary：负责 HTTP/WS 身份复核、撤销、限速和连接预算。
6. iOS presentation policies：用纯值模型投影发射横幅、频谱窗口、错误提示和
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
- Radio Lite 空闲且没有 dekey_required 时发现 ON，发布 external_ptt；
- external_ptt 不调用 PTT OFF，不抢夺现场人员控制；
- 回读变为 OFF 后发布 recovered，并以 `alert:null` 清除持久告警；
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
- 请求和 accepted reply 都携带精确 `radioId` 与 `commandId`；服务端按该 `radioId`
  查找唯一 supervisor，客户端拒绝任一字段不匹配的 reply，其他 radio 不得受影响；
- 目标 supervisor 的紧急 OFF/回读是必达尝试，digital、voice、tuning 或媒体清理抛错
  不能阻断它；实现使用独立的 `allSettled` 清理并优先启动目标 radio 的硬件停发；
- 若 reconfiguration preflight 正独占候选串口，同一 supervisor 先取消候选预检、等待
  cleanup、收回 canonical serial claim，再用 safety 优先级 transport 执行 OFF 与回读；
  该预检失败并保留 quarantine，不签发 proof。禁止路由到已关闭的旧 runtime；
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
- 旧 profile 缺少范围或 SWR 策略时仍可接收和控制，但持久化迁移只填入空范围和
  内部 sentinel `configuration_required`，起发返回 tx_safety_config_required；
- `configuration_required` 不能由 HTTP 新建/保存接受、不能签发 proof，也不能静默
  变成 acknowledged_internal_protection。配置页面要求管理员明确选择下面两种策略并
  补充范围后，才可执行严格保存；
- 配置页面明确提示补充范围和选择 SWR 策略，不静默替管理员确认机内保护。

SWR 策略为：

- 默认 trip 3.0、reset 2.0，可在安全范围内配置；
- 管理员必须明确选择 require_swr 或 acknowledged_internal_protection；
- 只读 preflight 只能证明 Hamlib/SWR meter capability，零 RF 时不能产生可相信的
  物理 SWR，不能要求或伪造起发前缓存读数；
- `require_swr` 的 cold/normal start 在审计通过后、PTT ON 前先耐久写入 `armed`，随后
  允许最多一秒的实际带 RF 首样本窗口。首个有效 transmitting sample 必须是有限值且
  `< trip`；缺失、过期、格式错误、读取失败或 `>= trip` 均立即锁定并进入停发恢复；
- 首样本通过后仍以约 1 Hz 采样；运行期缺失、过期、读取失败或 `>= trip` 同样立即
  锁定并停发，不能用一次 preflight 或首样本通过替代运行期 fail-closed；
- acknowledged_internal_protection 明确依赖电台机内保护，不使用服务端 meter latch。

`SwrSafetyStore` 在配置数据目录的 `safety/swr-state.json` 保存
`{ radioId, state: armed | latched | rearm_pending | rearm_in_progress,
trippedAtMs: number | null }`。
每次更新使用临时文件写入、文件 fsync、原子 rename 和目录 fsync。因为所有 radio
共用一个 JSON 文件，读取—修改—写回必须进入同一个 process-wide 串行事务；不能只按
radioId 加锁，否则 main 与 backup 并发更新会互相覆盖。损坏、不可读或持久化失败都
fail closed，禁止后续起发。

状态和 crash 语义固定为：

- 每次普通 `require_swr` PTT ON 前都耐久写入 `armed`；整个 PTT ON 期间保留它。只有
  Hamlib 真实回读 PTT OFF 且本次没有 trip 后才能耐久删除；OFF 前删除、单凭 stop reply
  删除或删除失败后继续开放起发均禁止；
- 启动读到 `armed` 或 `rearm_in_progress` 一律恢复成 `latched`，因为进程无法证明崩溃
  前的发射已安全结束。读到 `latched` 保持锁定，读到 `rearm_pending` 仍只允许下述一次
  受监测 rearm；
- trip 先在内存发布 `swr_trip_latched` 并立即进入 de-key，不等待 `armed -> latched`
  落盘。若在观察到高 SWR 后、latched 重写前崩溃，旧的 `armed` 仍使重启 fail closed；
- PTT OFF 回读只清 transmit/dekey owner，不能清独立的 SWR latch。SWR owner 仍锁定时
  必须重新显露 `swr_trip_latched`，不能错误发布 recovered。

管理员现场检查天线、馈线和功放后，才可调用
`POST /api/v1/radios/:radioId/swr-trip/reset`，body 必须精确为
`{ "acknowledgePhysicalInspection": true }`。端点在任何 await 前失效 pending start，
在 supervisor safety transaction 中重新读取真实 PTT，并且只在 PTT 已确认 OFF、没有
dekey latch、没有 reconfiguration fence 时耐久写入 `rearm_pending` 和发布
`swr_rearm_pending`；HTTP 成功不代表 SWR 已恢复。

`rearm_pending` 只允许一次受监测起发。PTT ON 前先耐久改为 `rearm_in_progress`；一秒
内首个有效样本必须 `<= reset`，否则立即停发并恢复 `latched`。安全首样本只能耐久改为
`armed`，随后清除可见 SWR owner 并按正常 `< trip` 规则继续当前发射；PTT 仍 ON 时绝不
删除 marker。之后若 SWR 升高，先立即停发，再异步把 `armed` 改为 `latched`；若在该
重写前崩溃，重启仍因 `armed` 进入 latched。只有这次发射最终真实回读 OFF 且全程未
trip，才删除 `armed`。因此“安全 rearm 首样本”不是永久解锁，也不能重复消费一次
reset。

起发准入使用一个可配置的单调时钟总 deadline，默认 500 毫秒，从耐久 TX 意图审计前
开始，到 CAT PTT ON 前结束。意图审计保留 250 毫秒子预算；`armed` 或
`rearm_in_progress` 的原子持久事务只能使用剩余总预算。任一预算耗尽都废弃同一个
transmit permit，保持 PTT OFF，晚到的审计或持久写入不能重新武装。

选择 acknowledged_internal_protection 后，预检保留结构化 acknowledged warning 供
界面和审计显示，但该项不再使最终 `overallStatus` 停留在 warning；只有所有未确认的
warning 都被策略解决后，最终状态才可为 passed 并签发 proof。

遥测命令始终低于 PTT OFF 优先级，不得延迟停发。

## 9. 硬件预检与能力协商

健康接口保留 protocolVersion，并冻结七个稳定 feature flags：

- hardwarePreflight；
- preflightProof；
- emergencyStop；
- safetyAlerts；
- accountAdministration；
- spectrumDisplayWindow；
- swrTripReset。

iOS 以 feature flags 判断能力。整个 `features` 缺失，或旧服务器返回前六项但缺少
`swrTripReset` 时，缺失项一律解码为 false；不能使旧健康响应整体解码失败。硬件测试端点 404 映射为
server_feature_unavailable，并提示“服务器版本过旧或反向代理路径错误”。
其他端点的 404 仍保持通用错误。

真实 profile 的只读预检只有 `overallStatus === passed` 时才返回十分钟有效的
preflight proof；warning 和 failed 均不签发 proof，也不能授权 hardware TX 保存。
proof 使用进程内随机 HMAC 密钥签名，并绑定：

- 管理员用户 ID；
- 规范化 profile 的稳定 SHA-256 指纹；
- 签发和过期时间；
- 预检通过状态；
- 若在 reconfiguration fence 内签发，绑定完整 fence ref：随机
  `reconfigurationEpoch` 与单调 `reconfigurationGeneration`。

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
   预检期间收到该 radio 的紧急停止时，supervisor 必须按 §7 抢占并清理候选
   transport、执行 OFF/回读，并让本次预检失败且不签 proof；
5. 保存成功、用户取消或服务端单调时钟到期后进入 resume；仅在测试进程已确认清理
   完成时才可继续；
6. resume 使用不会写 PTT 的探测 transport 先读真实 PTT。只有确认 OFF 才解除 fence
   并按新配置或旧配置创建 `startupObserve` runtime；该 runtime 初始化和后续外部 PTT
   监测都不写 OFF。若 ON 或不确定，保持 fence，发布 external PTT/telemetry 告警；
   supervisor 保持低频、只读的 probe，直到现场 PTT 自行恢复为 OFF 后才恢复 runtime。

每个 supervisor 构造时生成不可预测的 `reconfigurationEpoch`，并在该 epoch 内单调
递增 generation；进程或 supervisor 重建必须得到新 epoch，禁止数值复用命中旧请求。
preflight 回复返回完整 `{ reconfigurationEpoch, reconfigurationGeneration }` fence ref，
fence 内签发的 proof 也绑定同一 ref。保存完成 fence、cancel 和 resume 都必须携带这
两个精确字段；缺失或任一不匹配在任何写入、取消或 runtime 变更前返回
`stale_reconfiguration_generation`，不能查看、取消、恢复或覆盖当前的新 fence。
iOS 将完整 ref 与对应草稿一起保存，匹配完成后立即清除；真实 upsert envelope 同时
按以下三种互斥形状冻结，不能混用：

1. Dummy 或 `hardwareTxEnabled=false`：不携带 `hardwareTxConfirmation`、proof 或 fence；
2. `hardwareTxEnabled=true` 的真实 profile、且不在 fence 内：携带
   `hardwareTxConfirmation=profile.id` 和仍有效、指纹匹配、passed 的普通 proof，只省略
   `reconfigurationEpoch`/`reconfigurationGeneration`；
3. fence 内的真实 profile：携带同样的 confirmation、passed proof，以及 proof/草稿
   所属的完整且匹配的 epoch/generation ref。

第二、第三种缺少或无法验证 proof 都在配置写入前返回 `preflight_proof_required`；不能
因为没有 fence 就放行普通真实硬件保存，也不能把 half fence pair 当普通保存。

resume 读到 ON 或 unknown 时保留同一 fence ref，并由唯一 supervisor 以低频、只读
probe 自动继续；后来读到 OFF 后才解除 fence 并恢复 runtime。测试必须覆盖旧进程
epoch + 相同 generation、replacement fence、缺失/stale save 以及 ON/unknown→OFF 的
自动恢复，不能只测试 cancel/resume 的同进程计数器。

普通“保存”不会暗中停掉正在工作的电台。缺少 proof 一律返回
`preflight_proof_required`；只有所选 profile 占用当前 live managed-serial runtime 的
canonical 串口、无法在只读预检中取得独占 claim 时，预检端点才返回可识别的
`preflight_requires_runtime_stop`，由 iOS 引导管理员执行上述“停止该电台并预检”动作。
网络 rigctld、未占用串口及其他普通 proof 缺失不得滥用该错误。cleanup uncertain 时
设备继续 quarantine，不得签发 proof 或解除为可发射状态。fence 的取消、到期和安全
resume 均有审计与假时钟测试。

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

所有 HTTP 登录/配对限速和 WS pending/active 连接预算只消费同一个
`SourceAddressResolver` 的规范化结果。resolver 接收 TCP socket peer、原始
`Forwarded`/`X-Forwarded-For` 和显式 trusted-proxy CIDR allowlist，并遵守：

- allowlist 默认为空；peer 不命中 allowlist 时完全忽略所有 forwarding header，只把
  规范化 socket peer 作为 source，同一 peer 伪造不同 XFF 仍共享同一预算；
- 只有 socket peer 命中 allowlist 时才允许 forwarding header 提供恰好一个可规范化的
  IP；IPv4、IPv6 和 IPv4-mapped IPv6 归一到唯一表示；
- trusted peer 提供 malformed、多个逗号值、多个 `for=`、两个 header 冲突或任何歧义
  时，在 Argon2、预算分配和 WS handleUpgrade 前拒绝，不能回退 socket peer 或任选一项；
- service、login limiter 和 WS boundary 不得自行解析、split、直接信任或二次 fallback
  `Forwarded`/`X-Forwarded-For`，避免出现多个 source producer。

新增并文档化以下 API 与 iOS 管理入口：

- 用户创建、启用/禁用、角色和 canTransmit 修改；
- 自助改密；
- 配对设备列表、命名和撤销；
- 管理员审计分页查看；
- 当前会话登出及相应实时撤销。

仍不增加观察员角色。

## 12. 审计、错误与敏感信息

安全审计保持 JSONL，按 8 MB 轮转，最多保留五个文件（当前文件加四个历史文件）。
每次 append 生成唯一 `id`；HTTP `AuditRecord = AuditEvent & { id: string }`。磁盘上的
`StoredAuditRecord` 另带进程随机、不可变的 `generationId`，HTTP 投影只删除
`generationId`，不得把它暴露给客户端。当前 generation 使用预打开的常驻文件句柄并
串行 append；轮转是明确的 generation
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

重新打开 current 准备 append 时，若末行不完整，必须通过已经安全打开的 current
handle 找到最后一个完整换行后的 byte offset，truncate 到该 offset 并 fsync，然后才
允许写下一条完整 JSONL；没有完整换行则 truncate 到 0。不能只补一个换行，也不能按
路径重新打开替换后的文件。告警只进入内存健康状态和 stderr，不能递归 append 到受损
日志。`reopen -> append -> reopen` 必须仍按新到旧读出完整的 `c,b,a`，损坏片段不会
成为中间永久记录。

管理员分页按 current、1、2、3、4 从新到旧跨文件读取，opaque cursor 编码不可变
`generationId + byte offset`，通过记录内容定位 generation，而不是把 current/`.1`
文件名写进 cursor。因此页面之间发生 current→`.1` rename 后仍能继续；只有该
generation 被五文件 retention 真正删除时才返回 `audit_cursor_expired`。cursor 不接受
客户端构造的裸 offset，HTTP 记录和 cursor 错误都不泄露 generationId。

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
之前完成 write 加 sync。意图审计子预算默认 250 毫秒并可配置、可测试，包含在 8 节
定义的 500 毫秒端到端起发准入总 deadline 内；它不假装能抢占已经在途的普通 sync
或轮转栅栏。队列满、子预算或总 deadline、
write 或 sync 失败均返回 `tx_audit_unavailable`，永久 disarm 该 start attempt，不得
创建 lease、绑定媒体或在后台稍后自动键控。尚未开始的超时意图从队列移除；已经开始
的写入可以完成并留下 requested 记录，但其完成也永远不能重新武装该 attempt。成功
键控后追加 keyed/result 记录；该事后记录失败只触发审计健康告警，不能妨碍停发。

紧急停发、权限降低、撤销、deadline 和 dekey 恢复永远不能等待审计；这类审计失败
另行 latch 告警。审计健康依赖只能阻止新的起发，绝不能反向阻止关闭发射。

删除基于错误消息正则的 400 映射。只有显式 ValidationError/HttpError 才能把安全
消息返回客户端，第三方和内部异常统一映射为固定 500。

非管理员读取 radio profile 时返回裁剪视图，不暴露串口路径、PTT 路径和原始音频
设备 ID。协议冻结独立的 role-aware read model：这些硬件标识在 operator 响应中可缺失，
iOS 的电台列表/控制页必须能解码该原始裁剪 JSON；只有管理员把完整响应转换为可编辑
profile 时才要求 device/audio/PTT 标识齐全，裁剪对象不得被重新编码成保存请求。无效
Cookie 不回退 Bearer 的保守行为保持不变，因为自动回退会隐藏会话
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
3. 在任何接收音频恢复 await 之前注册 reply waiter 并把首个 tx.stop 帧交给本地
   WebSocket transport；该 first-frame-enqueued/handed-off 边界不是服务端收件或 OFF 证据；
4. 首帧 handoff 后立即恢复本地接收音频，不等待三秒 reply deadline 或完整 retry 序列；
5. 后台等待 reply，成功确认后清 token；失败按同一 immutable key 短暂退避重试；
6. 本地有界重试耗尽或控制 WS 断开时，只保留“远端状态未确认”的降级告警；首帧
   enqueue 本身失败时也恢复本地接收，但绝不清 token 或伪称远端已停发。

channel 必须先注册 exact pending reply identity 再调用 send；若 send 抛错或任务取消，
在返回失败前原子移除并只失败该 continuation、取消其 timeout。晚到 reply 不能命中已
移除 waiter，失败路径也不能泄漏 pending request。

这同时避免松手后麦克风继续运行、手机发热、弱网下等待约十秒才能恢复收听，以及 UI
已显示远端确认停发但服务器尚未确认。
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
`SafetyAlertSnapshot { t: "safety.snapshot", safetyEpoch, radioId, revision, alert: SafetyAlert? }`。
`safetyEpoch` 是服务进程启动时生成的随机标识；revision 在同一 epoch 内按 radio
单调递增；`alert: null` 是“当前无持久告警”的唯一 snapshot 表达，recovered 只作为
带 `t: "safety.event"` 的增量 transition，不能充当空状态。持久 alert kind 不包含
recovered，增量 event kind 才包含；snapshot 中出现 recovered 必须解码失败。

SafetyEventHub 在同一个串行边界内先注册客户端、捕获完整 snapshot set 与 revision，
再只投递同 epoch 且 `revision > snapshot.revision` 的后续事件，状态变化不能落入订阅
与快照之间的空窗。每条连接的 outbound queue 必须先按顺序放入 snapshot begin、全部
radio snapshot、snapshot end，再放入这期间缓冲的增量事件；iOS 在 end 前缓存新 epoch
事件，并在完整 snapshot set 原子应用后再按 revision 回放。configured radio IDs 由
registry 注入 hub；从未 publish 过告警的 radio 也必须发送 revision 0、`alert:null`，
禁止空的 begin/end 让客户端遗留旧 radio 横幅。增量事件至少包含
safetyEpoch、radioId、revision、kind、startedAt；持久 kind 覆盖 active、external_ptt、
telemetry_uncertain、dekey_required、dekey_escalated、swr_trip_latched 和
swr_rearm_pending，增量 event 另可为 recovered。非管理员只收到分类后的 source，不公开
owner 身份；管理员可收到 owner userId，不发送凭证。

SafetyEventHub 为每台 radio 保留 transmit、swr、telemetry 三个独立 owner slot，并按
`dekey_escalated > dekey_required > swr_trip_latched > swr_rearm_pending > active >
external_ptt > telemetry_uncertain` 投影唯一有效 alert。清除 transmit slot 后若 SWR
slot 仍在，下一 revision 必须显露 SWR 状态；只有三个 slot 全空才发布 recovered 和
`alert:null`。客户端只消费该投影，不自行合并或按本地 PTT 猜测被遮挡状态。

每个 owner slot 另有自己的单调 `ownerGeneration`。同 owner 的 publish、替换和 clear
必须携带该状态转换开始时捕获的 expected generation，并由 SafetyEventHub 在同一串行
边界内 compare-and-swap；成功转换推进 owner generation，旧 generation 只返回 stale，
不改变 slot、radio revision 或客户端投影。因而旧的 transmit active completion 不能覆盖
更新一代的 dekey_required/dekey_escalated，旧 OFF clear 不能清除新 de-key latch，旧 SWR
rearm/reset completion 也不能覆盖更新一代的 swr_trip_latched。跨 owner 的显示优先级不能
替代这项同 owner 所有权检查。

begin 与 end 都携带 safetyEpoch；iOS 把每条 begin/snapshot/end/event 以及 disconnect
callback 所属物理 WebSocket 捕获的 connection generation 传入 reducer。snapshot 只在匹配
generation 的 active envelope 内收集，event 只由当前 generation 应用，只有 epoch 和
connection generation 同时匹配的 end 才能原子提交；`markDisconnected(generation)` 也只
处理当前 active generation。孤立 snapshot 以及旧 socket 的 delayed snapshot、event、end
或 disconnect 都不能改变新连接状态、丢弃其 snapshot envelope 或把已恢复的横幅标为 stale。
所有 safety
begin/snapshot/end/event 必须在 `selectedRadioId` UI guard 之前进入全 radio reducer；
该 guard 只过滤其余单 radio UI 事件，切换到 backup 时不得等下一次重连才有权威状态。

同一 radio 的持久发射横幅唯一由服务端 snapshot 加 revision 投影：本地按键状态只
显示“正在请求/正在停止”等瞬态控件，不能覆盖或清除服务端横幅；`rig.state.ptt` 只作
遥测。epoch 不匹配、乱序、重复、旧 revision 和其他 radio 的事件不得改变当前横幅。
新 epoch 的完整 snapshot 原子替换旧 epoch。断线或尚未取得 snapshot 时，iOS 保留
最后一个非 null 服务端 SafetyAlert 的全部 kind，并标记 stale/“远端状态未确认”；
dekey_required、dekey_escalated、swr_trip_latched、swr_rearm_pending 和 external PTT
至少保持原严重级别，不能因断线降级
消失。若从未收到非 null alert，但本地仍持有 stopPending，也显示该降级状态。只有
匹配 epoch/radio 的完整 snapshot 可以替换或清除这些 stale 状态。
重连后用服务端 snapshot 原子替换降级状态。旧服务器未声明 safetyAlerts 时进入明确
标注的兼容降级，不能伪称拥有权威安全状态。

电台页顶部使用不会反复弹出的持久横幅：

- 本机语音、数字或天调发射：红色，显示持续秒数；
- 外部/现场 PTT：橙色，明确“只告警，未自动干预”；
- 停发未确认或安全恢复中：深红色；
- `swr_trip_latched`：深红色，明确“禁止发射；请现场检查天线、馈线及功放”；
- `swr_rearm_pending`：琥珀色，明确“下一次发射是一次性受监测复位，首样本必须
  `<= reset`”；
- 恢复成功后横幅按事件状态消失。

横幅和电台页常驻紧急停止按钮。按钮调用 tx.emergency-stop，而不是复用要求旧
transmit token 的 tx.stop。

只有管理员、`health.features.swrTripReset=true` 且当前权威 alert 为
`swr_trip_latched` 时，横幅才显示“检查后复位”动作。动作先打开不会反复弹出的确认页，
要求用户主动勾选“我已现场检查天线、馈线及功放，并确认电台 PTT 已关闭”，再向精确
radioId 发送 typed `POST /api/v1/radios/:radioId/swr-trip/reset` 和字面量 true。操作员、
旧六 flag 服务器、`swr_rearm_pending` 或其他 alert 均不显示按钮；操作员仍看到精确文案
“SWR 保护已锁定，禁止发射；请联系管理员现场检查并复位”。403 明确提示仅管理员；
409 明确提示需先得到 PTT OFF 并完成 dekey/reconfiguration；超时或传输失败提示“复位
结果未确认，以服务器安全横幅为准”。任何错误、HTTP 2xx 或本地弹窗关闭都不能清除
旧横幅；2xx 后仍等待同 epoch/radio/revision 的 `swr_rearm_pending` 或后续服务端事件。

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

同时增加独立 web-check；`push.paths` 保留 `ios/**`、`radio-lite-server/**` 和 workflow
自身，并加入 `web/**`、`deploy/**`、`scripts/**`、`.node-version`，保证单独修改发布
检查、打包器或 native addon 构建脚本也会运行 CI。`pull_request` 不得配置 `paths` 或
`paths-ignore`，以下五个 required job 也不得使用 event/path `if`，因此 docs-only 与其他
任何 PR 都会得到终态检查结果，而不会因整份 workflow 被跳过导致 required check 永久
Pending：

- job id 与显示名均为 `web-check`，Ubuntu 并读取同一 `.node-version`；
- 当前 Web 没有依赖锁文件，先在 web 工作目录直接执行 `npm test`；
- 若以后引入依赖，必须提交 lockfile 后改为 `npm ci && npm test`；
- server-check 与 web-check 在所有 pull request 和匹配 `push.paths` 的 push 上运行；`release-readiness` 通过
  `needs` 依赖它们、协议检查和 XCTest，并额外实际执行 drain/socket/release harness；
  正式 artifact job 只能依赖 passing `release-readiness`。仓库 ruleset/branch protection 另将这些精确 job name 设为
  required checks；这是一次性仓库设置，不通过重复 GitHub 设备授权完成。

删除 IPA job 中硬编码的 0.2.3/9 断言。版本只从 project.yml/构建设置读取；
CI 验证版本非空且格式合法。

CI 同时产出：

- 绑定审核 commit 的 Radio Lite 服务端源码归档、SHA-256 与 commit companion；
- Debug unsigned IPA，用于诊断；
- Release unsigned IPA，用于长期真机、发热、功耗、Opus 和频谱性能测试。

三类 artifact 都只能在 `release-readiness` 通过后发布；缺少 drain controller、control
socket、consume-self-shutdown、目录内 release script 或任一对应测试的 commit 必须让
该 gate 失败。服务端归档内的 release.json、commit companion、artifact 名称和 CI
commit 必须一致。

完整 Linux 特权套件只由 `release-readiness` 以 root euid 运行，并通过
`RADIO_LITE_TEST_*` 保留正数非 root 服务身份以覆盖 ownership、supplementary groups、
`setresgid`/`setresuid` 与 FD 屏障。后续普通用户 `server-release` job 不重复这些套件，
也不构建 test-hooks addon；它依赖已通过的 gate，只重建审核 commit 的 production addon，
并以独立 Node 进程做 clean-load/ABI smoke test 后归档。

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
- emergency-stop 不需要旧租约且幂等；main+backup 测试证明只操作请求 radio，
  digital/media 抛错及候选 preflight 持有串口时仍必达该 supervisor 的 OFF/回读；
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
- external PTT ON→OFF 与 telemetry 恢复发出精确 `t:safety.event` recovered；每个 configured
  radio（包括从未告警者）都在完整 snapshot 中出现；
- SafetyEventHub 的旧同-owner active publish、OFF clear 和 SWR rearm/reset completion 均因
  owner generation/CAS 失败而不能降级、清除或覆盖更新一代 latch；合法转换仍按每台 radio
  revision 顺序发布，清 transmit 后先显露仍存在的 SWR slot；
- cold `require_swr` 不依赖零 RF 缓存；PTT ON 后一秒内必须取得合格首样本，缺失、
  失败或 `>= trip` 立即停发；运行中读数缺失/过期/失败仍立即停发；
- `SwrSafetyStore` 的 armed/latched/rearm_pending/rearm_in_progress 原子轮转、损坏或
  read-denied fail-closed 和重启恢复；temp rewrite、file/directory fsync、rename 或 remove
  失败都会 poison 后续起发准入，PTT ON 期间发生则立即进入停发。启动读到
  armed/rearm_in_progress 必须锁定。main 与 backup 并发更新后重新打开文件仍保留两条
  记录，证明 process-wide 串行 RMW 不丢更新；
- SWR trip 在 OFF 后仍锁定，只有管理员显式现场检查 reset 才进入一次
  rearm_pending；安全 rearm 首样本只改回 armed 并在 PTT ON 期间保留。继续发射后再次
  高 SWR，或在 armed→latched 重写前崩溃，重启仍为 latched；全程未 trip 且真实 OFF
  后才删除 armed；启动必须在共享 store FIFO 内把崩溃遗留的 armed/rearm_in_progress
  持久规范化为 latched，再开放管理员 reset，并覆盖 restart→reset→单次 rearm；
- fake-clock 分别延迟审计和 SWR store fsync，证明 500 毫秒总起发准入 deadline 包含
  250 毫秒审计子预算；超时废弃 permit 且 PTT 保持 OFF；
- service close 即使 media close 卡住也先调用 runtime close；
- SIGHUP 和异常关闭只执行一次并 exit 1；
- deployment drain 遇到活跃发射、dekey latch、外部 PTT ON、读回超时或并发
  tx.start 时均拒绝替换；旧/过期 proof、CLI 断线和回滚也覆盖。proof 签发后出现的外部
  PTT、mode、pending admission、dekey/SWR latch、runtime availability 或 telemetry freshness
  变化会推进 safety generation；consume 必须在同一 drain generation 与 safety 串行域重新
  取得全部 configured runtime 的新鲜快照和真实 PTT OFF，再原子 consume 并注册 shutdown；
- process identity guard 失败在 consume 前取消。consume 回复丢失分别覆盖“已注册 shutdown
  后丢回复”和“请求未处理/过期/拒绝后无回复”：只有同一 control endpoint 返回绑定
  boot/process identity、drain generation、socket inode 与 consume attempt 的认证
  registered-shutdown 状态才允许后续 SIGTERM；无法证明时不得 signal 或切换 current；
- 新旧进程使用相同 data/host/port/insecure 配置；control 目录精确为 service UID/
  deployment GID、mode 02750（含 SGID），socket 0660 与同目录创建的 instance.json 0640
  依靠 SGID 继承 deployment GID，非 root 服务不 chgrp。第二个/人工服务在 radio 初始化前
  输掉 service flock，不能删除活 socket 或覆盖 instance record；
- bind-first、dead-owner proof、socket+record 同 inode 复核和最多一次 retry 均有测试。
  shutdown 在 listener 关闭后按自有 same-inode socket → instance record → service lock
  顺序清理；两次 unlink 间 crash 形成的 record-only 状态，只能由持有新 lease 且已成功 bind
  的进程凭 opaque dead-owner proof，在再次核对旧 record inode 与当前新 socket identity 后
  删除旧 record 并发布新 record；socket-only/missing-record 仍 fail closed 并要求人工修复；
- 真实 Linux addon barrier 覆盖 pre-open symlink/parent substitution、after-open
  pathname swap、lock/log FD pinning 和 current swap 后继续使用旧 release-dir FD；Bash
  wrapper 只做绝对 `/usr/bin/node` 到固定 launcher orchestrator 的 exec，host prerequisite
  检查要求 `process.execPath` 与 root-owned/non-writable 路径元数据一致，并在 drain 前证明
  `process.versions.node` 精确等于已认证 manifest/`.node-version`，而不只验证 N-API；
  `/usr/bin/npm`、坏 npm-cli metadata 和任一 host-tool mismatch 均在 candidate/drain 前失败，
  正常 npm 命令的直接 executable 仍只有 `/usr/bin/node`；所有
  normal/health/rollback child 的 FD table 都不含 root/staging/parent/deploy-lock FD；archive
  child 除 log/cwd 外只多一个显式只读 archive FD。外部 sentinel 不变，事务结束后下一次
  部署可正常取得锁；schema-3 manifest 只接受 launcher contract 1 并锁定四组件 digest，
  兼容 identity 不改 launcher 即可部署，不兼容或未知未来 contract 在 candidate/drain/current
  前 fail closed。普通 deploy/rollback 对 launcher mutation 为零；显式 updater 的 active-TX
  拒绝、目录内 staging、deprivileged addon load、identity-last、异常 cancel 与 mixed-state
  fail-closed 均覆盖。SIGKILL 恢复测试要求固定 updater 从 pinned `.update-*` transaction
  复核 generation、boot/process identity 和 socket inode 后只取消该 drain；旧 transaction
  不能取消重启后或并发事务的新 drain。未知未来 contract 没有在线 re-bootstrap 测试路径，
  只能进入另行设计和复核的离线 bootstrap。

### 协议与认证测试

- 错误、正确和缺失 Origin 的 WS upgrade；
- trusted-CIDR source resolver 默认忽略 untrusted peer 的 Forwarded/XFF spoof；只有
  allowlisted peer 的单个 canonical IP 生效，trusted malformed/multiple/conflicting
  header 在限速、Argon2、预算分配和 handleUpgrade 前拒绝且不 fallback；IPv6 CIDR 与
  textual aliases 必须归一，IPv4 及其 IPv4-mapped IPv6 形式在 login/WS 使用同一 bucket；
- 半开连接在约两轮 heartbeat 内关闭；
- logout、改密、禁用和设备撤销立即使旧 WS 失效并先停发；
- 登录双维度限速不进入 Argon2 队列；
- 六位码完整封禁时长和每码全局上限；
- 审计轮转每个 crash point、代际句柄、崩溃末行、跨五文件分页、权限及安全事件覆盖；
  每个 HTTP `AuditRecord` 有唯一 id 且无 generationId；cursor 用 immutable
  generationId+byte offset，在 current→`.1` rename 后继续，只有 retention 删除后
  expiry；损坏 current 用已打开 handle truncate+fsync 后 append，reopen→append→reopen
  仍得到完整 `c,b,a`；
- 意图审计在 250 毫秒上界内 durable 后才能键控；队列满、write/sync 卡住或失败时
  PTT 保持 OFF，且不得残留 lease、token 或媒体绑定；超时后晚到的 durable write
  也不能重新武装该 start attempt；
- 真实 profile 无 proof 返回 `preflight_proof_required`，相同指纹 passed proof 允许，
  修改后拒绝；Dummy/禁用 TX、ordinary enabled-real、fenced enabled-real 三种 upsert
  envelope 分别验证字段。Dummy/禁用 TX 携带任一 confirmation/proof/fence、enabled-real
  缺 confirmation/proof、ordinary proof 携带完整或 half fence pair 都在 config write 前
  拒绝；ordinary 必带 confirmation+proof 但不带 fence；
- 运行中 managed-serial profile 必须通过“停止并预检”fence，串口不会被自己的
  runtime 阻塞；warning/failed、活跃/未知 PTT 或 cleanup uncertain 时不能签发 proof；
  保存、取消和到期恢复都先做无写入 PTT 探测；ON/unknown 后同 fence 低频探测至 OFF
  自动恢复；旧 epoch 即使 generation 数值相同也不能 cancel/resume/save，新旧 save
  缺失或不匹配 ref 在 proof/config 写入前失败；只有占用 live canonical managed serial
  的预检返回 `preflight_requires_runtime_stop`，普通缺 proof 和网络设备不得返回该码；
- 频段外、频率未知、SWR trip/恢复与不支持 SWR 的确认策略；
- 健康接口精确返回七个 feature flags；管理员 SWR reset 路由只接受字面量 physical
  inspection acknowledgement，PTT ON/unknown、dekey/fence、操作员和缺少确认均拒绝，
  成功只产生 rearm_pending 而不宣称零 RF 已恢复。

### iOS 测试

- 旧 rig.state 回复不能覆盖新频率/模式；
- HTTP 仍为 300 秒，WS 为 15 秒；
- 首个 tx.stop frame handoff 早于接收音频恢复，而 deferred reply 和 retry completion
  晚于恢复；弱网不等待整段重试才恢复收听。首帧 send 失败/取消会原子移除 exact
  pending waiter，晚到 reply 不能命中且没有 continuation 泄漏；
- 停发失败保留 token、重试并显示未确认；
- safetyAlerts snapshot 是横幅权威；覆盖 snapshot/event 原子交接、`alert:null`、
  新 epoch、乱序 revision、其他 radio 和本地旧 PTT 状态；recovered 只能解码为 event，
  孤立 snapshot 与旧连接 delayed snapshot/event/end/disconnect 不能提交新状态、清掉新
  envelope 或把新连接标为 stale，safety 消息在 selected-radio guard 前全量 ingest；断线
  降级在重连 snapshot 后原子替换；
- 连接在 active、external PTT、dekey_required 和 dekey_escalated 任一状态断开时，
  stale 横幅不消失也不降低严重级别，只有完整匹配 snapshot 可清除；
- 原始 snapshot/event 可解码 `swr_trip_latched`/`swr_rearm_pending`，两者断线后保持
  stale 且按服务端固定严重级别显示；旧六 flag health 将 `swrTripReset` 解码为 false；
- SWR reset 只对管理员、feature=true、当前 trip latch 显示；未勾选现场检查不发请求，
  typed POST 使用精确 radioId 和字面量 true。403、409、超时、失败和 2xx reply 均不
  本地清横幅；只有权威 `swr_rearm_pending`/后续 snapshot 可改变状态；操作员无按钮但
  显示“请联系管理员现场检查并复位”的精确横幅文案；
- 本地 start 尚未得到 server active 时不显示持久红色横幅；本地松手、停止音频或
  emergency-stop reply 都不能清除仍为 active/dekey 的服务端横幅；
- 404 feature-unavailable 与其他 HTTP 错误分开；
- 原始 legacy JSON 缺 ranges/SWR 解码为 configuration-required；operator 裁剪的音频/
  串口响应能进入电台列表但不能转成可编辑保存 profile；fenced upsert 同时携带 proof
  与完整 epoch/generation ref，旧 completion 不清 replacement ref；
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
9. 先完成 drain/socket/目录内 release script、launcher contract 与独立人工 updater，再由 release-readiness 做全量回归并生成
   正式 server archive、Debug/Release IPA，最后文档和发布。

每个切片有独立失败测试、实现、局部测试和提交。最终统一跑全量验证。

## 19. GitHub 与 Debian 发布

开发期间所有提交先保存在本地。全部验证通过后使用：

- .codex-ssh/github_radio_deploy_ed25519；
- .codex-ssh/github_known_hosts；
- SSH port 443；
- StrictHostKeyChecking。

不调用 gh auth login，不生成设备码。推送失败时不阻塞开发，保留本地提交并刷新
Git bundle。

正式命名的 server archive 与双 IPA artifact job 只允许依赖一个 CI
`release-readiness` gate。该 gate 必须在同一 commit 上实际运行完整 server/Web/协议/
XCTest、deployment drain/socket 和 release-script harness；缺少 drain controller、CLI、
release script 或其测试时 gate 必须失败，因此中途 push 不能发布可误用的正式 archive。

Debian 发布只在新版服务端与 IPA CI 通过后执行：

- 所有新版本、备份、数据和回滚材料都放在 /opt/testradio；
- 读取并保留当前数据目录、监听地址和端口；
- 不删除 testradio 目录；
- 不修改 /opt/testradio 以外的服务、文件或目录；
- 健康检查失败时只在该目录内回退；
- 首轮只用 Dummy，真电台由用户另行确认后测试。

部署脚本先在 `/opt/testradio` 内核对 CI 归档的显式 SHA-256、commit companion 与
`release.json`，在旧服务仍运行时完成依赖安装、服务端/Web/协议候选检查；任一失败都
不能请求 drain、停止进程或切换 current。通过候选检查后才进入下面的同 generation
停发证明流程，五秒 proof 窗口内不再安装依赖或运行候选测试。

release shell 入口固定 `/bin/bash` shebang，并只允许执行常量形式的
`exec /usr/bin/node /opt/testradio/launcher/radio-lite-release.mjs "$@"`；不得使用
`/usr/bin/env`/PATH 解析解释器，Bash 也不得读取、
创建、重定向、append-open 或验证任何受管路径。Node orchestrator 只加载同一预装
launcher 内 root-owned、不可写且架构/N-API 匹配的 Linux N-API C addon；候选 CI 归档
内的 addon bytes 只能由该可信 addon 验证，不能在 root 进程中直接加载。Debian 必须提供
`openat2(2)`；addon 缺失/不匹配、`ENOSYS` 或任一安全约束失败都在 drain 前退出 70，
没有 lstat/realpath 或 JavaScript 路径检查 fallback。初始管理员 bootstrap 安装 root-owned、
不可写的 `/opt/testradio/launcher/radio-lite-release.sh`、绝对 `/usr/bin/node`、
`radio-lite-release.mjs`、独立 `radio-lite-launcher-update.mjs`、匹配 addon 与
`launcher.json`；普通部署不得通过 `current` 装载或改写这组 trust boundary。runner 必须
在任何受管路径 open 或 drain 前验证 `euid=0`，否则退出 77。

`release.json` schema 3 必须含字面量 launcher contract version 1，以及 release wrapper、
orchestrator、updater、secure-fs addon 四个实际归档字节的 SHA-256。安装的 `launcher.json`
记录同一 contract/digests。当前在线协议只实现 contract 1；普通 deploy/rollback 和固定
updater 对任何其他值都在 candidate、drain 以及任何 managed/launcher mutation 前
fail closed，不能把未知未来 contract 当成可恢复的 mixed state。普通 deploy/rollback 在
认证 archive 后、任何 candidate/drain 前，通过 pinned launcher dirfd 复核每个组件 root
owner/mode/type/nlink 与实际 digest；不匹配以 78/`launcher_update_required` 退出，且不得
candidate、drain、切换 current 或自动修复。

launcher 变化只能由管理员显式运行固定 updater，并传 reviewed archive hash/commit 与
`--confirm-contract`。updater 独占 deploy lock，取得但不 consume 安全 drain；active/unknown/
external PTT/dekey 拒绝写入。临时目录、transaction generation 与所有组件 mutation 严格在
`/opt/testradio/launcher` 内，候选 addon 只由降权 empty-group child clean-load，四个文件以
pinned parent+basename 原子替换，`launcher.json` 最后提交；所有正常成功/失败路径随后取消
精确 drain generation。中断造成 contract-1 mixed identity 时普通部署继续 fail closed，只有
能验证旧/目标 contract-1 transaction 的同一固定 updater 可以显式重试。未知未来 contract
不允许在线 re-bootstrap 或自动升级；它需要先让服务离线，并经过独立设计、复核和 bootstrap
流程，本设计不授予该写入路径。

updater 必须在第一次 launcher mutation 前，把 transaction basename、drain generation、
旧服务 boot ID/PID/start token/cwd/release commit、control socket device/inode 和目标组件
digests 写入并 fsync 到 pinned `.update-*` transaction。SIGKILL 后只能调用固定 updater 的
recovery 子命令：它先取得同一 `deploy.lock`，以 pinned launcher/control dirfd 验证 transaction
owner/mode/type/nlink 和内容，再要求当前 instance record、认证 control reply、process identity
与 socket inode 全部等于记录值，最后把完整 tuple 交给服务端取消仍未 consume 的同一 drain。
任一字段不匹配、旧进程已消失、服务已重启或 generation 已被复用时，都不得向当前服务发送
裸 generation cancel，更不得清除其他事务的 drain；旧 transaction 只保留为诊断证据。

精确 Node 24.7.0 位于 `/usr/bin/node`；固定 `/usr/bin/tar` 和
`/usr/share/nodejs/npm/bin/npm-cli.js` 也都是用户预先提供的只读 host prerequisites。
native addon 只读验证固定路径、root-owned 且不可由
group/other 写入的全部 parent、owner/mode/type/link/no-symlink；运行 Node 版本必须精确等于
artifact 的 `.node-version`（初始 24.7.0），失败在 candidate 或 drain 前退出。部署不安装、
升级或修复这些 host tools。Hosted CI 的正例只能使用 test addon 在私有 root-owned fixture
上生成的 opaque host-tool probe，并仅由同一 test addon 注入的 `runRelease` 接受；生产 addon、
环境、CLI 与 `RADIO_LITE_TEST_*` 都没有路径/版本覆盖。另以真实 setup-node 执行 production
entry，必须在 `openRoot`、lock、drain 前以 70 和精确路径不匹配诊断失败。

服务/部署身份及 dialout/audio 设备权限是用户预先提供的主机前置条件。本设计只能读取并
验证其数值 UID/GID 和 device-GID allowlist；不得创建或修改用户、组、membership、ACL、
`/etc` 或设备状态。缺失或不一致时在部署前失败。初始 root bootstrap 和后续显式 launcher
维护的所有实际写入
仍严格限制在 `/opt/testradio` 内。

addon 先打开并验证 `/opt/testradio` root directory FD；之后 run、incoming、releases、
staging、config、data、backups、logs、cache、tmp、部署/服务 lock、日志、instance record、runtime.env、
archive 和 release executable 的每次读取、创建、rename、执行与检查都只能相对保留的
directory FD 完成。所有 descendant open 使用 `openat2` 的 `RESOLVE_BENEATH |
RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS`，并使用 `O_NOFOLLOW | O_CLOEXEC`；每个
返回 FD 立即 `fstat` 验证期望的 UID/GID、mode、文件类型和 `nlink`。日志重定向必须把
已验证日志 FD 直接交给 child，Node/Bash 不能在验证后按路径重开。任何 pre-open
symlink/parent substitution 必须失败；after-open pathname swap 只能改变已不再使用的
名字，不能把已 pin 的 lock、日志、runtime 或 release FD 重定向到外部。所有创建、
删除、链接和 rename 都先用 `openat2` pin 直接 source/target parent，再只把单段 basename
交给 `*at` syscall；mutation API 不接受 `a/b`。

`run/deploy.lock` 必须在 bootstrap 时预创建为 root-owned、单链接、mode 0600，其 pinned
`run` parent 必须 root-owned 且 group/other 不可写。orchestrator 从启动到事务结束只以
`O_RDWR|O_APPEND|O_CLOEXEC`、明确不带 `O_CREAT` 打开并验证同一 inode，再执行非阻塞
`flock`；锁缺失或元数据不符直接退出 70，不能运行时补建。第二个部署必须在请求 drain
前失败；正常、候选检查、健康检查和回滚 child 都不能继承 lock/root/staging/parent FD，
长期服务退出 exec 后父部署进程仍独占锁，事务结束关闭后下一次部署才能获得。所有 child
在 exec 前必须先以 checked `setgroups` 替换继承组，再 checked `setresgid`/`setresuid`：
archive/candidate/health 使用空组，只有新/回滚服务取得不含 deployment group 的严格
device-GID allowlist；任一步失败都不得执行。child executable 只能是固定绝对
`/usr/bin/node`、`/usr/bin/tar`，禁止 PATH 搜索。npm candidate 命令由专用 native API
固定执行 `/usr/bin/node /usr/share/nodejs/npm/bin/npm-cli.js ...`，既不接受脚本路径参数，
也不执行 `/usr/bin/npm`/`/usr/bin/env`。共享数据和监听参数只从 addon 打开的
`config/runtime.env` FD 按允许键逐行解析，禁止 `source`/`eval`；至少固定解析后仍指向
root 下 data FD 的 `RADIO_LITE_DATA_DIR`、可配置 HOST/PORT、显式 ALLOW_INSECURE 及服务/
部署 UID/GID/device GIDs。变化的 `RADIO_LITE_RELEASE_COMMIT` 不得存入 runtime.env，
新服务注入 reviewed commit、回滚服务注入 pinned old commit；新旧 release 使用同一组
其余已验证配置，健康检查从该端口派生，不能退回 `./data` 或默认 8787。

另在同一 root-owned、group/other 不可写的 `run` parent 中预创建 service-UID/service-GID、
单链接、mode 0600 的 `run/service.lock`。服务只能通过 native 窄接口以固定路径、不带
`O_CREAT` 打开并取得 `LOCK_EX|LOCK_NB`；该 close-on-exec lease 从 radio 初始化前一直
持有到完整关闭末尾。它与 deploy lock 完全分离，部署进程/child 不继承 service lock，
长期服务也不继承 deploy lock。第二个或人工启动的服务拿不到锁时必须在初始化 radio、
bind、unlink 或写 instance record 前失败；不能借同 UID 删除活服务的控制路径。

server archive 及其精确 `.sha256`/`.commit` companion 必须从同一个 pinned `incoming`
directory FD 各打开一次；严格解析 companion，并要求其与显式参数、用 `pread` 从同一
保留 archive FD 计算的实际 hash、以及 archive 内 `release.json` 全部一致。tar listing
和 extraction 只能接受由只读 archive opener 产生、native role/access-mode 再验证的
opaque ArchiveFd，并映射到固定 child FD；lock/log/general FD 必须拒绝，hash 后不得按
pathname 重开。private stage 创建必须同时返回 pinned directory FD 与 addon 生成/验证的
单段 basename，以 service UID/GID、mode 0700 供降权后的候选命令使用；候选
通过后以 anchored no-follow walk seal 为 root-owned、service-group-readable 且不可写的
release tree，再通过 pinned staging/releases parent FD 与 basenames 安装。seal 或降权后
遍历/只读验证失败都必须发生在 drain 前。

`current` 是唯一允许的受管 symlink。addon 通过 `readlinkat(rootFd, "current")` 读取，
只接受字面量相对值 `releases/<40 位小写十六进制 commit>`，再用相同 openat2 约束打开
并 pin 该 release directory FD；后续旧 CLI、instance record、cwd 和 executable identity 都从该
FD 判断，即使测试在 read 后交换 current 也不能改变本次事务。切换只在 root FD 下以
`symlinkat` 创建临时链接并 `renameat` 原子替换。

服务端在 service-UID owned、deployment-GID 的 `run/control` 目录中监听 control socket；
目录 mode 精确为 02750 并验证 SGID，deployment identity 只有 traverse/read/connect、没有
目录写权限。socket mode 固定 0660；同一 pinned control dir 中创建的 record 临时 inode 与
最终 `instance.json` mode 固定 0640。二者都必须通过 SGID 目录继承已配置的 deployment GID；
服务进程的 primary/supplementary groups 不含该 GID，非 root 服务不得也不可能以 chgrp/fchown
补救。脚本不创建组、不修改 `/etc`。持有 service lock 后必须先通过 pinned control-dir FD 的
`/proc/self/fd/<N>/control.sock` bind，成功并验证继承后的 socket identity 后才可发布唯一、
service-owned、deployment-group-readable 的 `run/control/instance.json`；该 envelope 同时记录
process identity 与 socket device/inode。

现存记录不因 commit 相同而覆盖。`EADDRINUSE` 后才允许发送 nonce probe，并把回复与
instance record、boot ID、PID/start token、cwd/release inode、socket inode 全部交叉验证；
live、超时、缺记录或不一致都 fail closed。只有 native opaque dead-owner proof 才能进入
socket+record stale 清理，unlink 前同时复核两者 inode，只接受 basename，随后最多重试 bind
一次。禁止先 stat/unlink 再 bind。

正常关闭在 runtimes/service 与 listener 关闭后，必须先 same-inode unlink 自有 socket，再
same-inode unlink 自有 instance record，最后释放 service lock。若进程在两次 unlink 之间
崩溃，新进程取得 lease 并成功 bind 新 socket 后，可由 lease 窄接口为 record-only 状态生成
绑定该 lease 的 opaque dead-owner proof；它必须证明旧 record owner 已死、bind 曾在该路径
成功，并在 unlink 前再次核对旧 record inode 与当前新 socket device/inode，随后只删除旧
record 并 exclusive publish 新 record。bind 后、publish 前崩溃留下的 socket-only，或
`EADDRINUSE` 时缺失 record，仍视为不可认证并 fail closed/manual repair，绝不能猜测删除。
Linux 没有 `connectat(2)`，部署侧也只通过 pinned control-dir FD 的
`/proc/self/fd/<controlDirFd>/control.sock` 连接；boot-bound HMAC proof 和
`{bootId,pid,processStartToken,cwd,releaseCommit}` process identity 仍是部署授权，不能仅凭
连接成功信任服务。
服务端持有 drain ownership，不因 CLI 断开或客户端退出而解除，并分配单调
drainGeneration：进入 draining 的同步步骤必须先调用 `invalidateTransmitStarts` 推进
独立 transmit-admission generation，再拒绝新 upgrade、控制和 tx.start，但保留
emergency-stop；任何已 reserve、仍等待 durable intent audit 或 permit commit 的起发都
以 `pendingTransmitAdmission=true` 进入快照并视为不安全。晚到 audit 可以留在审计日志，
但旧 permit 永远不能 commit 或键控。每个会使安全快照过期的 mode/pending admission、
dekey/SWR latch、外部 PTT、telemetry freshness、runtime availability 或 supervisor epoch
变化还必须同步推进独立的 deployment safety generation，使所有尚未 consume 的旧证明失效。
随后才在同一个 drain generation fence 内证明所有 configured runtime 均无 voice/digital/
tuning、`dekeyRequired=false`，并取得新鲜 PTT OFF 回读。

safe-to-stop proof 绑定 process boot id、drainGeneration 和签发单调时间，最长有效五秒；
proof 还绑定签发时的 deployment safety generation。签发与首次 PTT 回读在同一 drain
安全串行边界；consume 时必须在相同 drain generation 的同一串行域重新枚举全部 configured
runtime，取得新鲜 PTT 和完整安全快照，并在 await 后复核 safety generation 未变化，然后
才可在一个不可分割的提交中标记 proof consumed 并向现有幂等 shutdown owner 注册关闭。
旧 generation、旧进程、超时 proof 或任何中间安全变化均拒绝，且不得 signal。服务不可达、
读回超时/不确定、外部 PTT ON、正在发射或 drain 期间并发起发都必须拒绝部署，不能靠
“先检查再重启”的竞态窗口继续。CLI 成功返回 0；活跃发射返回
10、latch/外部 PTT 返回 11、遥测不确定返回 12、服务/本机认证不可用返回 13。这些
drain/安全 gate 非零路径不得停止、替换或删除任何 release/进程，只保留 drain 以便 emergency-stop 或由
明确的 `deploy drain-cancel` 安全解除。

`drain` 的安全回复同时返回旧进程的 boot ID、PID、进程启动标识、cwd、releaseCommit、
control socket device/inode 与 deployment safety generation。
部署脚本在 proof 尚未 consume 时核对唯一 `instance.json`、socket inode、control reply、cwd inode 与 pinned
release commit 全部一致、启动标识未变化；任一失败
都以完整 `{drainGeneration,bootId,processIdentity,socketIdentity}` tuple 调用 drain-cancel；服务
只取消仍由该 tuple 拥有且未 consume 的 drain。`proof-consume` 带随机 consume attempt ID，
并按上段规则在旧服务进程内部原子重验安全、一次性消费 proof、记录 attempt 对应的
registered-shutdown 状态，再调用现有幂等 shutdown owner 自行停服；不得由脚本先 consume、
随后才做可失败的 PID/cwd guard。

若 consume 回复丢失，脚本不得先以旧进程自然退出推断请求已处理；必须先通过同一已认证
control endpoint 的 `consume-status` 取得 boot-bound HMAC 状态，证明完全相同的 attempt、
drain generation、process identity 与 socket inode 已注册 shutdown。只有取得该证明后才允许
等待该精确旧进程退出；有界等待超时后，还须再次核对 `/proc` 身份才能发送有限 SIGTERM。
请求未处理、proof 过期/拒绝、状态不可达、进程在 status 证明前消失或任何字段不一致都
fail closed，不得 signal、切换 current 或改动 release。测试必须分别覆盖已注册后丢回复与
未处理/拒绝后无回复，后者的 wait/signal/current mutation 计数必须为零。

若新版本健康检查失败，只有能证明它从未取得任何 runtime/发射能力，或已对它完成
同样的 drain，才允许启动旧版本回滚。部署测试覆盖旧 proof 重放、proof 超时、CLI
断开后 fence 仍在、各非零码无替换副作用及回滚路径。回滚必须先等待失败的新进程退出、
由内核释放 service lock；不能让旧服务与仍活着的新服务争夺或覆盖 control endpoint。

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
  safetyAlerts 权威；同 owner 的旧 publish/clear 不能越过 owner generation/CAS 改写新 latch；
- 外部现场 PTT 只告警，除非用户主动点击紧急停止；
- 杀死 rigctld、断媒体、断控制、过期租约和关闭服务均通过 Dummy 故障测试；
- FT8/FT4 不能在客户端消失后自行续控制权；
- iOS 松开 PTT 后麦克风和本地音频会话立即结束；
- iOS 在 15 秒内报告失联控制命令，HTTP 慢连接仍可等 300 秒；
- 硬件预检、频段范围与 SWR 策略在真实 profile 保存和发射入口生效；
- `require_swr` 的 armed/trip/rearm 状态跨重启 fail closed，现场检查 reset 只授予一次
  受监测 rearm，PTT ON 期间绝不删除 armed marker；
- 旧 8 kHz 频谱帧可按 3–4 kHz 设置正确裁剪；
- 混合跨度的瀑布历史逐行按自己的 span 正确显示；
- 账户/设备撤销即时生效，审计有界并可查询；
- 稳态 CAT 预算受测试约束；proof consume 在同一 safety 串行域重新确认全部 runtime 的
  新鲜 PTT OFF，无法认证 registered-shutdown 的丢回复路径绝不 SIGTERM 或替换进程；
- `service.lock` 保证只有一个服务实例；活/不可验证的 control endpoint 永不被替换，
  02750 SGID control 目录使 socket/record 安全继承 deployment GID；`instance.json` 仅在持锁
  且 bind 成功后发布，record-only crash 可凭 lease-bound proof 恢复，socket-only fail closed，
  关闭时按 socket、record、service lock 顺序清理；
- server artifact 只接受 launcher contract 1 并绑定四组件 digest；普通部署不兼容或未知
  contract 时在 drain 前退出 78 且绝不自更新，只有固定人工 updater 可在
  `/opt/testradio/launcher` 内 identity-last 更新 contract-1 组件，并以完整 transaction identity
  恢复取消 SIGKILL 遗留 drain；未来 contract 只能另行复核离线 bootstrap；
- 服务端、Web、协议、XCTest、Debug IPA 和 Release IPA 全部通过；
- 本地提交、GitHub 推送和 Debian 部署遵守既定认证与目录安全约束。
