import SwiftUI

enum ProviderRowProbeState: Equatable {
    case idle, testing, succeeded, failed
}

struct ProviderRow: View {
    @Environment(\.appLanguage) private var appLanguage

    let provider: Provider
    let active: Bool
    let pluginRunning: Bool?
    let probeState: ProviderRowProbeState
    let dragProvider: () -> NSItemProvider
    let select: () -> Void
    let test: () -> Void
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideContent
                .frame(minWidth: 720)
            compactContent
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(minHeight: 60)
        .background(active ? Color.ccGreenSoft.opacity(0.45) : Color.ccElevated)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13)
                .stroke(active ? Color.ccGreen.opacity(0.34) : Color.ccBorder)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("provider.\(provider.id)")
        .accessibilityHint(
            appLanguage.localized(provider.backend == .plugin && pluginRunning != true
                ? "请先在插件页启用此插件"
                : "点按切换到此服务")
        )
    }

    private var wideContent: some View {
        HStack(spacing: 12) {
            Button(action: select) {
                HStack(spacing: 12) {
                    dragHandle
                    ProviderIconView(name: provider.name, icon: provider.icon, size: 36)
                    providerIdentity
                        .frame(minWidth: 260, maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(2)
                    Spacer(minLength: 8)
                    modelBadges
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appLanguage.localized("切换到\(provider.name)"))
            actionButtons
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Button(action: select) {
                    HStack(spacing: 10) {
                        dragHandle
                        ProviderIconView(name: provider.name, icon: provider.icon, size: 36)
                        providerIdentity
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(2)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(appLanguage.localized("切换到\(provider.name)"))
                actionButtons
            }
            Button(action: select) {
                modelBadges
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 58)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(appLanguage.localized("切换到\(provider.name)"))
        }
    }

    private var dragHandle: some View {
        HStack(spacing: 2) {
            ForEach(0..<2, id: \.self) { _ in
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Color.ccCaption.opacity(0.55))
                            .frame(width: 2, height: 2)
                    }
                }
            }
        }
        .frame(width: 8, height: 18)
        .onDrag(dragProvider)
        .accessibilityHidden(true)
        .help("拖动排序")
    }

    private var providerIdentity: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(provider.name).font(.system(size: 14.5, weight: .semibold))
                protocolBadge
                if active { badge("使用中", color: .ccGreen) }
                if provider.backend == .plugin {
                    badge("插件", color: .ccBrandStrong)
                    badge(
                        pluginRunning == true ? "运行中" : "已停用",
                        color: pluginRunning == true ? .ccGreen : .ccCaption
                    )
                }
            }
            Text(provider.backend == .plugin
                 ? "Sidecar · \(displayURL)"
                 : "\(masked(provider.authToken)) · \(displayURL)")
                .font(.system(size: 11.5, design: .monospaced))
                .foregroundStyle(Color.ccCaption)
                .lineLimit(1)
                .truncationMode(.middle)
                .privacySensitive()
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 1) {
            actionButton(
                probeSymbol,
                help: provider.backend == .plugin && pluginRunning != true ? "请先在插件页启用" : "连接测试",
                disabled: probeState == .testing || (provider.backend == .plugin && pluginRunning != true),
                identifier: "provider.\(provider.id).test",
                action: test
            )
            .foregroundStyle(probeColor)
            actionButton(
                "pencil",
                help: "编辑",
                disabled: provider.backend == .plugin,
                identifier: "provider.\(provider.id).edit",
                action: edit
            )
            actionButton(
                "trash",
                help: "删除",
                disabled: provider.backend == .plugin,
                identifier: "provider.\(provider.id).delete",
                action: delete
            )
        }
    }

    private var protocolBadge: some View {
        let translated = provider.protocol != .anthropic
        return Text(protocolLabel)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(translated ? Color.ccBrandStrong : Color.ccMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(translated ? Color.ccBrandSoft : Color.ccForeground.opacity(0.05))
            .clipShape(Capsule())
            .help(appLanguage.localized(
                translated ? "由 Bifrost 自动转换协议" : "Anthropic 协议直通"
            ))
    }

    private var protocolLabel: String {
        switch provider.protocol {
        case .anthropic: "Anthropic"
        case .openAIChat: "OpenAI Chat"
        case .openAIResponses: "OpenAI Responses"
        }
    }

    private var modelBadges: some View {
        HStack(spacing: 4) {
            if !provider.defaultModel.isEmpty { badge("主 \(provider.defaultModel)", color: .ccMuted) }
            if !provider.smallFastModel.isEmpty, provider.smallFastModel != provider.defaultModel {
                badge("快 \(provider.smallFastModel)", color: .ccMuted)
            }
            ForEach(provider.models.prefix(2)) { item in
                badge("\(item.alias) → \(item.upstream)", color: .ccBrandStrong)
            }
        }
        .lineLimit(1)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(appLanguage.localized(text))
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    private func actionButton(
        _ symbol: String,
        help: String,
        disabled: Bool = false,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ccCaption)
        .background(Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .disabled(disabled)
        .opacity(disabled && probeState != .testing ? 0.25 : 1)
        .help(appLanguage.localized(help))
        .accessibilityIdentifier(identifier)
    }

    private var probeSymbol: String {
        switch probeState {
        case .idle: "arrow.clockwise"
        case .testing: "ellipsis"
        case .succeeded: "checkmark"
        case .failed: "xmark"
        }
    }

    private var probeColor: Color {
        switch probeState {
        case .succeeded: .ccGreen
        case .failed: .ccRed
        default: .ccCaption
        }
    }

    private var displayURL: String {
        provider.baseUrl
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
    }

    private func masked(_ value: String) -> String {
        guard value.count > 10 else { return value.isEmpty ? "无密钥" : "••••" }
        return "\(value.prefix(4))••••\(value.suffix(4))"
    }
}
