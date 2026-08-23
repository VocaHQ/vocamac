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
        ["close", "backtick"]:    BracketToken(literal: "`", attaches: .toPrevious),
        ["backtick"]:             BracketToken(literal: "`", attaches: .none)
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
        guard !text.isEmpty else { return text }
        guard !tiers.isEmpty || caseCommandsEnabled else { return text }

        // Newline commands run before this pass, so operate per line and keep
        // the line structure intact.
        let lines = text.components(separatedBy: "\n")
        let transformed = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            return applyToLine(
                line,
                tiers: tiers,
                pathStitching: pathStitching,
                caseCommandsEnabled: caseCommandsEnabled
            )
        }
        return transformed.joined(separator: "\n")
    }

    private static func applyToLine(
        _ line: String,
        tiers: SpokenSymbolTiers,
        pathStitching: Bool,
        caseCommandsEnabled: Bool
    ) -> String {
        var tokens = tokenize(line)
        guard !tokens.isEmpty else { return line }

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

        return render(tokens)
    }

    // MARK: - Tokenizing

    /// Split on whitespace and consume the "literally" escape hatch.
    private static func tokenize(_ line: String) -> [Token] {
        let raw = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var tokens: [Token] = []
        var protectNext = false

        for word in raw {
            if core(of: word).lowercased() == "literally" {
                protectNext = true
                continue
            }
            tokens.append(Token(text: word, isProtected: protectNext))
            protectNext = false
        }
        return tokens
    }

    /// Reassemble tokens, honoring glue flags.
    private static func render(_ tokens: [Token]) -> String {
        var result = ""
        for (index, token) in tokens.enumerated() {
            if index > 0 && !token.glueLeft {
                result += " "
            }
            result += token.text
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

    private static func lineHasIdentifierSignal(_ tokens: [Token]) -> Bool {
        tokens.contains { $0.isIdentifier }
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
        for token in tokens where !token.isProtected {
            let lowered = core(of: token.text).lowercased()
            if gluedSymbolPrefixes.contains(where: { $0.word == lowered }) {
                occurrences += 1
            } else if !gluedSplitDenylist.contains(lowered),
                      gluedSymbolPrefixes.contains(where: { lowered.hasPrefix($0.word) && lowered.count > $0.word.count }) {
                occurrences += 1
            }
            if pathCues.contains(lowered) {
                return true
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
                  isPlainWord(tokens[wordsEnd]) {
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
            let nameWords = tokens[nameStart..<index].map { $0.text.lowercased() }
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
        guard slashRuleApplies(tokens) else { return }

        var index = 0
        while index < tokens.count {
            let word = core(of: tokens[index].text).lowercased()
            guard word == "slash" || word == "forward" && isFollowedBySlash(tokens, at: index) else {
                index += 1
                continue
            }

            // "forward slash" spans two tokens.
            let commandLength = (word == "forward") ? 2 : 1
            let leftIndex = index - 1
            let rightIndex = index + commandLength
            guard leftIndex >= 0, rightIndex < tokens.count,
                  !tokens[index].isProtected,
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
                let leading = "/" + rightCore.lowercased() + rightSuffix
                tokens.replaceSubrange(index...rightIndex, with: [Token(text: leading, isIdentifier: true)])
                index += 1
                continue
            }

            guard isPlainWordOrPath(tokens[leftIndex]) else {
                index += 1
                continue
            }

            let merged = tokens[leftIndex].text.lowercased() + "/" + rightCore.lowercased() + rightSuffix
            tokens.replaceSubrange(leftIndex...rightIndex, with: [Token(text: merged, isIdentifier: true)])
            index = leftIndex + 1
        }
    }

    private static func isFollowedBySlash(_ tokens: [Token], at index: Int) -> Bool {
        guard index + 1 < tokens.count else { return false }
        return core(of: tokens[index + 1].text).lowercased() == "slash"
    }

    /// A token that can sit on either side of a path separator.
    private static func isPlainWordOrPath(_ token: Token) -> Bool {
        guard !token.isProtected, !token.text.isEmpty else { return false }
        return token.text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-" || $0 == "/" }
    }

    /// Gate for the slash rule: two or more slashes, a path cue, or a filename
    /// already produced by Tier A.
    private static func slashRuleApplies(_ tokens: [Token]) -> Bool {
        let slashCount = tokens.filter { core(of: $0.text).lowercased() == "slash" && !$0.isProtected }.count
        guard slashCount > 0 else { return false }
        if slashCount >= 2 { return true }
        if lineHasIdentifierSignal(tokens) { return true }
        return tokens.contains { pathCues.contains(core(of: $0.text).lowercased()) }
    }

    // MARK: - Tier B: identifier joiners

    /// `user dot name` → `user.name`, only once the line is known to be about
    /// code (a filename, path, or case command already fired).
    private static func applyIdentifierDotRule(_ tokens: inout [Token]) {
        guard lineHasIdentifierSignal(tokens) else { return }
        mergeAround(&tokens, commandWords: ["dot"], separator: ".")
    }

    /// `max underscore retries` → `max_retries`, same gating as above.
    private static func applyJoinerRule(_ tokens: inout [Token]) {
        guard lineHasIdentifierSignal(tokens) else { return }
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

            let merged = tokens[index - 1].text + separator + rightCore.lowercased() + rightSuffix
            tokens.replaceSubrange((index - 1)...(index + 1), with: [Token(text: merged, isIdentifier: true)])
            index = max(index - 1, 0) + 1
        }
    }
}
