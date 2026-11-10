// HallucinationGuard.swift
// VocaMac
//
// Drops the stock phrases a speech model writes over audio with no speech
// in it ("Thank you.", "Thanks for watching!"), when nothing says the
// recording held speech.
//
// Whisper large-v3 writes text for about 40% of non-speech clips, and a
// quarter of that is "thank you"; Parakeet can invent a word on a recording
// of a single quiet one. Trimming silence (`SpeechActivityTrimmer`) removes
// most of the cause. What's left is the recording the detector was unsure
// of — speech-like frames, but no stretch of speech long enough to keep —
// and the recording it never checked (not loaded yet, Skip Silence off, too
// long), where the engine's own confidence or the input level has to say
// whether anyone spoke.

import Foundation

enum HallucinationGuard {

    /// What the voice activity detector said about the recording.
    enum Detector: Equatable, Sendable {
        /// It found a stretch of speech. Never touched.
        case confirmed
        /// It found speech-like frames but no stretch of speech.
        case unconfirmed
        /// It did not run, so it says nothing either way.
        case unchecked
    }

    /// Whole transcripts that are, far more often than not, a model's
    /// filler for silence or noise. Lowercased, letters and spaces only.
    static let phrases: Set<String> = [
        "thank you", "thank you very much", "thank you so much", "thanks for watching",
        "thank you for watching", "thanks for watching and see you next time", "thank you for listening",
        "please subscribe", "like and subscribe", "subscribe to my channel", "see you next time",
        "you", "bye", "bye bye", "so", "the end", "music", "applause", "silence",
        "subtitles by the amara org community", "transcribed by", "i'm sorry",
    ]

    /// The same filler in other languages, keyed by ISO 639-1 code: what
    /// Whisper writes over silence after training on subtitled video. Same
    /// normalization as `phrases`.
    static let phrasesByLanguage: [String: Set<String>] = [
        "de": [
            "vielen dank", "danke", "danke schön", "danke fürs zuschauen", "bis zum nächsten mal",
            "untertitel im auftrag des zdf", "untertitel im auftrag des zdf für funk",
            "untertitel der amara org community", "untertitelung des zdf",
        ],
        "es": [
            "gracias", "muchas gracias", "gracias por ver", "gracias por ver el video",
            "subtítulos realizados por la comunidad de amara org", "suscríbete", "hasta la próxima",
        ],
        "fr": [
            "merci", "merci beaucoup", "merci d'avoir regardé", "merci de votre attention",
            "sous-titres réalisés par la communauté d'amara org", "sous titres réalisés para la communauté d'amara org",
            "abonnez-vous", "à bientôt",
        ],
        "it": [
            "grazie", "grazie mille", "grazie per la visione", "grazie per l'attenzione",
            "sottotitoli creati dalla comunità amara org", "iscriviti al canale",
        ],
        "pt": [
            "obrigado", "obrigada", "muito obrigado", "obrigado por assistir",
            "legendas pela comunidade amara org", "inscreva-se",
        ],
        "nl": [
            "bedankt", "dank je wel", "bedankt voor het kijken",
            "ondertiteling door de amara org gemeenschap", "ondertiteld door de amara org gemeenschap",
        ],
        "ru": [
            "спасибо", "спасибо за просмотр", "продолжение следует", "субтитры сделал dimatorzok",
            "редактор субтитров а синецкая корректор а егорова",
        ],
        "pl": ["dziękuję", "dziękuję za uwagę", "napisy stworzone przez społeczność amara org"],
        "tr": ["teşekkürler", "teşekkür ederim", "izlediğiniz için teşekkürler"],
        "hi": ["धन्यवाद", "देखने के लिए धन्यवाद"],
        "ja": ["ご視聴ありがとうございました", "ありがとうございました", "おやすみなさい"],
        "zh": ["谢谢观看", "謝謝觀看", "谢谢", "謝謝", "字幕由amara org社区提供", "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目"],
        "ko": ["시청해주셔서 감사합니다", "감사합니다", "구독과 좋아요 부탁드립니다"],
    ]

    /// The phrases to check for `language`: English and that language's,
    /// or every language's when the engine named none.
    static func phrases(for language: String?) -> Set<String> {
        guard let code = DictationOutputPipeline.knownLanguage(language)?
            .split(separator: "-").first.map(String.init) else {
            return phrasesByLanguage.values.reduce(phrases) { $0.union($1) }
        }
        return phrases.union(phrasesByLanguage[code] ?? [])
    }

    /// Lowercased letters (and apostrophes and hyphens inside words), one
    /// space between words.
    static func key(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'-")).inverted)
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'-")) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Whether `text` is nothing but one of the stock phrases for `language`.
    static func isStockPhrase(_ text: String, language: String? = nil) -> Bool {
        let key = key(text)
        guard !key.isEmpty else { return false }
        let candidates = phrases(for: language)
        return candidates.contains(key) || candidates.contains(key.replacingOccurrences(of: "-", with: " "))
    }

    /// `text`, or nothing when the detector heard no speech in the recording
    /// (`speechUnconfirmed`) and the text is a stock phrase. A recording the
    /// detector found speech in is never touched, so a real "Thank you." or
    /// "Bye." always reaches the user.
    static func filter(_ text: String, speechUnconfirmed: Bool, language: String? = nil) -> String {
        filter(text, detector: speechUnconfirmed ? .unconfirmed : .confirmed, language: language)
    }

    /// `text`, or nothing when it is a stock phrase and nothing says the
    /// recording held speech: the detector heard none, or it did not run and
    /// the engine or the input level says no one spoke
    /// (`engineHeardNoSpeech`). Speech the detector confirmed is never touched.
    static func filter(
        _ text: String, detector: Detector, engineHeardNoSpeech: Bool = false, language: String? = nil
    ) -> String {
        switch detector {
        case .confirmed:
            return text
        case .unchecked where !engineHeardNoSpeech:
            return text
        case .unconfirmed, .unchecked:
            guard isStockPhrase(text, language: language) else { return text }
            VocaLogger.info(
                .general,
                "Dropped a likely hallucination (\(text.count) characters) from audio with no detected speech"
            )
            return ""
        }
    }
}
