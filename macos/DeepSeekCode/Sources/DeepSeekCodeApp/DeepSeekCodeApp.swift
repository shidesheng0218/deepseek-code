import SwiftUI
import DeepSeekCodeCore

@main
struct DeepSeekCodeApp: App {
    @State private var store = WorkspaceStore()
    @State private var browserAutomationController = BrowserController()
    @State private var didProcessLaunchTrigger = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(browserAutomationController)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    _ = browserAutomationController.makeWebView()
                    guard !didProcessLaunchTrigger else { return }
                    didProcessLaunchTrigger = true
                    store.consumeScheduledTriggerFromLaunchArguments()
                }
        }
        .defaultSize(width: 1_440, height: 900)
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .newItem) {
                Button("打开项目…") {
                    store.isProjectPickerPresented = true
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandMenu("Agent") {
                Button("发送任务") {
                    store.sendTask()
                }
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
    }
}
