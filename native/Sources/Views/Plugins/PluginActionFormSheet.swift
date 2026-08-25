import SwiftUI

struct PluginActionFormSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appLanguage) private var appLanguage

    let pluginID: String
    let action: PluginActionViewState
    @State private var draft: PluginFormDraft
    @State private var validationError: PluginFormDraft.ValidationError?
    @State private var submitting = false

    init(
        pluginID: String,
        action: PluginActionViewState,
        initialValues: [String: PluginJSONValue]
    ) {
        self.pluginID = pluginID
        self.action = action
        _draft = State(initialValue: PluginFormDraft(
            action: action.action,
            initialValues: initialValues
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(action.label)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.mutedForeground)
                .accessibilityLabel("关闭")
            }
            .padding(.horizontal, 18)
            .frame(height: 52)

            Divider().overlay(Theme.separator)

            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    if draft.fields.isEmpty {
                        Text("此操作没有可填写的字段。")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.mutedForeground)
                    }
                    ForEach(draft.fields) { field in
                        fieldRow(field)
                    }
                    if let validationError {
                        Label(
                            appLanguage.localized(validationError.localizedDescription),
                            systemImage: "exclamationmark.circle"
                        )
                            .font(.ccCaption())
                            .foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("plugin.form.error")
                    }
                }
                .padding(20)
            }

            Divider().overlay(Theme.separator)

            HStack(spacing: 8) {
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(CompactActionButtonStyle())
                Button {
                    submit()
                } label: {
                    HStack(spacing: 6) {
                        if submitting { ProgressView().controlSize(.small) }
                        Text(action.hasCustomSubmitLabel
                             ? action.submitLabel
                             : appLanguage.localized(action.submitLabel))
                    }
                }
                .buttonStyle(CompactActionButtonStyle(primary: true))
                .disabled(submitting)
                .accessibilityIdentifier("plugin.form.submit")
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
        }
        .frame(width: 460)
        .frame(minHeight: 260, maxHeight: 620)
        .background(Theme.surface)
        .pluginAccessibilityContainerIdentifier(
            "plugin.form.\(pluginID).\(action.id)",
            label: action.label
        )
    }

    private func fieldRow(_ field: PluginFormField) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 3) {
                Text(field.label)
                if field.required { Text("*").foregroundStyle(Theme.danger) }
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.mutedForeground)

            fieldControl(field)
                .overlay {
                    if validationError?.key == field.key {
                        RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.danger, lineWidth: 1)
                    }
                }

            if let help = field.help {
                Text(help)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pluginAccessibilityContainerIdentifier(
            "plugin.form.field.\(field.key)",
            label: field.label
        )
    }

    @ViewBuilder
    private func fieldControl(_ field: PluginFormField) -> some View {
        switch field.kind {
        case .checkbox:
            Toggle("", isOn: checkedBinding(field.key))
                .labelsHidden()
                .toggleStyle(.checkbox)
        case .select:
            Picker("", selection: selectionBinding(field.key)) {
                ForEach(field.options) { option in
                    Text(option.label).tag(Optional(option.index))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        case .textarea:
            TextEditor(text: textBinding(field.key))
                .font(.system(size: 12.5, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 82)
                .background(Theme.fill)
                .clipShape(RoundedRectangle(cornerRadius: Radius.button))
                .overlay(RoundedRectangle(cornerRadius: Radius.button).stroke(Theme.separator))
        case .password:
            SecureField(field.placeholder, text: textBinding(field.key))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5))
        case .number, .text:
            TextField(field.placeholder, text: textBinding(field.key))
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12.5, design: .monospaced))
        }
    }

    private func textBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { draft.text(for: key) },
            set: {
                draft.setText($0, for: key)
                if validationError?.key == key { validationError = nil }
            }
        )
    }

    private func checkedBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { draft.isChecked(key) },
            set: { draft.setChecked($0, for: key) }
        )
    }

    private func selectionBinding(_ key: String) -> Binding<Int?> {
        Binding(
            get: { draft.selection(for: key) },
            set: {
                draft.setSelection($0, for: key)
                if validationError?.key == key { validationError = nil }
            }
        )
    }

    private func submit() {
        let values: [String: PluginJSONValue]
        do {
            values = try draft.collectedValues()
            validationError = nil
        } catch let error as PluginFormDraft.ValidationError {
            validationError = error
            return
        } catch {
            return
        }

        submitting = true
        Task {
            let response = await model.submitPluginAction(
                pluginID: pluginID,
                actionID: action.id,
                values: values
            )
            submitting = false
            if response?.succeeded == true { dismiss() }
        }
    }
}
