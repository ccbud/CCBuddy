import AppKit
import SwiftUI

struct MonitorPayloadTextView: NSViewRepresentable {
    let text: String
    let search: MonitorPayloadSearchState

    final class Coordinator {
        weak var textView: NSTextView?
        var renderedText = ""
        var renderedMatches: [NSRange] = []
        var renderedCurrentIndex: Int?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 13, height: 12)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityIdentifier("monitor.detail.payload")
        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        let shouldRender = context.coordinator.renderedText != text
            || context.coordinator.renderedMatches != search.matches
            || context.coordinator.renderedCurrentIndex != search.currentIndex

        if shouldRender {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3
            let rendered = NSMutableAttributedString(
                string: text,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular),
                    .foregroundColor: NSColor.labelColor,
                    .paragraphStyle: paragraph,
                ]
            )
            for (index, range) in search.matches.enumerated()
                where range.location != NSNotFound && NSMaxRange(range) <= rendered.length {
                rendered.addAttribute(
                    .backgroundColor,
                    value: index == search.currentIndex
                        ? NSColor.systemOrange.withAlphaComponent(0.48)
                        : NSColor.systemYellow.withAlphaComponent(0.34),
                    range: range
                )
            }
            textView.textStorage?.setAttributedString(rendered)
            context.coordinator.renderedText = text
            context.coordinator.renderedMatches = search.matches
            context.coordinator.renderedCurrentIndex = search.currentIndex
        }

        if let range = search.currentMatch, NSMaxRange(range) <= (text as NSString).length {
            textView.scrollRangeToVisible(range)
        }
    }
}

struct MonitorPayloadSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let next: () -> Void
    let previous: () -> Void
    let clear: () -> Void

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: MonitorPayloadSearchField

        init(parent: MonitorPayloadSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                    parent.previous()
                } else {
                    parent.next()
                }
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)),
               let field = control as? NSSearchField,
               !field.stringValue.isEmpty {
                field.stringValue = ""
                parent.text = ""
                parent.clear()
                return true
            }
            return false
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.font = .systemFont(ofSize: 11)
        field.controlSize = .small
        field.sendsSearchStringImmediately = true
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("monitor.detail.search")
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.stringValue != text { field.stringValue = text }
    }
}
