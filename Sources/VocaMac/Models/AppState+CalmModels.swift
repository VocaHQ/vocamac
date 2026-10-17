// AppState+CalmModels.swift
// VocaMac
//
// What Settings › Models shows, worked out from the catalog: the three
// pick cards per tab, the names and one-line facts each model row shows,
// the families the All models list groups by, and what a pick has to ask
// before it starts. Pure where it can be, so it is tested without views.

import Foundation

// MARK: - Names and facts

/// The words Settings › Models uses for a model: a short name and a muted
/// variant (“Parakeet v3” “Multilingual”) instead of the catalog's
/// parenthesised display names, and one line of facts.
enum CalmModelText {
    /// The model's name without its variant.
    static func name(_ size: ModelSize) -> String {
        switch size {
        case .tiny: return "Whisper Tiny"
        case .base: return "Whisper Base"
        case .small: return "Whisper Small"
        case .medium: return "Whisper Medium"
        case .largeV3LatestTurboCompact, .largeV3LatestTurbo, .largeV3Turbo: return "Whisper Large v3 Turbo"
        case .largeV3LatestCompact, .largeV3Latest: return "Whisper Large v3 Latest"
        case .largeV3: return "Whisper Large v3"
        case .distilLargeV3Compact: return "Distil Whisper Large v3"
        case .distilLargeV3TurboCompact: return "Distil Whisper Large v3 Turbo"
        case .vocaHinglish: return "Voca Hinglish"
        case .parakeetUltra: return "Parakeet Ultra"
        case .parakeetV3: return "Parakeet v3"
        case .parakeetV2: return "Parakeet v2"
        case .parakeetUnified: return "Parakeet Unified"
        case .parakeetTdtCtc110m: return "Parakeet 110M"
        case .appleSpeech: return "Apple Speech"
        case .moonshineTiny: return "Moonshine v2 Tiny"
        case .moonshineBase: return "Moonshine v2 Base"
        case .senseVoiceSmall: return "SenseVoice"
        case .gigaamV3: return "GigaAM v3"
        case .canary180mFlash: return "Canary 180M"
        case .qwen3Asr06B: return "Qwen3 ASR 0.6B"
        case .customEndpoint: return "Custom endpoint"
        }
    }

    /// The muted word after the name, when two models would otherwise read the same.
    /// `isBundled`: whether this build ships the model (Tiny is bundled
    /// only in release builds; a dev build saying “Built in” next to
    /// “Not downloaded” contradicts itself).
    static func variant(_ size: ModelSize, isBundled: Bool = true) -> String? {
        switch size {
        case .tiny: return isBundled ? "Built in" : nil
        case .medium: return "Legacy"
        case .largeV3Latest, .largeV3LatestTurbo: return "Full precision"
        case .largeV3Turbo: return "Original"
        case .parakeetUltra, .parakeetV3: return "Multilingual"
        case .parakeetV2, .parakeetUnified, .parakeetTdtCtc110m, .moonshineTiny, .moonshineBase,
             .distilLargeV3Compact, .distilLargeV3TurboCompact:
            return "English"
        case .gigaamV3: return "Russian"
        case .vocaHinglish: return "Hindi + English"
        default: return nil
        }
    }

    /// A download size the way the design writes it: “483 MB”, “2.15 GB”, “1 GB”.
    static func size(bytes: Int64) -> String {
        let megabytes = Double(bytes) / 1_000_000
        if megabytes < 1000 { return "\(Int(megabytes.rounded())) MB" }
        return "\(trimmed(megabytes / 1000, decimals: 2)) GB"
    }

    /// A model's download size, or what stands in for one.
    static func downloadSize(_ size: ModelSize) -> String {
        if size.isRemotelyHosted { return "On your server" }
        if size.isSystemManaged { return "No download" }
        return self.size(bytes: size.fileSizeBytes)
    }

    /// “About 1 GB”, “About 0.9 GB”.
    static func memory(gb: Double) -> String {
        "About \(trimmed(gb, decimals: 1)) GB"
    }

