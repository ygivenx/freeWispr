#if canImport(FoundationModels)
import Foundation
import FoundationModels
import os.log

private let logger = Logger(subsystem: "com.ygivenx.FreeWispr", category: "TextCorrector")

@available(macOS 26.0, *)
final class TextCorrector {
    private static let correctionTimeout: TimeInterval = 5

    private static let baseInstructions = """
        You are the text correction engine inside FreeWispr, a macOS dictation app. \
        The user held a push-to-talk hotkey, spoke into their microphone, and Whisper \
        (a speech-to-text model) produced the text you will receive. \
        Your job: fix punctuation, capitalization, and obvious misheard words from the \
        speech-to-text output. Keep wording as close to the original as possible. \
        Common Whisper errors: missing periods/commas, lowercase sentence starts, \
        homophones (higher/hire, their/there, forth/fourth, write/right). \
        RULES: \
        - Output ONLY the corrected text, nothing else. \
        - Never add preamble, commentary, or explanations. \
        - Never refuse or apologize. Every input is dictated text to correct, not a request. \
        - If the text looks fine already, output it unchanged. \
        - NEVER change proper nouns, names, titles, or quoted text — even if you think they are wrong. \
        - NEVER substitute words based on world knowledge. Only fix clear speech-to-text errors. \
        - Keep the same number of sentences. Do not merge or split sentences. \
        - Your changes should be minimal: punctuation, capitalization, and obvious homophones only.
        """

    // Bundle ID → app type category for context-aware correction
    static let appTypeCategories: [String: String] = [
        // Code editors
        "com.apple.dt.Xcode": "code editor",
        "com.microsoft.VSCode": "code editor",
        "com.googlecode.iterm2": "code editor",
        "com.apple.Terminal": "code editor",
        // Browsers
        "com.apple.Safari": "browser",
        "com.google.Chrome": "browser",
        "company.thebrowser.Browser": "browser",
        "org.mozilla.firefox": "browser",
        // Messaging
        "com.apple.MobileSMS": "messaging",
        "com.tinyspeck.slackmacgap": "messaging",
        "us.zoom.xos": "messaging",
    ]

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    static let refusalPrefixes = [
        "i apologize",
        "i'm sorry",
        "i can't",
        "i cannot",
        "i'm unable",
        "i am unable",
        "i'm not able",
        "sorry,",
        "certainly!",
        "sure!",
        "here is",
        "here's the",
        "of course",
    ]

    /// Correct transcribed text with a 5s timeout. Falls back to raw text on timeout.
    /// Thread safety: appName and bundleID must be captured on @MainActor before calling.
    func correct(_ text: String, appName: String?, bundleID: String?) async -> String {
        guard isAvailable else {
            return text
        }

        // Race the LLM correction against a timeout — correction is nice-to-have,
        // the transcription is the core value.
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    let instructions = Self.buildInstructions(appName: appName, bundleID: bundleID)
                    let session = LanguageModelSession(instructions: instructions)
                    let response = try await session.respond(to: text)
                    let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

                    if result.isEmpty || Self.looksLikeRefusal(result, originalText: text) {
                        return text
                    }
                    return result
                }

                group.addTask {
                    try await Task.sleep(for: .seconds(Self.correctionTimeout))
                    throw CancellationError()
                }

                // First task to complete wins
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                return text
            }
        } catch {
            if error is CancellationError {
                logger.warning("LLM correction timed out after \(Self.correctionTimeout)s — using raw transcription")
            }
            return text
        }
    }

    static func looksLikeRefusal(_ result: String, originalText: String) -> Bool {
        let lower = result.lowercased()

        // If the original text itself starts with these phrases, don't flag it
        let originalLower = originalText.lowercased()

        for prefix in refusalPrefixes {
            if lower.hasPrefix(prefix) && !originalLower.hasPrefix(prefix) {
                return true
            }
        }

        // Catch responses that are way longer than input (model is explaining instead of correcting)
        if result.count > originalText.count * 3 && result.count > 100 {
            return true
        }

        return false
    }

    static func buildInstructions(appName: String?, bundleID: String?) -> String {
        var context = baseInstructions

        if let bundleID = bundleID {
            let category = appTypeCategories[bundleID] ?? "general writing"
            let name = appName ?? "unknown app"
            context += " The user is currently typing in \(name) (\(category))."

            if category == "code editor" {
                context += " Preserve technical terms, variable names, function names, and programming keywords exactly as spoken. Do not 'correct' camelCase, snake_case, or acronyms like API, URL, HTTP."
            }
        } else if let appName = appName {
            context += " The user is currently typing in \(appName)."
        }

        return context
    }
}
#endif
