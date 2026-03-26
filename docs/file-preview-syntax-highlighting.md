# File Preview Syntax Highlighting

## Overview

Moss's file preview now uses a hybrid stack:

- Preview host: `WKWebView`
- Editor/rendering engine: `CodeMirror 6`
- Asset pipeline: local bundle built from `Web/CodeMirrorPreview`
- Preview mode: read-only, selectable source preview

The Swift side still owns file loading, error handling, theme colors, and preview layout. The web side only renders source text.

## Current Architecture

### 1. File Loading

`FilePreviewView` still handles all file IO on the Swift side:

- binary detection by scanning the first chunk for `0x00`
- UTF-8 decoding requirement
- error placeholder for binary or unreadable files

If the file is valid text, Moss builds a `FilePreviewContent` value with:

- the full file text
- an optional language hint from `PreviewLanguageResolver`

### 2. Preview Rendering

The actual preview surface is a custom `NSViewRepresentable` wrapper around `WKWebView`.

- `CodeMirrorPreviewView` bridges SwiftUI to AppKit/WebKit
- `CodeMirrorPreviewContainerView` owns one `WKWebView`
- Swift sends text, wrap mode, filename, language hint, and theme colors to JavaScript
- JavaScript updates one persistent CodeMirror editor instance

Important behaviors:

- read-only document
- selectable text
- line numbers
- wrap / horizontal scrolling toggle
- whole-document rendering in one CodeMirror view

### 3. Theme Integration

Swift derives preview colors from `MossTheme` and forwards them to the web layer.

- editor background comes from `surfaceBackground`
- gutter background is a slightly offset surface tone
- gutter separator uses `border`
- foreground text uses `foreground`
- gutter text uses `secondaryForeground`

CodeMirror applies those colors through a generated editor theme. Token colors use CodeMirror's built-in highlight styles:

- dark themes use `oneDarkHighlightStyle`
- light themes use `defaultHighlightStyle`

### 4. Language Resolution

Swift still provides a coarse `PreviewLanguage` hint, but CodeMirror primarily resolves languages from the filename and its own language registry.

Current behavior:

- Markdown is rendered through CodeMirror's Markdown package
- fenced code blocks in Markdown use CodeMirror language descriptions
- other files use filename matching first, then the Swift language hint as fallback

## Asset Pipeline

The web bundle lives under `Web/CodeMirrorPreview`.

- `package.json` declares the preview build toolchain
- `build.mjs` bundles the editor with `esbuild`
- output is written to `Resources/CodeMirrorPreview`

This keeps runtime fully local. The app does not depend on a CDN.

## Known Limitations

- Bundle size is currently larger than the old native preview path because CodeMirror language data emits many lazy chunks
- Highlight colors are better than the old Neon path, but they are not yet derived from the full ghostty palette
- Language detection still starts from a coarse Swift resolver for some special filenames
- This is still source preview only, not rendered Markdown

## Future Work

- Measure cold-open and memory costs versus the old native preview
- Trim the bundle by replacing `@codemirror/language-data` with a curated language set
- Add richer theme mapping from `MossTheme` into syntax token colors
- Add a dedicated rendered Markdown mode if the preview panel needs it