    /// Up to `decimals` places, without trailing zeros (“1”, “2.15”, “0.9”).
    static func trimmed(_ value: Double, decimals: Int) -> String {
        var text = String(format: "%.\(decimals)f", value)
        guard text.contains(".") else { return text }
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The languages, short: “99 languages”, “25 European languages”,
    /// “English”, “English, French, German, Spanish”, “English, Chinese and 3 more”.
    static func languages(_ size: ModelSize, systemLanguages: Set<String>?) -> String {
        switch size.languageCoverage {
        case .broad: return size.isRemotelyHosted ? "Whisper-compatible" : "99 languages"
        case .system: return "Languages set by macOS"
        case .only(let codes):
            if codes == ModelSize.parakeetV3Languages { return "25 European languages" }
            let names = orderedNames(codes)
            switch names.count {
            case 0: return "No languages"
            case 1...4: return names.joined(separator: ", ")
            case 5...9: return "\(names[0]), \(names[1]) and \(names.count - 2) more"
            default: return "\(names.count) languages"
            }
        }
    }

    /// The languages, long, with the ones the user speaks named: “25
    /// European languages, including English and German”.
    static func languagesInDetail(_ size: ModelSize, spoken: [String], systemLanguages: Set<String>?) -> String {
        let short = languages(size, systemLanguages: systemLanguages)
        if case .only(let codes) = size.languageCoverage, codes.count <= 4 { return short }
        let covered = ModelPickerCatalog.fit(of: size, for: spoken, systemLanguages: systemLanguages).covered
        guard !covered.isEmpty else { return short }
        return "\(short), including \(SpokenLanguages.list(covered))"
    }

    /// English first, then the rest by name.
    private static func orderedNames(_ codes: Set<String>) -> [String] {
        let names = codes.filter { $0 != "en" }.map(SpokenLanguages.displayName(for:)).sorted()
        return codes.contains("en") ? ["English"] + names : names
    }

    /// Speed in a word, from the catalog's relative speed.
    static func speed(_ size: ModelSize) -> String {
        switch size.relativeSpeed {
        case ...1: return "Fastest"
        case 2: return "Very fast"
        case 3...5: return "Fast"
        case 6...9: return "Medium speed"
        case 10...14: return "Slower"
        default: return "Slow"
        }
    }

    /// Accuracy as the step the word names: 0 basic, 1 fair, 2 accurate,
    /// 3 very accurate, 4 most accurate.
    static func accuracyTier(_ size: ModelSize) -> Int {
        switch size.accuracyScore {
        case 1...: return 4
        case 0.85...: return 3
        case 0.7...: return 2
        case 0.55...: return 1
        default: return 0
        }
    }

    /// Accuracy in a word, from the catalog's accuracy score.
    static func accuracy(_ size: ModelSize) -> String {
        ["basic", "fair", "accurate", "very accurate", "most accurate"][accuracyTier(size)]
    }

    /// The row's one meta line: “25 European languages · Fastest · very accurate”.
    static func meta(_ size: ModelSize, systemLanguages: Set<String>?) -> String {
        if size.isRemotelyHosted { return "Whisper-compatible · Depends on your server" }
        if size.isSystemManaged { return "\(languages(size, systemLanguages: systemLanguages)) · Managed by macOS" }
        return "\(languages(size, systemLanguages: systemLanguages)) · \(speed(size)) · \(accuracy(size))"
    }

    /// “Doesn't understand German”, when the model misses a spoken language.
    static func misfit(_ size: ModelSize, spoken: [String], systemLanguages: Set<String>?) -> String? {
        let fit = ModelPickerCatalog.fit(of: size, for: spoken, systemLanguages: systemLanguages)
        guard !fit.coversAll else { return nil }
        return "Doesn’t understand \(SpokenLanguages.list(fit.missing))"
    }

    /// Who made it and where it runs, for the details dialog.
    static func origin(_ size: ModelSize) -> String {
        let place: String
        switch size.engine {
        case .parakeet, .whisperKit: place = "runs on the Neural Engine"
        case .sherpaOnnx: place = "runs on the CPU"
        case .appleSpeech: place = "built into macOS"
        case .customEndpoint: return "Runs on your server"
        }
        return "\(size.creator.displayName) · \(place)"
    }

    // MARK: Writing models

    /// A writing model's name as the design writes it.
    static func name(_ kind: CleanupModelKind) -> String {
        kind == .ministral3_3b_q4_k_m ? "Ministral 3 3B" : kind.descriptor.displayName
    }

    /// “Cleanup only” for models too small to follow edits.
    static func variant(_ kind: CleanupModelKind) -> String? {
        kind.supportsCommandMode ? nil : "Cleanup only"
    }

    /// A writing model's download size: “491 MB”, “2.15 GB”.
    static func downloadSize(_ kind: CleanupModelKind) -> String {
        size(bytes: kind.descriptor.expectedByteCount)
    }

    /// Speed in a word, from the slowest-Mac generation speed.
    static func speed(_ kind: CleanupModelKind) -> String {
        switch kind.descriptor.generationTokensPerSecond {
        case 90...: return "Fastest"
        case 40...: return "Fast"
        case 20...: return "Medium speed"
        case 15...: return "Slower"
        default: return "Slow"
        }
    }

    /// The row's meta line: “Fastest · About 0.9 GB memory”.
    static func meta(_ kind: CleanupModelKind) -> String {
        "\(speed(kind)) · \(memory(gb: kind.descriptor.ramRequiredGB)) of memory"
    }
}

// MARK: - Families

/// The groups of the All speech models list, one per engine.
enum CalmSpeechFamily: String, CaseIterable, Identifiable, Sendable {
    case parakeet, whisper, appleSpeech, specialized, ownServer

