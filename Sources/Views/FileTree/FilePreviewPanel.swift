import AppKit
import SwiftUI

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
                            .foregroundStyle(theme.foreground)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.lastPathComponent)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.foreground)
                            .lineLimit(1)

                        Text(directoryPathDisplay)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.secondaryForeground)
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
                    .overlay((theme.border).opacity(0.8))
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
        .background(theme.background)
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
        theme.elevatedBackground
    }

    private var headerIconBackground: Color {
        theme.prominentBackground
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

// MARK: - Toolbar Buttons

private struct PreviewToolbarButton<Label: View>: View {
    let theme: MossTheme
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
        .pointerCursor()
        .onHover { isHovered = $0 }
    }

    private var backgroundColor: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.18 : 0.12)
        }
        return isHovered ? theme.accentHover : theme.accentSubtle
    }

    private var borderColor: Color {
        if isActive {
            return Color.accentColor.opacity(isHovered ? 0.52 : 0.32)
        }
        return isHovered ? theme.borderStrong : theme.borderMedium
    }

    private var foregroundColor: Color {
        if isActive {
            return theme.foreground
        }
        return isHovered ? theme.foreground : theme.secondaryForeground
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

private struct PreviewCloseButton: View {
    let theme: MossTheme
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(isHovered ? theme.foreground : theme.secondaryForeground)
                .frame(width: 28, height: 28)
                .background(closeBackground)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(closeBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .onHover { isHovered = $0 }
    }

    private var closeBackground: Color {
        let base = theme.raisedBackground
        return base.opacity(isHovered ? 1.0 : 0.88)
    }

    private var closeBorder: Color {
        isHovered ? theme.borderStrong : theme.borderMedium
    }
}

// MARK: - Escape Key Handler

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
        private var monitor: EventMonitor?

        init(onEscape: @escaping () -> Void) {
            self.onEscape = onEscape
        }

        func start() {
            guard monitor == nil else { return }
            monitor = EventMonitor(.keyDown) { [weak self] event in
                guard event.keyCode == 53 else {
                    return event
                }

                self?.onEscape()
                return nil
            }
        }

        func stop() {
            monitor = nil
        }
    }
}
