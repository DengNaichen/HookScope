import Foundation
import CSQLite

enum SQLValue {
    case text(String), integer(Int64), real(Double), null
    var string: String { if case .text(let s) = self { return s }; return "" }
    var int: Int { if case .integer(let n) = self { return Int(n) }; return 0 }
    var double: Double? {
        switch self { case .real(let n): return n; case .integer(let n): return Double(n); default: return nil }
    }
}

/// Each operation owns its connection; connections never cross threads.
final class SQLConnection {
    var handle: OpaquePointer?
    init(_ path: URL, writable: Bool = false, timeout: Int32 = 250, create: Bool = true) throws {
        let fm = FileManager.default
        var directory: ObjCBool = false
        let exists = fm.fileExists(atPath:path.path,isDirectory:&directory)
        guard !directory.boolValue,
              exists ? (fm.isReadableFile(atPath:path.path) && (!writable || fm.isWritableFile(atPath:path.path)))
                     : (writable && create && fm.isWritableFile(atPath:path.deletingLastPathComponent().path)) else {
            // Apple SQLite can emit open errors to stderr under Xcode's logging environment.
            // Reject inaccessible paths before entering SQLite, keeping hook streams untouched.
            throw HookScopeError("记录数据库不存在或不可访问。")
        }
        let flags = writable ? SQLITE_OPEN_READWRITE | (create ? SQLITE_OPEN_CREATE : 0) : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(path.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let detail = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle); handle = nil
            throw HookScopeError("无法打开记录数据库：\(detail)")
        }
        sqlite3_busy_timeout(handle, timeout)
    }
    deinit { sqlite3_close(handle) }
    @discardableResult func run(_ sql: String, _ args: [SQLValue] = []) throws -> [[String: SQLValue]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in args.enumerated() {
            let pos = Int32(index + 1)
            switch value {
            case .text(let s): sqlite3_bind_text(stmt, pos, s, -1, transient)
            case .integer(let n): sqlite3_bind_int64(stmt, pos, n)
            case .real(let n): sqlite3_bind_double(stmt, pos, n)
            case .null: sqlite3_bind_null(stmt, pos)
            }
        }
        var rows: [[String: SQLValue]] = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw failure() }
            var row: [String: SQLValue] = [:]
            for column in 0..<sqlite3_column_count(stmt) {
                let key = String(cString: sqlite3_column_name(stmt, column))
                switch sqlite3_column_type(stmt, column) {
                case SQLITE_INTEGER: row[key] = .integer(sqlite3_column_int64(stmt, column))
                case SQLITE_FLOAT: row[key] = .real(sqlite3_column_double(stmt, column))
                case SQLITE_TEXT: row[key] = .text(String(cString: sqlite3_column_text(stmt, column)))
                default: row[key] = .null
                }
            }
            rows.append(row)
        }
    }
    func failure() -> HookScopeError { HookScopeError("数据库操作失败：\(String(cString: sqlite3_errmsg(handle)))") }
}

