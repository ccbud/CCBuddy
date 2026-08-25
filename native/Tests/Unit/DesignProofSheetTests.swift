import AppKit
import SwiftUI
import XCTest

@testable import CCBuddy

/// Renders the design system off-screen so it can be inspected without a GUI session.
///
/// `ImageRenderer` draws through Core Graphics rather than the window server, so this works over
/// SSH, on CI, and while the screen is locked — which is exactly when a visual regression would
/// otherwise be impossible to catch.
///
/// It only draws SwiftUI's own rendering, though: AppKit-backed controls such as `TextField` come
/// out as a placeholder bar and `ScrollView` content does not appear at all. Sheets therefore cover
/// the design system itself — materials, inks, type, controls, rail rows — and not whole panels,
/// where a blank area could not be told apart from a real regression.
///
/// Opt in by creating `/tmp/ccg-proof` (or pointing `CCBUD_PROOF_SHEETS` somewhere) before running;
/// an ordinary run stays quiet.
@MainActor
final class DesignProofSheetTests: XCTestCase {
    /// Opt in by creating the directory before running: a hosted test process does not reliably
    /// inherit ad-hoc environment variables, and an existing directory is a signal that survives
    /// however the runner is launched.
    private var outputDirectory: URL? {
        let environmentPath = ProcessInfo.processInfo.environment["CCBUD_PROOF_SHEETS"]
        if let environmentPath, !environmentPath.isEmpty {
            let url = URL(fileURLWithPath: environmentPath, isDirectory: true)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let marker = URL(fileURLWithPath: "/tmp/ccg-proof", isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return nil }
        return marker
    }

    private func render<V: View>(_ name: String, _ view: V) throws {
        guard let outputDirectory else { throw XCTSkip("Set CCBUD_PROOF_SHEETS to render") }
        for (suffix, appearance) in [
            ("light", NSAppearance(named: .aqua)!),
            ("dark", NSAppearance(named: .darkAqua)!),
        ] {
            var data: Data?
            appearance.performAsCurrentDrawingAppearance {
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, suffix == "dark" ? .dark : .light))
                renderer.scale = 2
                guard let image = renderer.nsImage,
                      let tiff = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: tiff) else { return }
                data = bitmap.representation(using: .png, properties: [:])
            }
            let payload = try XCTUnwrap(data, "\(name) produced no image")
            try payload.write(to: outputDirectory.appendingPathComponent("\(name)-\(suffix).png"))
        }
    }

    func testRenderPaletteSheet() throws {
        try render("palette", PaletteProofSheet())
    }

    func testRenderControlsSheet() throws {
        try render("controls", ControlsProofSheet())
    }

    func testRenderRailSheet() throws {
        try render("rail", RailProofSheet())
    }

    func testRenderSessionRowSheet() throws {
        try render("session-rows", SessionRowProofSheet())
    }
}

// MARK: - Sheets

/// The session stream row in the states it actually appears in.
private struct SessionRowProofSheet: View {
    private static func metadata(
        _ id: String,
        _ title: String,
        _ source: HistorySource,
        _ project: String,
        starred: Bool = false,
        pinned: Bool = false,
        subagent: Bool = false
    ) -> HistorySessionMetadata {
        var value = HistorySessionMetadata(
            id: id,
            file: URL(fileURLWithPath: "/tmp/proof/\(id).jsonl"),
            source: source,
            dirID: "all",
            dirLabel: "all",
            sessionID: id,
            cwd: "/tmp/\(project)",
            project: project,
            title: title,
            autoTitle: title,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastActivity: Date(timeIntervalSince1970: 1_800_000_000),
            sizeBytes: 4_096,
            messageCount: 42
        )
        value.starred = starred
        value.pinned = pinned
        value.isSubagent = subagent
        return value
    }

