import SwiftUI
import AppKit

struct FilePreviewPanel: View {
    let url: URL
    @Environment(\.mossTheme) private var theme
    @State private var showDiff = false
    @State private var diffSummary: FileDiffSummary?
    @State private var availableEditors: [InstalledEditorApp] = []
    @State private var isEditorMenuPresented = false
    @AppStorage("filePreviewWrapLines") private var wrapLines = false
    @AppStorage("preferredExternalEditorBundleIdentifier") private var preferredEditorBundleIdentifier = ""
    @AppStorage("preferredExternalEditorPath") private var preferredEditorPath = ""
    let onClose: () -> Void

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(headerIconBackground)

                        Image(systemName: "doc.text")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme?.foreground ?? .primary)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme?.foreground ?? .primary)
                            .lineLimit(1)

                        Text(directoryPathDisplay)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme?.secondaryForeground ?? .secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        PreviewToolbarButton(
                            theme: theme,
                            isActive: wrapLines,
                            action: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    wrapLines.toggle()
                                }
                            }
                        ) {
                            PreviewToolbarIcon(
                                systemName: wrapLines ? "text.justify.left" : "arrow.left.and.right.text.vertical"
                            )
                        }
                        .help(wrapButtonHelp)

                        PreviewToolbarButton(
                            theme: theme,
                            isActive: showDiff,
                            action: {
                                withAnimation(.easeInOut(duration: 0.16)) {
                                    showDiff.toggle()
                                }
                            }
                        ) {
                            PreviewToolbarIcon(systemName: "arrow.left.arrow.right")
                        }
                        .help(diffButtonHelp)

                        EditorDropdownButton(
                            theme: theme,
                            selectedEditor: selectedEditor,
                            editors: orderedEditors,
                            isMenuPresented: $isEditorMenuPresented,
                            primaryAction: openPreferredEditor,
                            chooseEditor: openInEditor
                        )
                    }

                    PreviewCloseButton(theme: theme, action: onClose)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background {
                    ZStack {
                        headerBackground

                        if isEditorMenuPresented {
                            Rectangle()
                                .fill(Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    isEditorMenuPresented = false
                                }
                        }
                    }
                }
                .zIndex(20)

                Divider()
                    .overlay((theme?.border ?? .clear).opacity(0.8))
                    .zIndex(10)

                ZStack {
                    FilePreviewView(url: url, wrapLines: wrapLines)
                        .opacity(showDiff ? 0 : 1)
                        .allowsHitTesting(!showDiff)
                        .accessibilityHidden(showDiff)

                    FileDiffView(url: url)
                        .opacity(showDiff ? 1 : 0)
                        .allowsHitTesting(showDiff)
                        .accessibilityHidden(!showDiff)

                    if isEditorMenuPresented {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                isEditorMenuPresented = false
                            }
                    }
                }
                .zIndex(0)
            }
            
            if isEditorMenuPresented {
                EscapeKeyHandler {
                    isEditorMenuPresented = false
                }
                .allowsHitTesting(false)
            }
        }
        .background(theme?.background ?? Color(nsColor: .controlBackgroundColor))
        .task(id: url) {
            loadDiffSummary()
            refreshAvailableEditors()
            isEditorMenuPresented = false
        }
        .animation(.easeInOut(duration: 0.16), value: showDiff)
    }

    private var directoryPathDisplay: String {
        url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    private var wrapButtonHelp: String {
        wrapLines ? "Disable line wrapping" : "Enable line wrapping"
    }

    private var diffButtonHelp: String {
        let action = showDiff ? "Hide diff" : "Show diff"
        guard let diffSummary else { return action }
        return "\(action) (+\(diffSummary.additions) / -\(diffSummary.deletions))"
    }

    private var headerBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.02)
            ?? Color(nsColor: .controlBackgroundColor)
    }

    private var headerIconBackground: Color {
        theme?.surfaceBackground.mix(with: .white, by: 0.08)
            ?? Color(nsColor: .windowBackgroundColor)
    }

    private var selectedEditor: InstalledEditorApp? {
        if !preferredEditorBundleIdentifier.isEmpty,
           let preferred = availableEditors.first(where: { $0.bundleIdentifier == preferredEditorBundleIdentifier })
        {
            return preferred
        }

        if !preferredEditorPath.isEmpty,
           let preferred = availableEditors.first(where: { $0.applicationURL.path == preferredEditorPath })
        {
            return preferred
        }

        if let vscode = availableEditors.first(where: \.isVSCode) {
            return vscode
        }

        return availableEditors.first
    }

    private var orderedEditors: [InstalledEditorApp] {
        guard let selectedEditor else { return availableEditors }
        return [selectedEditor] + availableEditors.filter { $0.id != selectedEditor.id }
    }

    private func loadDiffSummary() {
        FileDiffLoader.loadSummary(for: url) { result in
            switch result {
            case let .success(summary):
                diffSummary = summary
            case .failure:
                diffSummary = nil
            }
        }
    }

    private func refreshAvailableEditors() {
        availableEditors = EditorAppDiscovery.discoverEditors(for: url)
    }

    private func openPreferredEditor() {
        if let selectedEditor {
            openInEditor(selectedEditor)
            return
        }

        if !NSWorkspace.shared.open(url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func openInEditor(_ editor: InstalledEditorApp) {
        preferredEditorBundleIdentifier = editor.bundleIdentifier ?? ""
        preferredEditorPath = editor.applicationURL.path

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open(
            [url],
            withApplicationAt: editor.applicationURL,
            configuration: configuration
        ) { _, error in
            if error != nil {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }
}

private struct PreviewToolbarButton<Label: View>: View {
    let theme: MossTheme?
    var isActive = false
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            label()
                .lineLimit(1)
                .frame(maxHeight: .infinity, alignment: .center)
                .foregroundStyle(foregroundColor)
                .padding(.horizontal, 12)
                .frame(height: 30)
                .background(backgroundColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(borderColor, lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var backgroundColor: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.18 : 0.12)
        }

        let base = theme?.surfaceBackground ?? Color(nsColor: .windowBackgroundColor)
        return base.mix(with: .accentColor, by: isHovered ? 0.08 : 0.02)
    }

    private var borderColor: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.52 : 0.32)
        }

        return (theme?.border ?? Color(nsColor: .separatorColor))
            .opacity(isHovered ? 0.95 : 0.65)
    }

    private var foregroundColor: Color {
        if isActive {
            return theme?.foreground ?? .primary
        }

        return isHovered
            ? (theme?.foreground ?? .primary)
            : (theme?.secondaryForeground ?? .secondary)
    }
}

