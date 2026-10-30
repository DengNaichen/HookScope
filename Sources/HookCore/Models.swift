import Foundation

public enum Outcome: String, CaseIterable, Codable, Sendable, Identifiable {
    case passed, blocked, error, running, incomplete
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .passed: "通过"
        case .blocked: "已拦截"
        case .error: "异常"
        case .running: "运行中"
        case .incomplete: "结果缺失"
        }
    }
    public var symbol: String {
        switch self {
        case .passed: "checkmark.circle.fill"
        case .blocked: "hand.raised.fill"
        case .error: "exclamationmark.triangle.fill"
        case .running: "clock"
        case .incomplete: "questionmark.circle"
        }
    }
}

public struct HookRun: Identifiable, Sendable {
    public let id: String
    public let hookID: String
    public let started: Date
    public let duration: Double?
    public let outcome: Outcome
    public let exitCode: Int?
    public let reason: String
    public let event: String
    public let session: String
    public let turn: String
    public let tool: String
    public let directory: String
    public let inputBytes: Int
    public var name: String { HookNames.name(hookID) }
}

public enum HookNames {
    public static func name(_ id: String) -> String {
        ["git-security": "Git Security", "security": "Security", "secret-guard": "Secret Guard"][id] ?? id
    }
}

public enum TimeRange: String, CaseIterable, Identifiable, Sendable {
    case hour, day, week, all
    public var id: String { rawValue }
    public var title: String { [Self.hour:"最近 1 小时", .day:"最近 24 小时", .week:"最近 7 天", .all:"全部时间"][self]! }
    public var seconds: Double? { [Self.hour:3600, .day:86400, .week:604800][self] }
}

public struct RunFilter: Equatable, Sendable {
    public var range: TimeRange = .day
    public var hookID: String = ""
    public var outcome: String = ""
    public var query: String = ""
    public var page: Int = 1
    public init() {}
}

public struct TrendPoint: Identifiable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)-\(outcome.rawValue)" }
    public let date: Date
    public let outcome: Outcome
    public let count: Int
}

public struct Snapshot: Sendable {
    public var total: Int = 0
    public var allTimeTotal: Int = 0
    public var counts: [Outcome: Int] = [:]
    public var averageMS: Double? = nil
    public var records: [HookRun] = []
    public var trend: [TrendPoint] = []
    public var hookIDs: [String] = []
    public var page: Int = 1
    public var pages: Int = 1
    public var refreshed: Date = .now
    public init() {}
}

public struct AppPaths: Sendable {
    public let root: URL
    public let codex: URL
    public init(root: URL? = nil, codex: URL? = nil) {
        self.root = root ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/HookScope", isDirectory: true)
        self.codex = codex ?? ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true)
    }
    public var database: URL { root.appendingPathComponent("hooks.sqlite3") }
    public var manifest: URL { root.appendingPathComponent("installation.json") }
    public var recorder: URL { root.appendingPathComponent("bin/hook-recorder") }
    public var hooks: URL { codex.appendingPathComponent("hooks.json") }
    public var legacyConfig: URL { codex.appendingPathComponent("hooks/personal-security/observer-config.json") }
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}

public struct HookScopeError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
