// ModelPickerComponents.swift
// VocaMac
//
// Pieces of the language-led speech model picker: the spoken-language bar,
// the search and filter row, and the badges each model row shows.

import SwiftUI

// MARK: - Spoken Languages

/// The languages the user dictates in, as removable chips with an add button.
struct SpokenLanguagesCard: View {
    @Binding var languages: [String]
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Languages You Speak")
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Text(languages.isEmpty
                     ? "Add the languages you dictate in to see which models understand them. Showing every model."
                     : "Models are matched to these languages, best fit first.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            FlowLayout(spacing: 6) {
                ForEach(languages, id: \.self) { code in
                    SpokenLanguageChip(name: SpokenLanguages.displayName(for: code)) {
                        languages.removeAll { $0 == code }
                    }
                }

                Button {
                    isAdding = true
                } label: {
                    Label(languages.isEmpty ? "Add Language" : "Add", systemImage: "plus")
                        .font(.callout)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .overlay(Capsule().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                        .foregroundStyle(.secondary)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("Add a language you speak")
                .popover(isPresented: $isAdding, arrowEdge: .bottom) {
                    SpokenLanguagePicker(chosen: languages) { code in
                        languages.append(code)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
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
                .textFieldStyle(.roundedBorder)
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
                                    .foregroundStyle(.tertiary)
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

    private func addFirstMatch() {
        guard let first = candidates.first else { return }
        add(first.code)
    }
}

// MARK: - Filter Row

/// Free-text search over the catalog plus a translation filter.
struct ModelFilterBar: View {
    @Binding var search: String
    @Binding var translationOnly: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search models, makers, or languages", text: $search)
                    .textFieldStyle(.plain)
                if !search.isEmpty {
                    Button {
                        search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(VocaDesign.line))

            Toggle(isOn: $translationOnly) {
                Label("Translates to English", systemImage: "character.bubble")
            }
            .toggleStyle(.button)
            .help("Show only models that can translate your speech into English")
        }
    }
}

// MARK: - Row Badges

/// Which languages a model covers, with the full list on hover.
struct ModelLanguageBadge: View {
    let size: ModelSize
    let systemLanguages: Set<String>?

    private var codes: [String]? {
        ModelPickerCatalog.languageCodes(for: size, systemLanguages: systemLanguages)
            .map { $0.map(SpokenLanguages.displayName(for:)).sorted() }
    }

    private var label: String {
        guard let codes else { return "99 languages" }
        return codes.count == 1 ? codes[0] : "\(codes.count) languages"
    }

    private var tooltip: String {
        guard let codes else {
            return "Whisper understands 99 languages, including every language VocaMac lists."
        }
        let names = codes.joined(separator: ", ")
        return size.languageCoverage == .system
            ? "macOS supports these languages on this Mac: \(names)"
            : names
    }

    var body: some View {
        ModelTag(text: label, systemImage: "globe")
            .help(tooltip)
    }
}

/// A small capsule label in a model row.
struct ModelTag: View {
    let text: String
    var systemImage: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption2)
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 1)
        .background(tint.opacity(0.12), in: Capsule())
        .foregroundStyle(tint)
    }
}

/// A labelled horizontal meter for accuracy or speed.
struct ModelScoreBar: View {
    let title: String
    /// 0–1
    let value: Double
    let accessibilityValue: String

    var body: some View {
        HStack(spacing: 4) {
            Text(title)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(VocaDesign.accent)
                    .frame(width: 36 * min(max(value, 0), 1))
            }
            .frame(width: 36, height: 4)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}
