import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.appLanguage) private var appLanguage

    var body: some View {
        VStack(spacing: 0) {
            Color.clear.frame(height: 48)
            brand.padding(.horizontal, model.sidebarCollapsed ? 5 : 6).padding(.bottom, 20)
            VStack(spacing: 2) {
                ForEach(AppModel.Destination.allCases) { destination in
                    navButton(destination)
                }
            }
            Spacer(minLength: 12)
            footer
        }
        .padding(.horizontal, model.sidebarCollapsed ? 5 : 10)
        .padding(.bottom, 14)
        .background(Color.ccSidebar.opacity(0.96))
    }

    private var brand: some View {
        HStack(spacing: 9) {
            AppLogo().frame(width: 30, height: 30)
            if !model.sidebarCollapsed {
                VStack(alignment: .leading, spacing: 1) {
                    Text("CC Buddy").font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("Coding CLI Buddy").font(.system(size: 11.5)).foregroundStyle(Color.ccCaption).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func navButton(_ destination: AppModel.Destination) -> some View {
        let selected = model.selected == destination
        return Button {
            withAnimation(.easeOut(duration: 0.18)) { model.selected = destination }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: destination.symbol).frame(width: 16, height: 16)
                if !model.sidebarCollapsed {
                    Text(LocalizedStringKey(destination.title))
                    Spacer(minLength: 0)
                }
            }
            .font(.system(size: 13.5, weight: selected ? .semibold : .medium))
            .foregroundStyle(selected ? Color.ccBrandStrong : Color.ccMuted)
            .padding(.horizontal, model.sidebarCollapsed ? 0 : 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(selected ? Color.ccBrandSoft : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(appLanguage.localized(destination.title))
        .accessibilityIdentifier("sidebar.\(destination.rawValue)")
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if !model.sidebarCollapsed {
                HStack(spacing: 5) {
                    Circle().fill(model.gatewayState.isRunning ? Color.ccGreen : Color.ccMuted).frame(width: 5, height: 5)
                    Text(LocalizedStringKey(model.gatewayState.isRunning ? "已接入" : "未接入"))
                }
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(model.gatewayState.isRunning ? Color.ccGreen : Color.ccMuted)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(model.gatewayState.isRunning ? Color.ccGreenSoft : Color.ccForeground.opacity(0.05))
                .clipShape(Capsule())
                Spacer(minLength: 0)
            }
            VStack(spacing: 3) {
                if !model.sidebarCollapsed { EmptyView() }
                footerButton(
                    symbol: model.sidebarCollapsed ? "chevron.right" : "chevron.left",
                    label: model.sidebarCollapsed ? "展开侧边栏" : "收起侧边栏",
                    identifier: "sidebar.collapse"
                ) { model.toggleSidebar() }
                footerButton(
                    symbol: model.themeMode == .dark ? "sun.max" : "moon",
                    label: model.themeMode == .dark ? "切换到浅色模式" : "切换到深色模式",
                    identifier: "sidebar.theme"
                ) { model.toggleTheme() }
            }
        }
        .padding(.top, 12)
        .overlay(alignment: .top) { Rectangle().fill(Color.ccBorder).frame(height: 1) }
    }

    private func footerButton(
        symbol: String,
        label: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).frame(width: 26, height: 26) }
            .buttonStyle(.plain).foregroundStyle(Color.ccMuted).background(Color.ccElevated)
            .clipShape(RoundedRectangle(cornerRadius: 7)).overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.ccBorder))
            .accessibilityLabel(appLanguage.localized(label))
            .accessibilityIdentifier(identifier)
    }
}

private struct AppLogo: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "icon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.ccBrandSoft)
                Image(systemName: "command").foregroundStyle(Color.ccBrandStrong)
            }
        }
    }
}