    var id: String { rawValue }

    init(engine: TranscriptionEngine) {
        switch engine {
        case .parakeet: self = .parakeet
        case .whisperKit: self = .whisper
        case .appleSpeech: self = .appleSpeech
        case .sherpaOnnx: self = .specialized
        case .customEndpoint: self = .ownServer
        }
    }

    var title: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "Whisper"
        case .appleSpeech: return "Apple Speech"
        case .specialized: return "Specialized"
        case .ownServer: return "Your own server"
        }
    }

    var blurb: String {
        switch self {
        case .parakeet: return "Fastest on Apple Silicon"
        case .whisper: return "99 languages, can translate into English"
        case .appleSpeech: return "Built into macOS 26"
        case .specialized: return "Small, run on the CPU"
        case .ownServer: return "Audio leaves this Mac"
        }
    }

    /// Models in catalog order, grouped by family, families in board order.
    static func groups(_ sizes: [ModelSize]) -> [(family: CalmSpeechFamily, models: [ModelSize])] {
        let ordered = sizes.sorted { catalogIndex($0) < catalogIndex($1) }
        return allCases.compactMap { family in
            let members = ordered.filter { CalmSpeechFamily(engine: $0.engine) == family }
            return members.isEmpty ? nil : (family, members)
        }
    }

    private static func catalogIndex(_ size: ModelSize) -> Int {
        ModelSize.standardCatalog.firstIndex(of: size) ?? ModelSize.allCases.count
    }
}

// MARK: - Picks

/// The three cards on each Models tab.
enum CalmPickSlot: String, Sendable {
    case recommended, lightest, mostAccurate, bestQuality

    var title: String {
        switch self {
        case .recommended: return "Recommended"
        case .lightest: return "Lightest"
        case .mostAccurate: return "Most accurate"
        case .bestQuality: return "Best quality"
        }
    }
}

/// One pick card: its slot and the model in it. `isRunnerUp` is set when
/// the slot's first choice already sits in an earlier card.
struct CalmModelPick<Model: Hashable>: Hashable {
    let slot: CalmPickSlot
    let model: Model
    var isRunnerUp = false
}

/// How the three picks are chosen (Model chooser parts board):
///
/// - Speech: Recommended = the fastest model that understands every
///   language the user speaks, the more accurate first · Lightest = the
///   smallest that does · Most accurate = the most accurate that does.
///   “Does” uses the onboarding recommendation's rules: supported on this
///   Mac, on this Mac (not a server), and fits the memory share (or, when
///   none fits, the lightest). Recommended and Lightest skip “basic”
///   models (Whisper Tiny) unless nothing better understands the languages.
///   Models that tie prefer the one in use, then one already downloaded,
///   then the smaller download, so English and German get Parakeet v3
///   rather than the larger Parakeet Ultra.
/// - Writing AI: Recommended = the model suggested for this Mac's memory
///   (Ministral 3 3B from 16 GB) · Lightest = Qwen 2.5 0.5B · Best quality =
///   Qwen 3 4B Instruct, or Ministral 3 3B when the user speaks a language
///   besides English (Qwen 3 4B translated German and French dictation into
///   English). Only models that fit `writingMemoryShare` of the memory.
/// - When a slot's choice is already in an earlier card, the slot shows its
///   next best.
enum CalmModelPicks {
    /// The models the speech cards choose from.
    static func eligibleSpeechModels(
        languages: [String], models: [WhisperModelInfo], systemLanguages: Set<String>?, memoryGB: Int?
    ) -> [ModelSize] {
        let codes = languages.filter { $0 != "auto" }
        let covering = models.map(\.size).filter { size in
            guard let model = models.first(where: { $0.size == size }) else { return false }
            return model.isSupported && !size.isRemotelyHosted && !size.isLegacy
                && ModelPickerCatalog.fit(of: size, for: codes, systemLanguages: systemLanguages).coversAll
        }
        let fitting = covering.filter { size in
            guard let memoryGB else { return true }
            return size.firstLoadRAMRequiredGB <= Double(memoryGB) * OnboardingModelGuidance.memoryShare
        }
        if !fitting.isEmpty { return fitting }
        return [covering.min { $0.firstLoadRAMRequiredGB < $1.firstLoadRAMRequiredGB }].compactMap { $0 }
    }

