// SpokenSymbolTransformer.swift
// VocaMac
//
// Turns spoken symbol names into literal punctuation: "config dot json"
// becomes `config.json`, "camel case handle user input" becomes
// `handleUserInput`.
//
// This is the highest-risk part of writing styles, because English prose is
// full of the same words ("the dot product", "slash and burn"). Every rule
// here is therefore context-locked and sorted into a confidence tier so a
// misfire can be narrowed without disabling the feature. Tier A only fires in
// contexts prose cannot plausibly produce; Tier B uses heuristics and is
// enabled only for the Code and Terminal styles.

import Foundation

/// Token-level spoken-symbol substitution. Pure and side-effect free.
enum SpokenSymbolTransformer {

    // MARK: - Vocabulary

    /// File extensions recognized after a spoken "dot".
    ///
    /// Deliberately excludes top-level domains (`com`, `net`, `org`, `io`,
    /// `ai`, `co`) — "dot com" appears in ordinary speech far more often than
    /// it names a file, and getting that wrong is very visible.
    static let knownExtensions: Set<String> = [
        "md", "markdown", "txt", "json", "yaml", "yml", "toml", "xml", "csv", "tsv",
        "swift", "ts", "tsx", "js", "jsx", "mjs", "cjs", "py", "rb", "go", "rs",
        "java", "kt", "kts", "c", "cc", "cpp", "cxx", "h", "hpp", "m", "mm",
        "cs", "php", "pl", "lua", "r", "scala", "clj", "ex", "exs", "erl", "hs",
        "sh", "bash", "zsh", "fish", "ps1", "bat",
        "html", "htm", "css", "scss", "sass", "less", "vue", "svelte",
        "sql", "graphql", "proto", "lock", "cfg", "conf", "ini", "env",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "pdf", "zip", "tar", "gz",
        "plist", "entitlements", "xcconfig", "gradle", "dockerfile", "makefile"
    ]

    /// The only words a filename may absorb ahead of its base word.
    ///
    /// A spoken filename is usually one word ("readme dot md"). Occasionally
    /// it is two ("my file dot md"). Distinguishing the second case from a
    /// verb ("compare readme dot md") cannot be done from grammar alone, so
    /// rather than guess, the lookback extends only across this small closed
    /// set of modifiers that essentially never end a clause. Everything else
    /// stops the lookback, which yields the single-word filename — the safe
    /// answer.
    private static let filenameModifiers: Set<String> = [
        "my", "new", "old", "test", "temp", "main", "index",
        "read", "make", "docker", "app", "user", "base", "local"
    ]

    /// Cues that make a following "slash" much more likely to be a path
    /// separator than the English word.
    private static let pathCues: Set<String> = [
        "open", "cd", "file", "files", "path", "in", "into", "import", "from",
        "edit", "create", "directory", "folder", "under", "inside", "at"
    ]

    /// Leading filler words removed when a style asks for it.
    static let leadingFillers: Set<String> = ["um", "uh", "erm", "ah", "eh", "hmm", "like", "so", "okay", "ok", "right", "well"]

    /// Symbol words that some engines glue onto the following word.
    ///
    /// Apple Speech in particular emits "slashcomponents" rather than
    /// "slash components", which hides the symbol from every whitespace-based
    /// rule below. Each prefix carries the tier its split belongs to.
    private static let gluedSymbolPrefixes: [(word: String, tier: SpokenSymbolTiers)] = [
        ("dot", .tierA),
        ("slash", .tierB),
        ("underscore", .tierB),
        ("dash", .tierB),
        ("hyphen", .tierB)
    ]

    /// Ordinary English words that merely begin with a symbol word. Splitting
    /// "dashboard" into "dash board" would be a bad and very visible failure.
    private static let gluedSplitDenylist: Set<String> = [
        "dashboard", "dashboards", "dashed", "dashing", "dasher",
        "dotted", "dotting", "dote", "doted", "dotcom", "dotnet",
        "slashed", "slashing", "slasher", "slashes",
        "underscored", "underscores", "underscoring",
        "hyphenate", "hyphenated", "hyphenation"
    ]

