# Plan: Replace WebView CodeMirror with Native Neon + tree-sitter

## Context

The file preview panel currently uses **WKWebView + CodeMirror 6** (bundled as 1.5MB app.js) for syntax highlighting. This involves a complex WebView bridge (scroll position via JS messages, theme serialization to CSS, page-ready handshaking, error logging). Replacing it with a native **NSTextView + Neon + SwiftTreeSitter** stack will:

- Eliminate WebView overhead and bridge complexity
- Remove the WebKit framework dependency
- Use ghostty's palette colors (ANSI 0-15) for syntax theming, matching the terminal's color scheme
- Provide AST-level accurate syntax highlighting (same engine as Zed, Neovim, Helix)

## Implementation

### 1. Add SPM Dependencies (`project.yml`)

**Packages to add:**
```yaml
packages:
  Neon:
    url: https://github.com/ChimeHQ/Neon
    branch: main
  tree-sitter-swift:
    url: https://github.com/alex-pinkus/tree-sitter-swift
    branch: main
  tree-sitter-c:
    url: https://github.com/tree-sitter/tree-sitter-c
    branch: master
  tree-sitter-cpp:
    url: https://github.com/tree-sitter/tree-sitter-cpp
    branch: master
  tree-sitter-go:
    url: https://github.com/tree-sitter/tree-sitter-go
    branch: master
  tree-sitter-python:
    url: https://github.com/tree-sitter/tree-sitter-python
    branch: master
  tree-sitter-javascript:
    url: https://github.com/tree-sitter/tree-sitter-javascript
    branch: master
  tree-sitter-typescript:
    url: https://github.com/tree-sitter/tree-sitter-typescript
    branch: master
  tree-sitter-rust:
    url: https://github.com/tree-sitter/tree-sitter-rust
    branch: master
  tree-sitter-java:
    url: https://github.com/tree-sitter/tree-sitter-java
    branch: master
  tree-sitter-json:
    url: https://github.com/tree-sitter/tree-sitter-json
    branch: master
  tree-sitter-bash:
    url: https://github.com/tree-sitter/tree-sitter-bash
    branch: master
  tree-sitter-ruby:
    url: https://github.com/tree-sitter/tree-sitter-ruby
    branch: master
  tree-sitter-css:
    url: https://github.com/tree-sitter/tree-sitter-css
    branch: master
  tree-sitter-html:
    url: https://github.com/tree-sitter/tree-sitter-html
    branch: master
  tree-sitter-yaml:
    url: https://github.com/tree-sitter-grammars/tree-sitter-yaml
    branch: master
  tree-sitter-markdown:
    url: https://github.com/tree-sitter-grammars/tree-sitter-markdown
    branch: main
  tree-sitter-toml:
    url: https://github.com/tree-sitter-grammars/tree-sitter-toml
    branch: master
```

**Target dependencies** — add Neon + all TreeSitter* products, remove `WebKit.framework`.

**Note:** csharp, php, sql, swift(official) lack SPM support — these fall back to plain text. `alex-pinkus/tree-sitter-swift` is a community grammar with SPM support as a substitute.

### 2. Extend MossTheme with Palette Colors (`Sources/Terminal/MossTheme.swift`)

Read ghostty's ANSI palette (colors 0-15) via `ghostty_config_get` with `ghostty_config_palette_s`:

```swift
// In MossTheme.init(config:)
var palette = ghostty_config_palette_s()
let paletteKey = "palette"
ghostty_config_get(config, &palette, paletteKey, UInt(paletteKey.utf8.count))

// Store as [NSColor] array for ANSI 0-15
self.paletteColors = (0..<16).map { i in
    let c = palette.colors[i]
    return NSColor(red: CGFloat(c.r)/255, green: CGFloat(c.g)/255, blue: CGFloat(c.b)/255, alpha: 1)
}
```

Add convenience accessors: `palette(index:) -> NSColor`.

### 3. Create Token → Color Mapping

Map tree-sitter capture names to ANSI palette indices (like terminal editors):