    var body: some View {
        VStack(spacing: 2) {
            ConversationSessionRow(
                metadata: Self.metadata("a", "把会话索引限制从 600 提到全量", .codex, "ccg", pinned: true),
                selected: false, hit: nil, searchQuery: ""
            ) {}
            ConversationSessionRow(
                metadata: Self.metadata("b", "重画侧栏：一套导航模型", .claude, "ccg", starred: true),
                selected: true, hit: nil, searchQuery: ""
            ) {}
            ConversationSessionRow(
                metadata: Self.metadata("c", "Gauss the 2nd · audit_conversation_memory", .codex, "ccg", subagent: true),
                selected: false, hit: nil, searchQuery: ""
            ) {}
            ConversationSessionRow(
                metadata: Self.metadata("d", "索引空闲页从不回收的原因", .grok, "cherry-studio-lite"),
                selected: false,
                hit: HistorySearchHit(
                    sessionID: "d",
                    file: URL(fileURLWithPath: "/tmp/proof/d.jsonl"),
                    source: .grok,
                    snippet: "…auto_vacuum 在已有数据库上是 no-op，incremental_vacuum 因此空转…",
                    count: 3
                ),
                searchQuery: "vacuum"
            ) {}
            ConversationSessionRow(
                metadata: Self.metadata("e", "无标题", .antigravity, ""),
                selected: false, hit: nil, searchQuery: ""
            ) {}
        }
        .padding(Space.sm)
        .frame(width: Metrics.streamWidth)
        .background(Theme.list)
    }
}

private struct SwatchRow: View {
    let name: String
    let color: Color
    var ink: Color?

    var body: some View {
        HStack(spacing: Space.md) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous).fill(color)
                if let ink {
                    Text(verbatim: "Aa 内容").font(.ccBody()).foregroundStyle(ink)
                }
            }
            .frame(width: 190, height: 34)
            .overlay {
                RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                    .strokeBorder(Theme.separator, lineWidth: 1)
            }
            Text(name).font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
            Spacer(minLength: 0)
        }
    }
}

private struct PaletteProofSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(verbatim: "Materials").font(.ccHeading())
            VStack(spacing: Space.xs) {
                SwatchRow(name: "sidebar", color: Theme.sidebar, ink: Theme.foreground)
                SwatchRow(name: "list", color: Theme.list, ink: Theme.foreground)
                SwatchRow(name: "background", color: Theme.background, ink: Theme.foreground)
                SwatchRow(name: "surface", color: Theme.surface, ink: Theme.foreground)
                SwatchRow(name: "fill", color: Theme.fill, ink: Theme.mutedForeground)
                SwatchRow(name: "hover", color: Theme.hover, ink: Theme.mutedForeground)
                SwatchRow(name: "selection", color: Theme.selection, ink: Theme.accentText)
                SwatchRow(name: "sidebarAccent", color: Theme.sidebarAccent, ink: Theme.foreground)
            }

            Text(verbatim: "Accent and status").font(.ccHeading())
            VStack(spacing: Space.xs) {
                SwatchRow(name: "accent / onAccent", color: Theme.accent, ink: Theme.onAccent)
                SwatchRow(name: "accentSoft / accentText", color: Theme.accentSoft, ink: Theme.accentText)
                SwatchRow(name: "successSoft / success", color: Theme.successSoft, ink: Theme.success)
                SwatchRow(name: "dangerSoft / danger", color: Theme.dangerSoft, ink: Theme.danger)
                SwatchRow(name: "warningSoft / warning", color: Theme.warningSoft, ink: Theme.warning)
            }

            Text(verbatim: "Type scale").font(.ccHeading())
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(verbatim: "Title 22 · 全部会话").font(.ccTitle())
                Text(verbatim: "Heading 16 · 会话标题").font(.ccHeading())
                Text(verbatim: "Body 14 · 导航行与按钮").font(.ccBody())
                Text(verbatim: "Caption 12 · 元信息与说明").font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
                Text(verbatim: "Label 11 · 计数与状态").font(.ccLabel()).foregroundStyle(Theme.mutedForeground)
                Text(verbatim: "Mono 12 · localhost:8788").font(.ccMono())
            }
        }
        .padding(Space.xxl)
        .frame(width: 520, alignment: .leading)
        .background(Theme.background)
    }
}

