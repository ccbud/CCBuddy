import SwiftUI

@main
struct CCBuddyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var commandLocalization = CommandLocalization()

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
                LiveApplicationRoot(appDelegate: appDelegate, commandLocalization: commandLocalization)
            }
        }
        // Wide enough for all four columns at the widths they were designed at: 224 rail, 336
        // stream, 288 overview and a 380-point column left to read in. At the old 1180 they fitted
        // only by taking three points off the stream, which is a poor first impression of a layout
        // that is meant to be roomy.
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        // Shortcuts are declared here rather than on a hidden zero-sized Button: a scene command is
        // the dependable place to register one, and it also puts the shortcut in the menu bar where
        // it can be discovered.
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .appSettings) {
                Button { post(.ccbudOpenSettings) } label: { commandText("设置…") }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandMenu(commandText("会话")) {
                Button { post(.ccbudFocusSearch) } label: { commandText("搜索会话") }
                    .keyboardShortcut("k", modifiers: .command)
                Button { post(.ccbudRefreshCatalog) } label: { commandText("更新会话索引") }
                    .keyboardShortcut("r", modifiers: .command)
                Divider()
                Button { post(.ccbudToggleFocusMode) } label: { commandText("专注阅读") }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandMenu(commandText("前往")) {
                destinationCommand(.conversations, key: "1")
                destinationCommand(.timeline, key: "2")
                destinationCommand(.providers, key: "3")
                destinationCommand(.monitor, key: "4")
                destinationCommand(.skills, key: "5")
                destinationCommand(.plugins, key: "6")
            }
        }
    }

    private func destinationCommand(_ destination: AppModel.Destination, key: KeyEquivalent) -> some View {
        Button {
            NotificationCenter.default.post(name: .ccbudNavigate, object: destination)
        } label: {
            commandText(destination.title)
        }
        .keyboardShortcut(key, modifiers: .command)
    }

    private func commandText(_ source: String) -> Text {
        Text(verbatim: commandLocalization.language.localized(source))
    }
}

/// Commands live above the window's locale environment. Sharing only this lightweight language
/// state keeps menus reactive without constructing a production AppModel in a hosted unit test.
@MainActor
final class CommandLocalization: ObservableObject {
    @Published var language = AppLanguage(locale: .autoupdatingCurrent)
}

private func post(_ name: Notification.Name) {
    NotificationCenter.default.post(name: name, object: nil)
}

private struct LiveApplicationRoot: View {
    let appDelegate: AppDelegate
    @ObservedObject var commandLocalization: CommandLocalization
    @StateObject private var model = AppModel()
    @State private var minimumContentHeight = WindowConfigurator.minimumFrameSize.height

    var body: some View {
        AppShellView()
            .environmentObject(model)
            .environment(\.locale, model.appLanguage.locale)
            .environment(\.appLanguage, model.appLanguage)
            .preferredColorScheme(model.themeMode.colorScheme)
            .background(WindowConfigurator(colorScheme: model.themeMode.colorScheme) { window in
                appDelegate.attach(model: model)
                appDelegate.registerMainWindow(window)
                let height = WindowConfigurator.minimumContentHeight(
                    frameHeight: window.frame.height,
                    contentLayoutHeight: window.contentLayoutRect.height
                )
                if minimumContentHeight != height { minimumContentHeight = height }
            })
            .onAppear {
                commandLocalization.language = model.appLanguage
                appDelegate.attach(model: model)
            }
            .onChange(of: model.appLanguage) { language in
                commandLocalization.language = language
            }
            // Keep SwiftUI's content constraint consistent with the complete 940 × 620 window.
            // NSWindow.minSize alone does not enforce the minimum under SwiftUI Auto Layout.
            .frame(minWidth: WindowConfigurator.minimumFrameSize.width, minHeight: minimumContentHeight)
    }
}
