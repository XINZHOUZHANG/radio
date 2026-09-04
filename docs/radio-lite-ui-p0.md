# Radio Lite：P0 UI 与交互改造

本任务中的 TX5DR 指 Radio Lite 的旧名称，所有改动均应用到 `ios/RadioLite` target。
基线为已通过 Actions 的 `94a53a54875a4fda44d9e3e7685fa94759c14fd7`（0.2.12 / 24），本批版本为 **0.2.13 / 25**。

## 文件映射

以下路径均相对仓库根目录。

| 功能 | 路径 | 类型或入口 |
| --- | --- | --- |
| 设计令牌 | `ios/RadioLite/App/RadioLiteTheme.swift` | `TX`、`DecodeKind`，按任务提供的 Swift 原文 |
| 兼容主题 | `ios/RadioLite/App/RadioTheme.swift` | `RadioPalette` 委托给 TX；`RadioPanel`、`RadioActionButtonStyle` |
| FT8 单行、时隙与筛选 | `ios/RadioLite/Features/RadioLite/RadioLiteFT8View.swift` | `RadioLiteFT8View` |
| 解码语义与格式化 | `ios/RadioLite/Features/RadioLite/RadioLiteFT8DensePresentation.swift` | `RadioLiteDenseDecodeSemantics`、`RadioLiteDenseDecodePresentation` |
| 电台模式、控制权和 PTT | `ios/RadioLite/Features/RadioLite/RadioLiteRadioView.swift` | `RadioLiteRadioView`、`RadioLiteHoldButton` |
| 波段、频率和长按步进 | `ios/RadioLite/Features/RadioLite/RadioLiteFrequencyControls.swift` | `RadioLiteFrequencyControls` |
| 滑块与页面滚动协调 | `ios/RadioLite/App/RadioLiteScrollInteraction.swift` | `radioLiteSliderEditing` 环境值 |
| 参数滑块 | `ios/RadioLite/Features/RadioLite/RadioLiteRigControlsView.swift`、`RadioLiteCapabilityControlRow.swift`、`RadioLiteControlDashboardView.swift` | 兼容控件、能力控件和参数弹层 |
| 日志与 UTC | `ios/RadioLite/Features/RadioLite/RadioLiteLogbookView.swift` | `RadioLiteQSORow`、`RadioLiteLogTime`、`RadioLiteQSORecordDetailView` |
| 设置分组 | `ios/RadioLite/Features/RadioLite/RadioLiteSettingsView.swift` | `RadioLiteSettingsView`；本批保留分组，P1 再调整 |
| 频谱与瀑布 | `ios/RadioLite/Features/RadioLite/RadioLiteSpectrumView.swift` | `RadioLiteSpectrumView` |
| 跨标签导航 | `ios/RadioLite/Features/RadioLite/RadioLiteShellView.swift` | FT8 频率入口切换到电台标签 |

## 实现与验收边界

1. **令牌**：原样添加用户给定 Swift 代码；改动的视图显式字体和颜色引用 TX，既有调色板转接至同一来源。
2. **单行解码**：时间、SNR、音频频率、报文、旗帜/网格同处一行；用固定行高的 LazyVStack。标准行高 44pt，宽度小于 375pt 时 36pt。实际 iPhone 可见行数必须以截图复核，不将布局推算写作测量。
3. **语义颜色**：分词后匹配呼号，支持 `<CALL>` 和便携/复合呼号，避免 `BG4XYZ` 命中 `BG4XYZZ`；有人叫我优先于已通联淡化。CQ 仅染前缀，已通联使用弱文字与删除线。
4. **FT8 顶部**：3pt 进度、44pt 导航、30pt 时隙、44pt 固定筛选；信息说明进弹层。保留既有频谱、QSO、队列和手动操作入口。时间差均值仅采用当前模式最近 30 秒收到的有限数值，不修改协议或解码数据。
5. **横向滚动**：电台的实际 8 种模式排为 5 列两行，波段为 9 等分；所有相关滑块编辑时通过 UUID 持有滚动锁，退出释放，控件上下各留 12pt。
6. **PTT**：顶部合并控制权与连接状态；底部只有一行状态文案，原因放入信息弹层。保留原有 PTT enabled 条件及按下、松开、视图消失回调。功率与 SWR 以现有真实数据为准，缺值显示 —；不假造 30 W、1.2 或 Tailscale 链路。
7. **频率**：四档 ±、0.5 秒后每秒 8 步、原生 touch-up/cancel 区分点击与取消；拖动时锁定所选位的步长，避免跨 9→10 时位值漂移。切台、失去控制权、后台及消失均结束连续调节；慢链路合并未发送目标，不能撤回已经发出的那一条请求。
8. **UTC 日志**：列表、网格通联列表和详情统一 `MM-dd HH:mmz`，详情额外显示标明“本地”的时间。服务端 `radio-lite-server/src/log/adif-log-store.ts` 已用 `getUTCFullYear/getUTCMonth/getUTCDate/getUTCHours/getUTCMinutes/getUTCSeconds` 生成 `QSO_DATE/TIME_ON`，本批没有修改导出。
9. **频谱/瀑布**：7 段 TX 色标，移除原 `pow(..., 0.62)` 显示抬亮；青绿色频谱线、50%→3% 填充，TX 音频频率虚线采用相同归一坐标同时绘制在两图。保留模拟和不可用提示，删除“真实声卡 FFT”徽标。

