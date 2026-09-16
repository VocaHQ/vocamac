import Foundation

/// Minimal English grammar edits supported by Grammar cleanup. These rules
/// qualify a model proposal; they never generate or infer missing content.
enum CleanupGrammar {
    static func accepts(
        removed: [String], added: [String], preceding: [String], following: [String],
        isKnownWord: (String) -> Bool
    ) -> Bool {
        guard let previous = preceding.last else { return false }
        if removed.count == 1, added.count == 1 {
            // Without a parser, a trailing pronoun is not proof of the whole
            // subject: "he and she", "neither he nor she", and quoted or
            // embedded clauses need more context. Qualify only a standalone
            // sentence-initial pronoun; ambiguous agreement stays as spoken.
            guard preceding.count == 1 else { return false }
            let before = removed[0], after = added[0]
            let singular = ["he", "she", "it"].contains(previous)
            let plural = ["we", "you", "they"].contains(previous)
            guard singular || plural || previous == "i" else { return false }
            // Keep present/past distinct. Agreement cannot introduce a tense.
            for forms in [["am", "is", "are"], ["was", "were"], ["has", "have"], ["does", "do"],
                          ["isn't", "aren't"], ["wasn't", "weren't"], ["hasn't", "haven't"], ["doesn't", "don't"]] {
                if forms.contains(before), forms.contains(after) {
                    let expected: String
                    switch forms[0] {
                    case "am": expected = previous == "i" ? "am" : singular ? "is" : "are"
                    case "was": expected = singular || previous == "i" ? "was" : "were"
                    case "has": expected = singular ? "has" : "have"
                    case "isn't":
                        guard previous != "i" else { return false }
                        expected = singular ? "isn't" : "aren't"
                    case "wasn't": expected = singular || previous == "i" ? "wasn't" : "weren't"
                    case "hasn't": expected = singular ? "hasn't" : "haven't"
                    case "doesn't": expected = singular ? "doesn't" : "don't"
                    default: expected = singular ? "does" : "do"
                    }
                    return after == expected
                }
            }
            // A finite verb list avoids treating noun plurals as agreement
            // or "he rose" as a misspelling of "he rises".
            let verbs: [String: String] = [
                "go": "goes", "say": "says", "work": "works", "need": "needs",
                "want": "wants", "like": "likes", "make": "makes", "take": "takes",
                "use": "uses", "look": "looks", "know": "knows", "think": "thinks",
                "send": "sends", "write": "writes", "read": "reads", "run": "runs",
                "try": "tries", "study": "studies", "watch": "watches", "finish": "finishes",
            ]
            return singular ? verbs[before] == after : verbs[after] == before
        }
        guard removed.isEmpty, added.count == 1, let noun = following.first,
              isKnownWord(noun) else { return false }
        // Only common singular count nouns and explicit constructions. No
        // possessives, quantities, mass nouns, or article replacement.
        let countNouns: Set<String> = [
            "report", "document", "file", "meeting", "message", "question", "problem",
            "ticket", "book", "car", "computer", "proposal", "draft", "idea", "email",
        ]
        if ["a", "an"].contains(added[0]), countNouns.contains(noun),
           ["need", "needs", "want", "wants", "bought", "buy", "found", "have", "has", "send", "write"].contains(previous) {
            let vowel = noun.first.map { "aeiou".contains($0) } ?? false
            return added[0] == (vowel ? "an" : "a")
        }
        return added[0] == "the" && ["to", "at", "from"].contains(previous)
            && ["office", "store", "station", "airport"].contains(noun)
    }
}