public struct RunStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func initialize() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
        let db = try SQLConnection(url, writable: true)
        try db.run("PRAGMA journal_mode=WAL")
        try db.run("""
        CREATE TABLE IF NOT EXISTS runs (
        id TEXT PRIMARY KEY, hook_id TEXT NOT NULL, started_ms INTEGER NOT NULL,
        finished_ms INTEGER, duration_ms REAL, status TEXT NOT NULL,
        exit_code INTEGER, reason TEXT NOT NULL DEFAULT '', event_name TEXT NOT NULL DEFAULT '',
        session_id TEXT NOT NULL DEFAULT '', turn_id TEXT NOT NULL DEFAULT '', tool_name TEXT NOT NULL DEFAULT '',
        cwd TEXT NOT NULL DEFAULT '', input_bytes INTEGER NOT NULL DEFAULT 0)
        """)
        try db.run("CREATE INDEX IF NOT EXISTS runs_time ON runs(started_ms DESC)")
        try db.run("CREATE INDEX IF NOT EXISTS runs_hook_time ON runs(hook_id,started_ms DESC)")
        try FileManager.default.setAttributes([.posixPermissions:0o600], ofItemAtPath: url.path)
    }
    public func begin(id: String, hook: String, at: Int64) -> Bool {
        do {
            let db = try SQLConnection(url, writable: true, timeout: 25, create: false)
            try db.run("INSERT INTO runs(id,hook_id,started_ms,status) VALUES(?,?,?,'running')", [.text(id),.text(hook),.integer(at)])
            return true
        } catch { return false }
    }
    public func updateInput(id: String, metadata: RunMetadata) {
        guard let db = try? SQLConnection(url, writable: true, timeout: 25, create: false) else { return }
        _ = try? db.run("UPDATE runs SET event_name=?,session_id=?,turn_id=?,tool_name=?,cwd=?,input_bytes=? WHERE id=?", metadata.values + [.text(id)])
    }
    public func finish(id: String, at: Int64, duration: Double, outcome: Outcome, code: Int32?, reason: String) {
        guard let db = try? SQLConnection(url, writable: true, timeout: 25, create: false) else { return }
        _ = try? db.run("UPDATE runs SET finished_ms=?,duration_ms=?,status=?,exit_code=?,reason=? WHERE id=?", [
            .integer(at),.real(duration),.text(outcome.rawValue),code.map { .integer(Int64($0)) } ?? .null,.text(reason),.text(id)
        ])
    }
    public func snapshot(_ filter: RunFilter = RunFilter(), now: Date = .now) throws -> Snapshot {
        let db = try SQLConnection(url)
        try db.run("BEGIN")
        defer { _ = try? db.run("ROLLBACK") }
        let nowMS = Int64(now.timeIntervalSince1970 * 1000)
        let effective = "CASE WHEN status='running' AND started_ms < \(nowMS - 15_000) THEN 'incomplete' ELSE status END"
        var predicates: [String] = [], args: [SQLValue] = []
        if let duration = filter.range.seconds { predicates.append("started_ms>=?"); args.append(.integer(nowMS - Int64(duration * 1000))) }
        if !filter.hookID.isEmpty { predicates.append("hook_id=?"); args.append(.text(filter.hookID)) }
        if Outcome(rawValue: filter.outcome) != nil { predicates.append("\(effective)=?"); args.append(.text(filter.outcome)) }
        let query = String(filter.query.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        if !query.isEmpty {
            let escaped = "%" + query.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            predicates.append("(session_id LIKE ? ESCAPE '\\' OR turn_id LIKE ? ESCAPE '\\' OR cwd LIKE ? ESCAPE '\\' OR reason LIKE ? ESCAPE '\\')")
            args += Array(repeating: .text(escaped), count: 4)
        }
        let clause = predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")
        var result = Snapshot(); result.refreshed = now
        result.total = try db.run("SELECT COUNT(*) AS n FROM runs" + clause, args).first?["n"]?.int ?? 0
        result.pages = max(1, (result.total + 49) / 50)
        result.page = min(max(1, filter.page), result.pages)
        let all = try db.run("SELECT COUNT(*) AS n,MIN(started_ms) AS first FROM runs").first ?? [:]
        result.allTimeTotal = all["n"]?.int ?? 0
        result.hookIDs = try db.run("SELECT DISTINCT hook_id FROM runs ORDER BY hook_id").map { $0["hook_id"]?.string ?? "" }
        for row in try db.run("SELECT \(effective) AS outcome,COUNT(*) AS n FROM runs" + clause + " GROUP BY outcome", args) {
            if let outcome = Outcome(rawValue: row["outcome"]?.string ?? "") { result.counts[outcome] = row["n"]?.int ?? 0 }
        }
        result.averageMS = try db.run("SELECT AVG(duration_ms) AS avg FROM runs" + clause, args).first?["avg"]?.double
        result.records = try db.run("SELECT *,\(effective) AS outcome FROM runs" + clause + " ORDER BY started_ms DESC,id LIMIT 50 OFFSET ?", args + [.integer(Int64((result.page - 1) * 50))]).map { row in
            HookRun(id: row["id"]!.string, hookID: row["hook_id"]!.string,
                started: Date(timeIntervalSince1970: Double(row["started_ms"]!.int) / 1000), duration: row["duration_ms"]?.double,
                outcome: Outcome(rawValue: row["outcome"]!.string) ?? .incomplete,
                exitCode: row["exit_code"]?.double.map { Int($0) }, reason: row["reason"]?.string ?? "",
                event: row["event_name"]?.string ?? "", session: row["session_id"]?.string ?? "", turn: row["turn_id"]?.string ?? "",
                tool: row["tool_name"]?.string ?? "", directory: row["cwd"]?.string ?? "", inputBytes: row["input_bytes"]?.int ?? 0)
        }
        let start = min(nowMS - 3_600_000, filter.range.seconds.map { nowMS - Int64($0 * 1000) } ?? Int64(all["first"]?.int ?? Int(nowMS)))
        let width = max(1, (nowMS - start) / 24)
        let buckets = try db.run("SELECT MIN(23,MAX(0,CAST((started_ms-?)/? AS INTEGER))) AS bucket,\(effective) AS outcome,COUNT(*) AS n FROM runs" + clause + " GROUP BY bucket,outcome", [.integer(start),.integer(width)] + args)
        for index in 0..<24 {
            for outcome in Outcome.allCases {
                let count = buckets.first { $0["bucket"]?.int == index && $0["outcome"]?.string == outcome.rawValue }?["n"]?.int ?? 0
                result.trend.append(TrendPoint(date: Date(timeIntervalSince1970: Double(start + Int64(index) * width) / 1000), outcome: outcome, count: count))
            }
        }
        return result
    }

    /// Snapshot a live WAL database with SQLite's backup API, then merge by stable run ID.
    /// Re-importing updates formerly unfinished rows, but never overwrites newer local completions.
    public func importHistory(from source: URL) throws -> Int {
        guard source.standardizedFileURL != url.standardizedFileURL else { return 0 }
        try initialize()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hookscope-\(UUID().uuidString).sqlite3")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let input = try SQLConnection(source)
            let output = try SQLConnection(temp, writable: true)
            guard let backup = sqlite3_backup_init(output.handle, "main", input.handle, "main") else { throw output.failure() }
            let deadline = Date().addingTimeInterval(3)
            var code: Int32
            repeat {
                code = sqlite3_backup_step(backup, 128)
                if code == SQLITE_BUSY || code == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.025) }
            } while (code == SQLITE_OK || code == SQLITE_BUSY || code == SQLITE_LOCKED) && Date() < deadline
            let finished = sqlite3_backup_finish(backup)
            guard code == SQLITE_DONE && finished == SQLITE_OK else { throw HookScopeError("历史数据库暂时繁忙，请稍后再导入。") }
        }
        let db = try SQLConnection(url, writable: true)
        try db.run("ATTACH DATABASE ? AS legacy", [.text(temp.path)])
        defer { _ = try? db.run("DETACH DATABASE legacy") }
        try db.run("BEGIN IMMEDIATE")
        do {
            let before = try db.run("SELECT COUNT(*) AS n FROM runs").first!["n"]!.int
            try db.run("""
            INSERT INTO runs SELECT * FROM legacy.runs WHERE true
            ON CONFLICT(id) DO UPDATE SET
                finished_ms=excluded.finished_ms,duration_ms=excluded.duration_ms,status=excluded.status,
                exit_code=excluded.exit_code,reason=excluded.reason,event_name=excluded.event_name,
                session_id=excluded.session_id,turn_id=excluded.turn_id,tool_name=excluded.tool_name,cwd=excluded.cwd,input_bytes=excluded.input_bytes
            WHERE runs.finished_ms IS NULL AND excluded.finished_ms IS NOT NULL
            """)
            let after = try db.run("SELECT COUNT(*) AS n FROM runs").first!["n"]!.int
            try db.run("COMMIT")
            return after - before
        } catch { _ = try? db.run("ROLLBACK"); throw error }
    }
}
