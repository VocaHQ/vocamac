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
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("I speak")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

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

// MARK: - Current Model

/// The model dictation uses right now, apart from the catalog, so the list
/// below reads as choices rather than a mix of choices and state.
struct CurrentModelCard: View {
    let model: WhisperModelInfo
    let spokenLanguages: [String]
    let systemLanguages: Set<String>?
    let onShowSuggestions: () -> Void

    private var missing: [String] {
        ModelPickerCatalog.fit(of: model.size, for: spokenLanguages, systemLanguages: systemLanguages).missing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ModelCreatorMark(creator: model.size.creator, size: 32, isActive: model.isActive)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isActive ? "In use" : "Switching to")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(VocaDesign.accent)
                Text(model.size.displayName)
                    .font(.headline)
                if missing.isEmpty {
                    Text(ModelLanguageBadge.label(for: model.size, systemLanguages: systemLanguages)
                         + " · " + model.size.pickerSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("Doesn't understand \(SpokenLanguages.list(missing)). Pick a model from For You.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            } else if !missing.isEmpty {
                Button("See Models", action: onShowSuggestions)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .vocaCard()
    }
}

// MARK: - Row Badges

/// How a model's language coverage is described.
enum ModelLanguageBadge {

    private static func names(for size: ModelSize, systemLanguages: Set<String>?) -> [String]? {
        ModelPickerCatalog.languageCodes(for: size, systemLanguages: systemLanguages)
            .map { $0.map(SpokenLanguages.displayName(for:)).sorted() }
    }

    /// "English", "25 languages", or "99 languages".
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

/// A labelled horizontal meter for accuracy or speed.
struct ModelScoreBar: View {
    let title: String
    /// 0–1
    let value: Double
    let accessibilityValue: String

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .frame(width: 50, alignment: .leading)
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
