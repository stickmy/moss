import SwiftUI

struct ZoomedTerminalView: View {
    @Bindable var session: TerminalSession
    @Binding var fileTreeSession: TerminalSession?
    @Binding var fileTreeFloating: Bool
    let onDismiss: () -> Void
    let onNewTerminal: () -> Void
    let onCloseTerminal: () -> Void

    private var showDockedFileTree: Bool {
        fileTreeSession?.id == session.id && !fileTreeFloating
    }

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar with back button
            HStack(spacing: 12) {
                Button(action: onDismiss) {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Text(session.title.isEmpty ? "Terminal" : session.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer()

                Button(action: onNewTerminal) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)

                Button(action: onCloseTerminal) {
                    Image(systemName: "xmark")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial)

            HSplitView {
                if showDockedFileTree {
                    FileTreeView(model: session.fileTreeModel)
                        .frame(minWidth: 200, idealWidth: 250, maxWidth: 400)
                }

                VStack(spacing: 0) {
                    TerminalSplitContentView(session: session)
                }
                .overlay(alignment: .topTrailing) {
                    if let searchState = session.searchState {
                        TerminalSearchOverlay(
                            searchState: searchState,
                            onNavigate: { session.navigateSearch($0) },
                            onClose: { session.endSearch() }
                        )
                    }
                }
            }
        }
        .overlay {
            StatusBorder(status: session.status)
        }
        .popover(
            isPresented: Binding(
                get: { fileTreeSession?.id == session.id && fileTreeFloating },
                set: { if !$0 { fileTreeSession = nil } }
            ), arrowEdge: .leading
        ) {
            FileTreeView(model: session.fileTreeModel)
                .frame(width: 300, height: 500)
        }
    }
}