| Token Name | Palette Index | Typical Color |
|-----------|--------------|--------------|
| `keyword` | 5 (magenta) | Magenta |
| `string` | 2 (green) | Green |
| `comment` | foreground@60% | Dimmed |
| `number`, `float` | 3 (yellow) | Yellow |
| `type` | 6 (cyan) | Cyan |
| `function` | 4 (blue) | Blue |
| `variable` | foreground | Default |
| `operator` | 1 (red) | Red |
| `constant`, `boolean` | 9 (bright red) | Bright Red |
| `property` | 14 (bright cyan) | Bright Cyan |
| `attribute` | 3 (yellow) | Yellow |
| `tag` | 1 (red) | Red (HTML) |

This mirrors Vim/Neovim terminal colorscheme behavior.

### 4. New File: `NativeCodePreviewView.swift`

NSViewRepresentable wrapping an NSTextView with Neon highlighting:

- **Read-only** NSTextView (editable=false, selectable=true)
- **Line numbers** via NSRuler or gutter drawing
- **Monospaced font** (system monospaced, matching terminal feel)
- **Scroll position memory** (static cache by filename, same pattern as current CodeMirrorPreviewContainerView)
- Uses `TextViewHighlighter` from Neon to wire tree-sitter → NSTextView
- `TokenAttributeProvider` closure maps token names → MossTheme palette colors
- Background color from `MossTheme.surfaceBackground`

### 5. New File: `TreeSitterLanguageProvider.swift`

Maps file extensions/names to `LanguageConfiguration`:

```swift
enum TreeSitterLanguageProvider {
    static func configuration(for url: URL) -> LanguageConfiguration? {
        switch url.pathExtension.lowercased() {
        case "swift": return try? .init(tree_sitter_swift(), name: "Swift")
        case "rs": return try? .init(tree_sitter_rust(), name: "Rust")
        case "py": return try? .init(tree_sitter_python(), name: "Python")
        // ... etc
        }
    }
}
```

Replaces both `PreviewLanguage` enum and `PreviewLanguageResolver`.

### 6. Update `FilePreviewView.swift`

Replace `CodeMirrorPreviewView(...)` with `NativeCodePreviewView(...)`. Remove the `PreviewLanguage` dependency — pass the URL directly and let `TreeSitterLanguageProvider` resolve internally.

### 7. Remove WebView Code

**Delete:**
- `Sources/Views/FileTree/CodeMirrorPreviewView.swift`
- `Sources/Views/FileTree/SyntaxHighlighter.swift` (PreviewLanguage/PreviewLanguageResolver)
- `Resources/CodeMirrorPreview/` (index.html + app.js)
- `Web/CodeMirrorPreview/` (source JS/HTML/build scripts)

**Remove from project.yml:**
- `Resources/CodeMirrorPreview` resource entry
- `WebKit.framework` SDK dependency

## Files to Modify

| File | Action |
|------|--------|
| `project.yml` | Add 18 SPM packages, remove CodeMirrorPreview resources + WebKit |
| `Sources/Terminal/MossTheme.swift` | Add palette color reading (ANSI 0-15) |
| `Sources/Views/FileTree/NativeCodePreviewView.swift` | **NEW** — NSTextView + Neon |
| `Sources/Views/FileTree/TreeSitterLanguageProvider.swift` | **NEW** — extension → grammar mapping |
| `Sources/Views/FileTree/FilePreviewView.swift` | Use NativeCodePreviewView |
| `Sources/Views/FileTree/CodeMirrorPreviewView.swift` | **DELETE** |
| `Sources/Views/FileTree/SyntaxHighlighter.swift` | **DELETE** |
| `Resources/CodeMirrorPreview/` | **DELETE** directory |

## Verification

1. `xcodegen generate` — project generates without errors
2. `xcodebuild -project Moss.xcodeproj -scheme Moss build` — compiles
3. Open app, select files in file tree — verify syntax highlighting renders
4. Test multiple languages: .swift, .py, .rs, .go, .js, .ts, .json, .yaml, .md
5. Verify colors match terminal palette (change ghostty theme → preview colors should update)
6. Verify unsupported file types (.sql, .php, .cs) show as plain text
7. Test scroll position memory (switch between files, verify scroll restores)