    /// The three speech cards, in order.
    static func speech(
        languages: [String], models: [WhisperModelInfo], systemLanguages: Set<String>?, memoryGB: Int?
    ) -> [CalmModelPick<ModelSize>] {
        let eligible = eligibleSpeechModels(
            languages: languages, models: models, systemLanguages: systemLanguages, memoryGB: memoryGB
        )
        let decent = eligible.filter { CalmModelText.accuracyTier($0) >= fairTier }
        let everyday = decent.isEmpty ? eligible : decent
        let ties = SpeechTieBreak(models: models)
        let rankings: [(CalmPickSlot, [ModelSize])] = [
            (.recommended, everyday.sorted { fastestFirst($0, $1, ties) }),
            (.lightest, everyday.sorted { lightestFirst($0, $1, ties) }),
            (.mostAccurate, eligible.sorted { mostAccurateFirst($0, $1, ties) }),
        ]
        return fill(rankings)
    }

    /// The lowest accuracy step the everyday cards offer: “fair”.
    private static let fairTier = 1

    /// What settles a tie between equally good models: the one in use, then
    /// one already on this Mac, then the smaller download.
    private struct SpeechTieBreak {
        let inUse: Set<ModelSize>
        let downloaded: Set<ModelSize>

        init(models: [WhisperModelInfo]) {
            inUse = Set(models.filter { $0.isActive || $0.isLoading }.map(\.size))
            downloaded = Set(models.filter(\.isDownloaded).map(\.size))
        }

        func prefers(_ lhs: ModelSize, _ rhs: ModelSize) -> Bool {
            if inUse.contains(lhs) != inUse.contains(rhs) { return inUse.contains(lhs) }
            if downloaded.contains(lhs) != downloaded.contains(rhs) { return downloaded.contains(lhs) }
            if lhs.fileSizeBytes != rhs.fileSizeBytes { return lhs.fileSizeBytes < rhs.fileSizeBytes }
            return lhs.rawValue < rhs.rawValue
        }
    }

    /// The most of the Mac's memory a writing card's model may need: it
    /// stays loaded beside the speech model and the user's apps.
    static let writingMemoryShare = 0.3

    /// Writing models that turned other languages into English instead of
    /// cleaning them up (AGENTS.md: Qwen 3 4B with German and French).
    static let translatesIntoEnglish: Set<CleanupModelKind> = [.qwen3_4b_instruct_2507_q4_k_m]

    /// The three Writing AI cards, in order, for this Mac's memory and the
    /// languages the user speaks.
    static func writing(memoryGB: Int, languages: [String] = []) -> [CalmModelPick<CleanupModelKind>] {
        let speaksOtherLanguages = languages.contains { $0 != "auto" && $0 != "en" }
        let isOffered: (CleanupModelKind) -> Bool = { kind in
            kind.descriptor.ramRequiredGB <= Double(memoryGB) * writingMemoryShare
                && !(speaksOtherLanguages && translatesIntoEnglish.contains(kind))
        }
        let suggested = CleanupModelCatalog.suggestion(memoryGB: memoryGB).cleanup
        let all = CleanupModelKind.cleanupChoices
        let bestQuality: [CleanupModelKind] = speaksOtherLanguages
            ? [.ministral3_3b_q4_k_m, .qwen25_7b_q4_k_m, .qwen25_1_5b_q4_k_m]
            : [.qwen3_4b_instruct_2507_q4_k_m, .qwen25_7b_q4_k_m, .ministral3_3b_q4_k_m, .qwen25_1_5b_q4_k_m]
        let rankings: [(CalmPickSlot, [CleanupModelKind])] = [
            (.recommended, ([suggested] + all.filter { $0 != suggested }).filter(isOffered)),
            (.lightest, [.qwen25_0_5b_q4_k_m, .qwen3_0_6b_q4_k_m, .qwen25_1_5b_q4_k_m, .ministral3_3b_q4_k_m].filter(isOffered)),
            (.bestQuality, bestQuality.filter(isOffered)),
        ]
        return fill(rankings)
    }

