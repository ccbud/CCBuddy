import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProviderEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage
    @EnvironmentObject private var model: AppModel
    @State private var draft: Provider
    /// Which protocol's address the field under the segmented control is editing. The control
    /// picks what you are looking at, not what the provider "is" — a provider binds up to three.
    @State private var editingProtocol: Provider.WireProtocol
    /// The base URL the addresses currently offered were derived from, so correcting a typo in
    /// the base updates the addresses that came from it and leaves everything typed by hand.
    @State private var derivationBase: String
    @State private var selectedPreset: String?
    @State private var presetQuery = ""
    @State private var showsToken = false
    @State private var mappingsExpanded = true
    @State private var iconPickerPresented = false
    @State private var testing = false
    @State private var testMessage: String?
    @State private var testSucceeded = false
    @State private var discovering = false
    /// What the last probe of `/v1/models` found. `.unsupported` is what greys the refresh
    /// control out: the provider answered and said it has no listing endpoint, so offering to
    /// refresh again would only produce the same answer.
    @State private var modelCatalog = ProviderModelCatalog.unknown

    let onSave: (Provider) -> Void

    init(provider: Provider?, onSave: @escaping (Provider) -> Void) {
        var value = provider ?? Provider()
        if value.models.isEmpty { value.models = [.init(alias: "", upstream: "")] }
        // A provider saved before per-protocol addresses has exactly one upstream, implied by its
        // base URL. Writing it out means the field shows the address actually in use rather than
        // looking empty under a segment that reads as bound.
        let base = value.baseUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.protocolUrls.isEmpty, !base.isEmpty {
            value.protocolUrls[value.protocol.rawValue] = base
        }
        _draft = State(initialValue: value)
        _editingProtocol = State(initialValue: value.primaryProtocol)
        _derivationBase = State(initialValue: value.baseUrl)
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
        // A listing endpoint belongs to one address; pointing the provider somewhere else makes
        // the previous "this host has no /v1/models" answer meaningless, so the control comes
        // back enabled rather than staying greyed out against a host never probed.
        .onChange(of: draft.baseUrl) { newValue in
            modelCatalog = .unknown
            rederiveOfferedAddresses(to: newValue)
        }
        .onChange(of: editingProtocol) { _ in
            modelCatalog = .unknown
            testMessage = nil
        }
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
    /// Even at two dozen vendors, capsules for all of them would fill the sheet before the fields
    /// they are meant to prefill. Typing narrows by name, host, endpoint or model id, which is how
    /// people actually look for a provider.
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
            editingProtocol = draft.primaryProtocol
            derivationBase = draft.baseUrl
            testMessage = nil
            // Availability was measured against the previous address.
            modelCatalog = .unknown
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
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 11) {
                editorField("名称") { TextField("GLM", text: $draft.name) }
                editorField("API 地址") {
                    TextField(ProviderEditorLayout.apiURLPlaceholder, text: $draft.baseUrl)
                }
            }
            Text("只填服务商根地址，每个协议各自的地址在下面绑定。")
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedForeground)
        }
    }

    /// The three addresses one provider binds.
    ///
    /// The segmented control chooses which one the field below is editing, not what the provider
    /// "is": a vendor publishing Anthropic Messages, Chat Completions and Responses of its own
    /// gets all three filled in and every client reaches it untouched. Leave one blank and the
    /// clients that speak it are converted onto the address that is filled in — which is the
    /// whole point of doing it per address rather than per provider.
    private var protocolField: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                fieldLabel("上游协议")
                Text(appLanguage.localized(draft.servesEveryProtocolDirectly ? "全部直通" : "按需转换"))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(
                        draft.servesEveryProtocolDirectly ? Theme.mutedForeground : Theme.accentText
                    )
                    .padding(.horizontal, 7).padding(.vertical, 2)
                    .background(
                        draft.servesEveryProtocolDirectly
                            ? Theme.foreground.opacity(0.05) : Theme.accentSoft
                    )
                    .clipShape(Capsule())
            }
            Picker("上游协议", selection: $editingProtocol) {
                ForEach(Provider.WireProtocol.allCases) { wireProtocol in
                    Text(segmentTitle(wireProtocol)).tag(wireProtocol)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .accessibilityIdentifier("provider.editor.protocol")

            HStack(spacing: 7) {
                TextField(
                    derivedAddress ?? ProviderEditorLayout.apiURLPlaceholder,
                    text: editedProtocolURL
                )
                .providerEditorTextField()
                .accessibilityIdentifier("provider.editor.protocolURL")
                if let derivedAddress, derivedAddress != draft.upstreamURL(for: editingProtocol) {
                    Button(appLanguage.localized("默认地址")) {
                        draft.protocolUrls[editingProtocol.rawValue] = derivedAddress
                        keepPrimaryOnAConfiguredProtocol()
                    }
                    .buttonStyle(CompactActionButtonStyle())
                    .help(appLanguage.localized("按 API 地址填入该协议的常规地址"))
                    .accessibilityIdentifier("provider.editor.fillProtocolURL")
                }
            }

            Text(appLanguage.localized(routingSummary))
                .font(.system(size: 11))
                .foregroundStyle(Theme.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// A bound protocol is marked, so the three addresses are readable without clicking through.
    private func segmentTitle(_ wireProtocol: Provider.WireProtocol) -> String {
        let title: String
        switch wireProtocol {
        case .anthropic: title = "Anthropic Messages"
        case .openAIChat: title = "OpenAI Chat"
        case .openAIResponses: title = "OpenAI Responses"
        }
        return draft.upstreamURL(for: wireProtocol) == nil ? title : "● " + title
    }

    private var derivedAddress: String? {
        GatewayUpstreamURL.derivedURL(for: editingProtocol, base: draft.baseUrl)
    }

    /// Clearing the field unbinds the protocol, which is how a client speaking it comes to be
    /// converted; the raw text is kept while typing so a half-written address is not swallowed.
    private var editedProtocolURL: Binding<String> {
        Binding(
            get: { draft.protocolUrls[editingProtocol.rawValue] ?? "" },
            set: { value in
                if value.isEmpty {
                    draft.protocolUrls.removeValue(forKey: editingProtocol.rawValue)
                } else {
                    draft.protocolUrls[editingProtocol.rawValue] = value
                }
                keepPrimaryOnAConfiguredProtocol()
            }
        )
    }

    private var routingSummary: String {
        let bound = draft.configuredProtocols
        guard let primary = bound.first else {
            return "至少绑定一个协议的地址，网关才有上游可用。"
        }
        if bound.count == Provider.WireProtocol.allCases.count {
            return "三个协议都已绑定：每个客户端都走自己的地址，不做任何转换。"
        }
        return "未绑定的协议会转换后发往「\(primary.title)」。"
    }

    /// `protocol` names the address that also takes callers this provider publishes nothing for,
    /// so it has to keep naming one that is still bound.
    private func keepPrimaryOnAConfiguredProtocol() {
        guard let primary = draft.configuredProtocols.first else { return }
        if draft.protocol != primary { draft.protocol = primary }
    }

    /// Follows the base URL: re-offers the addresses that came from it, fills in the one on
    /// screen if it is still blank, and leaves everything typed by hand alone.
    ///
    /// Filling the selected protocol matters — without it, a provider whose address field was
    /// never touched would fall back to the bare base URL and the gateway would ask
    /// `https://api.deepseek.com/v1/messages`, an address DeepSeek does not serve, while the
    /// editor showed an empty field under a segment marked as bound.
    private func rederiveOfferedAddresses(to newBase: String) {
        defer { derivationBase = newBase }
        guard derivationBase != newBase else { return }
        for wireProtocol in Provider.WireProtocol.allCases {
            guard let previous = GatewayUpstreamURL.derivedURL(
                for: wireProtocol, base: derivationBase
            ), draft.protocolUrls[wireProtocol.rawValue] == previous else { continue }
            if let replacement = GatewayUpstreamURL.derivedURL(
                for: wireProtocol, base: newBase
            ) {
                draft.protocolUrls[wireProtocol.rawValue] = replacement
            } else {
                draft.protocolUrls.removeValue(forKey: wireProtocol.rawValue)
            }
        }
        if (draft.protocolUrls[editingProtocol.rawValue] ?? "").isEmpty,
           let offered = GatewayUpstreamURL.derivedURL(
            for: editingProtocol, base: newBase
           ) {
            draft.protocolUrls[editingProtocol.rawValue] = offered
        }
        keepPrimaryOnAConfiguredProtocol()
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

    /// Refreshes the mapping list from the provider's own `/v1/models`.
    ///
    /// The button is disabled while a probe is in flight, while the address is unusable, and —
    /// the point of tracking availability at all — once a probe has established that this
    /// provider has no listing endpoint, so the control reads as unavailable rather than broken.
    private var discoverModelsControl: some View {
        HStack(spacing: 7) {
            Button {
                runModelDiscovery()
            } label: {
                HStack(spacing: 5) {
                    if discovering {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    Text(appLanguage.localized("从接口获取模型"))
                }
            }
            .buttonStyle(CompactActionButtonStyle())
            .disabled(discovering || !isValid || modelCatalog.availability == .unsupported)
            .accessibilityIdentifier("provider.editor.discoverModels")
            .help(appLanguage.localized(
                modelCatalog.availability == .unsupported
                    ? "该服务未提供 /v1/models 接口"
                    : "调用 /v1/models 或 /models 并自动创建模型绑定"
            ))
            if let message = discoveryMessage {
                Text(appLanguage.localized(message) + discoveryCountSuffix)
                    .font(.system(size: 11))
                    .foregroundStyle(
                        modelCatalog.availability == .available
                            ? Theme.mutedForeground : Theme.danger
                    )
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var discoveryMessage: String? {
        switch modelCatalog.availability {
        case .unknown: return modelCatalog.message
        case .available: return "已发现模型"
        case .unsupported: return modelCatalog.message ?? "该服务未提供模型列表接口"
        }
    }

    /// The model count is a number, so it is appended rather than interpolated into a phrase
    /// that would then have to be translated once per locale.
    private var discoveryCountSuffix: String {
        modelCatalog.availability == .available ? " · \(modelCatalog.models.count)" : ""
    }

    private var mappings: some View {
        DisclosureGroup(isExpanded: $mappingsExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("把客户端模型名精确映射到上游模型；未命中时才使用自动映射。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.mutedForeground)
                discoverModelsControl
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

    /// Every bound address has to be usable, not just the one currently on screen: saving a
    /// provider whose second address is a typo would leave the gateway refusing to start.
    private var isValid: Bool {
        guard !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let addresses = draft.configuredUpstreamURLs
        guard !addresses.isEmpty else { return false }
        return addresses.values.allSatisfy { address in
            let components = URLComponents(
                string: address.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            return ["http", "https"].contains(components?.scheme?.lowercased() ?? "")
                && components?.host?.isEmpty == false
        }
    }

    /// Tests the address on screen rather than the provider as a whole: three bound addresses can
    /// fail independently, and a single verdict would hide which one.
    private func runProbe() {
        testing = true
        testMessage = nil
        let wireProtocol = editingProtocol
        Task {
            let result = await ProviderProbeService().test(
                draft,
                wireProtocol: wireProtocol,
                insecureSkipVerify: model.config.insecureSkipVerify
            )
            await MainActor.run {
                testing = false
                testSucceeded = result.succeeded
                if result.succeeded {
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

    /// Probes the provider's model listing and folds whatever it returns into the bindings.
    ///
    /// Discovered models are added as identity mappings — the caller-facing name and the upstream
    /// name are the same — because that is what a provider advertising its own catalog means.
    /// Rows the user wrote are never touched.
    private func runModelDiscovery() {
        discovering = true
        let provider = draft
        let wireProtocol = editingProtocol
        let insecure = model.config.insecureSkipVerify
        Task {
            let catalog = await ProviderModelDiscoveryService().discover(
                provider,
                wireProtocol: wireProtocol,
                insecureSkipVerify: insecure
            )
            await MainActor.run {
                discovering = false
                modelCatalog = catalog
                guard catalog.availability == .available else { return }
                draft.models = ProviderModelDiscoveryService.merging(
                    discovered: catalog.models,
                    into: draft.models
                )
                if draft.defaultModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   let first = catalog.models.first {
                    draft.defaultModel = first
                }
                mappingsExpanded = true
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
