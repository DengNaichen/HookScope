import SwiftUI
import HookCore

@main struct HookScopeApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("HookScope", id:"main") {
            ContentView(model:model)
                .environment(\.locale,Locale(identifier:"zh_CN"))
                .frame(minWidth:960,minHeight:650)
                .task { await model.start() }
        }
        .defaultSize(width:1180,height:780)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing:.newItem) {}
            CommandGroup(after:.toolbar) {
                Button("刷新记录") { Task { await model.refresh() } }.keyboardShortcut("r")
                Toggle("自动刷新",isOn:$model.live)
            }
        }
        Settings {
            ConnectionView(model:model).frame(width:640,height:640)
                .environment(\.locale,Locale(identifier:"zh_CN"))
        }
    }
}