    /// Each slot takes its first model not already in an earlier card.
    private static func fill<Model: Hashable>(_ rankings: [(CalmPickSlot, [Model])]) -> [CalmModelPick<Model>] {
        var used = Set<Model>()
        var picks: [CalmModelPick<Model>] = []
        for (slot, ranked) in rankings {
            guard let model = ranked.first(where: { !used.contains($0) }) else { continue }
            used.insert(model)
            picks.append(CalmModelPick(slot: slot, model: model, isRunnerUp: model != ranked.first))
        }
        return picks
    }

    /// Fastest first; among equally fast, the higher accuracy step (the
    /// word the card shows, so Ultra's slightly higher score doesn't beat v3).
    private static func fastestFirst(_ lhs: ModelSize, _ rhs: ModelSize, _ ties: SpeechTieBreak) -> Bool {
        if lhs.relativeSpeed != rhs.relativeSpeed { return lhs.relativeSpeed < rhs.relativeSpeed }
        let lhsTier = CalmModelText.accuracyTier(lhs), rhsTier = CalmModelText.accuracyTier(rhs)
        if lhsTier != rhsTier { return lhsTier > rhsTier }
        return ties.prefers(lhs, rhs)
    }

    private static func lightestFirst(_ lhs: ModelSize, _ rhs: ModelSize, _ ties: SpeechTieBreak) -> Bool {
        // macOS owns Apple Speech's memory; its footprint isn't VocaMac's to promise.
        if lhs.isSystemManaged != rhs.isSystemManaged { return !lhs.isSystemManaged }
        if lhs.ramRequiredGB != rhs.ramRequiredGB { return lhs.ramRequiredGB < rhs.ramRequiredGB }
        return ties.prefers(lhs, rhs)
    }

    private static func mostAccurateFirst(_ lhs: ModelSize, _ rhs: ModelSize, _ ties: SpeechTieBreak) -> Bool {
        if lhs.accuracyScore != rhs.accuracyScore { return lhs.accuracyScore > rhs.accuracyScore }
        if lhs.relativeSpeed != rhs.relativeSpeed { return lhs.relativeSpeed < rhs.relativeSpeed }
        return ties.prefers(lhs, rhs)
    }

    // MARK: Card copy

    /// The sentence under a speech card's name.
    static func reason(for pick: CalmModelPick<ModelSize>, among picks: [CalmModelPick<ModelSize>], languages: [String]) -> String {
        let size = pick.model
        switch pick.slot {
        case .recommended:
            let scope: String
            switch languages.filter({ $0 != "auto" }).count {
            case 0: scope = ""
            case 1: scope = " in \(SpokenLanguages.displayName(for: languages[0]))"
            case 2: scope = " in both your languages"
            default: scope = " in all your languages"
            }
            return "Fastest on this Mac and \(CalmModelText.accuracy(size))\(scope)."
        case .lightest:
            let lead = pick.isRunnerUp ? "Light on memory." : "Uses the least memory."
            return size.accuracyScore >= 0.7 ? "\(lead) Still \(CalmModelText.accuracy(size))." : "\(lead) Fine for short notes."
        case .mostAccurate, .bestQuality:
            let recommended = picks.first { $0.slot == .recommended }?.model
            let slower = recommended.map { size.relativeSpeed > $0.relativeSpeed } ?? false
            return slower ? "Best for long, careful dictation. A little slower." : "Best for long, careful dictation."
        }
    }

