// WebsiteRulesSettings.swift
// VocaMac

import SwiftUI

struct WebsiteRulesSettings: View {
    @EnvironmentObject var appState: AppState
    @State private var editing: WebsiteStyleBinding?
    @State private var isAdding = false

    var body: some View {
        VocaSettingsGroup("Website Rules") {
            Text("Override a browser's app rule for a domain. VocaMac reads the focused tab URL through Accessibility; URLs are never saved to history.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if appState.websiteStyleBindings.isEmpty {
                Text("No website rules yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.websiteStyleBindings) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(rule.displayName)
                            Text(rule.hostPattern).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(rule.style.displayName).font(.caption).foregroundStyle(.secondary)
                        Toggle("", isOn: Binding(
                            get: { rule.isEnabled },
                            set: { enabled in update(rule) { $0.isEnabled = enabled } }
                        ))
                        .labelsHidden().controlSize(.mini)
                        Button { editing = rule } label: { Image(systemName: "slider.horizontal.3") }
                            .buttonStyle(.borderless)
                        Button(role: .destructive) {
                            appState.websiteStyleBindings.removeAll { $0.id == rule.id }
                        } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.borderless)
                    }
                    if rule.id != appState.websiteStyleBindings.last?.id { Divider() }
                }
            }

            Button("Add Website Rule…") { isAdding = true }
        }
        .sheet(isPresented: $isAdding) {
            WebsiteRuleEditor(rule: WebsiteStyleBinding(
                hostPattern: "", displayName: "Website", style: appState.writingStyleDefault
            )) { rule in
                var rules = appState.websiteStyleBindings
                rules.append(rule)
                appState.websiteStyleBindings = rules
                isAdding = false
            } onCancel: { isAdding = false }
        }
        .sheet(item: $editing) { rule in
            WebsiteRuleEditor(rule: rule) { updated in
                update(rule) { $0 = updated }
                editing = nil
            } onCancel: { editing = nil }
        }
    }

    private func update(_ rule: WebsiteStyleBinding, mutate: (inout WebsiteStyleBinding) -> Void) {
        var rules = appState.websiteStyleBindings
        guard let index = rules.firstIndex(where: { $0.id == rule.id }) else { return }
        mutate(&rules[index])
        appState.websiteStyleBindings = rules
    }
}

private struct WebsiteRuleEditor: View {
    let rule: WebsiteStyleBinding
    let onSave: (WebsiteStyleBinding) -> Void
    let onCancel: () -> Void

    @State private var draft: WebsiteStyleBinding

    init(
        rule: WebsiteStyleBinding,
        onSave: @escaping (WebsiteStyleBinding) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.rule = rule
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: rule)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(rule.hostPattern.isEmpty ? "Add Website Rule" : "Edit Website Rule")
                .font(.headline).padding()
            Form {
                TextField("Name", text: $draft.displayName)
                TextField("Domain", text: $draft.hostPattern, prompt: Text("example.com or *.example.com"))
                Picker("Format", selection: $draft.style) {
                    ForEach(WritingStyle.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Wording", selection: $draft.intent) {
                    ForEach(WritingIntent.allCases) { Text($0.displayName).tag($0) }
                }
                .disabled(!draft.style.supportsWording)
                Picker("Processing", selection: $draft.cleanup) {
                    ForEach(WritingCleanupPolicy.allCases) { Text($0.displayName).tag($0) }
                }
                Picker("Cleanup level", selection: $draft.cleanupLevel) {
                    Text("Use global setting").tag(Optional<CleanupLevel>.none)
                    ForEach(CleanupLevel.allCases) { Text($0.displayName).tag(Optional($0)) }
                }
                TextEditor(text: Binding(
                    get: { draft.cleanupPrompt ?? "" },
                    set: { draft.cleanupPrompt = $0.isEmpty ? nil : $0 }
                ))
                .frame(minHeight: 80)
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(normalizedDraft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(normalizedHost.isEmpty)
            }
            .padding()
        }
        .frame(width: 480, height: 500)
    }

    private var normalizedHost: String {
        var value = draft.hostPattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let url = URL(string: value), let host = url.host { value = host }
        return value.trimmingCharacters(in: CharacterSet(charactersIn: "/."))
    }

    private var normalizedDraft: WebsiteStyleBinding {
        var value = draft
        value.hostPattern = normalizedHost
        if value.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            value.displayName = normalizedHost
        }
        return value
    }
}
