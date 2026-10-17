// SpokenLanguageComponents.swift
// VocaMac
//
// The spoken-languages field onboarding uses: removable chips, an add
// button, and the searchable language list it opens.

import SwiftUI

/// Spoken languages as removable chips with an add button.
struct SpokenLanguagesField: View {
    @Binding var languages: [String]
    @State private var isAdding = false

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(languages, id: \.self) { code in
                SpokenLanguageChip(name: SpokenLanguages.displayName(for: code)) {
                    languages.removeAll { $0 == code }
                }
            }

            Button {
                isAdding = true
            } label: {
                Label(languages.isEmpty ? "Add Your Languages" : "Add", systemImage: "plus")
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                    .foregroundStyle(.secondary)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Add a language you dictate in")
            .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                SpokenLanguagePicker(chosen: languages) { code in
                    languages.append(code)
                }
            }
        }
    }
}

/// One spoken language, removable.
struct SpokenLanguageChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(VocaDesign.accent.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help("Remove \(name)")
            .accessibilityLabel("Remove \(name)")
        }
        .font(.callout)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(VocaDesign.accent.opacity(0.12), in: Capsule())
        .foregroundStyle(VocaDesign.accent)
    }
}

/// Searchable list of languages to add. Stays open so several can be added
/// in a row; Return adds the first match.
struct SpokenLanguagePicker: View {
    let chosen: [String]
    let onAdd: (String) -> Void
    @State private var search = ""
    @FocusState private var isSearchFocused: Bool

    private var candidates: [TranscriptionLanguage] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return TranscriptionLanguage.selectable.filter { language in
            !chosen.contains(language.code)
                && (needle.isEmpty
                    || language.displayName.lowercased().contains(needle)
                    || language.code == needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search languages", text: $search)
                .textFieldStyle(.voca)
                .focused($isSearchFocused)
                .onSubmit(addFirstMatch)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(candidates) { language in
                        Button {
                            add(language.code)
                        } label: {
                            HStack {
                                Text(language.displayName)
                                Spacer()
                                Text(language.code)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(VocaDisclosureHeaderButtonStyle())
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                }
            }

            if candidates.isEmpty {
                Text("No matching languages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
        .frame(width: 260, height: 300)
        .onAppear { isSearchFocused = true }
    }

    private func add(_ code: String) {
        onAdd(code)
        search = ""
    }

    /// Return adds the top match, but only for a search: with the box
    /// empty the top row is just the alphabet's first language.
    private func addFirstMatch() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = candidates.first else { return }
        add(first.code)
    }
}