    /// The sentence under a Writing AI card's name.
    static func reason(for kind: CleanupModelKind, languages: [String]) -> String {
        switch kind {
        case .qwen25_0_5b_q4_k_m: return "Cleanup only. Quick on any Mac."
        case .qwen3_0_6b_q4_k_m: return "Cleanup only. The smallest download."
        case .qwen25_1_5b_q4_k_m: return "Cleans up and follows simple edits by voice."
        case .ministral3_3b_q4_k_m:
            // Measured keeping Spanish, French and German dictation in its own language.
            let kept = languages.first { ["de", "fr", "es"].contains($0) }.map(SpokenLanguages.displayName(for:))
            return kept.map { "Cleans up and edits by voice. Keeps \($0) as \($0)." }
                ?? "Cleans up and edits by voice."
        case .qwen3_4b_instruct_2507_q4_k_m: return "Strongest edits. Needs more memory."
        case .qwen25_7b_q4_k_m: return "Largest. For long, careful rewrites. Slow."
        }
    }

    // MARK: Picking

    /// What picking a speech model has to do or ask first.
    enum SpeechStep: Equatable {
        /// Already the model in use, or already on its way.
        case nothing
        /// Your own server: open its dialog (never picked automatically).
        case setUpServer
        /// Not verified on this Mac's chip: ask before using it.
        case confirmExperimental
        /// Another download is past half way: ask before stopping it.
        case confirmStopDownload(ModelSize, progress: Double)
        /// Go, stopping another download first when there is one.
        case start(cancelling: ModelSize?)
    }

    /// The step for picking `size`, given what the user already confirmed.
    static func speechStep(
        for size: ModelSize, models: [WhisperModelInfo],
        confirmedExperimental: Bool = false, confirmedStop: Bool = false
    ) -> SpeechStep {
        guard let model = models.first(where: { $0.size == size }) else { return .nothing }
        if size.isRemotelyHosted { return .setUpServer }
        if model.downloadProgress != nil || model.isLoading { return .nothing }
        if model.isActive { return .nothing }
        if !model.isSupported && !confirmedExperimental { return .confirmExperimental }
        if let other = models.first(where: { $0.size != size && $0.downloadProgress != nil }) {
            let progress = other.downloadProgress ?? 0
            if progress > 0.5 && !confirmedStop { return .confirmStopDownload(other.size, progress: progress) }
            return .start(cancelling: other.size)
        }
        return .start(cancelling: nil)
    }

    /// What picking a writing model has to do or ask first.
    enum WritingStep: Equatable {
        case nothing
        case confirmStopDownload(CleanupModelKind, progress: Double)
        case start(cancelling: CleanupModelKind?)
    }

    /// The step for picking `kind`, given the cleanup service's state.
    static func writingStep(
        for kind: CleanupModelKind, state: CleanupModelState, isInUse: Bool, confirmedStop: Bool = false
    ) -> WritingStep {
        if case .downloading(let active, let progress) = state {
            if active == kind { return .nothing }
            if progress > 0.5 && !confirmedStop { return .confirmStopDownload(active, progress: progress) }
            return .start(cancelling: active)
        }
        return isInUse ? .nothing : .start(cancelling: nil)
    }
}

// MARK: - Command Mode engine choice

/// The “Command Mode uses” choices on Models › Writing AI.
enum CalmCommandModeChoice: String, Hashable, Sendable {
    /// One on-device model runs both features.
    case same
    /// Command Mode runs its own on-device model.
    case own
    /// Cleanup runs on a server; Command Mode runs a model on this Mac.
    case onThisMac
    case appleIntelligence
    /// The server Smart Cleanup uses.
    case server

    /// The segment's title.
    func title(provider: CleanupProvider) -> String {
        switch self {
        case .same: return "Same model"
        case .own: return "Its own model"
        case .onThisMac: return "On this Mac"
        case .appleIntelligence: return "Apple Intelligence"
        case .server: return "\(provider.displayName) server"
        }
    }

    /// The choices to offer. Apple Intelligence and the server only when
    /// they can run (or are already chosen).
    static func options(
        cleanupIsLocal: Bool, appleIntelligenceAvailable: Bool, endpointIsValid: Bool, engine: CommandModeEngine
    ) -> [CalmCommandModeChoice] {
        var options: [CalmCommandModeChoice] = []
        if cleanupIsLocal {
            options = [.same, .own]
        } else {
            if endpointIsValid || engine == .endpoint { options.append(.server) }
            options.append(.onThisMac)
        }
        if appleIntelligenceAvailable || engine == .appleIntelligence { options.append(.appleIntelligence) }
        return options
    }

