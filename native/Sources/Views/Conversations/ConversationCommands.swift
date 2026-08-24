import SwiftUI

struct ConversationCommandActions {
    let focusSearch: () -> Void
    let refresh: () -> Void
}

private struct ConversationCommandActionsKey: FocusedValueKey {
    typealias Value = ConversationCommandActions
}

extension FocusedValues {
    var conversationCommandActions: ConversationCommandActions? {
        get { self[ConversationCommandActionsKey.self] }
        set { self[ConversationCommandActionsKey.self] = newValue }
    }
}

struct ConversationCommands: Commands {
    @FocusedValue(\.conversationCommandActions) private var actions

    var body: some Commands {
        CommandMenu("Conversations") {
            Button("Search Conversations") {
                actions?.focusSearch()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(actions == nil)

            Button("Refresh Sessions") {
                actions?.refresh()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(actions == nil)
        }
    }
}
