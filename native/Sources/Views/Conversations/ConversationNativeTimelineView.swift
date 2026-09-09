import AppKit
import SwiftUI

/// One owned native scroll/table boundary supplies virtualization and a coherent accessibility
/// tree. Only available rows host SwiftUI content; the full projection remains addressable.
struct ConversationNativeTimelineView: NSViewRepresentable {
    let messages: [HistoryMessage]
    let inputs: ConversationTimelineReaderInputs
    let store: ConversationStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = ConversationNativeReaderScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.setAccessibilityIdentifier("conversation.timeline.scroll")
        scroll.onForwardedUserScroll = { [weak coordinator = context.coordinator] in
            coordinator?.userDidScroll()
        }

        let table = ConversationNativeReaderTable(frame: NSRect(x: 0, y: 0, width: 800, height: 0))
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("message"))
        column.width = 800
        column.minWidth = 1
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.rowHeight = 96
        table.usesAutomaticRowHeights = false
        table.allowsColumnReordering = false
        table.allowsColumnResizing = false
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = true
        table.selectionHighlightStyle = .none
        table.style = .plain
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.autoresizingMask = [.width]
        table.setAccessibilityIdentifier("conversation.timeline.table")
        table.delegate = context.coordinator
        table.dataSource = context.coordinator
        scroll.documentView = table
        context.coordinator.table = table
        table.onWidthChanged = { [weak coordinator = context.coordinator] in coordinator?.widthChanged() }
        table.onAccessibilityReveal = { [weak coordinator = context.coordinator] row in
            coordinator?.revealLogicalRow(row)
        }
        context.coordinator.update(messages: messages, inputs: inputs, environment: context.environment)
        return scroll
    }

    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.update(messages: messages, inputs: inputs, environment: context.environment)
    }

    static func dismantleNSView(_ view: NSScrollView, coordinator: Coordinator) {
        coordinator.disconnect()
    }

    @MainActor final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        let store: ConversationStore
        weak var table: ConversationNativeReaderTable?
        private var messages: [HistoryMessage] = []
        private var inputs: ConversationTimelineReaderInputs?
        private var environment = EnvironmentValues()
        private var rowMap = ConversationNativeReaderRowMap()
        private let interactionStore = ConversationNativeReaderInteractionStore()
        private var heights = ConversationNativeReaderHeights()
        private var pendingMeasurements: Set<Int> = []
        private var measurementScheduled = false
        private var measuring = false
        private var measuringSources: Set<Int> = []
        private var navigationScheduled = false
        private var applyingNavigation = false
        private var contentGeneration: UInt64 = 0
        private var reusableCells: [ConversationNativeReaderCell] = []
        private var focusedCell: ConversationNativeReaderCell?

        init(store: ConversationStore) { self.store = store }

        func update(messages: [HistoryMessage], inputs: ConversationTimelineReaderInputs,
                    environment: EnvironmentValues) {
            guard let table else { return }
            let scopeChanged = self.inputs?.scope != inputs.scope
            let contentChanged = scopeChanged || self.inputs?.projection !== inputs.projection
            let anchor = scopeChanged ? nil : readingAnchor()
            self.messages = messages
            self.inputs = inputs
            self.environment = environment
            table.rowActionTitle = { source in
                source.map { environment.appLanguage.localized("消息") + " \($0 + 1)" }
                    ?? environment.appLanguage.localized("最新消息")
            }

            if contentChanged {
                // A detached text-selection host is valid only for the immutable content it
                // displayed. Never pin an obsolete giant transcript after live source refresh.
                focusedCell?.discardContent()
                focusedCell = nil
                interactionStore.update(scope: inputs.scope,
                                        sourceIndices: inputs.projection.visibleMessageIndices)
                let change = rowMap.replace(with: inputs.projection.visibleMessageIndices)
                if scopeChanged {
                    contentGeneration &+= 1
                    releaseReusableContent()
                    pendingMeasurements.removeAll(keepingCapacity: true)
                }
                heights.retainSources(rowMap.rowBySource, resetting: scopeChanged)
                table.installLogicalRows(sourceIndices: rowMap.sourceIndices, resetting: scopeChanged)
                if scopeChanged {
                    table.reloadData()
                } else if !change.isEmpty {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0
                        table.beginUpdates()
                        table.removeRows(at: change.removed, withAnimation: [])
                        table.insertRows(at: change.inserted, withAnimation: [])
                        table.endUpdates()
                    }
                }
            }
            refreshAvailableCells()
            if let anchor { restoreReadingAnchor(anchor) }
            scheduleNavigation()
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rowMap.sourceIndices.count + 1 }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            guard rowMap.sourceIndices.indices.contains(row) else { return 68 }
            return heights.estimate(for: rowMap.sourceIndices[row])
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let source = rowMap.sourceIndices.indices.contains(row) ? rowMap.sourceIndices[row] : nil
            let cell: ConversationNativeReaderCell
            if let focusedCell, focusedCell.sourceIndex == source,
               focusedCell.contentGeneration == contentGeneration {
                cell = focusedCell
                self.focusedCell = nil
            } else {
                cell = reusableCells.popLast() ?? ConversationNativeReaderCell()
            }
            // Own a bounded reuse pool instead of allowing AppKit to reassign a selected text
            // host. The one focused row can remain resident offscreen, without retaining all rows.
            cell.identifier = nil
            cell.retainsTextFocus = false
            cell.onWillDetach = { [weak self, weak cell] in
                guard let self, let cell, let responder = self.table?.window?.firstResponder as? NSView,
                      responder === cell.host || responder.isDescendant(of: cell.host) else { return }
                cell.retainsTextFocus = true
            }
            configure(cell: cell, row: row)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let result = ConversationNativeReaderRowView()
            result.logicalIndex = row
            result.table = tableView as? ConversationNativeReaderTable
            return result
        }

        func tableView(_ tableView: NSTableView, didRemove rowView: NSTableRowView, forRow row: Int) {
            guard let cell = rowView.view(atColumn: 0) as? ConversationNativeReaderCell else { return }
            cell.onIntrinsicSizeInvalidated = nil
            if cell.canRetainTextFocus(projection: inputs?.projection, generation: contentGeneration,
                                      visibleSources: rowMap.rowBySource) {
                focusedCell?.discardContent()
                focusedCell = cell
            } else {
                cell.discardContent()
                if reusableCells.count < 12 { reusableCells.append(cell) }
            }
        }

        func widthChanged() {
            let anchor = readingAnchor()
            // Keep prior row heights as estimates until the new layout is actually measured.
            // Replacing a tall row with a 96-point estimate would clamp (and lose) a reading
            // offset deep inside that row before its new SwiftUI height can arrive.
            refreshAvailableCells()
            if let anchor { restoreReadingAnchor(anchor) }
            scheduleNavigation()
        }

        private func refreshAvailableCells() {
            table?.enumerateAvailableRowViews { [weak self] rowView, row in
                guard let cell = rowView.view(atColumn: 0) as? ConversationNativeReaderCell else { return }
                (rowView as? ConversationNativeReaderRowView)?.logicalIndex = row
                self?.configure(cell: cell, row: row)
            }
        }

        private func configure(cell: ConversationNativeReaderCell, row: Int) {
            guard let table, let inputs, row >= 0, row <= rowMap.sourceIndices.count else { return }
            let source = rowMap.sourceIndices.indices.contains(row) ? rowMap.sourceIndices[row] : nil
            cell.logicalIndex = row
            cell.sourceIndex = source
            cell.projection = inputs.projection
            cell.contentGeneration = contentGeneration
            cell.onIntrinsicSizeInvalidated = { [weak self, weak cell] in
                guard let cell, cell.sourceIndex == source, let source else { return }
                self?.scheduleMeasurement(source)
            }
            let width = max(1, table.tableColumns.first?.width ?? table.bounds.width)
            let content: AnyView
            if let index = source, messages.indices.contains(index) {
                content = AnyView(ConversationMessageView(
                    message: messages[index], messageIndex: index,
                    sourceRawValue: inputs.sourceRawValue, projection: inputs.projection,
                    searchQuery: inputs.query, isCurrentSearchMatch: inputs.currentMatch == index,
                    fontSize: inputs.fontSize, interactionState: interactionStore.state(for: index)
                )
                .padding(.horizontal, Space.xl)
                .padding(.top, row == 0 ? Space.xxl : 0)
                .padding(.bottom, Space.xxl)
                .frame(maxWidth: Metrics.readingMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("conversation.message.\(index)")
                .id(ContentIdentity(generation: contentGeneration, index: index)))
            } else {
                content = AnyView(Color.clear.frame(height: 68).accessibilityHidden(true))
            }
            cell.host.rootView = ConversationNativeReaderHostedContent(
                content: content, environment: environment, width: width)
            if let source { scheduleMeasurement(source) }
        }

        private func scheduleMeasurement(_ source: Int) {
            guard !measuringSources.contains(source) else { return }
            pendingMeasurements.insert(source)
            guard !measurementScheduled, !measuring else { return }
            measurementScheduled = true
            DispatchQueue.main.async { [weak self] in self?.measurePendingRows() }
        }

        private func measurePendingRows() {
            measurementScheduled = false
            guard let table else { return }
            let sources = pendingMeasurements
            pendingMeasurements.removeAll(keepingCapacity: true)
            measuringSources = sources
            let anchor = readingAnchor()
            measuring = true
            var changed = IndexSet()
            for source in sources {
                guard let row = rowMap.rowBySource[source],
                      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: false) as? ConversationNativeReaderCell,
                      cell.sourceIndex == source else { continue }
                let measured = cell.host.fittingSize.height
                guard measured.isFinite else { continue }
                let height = max(1, ceil(measured))
                if heights.record(height, for: source) {
                    changed.insert(row)
                }
            }
            if !changed.isEmpty {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0
                    table.noteHeightOfRows(withIndexesChanged: changed)
                }
                if let anchor { restoreReadingAnchor(anchor) }
            }
            measuring = false
            measuringSources.removeAll(keepingCapacity: true)
            // Content arriving during measurement queues its own real invalidation. There is no
            // delay/retry loop; unchanged layout does not keep navigating or rebuilding rows.
            if let source = pendingMeasurements.first { scheduleMeasurement(source) }
            if !changed.isEmpty { scheduleNavigation() }
        }

        private func readingAnchor() -> ConversationNativeReaderAnchor? {
            guard let table, let scroll = table.enclosingScrollView, !rowMap.sourceIndices.isEmpty else { return nil }
            let origin = scroll.contentView.bounds.minY
            let visibleRow = table.row(at: NSPoint(x: 1, y: max(0, origin)))
            let row = min(max(0, visibleRow), rowMap.sourceIndices.count - 1)
            return .init(sourceIndex: rowMap.sourceIndices[row],
                         offsetWithinRow: origin - table.rect(ofRow: row).minY)
        }

        private func restoreReadingAnchor(_ anchor: ConversationNativeReaderAnchor) {
            guard let table, let scroll = table.enclosingScrollView,
                  let row = rowMap.row(nearestTo: anchor.sourceIndex) else { return }
            let rect = table.rect(ofRow: row)
            let y = anchor.origin(rowOrigin: rect.minY, rowHeight: rect.height,
                                  maximumOrigin: table.bounds.height - scroll.contentView.bounds.height)
            guard abs(scroll.contentView.bounds.minY - y) > 0.5 else { return }
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        private func scheduleNavigation() {
            guard !navigationScheduled else { return }
            navigationScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.navigationScheduled = false
                self.applyNavigation()
            }
        }

        private func applyNavigation() {
            guard !applyingNavigation, let table, let inputs,
                  let request = inputs.layoutRequest, store.scrollLayoutRequest == request,
                  let scroll = table.enclosingScrollView else { return }
            let row: Int
            let bottom: Bool
            switch request.target {
            case .latest:
                row = rowMap.sourceIndices.count
                bottom = true
            case .message(let jump):
                guard let target = rowMap.rowBySource[jump.messageIndex] else { return }
                row = target
                bottom = false
            }
            applyingNavigation = true
            defer { applyingNavigation = false }
            table.scrollRowToVisible(row)
            let rect = table.rect(ofRow: row)
            let maximumY = max(0, table.bounds.height - scroll.contentView.bounds.height)
            let y = bottom ? maximumY : min(maximumY, max(0, rect.minY))
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }

        func revealLogicalRow(_ row: Int) {
            guard let table, row >= 0, row < table.numberOfRows else { return }
            userDidScroll()
            table.scrollRowToVisible(row)
            NSAccessibility.post(element: table, notification: .layoutChanged)
        }

        func userDidScroll() {
            guard let inputs, store.activeTranscriptFile == inputs.scope.file,
                  store.activeTranscriptID == inputs.scope.transcriptID else { return }
            store.pauseFollowingLatestFromUserScroll()
        }

        private func releaseReusableContent() {
            focusedCell?.discardContent()
            focusedCell = nil
            for cell in reusableCells { cell.discardContent() }
            reusableCells.removeAll(keepingCapacity: true)
        }

        func disconnect() {
            contentGeneration &+= 1
            if let scroll = table?.enclosingScrollView as? ConversationNativeReaderScrollView {
                scroll.disconnectWheelRouting()
                scroll.onForwardedUserScroll = nil
            }
            table?.onWidthChanged = nil
            table?.onAccessibilityReveal = nil
            table?.delegate = nil
            table?.dataSource = nil
            releaseReusableContent()
            pendingMeasurements.removeAll()
            table = nil
        }
    }

    private struct ContentIdentity: Hashable {
        let generation: UInt64
        let index: Int
    }
}
