import AppKit
import Highlightr

final class SyntaxHighlighter {
    static let shared = SyntaxHighlighter()

    private let highlightr: Highlightr?

    private init() {
        highlightr = Highlightr()
        highlightr?.setTheme(to: "atom-one-dark")
        highlightr?.theme.themeBackgroundColor = .clear
    }

    func highlight(_ code: String, language: String?) -> NSAttributedString? {
        return highlightr?.highlight(code, as: language)
    }

    /// Split a highlighted NSAttributedString into per-line AttributedStrings
    func highlightLines(_ code: String, language: String?) -> [AttributedString] {
        guard let highlighted = highlight(code, language: language) else {
            return code.components(separatedBy: "\n").map { AttributedString($0) }
        }
        return splitByNewlines(highlighted).compactMap { nsAttr in
            try? AttributedString(nsAttr, including: \.appKit)
        }
    }

    private func splitByNewlines(_ attrStr: NSAttributedString) -> [NSAttributedString] {
        let string = attrStr.string
        var result: [NSAttributedString] = []
        var searchStart = string.startIndex

        while searchStart < string.endIndex {
            if let newlineRange = string.range(of: "\n", range: searchStart..<string.endIndex) {
                let lineRange = searchStart..<newlineRange.lowerBound
                let nsRange = NSRange(lineRange, in: string)
                result.append(attrStr.attributedSubstring(from: nsRange))
                searchStart = newlineRange.upperBound
            } else {
                let lineRange = searchStart..<string.endIndex
                let nsRange = NSRange(lineRange, in: string)
                result.append(attrStr.attributedSubstring(from: nsRange))
                break
            }
        }

        // Handle trailing newline producing an empty last line
        if string.hasSuffix("\n") {
            result.append(NSAttributedString(string: ""))
        }

        return result
    }

    static func language(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        // Check special filenames first
        switch name {
        case "makefile", "gnumakefile": return "makefile"
        case "dockerfile": return "dockerfile"
        case "podfile", "gemfile", "rakefile", "fastfile", "appfile", "matchfile":
            return "ruby"
        case "cmakelists.txt": return "cmake"
        case ".gitignore", ".dockerignore": return "bash"
        default: break
        }

        switch ext {
        // Systems
        case "swift": return "swift"
        case "rs": return "rust"
        case "go": return "go"
        case "c": return "c"
        case "h": return "objectivec"
        case "m": return "objectivec"
        case "mm", "cpp", "cc", "cxx", "hpp", "hxx": return "cpp"
        case "zig": return "zig"

        // JVM
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "scala": return "scala"
        case "groovy", "gradle": return "groovy"

        // Web
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "mts": return "typescript"
        case "jsx": return "javascript"
        case "tsx": return "typescript"
        case "html", "htm": return "html"
        case "css": return "css"
        case "scss": return "scss"
        case "less": return "less"
        case "vue": return "html"
        case "svelte": return "html"

        // Scripting
        case "py": return "python"
        case "rb": return "ruby"
        case "php": return "php"
        case "pl", "pm": return "perl"
        case "lua": return "lua"
        case "r": return "r"
        case "sh", "bash", "zsh", "fish": return "bash"
        case "ps1", "psm1": return "powershell"

        // Functional
        case "hs": return "haskell"
        case "ex", "exs": return "elixir"
        case "erl": return "erlang"
        case "clj", "cljs": return "clojure"
        case "ml", "mli": return "ocaml"
        case "fs", "fsx": return "fsharp"
        case "elm": return "elm"

        // Data / Config
        case "json": return "json"
        case "xml", "plist", "xib", "storyboard": return "xml"
        case "yaml", "yml": return "yaml"
        case "toml": return "ini"
        case "ini", "cfg", "conf": return "ini"
        case "csv": return nil

        // Markup
        case "md", "markdown": return "markdown"
        case "tex", "latex": return "latex"
        case "rst": return "plaintext"

        // Other
        case "sql": return "sql"
        case "graphql", "gql": return "graphql"
        case "proto": return "protobuf"
        case "dart": return "dart"
        case "cs": return "csharp"
        case "vim": return "vim"
        case "diff", "patch": return "diff"
        case "cmake": return "cmake"
        case "nix": return "nix"
        case "tf", "hcl": return "hcl"

        default: return nil
        }
    }
}
