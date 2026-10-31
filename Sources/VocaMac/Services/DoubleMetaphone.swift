// DoubleMetaphone.swift
// VocaMac
//
// Lawrence Philips' Double Metaphone: a phonetic key for English words and
// names, with an alternate key for the ones that have two common sounds
// ("Schmidt" X/S). Ported from the Apache Commons Codec version.
//
// `DictionaryCorrector` uses it to tell a misheard spelling of a Dictionary
// term from an unrelated word: "Kubernetes" and "cooper netties" share the
// key KPRNTS, while "cloud" (KLT) never matches "cloud computing".

import Foundation

enum DoubleMetaphone {

    struct Key: Equatable {
        let primary: String
        let alternate: String

        /// Whether the two words can sound alike: any key of one equals any
        /// key of the other.
        func matches(_ other: Key) -> Bool {
            primary == other.primary || primary == other.alternate
                || alternate == other.primary || alternate == other.alternate
        }
    }

    /// The keys of `word`, or nil when it isn't plain ASCII letters (the
    /// rules are for English spelling) or has no consonant to key on.
    /// `maxLength` caps each key; whole terms are compared, so the default is
    /// longer than the classic four.
    static func encode(_ word: String, maxLength: Int = 12) -> Key? {
        guard !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var encoder = Encoder(Array(word.uppercased()), maxLength: maxLength)
        encoder.run()
        guard !encoder.primary.isEmpty else { return nil }
        return Key(primary: encoder.primary, alternate: encoder.alternate)
    }

    // MARK: - Encoder

    private struct Encoder {
        let value: [Character]
        let maxLength: Int
        let slavoGermanic: Bool
        var primary = ""
        var alternate = ""

        init(_ value: [Character], maxLength: Int) {
            self.value = value
            self.maxLength = maxLength
            let text = String(value)
            slavoGermanic = text.contains("W") || text.contains("K") || text.contains("CZ") || text.contains("WITZ")
        }

        private var isComplete: Bool { primary.count >= maxLength && alternate.count >= maxLength }

        private func char(_ index: Int) -> Character {
            index >= 0 && index < value.count ? value[index] : "\0"
        }

        private func isVowel(_ index: Int) -> Bool { "AEIOUY".contains(char(index)) }

        private func contains(_ start: Int, _ length: Int, _ options: String...) -> Bool {
            guard start >= 0, start + length <= value.count else { return false }
            let slice = String(value[start..<(start + length)])
            return options.contains(slice)
        }

        private mutating func add(_ main: String, _ other: String? = nil) {
            if primary.count < maxLength { primary += main.prefix(maxLength - primary.count) }
            let other = other ?? main
            if alternate.count < maxLength { alternate += other.prefix(maxLength - alternate.count) }
        }

        private mutating func addPrimary(_ text: String) {
            if primary.count < maxLength { primary += text.prefix(maxLength - primary.count) }
        }

        private mutating func addAlternate(_ text: String) {
            if alternate.count < maxLength { alternate += text.prefix(maxLength - alternate.count) }
        }

        mutating func run() {
            var index = 0
            if contains(0, 2, "GN", "KN", "PN", "WR", "PS") { index = 1 }
            if char(0) == "X" {
                add("S")
                index = 1
            }
            while !isComplete, index < value.count {
                index = step(at: index)
            }
        }

        private mutating func step(at index: Int) -> Int {
            switch char(index) {
            case "A", "E", "I", "O", "U", "Y":
                if index == 0 { add("A") }
                return index + 1
            case "B":
                add("P")
                return char(index + 1) == "B" ? index + 2 : index + 1
            case "C": return handleC(index)
            case "D": return handleD(index)
            case "F":
                add("F")
                return char(index + 1) == "F" ? index + 2 : index + 1
            case "G": return handleG(index)
            case "H": return handleH(index)
            case "J": return handleJ(index)
            case "K":
                add("K")
                return char(index + 1) == "K" ? index + 2 : index + 1
            case "L": return handleL(index)
            case "M":
                add("M")
                return conditionM0(index) ? index + 2 : index + 1
            case "N":
                add("N")
                return char(index + 1) == "N" ? index + 2 : index + 1
            case "P":
                if char(index + 1) == "H" {
                    add("F")
                    return index + 2
                }
                add("P")
                return contains(index + 1, 1, "P", "B") ? index + 2 : index + 1
            case "Q":
                add("K")
                return char(index + 1) == "Q" ? index + 2 : index + 1
            case "R": return handleR(index)
            case "S": return handleS(index)
            case "T": return handleT(index)
            case "V":
                add("F")
                return char(index + 1) == "V" ? index + 2 : index + 1
            case "W": return handleW(index)
            case "X": return handleX(index)
            case "Z": return handleZ(index)
            default: return index + 1
            }
        }