    /// Shortest remainder a glued split may leave behind.
    private static let minGluedRemainder = 3

    /// Bracket and quote commands. Each carries an explicit open/close word,
    /// which is what makes them safe: prose does not say "open paren".
    ///
    /// A solo "backtick" is deliberately not in this table. Programmers say the
    /// word in prose ("wrap it in a backtick"), so it needs the same open/close
    /// proof every other bracket carries.
    private static let bracketCommands: [[String]: BracketToken] = [
        ["open", "paren"]:        BracketToken(literal: "(", attaches: .toNext),
        ["open", "parenthesis"]:  BracketToken(literal: "(", attaches: .toNext),
        ["close", "paren"]:       BracketToken(literal: ")", attaches: .toPrevious),
        ["close", "parenthesis"]: BracketToken(literal: ")", attaches: .toPrevious),
        ["open", "bracket"]:      BracketToken(literal: "[", attaches: .toNext),
        ["close", "bracket"]:     BracketToken(literal: "]", attaches: .toPrevious),
        ["open", "brace"]:        BracketToken(literal: "{", attaches: .toNext),
        ["close", "brace"]:       BracketToken(literal: "}", attaches: .toPrevious),
        ["open", "angle"]:        BracketToken(literal: "<", attaches: .toNext),
        ["close", "angle"]:       BracketToken(literal: ">", attaches: .toPrevious),
        ["open", "backtick"]:     BracketToken(literal: "`", attaches: .toNext),
        ["close", "backtick"]:    BracketToken(literal: "`", attaches: .toPrevious)
    ]

    /// Symbol words that end a case command's word run.
    ///
    /// Without this "camel case handle user input dot swift" swallows the
    /// filename separator and yields `handleUserInputDotSwift`.
    private static let identifierBoundaryWords: Set<String> = [
        "dot", "slash", "underscore", "dash", "hyphen", "backtick"
    ]

    /// Case-conversion commands, longest phrase first so "screaming snake
    /// case" is matched before "snake case".
    private static let caseCommands: [(phrase: [String], style: IdentifierCase)] = [
        (["screaming", "snake", "case"], .screamingSnake),
        (["constant", "case"],           .screamingSnake),
        (["camel", "case"],              .camel),
        (["pascal", "case"],             .pascal),
        (["upper", "camel", "case"],     .pascal),
        (["snake", "case"],              .snake),
        (["kebab", "case"],              .kebab),
        (["dash", "case"],               .kebab)
    ]

    /// Maximum words a case command consumes.
    private static let maxCaseCommandWords = 6
    /// Maximum words absorbed into a filename before a spoken extension.
    private static let maxFilenameLookback = 3

    // MARK: - Types

    private enum BracketAttachment { case toNext, toPrevious, none }

    private struct BracketToken {
        let literal: String
        let attaches: BracketAttachment
    }

    private enum IdentifierCase {
        case camel, pascal, snake, kebab, screamingSnake

        func join(_ words: [String]) -> String {
            let cleaned = words.map { $0.lowercased() }.filter { !$0.isEmpty }
            guard let first = cleaned.first else { return "" }
            switch self {
            case .camel:
                return first + cleaned.dropFirst().map { $0.capitalized }.joined()
            case .pascal:
                return cleaned.map { $0.capitalized }.joined()
            case .snake:
                return cleaned.joined(separator: "_")
            case .kebab:
                return cleaned.joined(separator: "-")
            case .screamingSnake:
                return cleaned.joined(separator: "_").uppercased()
            }
        }
    }

    /// One whitespace-delimited token plus the flags the passes need.
    private struct Token {
        var text: String
        /// Index of the spoken word this token still *is*. Rules that rewrite
        /// a token build a fresh one, so a `nil` origin means "a rule fired
        /// here" — which is how the escape check knows whether saying
        /// "literally" prevented anything.
        var origin: Int? = nil
        /// Preceded by "literally" — never substitute using this token.
        var isProtected: Bool = false
        /// Produced by a substitution. Marks the line as identifier-ish, which
        /// is what unlocks the Tier B joiners.
        var isIdentifier: Bool = false
        /// Suppress the space that would normally precede this token.
        var glueLeft: Bool = false
    }

