import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    @EnvironmentObject private var model: AppModel
    @State private var draft: Provider
    @State private var selectedPreset: String?
    @State private var presetQuery = ""
    @State private var showsToken = false
    @State private var mappingsExpanded = true
    @State private var iconPickerPresented = false
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testSucceeded = false

    let onSave: (Provider) -> Void

    init(provider: Provider?, onSave: @escaping (Provider) -> Void) {
        var value = provider ?? Provider()
        if value.models.isEmpty { value.models = [.init(alias: "", upstream: "")] }
        _draft = State(initialValue: value)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Theme.separator).frame(height: 1)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 17) {
                    presets
                    iconEditor
                    identityFields
                    protocolField
                    tokenField
                    modelFields
                    Toggle("自动映射 Claude / Codex 默认模型", isOn: $draft.mapDefaultModels)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .font(.system(size: 12.5))
                    mappings
                    if let testMessage {
                        Label(
                            appLanguage.localized(testMessage),
                            systemImage: testSucceeded ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(testSucceeded ? Theme.success : Theme.danger)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(testSucceeded ? Theme.successSoft : Theme.dangerSoft)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 18)
            }
            Rectangle().fill(Theme.separator).frame(height: 1)
            footer
        }
        .frame(
            width: ProviderEditorLayout.sheetSize.width,
            height: ProviderEditorLayout.sheetSize.height
        )
        .background(Theme.surface)
        .overlay(alignment: .topLeading) {
            Rectangle()
                .fill(Color.clear)
                .frame(width: 1, height: 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(appLanguage.localized(draft.name.isEmpty ? "添加服务" : "编辑服务"))
                .accessibilityIdentifier("provider.editor")
                .allowsHitTesting(false)
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10.5, weight: .bold))
                    .frame(width: 26, height: 26)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator))
            }
            .buttonStyle(.plain)
            Text(appLanguage.localized(draft.name.isEmpty ? "添加服务" : "编辑服务"))
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Text("Bifrost")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.mutedForeground)
        }
        .padding(.horizontal, 18)
        .frame(height: 55)
    }

    /// A searchable, grouped picker rather than a wall of chips.
    ///
    /// The catalog grew from ten entries to seventy when it was ported from cc-switch, and seventy
    /// capsules would fill the sheet before the fields it is meant to prefill. Typing narrows by
    /// name, host or model id, which is how people actually look for a provider.
    private var presets: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            HStack(spacing: Space.sm) {
                fieldLabel("预设")
                Spacer(minLength: 0)
                HStack(spacing: Space.xs + 2) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: Typography.label))
                        .foregroundStyle(Theme.mutedForeground)
                    TextField(
                        appLanguage.localized("搜索服务商…"),
                        text: $presetQuery
                    )
                    .textFieldStyle(.plain)
                    .font(.ccCaption())
                    .accessibilityIdentifier("provider.preset.search")
                }
                .padding(.horizontal, Space.sm)
                .frame(width: 180, height: Metrics.controlHeight - 2)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            }

            let groups = ProviderPreset.grouped(matching: presetQuery)
            if groups.isEmpty {
                Text(appLanguage.localized("没有匹配的预设，直接在下方填写即可"))
                    .font(.ccCaption())
                    .foregroundStyle(Theme.mutedForeground)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Space.sm)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.md) {
                        ForEach(groups, id: \.category.id) { group in
                            VStack(alignment: .leading, spacing: Space.xs + 2) {
                                Text(appLanguage.localized(group.category.title))
                                    .font(.ccLabel())
                                    .foregroundStyle(Theme.mutedForeground)
                                ProviderPresetFlowLayout {
                                    ForEach(group.presets) { preset in
                                        presetChip(preset)
                                    }
                                }
                            }
                        }
                    }
                    .padding(Space.sm)
                }
                // A bounded region with its own material reads as a list you scroll inside, rather
                // than as page content that happens to be clipped.
                .frame(height: 138)
                .background(Theme.fillSubtle)
                .clipShape(RoundedRectangle(cornerRadius: Radius.row, style: .continuous))
            }
        }
    }

    private func presetChip(_ preset: ProviderPreset) -> some View {
        Button(preset.category == .custom
            ? appLanguage.localized("自定义")
            : preset.name) {
            selectedPreset = preset.id
            preset.apply(to: &draft)
            testMessage = nil
        }
        .buttonStyle(ProviderPresetButtonStyle(selected: selectedPreset == preset.id))
        .help(preset.baseURL.isEmpty ? preset.name : preset.baseURL)
    }

    private var iconEditor: some View {
        VStack(spacing: 5) {
            Button { iconPickerPresented.toggle() } label: {
                ProviderIconView(name: draft.name.isEmpty ? "?" : draft.name, icon: draft.icon, size: 52)
                    .overlay(RoundedRectangle(cornerRadius: 13).stroke(Theme.accentText.opacity(0.2)))
            }
            .buttonStyle(.plain)
            .popover(isPresented: $iconPickerPresented, arrowEdge: .bottom) {
                iconPicker
            }
            Text("点击自定义图标")
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.mutedForeground)
        }
        .frame(maxWidth: .infinity)
    }

    private var iconPicker: some View {
        VStack(spacing: 10) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(29), spacing: 4), count: 8), spacing: 4) {
                ForEach(Array(ProviderIconView.emojis.enumerated()), id: \.offset) { _, emoji in
                    Button(emoji) {
                        draft.icon = emoji
                        iconPickerPresented = false
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 18))
                    .frame(width: 29, height: 29)
                    .background(Theme.fill)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            HStack(spacing: 7) {
                Button("上传图片", action: chooseIcon)
                Button("随机") {
                    draft.icon = ProviderIconView.emojis.randomElement()
                    iconPickerPresented = false
                }
                Button("重置") {
                    draft.icon = nil
                    iconPickerPresented = false
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(12)
        .frame(width: 285)
    }

    private var identityFields: some View {
        HStack(alignment: .top, spacing: 11) {
            editorField("名称") { TextField("GLM", text: $draft.name) }
            editorField("API 地址") {
                TextField(ProviderEditorLayout.apiURLPlaceholder, text: $draft.baseUrl)
            }
        }
    }

    private var protocolField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                fieldLabel("上游协议")
                Text(appLanguage.localized(draft.protocol == .anthropic ? "直通" : "自动转换"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(draft.protocol == .anthropic ? Theme.mutedForeground : Theme.accentText)
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(draft.protocol == .anthropic ? Theme.foreground.opacity(0.05) : Theme.accentSoft)
                    .clipShape(Capsule())
            }
            Picker("上游协议", selection: $draft.protocol) {
                Text("Anthropic Messages").tag(Provider.WireProtocol.anthropic)
                Text("OpenAI Chat").tag(Provider.WireProtocol.openAIChat)
                Text("OpenAI Responses").tag(Provider.WireProtocol.openAIResponses)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
        }
    }

    private var tokenField: some View {
        editorField("API Key") {
            HStack(spacing: 7) {
                Group {
                    if showsToken { TextField("粘贴密钥", text: $draft.authToken) }
                    else { SecureField("粘贴密钥", text: $draft.authToken) }
                }
                .textContentType(.password)
                Button(appLanguage.localized(showsToken ? "隐藏" : "显示")) { showsToken.toggle() }
                    .buttonStyle(CompactActionButtonStyle())
            }
        }
    }

    private var modelFields: some View {
        HStack(alignment: .top, spacing: 11) {
            editorField("主模型") { TextField("glm-5.2", text: $draft.defaultModel) }
            editorField("轻量模型") { TextField("glm-5.2-air", text: $draft.smallFastModel) }
        }
    }

    private var mappings: some View {
        DisclosureGroup(isExpanded: $mappingsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("把客户端模型名精确映射到上游模型；未命中时才使用自动映射。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.mutedForeground)
                ForEach(Array(draft.models.indices), id: \.self) { index in
                    HStack(spacing: 7) {
                        TextField("客户端别名", text: mappingBinding(index, \.alias))
                            .providerEditorTextField()
                        Text("→").foregroundStyle(Theme.mutedForeground)
                        TextField("上游模型", text: mappingBinding(index, \.upstream))
                            .providerEditorTextField()
                        Button {
                            draft.models.remove(at: index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .bold))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.mutedForeground)
                    }
                }
                Button("+ 添加映射") { draft.models.append(.init(alias: "", upstream: "")) }
                    .buttonStyle(CompactActionButtonStyle())
            }
            .padding(.top, 10)
        } label: {
            Text("自定义模型别名（别名 ⇄ 上游模型）")
                .font(.system(size: 12.5, weight: .medium))
        }
        .padding(12)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator))
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button(action: runProbe) {
                if testing {
                    HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("测试中…") }
                } else { Text("连接测试") }
            }
            .buttonStyle(CompactActionButtonStyle())
            .disabled(testing)
            Spacer()
            Button("取消") { dismiss() }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
                .keyboardShortcut(.cancelAction)
            Button("保存") {
                var value = draft
                value.models = value.models.filter {
                    !$0.alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !$0.upstream.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                onSave(value)
                dismiss()
            }
            .buttonStyle(CompactActionButtonStyle(primary: true))
            .keyboardShortcut(.defaultAction)
            .disabled(!isValid || testing)
        }
        .padding(.horizontal, 14)
        .frame(height: 54)
    }

    private func editorField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            fieldLabel(title)
            content().providerEditorTextField()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(appLanguage.localized(title).uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.35)
            .foregroundStyle(Theme.mutedForeground)
    }

    private func mappingBinding(
        _ index: Int,
        _ keyPath: WritableKeyPath<ModelMapping, String>
    ) -> Binding<String> {
        Binding(
            get: { draft.models.indices.contains(index) ? draft.models[index][keyPath: keyPath] : "" },
            set: { if draft.models.indices.contains(index) { draft.models[index][keyPath: keyPath] = $0 } }
        )
    }

    private var isValid: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && ["http", "https"].contains(URLComponents(string: draft.baseUrl)?.scheme?.lowercased() ?? "")
    }

    private func runProbe() {
        testing = true
        testMessage = nil
        Task {
            let result = await ProviderProbeService().test(
                draft,
                insecureSkipVerify: model.config.insecureSkipVerify
            )
            await MainActor.run {
                testing = false
                testSucceeded = result.succeeded
                if result.succeeded {
                    if let migrated = result.migratedBaseURL { draft.baseUrl = migrated }
                    testMessage = "连接成功 · \(result.model ?? draft.defaultModel)"
                } else {
                    switch result.reason {
                    case .baseURLEmpty: testMessage = "请填写 API 地址"
                    case .baseURLInvalid: testMessage = "API 地址必须是有效的 HTTP(S) URL"
                    case .timeout: testMessage = "连接超时"
                    case nil:
                        testMessage = result.message.map { "连接测试失败：\($0)" }
                            ?? "连接测试失败"
                    }
                }
            }
        }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = ["png", "jpg", "jpeg", "gif", "webp", "tiff", "svg"]
            .compactMap { UTType(filenameExtension: $0) }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                if let encoded = try? ProviderIconEncoder.dataURL(from: url) {
                    draft.icon = encoded
                    iconPickerPresented = false
                }
            }
        }
    }
}

private struct ProviderPresetButtonStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.ccCaption(.medium))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? Theme.accentText : Theme.foreground)
            .padding(.horizontal, Space.sm + 2)
            .frame(minHeight: 26)
            .background(selected ? Theme.accentSoft : Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.button, style: .continuous)
                    .strokeBorder(selected ? Theme.accent.opacity(0.5) : Color.clear, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}

private extension View {
    func providerEditorTextField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.ccMono(Typography.caption))
            .padding(.horizontal, Space.sm + 1)
            .frame(minHeight: 30)
            .background(Theme.fill)
            .clipShape(RoundedRectangle(cornerRadius: Radius.button, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.separator))
    }
}
