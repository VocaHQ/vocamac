// ModelPickerComponents.swift
// VocaMac
//
// Pieces of the language-led speech model picker: the header with the
// spoken languages and the model in use, the search field, and the labels
// and ratings each model row shows.

import SwiftUI

// MARK: - Header

/// The top of the picker: what the user speaks, and what dictation uses now.
/// One card, so the catalog below reads as the only list of choices.
struct ModelPickerHeader: View {
    @Binding var languages: [String]
    let current: WhisperModelInfo?
    let systemLanguages: Set<String>?
    let onShowSuggestions: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ModelPickerHeaderRow(title: "I speak") {
                SpokenLanguagesField(languages: $languages)
            }
            if let current {
                Divider()
                ModelPickerHeaderRow(title: current.isLoading ? "Loading" : "Using") {
                    CurrentModelSummary(
                        model: current,
                        spokenLanguages: languages,
                        systemLanguages: systemLanguages,
                        onShowSuggestions: onShowSuggestions
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
    }
}

/// A header row: a fixed-width label, then its content.
struct ModelPickerHeaderRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

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

/// One line naming the current model, with a warning when it misses a
/// language the user speaks.
struct CurrentModelSummary: View {
    let model: WhisperModelInfo
    let spokenLanguages: [String]
    let systemLanguages: Set<String>?
    let onShowSuggestions: () -> Void

    private var missing: [String] {
        ModelPickerCatalog.fit(of: model.size, for: spokenLanguages, systemLanguages: systemLanguages).missing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(model.size.displayName)
                .font(.callout.weight(.medium))
            if model.isLoading {
                Text(model.loadingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if missing.isEmpty {
                Text(ModelLanguageBadge.label(for: model.size, systemLanguages: systemLanguages))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Label("Doesn't understand \(SpokenLanguages.list(missing))",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button("Find a Better Fit", action: onShowSuggestions)
                    .buttonStyle(.link)
                    .font(.caption)
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

    /// Return adds the top match, but only for a search: with the box
    /// empty the top row is just the alphabet's first language.
    private func addFirstMatch() {
        guard !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first = candidates.first else { return }
        add(first.code)
    }
}

// MARK: - Search

/// Free-text search over the catalog.
struct ModelSearchField: View {
    @Binding var search: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search models or languages", text: $search)
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
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(VocaDesign.line))
    }
}

// MARK: - Row Badges

/// How a model's language coverage is described.
enum ModelLanguageBadge {

    private static func names(for size: ModelSize, systemLanguages: Set<String>?) -> [String]? {
        ModelPickerCatalog.languageCodes(for: size, systemLanguages: systemLanguages)
            .map { $0.map(SpokenLanguages.displayName(for:)).sorted() }
    }

    /// "English only", "25 languages", or "99 languages".
    static func label(for size: ModelSize, systemLanguages: Set<String>?) -> String {
        guard let names = names(for: size, systemLanguages: systemLanguages) else { return "99 languages" }
        return names.count == 1 ? "\(names[0]) only" : "\(names.count) languages"
    }

    /// The full language list, for hover help.
    static func tooltip(for size: ModelSize, systemLanguages: Set<String>?) -> String {
        guard let names = names(for: size, systemLanguages: systemLanguages) else {
            return "Understands 99 languages, including every language VocaMac lists."
        }
        let list = names.joined(separator: ", ")
        return size.languageCoverage == .system ? "macOS supports: \(list)" : "Understands: \(list)"
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

/// A labelled five-dot rating for accuracy or speed, in half-dot steps.
struct ModelRating: View {
    let title: String
    /// 0–1
    let value: Double
    let accessibilityValue: String

    /// Filled dots, rounded to the nearest half.
    private var filled: Double {
        (min(max(value, 0), 1) * 10).rounded() / 2
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
            HStack(spacing: 2) {
                ForEach(0..<5, id: \.self) { index in
                    dot(fill: min(max(filled - Double(index), 0), 1))
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    private func dot(fill: Double) -> some View {
        Circle()
            .fill(Color.primary.opacity(0.15))
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    Rectangle()
                        .fill(VocaDesign.accent)
                        .frame(width: proxy.size.width * fill)
                }
                .clipShape(Circle())
            }
            .frame(width: 6, height: 6)
    }
}
