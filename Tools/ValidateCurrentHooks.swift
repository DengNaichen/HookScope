#!/usr/bin/env swift
// Read-only integration check of existing personal guards in a temporary copy.
// No production hook is executed directly and no production database is written.
import Foundation

let fm = FileManager.default
let project = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
let helper = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath:$0) } ?? project.appendingPathComponent("build/HookScope.app/Contents/Helpers/hook-recorder")
let guards = fm.homeDirectoryForCurrentUser.appendingPathComponent(".codex/hooks/personal-security")
let temp = fm.temporaryDirectory.appendingPathComponent("hookscope-real-guards-\(UUID().uuidString)")
try fm.createDirectory(at:temp,withIntermediateDirectories:true)
defer { try? fm.removeItem(at:temp) }
func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of:"'",with:"'\\''") + "'" }
struct Result: Equatable { let code: Int32; let stdout: Data; let stderr: Data }
func run(_ executable: URL,_ args: [String],input: Data = Data()) throws -> Result {
    let prefix = UUID().uuidString
    let stdinURL = temp.appendingPathComponent(prefix+".in"), stdoutURL = temp.appendingPathComponent(prefix+".out"), stderrURL = temp.appendingPathComponent(prefix+".err")
    try input.write(to:stdinURL); try Data().write(to:stdoutURL); try Data().write(to:stderrURL)
    let stdin = try FileHandle(forReadingFrom:stdinURL), stdout = try FileHandle(forWritingTo:stdoutURL), stderr = try FileHandle(forWritingTo:stderrURL)
    defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
    let process = Process(); process.executableURL = executable; process.arguments = args
    process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
    try process.run(); process.waitUntilExit()
    return Result(code:process.terminationStatus,stdout:try Data(contentsOf:stdoutURL),stderr:try Data(contentsOf:stderrURL))
}
do {
    var backups: [String:URL] = [:]
    if let configData = try? Data(contentsOf:guards.appendingPathComponent("observer-config.json")),
       let config = try JSONSerialization.jsonObject(with:configData) as? [String:Any], let path = config["database"] as? String,
       let manifestData = try? Data(contentsOf:URL(fileURLWithPath:path).deletingLastPathComponent().appendingPathComponent("installation.json")),
       let manifest = try JSONSerialization.jsonObject(with:manifestData) as? [String:Any],
       let files = manifest["files"] as? [String:[String:Any]] {
        for (name,item) in files { if let backup = item["backup"] as? String { backups[name] = URL(fileURLWithPath:backup) } }
    }
    for name in ["guard.py","secret_rules.py","secret-guard.toml","git-security.py","security.py","secret-guard.py"] {
        try fm.copyItem(at:backups[name] ?? guards.appendingPathComponent(name),to:temp.appendingPathComponent(name))
    }
    let dataRoot = temp.appendingPathComponent("records")
    guard try run(helper,["init","--home",dataRoot.path]).code == 0 else { throw NSError(domain:"Initialize",code:1) }
    let db = dataRoot.appendingPathComponent("hooks.sqlite3")
    let base: [String:Any] = ["hook_event_name":"PreToolUse","session_id":"integration-fixture","tool_name":"Bash","cwd":"/local/fixture"]
    var cases: [(String,[String:Any])] = []
    for (name,command) in [("git-security","git status"),("git-security","git reset --hard"),("security","echo hello"),("security","rm -rf /NEVER_EXECUTED_FIXTURE")] {
        var payload = base; payload["tool_input"] = ["command":command]; cases.append((name,payload))
    }
    cases += [
        ("secret-guard",["hook_event_name":"UserPromptSubmit","prompt":"请总结这个项目。"]),
        ("secret-guard",["hook_event_name":"UserPromptSubmit","prompt":"密码是 FakeSecretForUnitTest_9182"]),
        ("git-security",["invalid":"PRIVATE_FIXTURE"])
    ]
    for (index,item) in cases.enumerated() {
        let (name,payload) = item, file = temp.appendingPathComponent(name+".py")
        let input = try JSONSerialization.data(withJSONObject:payload)
        let original = try run(URL(fileURLWithPath:"/usr/bin/python3"),[file.path],input:input)
        let wrapped = try run(helper,["record","--database",db.path,"--hook",name,"--command","/usr/bin/python3 " + quote(file.path)],input:input)
        guard original == wrapped else { throw NSError(domain:"GuardParity",code:index,userInfo:[NSLocalizedDescriptionKey:"Original/wrapped result mismatch for \(name)"]) }
    }
    let sql = try run(URL(fileURLWithPath:"/usr/bin/sqlite3"),[db.path,"SELECT COUNT(*),SUM(status='blocked'),SUM(status='passed') FROM runs;"])
    guard String(decoding:sql.stdout,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines) == "7|4|3" else { throw NSError(domain:"Classification",code:1) }
    print("PASS: 7 real-guard cases; stdin/stdout/stderr/exit parity; 4 blocked and 3 passed. Production hooks and records untouched.")
} catch { fputs(error.localizedDescription+"\n",stderr); exit(1) }
