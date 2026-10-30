import SwiftUI
import HookCore

enum Page: String, CaseIterable, Identifiable {
    case overview = "概览", records = "记录", connection = "接入设置"
    var id: Self { self }
    var symbol: String {
        switch self { case .overview: "chart.bar.xaxis"; case .records: "list.bullet.rectangle"; case .connection: "link" }
    }
}

@MainActor final class AppModel: ObservableObject {
    let paths = AppPaths()
    @Published var page: Page? = .overview
    @Published var filter = RunFilter()
    @Published var snapshot = Snapshot()
    @Published var integration: IntegrationStatus?
    @Published var selectedID: String?
    @Published var selectedRun: HookRun?
    @Published var showInspector = false
    @Published var live = true
    @Published var loading = false
    @Published var working = false
    @Published var error: String?
    @Published var notice: String?
    private var generation = 0
    var recorderURL: URL { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/hook-recorder") }

    func start() async {
        let paths = paths
        do {
            try await Task.detached(priority:.userInitiated) {
                try paths.prepare()
                let store = RunStore(url:paths.database)
                let existed = FileManager.default.fileExists(atPath:paths.database.path)
                try store.initialize()
                if !existed, let legacy = Installer(paths:paths).legacyDatabase() { _ = try store.importHistory(from:legacy) }
            }.value
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func refresh() async {
        generation += 1
        let request = generation, filter = filter, paths = paths
        loading = true
        do {
            let result = try await Task.detached(priority:.userInitiated) {
                (try RunStore(url:paths.database).snapshot(filter), Installer(paths:paths).status())
            }.value
            guard request == generation else { return }
            snapshot = result.0; integration = result.1; loading = false
            if let id = selectedID, let row = snapshot.records.first(where: { $0.id == id }) { selectedRun = row }
        } catch {
            guard request == generation else { return }
            loading = false; self.error = error.localizedDescription
        }
    }
    func select(_ id: String?) {
        selectedID = id
        if let row = snapshot.records.first(where: { $0.id == id }) { selectedRun = row; showInspector = true }
    }
    func importHistory(from source: URL? = nil) async {
        guard !working else { return }
        working = true; defer { working = false }
        let paths = paths
        do {
            let count = try await Task.detached {
                if let source { return try RunStore(url:paths.database).importHistory(from:source) }
                return try Installer(paths:paths).importLegacy()
            }.value
            notice = "已导入 \(count) 条新记录，重复记录已自动合并。"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func connect() async {
        guard !working else { return }
        working = true; defer { working = false }
        let paths = paths, recorder = recorderURL
        do {
            _ = try await Task.detached { try Installer(paths:paths).install(recorder:recorder) }.value
            notice = "采集命令已配置。请前往 Codex 确认这些 hook 的信任状态，确认后新触发才会开始记录。"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() async {
        guard !working else { return }
        working = true; defer { working = false }
        let paths = paths
        do {
            try await Task.detached { try Installer(paths:paths).uninstall() }.value
            notice = "原始 hook 命令已恢复，历史记录已保留。请在 Codex 确认恢复后的配置。"
            await refresh()
        } catch { self.error = error.localizedDescription }
    }
}

extension Outcome {
    var color: Color {
        switch self { case .passed: .green; case .blocked: .orange; case .error: .red; case .running: .blue; case .incomplete: .secondary }
    }
}

func durationLabel(_ value: Double?) -> String {
    guard let value else { return "—" }
    return value < 1000 ? String(format:"%.0f ms",value) : String(format:"%.2f s",value/1000)
}