        // MARK: C

        private mutating func handleC(_ index: Int) -> Int {
            if conditionC0(index) {
                add("K")
                return index + 2
            }
            if index == 0, contains(index, 6, "CAESAR") {
                add("S")
                return index + 2
            }
            if contains(index, 2, "CH") { return handleCH(index) }
            if contains(index, 2, "CZ"), !contains(index - 2, 4, "WICZ") {
                add("S", "X")
                return index + 2
            }
            if contains(index + 1, 3, "CIA") {
                add("X")
                return index + 3
            }
            if contains(index, 2, "CC"), !(index == 1 && char(0) == "M") { return handleCC(index) }
            if contains(index, 2, "CK", "CG", "CQ") {
                add("K")
                return index + 2
            }
            if contains(index, 2, "CI", "CE", "CY") {
                if contains(index, 3, "CIO", "CIE", "CIA") { add("S", "X") } else { add("S") }
                return index + 2
            }
            add("K")
            if contains(index + 1, 2, " C", " Q", " G") { return index + 3 }
            if contains(index + 1, 1, "C", "K", "Q"), !contains(index + 1, 2, "CE", "CI") { return index + 2 }
            return index + 1
        }

        private func conditionC0(_ index: Int) -> Bool {
            if contains(index, 4, "CHIA") { return true }
            if index <= 1 || isVowel(index - 2) || !contains(index - 1, 3, "ACH") { return false }
            let next = char(index + 2)
            return (next != "I" && next != "E") || contains(index - 2, 6, "BACHER", "MACHER")
        }

        private mutating func handleCC(_ index: Int) -> Int {
            if contains(index + 2, 1, "I", "E", "H"), !contains(index + 2, 2, "HU") {
                if (index == 1 && char(index - 1) == "A") || contains(index - 1, 5, "UCCEE", "UCCES") {
                    add("KS")
                } else {
                    add("X")
                }
                return index + 3
            }
            add("K")
            return index + 2
        }

        private mutating func handleCH(_ index: Int) -> Int {
            if index > 0, contains(index, 4, "CHAE") {
                add("K", "X")
            } else if conditionCH0(index) || conditionCH1(index) {
                add("K")
            } else if index > 0 {
                if contains(0, 2, "MC") { add("K") } else { add("X", "K") }
            } else {
                add("X")
            }
            return index + 2
        }

        private func conditionCH0(_ index: Int) -> Bool {
            guard index == 0 else { return false }
            guard contains(index + 1, 5, "HARAC", "HARIS") || contains(index + 1, 3, "HOR", "HYM", "HIA", "HEM")
            else { return false }
            return !contains(0, 5, "CHORE")
        }

        private func conditionCH1(_ index: Int) -> Bool {
            if contains(0, 4, "VAN ", "VON ") || contains(0, 3, "SCH") { return true }
            if contains(index - 2, 6, "ORCHES", "ARCHIT", "ORCHID") || contains(index + 2, 1, "T", "S") { return true }
            let before = contains(index - 1, 1, "A", "O", "U", "E") || index == 0
            let after = contains(index + 2, 1, "L", "R", "N", "M", "B", "H", "F", "V", "W", " ")
                || index + 1 == value.count - 1
            return before && after
        }

        // MARK: D, G, H, J, L, M

        private mutating func handleD(_ index: Int) -> Int {
            if contains(index, 2, "DG") {
                if contains(index + 2, 1, "I", "E", "Y") {
                    add("J")
                    return index + 3
                }
                add("TK")
                return index + 2
            }
            add("T")
            return contains(index, 2, "DT", "DD") ? index + 2 : index + 1
        }

