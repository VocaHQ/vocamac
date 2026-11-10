// AppState+TextDelivery.swift
// VocaMac
//
// Settings for how a dictation goes into the app — pasted or typed — and
// Auto Send (pressing Return after it), plus the per-dictation choice
// built from them. The rules themselves live in `TextDelivery`.

import Foundation

extension AppState {
    // MARK: - Settings

    var insertionMethod: InsertionMethod {
        get {
            UserDefaults.standard.string(forKey: PreferenceKey.insertionMethod)
                .flatMap(InsertionMethod.init(rawValue:)) ?? .defaultMethod
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: PreferenceKey.insertionMethod)
            objectWillChange.send()
        }
    }

    /// Apps whose dictations are always typed, whatever `insertionMethod` says.
    var typedInsertionApps: [AutoPauseAppEntry] {
        get { AppListCoding.decode(UserDefaults.standard.string(forKey: PreferenceKey.typedInsertionApps)) }
        set {
            UserDefaults.standard.set(AppListCoding.encode(newValue), forKey: PreferenceKey.typedInsertionApps)
            objectWillChange.send()
        }
    }

    var autoSendMode: AutoSendMode {
        get {
            UserDefaults.standard.string(forKey: PreferenceKey.autoSendMode)
                .flatMap(AutoSendMode.init(rawValue:)) ?? .defaultMode
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: PreferenceKey.autoSendMode)
            objectWillChange.send()
        }
    }

    /// Terminals and code editors where Auto Send may still press Return.
    var autoSendApps: [AutoPauseAppEntry] {
        get { AppListCoding.decode(UserDefaults.standard.string(forKey: PreferenceKey.autoSendApps)) }
        set {
            UserDefaults.standard.set(AppListCoding.encode(newValue), forKey: PreferenceKey.autoSendApps)
            objectWillChange.send()
        }
    }

    // MARK: - Per dictation

    /// How this dictation is delivered, and the text to deliver.
    ///
    /// - Parameters:
    ///   - spoken: What the engine heard. Only these words can ask for
    ///     Return; the final text has been through cleanup.
    ///   - text: The text about to be inserted.
    ///   - app: The app it goes to.
    ///   - isCodeOrTerminal: Whether that app is a terminal, code editor or
    ///     coding agent, where Return runs or breaks something.
    static func textDelivery(
        spoken: String, text: String, app: RunningAppSnapshot?, isCodeOrTerminal: Bool,
        method: InsertionMethod, typingApps: [AutoPauseAppEntry],
        autoSendMode: AutoSendMode, autoSendApps: [AutoPauseAppEntry]
    ) -> (text: String, options: TextDeliveryOptions) {
        var options = TextDeliveryOptions.standard
        options.typesText = TextDeliveryPlan.typesText(method: method, app: app, typingApps: typingApps)
        let allowed = TextDeliveryPlan.autoSendAllowed(
            in: app, isCodeOrTerminal: isCodeOrTerminal, autoSendApps: autoSendApps
        )
        // Where Return may not be pressed, no line-break key may be either:
        // multiline text there is pasted (a bracketed paste stays inert in a
        // terminal), never typed, whatever the Auto Send mode.
        if !allowed {
            options.typesLineBreaks = false
            if text.contains(where: \.isNewline) {
                options.typesText = false
                options.typesWhenPasteFails = false
            }
        }
        guard autoSendMode != .off, allowed else { return (text, options) }

        // The cue counts only when the engine heard it as its own sentence
        // and it is still at the end of the text, where it can be removed.
        // When cleanup moved or reworded it, nothing is sent.
        let stripped = AutoSendCue.endsWithCue(spoken) ? AutoSendCue.removingCue(from: text) : nil
        let delivered = stripped ?? text
        // Return with no text is only for a spoken cue: "after every
        // dictation" must not send a draft when cleanup removed everything
        // (a lone "um").
        let hasText = !delivered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        options.pressesReturn = TextDeliveryPlan.pressesReturn(
            mode: autoSendMode, cueSpoken: stripped != nil, allowedHere: hasText || stripped != nil
        )
        return (delivered, options)
    }

    /// Whether `app` is a terminal, code editor or coding agent: by its
    /// bundle identifier (`TextDeliveryPlan.isCodingAgentApp`), the user's
    /// style rules, the built-in app catalog, or a coding agent running in
    /// a terminal.
    static func isCodeOrTerminal(_ app: RunningAppSnapshot?, resolved: ResolvedWritingStyle) -> Bool {
        if resolved.codingAgent || TextDeliveryPlan.isCodingAgentApp(app) { return true }
        if [.code, .terminal].contains(resolved.style) { return true }
        guard let app, let known = WritingStyleCatalog.suggestion(matching: app) else { return false }
        return known.style == .code || known.style == .terminal
    }
}