    // MARK: - Entry point

    /// Apply spoken-symbol substitution to one utterance.
    ///
    /// - Parameters:
    ///   - text: The utterance, possibly already containing newlines.
    ///   - tiers: Which confidence tiers are enabled.
    ///   - pathStitching: Allow multi-word filename lookback and path joining.
    ///   - caseCommandsEnabled: Honor "camel case" and friends.
    static func apply(
        _ text: String,
        tiers: SpokenSymbolTiers,
        pathStitching: Bool,
        caseCommandsEnabled: Bool
    ) -> String {
        let masked = applyMasking(
            text,
            tiers: tiers,
            pathStitching: pathStitching,
            caseCommandsEnabled: caseCommandsEnabled
        )
        return masked.restore(in: masked.text)
    }

    /// Apply substitution, leaving every token this pass produced masked as one
    /// opaque character.
    ///
    /// The style pipeline runs sentence case and punctuation polish after this
    /// pass, and neither should touch a filename or identifier the pass just
    /// built — capitalizing `readme.md` into `Readme.md` names a different
    /// file. Masking says "this span is settled" without threading string
    /// ranges through passes that rewrite the string.
    static func applyMasking(
        _ text: String,
        tiers: SpokenSymbolTiers,
        pathStitching: Bool,
        caseCommandsEnabled: Bool
    ) -> MaskedText {
        let unmasked = MaskedText(text: text, base: TextPlaceholder.identifierBase)
        guard !text.isEmpty else { return unmasked }
        guard !tiers.isEmpty || caseCommandsEnabled else { return unmasked }

        // Newline commands run before this pass, so operate per line and keep
        // the line structure intact.
        var masks: [String] = []
        var transformed: [String] = []
        for line in text.components(separatedBy: "\n") {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                transformed.append(line)
                continue
            }
            transformed.append(
                applyToLine(
                    line,
                    tiers: tiers,
                    pathStitching: pathStitching,
                    caseCommandsEnabled: caseCommandsEnabled,
                    masks: &masks
                )
            )
        }

