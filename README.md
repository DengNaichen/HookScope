# HookScope

原生 macOS Hook 观察工具。SwiftUI 界面、Swift 采集器、系统 SQLite，无 Python/Node 运行时、WebView、HTTP 服务或第三方包依赖。

## 打开项目与构建

要求 macOS 14+、Xcode 16+。当前构建在 Apple Silicon 上验证。

- 用 Xcode 打开 `HookScope.xcodeproj`，选择 **HookScope** scheme，按 ⌘R。采集器自动编译并包含在应用包中。
- 或在项目根目录运行以下命令，生成本地签名的 `build/HookScope.app`：

```sh
swift Tools/Build.swift --open
```

`project.yml` 是 XcodeGen 项目源；项目文件已经生成，正常打开、构建不需要安装 XcodeGen。增加文件或调整 target 后，可运行 `xcodegen generate` 重新生成。也支持 `swift build` / `swift test`。

## 使用

1. 首次启动会查找旧 dashboard 的数据位置，并把已有记录导入独立数据库，不改变旧版采集。
2. 「概览」显示总量、拦截、异常 / 缺失、耗时和趋势。「记录」支持时间、Hook、结果、目录 / 会话 / 原因筛选、分页及详情。
3. 「接入设置」→ **接入 Codex**，将全局 `hooks.json` 中的 command hook 包装为 Swift 采集命令。原命令、matcher、超时、其他配置字段保留，旧配置自动备份。
4. **在 Codex 中重新确认变更后的 hook 信任状态。** Codex 会根据配置内容计算信任标识，因此修改 command 后可能暂停执行，直到确认。HookScope 不修改信任设置，也不绕过确认。
5. 应用可退出。Codex 每次触发 hook 时会按需启动原生采集器；无需常驻应用或服务。若移动应用，已安装的采集器仍位于固定用户数据目录。

已接入后可以用「更新采集组件」替换原生二进制，或用「恢复原始 Hook 命令」停止采集并保留历史。恢复命令后同样应在 Codex 检查信任状态。

**应用自身完全使用 Swift。** 被观察的现有安全检查是用户已有的外部 hook，它们可以用 Python、Shell 或其他语言实现；本项目不会重写安全规则，也不会打包它们的运行时。

## 数据与范围

默认路径：

```text
~/Library/Application Support/HookScope/
  hooks.sqlite3         记录（WAL 模式）
  bin/hook-recorder     固定路径的原生采集器
  installation.json    已接入命令及恢复信息
  backups/              接入前配置与旧采集备份
```

- 支持全局 `$CODEX_HOME/hooks.json`（默认 `~/.codex/hooks.json`）中的 command hook；项目与插件配置不在本版接入范围。
- 仅记录时间、耗时、结果、退出码、事件、会话 / 轮次标识、工具名、工作目录及输入字节数。
- 提示词、完整命令、stdin/stdout/stderr 不写入**记录数据库**。原始配置命令会存在权限为 0600 的安装备份中，用于恢复。
- 只保存源码中列出的固定拦截原因；陌生输出改为通用描述。stdout 解析最多保留 8 KiB，超过上限且退出码为 0 时标记为结果缺失，避免误判结构化拦截。
- 采集器边转发边解析：输入解析缓冲上限约 4 MiB，输出解析缓冲各 8 KiB；实际流转发不截断。
- SQLite 写入等待上限 25 ms；写入失败时仍运行原命令且只运行一次。繁忙或不可写时可能缺少审计记录，不影响原 hook 的决策。
- 开始后超过 15 秒仍无完成记录，会显示「结果缺失」，不推测其是否通过。通用长时间 hook 也会暂时出现此状态，完成后更新。
- 无自动历史清理；历史导入使用 SQLite 在线备份接口，按 run ID 合并，重复导入不会产生重复记录。

退出应用和停止采集是不同操作。删除 `.app` 不会自动清理已配置的 hooks；应先在「接入设置」恢复原始命令。保留数据目录和采集二进制，可让仍持有旧配置的 Codex 进程安全结束。

## 结构

```text
Sources/HookScope/      SwiftUI 界面、后台查询与接入操作
Sources/HookCore/       SQLite、结果识别、流转发、安装和恢复
Sources/HookRecorder/   命令行入口
Sources/CSQLite/        系统 SQLite 的模块声明（无自定义 C 实现）
Tests/HookCoreTests/    流转发、并发、故障、迁移、恢复和信号测试
Tools/Build.swift      构建、生成图标、打包和本地签名
Tools/ValidateCurrentHooks.swift  对已有三个安全检查做隔离对照验证
```

Swift 采集器启动 `/bin/sh -c` 执行原始 hook 命令，继承工作目录、环境和宿主进程组，原样转发三个标准流。SIGTERM / SIGINT / SIGHUP 会转发给子进程；子进程信号退出会反映到采集器。宿主按进程组终止超时时，原命令及其子进程保持在同一组。

## 验证

```sh
swift build
swift test
swift Tools/Build.swift
swift Tools/ValidateCurrentHooks.swift
```

最后一项需要本机已有的三个 personal-security hooks。测试复制脚本和备份到临时目录，通过原来的解释器对照 Swift 包装前后结果；危险命令仅作为检查器的文本输入，不会执行。不会修改生产 hooks 或往生产数据库写入测试记录。

CLI 管理入口位于应用包 `Contents/Helpers/hook-recorder`，支持 `init`、`status`、`import`、`install`、`uninstall`。`--home` 和 `--codex-home` 可用于隔离测试目录。

## 分发

当前是供本机使用的 ad-hoc 签名构建，不含 App Sandbox、不需要管理员权限。向其他机器分发时，应配置自己的 Developer ID 签名并公证；当前产物不是已公证发行版。
