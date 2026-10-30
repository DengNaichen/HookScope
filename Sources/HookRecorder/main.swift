import Foundation
import HookCore
import Darwin

let arguments = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of:name), arguments.indices.contains(index+1) else { return nil }
    return arguments[index+1]
}
let paths = AppPaths(root:option("--home").map { URL(fileURLWithPath:$0) },codex:option("--codex-home").map { URL(fileURLWithPath:$0) })
do {
    switch arguments.first {
    case "record":
        guard let command = option("--command"), let hook = option("--hook"), let db = option("--database") else { throw HookScopeError("record requires --command, --hook and --database") }
        exit(Recorder.run(command:command,hook:hook,database:URL(fileURLWithPath:db)))
    case "init":
        try RunStore(url:paths.database).initialize()
        print(paths.database.path)
    case "install":
        let source = URL(fileURLWithPath:CommandLine.arguments[0]).standardizedFileURL
        let installation = try Installer(paths:paths).install(recorder:source)
        print("已配置 \(installation.registrations.count) 个 hook。请在 Codex 中重新确认这些 hook 的信任状态；本工具不会修改信任设置。")
    case "uninstall":
        try Installer(paths:paths).uninstall()
        print("已恢复原始 hook 命令，记录已保留。请在 Codex 中确认恢复后的配置。")
    case "import":
        if let source = option("--from") {
            print("导入 \(try RunStore(url:paths.database).importHistory(from:URL(fileURLWithPath:source))) 条记录")
        } else { print("导入 \(try Installer(paths:paths).importLegacy()) 条记录") }
    case "status":
        let status = Installer(paths:paths).status()
        print("\(status.title) · \(status.registrations.count) hooks")
        if let snapshot = try? RunStore(url:paths.database).snapshot() { print("全部记录：\(snapshot.allTimeTotal)") }
    default:
        print("""
        HookScope · native Swift hook recorder
          init | status | import [--from SQLite-file] | install | uninstall
          record --hook ID --database FILE --command ORIGINAL_COMMAND
        Optional management arguments: --home DATA_DIRECTORY --codex-home CODEX_DIRECTORY
        install changes command hooks in hooks.json and requires renewed trust in Codex.
        """)
    }
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