## 明确没有冒充完成的部分

- **30 秒第 10 分位噪底**：未实现。`RadioLiteMediaClient` 已在进入视图前做 AGC 和 8 位归一化，瀑布历史又降采样且缺少逐帧时间。视图层不能可靠恢复物理噪底；为了遵守不修改 FFT/媒体管线的边界，保留现有 AGC。新色标的静默效果仍待实机观察。
- **本站 TX 解码行**：现有接收解码模型不含可靠的本地 TX 来源标记。呈现器支持明确的 `isConfirmedLocalTransmit`，收到的含本站呼号消息按“叫我”显示，不根据文本伪造本台 TX 记录。
- **真实解码语义验收**：新增纯显示回归样例不等于真实电台记录回放；目前没有执行 RF 或真实解码采集。
- **Xcode / 截图**：本机为 Windows，没有 `swift`、`xcodebuild`、iOS 模拟器或 SwiftUI Preview。不能提供真实的四页截图，也不能本地确认无新增编译警告。沿用仓库 macOS Actions 编译与 XCTest；按 AGENTS.md，不等待或轮询构建。
- **P1**：设置重分组、完整 QSO 阶梯、新账户/证书能力及进一步频谱组件重构不在本批范围。

## 本地验证

- 用户提供的主题 Swift 代码与新增主题文件进行标准化换行后的逐字比较。
- `node scripts/check-ios-radio-lite-contract.mjs`
- `node scripts/check-radio-control-dashboard.mjs`
- `git diff --check`
- 检查改动视图无 `ScrollView(.horizontal)`、无裸十六进制和旧蓝色 `2EB2F2`。
- 对比基线，确认 `ios/RadioLite/Core`、服务端、图标资产、图标生成器和工作流未变。

新 XCTest 由现有 macOS job 执行，本地结果与 CI 结果分别报告。没有执行硬件测试、部署 Debian、修改密钥或进行发射操作。

### 本次已取得的本地结果

- iOS 协议契约通过：16 个 HTTP 路径、18 种控制消息，以及遥测、音频卡、媒体与二进制帧契约。
- 电台控制面板契约通过。
- `git diff --check` 通过；新增 13 个解码呈现 XCTest 与 2 个 UTC XCTest 未在 Windows 执行。
- 改动视图无横向 ScrollView、裸十六进制或裸字体；Radio Lite 应用目录未发现旧蓝色 `2EB2F2`。
- 受保护的 Core、服务端、图标、生成器和工作流相对基线没有改动。PTT 手势及松开回调与基线去除空白后相同。

### 可见行数：布局推算，不是实测

按任务给定 390×844pt 画布、顶部安全区 59pt、底部标签/安全区合计 83pt 估算，可用高度为 702pt。
固定顶部 121pt，操作条 64pt，解码区为 517pt。无呼叫卡、一个时隙分隔 20pt 时可完整显示 **11 行** 44pt 解码，第一行 y≈200pt。
显示 66pt 呼叫卡时省去首组重复分隔，解码区为 451pt，可完整显示 **10 行**，第一行 y≈246pt。
以上假设同一时隙有足够消息；额外时隙分隔每组占 20pt，会减少可见行数。实际安全区、系统字体与设备显示需要截图验收。

## 手机检查重点

安装时核对版本 0.2.13（25）；在同一屏幕尺寸、默认字体下记录 FT8 的首行纵坐标及实际可见行数，分别截取无呼叫卡和有呼叫卡的布局。检查精确呼号/复合呼号、已通联 CQ、滑块滚动、± 短点及长按松手、UTC 跨日显示。PTT 三态只能用模拟状态或已有获准的测试条件核对；本次开发没有执行发射。
