#if canImport(FoundationModels)
import AppKit
import FoundationModels

@available(macOS 26.0, *)
final class TextCorrector {
    private var session: LanguageModelSession?

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

    var isAvailable: Bool {
        SystemLanguageModel.default.availability == .available
    }

    private static let refusalPrefixes = [
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

    private static let preamblePrefixes = [
        "here is the corrected text",
        "here is the polished text",
        "here's the corrected text",
        "here's the polished text",
        "corrected text",
        "polished text",
        "correction",
        "revised text",
        "here you go",
        "the corrected text is",
        "the polished text is",
        "here is your corrected",
        "cleaned up text",
    ]

    func correct(_ text: String) async -> String {
        guard isAvailable else {
            return text
        }
        do {
            // Rebuild instructions each time to capture the current frontmost app.
            let instructions = Self.buildInstructions()
            let currentSession = session ?? LanguageModelSession(instructions: instructions)
            session = currentSession
            let response = try await currentSession.respond(to: text)
            let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

            guard let cleaned = Self.sanitizedResponse(result, originalText: text),
                  !Self.shouldFallbackToOriginal(cleaned, originalText: text) else {
                return text
            }
            return cleaned
        } catch {
            // Reset session on failure so next attempt starts fresh
            session = nil
            return text
        }
    }

    func resetSession() {
        session = nil
    }

    private static func sanitizedResponse(_ result: String, originalText: String) -> String? {
        var trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        trimmed = stripPreamble(from: trimmed)

        if trimmed.first == "\"", trimmed.last == "\"", trimmed.count >= 2 {
            trimmed.removeFirst()
            trimmed.removeLast()
            trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return trimmed.isEmpty ? nil : trimmed
    }

    private static func shouldFallbackToOriginal(_ result: String, originalText: String) -> Bool {
        let lower = result.lowercased()
        let originalLower = originalText.lowercased()

        for prefix in refusalPrefixes {
            if lower.hasPrefix(prefix) && !originalLower.hasPrefix(prefix) {
                return true
            }
        }

        for prefix in preamblePrefixes {
            if lower.hasPrefix(prefix) {
                return true
            }
        }

        if result.count > originalText.count * 3 && result.count > 100 {
            return true
        }

        return false
    }

    private static func stripPreamble(from text: String) -> String {
        var trimmed = text
        let lower = trimmed.lowercased()
        for prefix in preamblePrefixes {
            if lower.hasPrefix(prefix) {
                let dropCount = prefix.count
                trimmed = String(trimmed.dropFirst(dropCount))
                trimmed = trimmed.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ":-—")))
                return trimmed
            }
        }
        return trimmed
    }

    private static func buildInstructions() -> String {
        var context = baseInstructions
        if let app = NSWorkspace.shared.frontmostApplication {
            let name = app.localizedName ?? "unknown app"
            context += " The user is currently typing in \(name)."
        }
        return context
    }
}
#endif