        private mutating func handleG(_ index: Int) -> Int {
            let next = char(index + 1)
            if next == "H" { return handleGH(index) }
            if next == "N" {
                if index == 1, isVowel(0), !slavoGermanic {
                    add("KN", "N")
                } else if !contains(index + 2, 2, "EY"), next != "Y", !slavoGermanic {
                    add("N", "KN")
                } else {
                    add("KN")
                }
                return index + 2
            }
            if contains(index + 1, 2, "LI"), !slavoGermanic {
                add("KL", "L")
                return index + 2
            }
            if index == 0, next == "Y" || contains(
                index + 1, 2, "ES", "EP", "EB", "EL", "EY", "IB", "IL", "IN", "IE", "EI", "ER"
            ) {
                add("K", "J")
                return index + 2
            }
            if contains(index + 1, 2, "ER") || next == "Y",
               !contains(0, 6, "DANGER", "RANGER", "MANGER"),
               !contains(index - 1, 1, "E", "I"), !contains(index - 1, 3, "RGY", "OGY") {
                add("K", "J")
                return index + 2
            }
            if contains(index + 1, 1, "E", "I", "Y") || contains(index - 1, 4, "AGGI", "OGGI") {
                if contains(0, 4, "VAN ", "VON ") || contains(0, 3, "SCH") || contains(index + 1, 2, "ET") {
                    add("K")
                } else if contains(index + 1, 3, "IER") {
                    add("J")
                } else {
                    add("J", "K")
                }
                return index + 2
            }
            add("K")
            return next == "G" ? index + 2 : index + 1
        }

        private mutating func handleGH(_ index: Int) -> Int {
            if index > 0, !isVowel(index - 1) {
                add("K")
                return index + 2
            }
            if index == 0 {
                add(char(index + 2) == "I" ? "J" : "K")
                return index + 2
            }
            if (index > 1 && contains(index - 2, 1, "B", "H", "D"))
                || (index > 2 && contains(index - 3, 1, "B", "H", "D"))
                || (index > 3 && contains(index - 4, 1, "B", "H")) {
                return index + 2
            }
            if index > 2, char(index - 1) == "U", contains(index - 3, 1, "C", "G", "L", "R", "T") {
                add("F")
            } else if index > 0, char(index - 1) != "I" {
                add("K")
            }
            return index + 2
        }

        private mutating func handleH(_ index: Int) -> Int {
            if index == 0 || isVowel(index - 1), isVowel(index + 1) {
                add("H")
                return index + 2
            }
            return index + 1
        }

        private mutating func handleJ(_ index: Int) -> Int {
            if contains(index, 4, "JOSE") || contains(0, 4, "SAN ") {
                if (index == 0 && char(index + 4) == " ") || value.count == 4 || contains(0, 4, "SAN ") {
                    add("H")
                } else {
                    add("J", "H")
                }
                return index + 1
            }
            if index == 0, !contains(index, 4, "JOSE") {
                add("J", "A")
            } else if isVowel(index - 1), !slavoGermanic, char(index + 1) == "A" || char(index + 1) == "O" {
                add("J", "H")
            } else if index == value.count - 1 {
                addPrimary("J")
            } else if !contains(index + 1, 1, "L", "T", "K", "S", "N", "M", "B", "Z"),
                      !contains(index - 1, 1, "S", "K", "L") {
                add("J")
            }
            return char(index + 1) == "J" ? index + 2 : index + 1
        }

        private mutating func handleL(_ index: Int) -> Int {
            guard char(index + 1) == "L" else {
                add("L")
                return index + 1
            }
            if conditionL0(index) { addPrimary("L") } else { add("L") }
            return index + 2
        }

        private func conditionL0(_ index: Int) -> Bool {
            if index == value.count - 3, contains(index - 1, 4, "ILLO", "ILLA", "ALLE") { return true }
            return (contains(value.count - 2, 2, "AS", "OS") || contains(value.count - 1, 1, "A", "O"))
                && contains(index - 1, 4, "ALLE")
        }

        private func conditionM0(_ index: Int) -> Bool {
            if char(index + 1) == "M" { return true }
            return contains(index - 1, 3, "UMB") && (index + 1 == value.count - 1 || contains(index + 2, 2, "ER"))
        }

        // MARK: R, S, T, W, X, Z