    /// The choice that describes the current setup.
    static func current(engine: CommandModeEngine, cleanupIsLocal: Bool, sharesModel: Bool) -> CalmCommandModeChoice {
        switch engine {
        case .appleIntelligence: return .appleIntelligence
        case .endpoint: return .server
        case .local: return cleanupIsLocal ? (sharesModel ? .same : .own) : .onThisMac
        }
    }
}

// MARK: - AppState

extension AppState {
    /// This Mac's installed memory, as the recommendations read it.
    var calmMemoryGB: Int {
        systemCapabilities?.physicalMemoryGB ?? SystemInfo.physicalMemoryGB
    }

    /// The three Speech to text cards for the user's languages and Mac.
    var calmSpeechPicks: [CalmModelPick<ModelSize>] {
        CalmModelPicks.speech(
            languages: spokenLanguages, models: availableModels,
            systemLanguages: appleSpeechLanguages, memoryGB: calmMemoryGB
        )
    }

    /// The three Writing AI cards for this Mac.
    var calmWritingPicks: [CalmModelPick<CleanupModelKind>] {
        CalmModelPicks.writing(memoryGB: calmMemoryGB, languages: spokenLanguages)
    }

    /// The speech model the engine has loaded, whichever way it reports it.
    var calmLoadedSpeechModel: ModelSize? {
        if let model = currentModel { return model.size }
        guard let name = whisperService.loadedModelName else { return nil }
        return ModelSize(rawValue: name) ?? modelManager.modelSize(from: name)
    }

    /// The loaded speech model's name as the window writes it everywhere
    /// (“Whisper Tiny”, “Parakeet v3”), falling back to the engine's own
    /// identifier when the catalog doesn't know it.
    var calmLoadedSpeechModelName: String? {
        calmLoadedSpeechModel.map(CalmModelText.name) ?? whisperService.loadedModelName
    }

    /// The speech model dictation uses, or is switching to while it loads.
    var calmSpeechModelInUse: WhisperModelInfo? {
        availableModels.first(where: \.isLoading) ?? availableModels.first(where: \.isActive)
    }

    /// Whether the speech server is set up well enough to send audio to.
    var calmSpeechEndpointIsValid: Bool {
        speechEndpoint.validationProblem() == nil
    }

    /// Whether the cleanup server is set up well enough to run edits.
    var calmCleanupEndpointIsValid: Bool {
        !cleanupEndpoint.isLocal && cleanupEndpoint.validationProblem() == nil
    }

    /// The writing model Smart Cleanup runs on this Mac (nil on a server).
    var calmCleanupModelInUse: CleanupModelKind? {
        cleanupEndpoint.isLocal ? selectedCleanupModelKind : nil
    }

    /// The “Command Mode uses” choices to offer.
    var calmCommandModeOptions: [CalmCommandModeChoice] {
        CalmCommandModeChoice.options(
            cleanupIsLocal: cleanupEndpoint.isLocal, appleIntelligenceAvailable: appleIntelligenceAvailable(),
            endpointIsValid: calmCleanupEndpointIsValid, engine: commandModeEngine
        )
    }

    /// The “Command Mode uses” choice the current setup matches.
    var calmCommandModeChoice: CalmCommandModeChoice {
        CalmCommandModeChoice.current(
            engine: commandModeEngine, cleanupIsLocal: cleanupEndpoint.isLocal, sharesModel: sharesAIModel
        )
    }

    /// The on-device model Command Mode would run on its own: its current
    /// one, else the one suggested for this Mac.
    var calmCommandModeLocalCandidate: CleanupModelKind {
        if case .local(let kind) = commandModeEngine { return kind }
        return cleanupModelSuggestion.commandMode
    }

    /// Apply a “Command Mode uses” choice.
    func selectCalmCommandModeChoice(_ choice: CalmCommandModeChoice) async {
        switch choice {
        case .same:
            await setSharesAIModel(true)
        case .own:
            await setSharesAIModel(false)
            if case .local = commandModeEngine { return }
            await useAIModel(calmCommandModeLocalCandidate, for: .commandMode)
        case .onThisMac:
            await useAIModel(calmCommandModeLocalCandidate, for: .commandMode)
        case .appleIntelligence:
            selectCommandModeEngine(.appleIntelligence)
        case .server:
            selectCommandModeEngine(.endpoint)
        }
    }

