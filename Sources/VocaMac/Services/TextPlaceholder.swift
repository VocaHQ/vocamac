// TextPlaceholder.swift
// VocaMac
//
// Single-character stand-ins for text that must survive formatting untouched.
//
// Snippet expansions are literal text the user authored: a signature block, an
// email address, a code fragment. Writing styles reshape whole utterances —
// sentence case, symbol substitution, filler trimming — and none of that may
// run over an expansion. Masking each expansion as one private-use scalar lets
// styling run on the surrounding sentence while the expansion travels through
// the pipeline as an opaque token, then comes back verbatim.
//
// Expanding *before* styling is what makes triggers reliable: they are matched
// against the raw transcript, so a style that trims a leading "so" or joins
// "dot" to the next word cannot break a trigger before it is seen.

import Foundation

/// Private-use scalars reserved for masked spans.
///
/// Two lanes, so two independent maskings can coexist in one string: the
/// snippet lane is allocated by the caller before styling, the identifier lane
/// by the style engine during it. Each restores only its own scalars.
enum TextPlaceholder {
    /// Start of the Unicode Private Use Area. Speech engines never emit these.
    static let firstScalar: UInt32 = 0xE000
    /// End of the BMP Private Use Area.
    static let lastScalar: UInt32 = 0xF8FF

    /// First scalar of the snippet-expansion lane.
    static let snippetBase: UInt32 = 0xE000
    /// First scalar of the writing-style identifier lane.
    static let identifierBase: UInt32 = 0xE800

    /// How many masks one lane can hold. Far beyond any real transcript.
    static func capacity(base: UInt32) -> Int {
        let ceiling = base < identifierBase ? identifierBase : lastScalar + 1
        return Int(ceiling - base)
    }

    /// The placeholder character for the nth masked span in a lane.
    static func character(at index: Int, base: UInt32 = snippetBase) -> Character? {
        guard index >= 0, index < capacity(base: base),
              let scalar = UnicodeScalar(base + UInt32(index)) else { return nil }
        return Character(scalar)
    }

    /// Whether a character is a mask from any lane.
    static func isPlaceholder(_ character: Character) -> Bool {
        guard let scalar = singleScalar(character) else { return false }
        return scalar >= firstScalar && scalar <= lastScalar
    }

    /// Whether any character in the string is a mask.
    static func containsPlaceholder(_ text: String) -> Bool {
        text.contains { isPlaceholder($0) }
    }

    /// The mask index a character carries within `base`'s lane, if any.
    static func index(of character: Character, base: UInt32) -> Int? {
        guard let scalar = singleScalar(character), scalar >= base else { return nil }
        let offset = Int(scalar - base)
        guard offset < capacity(base: base) else { return nil }
        return offset
    }

    private static func singleScalar(_ character: Character) -> UInt32? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first else { return nil }
        return scalar.value
    }
}

/// Text with its protected spans masked, plus the originals to restore.
struct MaskedText: Equatable {
    /// The text with each protected span replaced by one placeholder scalar.
    var text: String
    /// Replacement text, indexed the same way `TextPlaceholder.character(at:)` is.
    var replacements: [String]
    /// The lane these masks were allocated from.
    var base: UInt32

    init(text: String, replacements: [String] = [], base: UInt32 = TextPlaceholder.snippetBase) {
        self.text = text
        self.replacements = replacements
        self.base = base
    }

    /// Whether anything was masked at all.
    var isEmpty: Bool { replacements.isEmpty }

    /// Put this lane's original spans back into `formatted`.
    ///
    /// Takes the formatted string rather than `text` because the whole point is
    /// to restore *after* the formatting passes have run. A placeholder that
    /// formatting dropped simply does not come back; placeholders from another
    /// lane are passed through untouched.
    func restore(in formatted: String) -> String {
        guard !replacements.isEmpty else { return formatted }

        var result = ""
        result.reserveCapacity(formatted.count)
        // A replacement that already ends in whitespace swallows the space a
        // trailing-space rule appended after its mask: the rule skips text that
        // ends in whitespace, and the mask is what hid that from it.
        var swallowNextSpace = false

        for character in formatted {
            guard let index = TextPlaceholder.index(of: character, base: base),
                  index < replacements.count else {
                if swallowNextSpace, character == " " {
                    swallowNextSpace = false
                    continue
                }
                swallowNextSpace = false
                result.append(character)
                continue
            }
            let replacement = replacements[index]
            result += replacement
            swallowNextSpace = replacement.last?.isWhitespace == true
        }
        return result
    }
}
