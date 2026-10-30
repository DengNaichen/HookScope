import SwiftUI
import HookCore
import UniformTypeIdentifiers

struct ConnectionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section {
                HStack(spacing:14) {
                    Image(systemName:"link.circle.fill").font(.system(size:40)).foregroundStyle(.blue)
                    VStack(alignment:.leading,spacing:5) {
                        Text("Codex Hooks").font(.title3.weight(.semibold))
                        Text(model.integration?.title ?? "正在检查…").foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.working { ProgressView().controlSize(.small) }
                }.padding(.vertical,6)
                if model.integration?.active == true {
                    ForEach(model.integration?.registrations ?? []) { hook in
                        LabeledContent(hook.name,value:hook.event)
                    }
                    Text("采集命令已写入配置；是否启用由 Codex 的信任设置决定。修改接入后，请在 Codex 中确认相应 hook。")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button("更新采集组件") { Task { await model.connect() } }
                        Spacer()
                        Button("恢复原始 Hook 命令",role:.destructive) { Task { await model.disconnect() } }
                    }
                } else {
                    Text("接入后，Swift 采集组件会随每次 hook 触发运行。退出此应用后，仍可继续记录。")
                    Text("接入会更新全局 hooks.json 中的 command hook，并备份原配置。Codex 会将变更后的命令视为待确认；重新确认信任前，这些 hook 可能暂停执行。")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("接入 Codex") { Task { await model.connect() } }.buttonStyle(.borderedProminent)
                }
            } header: { Text("采集") }
            Section {
                LabeledContent("保存的记录",value:model.snapshot.allTimeTotal.formatted())
                HStack {
                    Text("存储位置")
                    Spacer()
                    Button("在 Finder 中显示") { NSWorkspace.shared.open(model.paths.root) }
                }
                HStack {
                    if model.integration?.legacyDatabase != nil {
                        Button("导入旧版记录") { Task { await model.importHistory() } }
                    }
                    Button("从数据库导入…") { chooseDatabase() }
                }
                Text("导入会合并相同 ID 的记录。数据保存在应用包之外，更新应用不会移除历史。")
                    .font(.callout).foregroundStyle(.secondary)
            } header: { Text("数据") }
            Section {
                LabeledContent("界面与采集器",value:"SwiftUI · Swift")
                LabeledContent("数据库",value:"本机 SQLite")
                Text("应用没有网页服务器，也没有常驻采集服务。原有 hook 可以使用任意语言；HookScope 只负责观察它们的执行结果。")
                    .foregroundStyle(.secondary)
                Text("记录包含时间、耗时、退出码、会话标识和固定的拦截原因，不保存提示词、完整命令或原始输出。当前接入范围为 Codex 全局 hooks.json；项目及插件配置不在此范围内。")
                    .foregroundStyle(.secondary)
            } header: { Text("关于 HookScope") }
        }
        .formStyle(.grouped)
        .disabled(model.working)
    }
    private func chooseDatabase() {
        let panel = NSOpenPanel()
        panel.title = "选择 HookScope 或旧版 dashboard 的 SQLite 数据库"
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { result in
            if result == .OK, let url = panel.url { Task { await model.importHistory(from:url) } }
        }
    }
}
