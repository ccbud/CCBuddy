import SwiftUI

enum ProviderRowProbeState: Equatable {
    case idle, testing, succeeded, failed
}

struct ProviderRow: View {
    @Environment(\.appLanguage) private var appLanguage

    let provider: Provider
    let active: Bool
    /// The provider's place in the failover queue, when that queue is what routes traffic. Nil
    /// while failover is off, so the badge only claims a priority that is actually in force.
    var failoverPriority: Int?
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
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .frame(minHeight: 56)
        // Selection speaks the same language everywhere in the app: the clay wash, not a second
        // status color. Green stays reserved for "the gateway is up".
        .background(active ? Theme.selection : Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.row, style: .continuous)
                .strokeBorder(active ? Theme.accent.opacity(0.35) : Theme.separator, lineWidth: 1)
        }
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
                            .fill(Theme.faintForeground)
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
                Text(provider.name).font(.ccBody(.semibold))
                protocolBadge
                if active { badge("使用中", color: Theme.accentText) }
                if let failoverPriority {
                    badge("P\(failoverPriority)", color: Theme.accentText)
                        .help(appLanguage.localized("故障转移优先级 \(failoverPriority)"))
                }
                if provider.backend == .plugin {
                    badge("插件", color: Theme.mutedForeground)
                    badge(
                        pluginRunning == true ? "运行中" : "已停用",
                        color: pluginRunning == true ? Theme.success : Theme.mutedForeground
                    )
                }
            }
            Text(provider.backend == .plugin
                 ? "Sidecar · \(displayURL)"
                 : "\(masked(provider.authToken)) · \(displayURL)")
                .font(.ccMono(Typography.label))
                .foregroundStyle(Theme.mutedForeground)
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
            .font(.ccLabel(.medium))
            .foregroundStyle(translated ? Theme.accentText : Theme.mutedForeground)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(translated ? Theme.accentSoft : Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
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
            if !provider.defaultModel.isEmpty { badge("主 \(provider.defaultModel)", color: Theme.mutedForeground) }
            if !provider.smallFastModel.isEmpty, provider.smallFastModel != provider.defaultModel {
                badge("快 \(provider.smallFastModel)", color: Theme.mutedForeground)
            }
            ForEach(provider.models.prefix(2)) { item in
                badge("\(item.alias) → \(item.upstream)", color: Theme.accentText)
            }
        }
        .lineLimit(1)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(appLanguage.localized(text))
            .font(.ccMono(Typography.label, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.badge, style: .continuous))
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
        }
        .buttonStyle(CCIconButtonStyle(size: 26, symbolSize: Typography.caption))
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
        case .succeeded: Theme.success
        case .failed: Theme.danger
        default: Theme.mutedForeground
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
