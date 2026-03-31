import AppKit
import SwiftUI

// MARK: - Model

struct InstalledEditorApp: Identifiable, Hashable {
    let applicationURL: URL
    let bundleIdentifier: String?
    let displayName: String
    let ranking: Int
    let icon: NSImage

    var id: String {
        bundleIdentifier ?? applicationURL.path
    }

    var isVSCode: Bool {
        bundleIdentifier == "com.microsoft.VSCode" || displayName == "VS Code"
    }

    static func == (lhs: InstalledEditorApp, rhs: InstalledEditorApp) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Discovery

struct KnownEditorDefinition {
    let displayName: String
    let ranking: Int
    let bundleIdentifiers: [String]
    let applicationNames: [String]

    func matches(name: String, bundleIdentifier: String?) -> Bool {
        if let bundleIdentifier, bundleIdentifiers.contains(bundleIdentifier) {
            return true
        }

        let normalized = name
            .lowercased()
            .replacingOccurrences(of: ".app", with: "")
        return applicationNames.contains {
            $0.lowercased().replacingOccurrences(of: ".app", with: "") == normalized
        }
    }
}

enum EditorAppDiscovery {
    static let applicationSearchRoots: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Setapp"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Applications"),
    ]

    static let knownEditors: [KnownEditorDefinition] = [
        KnownEditorDefinition(
            displayName: "VS Code",
            ranking: 0,
            bundleIdentifiers: ["com.microsoft.VSCode"],
            applicationNames: ["Visual Studio Code", "VS Code"]
        ),
        KnownEditorDefinition(
            displayName: "Cursor",
            ranking: 1,
            bundleIdentifiers: ["com.todesktop.230313mzl4w4u92"],
            applicationNames: ["Cursor"]
        ),
        KnownEditorDefinition(
            displayName: "Zed",
            ranking: 2,
            bundleIdentifiers: ["dev.zed.Zed", "dev.zed.Zed-Preview"],
            applicationNames: ["Zed", "Zed Preview"]
        ),
        KnownEditorDefinition(
            displayName: "Qoder",
            ranking: 3,
            bundleIdentifiers: [],
            applicationNames: ["Qoder"]
        ),
        KnownEditorDefinition(
            displayName: "Windsurf",
            ranking: 4,
            bundleIdentifiers: [],
            applicationNames: ["Windsurf"]
        ),
        KnownEditorDefinition(
            displayName: "Sublime Text",
            ranking: 5,
            bundleIdentifiers: ["com.sublimetext.4"],
            applicationNames: ["Sublime Text"]
        ),
        KnownEditorDefinition(
            displayName: "Nova",
            ranking: 6,
            bundleIdentifiers: ["com.panic.Nova"],
            applicationNames: ["Nova"]
        ),
        KnownEditorDefinition(
            displayName: "BBEdit",
            ranking: 7,
            bundleIdentifiers: ["com.barebones.bbedit"],
            applicationNames: ["BBEdit"]
        ),
        KnownEditorDefinition(
            displayName: "TextMate",
            ranking: 8,
            bundleIdentifiers: ["com.macromates.TextMate"],
            applicationNames: ["TextMate"]
        ),
        KnownEditorDefinition(
            displayName: "Xcode",
            ranking: 9,
            bundleIdentifiers: ["com.apple.dt.Xcode"],
            applicationNames: ["Xcode"]
        ),
    ]

    static func discoverEditors(for url: URL) -> [InstalledEditorApp] {
        var editorsByID: [String: InstalledEditorApp] = [:]

        func register(_ editor: InstalledEditorApp) {
            if let existing = editorsByID[editor.id], existing.ranking <= editor.ranking {
                return
            }
            editorsByID[editor.id] = editor
        }

        for definition in knownEditors {
            if let editor = resolveKnownEditor(definition) {
                register(editor)
            }
        }

        let workspaceEditors = NSWorkspace.shared.urlsForApplications(toOpen: url)
        for applicationURL in workspaceEditors {
            if let editor = resolveEditor(at: applicationURL) {
                register(editor)
            }
        }

        if editorsByID.isEmpty {
            for applicationURL in workspaceEditors {
                if let editor = resolveEditor(at: applicationURL, allowFallback: true) {
                    register(editor)
                }
            }
        }

        return editorsByID.values.sorted {
            if $0.ranking != $1.ranking {
                return $0.ranking < $1.ranking
            }

            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private static func resolveKnownEditor(_ definition: KnownEditorDefinition) -> InstalledEditorApp? {
        for bundleIdentifier in definition.bundleIdentifiers {
            if let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier),
               let editor = resolveEditor(at: applicationURL, knownDefinition: definition, allowFallback: true)
            {
                return editor
            }
        }

        for applicationName in definition.applicationNames {
            if let applicationURL = findApplication(named: applicationName),
               let editor = resolveEditor(at: applicationURL, knownDefinition: definition, allowFallback: true)
            {
                return editor
            }
        }

        return nil
    }

    private static func resolveEditor(
        at applicationURL: URL,
        knownDefinition: KnownEditorDefinition? = nil,
        allowFallback: Bool = false
    ) -> InstalledEditorApp? {
        let bundle = Bundle(url: applicationURL)
        let bundleIdentifier = bundle?.bundleIdentifier
        let appName =
            (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? applicationURL.deletingPathExtension().lastPathComponent

        let matchedDefinition = knownDefinition ?? knownEditors.first {
            $0.matches(name: appName, bundleIdentifier: bundleIdentifier)
        }

        if matchedDefinition == nil && !allowFallback && !isLikelyEditor(name: appName, bundleIdentifier: bundleIdentifier) {
            return nil
        }

        return InstalledEditorApp(
            applicationURL: applicationURL,
            bundleIdentifier: bundleIdentifier,
            displayName: matchedDefinition?.displayName ?? normalizedDisplayName(for: appName),
            ranking: matchedDefinition?.ranking ?? fallbackRanking(for: appName, bundleIdentifier: bundleIdentifier),
            icon: applicationIcon(for: applicationURL)
        )
    }

    private static func normalizedDisplayName(for appName: String) -> String {
        if appName == "Visual Studio Code" {
            return "VS Code"
        }

        return appName
    }

    private static func fallbackRanking(for appName: String, bundleIdentifier: String?) -> Int {
        let haystack = [appName, bundleIdentifier ?? ""].joined(separator: " ").lowercased()

        if haystack.contains("code") { return 20 }
        if haystack.contains("cursor") { return 21 }
        if haystack.contains("zed") { return 22 }
        if haystack.contains("qoder") { return 23 }
        if haystack.contains("xcode") { return 40 }
        if haystack.contains("textedit") { return 90 }

        return 60
    }

    private static func isLikelyEditor(name: String, bundleIdentifier: String?) -> Bool {
        let haystack = [name, bundleIdentifier ?? ""].joined(separator: " ").lowercased()
        let keywords = [
            "code", "cursor", "zed", "qoder", "editor", "sublime",
            "nova", "bbedit", "textmate", "xcode", "vim", "emacs",
            "windsurf", "trae",
        ]
        return keywords.contains { haystack.contains($0) }
    }

    private static func findApplication(named applicationName: String) -> URL? {
        let fileManager = FileManager.default
        let normalizedName = applicationName.hasSuffix(".app") ? applicationName : "\(applicationName).app"

        for root in applicationSearchRoots {
            let directURL = root.appendingPathComponent(normalizedName)
            if fileManager.fileExists(atPath: directURL.path) {
                return directURL
            }

            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            if let match = children.first(where: {
                $0.lastPathComponent.localizedCaseInsensitiveCompare(normalizedName) == .orderedSame
            }) {
                return match
            }
        }

        return nil
    }

    private static func applicationIcon(for applicationURL: URL) -> NSImage {
        let icon = NSWorkspace.shared.icon(forFile: applicationURL.path)
        icon.size = NSSize(width: 32, height: 32)
        return icon
    }
}

// MARK: - Dropdown UI

struct EditorDropdownButton: View {
    let theme: MossTheme
    let selectedEditor: InstalledEditorApp?
    let editors: [InstalledEditorApp]
    @Binding var isMenuPresented: Bool
    let primaryAction: () -> Void
    let chooseEditor: (InstalledEditorApp) -> Void
    @State private var isPrimaryHovered = false
    @State private var isChevronHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: primaryAction) {
                EditorAppIcon(editor: selectedEditor)
                    .frame(width: 36, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(segmentHighlight(isPrimaryHovered))
            .pointerCursor()
            .onHover { isPrimaryHovered = $0 }

            Rectangle()
                .fill(separatorColor)
                .frame(width: 1, height: 16)

            Button {
                isMenuPresented.toggle()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(chevronForeground)
                    .frame(width: 28, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(segmentHighlight(isChevronHovered))
            .pointerCursor()
            .onHover { isChevronHovered = $0 }
        }
        .background(baseBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(buttonBorder, lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if isMenuPresented {
                EditorDropdownPopover(
                    editors: editors
                ) { editor in
                    chooseEditor(editor)
                    isMenuPresented = false
                }
                .fixedSize()
                .offset(y: 36)
            }
        }
        .help(selectedEditor?.displayName ?? "Open in Editor")
        .zIndex(isMenuPresented ? 30 : 0)
    }

    private var baseBackground: Color {
        theme.accentSubtle
    }

    private var buttonBorder: Color {
        (isPrimaryHovered || isChevronHovered || isMenuPresented) ? theme.borderStrong : theme.borderMedium
    }

    private var separatorColor: Color {
        theme.borderMedium
    }

    private func segmentHighlight(_ isHovered: Bool) -> Color {
        isHovered ? theme.accentHover : .clear
    }

    private var chevronForeground: Color {
        isChevronHovered || isMenuPresented ? theme.foreground : theme.secondaryForeground
    }
}

private struct EditorDropdownPopover: View {
    @Environment(\.mossTheme) private var theme
    let editors: [InstalledEditorApp]
    let chooseEditor: (InstalledEditorApp) -> Void

    private var rowWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12, weight: .medium)
        let widestTitle = editors.map {
            ($0.displayName as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(widestTitle + 16 + 10 + 20 + 12)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if editors.isEmpty {
                Text("No compatible editors found")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(editors) { editor in
                    EditorDropdownRow(
                        theme: theme,
                        editor: editor,
                        rowWidth: rowWidth,
                        chooseEditor: chooseEditor
                    )
                }
            }
        }
        .padding(6)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(theme.borderSubtle, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 8)
    }
}

private struct EditorDropdownRow: View {
    let theme: MossTheme
    let editor: InstalledEditorApp
    let rowWidth: CGFloat
    let chooseEditor: (InstalledEditorApp) -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            EditorAppIcon(editor: editor)

            Text(editor.displayName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.foreground)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 10)
        .frame(width: rowWidth, height: 30, alignment: .leading)
        .background(rowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture { chooseEditor(editor) }
        .onHover { isHovered = $0 }
        .pointerCursor()
    }

    private var rowBackground: Color {
        if isHovered {
            return theme.accentHover
        }
        return .clear
    }
}

struct EditorAppIcon: View {
    let editor: InstalledEditorApp?

    var body: some View {
        Group {
            if let editor {
                Image(nsImage: editor.icon)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            } else {
                Image(systemName: "square.and.pencil")
                    .resizable()
                    .scaledToFit()
            }
        }
        .frame(width: 16, height: 16)
    }
}
