import SwiftUI

/// Settings is a scene, not a peer destination.
///
/// It keeps the same three-column rhythm as the rest of the window — a rail on the list material,
/// content on the canvas — so arriving here does not feel like entering a different application.
/// The old back-chevron and the "设置 / 网关与应用偏好" caption above the rail are gone: the rail
/// already says where you are, and a second header only repeated it.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 0) {
            navigation
                .frame(width: 188)
            ScrollView {
                pane
                    .padding(.horizontal, Space.xl)
                    // Clear the traffic-light band so the first section never starts underneath it.
                    .padding(.top, Metrics.titleBarHeight + Space.sm)
                    .padding(.bottom, Space.xxl)
                    .frame(maxWidth: 780, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
                    .id(model.navigation.settingsPane)
            }
            .scrollIndicators(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.navigation.settingsPane)
        .settingsAccessibilityContainerIdentifier("view.settings", label: "设置")
    }

    private var navigation: some View {
        VStack(spacing: 0) {
            HStack {
                Text(appLanguage.localized("设置"))
                    .font(.ccTitle())
                    .tracking(-0.35)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.md)
            .padding(.top, Metrics.titleBarHeight + Space.sm)
            .padding(.bottom, Space.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WindowDragRegion())

            VStack(spacing: 2) {
                ForEach(AppModel.SettingsPane.functionalCases) { item in
                    paneRow(item)
                }
            }
            .padding(.horizontal, Space.sm)

            Spacer(minLength: Space.md)

            VStack(spacing: 2) {
                paneRow(.about)
            }
            .padding(.horizontal, Space.sm)
            .padding(.bottom, Space.md)

            Button {
                model.selected = .conversations
            } label: {
                Label(appLanguage.localized("返回会话"), systemImage: "chevron.left")
            }
            .buttonStyle(.ccQuiet)
            .padding(.horizontal, Space.sm)
            .padding(.bottom, Space.md)
            .accessibilityIdentifier("settings.close")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.list)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Theme.separator).frame(width: 1).accessibilityHidden(true)
        }
    }

    private func paneRow(_ item: AppModel.SettingsPane) -> some View {
        let selected = item == model.navigation.settingsPane
        return Button {
            model.selectSettingsPane(item)
        } label: {
            HStack(spacing: Space.sm) {
                Image(systemName: item.symbol)
                    .font(.system(size: Typography.body))
                    .frame(width: Rail.leadBox)
                Text(appLanguage.localized(item.title)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.ccBody(selected ? .medium : .regular))
            .foregroundStyle(selected ? Theme.foreground : Theme.mutedForeground)
            .padding(.horizontal, Space.sm)
            .frame(maxWidth: .infinity, minHeight: Metrics.rowHeight)
            .background(selected ? Theme.sidebarAccent : .clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings.nav.\(item.rawValue)")
    }

    @ViewBuilder private var pane: some View {
        switch model.navigation.settingsPane {
        case .general:
            GeneralSettingsPane()
                .settingsAccessibilityContainerIdentifier("settings.pane.general", label: "常规")
        case .locations:
            LocationsSettingsPane()
                .settingsAccessibilityContainerIdentifier("settings.pane.locations", label: "会话位置")
        case .gateway:
            GatewaySettingsPane()
                .settingsAccessibilityContainerIdentifier("settings.pane.gateway", label: "网关")
        case .data:
            DataSettingsPane()
                .settingsAccessibilityContainerIdentifier("settings.pane.data", label: "数据")
        case .about:
            AboutSettingsPane()
                .settingsAccessibilityContainerIdentifier("settings.pane.about", label: "关于与更新")
        }
    }
}

private extension View {
    /// A full-pane identifier propagates through SwiftUI and replaces identifiers on copy buttons
    /// and navigation controls. Keep the container marker independent so both levels remain
    /// addressable by accessibility automation.
    func settingsAccessibilityContainerIdentifier(_ identifier: String, label: String) -> some View {
        overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityIdentifier(identifier)
                .allowsHitTesting(false)
        }
    }
}