        return MaskedText(
            text: transformed.joined(separator: "\n"),
            replacements: masks,
            base: TextPlaceholder.identifierBase
        )
    }

    private static func applyToLine(
        _ line: String,
        tiers: SpokenSymbolTiers,
        pathStitching: Bool,
        caseCommandsEnabled: Bool,
        masks: inout [String]
    ) -> String {
        let words = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return line }

        let escapes = escapeIndices(in: words)
        let protecting = effectiveEscapes(
            among: escapes,
            in: words,
            tiers: tiers,
            pathStitching: pathStitching,
            caseCommandsEnabled: caseCommandsEnabled
        )
        let tokens = runRules(
            tokenize(words, droppingAt: protecting, protectingAt: protecting),
            tiers: tiers,
            pathStitching: pathStitching,
            caseCommandsEnabled: caseCommandsEnabled
        )

        // Whitespace between words is the user's, not ours: only re-render the
        // line when a rule actually fired, so untouched dictation keeps its
        // original spacing byte for byte.
        let unchanged = tokens.count == words.count
            && zip(tokens, words).allSatisfy { $0.text == $1 }
            && !tokens.contains(where: { $0.glueLeft })
        guard !unchanged else { return line }

        return render(tokens, masks: &masks)
    }

    /// Run every enabled rule over a token list.
    private static func runRules(
        _ tokens: [Token],
        tiers: SpokenSymbolTiers,
        pathStitching: Bool,
        caseCommandsEnabled: Bool
    ) -> [Token] {
        var tokens = tokens

        // Must run first: every rule below matches whole tokens, so a symbol
        // fused to its neighbour is invisible until it is separated.
        splitGluedSymbolWords(&tokens, tiers: tiers)

        if caseCommandsEnabled {
            applyCaseCommands(&tokens)
        }
        if tiers.contains(.tierA) {
            applyExtensionRule(&tokens, pathStitching: pathStitching)
            applyBracketCommands(&tokens)
        }
        if tiers.contains(.tierB) {
            applySlashRule(&tokens, pathStitching: pathStitching)
            applyIdentifierDotRule(&tokens)
            applyJoinerRule(&tokens)
        }
        return tokens
    }

    // MARK: - Tokenizing

    /// Positions of a spoken "literally" that could be an escape.
    ///
    /// Whether one *is* an escape is decided by `effectiveEscapes`, not by a
    /// word list: any list would have to include "open", "close", "go", "dash"
    /// and "forward", all of which are ordinary English.
    private static func escapeIndices(in words: [String]) -> [Int] {
        words.indices.filter { index in
            core(of: words[index]).lowercased() == "literally"
                && index + 1 < words.count
                && core(of: words[index + 1]).lowercased() != "literally"
        }
    }

    /// Which candidates actually suppress a substitution.
    ///
    /// Answers the user's own question — "would this word have been rewritten
    /// if I had not said it?" — from a single extra pass over the line with no
    /// protection at all. A word that survives that pass unchanged had nothing
    /// to be protected from, so its "literally" was the adverb, not a command.
    ///
    /// One pass, not one per candidate: an utterance can contain the word many
    /// times, and re-running the line for each was quadratic.
    private static func effectiveEscapes(
        among candidates: [Int],
        in words: [String],
        tiers: SpokenSymbolTiers,
        pathStitching: Bool,
        caseCommandsEnabled: Bool
    ) -> Set<Int> {
        guard !candidates.isEmpty else { return [] }

        // One baseline pass with every candidate dropped and nothing protected:
        // the line as if the word had never been said. A word that comes
        // through it untouched had nothing to be protected from.
        let baseline = runRules(
            tokenize(words, droppingAt: Set(candidates), protectingAt: []),
            tiers: tiers,
            pathStitching: pathStitching,
            caseCommandsEnabled: caseCommandsEnabled
        )

        var survived: [Int: Token] = [:]
        for token in baseline {
            guard let origin = token.origin else { continue }
            survived[origin] = token
        }

        return Set(
            candidates.filter { candidate in
                // Inserting the escape between the two words of `forward
                // slash` protects that command even when an earlier path has
                // already been completed and no longer supplies local context
                // in the baseline pass.
                if tiers.contains(.tierB), pathStitching,
                   candidate > 0,
                   core(of: words[candidate - 1]).lowercased() == "forward",
                   core(of: words[candidate + 1]).lowercased() == "slash" {
                    return true
                }
                guard let token = survived[candidate + 1] else { return true }
                return token.text != words[candidate + 1] || token.glueLeft
            }
        )
    }

    /// Build the token list for one line.
    ///
    /// - Parameters:
    ///   - words: The whitespace-split line.
    ///   - dropped: Positions of "literally" to leave out of the output.
    ///   - protectingAt: The subset of those whose next word is protected
    ///     from substitution. A position that is dropped but not protecting
    ///     yields the control run: the line as if the word had never been said.
    private static func tokenize(
        _ words: [String],
        droppingAt dropped: Set<Int>,
        protectingAt protecting: Set<Int>
    ) -> [Token] {
        var tokens: [Token] = []
        var protectNext = false

        for (index, word) in words.enumerated() {
            if dropped.contains(index) {
                protectNext = protecting.contains(index)
                continue
            }
            // A masked span (an already-expanded snippet) is user-authored
            // text, not dictation: never substitute inside it.
            let isMasked = TextPlaceholder.containsPlaceholder(word)
            tokens.append(Token(text: word, origin: index, isProtected: protectNext || isMasked))
            protectNext = false
        }
        return tokens
    }

    /// Reassemble tokens, honoring glue flags and masking substituted spans.
    ///
    /// Only the token's core is masked — trailing punctuation stays visible so
    /// the pipeline's sentence-ending rules can still strip or keep it.
    private static func render(_ tokens: [Token], masks: inout [String]) -> String {
        var result = ""
        for (index, token) in tokens.enumerated() {
            if index > 0 && !token.glueLeft {
                result += " "
            }
            guard token.isIdentifier else {
                result += token.text
                continue
            }
            let (core, suffix) = splitTrailingPunctuation(token.text)
            guard core.contains(where: { $0.isLetter || $0.isNumber }),
                  let placeholder = TextPlaceholder.character(
                      at: masks.count,
                      base: TextPlaceholder.identifierBase
                  ) else {
                // Punctuation-only output — a bracket literal — stays visible:
                // masking it would hide the sentence start behind it.
                result += token.text
                continue
            }
            masks.append(core)
            result.append(placeholder)
            result += suffix
        }
        return result
    }

    /// Split a token into its word body and any trailing punctuation, so
    /// "json," can match the extension list and keep its comma.
    static func splitTrailingPunctuation(_ token: String) -> (core: String, suffix: String) {
        var core = token
        var suffix = ""
        while let last = core.last, ",.!?;:)\"'".contains(last) {
            suffix.insert(last, at: suffix.startIndex)
            core.removeLast()
        }
        return (core, suffix)
    }

    private static func core(of token: String) -> String {
        splitTrailingPunctuation(token).core
    }

    /// A bare lowercase word with no punctuation — the only shape the joiner
    /// rules will merge.
    private static func isPlainWord(_ token: Token) -> Bool {
        guard !token.isProtected else { return false }
        let text = token.text
        guard !text.isEmpty else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber }
    }

    /// Whether this token itself is strong evidence that an adjacent spoken
    /// joiner belongs to an identifier. Keeping this local is important: a
    /// filename near the start of an utterance must not turn unrelated prose
    /// near the end into code.
    private static func hasIdentifierSignal(_ token: Token) -> Bool {
        if token.isIdentifier { return true }
        let text = core(of: token.text)
        return text.contains("/")
            || text.contains("_")
            || text.contains(".")
            || text.dropFirst().contains(where: \Character.isUppercase)
    }

    // MARK: - Glued symbol words

    /// Separate a symbol word that an engine fused to the word after it, so
    /// "slashcomponents" becomes "slash" + "components".
    ///
    /// Gated hard, because the split is a guess about a single token:
    ///
    /// - A `dot` split requires the remainder to be a known file extension
    ///   ("dotjson" → `.json`), which prose cannot produce by accident.
    /// - The other prefixes are Tier B and additionally require corroboration
    ///   on the line — a second symbol occurrence or a path cue — so an
    ///   isolated "dashboard" is never touched.
    /// - A denylist covers ordinary words that begin with a symbol word.
    private static func splitGluedSymbolWords(_ tokens: inout [Token], tiers: SpokenSymbolTiers) {
        guard !tiers.isEmpty else { return }
        let allowTierBSplit = tiers.contains(.tierB) && gluedSplitIsCorroborated(tokens)

        var index = 0
        while index < tokens.count {
            guard !tokens[index].isProtected,
                  let split = gluedSplit(
                      of: tokens[index].text,
                      tiers: tiers,
                      allowTierBSplit: allowTierBSplit
                  ) else {
                index += 1
                continue
            }

            tokens.replaceSubrange(index...index, with: [
                Token(text: split.symbol),
                Token(text: split.remainder)
            ])
            // Re-examine the remainder: "slashsrcslashutils" splits repeatedly.
            index += 1
        }
    }

    /// Split one token, or `nil` when no rule applies.
    private static func gluedSplit(
        of token: String,
        tiers: SpokenSymbolTiers,
        allowTierBSplit: Bool
    ) -> (symbol: String, remainder: String)? {
        let (core, suffix) = splitTrailingPunctuation(token)
        let lowered = core.lowercased()
        guard !gluedSplitDenylist.contains(lowered) else { return nil }

        for (word, tier) in gluedSymbolPrefixes {
            guard lowered.hasPrefix(word), lowered.count > word.count else { continue }
            guard tiers.contains(tier) else { continue }

            let remainderCore = String(core.dropFirst(word.count))
            guard let first = remainderCore.first, first.isLetter else { continue }

            switch tier {
            case .tierA:
                // Only a real extension justifies splitting on "dot".
                guard knownExtensions.contains(remainderCore.lowercased()) else { continue }
            default:
                guard allowTierBSplit,
                      remainderCore.count >= minGluedRemainder else { continue }
            }

            return (symbol: word, remainder: remainderCore + suffix)
        }
        return nil
    }

    /// Whether the line carries enough evidence to risk a Tier B glued split.
    private static func gluedSplitIsCorroborated(_ tokens: [Token]) -> Bool {
        var occurrences = 0
        for (index, token) in tokens.enumerated() where !token.isProtected {
            let lowered = core(of: token.text).lowercased()
            if gluedSymbolPrefixes.contains(where: { $0.word == lowered }) {
                occurrences += 1
            } else if !gluedSplitDenylist.contains(lowered),
                      gluedSymbolPrefixes.contains(where: { lowered.hasPrefix($0.word) && lowered.count > $0.word.count }) {
                occurrences += 1
                // A path cue corroborates only a nearby fused symbol. A cue
                // later in ordinary prose ("slashfiction in class") is not
                // evidence for the earlier token.
                let contextStart = max(index - 2, 0)
                if tokens[contextStart..<index].contains(where: {
                    pathCues.contains(core(of: $0.text).lowercased())
                }) {
                    return true
                }
            }
        }
        return occurrences >= 2
    }

    // MARK: - Tier A: case commands

    /// Replace "camel case handle user input" with a single `handleUserInput`
    /// token. Safe at any tier because the user said the command out loud.
    private static func applyCaseCommands(_ tokens: inout [Token]) {
        var index = 0
        while index < tokens.count {
            guard let match = matchCaseCommand(tokens, at: index) else {
                index += 1
                continue
            }

            let wordsStart = index + match.phrase.count
            var wordsEnd = wordsStart
            while wordsEnd < tokens.count,
                  wordsEnd - wordsStart < maxCaseCommandWords,
                  isPlainWord(tokens[wordsEnd]),
                  !identifierBoundaryWords.contains(tokens[wordsEnd].text.lowercased()) {
                wordsEnd += 1
            }

            guard wordsEnd > wordsStart else {
                // "camel case" with nothing to convert — leave it spoken.
                index += 1
                continue
            }

            // A trailing punctuation mark on the final word ends the run and
            // must survive the merge.
            var suffix = ""
            if wordsEnd < tokens.count, !isPlainWord(tokens[wordsEnd]) {
                let (wordCore, wordSuffix) = splitTrailingPunctuation(tokens[wordsEnd].text)
                if !wordCore.isEmpty, !wordSuffix.isEmpty,
                   wordCore.allSatisfy({ $0.isLetter || $0.isNumber }),
                   wordsEnd - wordsStart < maxCaseCommandWords,
                   !tokens[wordsEnd].isProtected {
                    suffix = wordSuffix
                    tokens[wordsEnd].text = wordCore
                    wordsEnd += 1
                }
            }

            let words = tokens[wordsStart..<wordsEnd].map(\.text)
            let joined = match.style.join(words) + suffix
            tokens.replaceSubrange(index..<wordsEnd, with: [Token(text: joined, isIdentifier: true)])
            index += 1
        }
    }

    private static func matchCaseCommand(_ tokens: [Token], at index: Int) -> (phrase: [String], style: IdentifierCase)? {
        for command in caseCommands {
            guard index + command.phrase.count <= tokens.count else { continue }
            let slice = tokens[index..<(index + command.phrase.count)]
            guard slice.allSatisfy({ !$0.isProtected }) else { continue }
            let words = slice.map { core(of: $0.text).lowercased() }
            if words == command.phrase {
                return command
            }
        }
        return nil
    }

    // MARK: - Tier A: spoken file extensions

    /// Merge `<name> dot <known extension>` into `name.ext`.
    ///
    /// With `pathStitching` on, the name absorbs up to
    /// `maxFilenameLookback` preceding words, stopping at a boundary word, so
    /// "open my file dot md" yields `myfile.md` rather than `my file.md`.
    private static func applyExtensionRule(_ tokens: inout [Token], pathStitching: Bool) {
        var index = 0
        while index < tokens.count {
            guard core(of: tokens[index].text).lowercased() == "dot",
                  !tokens[index].isProtected,
                  index > 0,
                  index + 1 < tokens.count else {
                index += 1
                continue
            }

            let next = tokens[index + 1]
            let (extCore, extSuffix) = splitTrailingPunctuation(next.text)
            guard !next.isProtected,
                  knownExtensions.contains(extCore.lowercased()),
                  isPlainWord(tokens[index - 1]) else {
                index += 1
                continue
            }

            let nameStart = pathStitching ? filenameLookbackStart(tokens, endingBefore: index) : index - 1
            // Keep the case the engine produced: `Info.plist` and `README.md`
            // are the names on disk, and lowercasing them is not recoverable.
            // Only the extension is normalized, since it is matched lowercased.
            let nameWords = tokens[nameStart..<index].map(\.text)
            let filename = nameWords.joined() + "." + extCore.lowercased() + extSuffix

            tokens.replaceSubrange(
                nameStart...(index + 1),
                with: [Token(text: filename, isIdentifier: true)]
            )
            index = nameStart + 1
        }
    }

    /// First index of the word run that forms a filename, scanning backwards
    /// from just before the spoken "dot".
    ///
    /// Extends only across `filenameModifiers`, so an unrecognized preceding
    /// word leaves a single-word filename rather than gluing a verb to it.
    private static func filenameLookbackStart(_ tokens: [Token], endingBefore dotIndex: Int) -> Int {
        var start = dotIndex - 1
        while start > 0,
              dotIndex - start < maxFilenameLookback,
              isPlainWord(tokens[start - 1]),
              filenameModifiers.contains(tokens[start - 1].text.lowercased()) {
            start -= 1
        }
        return start
    }

    // MARK: - Tier A: bracket and quote commands

    private static func applyBracketCommands(_ tokens: inout [Token]) {
        var index = 0
        while index < tokens.count {
            guard let (length, bracket) = matchBracketCommand(tokens, at: index) else {
                index += 1
                continue
            }

            var replacement = Token(text: bracket.literal, isIdentifier: true)

            switch bracket.attaches {
            case .toPrevious:
                replacement.glueLeft = index > 0
            case .toNext:
                if index + length < tokens.count {
                    tokens[index + length].glueLeft = true
                }
            case .none:
                break
            }

            tokens.replaceSubrange(index..<(index + length), with: [replacement])
            index += 1
        }
    }

    private static func matchBracketCommand(_ tokens: [Token], at index: Int) -> (length: Int, bracket: BracketToken)? {
        for length in stride(from: 2, through: 1, by: -1) {
            guard index + length <= tokens.count else { continue }
            let slice = tokens[index..<(index + length)]
            guard slice.allSatisfy({ !$0.isProtected }) else { continue }
            let words = slice.map { core(of: $0.text).lowercased() }
            if let bracket = bracketCommands[words] {
                return (length, bracket)
            }
        }
        return nil
    }

    // MARK: - Tier B: path slashes

    /// Merge `<a> slash <b>` into `a/b`, but only where the utterance looks
    /// like it is about a path.
    private static func applySlashRule(_ tokens: inout [Token], pathStitching: Bool) {
        guard pathStitching else { return }

        var index = 0
        while index < tokens.count {
            guard let commandLength = slashCommandLength(tokens, at: index),
                  slashRuleApplies(tokens, at: index, commandLength: commandLength) else {
                index += 1
                continue
            }

            let leftIndex = index - 1
            let rightIndex = index + commandLength
            guard leftIndex >= 0, rightIndex < tokens.count,
                  !tokens[rightIndex].isProtected else {
                index += 1
                continue
            }

            let (rightCore, rightSuffix) = splitTrailingPunctuation(tokens[rightIndex].text)
            guard !rightCore.isEmpty, rightCore.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" }) else {
                index += 1
                continue
            }

            // A path cue is a verb or preposition, not a path component:
            // "open slash utils" means `/utils`, not `open/utils`. Absorbing
            // the cue would glue an English word onto the path.
            let leftIsCue = pathCues.contains(core(of: tokens[leftIndex].text).lowercased())
            guard !leftIsCue else {
                let leading = "/" + rightCore + rightSuffix
                tokens.replaceSubrange(index...rightIndex, with: [Token(text: leading, isIdentifier: true)])
                index += 1
                continue
            }

            guard isPlainWordOrPath(tokens[leftIndex]) else {
                index += 1
                continue
            }

            let merged = tokens[leftIndex].text + "/" + rightCore + rightSuffix
            tokens.replaceSubrange(leftIndex...rightIndex, with: [Token(text: merged, isIdentifier: true)])
            index = leftIndex + 1
        }
    }

    /// Length of a slash command at `index`, provided every word in the
    /// command is unprotected. This makes `forward literally slash` protect
    /// the complete two-word command rather than only its first token.
    private static func slashCommandLength(_ tokens: [Token], at index: Int) -> Int? {
        guard index < tokens.count, !tokens[index].isProtected else { return nil }
        let word = core(of: tokens[index].text).lowercased()
        if word == "slash" { return 1 }
        guard word == "forward", index + 1 < tokens.count,
              !tokens[index + 1].isProtected,
              core(of: tokens[index + 1].text).lowercased() == "slash" else {
            return nil
        }
        return 2
    }

    /// A token that can sit on either side of a path separator.
    private static func isPlainWordOrPath(_ token: Token) -> Bool {
        guard !token.isProtected, !token.text.isEmpty else { return false }
        return token.text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "/" }
    }

    /// Gate one slash command using only its immediate path run. Accepted
    /// evidence is an adjacent identifier, a cue immediately before the path,
    /// or another separator after the next component. Evidence elsewhere in
    /// the line is deliberately ignored.
    private static func slashRuleApplies(
        _ tokens: [Token],
        at index: Int,
        commandLength: Int
    ) -> Bool {
        let leftIndex = index - 1
        let rightIndex = index + commandLength
        guard leftIndex >= 0, rightIndex < tokens.count else { return false }

        if hasIdentifierSignal(tokens[leftIndex]) || hasIdentifierSignal(tokens[rightIndex]) {
            return true
        }

        let leftWord = core(of: tokens[leftIndex].text).lowercased()
        if pathCues.contains(leftWord) { return true }
        if leftIndex > 0,
           pathCues.contains(core(of: tokens[leftIndex - 1].text).lowercased()) {
            return true
        }

        // `src slash components slash button`: the first separator is proven
        // by the next one; after it merges, the produced path proves the next.
        return slashCommandLength(tokens, at: rightIndex + 1) != nil
    }

    // MARK: - Tier B: identifier joiners

    /// `user dot name` → `user.name`, only once the line is known to be about
    /// code immediately beside this joiner.
    private static func applyIdentifierDotRule(_ tokens: inout [Token]) {
        mergeAround(&tokens, commandWords: ["dot"], separator: ".")
    }

    /// Joiners extend a path or identifier produced next to them. They never
    /// inherit evidence from an unrelated token elsewhere in the utterance.
    private static func applyJoinerRule(_ tokens: inout [Token]) {
        mergeAround(&tokens, commandWords: ["underscore"], separator: "_")
        mergeAround(&tokens, commandWords: ["dash", "hyphen"], separator: "-")
    }

    /// Merge `<plain word> <command> <plain word>` into one token.
    private static func mergeAround(_ tokens: inout [Token], commandWords: [String], separator: String) {
        var index = 0
        while index < tokens.count {
            let word = core(of: tokens[index].text).lowercased()
            guard commandWords.contains(word),
                  !tokens[index].isProtected,
                  index > 0, index + 1 < tokens.count,
                  isPlainWordOrPath(tokens[index - 1]),
                  hasIdentifierSignal(tokens[index - 1])
                      || hasIdentifierSignal(tokens[index + 1]),
                  !tokens[index + 1].isProtected else {
                index += 1
                continue
            }

            let (rightCore, rightSuffix) = splitTrailingPunctuation(tokens[index + 1].text)
            guard !rightCore.isEmpty,
                  rightCore.allSatisfy({ $0.isLetter || $0.isNumber }) else {
                index += 1
                continue
            }

            let merged = tokens[index - 1].text + separator + rightCore + rightSuffix
            tokens.replaceSubrange((index - 1)...(index + 1), with: [Token(text: merged, isIdentifier: true)])
            index = max(index - 1, 0) + 1
        }
    }
}
