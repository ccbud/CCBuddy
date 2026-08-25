import SwiftUI

@main
struct CCBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("CC Buddy") {
            // Hosted XCTest launches the application executable to load CCBuddyTests.xctest.
            // Constructing the production AppModel here would read live configuration/history,
            // contend for the single-instance lock, and potentially start background services
            // before a test method runs. Tests construct every model they need explicitly.
            if AppModel.processRuntimeMode(environment: ProcessInfo.processInfo.environment)
                == .unitTestHost {
                EmptyView()
            } else {
                LiveApplicationRoot(appDelegate: appDelegate)
            }
        }
        .defaultSize(width: 1180, height: 760)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        // Shortcuts are declared here rather than on a hidden zero-sized Button: a scene command is
        // the dependable place to register one, and it also puts the shortcut in the menu bar where
        // it can be discovered.
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { post(.ccbudOpenSettings) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu("会话") {
                Button("搜索会话") { post(.ccbudFocusSearch) }
                    .keyboardShortcut("k", modifiers: .command)
                Button("更新会话索引") { post(.ccbudRefreshCatalog) }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }
}

private func post(_ name: Notification.Name) {
    NotificationCenter.default.post(name: name, object: nil)
}

private struct LiveApplicationRoot: View {
    let appDelegate: AppDelegate
    @StateObject private var model = AppModel()

    var body: some View {
        AppShellView()
            .environmentObject(model)
            .environment(\.locale, model.appLanguage.locale)
            .environment(\.appLanguage, model.appLanguage)
            .preferredColorScheme(model.themeMode.colorScheme)
            .background(WindowConfigurator { window in
                appDelegate.attach(model: model)
                appDelegate.registerMainWindow(window)
            })
            .onAppear { appDelegate.attach(model: model) }
            .frame(minWidth: 940, minHeight: 620)
    }
}
