// WebsiteRulesSettings.swift
// VocaMac

import SwiftUI

struct WebsiteRulesSettings: View {
    @EnvironmentObject var appState: AppState
    @State private var editing: WebsiteStyleBinding?
    @State private var isAdding = false

    var body: some View {
        VocaSettingsGroup("Websites", subtitle: "Use a different style on one site in your browser.") {
            if appState.websiteStyleBindings.isEmpty {
                Text("No websites set up yet.")
                    .foregroundStyle(.secondary)
                    .help("VocaMac reads the focused tab's URL through Accessibility. URLs are never saved to history.")
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

            Button("Add Website…") { isAdding = true }
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
            .environmentObject(appState)
        }
        .sheet(item: $editing) { rule in
            WebsiteRuleEditor(rule: rule) { updated in
                update(rule) { $0 = updated }
                editing = nil
            } onCancel: { editing = nil }
            .environmentObject(appState)
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
    @State private var showsAdvanced: Bool

    init(
        rule: WebsiteStyleBinding,
        onSave: @escaping (WebsiteStyleBinding) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.rule = rule
        self.onSave = onSave
        self.onCancel = onCancel
        _draft = State(initialValue: rule)
        _showsAdvanced = State(initialValue: rule.cleanup != .inherit
            || rule.cleanupLevel != nil
            || rule.cleanupPrompt != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(rule.hostPattern.isEmpty ? "Add Website" : "Edit Website")
                .font(.headline).padding()
            Form {
                Section {
                    TextField("Name", text: $draft.displayName)
                    TextField("Domain", text: $draft.hostPattern, prompt: Text("example.com or *.example.com"))
                    Text("A domain also matches its subdomains: example.com covers mail.example.com.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section {
                    Picker("Style", selection: $draft.style) {
                        ForEach(WritingStyle.allCases) { Text($0.displayName).tag($0) }
                    }
                    WritingStyleExample(style: draft.style)
                    Picker("Tone", selection: $draft.intent) {
                        ForEach(WritingIntent.allCases) { Text($0.displayName).tag($0) }
                    }
                    .disabled(!draft.style.supportsWording)
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showsAdvanced) {
                        Picker("AI cleanup", selection: $draft.cleanup) {
                            ForEach(WritingCleanupPolicy.allCases) { Text($0.displayName).tag($0) }
                        }
                        Picker("Cleanup level", selection: $draft.cleanupLevel) {
                            Text("Same as Cleanup page").tag(Optional<CleanupLevel>.none)
                            ForEach(CleanupLevel.allCases) { Text($0.displayName).tag(Optional($0)) }
                        }
                        .disabled(draft.cleanup != .inherit)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom cleanup instructions")
                            TextEditor(text: Binding(
                                get: { draft.cleanupPrompt ?? "" },
                                set: { draft.cleanupPrompt = $0.isEmpty ? nil : $0 }
                            ))
                            .font(.system(.caption, design: .monospaced))
                            .frame(minHeight: 70)
                            Text("Leave blank to use the instructions from the Cleanup page. Applies only on this website.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
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
        .frame(width: 480, height: 560)
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
