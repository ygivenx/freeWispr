import Foundation

/// Converts spoken shell commands ("cd dot dot slash src") into typed form ("cd ../src").
///
/// Conservative by design: the utterance must START with a known shell command,
/// otherwise `format` returns nil and the text is left untouched. This keeps prose
/// dictated into terminal AI tools (e.g. Claude Code) from being mangled.
///
/// Limitation: an utterance that starts with a symbol word ("dot slash build dot sh")
/// is not recognised as a command and is left alone.
enum TerminalCommandFormatter {
    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "net.kovidgoyal.kitty",
        "org.alacritty",
        "com.github.wez.wezterm",
        "co.zeit.hyper",
    ]

    // Words that commonly start English sentences (open, make, find, go, code, touch, ...) are
    // left out on purpose: prose dictated into terminal AI tools must never be reformatted.
    private static let commands: Set<String> = [
        "cd", "ls", "ll", "pwd", "git", "npm", "npx", "pnpm", "yarn", "brew",
        "python", "python3", "pip", "pip3", "uv", "uvx", "node", "swift",
        "cargo", "docker", "kubectl", "ssh", "scp", "cat", "grep", "rg",
        "mkdir", "rmdir", "rm", "mv", "cp", "chmod", "chown", "echo", "sudo",
        "vim", "nvim", "nano", "curl", "wget", "tar", "unzip", "pkill", "ps", "htop",
        "claude", "gh",
    ]

    /// How a symbol glues to its neighbours.
    private enum Glue {
        case both     // "." "/" "_" ":" "=" "@" "\\": attach to previous and next
        case prefix   // "-" "~" "$" "#" "*": space before, attach to next
        case spaced   // "|" "&&" ">" ...: spaces on both sides
        case quote    // opens like prefix, closes like a suffix
    }

    private struct Symbol { let text: String; let glue: Glue }

    // Multi-word phrases first (longest match wins).
    private static let phrases: [(words: [String], symbol: Symbol)] = [
        (["double", "greater", "than"], Symbol(text: ">>", glue: .spaced)),
        (["double", "ampersand"], Symbol(text: "&&", glue: .spaced)),
        (["and", "and"], Symbol(text: "&&", glue: .spaced)),
        (["forward", "slash"], Symbol(text: "/", glue: .both)),
        (["double", "dash"], Symbol(text: "--", glue: .prefix)),
        (["dash", "dash"], Symbol(text: "--", glue: .prefix)),
        (["greater", "than"], Symbol(text: ">", glue: .spaced)),
        (["less", "than"], Symbol(text: "<", glue: .spaced)),
        (["equal", "sign"], Symbol(text: "=", glue: .both)),
        (["dollar", "sign"], Symbol(text: "$", glue: .prefix)),
        (["at", "sign"], Symbol(text: "@", glue: .both)),
        (["double", "quote"], Symbol(text: "\"", glue: .quote)),
        (["single", "quote"], Symbol(text: "'", glue: .quote)),
        (["dot"], Symbol(text: ".", glue: .both)),
        (["period"], Symbol(text: ".", glue: .both)),
        (["slash"], Symbol(text: "/", glue: .both)),
        (["backslash"], Symbol(text: "\\", glue: .both)),
        (["dash"], Symbol(text: "-", glue: .prefix)),
        (["hyphen"], Symbol(text: "-", glue: .prefix)),
        (["minus"], Symbol(text: "-", glue: .prefix)),
        (["underscore"], Symbol(text: "_", glue: .both)),
        (["tilde"], Symbol(text: "~", glue: .prefix)),
        (["pipe"], Symbol(text: "|", glue: .spaced)),
        (["star"], Symbol(text: "*", glue: .prefix)),
        (["asterisk"], Symbol(text: "*", glue: .prefix)),
        (["equals"], Symbol(text: "=", glue: .both)),
        (["colon"], Symbol(text: ":", glue: .both)),
        (["hash"], Symbol(text: "#", glue: .prefix)),
        (["pound"], Symbol(text: "#", glue: .prefix)),
        (["ampersand"], Symbol(text: "&", glue: .spaced)),
        (["quote"], Symbol(text: "\"", glue: .quote)),
    ]

    private enum Piece {
        case command(String)
        case word(String)
        case symbol(Symbol, closingQuote: Bool)
    }

    /// Returns the formatted command, or nil when `text` is not a command.
    static func format(_ text: String) -> String? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, "!?".contains(last) { s.removeLast() }
        // Strip one sentence period, but keep literal dots ("cd ..", "cd..", "cd .").
        if s.hasSuffix("."), !s.hasSuffix(".."), let tail = s.split(whereSeparator: { $0.isWhitespace }).last, tail != "." {
            s.removeLast()
        }
        s = s.replacingOccurrences(of: ",", with: "")
        var tokens = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard let first = tokens.first else { return nil }

        // Recognizers may glue symbols to the command ("cd..", "cd~").
        let prefixLen = first.prefix(while: { $0.isLetter || $0.isNumber }).count
        let head = String(first.prefix(prefixLen)).lowercased()
        let rest = String(first.dropFirst(prefixLen))
        guard commands.contains(head),
              rest.allSatisfy({ "./~-_".contains($0) }) else { return nil }
        tokens.removeFirst()
        if !rest.isEmpty { tokens.insert(rest, at: 0) }

        var pieces: [Piece] = [.command(head)]
        var openQuote: String?
        var i = 0
        outer: while i < tokens.count {
            let lowered = tokens[i...].prefix(3).map { $0.lowercased() }
            for (words, sym) in phrases where lowered.count >= words.count && Array(lowered.prefix(words.count)) == words {
                var closing = false
                if sym.glue == .quote {
                    if openQuote == sym.text { openQuote = nil; closing = true } else { openQuote = sym.text }
                }
                pieces.append(.symbol(sym, closingQuote: closing))
                i += words.count
                continue outer
            }
            pieces.append(.word(tokens[i]))
            i += 1
        }

        var out = ""
        for (idx, piece) in pieces.enumerated() {
            let prev: Piece? = idx > 0 ? pieces[idx - 1] : nil
            let next: Piece? = idx + 1 < pieces.count ? pieces[idx + 1] : nil
            var attach = false
            switch piece {
            case .command:
                break
            case .word:
                if let prev, case .symbol(let sym, let closing) = prev {
                    attach = sym.glue == .both || sym.glue == .prefix || (sym.glue == .quote && !closing)
                }
            case .symbol(let sym, let closing):
                guard let prev else { break }
                if case .command = prev { break }   // never join onto the command word
                switch sym.glue {
                case .spaced, .prefix:
                    // Prefix symbols still glue after a symbol that expects a follower ("~/", "--").
                    if case .symbol(let p, _) = prev, sym.glue == .prefix, p.glue == .both || p.glue == .prefix { attach = true }
                case .both:
                    switch prev {
                    case .word:
                        // "add dot" -> "add ."; "main dot py" -> "main.py"
                        if sym.text == ".", !isWord(next) { attach = false } else { attach = true }
                    case .symbol(let p, let pClosing):
                        attach = p.glue == .both || p.glue == .prefix || (p.glue == .quote && pClosing)
                    case .command:
                        break
                    }
                case .quote:
                    attach = closing
                }
            }
            if idx > 0 && !attach { out += " " }
            switch piece {
            case .command(let c): out += c
            case .word(let w): out += w
            case .symbol(let sym, _): out += sym.text
            }
        }
        return out
    }

    private static func isWord(_ piece: Piece?) -> Bool {
        if let piece, case .word = piece { return true }
        return false
    }
}
