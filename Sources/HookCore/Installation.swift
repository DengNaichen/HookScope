import Foundation
import CryptoKit
import Darwin

public struct HookRegistration: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let event: String
    public let matcher: String
    public let original: String
    public let wrapped: String
}

public struct Installation: Codable, Sendable {
    public var active: Bool
    public let installedAt: Date
    public let hooksFile: String
    public let registrations: [HookRegistration]
    public let backupDirectory: String
}

public struct IntegrationStatus: Sendable {
    public let active: Bool
    public let registrations: [HookRegistration]
    public let changed: Bool
    public let legacyDatabase: URL?
    public var title: String { changed ? "配置已变化" : active ? "已配置采集" : "尚未接入" }
}

public struct Installer: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths = AppPaths()) { self.paths = paths }
    public func legacyDatabase() -> URL? {
        guard let data = try? Data(contentsOf:paths.legacyConfig),
              let json = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              let path = json["database"] as? String,
              FileManager.default.fileExists(atPath:path) else { return nil }
        return URL(fileURLWithPath:path)
    }
    public func status() -> IntegrationStatus {
        let installation = try? JSONDecoder().decode(Installation.self, from:Data(contentsOf:paths.manifest))
        let document = try? loadHooks()
        let commands = document.map { entries($0).map { $0.command } } ?? []
        let active = installation?.active == true
        let changed = active && !(installation?.registrations.allSatisfy { commands.contains($0.wrapped) } ?? false)
        return IntegrationStatus(active:active,registrations:installation?.registrations ?? [],changed:changed,legacyDatabase:legacyDatabase())
    }
    public func importLegacy() throws -> Int {
        guard let source = legacyDatabase() else { throw HookScopeError("没有找到旧版 dashboard 的记录。可以在应用中选择 SQLite 文件导入。") }
        return try RunStore(url:paths.database).importHistory(from:source)
    }
    /// Called only from the explicit Connect action. Never modifies Codex's trust state.
    public func install(recorder: URL) throws -> Installation {
        try paths.prepare()
        let lock = try installationLock()
        defer { flock(lock,LOCK_UN); close(lock) }
        if let prior = try? JSONDecoder().decode(Installation.self,from:Data(contentsOf:paths.manifest)), prior.active {
            guard !status().changed else { throw HookScopeError("Hook 配置已被修改，未覆盖你的更改。请先检查 hooks.json。") }
            try copyRecorder(recorder)
            return prior
        }
        let originalData = try Data(contentsOf:paths.hooks)
        var document = try loadHooks()
        let found = entries(document)
        guard !found.isEmpty else { throw HookScopeError("没有在 Codex 全局 hooks.json 中找到 command 类型的 hook。") }
        guard !found.contains(where: { $0.command.contains("hook-recorder") }) else { throw HookScopeError("检测到已有采集包装命令，但缺少对应安装清单。请先检查配置。") }
        let backup = paths.root.appendingPathComponent("backups/\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:backup,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try atomic(originalData,to:backup.appendingPathComponent("hooks.json"))
        try copyRecorder(recorder)
        try RunStore(url:paths.database).initialize()
        if let old = legacyDatabase() { _ = try RunStore(url:paths.database).importHistory(from:old) }
        let legacy = try legacyRestoration()
        for (index,item) in legacy.enumerated() {
            try atomic(item.current,to:backup.appendingPathComponent("legacy-\(index)"))
        }
        var registrations: [HookRegistration] = []
        for entry in found {
            let command = [shellQuote(paths.recorder.path),"record","--database",shellQuote(paths.database.path),"--hook",shellQuote(entry.id),"--command",shellQuote(entry.command)].joined(separator:" ")
            replace(&document,event:entry.event,group:entry.group,handler:entry.handler,command:command)
            registrations.append(HookRegistration(id:entry.id,name:entry.name,event:entry.event,matcher:entry.matcher,original:entry.command,wrapped:command))
        }
        let installation = Installation(active:true,installedAt:.now,hooksFile:paths.hooks.path,registrations:registrations,backupDirectory:backup.path)
        let newData = try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        let manifestData = try JSONEncoder().encode(installation)
        // Preflight all changes before writing. Existing user edits are never silently overwritten.
        guard try Data(contentsOf:paths.hooks) == originalData else { throw HookScopeError("Hook 配置在接入期间发生变化，请重试。") }
        for item in legacy where try Data(contentsOf:item.url) != item.current { throw HookScopeError("旧采集脚本在接入期间发生变化，已停止接入。") }
        var written: [LegacyFile] = []
        var configWritten = false
        do {
            for item in legacy { try atomic(item.restored,to:item.url,mode:item.mode); written.append(item) }
            try atomic(newData,to:paths.hooks,mode:fileMode(paths.hooks)); configWritten = true
            try atomic(manifestData,to:paths.manifest)
        } catch {
            // Roll back only bytes still owned by this operation.
            if configWritten, (try? Data(contentsOf:paths.hooks)) == newData { try? atomic(originalData,to:paths.hooks) }
            for item in written where (try? Data(contentsOf:item.url)) == item.restored { try? atomic(item.current,to:item.url,mode:item.mode) }
            throw error
        }
        return installation
    }
    public func uninstall() throws {
        try paths.prepare()
        let lock = try installationLock(); defer { flock(lock,LOCK_UN); close(lock) }
        var installation = try JSONDecoder().decode(Installation.self,from:Data(contentsOf:paths.manifest))
        guard installation.active else { return }
        let original = try Data(contentsOf:paths.hooks)
        var document = try loadHooks()
        let all = entries(document)
        for registered in installation.registrations {
            let matches = all.filter { $0.command == registered.wrapped }
            guard matches.count == 1, let entry = matches.first else { throw HookScopeError("Hook 命令已有其他修改，未覆盖。请检查 hooks.json 后再恢复。") }
            replace(&document,event:entry.event,group:entry.group,handler:entry.handler,command:registered.original)
        }
        let restored = try JSONSerialization.data(withJSONObject:document,options:[.prettyPrinted,.sortedKeys,.withoutEscapingSlashes])
        guard try Data(contentsOf:paths.hooks) == original else { throw HookScopeError("Hook 配置发生变化，请重试。") }
        installation.active = false
        try atomic(restored,to:paths.hooks,mode:fileMode(paths.hooks))
        do { try atomic(JSONEncoder().encode(installation),to:paths.manifest) }
        catch {
            if (try? Data(contentsOf:paths.hooks)) == restored { try? atomic(original,to:paths.hooks) }
            throw error
        }
        // Keep the binary and history so an in-flight hook or stale host config can still finish safely.
    }
    private func copyRecorder(_ source: URL) throws {
        guard FileManager.default.isExecutableFile(atPath:source.path) else { throw HookScopeError("应用包中缺少可执行的 Swift 采集组件。请重新构建应用。") }
        try FileManager.default.createDirectory(at:paths.recorder.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try atomic(Data(contentsOf:source),to:paths.recorder,mode:0o755)
    }
    private func installationLock() throws -> Int32 {
        let fd = open(paths.root.appendingPathComponent("installation.lock").path,O_CREAT|O_RDWR,0o600)
        guard fd >= 0 else { throw HookScopeError("无法创建接入锁。") }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { close(fd); throw HookScopeError("另一个接入操作正在进行，请稍后重试。") }
        return fd
    }
    private func loadHooks() throws -> [String:Any] {
        guard let doc = try JSONSerialization.jsonObject(with:Data(contentsOf:paths.hooks)) as? [String:Any], doc["hooks"] is [String:Any] else { throw HookScopeError("hooks.json 格式不受支持。") }
        return doc
    }
    private struct Entry {
        let event: String, group: Int, handler: Int, command: String, matcher: String, id: String, name: String
    }
    private func entries(_ doc: [String:Any]) -> [Entry] {
        guard let hooks = doc["hooks"] as? [String:Any] else { return [] }
        var result: [Entry] = []
        var usedIDs: Set<String> = []
        for event in hooks.keys.sorted() {
            for (groupIndex,group) in (hooks[event] as? [[String:Any]] ?? []).enumerated() {
                for (handlerIndex,handler) in (group["hooks"] as? [[String:Any]] ?? []).enumerated() {
                    guard handler["type"] as? String == "command", let command = handler["command"] as? String, !command.isEmpty else { continue }
                    let known = ["git-security","secret-guard","security"].first { command.contains("/" + $0 + ".py") }
                    let matcher = group["matcher"] as? String ?? "全部"
                    var id = known ?? "hook-" + String(hash(Data("\(event):\(matcher):\(command)".utf8)).prefix(10))
                    if usedIDs.contains(id) { id += "-" + String(hash(Data("\(event):\(groupIndex):\(handlerIndex)".utf8)).prefix(8)) }
                    usedIDs.insert(id)
                    result.append(Entry(event:event,group:groupIndex,handler:handlerIndex,command:command,matcher:matcher,id:id,name:handler["statusMessage"] as? String ?? HookNames.name(id)))
                }
            }
        }
        return result
    }
    private func replace(_ document: inout [String:Any],event: String,group: Int,handler: Int,command: String) {
        var hooks = document["hooks"] as! [String:Any]
        var groups = hooks[event] as! [[String:Any]]
        var handlers = groups[group]["hooks"] as! [[String:Any]]
        handlers[handler]["command"] = command
        groups[group]["hooks"] = handlers; hooks[event] = groups; document["hooks"] = hooks
    }
    private struct LegacyFile { let url: URL, current: Data, restored: Data, mode: Int }
    private func legacyRestoration() throws -> [LegacyFile] {
        guard let db = legacyDatabase() else { return [] }
        let manifest = db.deletingLastPathComponent().appendingPathComponent("installation.json")
        guard let data = try? Data(contentsOf:manifest),
              var json = try JSONSerialization.jsonObject(with:data) as? [String:Any],
              json["active"] as? Bool == true else { return [] }
        guard let directory = json["hooks_dir"] as? String, let files = json["files"] as? [String:[String:Any]] else { throw HookScopeError("旧版采集安装清单不完整。") }
        var result: [LegacyFile] = []
        for name in files.keys.sorted() {
            guard !name.contains("/"), let info = files[name], let backup = info["backup"] as? String else { throw HookScopeError("旧版备份路径无效。") }
            let url = URL(fileURLWithPath:directory).appendingPathComponent(name)
            let current = try Data(contentsOf:url), original = try Data(contentsOf:URL(fileURLWithPath:backup))
            guard hash(current) == info["installed_sha256"] as? String, hash(original) == info["original_sha256"] as? String else { throw HookScopeError("\(name) 或其备份已有更改，未覆盖。请先检查旧版采集脚本。") }
            result.append(LegacyFile(url:url,current:current,restored:original,mode:fileMode(url)))
        }
        json["active"] = false
        result.append(LegacyFile(url:manifest,current:data,restored:try JSONSerialization.data(withJSONObject:json,options:[.prettyPrinted,.sortedKeys]),mode:0o600))
        return result
    }
}

public func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
func hash(_ data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
func fileMode(_ url: URL) -> Int { (try? FileManager.default.attributesOfItem(atPath:url.path)[.posixPermissions] as? Int) ?? 0o600 }
func atomic(_ data: Data,to url: URL,mode: Int = 0o600) throws {
    let temp = url.deletingLastPathComponent().appendingPathComponent(".hookscope-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at:temp) }
    try data.write(to:temp,options:.withoutOverwriting)
    try FileManager.default.setAttributes([.posixPermissions:mode],ofItemAtPath:temp.path)
    let fd = open(temp.path,O_RDONLY)
    if fd >= 0 { fsync(fd); close(fd) }
    guard rename(temp.path,url.path) == 0 else { throw HookScopeError("无法原子更新 \(url.lastPathComponent)：\(String(cString:strerror(errno)))") }
}
