import SwiftUI

/// A row's durable interaction state contains only explicit disclosure choices, never rendered
/// text or a retained view tree. The native reader owns these for one source/transcript scope so
/// cell recycling and an appended projection cannot collapse a reader's open tool output.
final class ConversationMessageInteractionState: ObservableObject {
    struct Key: Hashable {
        let blockIndex: Int
        let type: String
        let toolID: String?

        init(blockIndex: Int, block: HistoryContentBlock) {
            self.blockIndex = blockIndex
            type = block.type
            toolID = block.id ?? block.toolUseID
        }
    }

    @Published private(set) var choices: [Key: Bool] = [:]

    func isExpanded(_ key: Key, default defaultValue: Bool = false) -> Bool {
        choices[key] ?? defaultValue
    }

    func setExpanded(_ expanded: Bool, for key: Key) {
        guard choices[key] != expanded else { return }
        choices[key] = expanded
    }

    func binding(blockIndex: Int, block: HistoryContentBlock,
                 initiallyExpanded: Bool = false) -> Binding<Bool> {
        let key = Key(blockIndex: blockIndex, block: block)
        return Binding(get: { self.isExpanded(key, default: initiallyExpanded) },
                       set: { self.setExpanded($0, for: key) })
    }
}
