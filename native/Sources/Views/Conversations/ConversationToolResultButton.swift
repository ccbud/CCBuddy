import AppKit
import SwiftUI

/// The visible disclosure strip is one real AppKit button, including its title and byte badge.
/// Keeping drawing, keyboard activation and accessibility on that same object avoids SwiftUI's
/// synthetic button losing its label inside a reused NSHostingView/NSTableCellView hierarchy.
struct ConversationToolResultButton: NSViewRepresentable {
    let title: String
    let summary: String
    let isError: Bool
    let fontSize: CGFloat
    let expandedValue: String
    let collapsedValue: String
    @Binding var expanded: Bool

    func makeNSView(context: Context) -> ConversationToolResultNativeButton {
        ConversationToolResultNativeButton()
    }

    func updateNSView(_ button: ConversationToolResultNativeButton, context: Context) {
        button.isEnabled = context.environment.isEnabled
        button.configure(title: title, summary: summary, isError: isError, fontSize: fontSize,
                         expanded: expanded, expandedValue: expandedValue, collapsedValue: collapsedValue,
                         onChange: { expanded = $0 })
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ConversationToolResultNativeButton,
                     context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 100, height: max(27, fontSize + 12))
    }

    static func dismantleNSView(_ button: ConversationToolResultNativeButton, coordinator: ()) {
        button.onChange = nil
    }
}

final class ConversationToolResultNativeButton: NSButton {
    private(set) var expanded = false
    private var summary = ""
    private var symbol = "✓"
    private var expandedValue = ""
    private var collapsedValue = ""
    private var resultColor = NSColor(Theme.success)
    var onChange: ((Bool) -> Void)?

    init() {
        super.init(frame: .zero)
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .exterior
        alignment = .left
        target = self
        action = #selector(toggleResult)
        setAccessibilityIdentifier("conversation.tool.result.disclosure")
    }

    required init?(coder: NSCoder) { nil }

    func configure(title: String, summary: String, isError: Bool, fontSize: CGFloat,
                   expanded: Bool, expandedValue: String, collapsedValue: String,
                   onChange: @escaping (Bool) -> Void) {
        self.title = title
        self.summary = summary
        self.symbol = isError ? "✗" : "✓"
        self.resultColor = NSColor(isError ? Theme.danger : Theme.success)
        self.font = .systemFont(ofSize: fontSize, weight: .semibold)
        self.expandedValue = expandedValue
        self.collapsedValue = collapsedValue
        self.onChange = onChange
        setExpanded(expanded)
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    private func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    @objc private func toggleResult() {
        guard isEnabled else { return }
        setExpanded(!expanded)
        onChange?(expanded)
    }

    override var acceptsFirstResponder: Bool { isEnabled }
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: max(27, (font?.pointSize ?? 9.5) + 12))
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Native tracking highlights on mouse-down and cancels on drag-out. Static color feedback
        // also respects Reduce Motion without an animation or delay on the interaction path.
        if isHighlighted {
            NSColor(Theme.foreground).withAlphaComponent(0.07).setFill()
            NSBezierPath(rect: bounds).fill()
        }
        let opacity: CGFloat = !isEnabled ? 0.5 : isHighlighted ? 0.82 : 1
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let label = NSAttributedString(string: "\(symbol)  \(title)", attributes: [
            .font: font ?? .systemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: resultColor.withAlphaComponent(opacity), .paragraphStyle: paragraph
        ])
        let badge = NSAttributedString(string: summary, attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold),
            .foregroundColor: NSColor(Theme.mutedForeground).withAlphaComponent(opacity),
            .paragraphStyle: paragraph
        ])
        let badgeWidth = summary.isEmpty ? 0 : min(badge.size().width + 12, max(0, bounds.width - 100))
        let labelWidth = max(0, bounds.width - 20 - (badgeWidth > 0 ? badgeWidth + 6 : 0))
        label.draw(in: NSRect(x: 10, y: (bounds.height - label.size().height) / 2,
                             width: labelWidth, height: label.size().height))
        if badgeWidth > 0 {
            let rect = NSRect(x: bounds.width - 10 - badgeWidth,
                              y: (bounds.height - badge.size().height - 2) / 2,
                              width: badgeWidth, height: badge.size().height + 2)
            NSColor(Theme.foreground).withAlphaComponent(0.05).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            badge.draw(in: rect.insetBy(dx: 6, dy: 1))
        }
    }

    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 5, yRadius: 5).fill()
    }

    private var resultLabel: String { title + (summary.isEmpty ? "" : ", " + summary) }
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityTitle() -> String? { resultLabel }
    override func accessibilityLabel() -> String? { resultLabel }
    override func accessibilityValue() -> Any? { expanded ? expandedValue : collapsedValue }
    override func accessibilityFrame() -> NSRect { ConversationNativeReaderViewGeometry.frame(of: self) }
    override func accessibilityActivationPoint() -> NSPoint {
        ConversationNativeReaderViewGeometry.activationPoint(of: self)
    }
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        performClick(nil)
        return true
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeNames() -> [NSAccessibility.Attribute] {
        var names = super.accessibilityAttributeNames()
        for name: NSAccessibility.Attribute in [.title, .description, .value, .position, .size]
            where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityAttributeValue(_ attribute: NSAccessibility.Attribute) -> Any? {
        switch attribute {
        case .title, .description: return resultLabel
        case .value: return accessibilityValue()
        case .position: return NSValue(point: accessibilityFrame().origin)
        case .size: return NSValue(size: accessibilityFrame().size)
        default: return super.accessibilityAttributeValue(attribute)
        }
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityActionNames() -> [NSAccessibility.Action] {
        var names = super.accessibilityActionNames().filter { $0 != .press }
        if isEnabled { names.append(.press) }
        return names
    }

    @available(macOS, deprecated: 10.10)
    override func accessibilityPerformAction(_ action: NSAccessibility.Action) {
        if action == .press { _ = accessibilityPerformPress() }
        else { super.accessibilityPerformAction(action) }
    }
}