private struct ControlsProofSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(verbatim: "Buttons").font(.ccHeading())
            HStack(spacing: Space.sm) {
                Button("在终端继续") {}.buttonStyle(.ccPrimary)
                Button("添加") {}.buttonStyle(.ccSecondary)
                Button("更多") {}.buttonStyle(.ccQuiet)
                Button("删除") {}.buttonStyle(.ccDanger)
                Button { } label: { Image(systemName: "star") }.buttonStyle(.ccIcon)
            }

            Text(verbatim: "Badges").font(.ccHeading())
            HStack(spacing: Space.sm) {
                CCBadge(text: "933")
                CCBadge(text: "Anthropic")
                CCKeyBadge(keys: "⌘K")
                CCStatusLabel(text: "网关运行中", tint: Theme.success)
                CCStatusLabel(text: "网关未启动", tint: Theme.mutedForeground)
            }

            Text(verbatim: "Section header").font(.ccHeading())
            CCSectionHeader("服务商") {
                Button("添加") {}.buttonStyle(.ccSecondary)
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
            .panelSurface(bordered: true)

            Text(verbatim: "Empty state").font(.ccHeading())
            CCEmptyState(
                symbol: "bubble.left.and.text.bubble.right",
                title: "选择左侧会话",
                message: "从列表里挑一个，或按 ⌘K 搜索。",
                compact: true
            )
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous))
        }
        .padding(Space.xxl)
        .frame(width: 560, alignment: .leading)
        .background(Theme.background)
    }
}

private struct RailProofSheet: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "CC Buddy").font(.ccHeading())
                Spacer(minLength: 0)
            }
            .padding(.leading, Rail.titleInset - Rail.edge + Space.xs)
            .padding(.bottom, Space.md)

            HStack(spacing: Space.xs + 2) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: Typography.caption, weight: .medium))
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(width: 14)
                Text(verbatim: "搜索会话").font(.ccCaption()).foregroundStyle(Theme.mutedForeground)
                Spacer(minLength: 0)
                CCKeyBadge(keys: "⌘K")
            }
            .padding(.horizontal, Space.sm)
            .frame(height: Metrics.rowHeight)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .padding(.bottom, Space.md)

            VStack(spacing: 2) {
                SidebarRow(lead: .symbol("bubble.left", size: 15), title: "会话", selected: true, identifier: "p1") {}
                SidebarRow(lead: .symbol("square.grid.2x2", size: 15), title: "服务", selected: false, identifier: "p2") {}
                SidebarRow(lead: .symbol("chart.line.uptrend.xyaxis", size: 15), title: "监控", selected: false, identifier: "p3") {}
            }
            .padding(.bottom, Space.md)

            VStack(spacing: 2) {
                SidebarRow(lead: .symbol("tray.full", size: 15), title: "全部会话", count: 933, selected: true, identifier: "l1") {}
                SidebarRow(lead: .symbol("star", size: 14), title: "收藏", count: 6, selected: false, identifier: "l2") {}
                SidebarRow(lead: .brand(.claude), title: "Claude Code", count: 2, selected: false, nested: true, identifier: "l3") {}
                SidebarRow(lead: .brand(.codex), title: "Codex", count: 749, selected: false, nested: true, identifier: "l4") {}
                SidebarRow(lead: .symbol("folder", size: 14), title: "ccg", count: 245, selected: false, nested: true, identifier: "l5") {}
            }
            Spacer(minLength: Space.md)
        }
        .padding(.horizontal, Rail.edge)
        .padding(.vertical, Space.lg)
        .frame(width: Metrics.sidebarWidth, height: 420)
        .background(Theme.sidebar)
    }
}
