import SwiftUI

enum ConversationFontSizeMode: String, CaseIterable, Identifiable {
    case defaultSize
    case large
    case extraLarge
    case custom

    static let defaultPoints = 13
    static let largePoints = 15
    static let extraLargePoints = 17
    static let minimumPoints = 10
    static let maximumPoints = 24

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultSize: "默认"
        case .large: "大"
        case .extraLarge: "特大"
        case .custom: "自定义"
        }
    }

    static func resolved(from configuredPoints: Int?) -> Self {
        switch normalized(configuredPoints) {
        case defaultPoints: .defaultSize
        case largePoints: .large
        case extraLargePoints: .extraLarge
        default: .custom
        }
    }

    static func normalized(_ points: Int?) -> Int {
        min(maximumPoints, max(minimumPoints, points ?? defaultPoints))
    }

    /// `nil` is the persisted representation of the default. Custom is deliberately excluded:
    /// selecting it reveals the numeric field without changing the user's existing value.
    var presetConfiguration: Int? {
        switch self {
        case .defaultSize: nil
        case .large: Self.largePoints
        case .extraLarge: Self.extraLargePoints
        case .custom: nil
        }
    }
}

struct GeneralSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @State private var tokenDraft = ""
    @State private var customFontSize = ConversationFontSizeMode.defaultPoints
    @State private var customFontModeOpen = false

    var body: some View {
        VStack(spacing: 28) {
            SettingsCard("应用") {
                HStack(spacing: 28) {
                    Toggle(
                        "开机自启动",
                        isOn: Binding(
                            get: { model.config.openAtLogin },
                            set: { enabled in Task { await model.setOpenAtLogin(enabled) } }
                        )
                    )
                    .toggleStyle(.switch).controlSize(.small)

                    Toggle(
                        "本地访问令牌",
                        isOn: Binding(
                            get: { model.config.requireToken },
                            set: { enabled in Task { await model.setRequireToken(enabled) } }
                        )
                    )
                    .toggleStyle(.switch).controlSize(.small)
                }

                if model.config.requireToken {
                    HStack(spacing: 8) {
                        SecureField("网关令牌", text: $tokenDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .background(Theme.fill)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.button))
                            .overlay(RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.separator))
                            .onSubmit { Task { await model.setGatewayToken(tokenDraft) } }
                        Button("保存") { Task { await model.setGatewayToken(tokenDraft) } }
                            .buttonStyle(CompactActionButtonStyle())
                        Button("生成") {
                            Task {
                                await model.generateGatewayToken()
                                tokenDraft = model.config.gatewayToken
                            }
                        }
                        .buttonStyle(CompactActionButtonStyle())
                    }
                    Text("令牌会同步写入已接入的 Claude Code 与 Codex 配置。")
                        .font(.ccCaption())
                        .foregroundStyle(Theme.mutedForeground)
                }

                SettingsDivider()
                HStack(spacing: 18) {
                    Toggle(
                        "菜单栏显示用量",
                        isOn: Binding(
                            get: { model.config.trayUsage.enabled },
                            set: { enabled in
                                Task {
                                    await model.setTrayUsage(
                                        enabled: enabled,
                                        range: model.config.trayUsage.range
                                    )
                                }
                            }
                        )
                    )
                    .toggleStyle(.switch).controlSize(.small)
                    if model.config.trayUsage.enabled {
                        Picker(
                            "范围",
                            selection: Binding(
                                get: { model.config.trayUsage.range },
                                set: { range in
                                    Task { await model.setTrayUsage(enabled: true, range: range) }
                                }
                            )
                        ) {
                            Text("今日").tag("1d")
                            Text("近 7 天").tag("7d")
                            Text("近 30 天").tag("30d")
                            Text("全部").tag("all")
                        }
                        .labelsHidden().frame(width: 110)
                    }
                    Spacer()
                }

                SettingsDivider()
                HStack(spacing: 14) {
                    Text("语言").font(.system(size: 12.5, weight: .medium))
                    Picker(
                        "语言",
                        selection: Binding(
                            get: { model.config.language ?? model.appLanguage.rawValue },
                            set: { language in Task { await model.setLanguage(language) } }
                        )
                    ) {
                        Text("English").tag("en")
                        Text("简体中文").tag("zh")
                        Text("繁體中文").tag("zh-TW")
                        Text("日本語").tag("ja")
                        Text("한국어").tag("ko")
                    }
                    .labelsHidden().frame(width: 135)
                    Spacer()
                }
            }

            SettingsCard("会话") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) {
                        fontSizeDescription
                            .fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 12)
                        fontSizeControls
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        fontSizeDescription
                        fontSizeControls
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }

                HStack(spacing: 12) {
                    Text("会话正文将以这个大小显示 — 这是一段用于预览的示例文字。")
                        .font(.system(size: CGFloat(displayedFontSize)))
                        .lineLimit(2)
                        .accessibilityIdentifier("settings.general.font.preview")
                    Spacer(minLength: 0)
                    Text("\(displayedFontSize)px")
                        .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(Theme.foreground.opacity(0.05))
                        .clipShape(Capsule())
                        .accessibilityIdentifier("settings.general.font.preview.value")
                }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.fill)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.row))
                    .overlay(RoundedRectangle(cornerRadius: Radius.row).stroke(Theme.separator))
            }
        }
        .onAppear {
            tokenDraft = model.config.gatewayToken
            customFontSize = ConversationFontSizeMode.normalized(model.config.convFontPx)
            customFontModeOpen = ConversationFontSizeMode.resolved(
                from: model.config.convFontPx
            ) == .custom
        }
        .onChange(of: model.config.gatewayToken) { tokenDraft = $0 }
    }

    private var selectedFontMode: ConversationFontSizeMode {
        if customFontModeOpen { return .custom }
        return ConversationFontSizeMode.resolved(from: model.config.convFontPx)
    }

    private var displayedFontSize: Int {
        selectedFontMode == .custom
            ? ConversationFontSizeMode.normalized(customFontSize)
            : ConversationFontSizeMode.normalized(model.config.convFontPx)
    }

    private var fontSizeModeBinding: Binding<ConversationFontSizeMode> {
        Binding(
            get: { selectedFontMode },
            set: { mode in
                if mode == .custom {
                    customFontSize = ConversationFontSizeMode.normalized(model.config.convFontPx)
                    customFontModeOpen = true
                    return
                }
                customFontModeOpen = false
                Task { await model.setConversationFontSize(mode.presetConfiguration) }
                customFontSize = ConversationFontSizeMode.normalized(mode.presetConfiguration)
            }
        )
    }

    private var fontSizeDescription: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("正文字号").font(.system(size: 12.5, weight: .medium))
            Text("调整会话页消息正文的字体大小。")
                .font(.ccCaption())
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var fontSizeControls: some View {
        HStack(spacing: 8) {
            Picker("字号", selection: fontSizeModeBinding) {
                ForEach(ConversationFontSizeMode.allCases) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 260)
            .accessibilityLabel("正文字号")
            .accessibilityIdentifier("settings.general.font.mode")

            if selectedFontMode == .custom {
                HStack(spacing: 5) {
                    TextField(
                        "自定义",
                        value: $customFontSize,
                        format: .number
                    )
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .multilineTextAlignment(.trailing)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 6)
                    .frame(width: 56)
                    .background(Theme.fill)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.button))
                    .overlay(RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.separator))
                    .accessibilityLabel("自定义")
                    .accessibilityValue("\(customFontSize) px")
                    .accessibilityIdentifier("settings.general.font.custom.value")
                    .onChange(of: customFontSize) { newValue in
                        let points = ConversationFontSizeMode.normalized(newValue)
                        if customFontSize != points { customFontSize = points }
                        Task {
                            await model.setConversationFontSize(
                                points == ConversationFontSizeMode.defaultPoints ? nil : points
                            )
                        }
                    }
                    Text("px")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.mutedForeground)
                }
                .transition(.opacity)
            }
        }
    }
}
