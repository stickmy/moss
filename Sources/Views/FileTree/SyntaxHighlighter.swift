import Foundation

enum PreviewLanguage: Equatable {
    case bash
    case c
    case cpp
    case csharp
    case css
    case go
    case html
    case java
    case javascript
    case json
    case markdown
    case php
    case python
    case ruby
    case rust
    case swift
    case sql
    case toml
    case typescript
    case yaml

    var debugName: String {
        switch self {
        case .bash: "bash"
        case .c: "c"
        case .cpp: "cpp"
        case .csharp: "csharp"
        case .css: "css"
        case .go: "go"
        case .html: "html"
        case .java: "java"
        case .javascript: "javascript"
        case .json: "json"
        case .markdown: "markdown"
        case .php: "php"
        case .python: "python"
        case .ruby: "ruby"
        case .rust: "rust"
        case .swift: "swift"
        case .sql: "sql"
        case .toml: "toml"
        case .typescript: "typescript"
        case .yaml: "yaml"
        }
    }
}

enum PreviewLanguageResolver {
    static func language(for url: URL) -> PreviewLanguage? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        switch name {
        case "makefile", "gnumakefile": return .bash
        case "dockerfile": return .bash
        case "podfile", "gemfile", "rakefile", "fastfile", "appfile", "matchfile":
            return .ruby
        case "cmakelists.txt": return .cpp
        case ".gitignore", ".dockerignore": return .bash
        default: break
        }

        switch ext {
        case "swift": return .swift
        case "rs": return .rust
        case "go": return .go
        case "c": return .c
        case "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hxx": return .cpp

        case "java": return .java
        case "kt", "kts", "scala", "groovy", "gradle": return .java

        case "js", "mjs", "cjs", "jsx": return .javascript
        case "ts", "mts", "tsx": return .typescript
        case "html", "htm", "vue", "svelte": return .html
        case "css", "scss", "less": return .css

        case "py": return .python
        case "rb": return .ruby
        case "php": return .php
        case "sh", "bash", "zsh", "fish", "ps1", "psm1": return .bash

        case "json", "plist", "xib", "storyboard": return .json
        case "yaml", "yml": return .yaml
        case "toml", "ini", "cfg", "conf": return .toml

        case "md", "markdown", "rst", "tex", "latex": return .markdown

        case "sql": return .sql
        case "graphql", "gql": return .javascript
        case "cs": return .csharp

        default: return nil
        }
    }
}
