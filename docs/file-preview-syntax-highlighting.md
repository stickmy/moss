# File Preview Syntax Highlighting

## Overview

Moss's file preview now uses a single AppKit text system instead of the old per-line SwiftUI rendering path.

- Preview host: `STTextView`
- Syntax highlighting engine: `STTextView-Plugin-Neon`
- Parsing/highlighting backend: Tree-sitter via Neon
- Preview mode: read-only, selectable source preview

This gives the preview panel editor-like behavior for:

- cross-line text selection
- `Cmd+A` / copy
- line numbers
- wrap / horizontal scrolling toggle
- whole-document rendering instead of one SwiftUI view per line

## Current Architecture

### 1. File Loading

`FilePreviewView` loads the file contents asynchronously and keeps the existing safety checks:

- binary detection by scanning the first chunk for `0x00`
- UTF-8 decoding requirement
- error placeholder for binary or unreadable files

If the file is valid text, Moss builds a single `FilePreviewContent` value with:

- the full file text
- an optional preview language

### 2. Preview Rendering

The actual preview surface is a custom `NSViewRepresentable` wrapper around `STTextView`.

- `PreviewTextView` bridges SwiftUI to AppKit
- `PreviewTextContainerView` owns `NSScrollView + STTextView`
- the full document is assigned to one text view
- the preview is read-only but selectable

Important behaviors:

- `isEditable = false`
- `isSelectable = true`
- `showsLineNumbers = true`
- wrap toggle is implemented through `isHorizontallyResizable`

### 3. Theme Integration

Preview surfaces are visually aligned with Moss / ghostty theme colors where possible.

- editor background comes from `MossTheme.surfaceBackground`
- gutter text uses `secondaryForeground`
- gutter separator uses `border`
- foreground text uses `foreground`

Neon token colors currently use the plugin's default theme. Moss only controls the surrounding editor surface and gutter styling for now.

### 4. Language Resolution

`PreviewLanguageResolver` maps file names and extensions to the highlight language used by Neon.

Current supported highlight language enum:

- `bash`
- `c`
- `cpp`
- `csharp`
- `css`
- `go`
- `html`
- `java`
- `javascript`
- `json`
- `markdown`
- `php`
- `python`
- `ruby`
- `rust`
- `swift`
- `sql`
- `toml`
- `typescript`
- `yaml`

Representative mappings include:

- `Dockerfile`, `Makefile`, `.gitignore` -> `bash`
- `swift` -> `swift`
- `rs` -> `rust`
- `js`, `jsx` -> `javascript`
- `ts`, `tsx` -> `typescript`
- `md`, `markdown` -> `markdown`
- `yaml`, `yml` -> `yaml`

## Current Fallback Rules

### Unsupported Text Files

If a text file does not map to a known highlight language:

- Moss still opens it in `STTextView`
- syntax highlighting is skipped
- preview falls back to plain text rendering

### Binary Or Invalid Text

If a file is binary or cannot be decoded as UTF-8:

- the preview does not attempt to render the contents
- a placeholder error state is shown instead

### Markdown Safety Fallback

Markdown is currently treated as a special safety case.

- `.md` / `.markdown` files are still previewed as normal text
- Neon highlighting is temporarily disabled for markdown
- Moss logs a warning when this fallback is used

Reason:

- `STTextView-Plugin-Neon` is currently crashing in the markdown highlight path when applying TextKit 2 rendering attributes
- one concrete repro was opening this repository's `AGENTS.md`

This workaround keeps the app stable while preserving source preview, selection, copying, wrapping, and line numbers.

## Dependency Notes

Relevant package configuration lives in `project.yml`.

- `STTextView`
- `STTextView-Plugin-Neon`

Notes:

- `Highlightr` has been removed from the preview path
- `STTextView-Plugin-Neon` is currently referenced from `main` because the tagged release did not resolve cleanly in the current setup
- the resolved revision is pinned by SwiftPM in `Moss.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

## Known Limitations

- Markdown rendered preview is not implemented; markdown is source preview only
- Markdown syntax highlighting is temporarily disabled because of the upstream crash path
- Neon token colors are not yet derived from ghostty theme colors
- Unsupported text formats fall back to plain text instead of best-effort highlighting

## Future Work

- Re-enable markdown highlighting after fixing or working around the Neon / STTextView markdown crash
- Consider a custom Neon theme generated from `MossTheme`
- Expand language mappings if more repository file types need first-class highlighting
- Add a dedicated rendered markdown preview mode separate from source preview
