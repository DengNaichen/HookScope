import XCTest
import Foundation
import CSQLite
import Darwin
@testable import HookCore

final class HookCoreTests: XCTestCase {
    var root: URL!
    var database: URL!
    var recorder: URL {
        if let path = ProcessInfo.processInfo.environment["HOOKSCOPE_TEST_RECORDER"] { return URL(fileURLWithPath:path) }
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = [Bundle(for:HookCoreTests.self).bundleURL.deletingLastPathComponent().appendingPathComponent("hook-recorder"),repo.appendingPathComponent(".build/debug/hook-recorder"),repo.appendingPathComponent(".build/out/Products/Debug/hook-recorder")]
        return paths.first { FileManager.default.isExecutableFile(atPath:$0.path) } ?? paths[0]
    }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hookscope-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        database = root.appendingPathComponent("hooks.sqlite3")
        try RunStore(url:database).initialize()
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at:root) }
    struct Result: Equatable { let code: Int32; let output: Data; let error: Data }
    func run(_ command: String,input: Data = Data("{}".utf8),wrapped: Bool = true,db: URL? = nil) throws -> Result {
        let folder = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        let inputURL = folder.appendingPathComponent("stdin"), outputURL = folder.appendingPathComponent("stdout"), errorURL = folder.appendingPathComponent("stderr")
        try input.write(to:inputURL); try Data().write(to:outputURL); try Data().write(to:errorURL)
        let inputFile = try FileHandle(forReadingFrom:inputURL), outputFile = try FileHandle(forWritingTo:outputURL), errorFile = try FileHandle(forWritingTo:errorURL)
        defer { try? inputFile.close(); try? outputFile.close(); try? errorFile.close() }
        let process = Process()
        process.executableURL = wrapped ? recorder : URL(fileURLWithPath:"/bin/sh")
        process.arguments = wrapped ? ["record","--hook","test-hook","--database",(db ?? database).path,"--command",command] : ["-c",command]
        process.standardInput = inputFile; process.standardOutput = outputFile; process.standardError = errorFile
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval:0.005) }
        if process.isRunning { process.terminate(); XCTFail("Recorder did not finish within 8 seconds") }
        process.waitUntilExit()
        return Result(code:process.terminationStatus,output:try Data(contentsOf:outputURL),error:try Data(contentsOf:errorURL))
    }
    func allRows() throws -> [[String:SQLValue]] { try SQLConnection(database).run("SELECT * FROM runs ORDER BY started_ms") }

    func testExactStreamsExitAndPrivateInput() throws {
        let input = Data("{\"session_id\":\"session-123\",\"turn_id\":\"turn-1\",\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"prompt\":\"PRIVATE_MARKER_827\",\"tool_input\":{\"command\":\"DO_NOT_SAVE_COMMAND\"}}".utf8)
        for code in [0,2,7] {
            let command = "cat; printf '\\000\\377binary' >&2; exit \(code)"
            XCTAssertEqual(try run(command,input:input),try run(command,input:input,wrapped:false))
        }
        let rows = try allRows()
        XCTAssertEqual(rows.count,3)
        XCTAssertEqual(Set(rows.map { $0["status"]!.string }),Set(["passed","blocked","error"]))
        XCTAssertTrue(rows.allSatisfy { $0["session_id"]!.string == "session-123" })
        for row in rows {
            XCTAssertFalse(row.values.contains { $0.string.contains("PRIVATE_MARKER") || $0.string.contains("DO_NOT_SAVE_COMMAND") })
        }
    }
    func testLargeBidirectionalStreamsDoNotDeadlockOrTruncate() throws {
        let input = Data(repeating:65,count:5*1024*1024)
        let command = "head -c 200000 /dev/zero >&2; cat; head -c 200000 /dev/zero"
        XCTAssertEqual(try run(command,input:input),try run(command,input:input,wrapped:false))
        XCTAssertEqual(try allRows().first?["input_bytes"]?.int,input.count)
    }
    func testJSONDenialWithZeroExitAndUnknownReasonRedaction() throws {
        let command = "cat >/dev/null; printf '%s' '{\"decision\":\"block\",\"reason\":\"PRIVATE_DENIAL_918\"}'"
        let result = try run(command)
        XCTAssertEqual(result.code,0)
        let row = try XCTUnwrap(allRows().first)
        XCTAssertEqual(row["status"]?.string,"blocked")
        XCTAssertFalse(row["reason"]!.string.contains("PRIVATE_DENIAL"))
        let specific = ResultClassifier.classify(code:0,stdout:Data("{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\"}}".utf8),stderr:Data())
        XCTAssertEqual(specific.0,.blocked)
        XCTAssertEqual(ResultClassifier.classify(code:0,stdout:Data(),stderr:Data(),outputTruncated:true).0,.incomplete)
    }
    func testTerminationPropagatesAndForcedKillKeepsUnknownResult() throws {
        for force in [false,true] {
            let childPID = root.appendingPathComponent("child-\(force).pid")
            let inputURL = root.appendingPathComponent("signal-\(force).input")
            try Data("{\"session_id\":\"signal-session\",\"hook_event_name\":\"PreToolUse\"}".utf8).write(to:inputURL)
            let input = try FileHandle(forReadingFrom:inputURL)
            defer { try? input.close() }
            let process = Process(); process.executableURL = recorder
            process.arguments = ["record","--hook",force ? "forced" : "terminated","--database",database.path,"--command","printf %s $$ > \(shellQuote(childPID.path)); cat >/dev/null; exec /bin/sleep 30"]
            process.standardInput = input; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                if process.isRunning { kill(process.processIdentifier,SIGKILL); process.waitUntilExit() }
                if let text = try? String(contentsOf:childPID,encoding:.utf8),let pid = Int32(text) { kill(pid,SIGKILL) }
            }
            let deadline = Date().addingTimeInterval(3)
            while Date() < deadline {
                if try allRows().contains(where: { $0["hook_id"]?.string == (force ? "forced" : "terminated") && $0["session_id"]?.string == "signal-session" }) { break }
                Thread.sleep(forTimeInterval:0.01)
            }
            kill(process.processIdentifier,force ? SIGKILL : SIGTERM)
            let stopped = Date().addingTimeInterval(3)
            while process.isRunning && Date() < stopped { Thread.sleep(forTimeInterval:0.01) }
            XCTAssertFalse(process.isRunning)
            if process.isRunning { kill(process.processIdentifier,SIGKILL) }
            process.waitUntilExit()
            let row = try XCTUnwrap(allRows().first { $0["hook_id"]?.string == (force ? "forced" : "terminated") })
            XCTAssertEqual(row["session_id"]?.string,"signal-session")
            XCTAssertEqual(row["status"]?.string,force ? "running" : "error")
            XCTAssertEqual(process.terminationReason,.uncaughtSignal)
            XCTAssertEqual(process.terminationStatus,force ? SIGKILL : SIGTERM)
            if force { XCTAssertNil(row["finished_ms"]?.double) }
        }
    }
    func testUnavailableAndLockedDatabasePreserveGuardResultExactlyOnce() throws {
        let marker = root.appendingPathComponent("calls")
        let command = "printf x >> \(shellQuote(marker.path)); printf rejected >&2; exit 2"
        let expected = Result(code:2,output:Data(),error:Data("rejected".utf8))
        XCTAssertEqual(try run(command,db:root.appendingPathComponent("absent/db")),expected)
        let lock = try SQLConnection(database,writable:true)
        try lock.run("BEGIN IMMEDIATE")
        XCTAssertEqual(try run(command),expected)
        try lock.run("ROLLBACK")
        XCTAssertEqual(try Data(contentsOf:marker),Data("xx".utf8))
        XCTAssertEqual(try allRows().count,0)
    }
    func testConcurrentRecordersWithoutApplication() throws {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 6
        let lock = NSLock()
        var failures: [String] = []
        for _ in 0..<18 {
            queue.addOperation {
                do {
                    let result = try self.run("cat >/dev/null; exit 0")
                    if result.code != 0 { lock.lock(); failures.append("exit \(result.code)"); lock.unlock() }
                } catch { lock.lock(); failures.append(error.localizedDescription); lock.unlock() }
            }
        }
        queue.waitUntilAllOperationsAreFinished()
        XCTAssertEqual(failures,[])
        XCTAssertEqual(try allRows().count,18)
        XCTAssertTrue(try allRows().allSatisfy { $0["status"]!.string == "passed" })
    }
    func testMissingCompletionIsNeverPassedAndFiltersEscapeWildcards() throws {
        let store = RunStore(url:database), now = Date()
        XCTAssertTrue(store.begin(id:"missing",hook:"security",at:Int64(now.timeIntervalSince1970*1000)-20_000))
        store.updateInput(id:"missing",metadata:RunMetadata(input:Data("{\"cwd\":\"/local/has_percent%_name\",\"session_id\":\"s1\"}".utf8),totalBytes:10))
        var filter = RunFilter(); filter.outcome = "incomplete"; filter.query = "%_"; filter.page = 999
        let snapshot = try store.snapshot(filter,now:now)
        XCTAssertEqual(snapshot.total,1); XCTAssertEqual(snapshot.page,1)
        XCTAssertEqual(snapshot.records.first?.outcome,.incomplete); XCTAssertNil(snapshot.records.first?.exitCode)
        XCTAssertEqual(snapshot.trend.reduce(0) { $0+$1.count },1)
        filter.query = "' OR 1=1 --"
        XCTAssertEqual(try store.snapshot(filter).total,0)
    }
    func testLiveWALImportIsIdempotentAndRefreshesIncompleteRows() throws {
        let source = root.appendingPathComponent("legacy.sqlite3"), old = RunStore(url:source), store = RunStore(url:database)
        try old.initialize()
        let keepOpen = try SQLConnection(source,writable:true)
        try keepOpen.run("PRAGMA wal_autocheckpoint=0")
        XCTAssertTrue(old.begin(id:"old-run",hook:"security",at:Int64(Date().timeIntervalSince1970*1000)))
        XCTAssertEqual(try store.importHistory(from:source),1)
        old.finish(id:"old-run",at:123,duration:2,outcome:.blocked,code:2,reason:"fixed")
        XCTAssertEqual(try store.importHistory(from:source),0)
        XCTAssertEqual(try store.snapshot().records.first?.outcome,.blocked)
        XCTAssertEqual(try store.importHistory(from:source),0)
        XCTAssertEqual(try allRows().count,1)
    }
    func fixturePaths() throws -> AppPaths {
        let codex = root.appendingPathComponent("codex"), support = root.appendingPathComponent("Application Support/HookScope")
        try FileManager.default.createDirectory(at:codex,withIntermediateDirectories:true)
        let json: [String:Any] = ["unrelated":"keep","hooks":["PreToolUse":[["matcher":"^Bash$","hooks":[["type":"command","command":"printf '%s' \"quoted value\"","timeout":5,"statusMessage":"Fixture","extra":true]]]]]]
        try JSONSerialization.data(withJSONObject:json).write(to:codex.appendingPathComponent("hooks.json"))
        return AppPaths(root:support,codex:codex)
    }
    func testInstallIdempotenceAndUninstallPreserveUnrelatedEdits() throws {
        let paths = try fixturePaths(), installer = Installer(paths:paths)
        let installed = try installer.install(recorder:recorder)
        XCTAssertEqual(installed.registrations.count,1)
        XCTAssertTrue(installer.status().active)
        XCTAssertFalse(installer.status().changed)
        _ = try installer.install(recorder:recorder)
        var json = try JSONSerialization.jsonObject(with:Data(contentsOf:paths.hooks)) as! [String:Any]
        json["later-edit"] = "preserve this"
        try JSONSerialization.data(withJSONObject:json).write(to:paths.hooks)
        try installer.uninstall()
        let restored = try JSONSerialization.jsonObject(with:Data(contentsOf:paths.hooks)) as! [String:Any]
        XCTAssertEqual(restored["later-edit"] as? String,"preserve this")
        XCTAssertEqual(restored["unrelated"] as? String,"keep")
        let groups = (restored["hooks"] as! [String:Any])["PreToolUse"] as! [[String:Any]]
        let hook = (groups[0]["hooks"] as! [[String:Any]])[0]
        XCTAssertEqual(hook["command"] as? String,installed.registrations[0].original)
        XCTAssertEqual(hook["timeout"] as? Int,5)
        XCTAssertEqual(hook["extra"] as? Bool,true)
        XCTAssertFalse(installer.status().active)
        XCTAssertFalse(FileManager.default.fileExists(atPath:paths.codex.appendingPathComponent("config.toml").path))
    }
    func testChangedHookIsNotOverwrittenOnDisconnect() throws {
        let paths = try fixturePaths(), installer = Installer(paths:paths)
        _ = try installer.install(recorder:recorder)
        let original = try String(contentsOf:paths.hooks,encoding:.utf8)
        let altered = original.replacingOccurrences(of:"hook-recorder",with:"my-custom-recorder")
        try altered.write(to:paths.hooks,atomically:true,encoding:.utf8)
        XCTAssertThrowsError(try installer.uninstall())
        XCTAssertEqual(try String(contentsOf:paths.hooks,encoding:.utf8),altered)
    }
    func testLegacyMigrationVerifiesBackupsAndPreservesHistory() throws {
        let paths = try fixturePaths(), installer = Installer(paths:paths)
        let oldRoot = root.appendingPathComponent("old/data"), guards = paths.legacyConfig.deletingLastPathComponent()
        try FileManager.default.createDirectory(at:oldRoot,withIntermediateDirectories:true)
        try FileManager.default.createDirectory(at:guards,withIntermediateDirectories:true)
        let oldDB = oldRoot.appendingPathComponent("hooks.sqlite3"), oldStore = RunStore(url:oldDB)
        try oldStore.initialize()
        XCTAssertTrue(oldStore.begin(id:"old-preserved",hook:"security",at:Int64(Date().timeIntervalSince1970*1000)))
        let original = Data("original guard bytes".utf8), patched = Data("instrumented guard bytes".utf8)
        let file = guards.appendingPathComponent("security.py"), backup = root.appendingPathComponent("original.py")
        try patched.write(to:file)
        try Data("corrupted backup".utf8).write(to:backup)
        let manifest: [String:Any] = ["active":true,"hooks_dir":guards.path,"files":["security.py":["backup":backup.path,"original_sha256":HookCore.hash(original),"installed_sha256":HookCore.hash(patched)]]]
        try JSONSerialization.data(withJSONObject:manifest).write(to:oldRoot.appendingPathComponent("installation.json"))
        try JSONSerialization.data(withJSONObject:["database":oldDB.path]).write(to:paths.legacyConfig)
        let initialConfig = try Data(contentsOf:paths.hooks)
        XCTAssertThrowsError(try installer.install(recorder:recorder))
        XCTAssertEqual(try Data(contentsOf:paths.hooks),initialConfig)
        XCTAssertEqual(try Data(contentsOf:file),patched)
        try original.write(to:backup)
        _ = try installer.install(recorder:recorder)
        XCTAssertEqual(try Data(contentsOf:file),original)
        let migrated = try JSONSerialization.jsonObject(with:Data(contentsOf:oldRoot.appendingPathComponent("installation.json"))) as! [String:Any]
        XCTAssertEqual(migrated["active"] as? Bool,false)
        XCTAssertEqual(try RunStore(url:paths.database).snapshot().allTimeTotal,1)
        try installer.uninstall()
        XCTAssertEqual(try Data(contentsOf:file),original)
    }
    func testShellQuoteRoundTripsAllMetacharacters() throws {
        let value = "a ' quote \" space; $HOME $(nothing) `nothing` \n utf8-中文"
        let result = try run("printf %s " + shellQuote(value),wrapped:false)
        XCTAssertEqual(result.output,Data(value.utf8)); XCTAssertEqual(result.code,0)
    }
}
