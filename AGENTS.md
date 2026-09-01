# AGENTS.md

本文件是本仓库对 AI 编码代理（Codex / Claude Code 等）的常驻约束。
代理在开始任何任务前必须先读完本文件。**这些规则不需要在每次对话里重复粘贴。**

---

## 0. 本项目是什么

远程控制 Yaesu FT-710 电台。**代码会让一台真实的电台发射射频。**

- 目标电台：Yaesu FT-710（Hamlib model 1049）
- 服务端：Debian 13，Hamlib 4.6.2，`rigctld` 监听 127.0.0.1:4532
- 客户端：iOS 17+ SwiftUI
- 硬件真值记录在 `docs/hardware-truth-FT710.txt`——**关于电台能力的任何判断都必须引用它，不许从 Hamlib 版本号或文档推理**

---

## 1. 执行约束（防卡死）—— 违反即视为任务失败

这些规则的存在是因为执行环境会因 **SSE 空闲超时**断开：任何一步超过约 60 秒没有输出，连接就会掉，之前的工作全部丢失。

1. **每条可能耗时的命令必须包裹超时**：`timeout 120 <command>`
2. **不允许静默段。** 分步执行，每步开始时先 `echo` 一个进度标记：
   ```bash
   echo "STEP_1_FETCH"; timeout 60 git fetch origin
   echo "STEP_2_TEST";  timeout 300 npm --prefix radio-lite-server run test:ci
   echo "DONE"
   ```
3. **一次 SSH 会话只做一组检查，总时长不超过 120 秒。** 需要更多检查就分成多次会话，**不要合并成一个长脚本**——那正是历史上断掉的原因。
4. **禁止任何形式的等待与轮询**：
   - 禁止 `gh run watch`
   - 禁止等待 GitHub Actions 完成
   - 禁止 `while` / `sleep` 轮询循环
   - 触发后记录 Run URL 就停止
5. **禁止 `npm run test:watch`**——它永不退出。
6. **禁止裸跑 `npm test`。** 只用 `npm run test:ci`（带超时保护，见 §3）。
7. **遇到阻塞立即停止并汇报，最多重试 1 次。** 反复重试从来没有解决过问题，只会耗尽时间预算。
8. **禁止交互式命令**：`gh auth login`、`git rebase -i`、任何等待 stdin 的命令。包管理一律加 `--yes --no-audit --no-fund`。

---

## 2. 凭据与网络

边界已经铺平，**不要再临时创建凭据**：

- **GitHub**：使用仓库级 deploy key，路径见 `.ssh-config`。`known_hosts` 已提交在 `docs/github_known_hosts`。
  - **禁止** `gh auth login`
  - **禁止** 设备授权流程（device authorization）
  - **禁止** 修改 `known_hosts`
- **Debian**：使用 `~/.ssh/config` 中的 Host 别名 `radiotest`，长期有效。
  - **禁止**创建"临时自动过期"密钥——过期就是下一次卡住的起点
- **IPA 产物**：从 GitHub **Release** 下载，不要用 Actions artifact（artifact 需要登录，会返回 401）

如果凭据确实失效：**停止并汇报**，不要自己想办法绕过。

---

## 3. 测试

```bash
npm --prefix radio-lite-server run test:ci    # 唯一允许的测试命令
```

`test:ci` 带 `--test-timeout=30000 --test-force-exit`，任何阻塞的用例会在 30 秒后失败而不是永久挂起。

**48 个测试文件里有 14 个引用了 `rigctld` / `wsjtx-lib` / 声卡设备。**在没有硬件的开发机上它们会失败或跳过——**这是预期的，不是缺陷，不要为了让它们通过而安装软件或修改环境。**记录为"外部依赖跳过"即可。

---

## 4. 安全红线（不可协商）

- **禁止任何真实发射。** 当前没有假负载。不执行 PTT ON、Tune、FT8/FT4 发射、语音发射。
- **禁止削弱 fail-safe 行为**来让测试通过。特别是 PTT 的读回校验——它可能是唯一能发现电台仍在发射的机制。
- **禁止**为了让测试变绿而放宽任何安全断言。宁可让测试红着，并说明原因。
- Debian 上只允许操作 `/opt/testradio`，不得修改或删除该目录以外的任何文件。
- 不得停止、重启 `tx5dr.service`——那是正在使用的生产服务。

---

## 5. 测试的诚实性

区分**猜测**和**测量**。每一条基于假设的契约断言必须标注：

```ts
// ASSUMED（未经真机验证）: Hamlib 会在 \set_func ? 中通告 TUNER
// MEASURED 2026-09-01 (docs/hardware-truth-FT710.txt:12): \set_func ? 不含 TUNER
```

**规则：只有 MEASURED 的断言可以阻断（throw / assert failure）。ASSUMED 的只能记 warning。**

历史教训：`test/hamlib-tuner-readback.test.ts` 曾用一条假设出来的"FT-710 契约"写死了"读回不一致就拒绝调谐"，把一个 bug 锁成了"设计"。19 个提交没能修复天调，就是因为后续会话把这个测试当成了事实。

---

## 6. 任务形状

每个任务必须能填进这个模板。**填不满就说明任务还没想清楚，先问，不要开始写代码。**

```
【假设】<一句话，可证伪>
【证据】<docs/hardware-truth-FT710.txt 第 N 行，或具体代码位置>
【改动】<一处>
【真机判据】<在电台或手机上能观察到的现象>
```

- 一个假设、一处改动、一条真机判据
- **验证不了的假设不许写成测试**
- 不要在一条分支上混合不相关的问题

---

## 7. 分支与交付

- 主线是 `main`。功能分支从 `main` 切出，**做完就合回去**。
- **同一时间只允许一条分支上传 IPA。** 否则没人知道手机上装的是哪份代码。
- 每改完一个文件就提交一次，不要攒到最后——卡死时至少保住前面的进度。
- 提交信息说明"为什么"，不只是"改了什么"。

---

## 8. 已知的坑

| 坑 | 说明 |
|---|---|
| `NSAllowsLocalNetworking` | 与 `NSAllowsArbitraryLoads` 互斥。iOS 10+ 只要前者存在，后者被忽略。只保留 `NSAllowsArbitraryLoads`。 |
| `\set_func ?` 不通告 TUNER | Hamlib 的 Yaesu 后端普遍如此。**不通告 ≠ 不支持。** 不要用它来门控天调命令。 |
| FT-710 `AC` 指令 P3 | 三义字段：`0=Tuner OFF/Tuning Stop`、`1=Tuner ON`、`3=Tuning Start`。读回值不保证等于写入值，不要做严格相等校验。 |
| `audioCodecPreference` | iOS 端若写死 `"pcm"`，48 kHz 单声道 = 768 kbit/s。用 `"opus"`（**不要用 `"auto"`**，它会回落到 PCM）。 |
| `scheduleBuffer` 旧回调 | 语义是 `.dataConsumed` 不是播完。必须用 `completionCallbackType: .dataPlayedBack`，否则延迟单调增长。 |
| `waitsForConnectivity` | 会把"连不上"变成"静默等待"。控制类 App 必须快速失败。 |