    /// Run Smart Cleanup on this Mac again, after it ran on a server.
    func calmRunCleanupOnThisMac() {
        guard !cleanupEndpoint.isLocal else { return }
        var configuration = cleanupEndpoint
        configuration.provider = .local
        cleanupEndpoint = configuration
    }

    /// Bring Smart Cleanup back to this Mac with `kind`. The server keeps
    /// cleaning while `kind` downloads and loads; only then does cleanup
    /// switch, so dictations are never left uncleaned meanwhile and a failed
    /// download keeps the server. Command Mode set to the server moves to
    /// `kind` (or Apple Intelligence when `kind` can't edit), since the
    /// server setting stops applying.
    ///
    /// - Parameter isWanted: Checked after each wait; false (a newer pick,
    ///   a cancel) leaves everything as it was.
    /// - Returns: Whether cleanup now runs on this Mac with `kind`.
    @discardableResult
    func calmMoveCleanupToThisMac(
        _ kind: CleanupModelKind, for role: AIModelRole, isWanted: () -> Bool = { true }
    ) async -> Bool {
        guard !cleanupEndpoint.isLocal else {
            await useAIModel(kind, for: role)
            return true
        }
        if !transcriptCleanup.isDownloaded(kind) {
            await transcriptCleanup.download(kind)
            guard isWanted(), transcriptCleanup.isDownloaded(kind) else { return false }
        }
        if transcriptCleanupEnabled {
            await transcriptCleanup.load(kind)
            guard isWanted(), transcriptCleanup.loadedKind == kind else { return false }
        }
        // Read before the switch: once cleanup is local, the server choice
        // no longer reads as `.endpoint`.
        let commandModeWasOnServer = commandModeEngine == .endpoint
        calmRunCleanupOnThisMac()
        if commandModeWasOnServer {
            if kind.supportsCommandMode {
                commandModeEngine = .local(kind)
            } else if appleIntelligenceAvailable() {
                commandModeEngine = .appleIntelligence
            }
        }
        // Cleanup is local now, so this loads and warms `kind` as usual.
        await useAIModel(kind, for: role)
        return true
    }

    /// Dismiss the download or delete error the Models pages show.
    func calmDismissError() {
        errorMessage = nil
        if appStatus == .error { appStatus = .idle }
    }
}

// MARK: - Smart Cleanup copy

/// The before / after example and one-line description Settings › Smart
/// Cleanup shows for each level. Written to match what each level does
/// (`CleanupLevel.detail`): Light keeps fillers, Grammar repairs agreement,
/// High also drops what a correction replaces.
struct CalmCleanupExample: Equatable {
    let said: String
    let types: String
    let summary: String

    private static let rambling = "um so I think we should uh ship it on friday actually no thursday"

    static func example(for level: CleanupLevel) -> CalmCleanupExample {
        switch level {
        case .none:
            return CalmCleanupExample(said: rambling, types: rambling, summary: "Keeps your words exactly as spoken")
        case .light:
            return CalmCleanupExample(
                said: rambling, types: "Um, so I think we should, uh, ship it on Friday, actually no, Thursday.",
                summary: "Tidies punctuation and capitals. Keeps every word"
            )
        case .medium:
            return CalmCleanupExample(
                said: rambling, types: "So I think we should ship it on Thursday.",
                summary: "Also drops fillers and keeps only what you meant when you correct yourself"
            )
        case .grammar:
            return CalmCleanupExample(
                said: "um so she want to ship it on friday actually no thursday",
                types: "So she wants to ship it on Thursday.",
                summary: "Also fixes small English grammar slips, like “she want”"
            )
        case .high:
            return CalmCleanupExample(
                said: "um send it to john no mary and uh scratch that send it tomorrow",
                types: "Send it tomorrow.",
                summary: "Also follows looser corrections and drops what you cancel with “scratch that”"
            )
        }
    }

    /// The levels the segmented control offers. None only while it is the
    /// stored level: with Smart Cleanup on it would mean the model never runs.
    static func levels(current: CleanupLevel) -> [CleanupLevel] {
        CleanupLevel.displayOrder.filter { $0 != .none || current == .none }
    }
}