private struct PreviewToolbarIcon: View {
    let systemName: String

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11, weight: .semibold))
            .frame(width: 12, height: 12, alignment: .center)
    }
}

private struct EditorDropdownButton: View {
    let theme: MossTheme?
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
            .onHover { hovering in
                isPrimaryHovered = hovering
            }

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
            .onHover { hovering in
                isChevronHovered = hovering
            }
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
        let base = theme?.surfaceBackground ?? Color(nsColor: .windowBackgroundColor)
        return base.mix(with: .accentColor, by: 0.02)
    }

    private var buttonBorder: Color {
        (theme?.border ?? Color(nsColor: .separatorColor))
            .opacity((isPrimaryHovered || isChevronHovered || isMenuPresented) ? 0.95 : 0.65)
    }

    private var separatorColor: Color {
        (theme?.border ?? Color(nsColor: .separatorColor))
            .opacity(0.65)
    }

    private func segmentHighlight(_ isHovered: Bool) -> Color {
        let base = theme?.surfaceBackground ?? Color(nsColor: .windowBackgroundColor)
        if isHovered {
            return base.mix(with: .accentColor, by: 0.10)
        }
        return .clear
    }

    private var chevronForeground: Color {
        isChevronHovered || isMenuPresented
            ? (theme?.foreground ?? .primary)
            : (theme?.secondaryForeground ?? .secondary)
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
                .stroke(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 8)
    }
}

private struct EditorDropdownRow: View {
    let theme: MossTheme?
    let editor: InstalledEditorApp
    let rowWidth: CGFloat
    let chooseEditor: (InstalledEditorApp) -> Void
    @State private var isHovered = false

    var body: some View {
        Button {
            chooseEditor(editor)
        } label: {
            HStack(spacing: 10) {
                EditorAppIcon(editor: editor)

                Text(editor.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme?.foreground ?? .primary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(width: rowWidth, height: 30, alignment: .leading)
            .background(rowBackground)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !isHovered { isHovered = true }
                NSCursor.arrow.set()
            case .ended:
                isHovered = false
            }
        }
    }

    private var rowBackground: Color {
        if isHovered {
            let base = theme?.surfaceBackground ?? Color(nsColor: .windowBackgroundColor)
            return base.mix(with: .accentColor, by: 0.12)
        }
        return .clear
    }
}

private struct EditorAppIcon: View {
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

private struct EscapeKeyHandler: NSViewRepresentable {
    let onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onEscape: onEscape)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        context.coordinator.start()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEscape = onEscape
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onEscape: () -> Void
        private var monitor: Any?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else {
                    return event
                }

                self?.onEscape()
                return nil
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        deinit {
            stop()
        }
    }
}

private struct PreviewCloseButton: View {
    let theme: MossTheme?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered ? (theme?.foreground ?? .primary) : (theme?.secondaryForeground ?? .secondary))
                .frame(width: 28, height: 28)
                .background(closeBackground)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(closeBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var closeBackground: Color {
        let base = theme?.surfaceBackground.mix(with: .white, by: 0.04)
            ?? Color(nsColor: .windowBackgroundColor)
        return base.opacity(isHovered ? 1.0 : 0.88)
    }

    private var closeBorder: Color {
        (theme?.border ?? Color(nsColor: .separatorColor))
            .opacity(isHovered ? 0.9 : 0.6)
    }
}

private struct InstalledEditorApp: Identifiable, Hashable {
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

private struct KnownEditorDefinition {
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

private enum EditorAppDiscovery {
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
        )
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
            (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ??
            (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String) ??
            applicationURL.deletingPathExtension().lastPathComponent

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
            "windsurf", "trae"
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
