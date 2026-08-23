import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var navigationCollapsed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            HStack(alignment: .top, spacing: 20) {
                navigation
                ScrollView {
                    pane
                        .frame(maxWidth: 920)
                        .padding(.trailing, 4)
                        .padding(.bottom, 20)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
                        .id(model.navigation.settingsPane)
                }
                .scrollIndicators(.automatic)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: 1120, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.top, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(
            reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1),
            value: model.navigation.settingsPane
        )
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 1), value: navigationCollapsed)
        .settingsAccessibilityContainerIdentifier("view.settings", label: "设置")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                navigationCollapsed.toggle()
            } label: {
                Image(systemName: navigationCollapsed ? "chevron.right" : "chevron.left")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.ccMuted)
            .background(Color.ccElevated)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ccBorder))
            .accessibilityLabel("收起或展开设置导航")

            VStack(alignment: .leading, spacing: 2) {
                Text("设置")
                    .font(.system(size: 12.5, weight: .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Color.ccCaption)
                Text("网关与应用偏好")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.ccCaption)
            }
        }
    }

    private var navigation: some View {
        VStack(spacing: 2) {
            ForEach(AppModel.SettingsPane.allCases) { item in
                let selected = item == model.navigation.settingsPane
                Button {
                    model.selectSettingsPane(item)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.symbol)
                            .frame(width: 16)
                        if !navigationCollapsed {
                            Text(LocalizedStringKey(item.title)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.ccBrandStrong : Color.ccMuted)
                    .padding(.horizontal, navigationCollapsed ? 0 : 10)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(selected ? Color.ccBrandSoft : .clear)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityIdentifier("settings.nav.\(item.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.trailing, navigationCollapsed ? 8 : 16)
        .frame(width: navigationCollapsed ? 44 : 148)
        .frame(maxHeight: .infinity, alignment: .top)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.ccBorder)
                .frame(width: 1)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var pane: some View {
        switch model.navigation.settingsPane {
        case .gateway:
            GatewaySettingsPane()
                .settingsAccessibilityContainerIdentifier("settings.pane.gateway", label: "网关")
        case .general:
            GeneralSettingsPane()
                .settingsAccessibilityContainerIdentifier("settings.pane.general", label: "常规")
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
