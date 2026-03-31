import Foundation
import SwiftTreeSitter
import SwiftTreeSitterLayer
import TreeSitter

import TreeSitterBash
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

enum TreeSitterLanguageProvider {
    static func configuration(for url: URL) -> LanguageConfiguration? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()

        // Match by filename first
        switch name {
        case "makefile", "gnumakefile", "dockerfile", ".gitignore", ".dockerignore":
            return tryConfig(tree_sitter_bash(), name: "Bash")
        case "podfile", "gemfile", "rakefile", "fastfile", "appfile", "matchfile":
            return tryConfig(tree_sitter_ruby(), name: "Ruby")
        case "cmakelists.txt":
            return tryConfig(tree_sitter_cpp(), name: "CPP")
        default:
            break
        }

        // Match by extension
        switch ext {
        case "rs":
            return tryConfig(tree_sitter_rust(), name: "Rust")
        case "go":
            return tryConfig(tree_sitter_go(), name: "Go")
        case "c":
            return tryConfig(tree_sitter_cpp(), name: "CPP")
        case "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "hxx":
            return tryConfig(tree_sitter_cpp(), name: "CPP")
        case "swift":
            // No tree-sitter-swift SPM package available; fall back to C++ for basic highlighting
            return tryConfig(tree_sitter_cpp(), name: "CPP")
        case "java", "kt", "kts", "scala", "groovy", "gradle":
            return tryConfig(tree_sitter_java(), name: "Java")
        case "js", "mjs", "cjs", "jsx":
            return tryConfig(tree_sitter_javascript(), name: "JavaScript")
        case "ts", "mts":
            return tryConfig(tree_sitter_typescript(), name: "TypeScript")
        case "tsx":
            return tryConfig(tree_sitter_tsx(), name: "TSX")
        case "html", "htm", "vue", "svelte":
            return tryConfig(tree_sitter_html(), name: "HTML")
        case "css", "scss", "less":
            return tryConfig(tree_sitter_css(), name: "CSS")
        case "py":
            return tryConfig(tree_sitter_python(), name: "Python")
        case "rb":
            return tryConfig(tree_sitter_ruby(), name: "Ruby")
        case "sh", "bash", "zsh", "fish":
            return tryConfig(tree_sitter_bash(), name: "Bash")
        case "json":
            return tryConfig(tree_sitter_json(), name: "JSON")
        case "yaml", "yml":
            return tryConfig(tree_sitter_yaml(), name: "YAML")
        case "toml", "ini", "cfg", "conf":
            return tryConfig(tree_sitter_toml(), name: "TOML")
        case "md", "markdown":
            return tryConfig(tree_sitter_markdown(), name: "Markdown")
        default:
            return nil
        }
    }

    private static func tryConfig(_ language: OpaquePointer, name: String) -> LanguageConfiguration? {
        try? LanguageConfiguration(language, name: name)
    }
}