        private mutating func handleR(_ index: Int) -> Int {
            if index == value.count - 1, !slavoGermanic, contains(index - 2, 2, "IE"),
               !contains(index - 4, 2, "ME", "MA") {
                addAlternate("R")
            } else {
                add("R")
            }
            return char(index + 1) == "R" ? index + 2 : index + 1
        }

        private mutating func handleS(_ index: Int) -> Int {
            if contains(index - 1, 3, "ISL", "YSL") { return index + 1 }
            if index == 0, contains(index, 5, "SUGAR") {
                add("X", "S")
                return index + 1
            }
            if contains(index, 2, "SH") {
                add(contains(index + 1, 4, "HEIM", "HOEK", "HOLM", "HOLZ") ? "S" : "X")
                return index + 2
            }
            if contains(index, 3, "SIO", "SIA") || contains(index, 4, "SIAN") {
                if slavoGermanic { add("S") } else { add("S", "X") }
                return index + 3
            }
            if (index == 0 && contains(index + 1, 1, "M", "N", "L", "W")) || contains(index + 1, 1, "Z") {
                add("S", "X")
                return contains(index + 1, 1, "Z") ? index + 2 : index + 1
            }
            if contains(index, 2, "SC") { return handleSC(index) }
            if index == value.count - 1, contains(index - 2, 2, "AI", "OI") {
                addAlternate("S")
            } else {
                add("S")
            }
            return contains(index + 1, 1, "S", "Z") ? index + 2 : index + 1
        }

        private mutating func handleSC(_ index: Int) -> Int {
            if char(index + 2) == "H" {
                if contains(index + 3, 2, "OO", "ER", "EN", "UY", "ED", "EM") {
                    if contains(index + 3, 2, "ER", "EN") { add("X", "SK") } else { add("SK") }
                } else if index == 0, !isVowel(3), char(3) != "W" {
                    add("X", "S")
                } else {
                    add("X")
                }
            } else if contains(index + 2, 1, "I", "E", "Y") {
                add("S")
            } else {
                add("SK")
            }
            return index + 3
        }

        private mutating func handleT(_ index: Int) -> Int {
            if contains(index, 4, "TION") || contains(index, 3, "TIA", "TCH") {
                add("X")
                return index + 3
            }
            if contains(index, 2, "TH") || contains(index, 3, "TTH") {
                if contains(index + 2, 2, "OM", "AM") || contains(0, 4, "VAN ", "VON ") || contains(0, 3, "SCH") {
                    add("T")
                } else {
                    add("0", "T")
                }
                return index + 2
            }
            add("T")
            return contains(index + 1, 1, "T", "D") ? index + 2 : index + 1
        }

        private mutating func handleW(_ index: Int) -> Int {
            if contains(index, 2, "WR") {
                add("R")
                return index + 2
            }
            if index == 0, isVowel(index + 1) || contains(index, 2, "WH") {
                if isVowel(index + 1) { add("A", "F") } else { add("A") }
                return index + 1
            }
            if (index == value.count - 1 && isVowel(index - 1))
                || contains(index - 1, 5, "EWSKI", "EWSKY", "OWSKI", "OWSKY") || contains(0, 3, "SCH") {
                addAlternate("F")
                return index + 1
            }
            if contains(index, 4, "WICZ", "WITZ") {
                add("TS", "FX")
                return index + 4
            }
            return index + 1
        }

        private mutating func handleX(_ index: Int) -> Int {
            if index == 0 {
                add("S")
                return index + 1
            }
            let silentEnding = index == value.count - 1
                && (contains(index - 3, 3, "IAU", "EAU") || contains(index - 2, 2, "AU", "OU"))
            if !silentEnding { add("KS") }
            return contains(index + 1, 1, "C", "X") ? index + 2 : index + 1
        }

        private mutating func handleZ(_ index: Int) -> Int {
            if char(index + 1) == "H" {
                add("J")
                return index + 2
            }
            if contains(index + 1, 2, "ZO", "ZI", "ZA") || (slavoGermanic && index > 0 && char(index - 1) != "T") {
                add("S", "TS")
            } else {
                add("S")
            }
            return char(index + 1) == "Z" ? index + 2 : index + 1
        }
    }
}
